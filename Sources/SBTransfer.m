#import "SBTransfer.h"
#import "SBDisk.h"
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

/// Deepest folder nesting copied from the Mac.
static const NSInteger kMaxDepth = 32;

static NSError *SBTransferError(NSString *message) {
    return [NSError errorWithDomain:SBErrorDomain code:2 userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation SBTransfer

#pragma mark Copying

/// Copies only the file's contents (no Mac metadata, so no ._ files on FAT)
/// to a new file. Never replaces an existing file, never follows a link.
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

+ (void)addFile:(NSURL *)url into:(NSURL *)folder prefix:(NSString *)prefix results:(NSMutableArray<NSString *> *)results {
    NSString *display = [prefix stringByAppendingString:url.lastPathComponent];
    NSURL *destination = [folder URLByAppendingPathComponent:url.lastPathComponent];
    if ([NSFileManager.defaultManager fileExistsAtPath:destination.path]) {
        [results addObject:[NSString stringWithFormat:@"%@: skipped. A file with that name is already there.", display]];
        return;
    }
    NSError *error = nil;
    if ([self copyContentsOf:url to:destination error:&error]) {
        [results addObject:[NSString stringWithFormat:@"%@: copied", display]];
    } else {
        [results addObject:[NSString stringWithFormat:@"%@: skipped. %@", display, error.localizedDescription]];
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
    for (NSURL *child in children) {
        [self addItem:child into:destination depth:depth prefix:prefix results:results progress:progress];
    }
}

+ (void)addItem:(NSURL *)url into:(NSURL *)folder depth:(NSInteger)depth
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
        NSURL *made = [folder URLByAppendingPathComponent:name isDirectory:YES];
        BOOL existingIsDir = NO;
        if ([NSFileManager.defaultManager fileExistsAtPath:made.path isDirectory:&existingIsDir]) {
            if (!existingIsDir) {
                [results addObject:[NSString stringWithFormat:@"%@/: skipped. A file with that name is already there.", display]];
                return;
            }
            [results addObject:[NSString stringWithFormat:@"%@/: adding to the folder already there", display]];
        } else {
            NSError *error = nil;
            if (![NSFileManager.defaultManager createDirectoryAtURL:made withIntermediateDirectories:NO attributes:nil error:&error]) {
                [results addObject:[NSString stringWithFormat:@"%@/: skipped. %@", display, error.localizedDescription]];
                return;
            }
            [results addObject:[NSString stringWithFormat:@"%@/: copied", display]];
        }
        [self addFolderContents:url into:made depth:depth + 1
                         prefix:[display stringByAppendingString:@"/"] results:results progress:progress];
        return;
    }
    if (!isFile.boolValue) {
        [results addObject:[NSString stringWithFormat:@"%@: skipped (not a regular file).", display]];
        return;
    }
    if (progress) progress(display);
    [self addFile:url into:folder prefix:prefix results:results];
}

+ (NSArray<NSString *> *)addItems:(NSArray<NSURL *> *)items toFolder:(NSURL *)folder progress:(void (^)(NSString *))progress {
    NSMutableArray<NSString *> *results = [NSMutableArray array];
    for (NSURL *url in items) {
        @autoreleasepool {
            [self addItem:url into:folder depth:0 prefix:@"" results:results progress:progress];
        }
    }
    sync();
    return results;
}

@end
