// SampleBlaster Lite tests. Built and run by Tests/run-tests.sh on a Mac:
// naming, WAV conversion, and a real mount → add files → eject cycle on a
// FAT16 image with an MBR, like ZuluSCSI images made by the MPC.

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
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

static uint32_t le32(NSData *d, NSUInteger o) { uint32_t v; [d getBytes:&v range:NSMakeRange(o, 4)]; return CFSwapInt32LittleToHost(v); }
static uint16_t le16(NSData *d, NSUInteger o) { uint16_t v; [d getBytes:&v range:NSMakeRange(o, 2)]; return CFSwapInt16LittleToHost(v); }

/// A short stereo 48 kHz float AIFF tone.
static NSURL *makeAIFF(NSURL *dir, NSString *name, double seconds) {
    NSURL *url = [dir URLByAppendingPathComponent:name];
    NSDictionary *settings = @{AVFormatIDKey: @(kAudioFormatLinearPCM), AVSampleRateKey: @48000, AVNumberOfChannelsKey: @2,
                               AVLinearPCMBitDepthKey: @24, AVLinearPCMIsFloatKey: @NO, AVLinearPCMIsBigEndianKey: @YES};
    NSError *error = nil;
    AVAudioFile *file = [[AVAudioFile alloc] initForWriting:url settings:settings error:&error];
    if (!file) { fprintf(stderr, "couldn't make AIFF: %s\n", error.localizedDescription.UTF8String); return nil; }
    AVAudioFrameCount frames = (AVAudioFrameCount)(48000 * seconds);
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat frameCapacity:frames];
    buffer.frameLength = frames;
    for (AVAudioChannelCount c = 0; c < 2; c++)
        for (AVAudioFrameCount i = 0; i < frames; i++) buffer.floatChannelData[c][i] = (float)(0.5 * sin(2 * M_PI * 440 * i / 48000.0));
    [file writeFromBuffer:buffer error:&error];
    return url;
}

static void testNames(void) {
    CHECK([[SBTransfer baseName:@"Kick Drum 01" fallback:@"X"] isEqualToString:@"KICK_DRU"], @"%@", [SBTransfer baseName:@"Kick Drum 01" fallback:@"X"]);
    CHECK([[SBTransfer baseName:@"café/../x" fallback:@"X"] isEqualToString:@"CAFE_X"], @"%@", [SBTransfer baseName:@"café/../x" fallback:@"X"]);
    CHECK([[SBTransfer baseName:@"..." fallback:@"SAMPLE"] isEqualToString:@"SAMPLE"], @"dots only");
    CHECK([[SBTransfer baseName:@"" fallback:@"SAMPLE"] isEqualToString:@"SAMPLE"], @"empty");

    NSMutableSet *taken = [NSMutableSet setWithArray:@[@"KICK.WAV"]];
    NSString *a = [SBTransfer uniqueFileName:@"kick" extension:@"wav" taken:taken];
    NSString *b = [SBTransfer uniqueFileName:@"KICK" extension:@"WAV" taken:taken];
    CHECK([a isEqualToString:@"KICK1.WAV"], @"%@", a);
    CHECK([b isEqualToString:@"KICK2.WAV"], @"%@", b);
    NSString *longBase = [SBTransfer uniqueFileName:@"ABCDEFGHIJ" extension:@"pgm" taken:taken];
    NSString *longBase2 = [SBTransfer uniqueFileName:@"ABCDEFGHIJ" extension:@"pgm" taken:taken];
    CHECK([longBase isEqualToString:@"ABCDEFGH.PGM"] && [longBase2 isEqualToString:@"ABCDEFG1.PGM"], @"%@ %@", longBase, longBase2);
    CHECK([[SBTransfer uniqueFileName:@"x" extension:@"aiff" taken:taken] isEqualToString:@"X.AIF"], @"extension cut to 3");
    NSMutableSet *folders = [NSMutableSet setWithArray:@[@"DRUMS"]];
    CHECK([[SBTransfer uniqueFolderName:@"Drums" taken:folders] isEqualToString:@"DRUMS1"], @"folder uniquing");

    NSData *wav = [SBTransfer wavWithPCM:[NSMutableData dataWithLength:6] channels:1 sampleRate:44100];
    CHECK(wav.length == 50 && le32(wav, 4) == 42 && le32(wav, 40) == 6, @"minimal WAV header");
}

