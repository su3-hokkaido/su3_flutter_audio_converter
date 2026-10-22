# su3_flutter_audio_converter

A Flutter FFI plugin that converts audio files entirely on the device. It bundles a minimal,
audio-only build of FFmpeg and calls it through a thin C wrapper and `dart:ffi`.

## Features

- Input and output formats: mp3, m4a, wma, wav, aac (all 5 x 5 pairs, including same-format).
- Bitrate: 128 / 192 / 256 / 320 kbps (default 128), narrowed per output format.
- Progress reporting and cancellation, with no temporary or partial files left behind.
- Fully offline: no network access, no analytics, no data collected.
- Platforms: iOS, Android, macOS and Windows (Windows is experimental: the build is checked in CI,
  but it has not been run on a Windows machine yet).

## Installation

```
flutter pub add su3_flutter_audio_converter
```

The prebuilt FFmpeg and LAME libraries are bundled in the package, so no toolchain and no network
access are needed when you build your app. Minimum versions: iOS 15.0, macOS 10.15, Android API 24.

## Usage

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

Read the properties of a file, offer only the bitrates the encoder honours, and pick a free output
name:

```dart
final info = await converter.probe('/path/to/recording.wav'); // format, duration, rate, channels
final bitrates = converter.supportedBitrates(AudioFormat.mp3, input: info);
final outputPath = resolveUniqueOutputPath('/path/to', 'recording', AudioFormat.mp3);
// -> /path/to/recording.mp3, or "recording (1).mp3" if that name is taken
```

Notes:

- MP3 from input below 32 kHz is limited by the format to 160 kbps (64 kbps at 12 kHz and below), so
  only 128 kbps is offered there.
- Lossy outputs are at most stereo; input with more channels is mixed down. When an encoder does not
  support the input sample rate, the nearest supported rate is used. 8-bit WAV input gives 16-bit
  WAV output.

## Licenses

This package is released under the [MIT License](./LICENSE). The bundled FFmpeg and LAME libraries
are built in an LGPL-only configuration and linked dynamically (separate shared libraries, so you
can replace them with your own build):

| Component | Version | License | Source |
|---|---|---|---|
| [FFmpeg](https://ffmpeg.org/) (libavformat, libavcodec, libswresample, libavutil) | 8.1.3 | LGPL 2.1 or later | https://ffmpeg.org/releases/ffmpeg-8.1.3.tar.xz |
| [LAME](https://lame.sourceforge.io/) (libmp3lame) | 3.100 | LGPL 2 | https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz |

The license texts and rebuilding notes are in [`licenses/`](./licenses). The build scripts are in
`build/ffmpeg/`, and the GitHub Release named by `PREBUILT_TAG` in `build/versions.env` attaches the
exact sources and checksums. An app that uses this package should show these notices, for example
through Flutter's `LicenseRegistry`.

## Support

If this package is useful to you, you can support its development:
https://buymeacoffee.com/su3hokkaido

## Development

Prebuilt FFmpeg and LAME libraries are not committed. Fetch the ones published as a GitHub Release
(the tag is `PREBUILT_TAG` in `build/versions.env`; the Release also carries the sources and build
scripts):

```
tool/fetch_prebuilt.sh                # all platforms, or name them: macos ios android windows
```

Or build them yourself. On macOS:

```
build/ffmpeg/fetch_sources.sh         # download and verify the pinned sources
build/ffmpeg/build_macos.sh           # build universal dylibs into build/work/out/macos
build/ffmpeg/package_macos.sh         # create macos/Frameworks/*.xcframework and prebuilt/include
tool/run_native_tests_macos.sh        # native tests (add --leaks for the leak check)
```
