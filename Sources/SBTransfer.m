#import "SBTransfer.h"
#import "SBDisk.h"
#import <AVFoundation/AVFoundation.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

/// 256 MiB of 16-bit audio: far beyond the MPC2000XL's 32 MB sample memory,
/// and a cap on what a file with a lying header can make us allocate.
static const NSUInteger kMaxPCMBytes = 256u * 1024u * 1024u;
/// Deepest folder nesting copied from the Mac.
static const NSInteger kMaxDepth = 32;

static NSError *SBTransferError(NSString *message) {
    return [NSError errorWithDomain:SBErrorDomain code:2 userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation SBTransfer

#pragma mark Names

+ (NSString *)baseName:(NSString *)raw fallback:(NSString *)fallback {
    NSString *folded = [[raw stringByFoldingWithOptions:NSDiacriticInsensitiveSearch locale:nil] uppercaseString];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"];
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < folded.length; i++) {
        unichar c = [folded characterAtIndex:i];
        if ([allowed characterIsMember:c]) {
            [out appendFormat:@"%C", c];
        } else if ((c == ' ' || c == '.') && ![out hasSuffix:@"_"]) {
            [out appendString:@"_"];
        }
    }
    NSString *trimmed = [out stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"_"]];
    if (trimmed.length == 0) trimmed = fallback;
    return trimmed.length > 8 ? [trimmed substringToIndex:8] : trimmed;
}

+ (NSString *)uniqueFileName:(NSString *)rawBase extension:(NSString *)extension taken:(NSMutableSet<NSString *> *)taken {
    NSString *base = [self baseName:rawBase fallback:@"SAMPLE"];
    NSString *ext = [self baseName:extension fallback:@"BIN"];
    if (ext.length > 3) ext = [ext substringToIndex:3];
    NSString *candidate = [NSString stringWithFormat:@"%@.%@", base, ext];
    for (NSUInteger n = 1; [taken containsObject:candidate.uppercaseString]; n++) {
        NSString *suffix = [NSString stringWithFormat:@"%lu", (unsigned long)n];
        NSString *shortBase = base.length + suffix.length > 8 ? [base substringToIndex:8 - suffix.length] : base;
        candidate = [NSString stringWithFormat:@"%@%@.%@", shortBase, suffix, ext];
    }
    [taken addObject:candidate.uppercaseString];
    return candidate;
}

+ (NSString *)uniqueFolderName:(NSString *)raw taken:(NSMutableSet<NSString *> *)taken {
    NSString *base = [self baseName:raw fallback:@"FOLDER"];
    NSString *candidate = base;
    for (NSUInteger n = 1; [taken containsObject:candidate.uppercaseString]; n++) {
        NSString *suffix = [NSString stringWithFormat:@"%lu", (unsigned long)n];
        NSString *shortBase = base.length + suffix.length > 8 ? [base substringToIndex:8 - suffix.length] : base;
        candidate = [shortBase stringByAppendingString:suffix];
    }
    [taken addObject:candidate.uppercaseString];
    return candidate;
}

+ (NSMutableSet<NSString *> *)takenNamesInFolder:(NSURL *)folder {
    NSMutableSet<NSString *> *taken = [NSMutableSet set];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:folder.path error:NULL]) {
        [taken addObject:name.uppercaseString];
    }
    return taken;
}

#pragma mark Audio

+ (BOOL)isConvertibleAudio:(NSURL *)url {
    static NSSet<NSString *> *exts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        exts = [NSSet setWithArray:@[@"wav", @"wave", @"aif", @"aiff", @"aifc", @"caf",
                                     @"mp3", @"m4a", @"aac", @"flac"]];
    });
    return [exts containsObject:url.pathExtension.lowercaseString];
}

