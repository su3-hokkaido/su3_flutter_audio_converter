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

## M2 results (C wrapper, macOS)

- Library name: kept as the package name `su3_flutter_audio_converter` (the `plugin_ffi` loader and
  CMake expect it); "libsu3_audio_core" in the plan is a conceptual name only.
- Header: `su3_convert_start` / `su3_convert_cancel` / `su3_last_error` / `su3_job_release`.
  `su3_job_release` was added: the job (and its error message) stays valid until Dart has read it,
  because the callback arrives asynchronously through `NativeCallable.listener`.
  `su3_probe` is not written yet; it comes with the Dart API (M3) because `AudioInfo` is needed.
- Implemented: any decodable input to MP3 (mono or stereo, input sample rate, 128/192/256/320 kbps),
  progress every 1%, cancellation with removal of the partial output, error codes for missing input,
  corrupt input, unsupported bitrate and not-yet-implemented output formats.
- Tests: `tool/run_native_tests_macos.sh` builds `test/native/test_convert.c` with the wrapper under
  AddressSanitizer and UndefinedBehaviorSanitizer (all pass); `--leaks` runs it without sanitizers
  under the system `leaks` tool (0 leaks). LeakSanitizer is not available on Apple silicon.
  The cancel test accepts "done" as well as "cancelled" because a fast conversion can win the race;
  it checks that a cancelled job leaves no file and that exactly one terminal callback is sent.
- The example app builds for macOS and embeds the five frameworks plus the plugin framework, which
  exports the `su3_*` symbols and links the FFmpeg frameworks. It has not been run yet (M3).
- Toolchain finding: the installed Xcode rejects macOS deployment targets below 12.0, while Flutter
  3.35's macOS pods still use 10.15. The example's Podfile overrides the pod targets to 12.0 and the
  Runner uses 12.0. The package's podspec still declares 10.15; revisit when preparing the release.

Not verified: the Windows branches of the threading code (written but never compiled), and the iOS,
Android and Windows builds, which are broken until milestone 4 because their build files do not
link the prebuilt libraries yet.

## M3 results (Dart API, macOS)

- Public API: `AudioConverter` (abstract interface with a factory returning `NativeAudioConverter`,
  so tests and apps can substitute a fake), `ConvertOptions`, `CancelToken`, `AudioFormat`, and the
  exceptions `UnsupportedFormatException`, `UnsupportedBitrateException`, `CorruptedFileException`,
  `ConversionCancelledException` under the base `ConversionException` (which also carries missing
  input, I/O and internal errors with the native error code).
- `supportedBitrates(format)` has no `input` argument yet; it arrives with `probe` and `AudioInfo`
  (the plan's `supportedBitrates(format, {AudioInfo? input})`). `probe` is not implemented.
- Validation (bitrate against the per-format table, token already cancelled) happens in Dart before
  any native call.
- Progress and completion use `NativeCallable.listener`; each conversion owns one callable that is
  closed after the terminal event, and the native job is released then.
- The example app converts a generated 3 minute sine WAV (no file picker yet; macOS sandbox and a
  picker package are left for the app work) with a bitrate dropdown, progress bar and cancel button.
- `example/integration_test/convert_test.dart` runs in the real macOS app
  (`cd example && flutter test integration_test -d macos`): conversion with progress, bitrates
  128 and 320 (output size within 15% of the expectation), cancellation of a 10 minute file,
  a pre-cancelled token, missing and garbage input, and four parallel conversions. All pass.
  These need the prebuilt frameworks, so CI does not run them yet.
- `ffi` moved from dev dependency to dependency (BSD-3-Clause, Dart team); the unused template
  dependency `plugin_platform_interface` was removed.

## M3 review follow-ups

- `NativeAudioConverter.convert` now closes the `NativeCallable` on every failure path, completes the
  Future with the error when `onProgress` or the error-message read throws, reports `1.0` on
  completion, and decodes native messages with malformed UTF-8 tolerated.
- Decoders `mp3float` and `pcm_u8` are outside the plan's 5.3 table: `mp3float` is the decoder FFmpeg
  actually uses for MP3, `pcm_u8` reads 8-bit WAV. Reason recorded in `build/ffmpeg/build_macos.sh`.
- Not done (later milestones): single source for the bitrate table (Dart vs C), unit tests for the
  native error mapping, typed exception assertions in the missing/garbage input integration tests.

## M5 results

- Decisions recorded in project_plan 8.1 #20-#22 (stereo cap, nearest sample rate, 8-bit -> 16-bit).
- Measured encoder behaviour (3 s white noise, probe of the output):
  - MP3: >= 32 kHz honours 128/192/256/320; 16-24 kHz gives 128 for 128 and 160 for anything higher;
    <= 12 kHz is fixed at 64 kbps (even for 128). Hence `supportedBitrates` offers [128] below
    32 kHz and `convert` probes the input to reject higher values. At <= 12 kHz the output is still
    64 kbps; no offered value can be honoured there.
  - AAC / M4A (FFmpeg `aac`): undershoots, e.g. stereo 44.1 kHz gives 126/188/252/320, mono 44.1 kHz
    gives 124/191/201/201, 22.05 kHz mono about 100 for every request. Not a hard cap, so the list
    is not narrowed; tests use a generous lower bound.
  - WMA (wmav2): 192 and 256 produce the same size on simple signals; 320 is rejected (decision #16).
- Corrupted packets in the middle of a file fail the whole conversion (by design for now).
- Integration tests: run the files one at a time (`flutter test integration_test/matrix_test.dart -d
  macos`); running both files in one invocation fails to launch the second app instance.
- Windows branches (`_wremove`, same-file check by `strcmp`) are written but not compiled here.

## Open questions

None blocking. The final native library name is decided at M2 (see above).

## Risks

- Building FFmpeg needs `nasm` or `--disable-x86asm`, Xcode command line tools and network access
  to download tarballs (build-time only, allowed by §9). Source downloads are done by the user or
  by an approved script run, because `curl`/`wget` are denied in `.claude/settings.json`.
- Notarization and code signing of dynamic frameworks in the macOS app are handled in Step 2.
