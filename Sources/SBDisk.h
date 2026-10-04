// SampleBlaster Lite: mounting and ejecting ZuluSCSI disk images.
// Plain Objective-C and AppKit/Foundation only, so it runs on macOS 10.13
// High Sierra and later.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const SBErrorDomain;

/// A disk image attached with hdiutil, and its mounted FAT partitions.
@interface SBMountedImage : NSObject
@property (nonatomic, readonly) NSURL *imageURL;
/// The whole-disk device (/dev/diskN); detaching it releases every partition.
@property (nonatomic, readonly) NSString *device;
/// Mounted partitions, in disk order.
@property (nonatomic, readonly) NSArray<NSURL *> *mountPoints;
- (instancetype)initWithImageURL:(NSURL *)imageURL device:(NSString *)device mountPoints:(NSArray<NSURL *> *)mountPoints;
@end

@interface SBDisk : NSObject

/// Runs a command-line tool and waits for it. Reads stdout and stderr at the
/// same time, so a chatty tool can't fill one pipe and stall.
+ (int)runTool:(NSString *)path
     arguments:(NSArray<NSString *> *)arguments
        output:(NSData * _Nullable * _Nullable)output
   errorOutput:(NSString * _Nullable * _Nullable)errorOutput;

/// True for the extensions SCSI emulators use for hard disk images.
+ (BOOL)isDiskImage:(NSURL *)url;

/// Attaches a raw disk image (a ZuluSCSI/BlueSCSI .img or .hda, with or
/// without an MBR partition table) and mounts its FAT partitions. The volumes
/// are hidden from Finder, so Finder doesn't litter them with .DS_Store files.
+ (nullable SBMountedImage *)attachImageAtURL:(NSURL *)url error:(NSError **)error;

/// Removes Mac clutter (._ files, .DS_Store, .Trashes, .fseventsd…) from a
/// mounted volume, then detaches the whole image. Tries a normal detach
/// first and a forced one only if that fails.
+ (BOOL)ejectImage:(SBMountedImage *)image error:(NSError **)error;

/// Deletes the files macOS leaves on FAT volumes, which the MPC would list
/// as if they were samples. Never follows symbolic links. Returns how many
/// were removed.
+ (NSUInteger)removeMacClutterInVolume:(NSURL *)root;

/// Parses `hdiutil attach -plist` output: the whole-disk device and the
/// mount points in disk order. Exposed for the tests.
+ (nullable NSString *)parseAttachPlist:(NSData *)plist mountPoints:(NSArray<NSURL *> * _Nullable * _Nullable)mountPoints;

@end

NS_ASSUME_NONNULL_END
