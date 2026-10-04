# SampleBlaster Lite

A simple Mac utility for ZuluSCSI disk images, by Ed Davis. It runs on **macOS 10.13 High Sierra** and later, on Intel and Apple silicon Macs.

It does two things:

1. **Mounts** a ZuluSCSI / BlueSCSI hard disk image (`HD0.img`, `.hda`), straight from the SD card.
2. **Adds files** to it: drag files and folders onto the window, or click **Add Files…**.
   - Every file is copied exactly as it is: no conversion, so samples keep their own sample rate and bit depth, and MPC files (.SND, .PGM, .APS, .ALL…) are untouched.
   - Names become MPC-friendly 8.3 uppercase names (`Kick Drum 01.wav` → `KICK_DRU.WAV`), and folders keep their structure.

Then click **Eject**. Mac clutter (`._` files, `.DS_Store`, `.Trashes`…) is removed first, so the MPC only sees your files, and the SD card can be ejected too.

You can open folders on the image (double-click) to add files inside them, and pick a partition on images with more than one.

## Building

`./make-app.sh` builds `build/SampleBlaster Lite.app` and a DMG. It's written in Objective-C so that it needs nothing High Sierra doesn't already have, and the build fails if it uses anything newer than 10.13. `Packaging/check-compat.sh` then checks the finished app is marked for 10.13 and only uses system libraries.

`./Tests/run-tests.sh` runs the tests on a Mac, including a real mount, add and eject of an MBR FAT16 image.

Artwork is in `Artwork/`: `AppIcon.png` (the app icon) and `Splash.png` (shown at launch). The splash and the window's title bar show "Copyright Ed Davis 2026" with the version and build. The version is always marked **beta**, and the build number counts commits. An optional `Header.png` can go across the top of the window.

Push to a `test-release/<anything>` branch to publish the DMG as a GitHub pre-release.

The app is ad-hoc signed. The first time, right-click it and choose **Open**.
