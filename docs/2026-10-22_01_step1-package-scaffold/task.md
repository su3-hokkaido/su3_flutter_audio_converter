# Tasks

Each item is sized to one commit.

- [x] M0: scaffold the `plugin_ffi` package (pubspec metadata, formatted template, `flutter analyze` clean)
- [x] M0: add `test/` with an `AudioFormat` smoke test and `README.md` / `CHANGELOG.md` for this package
- [x] M1: `build/versions.env` with pinned FFmpeg 8.1.3 and LAME 3.100 and SHA-256 checksums (first-download values; not yet checked against FFmpeg's signature)
- [x] M1: `build/ffmpeg/build_macos.sh` (written; LAME, then FFmpeg; shared; minimal flags). All enable/disable names were checked against FFmpeg 8.1.3 `./configure --list-*`. Run on macOS: succeeds, see the build results in design.md
- [x] M1: report size (4.3 MB universal, 5 dylibs)
- [ ] M1: package the macOS dylibs as dynamic frameworks / XCFramework for the podspec, and wire `tool/fetch_prebuilt.sh` (see design.md, build results)
- [ ] M2: C wrapper header with `su3_probe`, `su3_convert_start`, `su3_convert_cancel`, `su3_last_error`
- [ ] M2: wav -> mp3 implementation on a worker thread, C-level test
- [ ] M2: regenerate bindings (`regenerate-bindings` skill)
- [ ] M3: Dart API slice (`AudioFormat`, `ConvertOptions`, `AudioConverter.convert`) with typed exceptions
- [ ] M3: example app converts wav -> mp3 on macOS
- [ ] Add a changeset-equivalent entry (CHANGELOG) and run `code-reviewer`, `license-auditor`