+ (NSData *)wavWithPCM:(NSData *)pcm channels:(uint16_t)channels sampleRate:(uint32_t)sampleRate {
    NSMutableData *d = [NSMutableData dataWithCapacity:44 + pcm.length];
    void (^text)(const char *) = ^(const char *s) { [d appendBytes:s length:4]; };
    void (^u32)(uint32_t) = ^(uint32_t v) { uint32_t le = CFSwapInt32HostToLittle(v); [d appendBytes:&le length:4]; };
    void (^u16)(uint16_t) = ^(uint16_t v) { uint16_t le = CFSwapInt16HostToLittle(v); [d appendBytes:&le length:2]; };
    uint16_t blockAlign = channels * 2;
    text("RIFF"); u32((uint32_t)(36 + pcm.length)); text("WAVE");
    text("fmt "); u32(16); u16(1); u16(channels); u32(sampleRate); u32(sampleRate * blockAlign); u16(blockAlign); u16(16);
    text("data"); u32((uint32_t)pcm.length);
    [d appendData:pcm];
    if (pcm.length % 2) [d appendBytes:"\0" length:1];
    return d;
}

+ (NSData *)mpcWAVFromAudioFile:(NSURL *)source error:(NSError **)error {
    NSError *openError = nil;
    AVAudioFile *input = [[AVAudioFile alloc] initForReading:source error:&openError];
    if (!input) {
        if (error) *error = openError ?: SBTransferError(@"This audio file can't be read.");
        return nil;
    }
    AVAudioFormat *inFormat = input.processingFormat;
    double inRate = inFormat.sampleRate;
    if (!(inRate >= 1000 && inRate <= 768000) || inFormat.channelCount == 0) {
        if (error) *error = SBTransferError(@"This audio format can't be converted.");
        return nil;
    }
    const double outRate = 44100;
    AVAudioChannelCount channels = MIN(inFormat.channelCount, (AVAudioChannelCount)2);
    // The header's length is only a hint, but refuse obviously huge files early.
    double expectedBytes = (double)input.length * outRate / inRate * channels * 2;
    if (expectedBytes > kMaxPCMBytes) {
        if (error) *error = SBTransferError(@"This audio is too long for the MPC (it holds at most 32 MB of samples).");
        return nil;
    }

    AVAudioFormat *outFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                                sampleRate:outRate channels:channels interleaved:YES];
    AVAudioConverter *converter = [[AVAudioConverter alloc] initFromFormat:inFormat toFormat:outFormat];
    AVAudioPCMBuffer *inBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:inFormat frameCapacity:8192];
    if (!outFormat || !converter || !inBuffer) {
        if (error) *error = SBTransferError(@"This audio format can't be converted.");
        return nil;
    }
    converter.downmix = inFormat.channelCount > 2;
    converter.sampleRateConverterQuality = AVAudioQualityMax;

    AVAudioFrameCount outCapacity = (AVAudioFrameCount)(8192.0 * outRate / inRate) + 1024;
    NSMutableData *pcm = [NSMutableData data];
    __block BOOL reachedEnd = NO;
    while (YES) {
        AVAudioPCMBuffer *outBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:outFormat frameCapacity:outCapacity];
        if (!outBuffer) break;
        NSError *convertError = nil;
        AVAudioConverterOutputStatus status =
            [converter convertToBuffer:outBuffer error:&convertError
                    withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount count, AVAudioConverterInputStatus *inputStatus) {
            if (reachedEnd) { *inputStatus = AVAudioConverterInputStatus_EndOfStream; return nil; }
            NSError *readError = nil;
            if (![input readIntoBuffer:inBuffer frameCount:inBuffer.frameCapacity error:&readError] || inBuffer.frameLength == 0) {
                reachedEnd = YES;
                *inputStatus = AVAudioConverterInputStatus_EndOfStream;
                return nil;
            }
            *inputStatus = AVAudioConverterInputStatus_HaveData;
            return inBuffer;
        }];
        if (status == AVAudioConverterOutputStatus_Error) {
            if (error) *error = convertError ?: SBTransferError(@"The audio couldn't be converted.");
            return nil;
        }
        if (outBuffer.frameLength > 0 && outBuffer.int16ChannelData) {
            [pcm appendBytes:outBuffer.int16ChannelData[0] length:(NSUInteger)outBuffer.frameLength * channels * 2];
            if (pcm.length > kMaxPCMBytes) {
                if (error) *error = SBTransferError(@"This audio is too long for the MPC (it holds at most 32 MB of samples).");
                return nil;
            }
        }
        if (status == AVAudioConverterOutputStatus_EndOfStream || status == AVAudioConverterOutputStatus_InputRanDry) break;
    }
    if (pcm.length == 0) {
        if (error) *error = SBTransferError(@"The file contains no audio.");
        return nil;
    }
    return [self wavWithPCM:pcm channels:(uint16_t)channels sampleRate:(uint32_t)outRate];
}

