// SampleBlaster Lite: adding files to a mounted disk image.
//
// Files and folders are copied exactly as they are, names included: nothing
// is converted or renamed, because the image may be for any device (an MPC,
// a sampler, a synth…) and only the user knows what that device needs. Only
// file contents are written, never Mac metadata, so no ._ files appear on
// the card. Existing files are never replaced.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SBTransfer : NSObject

/// Copies files and folders into `folder` with their own names. A folder
/// that already exists there is added to; a file that already exists is
/// skipped, never replaced. Hidden files (.DS_Store and the like) and
/// symbolic links are skipped. `progress` is called with each source file's
/// name before it's copied. Returns one line per item: what was copied, or
/// why it was skipped.
+ (NSArray<NSString *> *)addItems:(NSArray<NSURL *> *)items
                         toFolder:(NSURL *)folder
                         progress:(nullable void (^)(NSString *name))progress;

@end

NS_ASSUME_NONNULL_END
