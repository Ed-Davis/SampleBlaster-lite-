#include "SBImageMaker.h"

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#ifndef __APPLE__
#include <time.h>
#endif

const int64_t SBImageSizesMB[] = {100, 250, 500, 750, 1024};
const int SBImageSizeCount = (int)(sizeof(SBImageSizesMB) / sizeof(SBImageSizesMB[0]));

enum {
    kSectorSize = 512,
    kFirstLBA = 63,            // the classic PC layout older firmware expects
    kRootEntries = 512,
    kRootDirSectors = kRootEntries * 32 / kSectorSize,
    kMaxFAT16Clusters = 65524,
};
static const int64_t kMegabyte = 1048576;

/// Microsoft's standard FAT16 cluster size for a partition of this size.
static int standardSectorsPerCluster(int64_t sectors) {
    int64_t mb = sectors * kSectorSize / kMegabyte;
    if (mb < 128) return 4;     // 2 KB
    if (mb < 256) return 8;     // 4 KB
    if (mb < 512) return 16;    // 8 KB
    if (mb < 1024) return 32;   // 16 KB
    return 64;                  // 32 KB
}

/// Sectors per FAT, using the formula from Microsoft's FAT specification.
static int fatSectorsFor(int64_t sectors, int spc) {
    int64_t tmp1 = sectors - (1 + kRootDirSectors);   // 1 reserved sector
    int64_t tmp2 = 256 * (int64_t)spc + 2;
    return (int)((tmp1 + tmp2 - 1) / tmp2);
}

static int clustersFor(int64_t sectors, int spc, int fatSectors) {
    return (int)((sectors - 1 - 2 * (int64_t)fatSectors - kRootDirSectors) / spc);
}

int SBImageLayoutForMB(int64_t totalMB, SBImageLayout *layout) {
    if (totalMB < SB_IMAGE_MIN_MB || totalMB > SB_IMAGE_MAX_MB || !layout) return -1;
    SBImageLayout l;
    l.totalSectors = totalMB * kMegabyte / kSectorSize;
    l.startLBA = kFirstLBA;
    l.sectors = l.totalSectors - kFirstLBA;
    l.sectorsPerCluster = standardSectorsPerCluster(l.sectors);
    l.fatSectors = fatSectorsFor(l.sectors, l.sectorsPerCluster);
    l.clusterCount = clustersFor(l.sectors, l.sectorsPerCluster, l.fatSectors);
    // Just under a size boundary (a 1 GB image, say) the standard cluster
    // size gives more clusters than FAT16 allows, so go up a step.
    while (l.clusterCount > kMaxFAT16Clusters && l.sectorsPerCluster < 64) {
        l.sectorsPerCluster *= 2;
        l.fatSectors = fatSectorsFor(l.sectors, l.sectorsPerCluster);
        l.clusterCount = clustersFor(l.sectors, l.sectorsPerCluster, l.fatSectors);
    }
    *layout = l;
    return 0;
}

void SBImageVolumeLabel(const char *name, char out[12]) {
    int n = 0;
    for (const char *p = name ? name : ""; *p && n < 11; p++) {
        char c = (char)toupper((unsigned char)*p);
        out[n++] = (isupper((unsigned char)c) || isdigit((unsigned char)c) || c == '_' || c == '-') ? c : '_';
    }
    if (n == 0) { strcpy(out, "SCSI"); return; }
    out[n] = 0;
}

static void le16(uint8_t *p, uint32_t v) { p[0] = v & 0xFF; p[1] = (v >> 8) & 0xFF; }
static void le32(uint8_t *p, uint32_t v) { for (int i = 0; i < 4; i++) p[i] = (v >> (8 * i)) & 0xFF; }

/// Cylinder/head/sector address for an MBR entry (255 heads, 63 sectors),
/// capped at the CHS maximum as DOS does.
static void chs(uint8_t *p, int64_t lba) {
    int64_t c = lba / (255 * 63), h = (lba / 63) % 255, s = lba % 63 + 1;
    if (c > 1023) { c = 1023; h = 254; s = 63; }
    p[0] = (uint8_t)h;
    p[1] = (uint8_t)(s | ((c >> 2) & 0xC0));
    p[2] = (uint8_t)(c & 0xFF);
}

