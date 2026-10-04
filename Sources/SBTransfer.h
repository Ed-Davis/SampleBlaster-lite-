// SampleBlaster Lite: adding files to a mounted MPC disk image.
//
// Every name written is a DOS 8.3 uppercase name the MPC2000XL can show.
// Audio macOS can read is converted to a plain 16-bit / 44.1 kHz WAV (mono
// or stereo); everything else (.SND, .PGM, .APS, .ALL…) is copied byte for
// byte. Only file contents are written, never Mac metadata, so no ._ files
// appear on the card.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SBTransfer : NSObject

/// Up to 8 characters of A–Z, 0–9, "_" and "-"; spaces and dots become "_".
+ (NSString *)baseName:(NSString *)raw fallback:(NSString *)fallback;

/// "NAME.EXT", made unique (case-insensitively) against `taken`, which it
/// then joins. The extension is uppercased and cut to 3 characters.
+ (NSString *)uniqueFileName:(NSString *)rawBase extension:(NSString *)extension taken:(NSMutableSet<NSString *> *)taken;

/// Same rules for a folder (no extension).
+ (NSString *)uniqueFolderName:(NSString *)raw taken:(NSMutableSet<NSString *> *)taken;

/// Uppercased names already in `folder`.
+ (NSMutableSet<NSString *> *)takenNamesInFolder:(NSURL *)folder;

/// Extensions converted to WAV. Anything else is copied unchanged.
+ (BOOL)isConvertibleAudio:(NSURL *)url;

/// The file converted to a 16-bit / 44.1 kHz WAV with a minimal header.
+ (nullable NSData *)mpcWAVFromAudioFile:(NSURL *)source error:(NSError **)error;

/// A minimal RIFF/WAVE file around 16-bit little-endian PCM.
+ (NSData *)wavWithPCM:(NSData *)pcm channels:(uint16_t)channels sampleRate:(uint32_t)sampleRate;

/// Adds files and folders to `folder` (folders keep their structure).
/// Hidden files and symbolic links are skipped. `progress` is called with
/// each source file's name before it's added. Returns one line per item:
/// what it became, or why it was skipped.
+ (NSArray<NSString *> *)addItems:(NSArray<NSURL *> *)items
                         toFolder:(NSURL *)folder
                         progress:(nullable void (^)(NSString *name))progress;

@end

NS_ASSUME_NONNULL_END
