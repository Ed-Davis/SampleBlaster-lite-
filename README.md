# SampleBlaster Lite

A simple Mac utility for ZuluSCSI disk images, by Ed Davis. It runs on **macOS 10.13 High Sierra** and later, on Intel and Apple silicon Macs.

It does two things:

1. **Mounts** a ZuluSCSI / BlueSCSI hard disk image (`HD0.img`, `.hda`), straight from the SD card.
2. **Copies files** onto it: drag files and folders onto the window, or click **Add Files…**.
   - Everything is copied exactly as it is, names included: nothing is converted or renamed. The image could be for an MPC, a sampler or a synth, so it's up to you to give each device the file formats and names it needs.
   - Folders keep their structure. Copying a folder that's already on the image adds to it.
   - A file that's already on the image is never replaced: it's skipped, and you're told.
   - Hidden Mac files (`.DS_Store` and the like) and aliases are left out.

Then click **Eject**. Mac clutter (`._` files, `.DS_Store`, `.Trashes`…) is removed first, so the device only sees your files, and the SD card can be ejected too.

You can open folders on the image (double-click) to copy files into them, and pick a partition on images with more than one.

## Building

`./make-app.sh` builds `build/SampleBlaster Lite.app` and a DMG. It's written in Objective-C so that it needs nothing High Sierra doesn't already have, and the build fails if it uses anything newer than 10.13. `Packaging/check-compat.sh` then checks the finished app is marked for 10.13 and only uses system libraries.

`./Tests/run-tests.sh` runs the tests on a Mac, including a real mount, add and eject of an MBR FAT16 image.

Artwork is in `Artwork/`: `AppIcon.png` (the app icon) and `Splash.png` (shown at launch). The splash and the window's title bar show "Copyright Ed Davis 2026" with the version and build. The version is always marked **beta**, and the build number counts commits. An optional `Header.png` can go across the top of the window.

Push to a `test-release/<anything>` branch to publish the DMG as a GitHub pre-release.

The app is ad-hoc signed. The first time, right-click it and choose **Open**.
