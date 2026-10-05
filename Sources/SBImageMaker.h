// SampleBlaster Lite: creating blank SCSI hard disk images.
//
// Plain C (kept in a .m file so it builds with the rest of the app), so it
// runs on macOS 10.13 High Sierra and can be tested anywhere. The layout is the same as MPC Blaster's new images: a PC master
// boot record and one FAT16 partition starting at sector 63, which is what
// SCSI Blaster, ZuluSCSI, BlueSCSI and SCSI2SD images hold and what MPCs and
// most samplers that read PC disks expect. Sizes run from 100 MB to 1 GB,
// which always fits in a single FAT16 partition.
//
// Everything is written directly (no hdiutil or newfs), so the result doesn't
// depend on which FAT tools the Mac has.

#ifndef SBImageMaker_h
#define SBImageMaker_h

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Sizes offered in the New Disk Image menu, in MB (1 GB = 1024 MB).
extern const int64_t SBImageSizesMB[];
extern const int SBImageSizeCount;

#define SB_IMAGE_MIN_MB 100
#define SB_IMAGE_MAX_MB 1024

/// The FAT16 partition an image of a given size gets.
typedef struct {
    int64_t totalSectors;       // whole image, 512-byte sectors
    int64_t startLBA;           // first sector of the partition (63)
    int64_t sectors;            // partition length
    int sectorsPerCluster;
    int fatSectors;             // sectors per FAT (two copies)
    int clusterCount;
} SBImageLayout;

/// Works out the layout for `totalMB`. Returns 0, or -1 if the size is
/// outside 100 MB–1 GB.
int SBImageLayoutForMB(int64_t totalMB, SBImageLayout *layout);

/// Turns a name into a FAT volume label: up to 11 characters, uppercase,
/// anything DOS doesn't allow becomes "_". Empty gives "SCSI". `out` must
/// hold 12 bytes.
void SBImageVolumeLabel(const char *name, char out[12]);

/// Writes a new, blank image of `totalMB` to `path`, which must not exist yet.
/// Returns 0, or an errno value (the partly written file is removed).
int SBImageCreate(const char *path, int64_t totalMB, const char *volumeName);

#ifdef __cplusplus
}
#endif

#endif