static void paddedLabel(uint8_t *p, const char *label) {
    memset(p, ' ', 11);
    memcpy(p, label, strlen(label) < 11 ? strlen(label) : 11);
}

static uint32_t volumeSerial(void) {
#ifdef __APPLE__
    return arc4random() | 1;
#else
    srand((unsigned)time(NULL) ^ (unsigned)getpid());
    return ((uint32_t)rand() << 16 ^ (uint32_t)rand()) | 1;
#endif
}

static int writeAt(int fd, const void *bytes, size_t length, int64_t sector) {
    ssize_t n = pwrite(fd, bytes, length, (off_t)(sector * kSectorSize));
    return n == (ssize_t)length ? 0 : (errno ? errno : EIO);
}

int SBImageCreate(const char *path, int64_t totalMB, const char *volumeName) {
    SBImageLayout l;
    if (SBImageLayoutForMB(totalMB, &l) != 0) return EINVAL;
    char label[12];
    SBImageVolumeLabel(volumeName, label);

    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (fd < 0) return errno;

    uint8_t mbr[kSectorSize] = {0}, boot[kSectorSize] = {0}, root[32] = {0};
    const uint8_t fatStart[4] = {0xF8, 0xFF, 0xFF, 0xFF};   // media byte + end-of-chain

    // Master boot record: one FAT16 partition (type 06), not bootable.
    uint8_t *e = mbr + 446;
    chs(e + 1, l.startLBA);
    e[4] = 0x06;
    chs(e + 5, l.startLBA + l.sectors - 1);
    le32(e + 8, (uint32_t)l.startLBA);
    le32(e + 12, (uint32_t)l.sectors);
    mbr[510] = 0x55; mbr[511] = 0xAA;

    // FAT16 boot sector.
    boot[0] = 0xEB; boot[1] = 0x3C; boot[2] = 0x90;
    memcpy(boot + 3, "MSDOS5.0", 8);
    le16(boot + 11, kSectorSize);
    boot[13] = (uint8_t)l.sectorsPerCluster;
    le16(boot + 14, 1);                                   // reserved sectors
    boot[16] = 2;                                         // FAT copies
    le16(boot + 17, kRootEntries);
    if (l.sectors < 65536) le16(boot + 19, (uint32_t)l.sectors);
    boot[21] = 0xF8;                                      // fixed disk
    le16(boot + 22, (uint32_t)l.fatSectors);
    le16(boot + 24, 63);                                  // sectors per track
    le16(boot + 26, 255);                                 // heads
    le32(boot + 28, (uint32_t)l.startLBA);                // hidden sectors
    if (l.sectors >= 65536) le32(boot + 32, (uint32_t)l.sectors);
    boot[36] = 0x80;                                      // drive number
    boot[38] = 0x29;                                      // extended boot signature
    le32(boot + 39, volumeSerial());
    paddedLabel(boot + 43, label);
    memcpy(boot + 54, "FAT16   ", 8);
    boot[510] = 0x55; boot[511] = 0xAA;

    // Root directory: just the volume label.
    paddedLabel(root, label);
    root[11] = 0x08;

    int err = 0;
    // Set the full size first. Unwritten space reads as zeros (and on APFS
    // costs nothing until used), which is what an empty FAT needs.
    if (ftruncate(fd, (off_t)(l.totalSectors * kSectorSize)) != 0) err = errno;
    int64_t fat1 = l.startLBA + 1, fat2 = fat1 + l.fatSectors, rootDir = fat2 + l.fatSectors;
    if (!err) err = writeAt(fd, mbr, sizeof mbr, 0);
    if (!err) err = writeAt(fd, boot, sizeof boot, l.startLBA);
    if (!err) err = writeAt(fd, fatStart, sizeof fatStart, fat1);
    if (!err) err = writeAt(fd, fatStart, sizeof fatStart, fat2);
    if (!err) err = writeAt(fd, root, sizeof root, rootDir);
    if (!err && fsync(fd) != 0) err = errno;
    if (close(fd) != 0 && !err) err = errno;
    if (err) unlink(path);
    return err;
}
