#import "SBDisk.h"
#include <unistd.h>

NSString * const SBErrorDomain = @"SampleBlasterLite";

static NSString * const kHdiutil = @"/usr/bin/hdiutil";

static NSError *SBError(NSString *message) {
    return [NSError errorWithDomain:SBErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation SBMountedImage
- (instancetype)initWithImageURL:(NSURL *)imageURL device:(NSString *)device mountPoints:(NSArray<NSURL *> *)mountPoints {
    if ((self = [super init])) {
        _imageURL = imageURL;
        _device = [device copy];
        _mountPoints = [mountPoints copy];
    }
    return self;
}
@end

@implementation SBDisk

+ (int)runTool:(NSString *)path
     arguments:(NSArray<NSString *> *)arguments
        output:(NSData **)output
   errorOutput:(NSString **)errorOutput {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:path];
    task.arguments = arguments;
    NSPipe *outPipe = [NSPipe pipe], *errPipe = [NSPipe pipe];
    task.standardOutput = outPipe;
    task.standardError = errPipe;
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];

    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        if (errorOutput) *errorOutput = launchError.localizedDescription ?: @"Couldn't start the tool.";
        if (output) *output = [NSData data];
        return -1;
    }
    // Read stderr on another queue while this one reads stdout.
    __block NSData *errData = nil;
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        errData = [errPipe.fileHandleForReading readDataToEndOfFile];
    });
    NSData *outData = [outPipe.fileHandleForReading readDataToEndOfFile];
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    [task waitUntilExit];

    if (output) *output = outData ?: [NSData data];
    if (errorOutput) {
        NSString *text = errData.length ? [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding] : @"";
        *errorOutput = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    }
    return task.terminationStatus;
}

+ (BOOL)isDiskImage:(NSURL *)url {
    NSString *ext = url.pathExtension.lowercaseString;
    return [ext isEqualToString:@"img"] || [ext isEqualToString:@"hda"] || [ext isEqualToString:@"hdd"];
}

+ (NSString *)parseAttachPlist:(NSData *)data mountPoints:(NSArray<NSURL *> **)mountPoints {
    if (mountPoints) *mountPoints = @[];
    if (data.length == 0) return nil;
    id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
    if (![plist isKindOfClass:NSDictionary.class]) return nil;
    NSArray *entities = plist[@"system-entities"];
    if (![entities isKindOfClass:NSArray.class]) return nil;

    NSString *whole = nil;
    NSMutableArray<NSDictionary *> *mounted = [NSMutableArray array];
    for (NSDictionary *entity in entities) {
        if (![entity isKindOfClass:NSDictionary.class]) continue;
        NSString *dev = entity[@"dev-entry"];
        if (![dev isKindOfClass:NSString.class]) continue;
        // The whole-disk node (/dev/disk4) is the shortest dev-entry.
        if (!whole || dev.length < whole.length) whole = dev;
        NSString *mount = entity[@"mount-point"];
        if ([mount isKindOfClass:NSString.class] && mount.length) [mounted addObject:@{@"dev": dev, @"mount": mount}];
    }
    [mounted sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"dev"] compare:b[@"dev"] options:NSNumericSearch];
    }];
    if (mountPoints) {
        NSMutableArray<NSURL *> *urls = [NSMutableArray array];
        for (NSDictionary *m in mounted) [urls addObject:[NSURL fileURLWithPath:m[@"mount"] isDirectory:YES]];
        *mountPoints = urls;
    }
    return whole;
}

+ (SBMountedImage *)attachImageAtURL:(NSURL *)url error:(NSError **)error {
    NSNumber *isRegular = nil;
    [url getResourceValue:&isRegular forKey:NSURLIsRegularFileKey error:NULL];
    if (!isRegular.boolValue) {
        if (error) *error = SBError([NSString stringWithFormat:@"%@ isn't a disk image file.", url.lastPathComponent]);
        return nil;
    }
    NSData *output = nil;
    NSString *errText = nil;
    // Raw images have no Mac header: say so, or hdiutil won't recognise them.
    // -noautoopen: never open a Finder window. -nobrowse: keep Finder (and
    // its .DS_Store files) off the volume.
    int status = [self runTool:kHdiutil
                     arguments:@[@"attach", @"-plist", @"-nobrowse", @"-noautoopen",
                                 @"-imagekey", @"diskimage-class=CRawDiskImage", url.path]
                        output:&output errorOutput:&errText];
    NSArray<NSURL *> *mounts = nil;
    NSString *device = [self parseAttachPlist:output mountPoints:&mounts];
    if (status != 0 || mounts.count == 0) {
        if (device) [self runTool:kHdiutil arguments:@[@"detach", device] output:NULL errorOutput:NULL];
        NSString *why = errText.length ? errText : @"No FAT volume was found inside it.";
        if (error) *error = SBError([NSString stringWithFormat:@"Couldn't mount %@. %@", url.lastPathComponent, why]);
        return nil;
    }
    return [[SBMountedImage alloc] initWithImageURL:url device:device mountPoints:mounts];
}

+ (BOOL)ejectImage:(SBMountedImage *)image error:(NSError **)error {
    for (NSURL *mount in image.mountPoints) [self removeMacClutterInVolume:mount];
    sync();
    NSString *errText = nil;
    if ([self runTool:kHdiutil arguments:@[@"detach", image.device] output:NULL errorOutput:&errText] == 0) return YES;
    if ([self runTool:kHdiutil arguments:@[@"detach", @"-force", image.device] output:NULL errorOutput:&errText] == 0) return YES;
    if (error) *error = SBError([NSString stringWithFormat:@"Couldn't eject %@. %@ Close anything using it and try again.",
                                 image.imageURL.lastPathComponent, errText ?: @""]);
    return NO;
}

+ (NSUInteger)removeMacClutterInVolume:(NSURL *)root {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSUInteger removed = 0;
    for (NSString *name in @[@".Trashes", @".fseventsd", @".Spotlight-V100", @".TemporaryItems",
                             @".DocumentRevisions-V100", @".apdisk", @".VolumeIcon.icns"]) {
        NSURL *url = [root URLByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:url.path] && [fm removeItemAtURL:url error:NULL]) removed++;
    }
    // The enumerator doesn't follow symbolic links, so this stays on the volume.
    NSDirectoryEnumerator *e = [fm enumeratorAtURL:root includingPropertiesForKeys:nil options:0 errorHandler:nil];
    NSMutableArray<NSURL *> *junk = [NSMutableArray array];
    for (NSURL *url in e) {
        NSString *name = url.lastPathComponent;
        if ([name isEqualToString:@".DS_Store"] || [name hasPrefix:@"._"]) [junk addObject:url];
    }
    for (NSURL *url in junk) if ([fm removeItemAtURL:url error:NULL]) removed++;
    return removed;
}

@end