#pragma mark Copying

/// Copies only the file's contents (no Mac metadata, so no ._ files on FAT)
/// to a new file. Never overwrites, never follows a link at the destination.
+ (BOOL)copyContentsOf:(NSURL *)source to:(NSURL *)destination error:(NSError **)error {
    int src = open(source.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    if (src < 0) {
        if (error) *error = SBTransferError([NSString stringWithFormat:@"Couldn't read it (%s).", strerror(errno)]);
        return NO;
    }
    int dst = open(destination.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0644);
    if (dst < 0) {
        int e = errno;
        close(src);
        if (error) *error = SBTransferError([NSString stringWithFormat:@"Couldn't write it (%s).", strerror(e)]);
        return NO;
    }
    BOOL ok = YES;
    int failure = 0;
    char *buffer = malloc(1 << 20);
    if (!buffer) { close(src); close(dst); unlink(destination.fileSystemRepresentation); return NO; }
    while (ok) {
        ssize_t n = read(src, buffer, 1 << 20);
        if (n == 0) break;
        if (n < 0) { if (errno == EINTR) continue; ok = NO; failure = errno; break; }
        for (ssize_t done = 0; done < n;) {
            ssize_t w = write(dst, buffer + done, (size_t)(n - done));
            if (w < 0) { if (errno == EINTR) continue; ok = NO; failure = errno; break; }
            done += w;
        }
    }
    free(buffer);
    if (ok && fsync(dst) != 0) { ok = NO; failure = errno; }
    close(src);
    close(dst);
    if (!ok) {
        unlink(destination.fileSystemRepresentation);   // never leave half a file on the card
        if (error) *error = SBTransferError([NSString stringWithFormat:@"Couldn't write it (%s).", strerror(failure)]);
    }
    return ok;
}

+ (BOOL)writeData:(NSData *)data to:(NSURL *)destination error:(NSError **)error {
    int out = open(destination.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0644);
    if (out < 0) {
        if (error) *error = SBTransferError([NSString stringWithFormat:@"Couldn't write it (%s).", strerror(errno)]);
        return NO;
    }
    const char *bytes = data.bytes;
    NSUInteger done = 0;
    int failure = 0;
    while (done < data.length) {
        ssize_t w = write(out, bytes + done, data.length - done);
        if (w < 0) { if (errno == EINTR) continue; failure = errno; break; }
        done += (NSUInteger)w;
    }
    if (failure == 0 && fsync(out) != 0) failure = errno;
    close(out);
    if (failure) {
        unlink(destination.fileSystemRepresentation);
        if (error) *error = SBTransferError([NSString stringWithFormat:@"Couldn't write it (%s).", strerror(failure)]);
        return NO;
    }
    return YES;
}

+ (void)addFile:(NSURL *)url into:(NSURL *)folder taken:(NSMutableSet<NSString *> *)taken
         prefix:(NSString *)prefix results:(NSMutableArray<NSString *> *)results {
    NSString *display = [prefix stringByAppendingString:url.lastPathComponent];
    NSString *base = url.lastPathComponent.stringByDeletingPathExtension;
    NSError *error = nil;

    if ([self isConvertibleAudio:url]) {
        NSData *wav = [self mpcWAVFromAudioFile:url error:&error];
        if (wav) {
            NSString *name = [self uniqueFileName:base extension:@"WAV" taken:taken];
            if ([self writeData:wav to:[folder URLByAppendingPathComponent:name] error:&error]) {
                [results addObject:[NSString stringWithFormat:@"%@ → %@", display, name]];
                return;
            }
            [taken removeObject:name.uppercaseString];
            [results addObject:[NSString stringWithFormat:@"%@: skipped. %@", display, error.localizedDescription]];
            return;
        }
        // Not decodable after all: fall through and copy it unchanged.
    }
    NSString *ext = url.pathExtension.length ? url.pathExtension : @"BIN";
    NSString *name = [self uniqueFileName:base extension:ext taken:taken];
    NSError *copyError = nil;
    if ([self copyContentsOf:url to:[folder URLByAppendingPathComponent:name] error:&copyError]) {
        NSString *note = error ? @" (copied as it is: it couldn't be converted)" : @"";
        [results addObject:[NSString stringWithFormat:@"%@ → %@%@", display, name, note]];
    } else {
        [taken removeObject:name.uppercaseString];
        [results addObject:[NSString stringWithFormat:@"%@: skipped. %@", display, copyError.localizedDescription]];
    }
}

+ (void)addFolderContents:(NSURL *)source into:(NSURL *)destination depth:(NSInteger)depth
                   prefix:(NSString *)prefix results:(NSMutableArray<NSString *> *)results
                 progress:(void (^)(NSString *))progress {
    if (depth > kMaxDepth) {
        [results addObject:[NSString stringWithFormat:@"%@: skipped. Folders are nested too deeply.", prefix]];
        return;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSURL *> *children = [fm contentsOfDirectoryAtURL:source
                                   includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey, NSURLIsRegularFileKey]
                                                      options:NSDirectoryEnumerationSkipsHiddenFiles error:NULL] ?: @[];
    children = [children sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        return [a.lastPathComponent localizedStandardCompare:b.lastPathComponent];
    }];
    NSMutableSet<NSString *> *taken = [self takenNamesInFolder:destination];
    for (NSURL *child in children) {
        [self addItem:child into:destination taken:taken depth:depth prefix:prefix results:results progress:progress];
    }
}

