# Bundled third-party components

`su3_flutter_audio_converter` is released under the MIT License (`../LICENSE`). The package bundles
prebuilt native libraries of the following components. They are built in an LGPL-only
configuration and linked **dynamically** (separate shared libraries), so you can replace them with
your own build.

| Component | Version | License | Source |
|---|---|---|---|
| FFmpeg (libavformat, libavcodec, libswresample, libavutil) | 8.1.3 | LGPL 2.1 or later (no `--enable-gpl`, no `--enable-nonfree`) | https://ffmpeg.org/releases/ffmpeg-8.1.3.tar.xz |
| LAME (libmp3lame) | 3.100 | LGPL 2 (libmp3lame is used as a separate library) | https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz |

The versions above are the ones pinned in `build/versions.env`. Both are built from the pinned
tarballs; the only adjustments are made by the build scripts in `build/ffmpeg/`:

- LAME (macOS and iOS scripts): `lame_init_old` is deleted from `include/libmp3lame.sym`; LAME 3.100
  lists the symbol but does not define it, which newer linkers reject. The Windows script compiles the
  unmodified LAME sources directly and exports through the shipped `lame.def`.
- FFmpeg (Android script): the generated `ffbuild/config.mak` is patched so the libraries get plain
  SONAMEs (`libavcodec.so`, not `libavcodec.so.62`). This changes the build system, not FFmpeg's code.

No source file of FFmpeg is modified.

- License texts: [`ffmpeg/`](./ffmpeg) (`COPYING.LGPLv2.1`, `COPYING.LGPLv3`, `LICENSE.md`) and
  [`lame/`](./lame) (`COPYING`, `LICENSE`), copied from the source tarballs.
- Audio encoding with MP3 uses LAME (https://lame.sourceforge.io/). AAC and WMA use FFmpeg's own
  encoders; `libfdk-aac` is not used.
- FFmpeg is configured from `--disable-everything` and enables only the components listed in
  `build/ffmpeg/build_macos.sh` (the same list is used by the iOS, Android and Windows scripts).
- Rebuilding: the build scripts are in `build/ffmpeg/`. The GitHub Release named by `PREBUILT_TAG`
  in `build/versions.env` attaches the exact source tarballs, the build scripts and checksums.
  Replace the shared libraries in your app (`libav*.so`, `*.xcframework`, `*.dll`) with your own
  build to relink against a modified FFmpeg or LAME.

If you ship an app that uses this package, show these notices (for example through Flutter's
`LicenseRegistry`).
