// SampleBlaster Lite tests. Built and run by Tests/run-tests.sh on a Mac:
// a real mount → add files → eject cycle on a FAT16 image with an MBR, like
// ZuluSCSI images. Files and folders must arrive exactly as they are, names
// included, and nothing already on the image may be replaced.

#import <Foundation/Foundation.h>
#import "../Sources/SBDisk.h"
#import "../Sources/SBTransfer.h"

static int failures = 0;
static int checks = 0;

#define CHECK(cond, ...) do { checks++; if (!(cond)) { failures++; \
    fprintf(stderr, "✗ %s:%d: %s — %s\n", __FILE__, __LINE__, #cond, [[NSString stringWithFormat:__VA_ARGS__] UTF8String]); } } while (0)

static NSURL *tempDir(void) {
    NSURL *url = [NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:url withIntermediateDirectories:YES attributes:nil error:NULL];
    return url;
}


/// A file of recognisable bytes (a stand-in for a sample: contents are never inspected).
static NSURL *makeFile(NSURL *dir, NSString *name, NSUInteger length, uint8_t seed) {
    NSMutableData *data = [NSMutableData dataWithLength:length];
    uint8_t *bytes = data.mutableBytes;
    for (NSUInteger i = 0; i < length; i++) bytes[i] = (uint8_t)(i * 31 + seed);
    NSURL *url = [dir URLByAppendingPathComponent:name];
    [data writeToURL:url atomically:YES];
    return url;
}

/// A 64 MB raw image with an MBR and one FAT16 partition, as ZuluSCSI uses.
static NSURL *makeImage(NSURL *dir) {
    NSString *base = [dir URLByAppendingPathComponent:@"HD0"].path;
    NSString *errText = nil;
    int status = [SBDisk runTool:@"/usr/bin/hdiutil"
                       arguments:@[@"create", @"-size", @"64m", @"-layout", @"MBRSPUD", @"-fs", @"MS-DOS FAT16",
                                   @"-volname", @"MPCTEST", @"-type", @"UDIF", base]
                          output:NULL errorOutput:&errText];
    CHECK(status == 0, @"hdiutil create: %@", errText);
    // Convert to a raw image (.cdr), which is what an SD card's HD0.img is.
    status = [SBDisk runTool:@"/usr/bin/hdiutil"
                   arguments:@[@"convert", [base stringByAppendingString:@".dmg"], @"-format", @"UDTO", @"-o", base]
                      output:NULL errorOutput:&errText];
    CHECK(status == 0, @"hdiutil convert: %@", errText);
    NSURL *img = [dir URLByAppendingPathComponent:@"HD0.img"];
    [NSFileManager.defaultManager moveItemAtURL:[NSURL fileURLWithPath:[base stringByAppendingString:@".cdr"]] toURL:img error:NULL];
    return img;
}

static void testMountAddEject(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *dir = tempDir();
    NSURL *img = makeImage(dir);

    // Things to add: audio, an MPC program, a folder with a subfolder, plus
    // things that must not reach the card (hidden file, symlink).
    NSURL *source = [dir URLByAppendingPathComponent:@"source" isDirectory:YES];
    NSURL *kit = [source URLByAppendingPathComponent:@"My Kit" isDirectory:YES];
    NSURL *inner = [kit URLByAppendingPathComponent:@"Snares and stuff" isDirectory:YES];
    [fm createDirectoryAtURL:inner withIntermediateDirectories:YES attributes:nil error:NULL];
    NSURL *tone = makeFile(source, @"Long Tone Name.aiff", 300000, 1);   // 24-bit 48 kHz, say: must stay that way
    NSURL *wav = makeFile(source, @"Snare 96k.wav", 5000, 2);
    NSData *pgm = [NSMutableData dataWithLength:2000];
    [pgm writeToURL:[source URLByAppendingPathComponent:@"cym1.pgm"] atomically:YES];
    [pgm writeToURL:[inner URLByAppendingPathComponent:@"snare.snd"] atomically:YES];
    NSURL *kick = makeFile(kit, @"kick.aif", 4000, 3);
    [@"x" writeToURL:[kit URLByAppendingPathComponent:@".DS_Store"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [fm createSymbolicLinkAtURL:[kit URLByAppendingPathComponent:@"home link"] withDestinationURL:fm.homeDirectoryForCurrentUser error:NULL];
    // A quarantine-style attribute that would become a ._ file if copied.
    [SBDisk runTool:@"/usr/bin/xattr" arguments:@[@"-w", @"com.example.test", @"1", [source URLByAppendingPathComponent:@"cym1.pgm"].path] output:NULL errorOutput:NULL];

    NSError *error = nil;
    SBMountedImage *mounted = [SBDisk attachImageAtURL:img error:&error];
    CHECK(mounted != nil, @"mount failed: %@", error);
    if (!mounted) return;
    CHECK(mounted.mountPoints.count == 1, @"%lu partitions", (unsigned long)mounted.mountPoints.count);
    CHECK([mounted.device hasPrefix:@"/dev/disk"], @"device %@", mounted.device);
    NSURL *root = mounted.mountPoints.firstObject;

    NSArray *results = [SBTransfer addItems:@[tone, wav, [source URLByAppendingPathComponent:@"cym1.pgm"], kit] toFolder:root progress:nil];
    printf("  %s\n", [results componentsJoinedByString:@"\n  "].UTF8String);
    NSUInteger skipped = 0;
    for (NSString *line in results) if ([line containsString:@"skipped"]) skipped++;
    CHECK(skipped == 1, @"only the link is skipped: %@", results);

    // Names are kept exactly, case and spaces included.
    NSSet *top = [NSSet setWithArray:[fm contentsOfDirectoryAtPath:root.path error:NULL]];
    for (NSString *expected in @[@"Long Tone Name.aiff", @"Snare 96k.wav", @"cym1.pgm", @"My Kit"]) {
        CHECK([top containsObject:expected], @"%@ missing from %@", expected, top);
    }
    NSSet *kitFiles = [NSSet setWithArray:[fm contentsOfDirectoryAtPath:[root URLByAppendingPathComponent:@"My Kit"].path error:NULL]];
    NSSet *wantKit = [NSSet setWithArray:@[@"kick.aif", @"Snares and stuff"]];
    CHECK([kitFiles isEqualToSet:wantKit], @"My Kit holds %@", kitFiles);
    // Contents arrive byte for byte: no conversion.
    CHECK([[NSData dataWithContentsOfURL:[root URLByAppendingPathComponent:@"My Kit/Snares and stuff/snare.snd"]] isEqualToData:pgm], @"snare.snd unchanged");
    CHECK([[NSData dataWithContentsOfURL:[root URLByAppendingPathComponent:@"cym1.pgm"]] isEqualToData:pgm], @"cym1.pgm unchanged");
    CHECK([[NSData dataWithContentsOfURL:[root URLByAppendingPathComponent:@"Long Tone Name.aiff"]] isEqualToData:[NSData dataWithContentsOfURL:tone]], @"AIFF unchanged");
    CHECK([[NSData dataWithContentsOfURL:[root URLByAppendingPathComponent:@"Snare 96k.wav"]] isEqualToData:[NSData dataWithContentsOfURL:wav]], @"WAV unchanged");
    CHECK([[NSData dataWithContentsOfURL:[root URLByAppendingPathComponent:@"My Kit/kick.aif"]] isEqualToData:[NSData dataWithContentsOfURL:kick]], @"nested file unchanged");

    // Adding again: existing files are never replaced (even with different
    // contents), existing folders are added to, new files go in.
    NSURL *other = [dir URLByAppendingPathComponent:@"other" isDirectory:YES];
    NSURL *otherKit = [other URLByAppendingPathComponent:@"My Kit" isDirectory:YES];
    [fm createDirectoryAtURL:otherKit withIntermediateDirectories:YES attributes:nil error:NULL];
    makeFile(other, @"cym1.pgm", 10, 9);
    makeFile(otherKit, @"kick.aif", 10, 9);
    NSURL *hat = makeFile(otherKit, @"hat.wav", 700, 4);
    NSArray *again = [SBTransfer addItems:@[[other URLByAppendingPathComponent:@"cym1.pgm"], otherKit] toFolder:root progress:nil];
    printf("  %s\n", [again componentsJoinedByString:@"\n  "].UTF8String);
    NSUInteger skippedAgain = 0;
    for (NSString *line in again) if ([line containsString:@"skipped"]) skippedAgain++;
    CHECK(skippedAgain == 2, @"both clashing files skipped: %@", again);
    CHECK([[NSData dataWithContentsOfURL:[root URLByAppendingPathComponent:@"cym1.pgm"]] isEqualToData:pgm], @"existing file not replaced");
    CHECK([[NSData dataWithContentsOfURL:[root URLByAppendingPathComponent:@"My Kit/kick.aif"]] isEqualToData:[NSData dataWithContentsOfURL:kick]], @"existing nested file not replaced");
    CHECK([[NSData dataWithContentsOfURL:[root URLByAppendingPathComponent:@"My Kit/hat.wav"]] isEqualToData:[NSData dataWithContentsOfURL:hat]], @"new file added to existing folder");

    // Clutter macOS might leave, which eject must remove.
    [@"x" writeToURL:[root URLByAppendingPathComponent:@"._cym1.pgm"] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    [fm createDirectoryAtURL:[root URLByAppendingPathComponent:@".Trashes"] withIntermediateDirectories:NO attributes:nil error:NULL];

    BOOL ejected = [SBDisk ejectImage:mounted error:&error];
    CHECK(ejected, @"eject failed: %@", error);

    // Mount again read-only: everything is there and there's no clutter.
    NSData *plist = nil;
    [SBDisk runTool:@"/usr/bin/hdiutil" arguments:@[@"attach", @"-readonly", @"-nobrowse", @"-plist", @"-imagekey",
                                                    @"diskimage-class=CRawDiskImage", img.path] output:&plist errorOutput:NULL];
    NSArray<NSURL *> *mounts = nil;
    NSString *device = [SBDisk parseAttachPlist:plist mountPoints:&mounts];
    CHECK(mounts.count == 1, @"remount");
    if (mounts.count) {
        NSDirectoryEnumerator *e = [fm enumeratorAtURL:mounts[0] includingPropertiesForKeys:nil options:0 errorHandler:nil];
        NSMutableArray *dotFiles = [NSMutableArray array];
        for (NSURL *url in e) if ([url.lastPathComponent hasPrefix:@"."]) [dotFiles addObject:url.lastPathComponent];
        CHECK(dotFiles.count == 0, @"no Mac clutter on the card, found %@", dotFiles);
        CHECK([fm fileExistsAtPath:[mounts[0] URLByAppendingPathComponent:@"My Kit/hat.wav"].path], @"files survive eject");
    }
    if (device) [SBDisk runTool:@"/usr/bin/hdiutil" arguments:@[@"detach", @"-force", device] output:NULL errorOutput:NULL];

    // Not a disk image: refused with a message, nothing left attached.
    NSURL *bogus = [dir URLByAppendingPathComponent:@"bogus.img"];
    [[NSMutableData dataWithLength:1 << 20] writeToURL:bogus atomically:YES];
    CHECK([SBDisk attachImageAtURL:bogus error:&error] == nil && error.localizedDescription.length, @"blank file refused");
    [fm removeItemAtURL:dir error:NULL];
}

static void testParsePlist(void) {
    NSDictionary *plist = @{@"system-entities": @[
        @{@"dev-entry": @"/dev/disk7", @"content-hint": @"FDisk_partition_scheme"},
        @{@"dev-entry": @"/dev/disk7s10", @"mount-point": @"/Volumes/B"},
        @{@"dev-entry": @"/dev/disk7s2", @"mount-point": @"/Volumes/A"}]};
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
    NSArray<NSURL *> *mounts = nil;
    NSString *device = [SBDisk parseAttachPlist:data mountPoints:&mounts];
    CHECK([device isEqualToString:@"/dev/disk7"], @"%@", device);
    CHECK(mounts.count == 2 && [mounts[0].path isEqualToString:@"/Volumes/A"], @"numeric partition order: %@", mounts);
    CHECK([SBDisk parseAttachPlist:[NSData data] mountPoints:&mounts] == nil && mounts.count == 0, @"empty output");
}

int main(void) {
    @autoreleasepool {
        testParsePlist();
        testMountAddEject();
        printf("%d checks, %d failed\n", checks, failures);
    }
    return failures ? 1 : 0;
}