+ (void)addItem:(NSURL *)url into:(NSURL *)folder taken:(NSMutableSet<NSString *> *)taken depth:(NSInteger)depth
         prefix:(NSString *)prefix results:(NSMutableArray<NSString *> *)results progress:(void (^)(NSString *))progress {
    NSString *name = url.lastPathComponent;
    NSString *display = [prefix stringByAppendingString:name];
    if ([name hasPrefix:@"."]) return;   // Mac clutter, never wanted on the MPC
    NSNumber *isLink = nil, *isDir = nil, *isFile = nil;
    [url getResourceValue:&isLink forKey:NSURLIsSymbolicLinkKey error:NULL];
    [url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:NULL];
    [url getResourceValue:&isFile forKey:NSURLIsRegularFileKey error:NULL];
    if (isLink.boolValue) {
        [results addObject:[NSString stringWithFormat:@"%@: skipped (it's an alias or link).", display]];
        return;
    }
    if (isDir.boolValue) {
        NSString *folderName = [self uniqueFolderName:name taken:taken];
        NSURL *made = [folder URLByAppendingPathComponent:folderName isDirectory:YES];
        NSError *error = nil;
        if (![NSFileManager.defaultManager createDirectoryAtURL:made withIntermediateDirectories:NO attributes:nil error:&error]) {
            [taken removeObject:folderName.uppercaseString];
            [results addObject:[NSString stringWithFormat:@"%@: skipped. %@", display, error.localizedDescription]];
            return;
        }
        [results addObject:[NSString stringWithFormat:@"%@/ → %@/", display, folderName]];
        [self addFolderContents:url into:made depth:depth + 1
                         prefix:[display stringByAppendingString:@"/"] results:results progress:progress];
        return;
    }
    if (!isFile.boolValue) {
        [results addObject:[NSString stringWithFormat:@"%@: skipped (not a regular file).", display]];
        return;
    }
    if (progress) progress(display);
    [self addFile:url into:folder taken:taken prefix:prefix results:results];
}

+ (NSArray<NSString *> *)addItems:(NSArray<NSURL *> *)items toFolder:(NSURL *)folder progress:(void (^)(NSString *))progress {
    NSMutableArray<NSString *> *results = [NSMutableArray array];
    NSMutableSet<NSString *> *taken = [self takenNamesInFolder:folder];
    for (NSURL *url in items) {
        @autoreleasepool {
            [self addItem:url into:folder taken:taken depth:0 prefix:@"" results:results progress:progress];
        }
    }
    sync();
    return results;
}

@end
