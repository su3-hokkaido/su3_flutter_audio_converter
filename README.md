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

The Flutter version is pinned in `.fvmrc` and used through [FVM](https://fvm.app/): run
`fvm use` once to link the SDK (the `Makefile` calls `fvm flutter` when `fvm` is installed, and plain
`flutter` otherwise).

Common tasks have shortcuts in the `Makefile`; `make help` lists them all:

```
make setup                            # flutter pub get (package and example app)
make check                            # format check, flutter analyze and flutter test (same as CI)
make act                              # run .github/workflows/ci.yml locally in Docker with act
make fetch-prebuilt                   # same as tool/fetch_prebuilt.sh (PLATFORMS="macos ios" to narrow)
make prebuilt-macos                   # fetch sources, build and package the macOS libraries
make native-test                      # native tests (make native-test-leaks for the leak check)
make integration-test DEVICE=macos   # integration tests on a device
make publish-dry-run                  # flutter pub publish --dry-run
```

The sections below show the underlying commands.

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

### Releasing

Two independent things are released: the prebuilt native libraries (GitHub Release `prebuilt-vN`)
and the package itself (`vX.Y.Z`, pub.dev). The repository needs the setting "Allow GitHub Actions
to create and approve pull requests" (or a `RELEASE_TOKEN` secret), and `main` as its default branch.

**1. Prebuilt libraries** (only when FFmpeg, LAME, the build scripts or a deployment target change)

1. Change the code, bump `PREBUILT_TAG` in `build/versions.env` (for example `prebuilt-v2`) and merge
   it through `develop`.
2. Run the **Prebuilt** workflow by hand (Actions > Prebuilt > Run workflow). It builds macOS, iOS,
   Android and Windows and keeps the archives as workflow artifacts. Fix failures here; the Windows
   job uploads `build-windows-log`.
3. When all four jobs pass, tag the commit on `main` and push the tag. The workflow runs again and
   creates the Release (the four archives, the FFmpeg and LAME sources, the build scripts,
   `BUILD-INFO.txt`, `SHA256SUMS`). A tag is used once; if the Release job fails, delete the tag and
   the partial Release, or move to the next number.

   ```
   git switch main && git pull
   git tag prebuilt-v2 && git push origin prebuilt-v2
   ```

**2. Package version** (release-please)

1. Use Conventional Commits. `feat:` and `fix:` change the package and open a release pull request;
   `build:`, `ci:`, `chore:` and `docs:` do not (use them for build scripts, workflows and
   documentation). Messages must describe the change, not name a branch.
2. Merge `develop` into `main`. The **Release Please** workflow opens `chore(main): release X.Y.Z`
   (it bumps `pubspec.yaml` and `CHANGELOG.md`). Edit the changelog entry in that pull request if
   needed, then merge it: the tag `vX.Y.Z` and a GitHub Release are created.
3. Merge `main` back into `develop`.

**3. Publishing to pub.dev** (by hand)

On the `vX.Y.Z` commit of `main`:

```
tool/fetch_prebuilt.sh                # all four platforms, from PREBUILT_TAG
flutter analyze && flutter test
flutter pub publish --dry-run         # expect 0 warnings and about 14 MB
flutter pub publish
```

The first three steps are also `make fetch-prebuilt`, `make check` and `make publish-dry-run`.

`.pubignore` replaces `.gitignore` for publishing, so the git-ignored prebuilt libraries are
included. Checks that were done for 0.1.x:

- `pana` scores 160/160. Run it on a copy of the package without the example app's generated
  directories (`.symlinks`, `ephemeral`, `Pods`, `build`): on the working tree it follows
  `example/ios/.symlinks` back into the package and fills the disk.
- `pod lib lint` currently fails with Xcode 27 because the Flutter SDK's own `Flutter` pod targets an
  old iOS version; building the example app (`flutter build ios`, `flutter build macos`) is the
  check that matters.