static void testConversion(void) {
    NSURL *dir = tempDir();
    NSURL *aiff = makeAIFF(dir, @"tone.aiff", 0.5);
    NSError *error = nil;
    NSData *wav = [SBTransfer mpcWAVFromAudioFile:aiff error:&error];
    CHECK(wav != nil, @"conversion failed: %@", error);
    if (wav) {
        CHECK(le16(wav, 20) == 1 && le16(wav, 22) == 2 && le32(wav, 24) == 44100 && le16(wav, 34) == 16,
              @"format %u ch %u rate %u bits %u", le16(wav, 20), le16(wav, 22), le32(wav, 24), le16(wav, 34));
        uint32_t frames = le32(wav, 40) / 4;
        CHECK(frames > 22000 && frames < 22200, @"0.5 s at 44.1 kHz, got %u frames", frames);
    }
    NSURL *junk = [dir URLByAppendingPathComponent:@"notaudio.wav"];
    [[@"definitely not audio" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:junk atomically:YES];
    CHECK([SBTransfer mpcWAVFromAudioFile:junk error:&error] == nil, @"junk shouldn't convert");
    [NSFileManager.defaultManager removeItemAtURL:dir error:NULL];
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
    NSURL *tone = makeAIFF(source, @"Long Tone Name.aiff", 0.2);
    NSData *pgm = [NSMutableData dataWithLength:2000];
    [pgm writeToURL:[source URLByAppendingPathComponent:@"cym1.pgm"] atomically:YES];
    [pgm writeToURL:[inner URLByAppendingPathComponent:@"snare.snd"] atomically:YES];
    makeAIFF(kit, @"kick.aif", 0.1);
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

    NSArray *results = [SBTransfer addItems:@[tone, [source URLByAppendingPathComponent:@"cym1.pgm"], kit] toFolder:root progress:nil];
    NSArray *again = [SBTransfer addItems:@[[source URLByAppendingPathComponent:@"cym1.pgm"]] toFolder:root progress:nil];
    printf("  %s\n", [[results arrayByAddingObjectsFromArray:again] componentsJoinedByString:@"\n  "].UTF8String);

    // Clutter macOS might leave, which eject must remove.
    [@"x" writeToURL:[root URLByAppendingPathComponent:@"._CYM1.PGM"] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    [fm createDirectoryAtURL:[root URLByAppendingPathComponent:@".Trashes"] withIntermediateDirectories:NO attributes:nil error:NULL];

    NSSet *top = [NSSet setWithArray:[fm contentsOfDirectoryAtPath:root.path error:NULL]];
    for (NSString *expected in @[@"LONG_TON.WAV", @"CYM1.PGM", @"CYM11.PGM", @"MY_KIT"]) {
        CHECK([top containsObject:expected], @"%@ missing from %@", expected, top);
    }
    NSSet *kitFiles = [NSSet setWithArray:[fm contentsOfDirectoryAtPath:[root URLByAppendingPathComponent:@"MY_KIT"].path error:NULL]];
    NSSet *wantKit = [NSSet setWithArray:@[@"KICK.WAV", @"SNARES_A"]];
    CHECK([kitFiles isEqualToSet:wantKit], @"MY_KIT holds %@", kitFiles);
    NSData *copied = [NSData dataWithContentsOfURL:[root URLByAppendingPathComponent:@"MY_KIT/SNARES_A/SNARE.SND"]];
    CHECK([copied isEqualToData:pgm], @"SNARE.SND copied byte for byte");
    CHECK([[NSData dataWithContentsOfURL:[root URLByAppendingPathComponent:@"CYM1.PGM"]] isEqualToData:pgm], @"CYM1.PGM byte for byte");
    NSUInteger skipped = 0;
    for (NSString *line in results) if ([line containsString:@"skipped"]) skipped++;
    CHECK(skipped == 1, @"only the link is skipped: %@", results);

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
        CHECK([fm fileExistsAtPath:[mounts[0] URLByAppendingPathComponent:@"MY_KIT/KICK.WAV"].path], @"files survive eject");
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
        testNames();
        testParsePlist();
        testConversion();
        testMountAddEject();
        printf("%d checks, %d failed\n", checks, failures);
    }
    return failures ? 1 : 0;
}
