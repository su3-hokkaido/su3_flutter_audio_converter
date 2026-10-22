# su3_flutter_audio_converter

A Flutter FFI plugin that converts audio files entirely on the device. It bundles a minimal,
audio-only build of FFmpeg and calls it through a thin C wrapper and `dart:ffi`.

> Status: under development. The public API is not available yet; nothing is published on pub.dev.

## Features (planned)

- Input and output formats: mp3, m4a, wma, wav, aac (all 5 x 5 pairs, including same-format).
- Bitrate: 128 / 192 / 256 / 320 kbps (default 128), narrowed per output format.
- Progress reporting and cancellation, with no temporary or partial files left behind.
- Fully offline: no network access, no analytics, no data collected.
- Platforms: iOS, Android, macOS, Windows.

See [docs/project_plan.md](./docs/project_plan.md) for the specification.

## Usage (work in progress)

```dart
final converter = AudioConverter();
final token = CancelToken();

final written = await converter.convert(
  inputPath: '/path/to/recording.wav',
  outputPath: '/path/to/recording.mp3',
  options: const ConvertOptions(outputFormat: AudioFormat.mp3, bitrateKbps: 192),
  onProgress: (progress) => print('${(progress * 100).round()}%'),
  cancelToken: token, // token.cancel() stops it and removes the partial file
);
```

Only conversion to MP3 on macOS works so far.

## Licenses

This package is released under the [MIT License](./LICENSE). The bundled FFmpeg and LAME libraries
are built in an LGPL-only configuration and linked dynamically; their versions, licenses and source
locations will be listed in `licenses/` and in this README before the first release.

## Support

If this package is useful to you, you can support its development:
https://buymeacoffee.com/su3hokkaido

## Development

Prebuilt FFmpeg and LAME libraries are not committed. On macOS:

```
build/ffmpeg/fetch_sources.sh         # download and verify the pinned sources
build/ffmpeg/build_macos.sh           # build universal dylibs into build/work/out/macos
build/ffmpeg/package_macos.sh         # create macos/Frameworks/*.xcframework and prebuilt/include
tool/run_native_tests_macos.sh        # native tests (add --leaks for the leak check)
```
