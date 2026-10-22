# Test fixtures

`tone.wav`, `tone.mp3`, `tone.wma`, `tone.m4a` and `tone.aac` are the same synthetic clip in the
five supported formats: 1 second, mono, 22.05 kHz, a 300 Hz to 1200 Hz sine sweep with a slow
amplitude modulation. There is no third-party or copyrighted audio; the signal is computed in
`tool/make_fixtures.c`.

How they were made (`tool/make_fixtures_macos.sh`, macOS only, needs the prebuilt FFmpeg from
`build/ffmpeg/build_macos.sh`):

- `tone.wav`: written by `tool/make_fixtures.c` (16-bit PCM).
- `tone.mp3`, `tone.wma`: converted from `tone.wav` at 128 kbps with this package's native core
  (`su3_convert_start`), linked by the same script.
- `tone.m4a`, `tone.aac` (ADTS): converted from `tone.wav` with `/usr/bin/afconvert` at 64 kbps
  (`-f m4af` and `-f adts`, `-d aac`), so the AAC inputs come from an independent encoder.

Total size is about 90 KB. The files are committed; rerun the script only to change them. The
integration test (`example/integration_test/matrix_test.dart`) loads them as assets of the example
app (`example/pubspec.yaml`).
