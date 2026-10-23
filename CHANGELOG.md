# Changelog

## [0.1.3](https://github.com/su3-hokkaido/su3_flutter_audio_converter/compare/v0.1.2...v0.1.3) (2026-10-23)


### Bug Fixes

* Find .lib from both of lib/ and bin/ ([ea01195](https://github.com/su3-hokkaido/su3_flutter_audio_converter/commit/ea01195f34135d295f32a5e51291eeedc414d9d0))
* Find .lib from both of lib/ and bin/ ([211f180](https://github.com/su3-hokkaido/su3_flutter_audio_converter/commit/211f180508468d5f0688b9e9e9f8368b54c8bec3))

## [0.1.2](https://github.com/su3-hokkaido/su3_flutter_audio_converter/compare/v0.1.1...v0.1.2) (2026-10-23)


### Bug Fixes

* Add  to  in configure ([9eaaf16](https://github.com/su3-hokkaido/su3_flutter_audio_converter/commit/9eaaf168190e749bae0d426f80b48dcd187a7309))
* Add  to  in configure ([d0fce51](https://github.com/su3-hokkaido/su3_flutter_audio_converter/commit/d0fce51adb159f609ffd8e48ae9aa55a9dde142d))

## [0.1.1](https://github.com/su3-hokkaido/su3_flutter_audio_converter/compare/v0.1.0...v0.1.1) (2026-10-23)


### Bug Fixes

* link error of LAME ([64d0a2d](https://github.com/su3-hokkaido/su3_flutter_audio_converter/commit/64d0a2d47960aa46877fab323f7f35a8009dbe62))
* link error of LAME ([789c6dc](https://github.com/su3-hokkaido/su3_flutter_audio_converter/commit/789c6dcfd5de78e585489d85ac518f3288749f76))

## [0.1.0](https://github.com/su3-hokkaido/su3_flutter_audio_converter/compare/v0.0.1...v0.1.0) (2026-10-22)

First release.

### Features

* Convert between all 5 x 5 formats (mp3, m4a, wma, wav, aac) fully on the device with a bundled, minimal, LGPL-only FFmpeg and LAME, through `dart:ffi`.
* Progress reporting and cancellation; partial output is removed on failure or cancel.
* `AudioConverter.probe` / `AudioInfo`, `supportedBitrates(format, {input})` (MP3 is narrowed to 128 kbps for input below 32 kHz), and `resolveUniqueOutputPath` (`name (1).mp3`).
* Platforms: iOS 15.0+, Android API 24+ (arm64-v8a, armeabi-v7a, x86_64), macOS 10.15+ and Windows x64 (experimental: not yet run on a Windows machine).
