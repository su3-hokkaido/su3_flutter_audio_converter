# M4 iOS and Android: FFmpeg/LAME build, plugin integration and verification

Scope: `docs/project_plan.md` §7 Step 1 milestone 4, iOS and Android parts. The Windows part is in
`docs/2026-10-22_04_m4-windows/design.md` (unverified, no Windows machine).

## Files

- `build/ffmpeg/build_ios.sh`: device arm64 and simulator arm64 + x86_64 dylibs (same configure list
  as `build_macos.sh`).
- `build/ffmpeg/package_ios.sh`: dylibs -> dynamic frameworks -> XCFrameworks in `ios/Frameworks/`,
  headers in `prebuilt/include/`. Fails if a bare `@rpath/lib*.dylib` reference remains.
- `ios/su3_flutter_audio_converter.podspec`: `vendored_frameworks`, iOS 15.0.
- `build/ffmpeg/build_android.sh`: NDK build for arm64-v8a, armeabi-v7a, x86_64; unversioned SONAMEs
  (patched `config.mak`, checked after patching); output in `android/src/main/jniLibs/<abi>/`.
- `android/CMakeLists.txt`: compiles `src/` and links the prebuilt `.so` files. `android/build.gradle`
  points at it and limits `abiFilters` to the three built ABIs (32-bit x86 is not built).
- `build/versions.env`: `IOS_DEPLOYMENT_TARGET`, `ANDROID_NDK_VERSION`, `ANDROID_API_LEVEL`.

## Verification results

| Target | Check | Result |
|---|---|---|
| iOS simulator (iPad Pro, iOS 26.5) | `matrix_test`, `convert_test` | 79 + 7 passed |
| iOS device (arm64) | `flutter build ios --no-codesign` | builds; five frameworks embedded, arm64 only. Not run on hardware |
| Android emulator (Pixel 9a, API 36, x86_64) | `matrix_test`, `convert_test` | 79 + 7 passed |
| Android arm64-v8a, armeabi-v7a | debug APK build | builds; all `.so` packaged. Not run |
| macOS | `matrix_test` (regression) | 79 passed |
| Package | `flutter test`, `flutter analyze` | 50 passed, no issues |
| 16 KB pages | LOAD alignment of arm64-v8a and x86_64 `.so` | 0x4000 |
| Licenses | `license-auditor` on configure flags and generated `config.h` | `CONFIG_GPL 0`, `CONFIG_NONFREE 0`, shared only |

## Sizes (section 6.4)

| Artifact | Size |
|---|---|
| Android arm64-v8a (5 stripped `.so`) | 2180 KiB |
| Android armeabi-v7a | 1972 KiB |
| Android x86_64 | 2264 KiB |
| iOS XCFrameworks (device + simulator slices, 5 libraries) | 6.6 MiB |

## Problems found and fixed

- Gradle also built 32-bit `x86` and failed on the missing `.so`: fixed with `abiFilters`.
- Flutter assets with a `../` key (`../test/fixtures/...`) are not readable on Android: the fixtures
  moved to `example/assets/fixtures/` (references updated).

## Not covered / follow-ups

- iOS and Android arm devices were not available; only the build and the simulator/emulator ran.
- The `licenses/` directory and the per-component table in README (section 5.4) are still to be
  written before publishing, together with `.pubignore` so the git-ignored binaries are included
  in the published package.
- An app that uses a different NDK from 27.0.12077973 is accepted (decision #25).
