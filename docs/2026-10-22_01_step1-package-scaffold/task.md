# Tasks

Each item is sized to one commit.

- [x] M0: scaffold the `plugin_ffi` package (pubspec metadata, formatted template, `flutter analyze` clean)
- [ ] M0: add `test/` with a smoke test and `README.md` / `CHANGELOG.md` placeholders for this package
- [ ] M1: `build/versions.env` with pinned FFmpeg and LAME versions and checksums
- [ ] M1: `build/ffmpeg/build_macos.sh` (LAME, then FFmpeg; shared; minimal flags) and run it
- [ ] M1: package the macOS XCFramework layout and the git-ignore rules; report size
- [ ] M2: C wrapper header with `su3_probe`, `su3_convert_start`, `su3_convert_cancel`, `su3_last_error`
- [ ] M2: wav -> mp3 implementation on a worker thread, C-level test
- [ ] M2: regenerate bindings (`regenerate-bindings` skill)
- [ ] M3: Dart API slice (`AudioFormat`, `ConvertOptions`, `AudioConverter.convert`) with typed exceptions
- [ ] M3: example app converts wav -> mp3 on macOS
- [ ] Add a changeset-equivalent entry (CHANGELOG) and run `code-reviewer`, `license-auditor`
