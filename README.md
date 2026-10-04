# SampleBlaster Lite

A simple Mac utility for ZuluSCSI disk images, by Ed Davis. It runs on **macOS 10.13 High Sierra** and later, on Intel and Apple silicon Macs.

It does two things:

1. **Mounts** a ZuluSCSI / BlueSCSI hard disk image (`HD0.img`, `.hda`), straight from the SD card.
2. **Adds files** to it: drag files and folders onto the window, or click **Add Files…**.
   - Audio the Mac can read (WAV, AIFF, MP3, M4A, CAF, FLAC) becomes a 16-bit, 44.1 kHz WAV.
   - Everything else (.SND, .PGM, .APS, .ALL…) is copied exactly as it is.
   - Names become MPC-friendly 8.3 uppercase names (`Kick Drum 01.wav` → `KICK_DRU.WAV`), and folders keep their structure.

Then click **Eject**. Mac clutter (`._` files, `.DS_Store`, `.Trashes`…) is removed first, so the MPC only sees your files, and the SD card can be ejected too.

You can open folders on the image (double-click) to add files inside them, and pick a partition on images with more than one.

## Building

`./make-app.sh` builds `build/SampleBlaster Lite.app` and a DMG. It's written in Objective-C so that it needs nothing High Sierra doesn't already have, and the build fails if it uses anything newer than 10.13. `Packaging/check-compat.sh` then checks the finished app is marked for 10.13 and only uses system libraries.

`./Tests/run-tests.sh` runs the tests on a Mac, including a real mount, add and eject of an MBR FAT16 image.

Artwork goes in `Artwork/`: `AppIcon.png` (1024 × 1024) and an optional `Header.png` shown across the top of the window.

The app is ad-hoc signed. The first time, right-click it and choose **Open**.
