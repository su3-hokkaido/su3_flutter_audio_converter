---
name: ffmpeg-build
description: Build the minimal audio-only FFmpeg and LAME for a target OS, with the configure options from the project plan, and measure artifact size. Use when working on build/ffmpeg scripts or producing binaries.
---

Build the minimal LGPL, audio-only FFmpeg (plus LAME) for one target OS. The configure options are
in [configure-flags.md](./configure-flags.md); they implement `docs/project_plan.md` §5.3 and §5.4
and must not be widened without asking the user.

## Steps

1. Read `build/versions.env` for the pinned FFmpeg and LAME versions. Download the source tarballs
   and verify the checksums before building. If a checksum is missing, stop and ask.
2. Pick the script for the target:
   - macOS: `build/ffmpeg/build_macos.sh` (arm64 + x86_64, Universal XCFramework of dynamic frameworks)
   - iOS / iPadOS: `build/ffmpeg/build_ios.sh` (device arm64; simulator arm64 + x86_64)
   - Android: `build/ffmpeg/build_android.sh` (arm64-v8a, armeabi-v7a, x86_64; `.so` into `jniLibs`)
   - Windows: `build/ffmpeg/build_windows.ps1` (x64 `.dll`, MSYS2 or MSVC)
3. Build LAME first (shared, no frontend), then FFmpeg against it.
4. Place artifacts per §6.3. They are git-ignored; never commit binaries.
5. Verify the license posture of the result: no GPL/nonfree in `configure` output, only the
   libraries listed in the flags file are produced, libraries are dynamic.
6. Measure and report the size per architecture and in total (§6.4).
7. Run the `license-auditor` agent on the result.

## Rules

- `--disable-everything` first, then enable only listed components. Report the reason for any extra.
- Never pass `--enable-gpl`, `--enable-nonfree` or enable `libfdk-aac` (the guard hook blocks it).
- Do not upload to GitHub Releases yourself; give the user the exact command.
