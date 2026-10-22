# Tasks

Each item is sized to one commit.

- [x] M0: scaffold the `plugin_ffi` package (pubspec metadata, formatted template, `flutter analyze` clean)
- [x] M0: add `test/` with an `AudioFormat` smoke test and `README.md` / `CHANGELOG.md` for this package
- [x] M1: `build/versions.env` with pinned FFmpeg 8.1.3 and LAME 3.100 and SHA-256 checksums (first-download values; not yet checked against FFmpeg's signature)
- [x] M1: `build/ffmpeg/build_macos.sh` (written; LAME, then FFmpeg; shared; minimal flags). All enable/disable names were checked against FFmpeg 8.1.3 `./configure --list-*`. Run on macOS: succeeds, see the build results in design.md
- [x] M1: report size (4.3 MB universal, 5 dylibs)
- [x] M1: package the macOS dylibs as dynamic frameworks / XCFrameworks (`build/ffmpeg/package_macos.sh`) and wire the macOS podspec
- [ ] `tool/fetch_prebuilt.sh` (needs GitHub Releases artifacts; postponed to milestone 6)
- [x] M2: C wrapper header with `su3_convert_start`, `su3_convert_cancel`, `su3_last_error`, `su3_job_release` (`su3_probe` moves to M3/M5, see design.md)
- [x] M2: wav -> mp3 implementation on a worker thread, C-level tests with ASan/UBSan and `leaks` (`tool/run_native_tests_macos.sh`)
- [x] M2: regenerate bindings; macOS example app builds and embeds the frameworks
- [x] M3: Dart API slice (`AudioFormat`, `ConvertOptions`, `CancelToken`, `AudioConverter.convert`, `supportedBitrates`) with typed exceptions
- [x] M3: example app converts a generated wav -> mp3 on macOS; integration tests pass in the real macOS app
- [x] CHANGELOG entry
- [x] Run `code-reviewer` and `license-auditor` (before handing M0-M3 over for the PR); both majors fixed (callback lifecycle on failure paths), see design.md
- [ ] Before the first release: add `licenses/` and README notes for FFmpeg 8.1.3 / LAME 3.100 (license, source, relinking); check the built dylibs are LGPL v2.1+ as expected

## M5 (all 5x5 paths, bitrate constraints, probe)

- [x] C core: 5 inputs x 5 outputs, `su3_probe`, bitrate validation, nearest sample rate, stereo cap
- [x] Dart: `probe`, `AudioInfo`, `supportedBitrates(format, {input})`, `resolveUniqueOutputPath`
- [x] Tests: native 25 pairs (ASan/UBSan, leaks), unit tests, fixtures, macOS 5x5 integration matrix
- [x] `code-reviewer` run; findings fixed (probe on an isolate, double completion, Windows UTF-8 delete,
  error mapping, flush loop, locking, same-file check)
- [ ] Windows branches of the C code (`_wremove`, same-file check) are uncompiled until M4
- [ ] Run `license-auditor` again before the PR (no dependency changes in M5)
