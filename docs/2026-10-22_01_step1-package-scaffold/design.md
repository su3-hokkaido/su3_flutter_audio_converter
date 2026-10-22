# Step 1: package scaffold and first conversion path

Scope of this task: milestones 0 to 3 of `docs/project_plan.md` §7 Step 1 (scaffold, minimal FFmpeg
for macOS, C wrapper wav -> mp3, call it from the example app). Milestones 4 to 7 (other OSes, full
5x5 matrix, CI binaries, publish) get their own task directories.

## Requirements

- A `plugin_ffi` package for iOS, Android, macOS and Windows (§7 Step 1).
- macOS first; convert one path, wav -> mp3, through `dart:ffi` from the example app.
- Constraints from §4, §5 and §9 apply unchanged (offline, LGPL only, dynamic linking, minimal
  FFmpeg built from `--disable-everything`).

## Design

### Scaffold (done)

Generated with `flutter create --template=plugin_ffi --platforms=android,ios,macos,windows` and
copied into the repository root. Kept as generated: `src/` (CMake), `ios/` and `macos/` podspecs
and forwarding `Classes/*.c`, `windows/CMakeLists.txt`, `android/build.gradle`, `ffigen.yaml`.

Known template leftovers to replace as the wrapper is written:

- The C sources are the template's `sum` / `sum_long_running` demo. The shared library is still
  named `su3_flutter_audio_converter`; the plan calls it `libsu3_audio_core`. Decide the final
  name when the first real function lands (renaming touches CMake, podspecs, `ffigen.yaml` and the
  Dart loader).
- `ffi` is a dev dependency in the template. It becomes a regular dependency as soon as the Dart
  side uses `package:ffi` (allocation helpers).
- The generated bindings are formatted with `dart format` so the CI format check passes; repeat
  that after every regeneration.

### Native layout

- `src/` holds the C wrapper, compiled from source in every plugin build (decision #17).
- FFmpeg and LAME are prebuilt dynamic libraries (decision #3), fetched into git-ignored
  locations: `macos/Frameworks` (XCFramework), later `android/src/main/jniLibs`, `windows/`.
  `build/ffmpeg/` and `build/versions.env` are committed; outputs are not.
- Link FFmpeg and LAME dynamically (LGPL).

### Milestone sequence

1. M0 scaffold (this commit).
2. M1 macOS build script: `build/versions.env`, `build/ffmpeg/build_macos.sh`, checksum
   verification, flags from `.claude/skills/ffmpeg-build/configure-flags.md`. Verify the flag names
   against the pinned FFmpeg `./configure --help` before the first build. Report size.
3. M2 C wrapper: `su3_convert_start` for wav -> mp3 on a worker thread, `su3_last_error`; test it
   from a C or Dart test before FFI.
4. M3 Dart API slice: `AudioFormat`, `ConvertOptions`, `AudioConverter.convert` for this one path,
   `NativeCallable.listener` for progress; example app on macOS.

## Build results (M1, macOS)

`build/ffmpeg/build_macos.sh` with FFmpeg 8.1.3 and LAME 3.100 produced five universal
(arm64 + x86_64) dylibs in `build/work/out/macos/lib`, 4.3 MB in total:

| Library | Size |
|---|---|
| libavcodec | 1.29 MB |
| libavformat | 1.31 MB |
| libavutil | 1.05 MB |
| libmp3lame | 0.70 MB |
| libswresample | 0.19 MB |

Checks done: both architectures present in every file; install names and inter-library references
are `@rpath/...`; the only other dependencies are `libSystem` and the CoreFoundation, CoreVideo
and CoreMedia frameworks; the binaries report "LGPL version 2.1 or later"; the recorded configure
line matches the flags file (no GPL/nonfree). Minimum macOS is 10.15 for x86_64 and 11.0 for arm64.

Findings to act on:

- CoreVideo and CoreMedia are linked although no video is used (libavutil's Darwin hardware-context
  code). Harmless, but it is more than "libSystem only"; revisit with `--disable-videotoolbox` and
  similar if the final configure shows it can be dropped without losing anything required.
- The five dylibs still need to become dynamic frameworks (iOS requires them; macOS uses the same
  layout for consistency) and be wired into the podspec via `vendored_frameworks`. This also needs
  `tool/fetch_prebuilt.sh`. Doing it as the first step of M2 keeps the wrapper buildable.
- The x86_64 slice needs Rosetta on Apple-silicon build machines (LAME runs its configure tests).

## Open questions

None blocking. The final native library name is decided at M2 (see above).

## Risks

- Building FFmpeg needs `nasm` or `--disable-x86asm`, Xcode command line tools and network access
  to download tarballs (build-time only, allowed by §9). Source downloads are done by the user or
  by an approved script run, because `curl`/`wget` are denied in `.claude/settings.json`.
- Notarization and code signing of dynamic frameworks in the macOS app are handled in Step 2.
