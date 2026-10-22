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

## Licenses

This package is released under the [MIT License](./LICENSE). The bundled FFmpeg and LAME libraries
are built in an LGPL-only configuration and linked dynamically; their versions, licenses and source
locations will be listed in `licenses/` and in this README before the first release.

## Support

If this package is useful to you, you can support its development:
https://buymeacoffee.com/su3hokkaido
