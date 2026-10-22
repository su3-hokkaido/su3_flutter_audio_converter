# Audio Converter — Context for Claude Code

> This file gives Claude Code the background of the project.
> It covers the background, requirements, technical approach and decisions shared by two repositories (a Flutter package and a Flutter app).
> Copy the relevant sections into each repository's `CLAUDE.md`.

---

## 1. Overview

| Item | Details |
|---|---|
| Purpose | Publish a cross-platform app that converts audio files to other formats on the device |
| Background | Convert my old recordings (wma and other legacy formats) into formats in common use today |
| Framework | Flutter / Dart |
| Core package | `su3_flutter_audio_converter` (my own package, to be published on pub.dev) |
| Conversion engine | A self-built FFmpeg (a minimal, audio-only build created from scratch) bundled with the package |
| Dart bridge | `dart:ffi` |
| Revenue model | None (no subscriptions, no in-app purchases) |
| Donations | **Not shown in the app.** Listed only in the GitHub README: https://buymeacoffee.com/su3hokkaido |
| Networking | None. No API calls, no servers. All conversion runs entirely on the device |

---

## 2. Repositories

| Repository | Role | Target OS |
|---|---|---|
| `su3_flutter_audio_converter` | Flutter FFI plugin package that provides the conversion logic (with bundled FFmpeg). Published on pub.dev | iOS / iPadOS, Android, macOS, **Windows** |
| `audio-converter-crossplatform-app` | End-user app built on the package above | iOS / iPadOS, Android, macOS |

- The package supports Windows, but **the app is published to the stores for iOS / iPadOS / macOS / Android only**.
- iPadOS ships in the same (Universal) binary as iOS.
- Stores: App Store (iOS / iPadOS / macOS) and Google Play.

### 2.1 App identity

| Item | Value |
|---|---|
| App display name | Audio Converter for Crossplatform |
| Bundle ID (iOS / macOS) | `su3hokkaido.audioconverter.com` |
| Application ID (Android) | `su3hokkaido.audioconverter.com` |

- Store listing names are limited to 30 characters on both the App Store and Google Play, so the store listing name and the home-screen name (`CFBundleDisplayName` / `android:label`) are `Audio Converter by Su3` (22 characters, decision #14).
- The Bundle ID / Application ID **cannot be changed after the app is published**. They are confirmed in decision #15.

---

## 3. Functional requirements

### 3.1 Input and output formats (initial scope)

| Direction | Formats |
|---|---|
| Input | mp3, m4a, wma, wav, aac |
| Output | mp3, m4a, wma, wav, aac |

- Conversion between all 5 × 5 format pairs.
- **Conversion to the same format is allowed** (e.g. changing the bitrate of an mp3 from 256 kbps to 128 kbps).
- **3GP is out of scope** (for both input and output). Keep the design easy to extend so that a future format only needs a new `AudioFormat` value.

### 3.2 Bitrate

- Options: **128 / 192 / 256 / 320 kbps**
- **Default: 128 kbps**
- Options are narrowed per format (the UI does not allow invalid values to be selected).

| Output format | 128 | 192 | 256 | 320 | Notes |
|---|---|---|---|---|---|
| mp3 | ○ | ○ | ○ | ○ | |
| m4a / aac (AAC-LC) | ○ | ○ | ○ | ○ | FFmpeg's built-in `aac` encoder |
| wma (WMAv2) | ○ | ○ | ○ | − | 320 kbps is not offered for WMA (decision #16) |
| wav (PCM) | − | − | − | − | Uncompressed, so there is no bitrate option (hidden in the UI) |

- The allowed values are defined in the package (`supportedBitrates(format)`). The app builds its UI from the return value.
- For mono or low-sample-rate input, the encoder's upper bitrate limit may be lower. To handle this, allow narrowing based on the `probe` result (e.g. `supportedBitrates(format, inputInfo)`).

### 3.3 WAV output

- **Keep the input's sample rate and channel count.**
- Bit depth: kept if the input is PCM (wav). If the input is compressed (mp3 / m4a / aac / wma), output 16-bit PCM.

### 3.4 Metadata

- **Not carried over in the initial version** (tags such as title, artist and recording date are not written to the output).
- Planned for later. Design the API so that an option (e.g. `ConvertOptions.preserveMetadata`) can be added later.

### 3.5 Output file names

- The output name is "original file name (without extension) + extension of the output format".
- **If a file with the same name already exists in the destination, append a number**: `recording.mp3` → `recording (1).mp3` → `recording (2).mp3` …
- The same rule applies when a single batch produces several outputs with the same name (e.g. converting both `a.wav` and `a.wma` to mp3).

### 3.6 User flow (app)

1. **Select files** (multiple selection allowed)
   - iOS / iPadOS / Android: select from the OS file manager (Files app / SAF)
   - macOS: select from Finder (NSOpenPanel)
   - Windows (package example app only): select from a folder dialog
2. **Select the output format** (and bitrate; default 128 kbps; bitrate is hidden when wav is selected)
3. **Convert** (show per-file and overall progress; cancellable)
4. **Save**: the user selects the destination directory
   - iOS / iPadOS / Android: select the destination in the file manager
   - macOS: select a directory in Finder
   - Windows: select a folder in a folder dialog

---

## 4. Non-functional requirements and constraints

- **Fully offline**: do not request network permissions. Do not include analytics SDKs or anything that sends crash reports externally.
- **Privacy**: collect no user data. The app must qualify for "Data Not Collected" in App Store App Privacy and "no data collected or shared" in Google Play Data safety.
- **macOS sandbox**: App Sandbox enabled, with only `com.apple.security.files.user-selected.read-write`. No network entitlements.
- **Temporary files**: keep intermediate files in the app's temporary directory and always delete them on completion, cancellation or error.
- **Large files**: do not load long recordings (hundreds of MB) fully into memory (process them file by file).
- **Do not block the UI thread**: run conversion on a native worker thread; the Dart side receives results asynchronously.
- **No donation or external-payment links in the app** (to avoid store review issues).

---

## 5. Conversion engine: minimal FFmpeg + `dart:ffi`

### 5.1 Approach

- Do not use `ffmpeg_kit_flutter`; it has been officially retired. Do not fork it either.
- **Build a minimal, audio-only FFmpeg from scratch and bundle it with `su3_flutter_audio_converter`.**
- Instead of embedding the FFmpeg CLI (the `ffmpeg` command), write a **thin C wrapper that calls libavformat / libavcodec / libswresample directly**, and call that wrapper from `dart:ffi`.

### 5.2 Architecture

```
Dart (lib/)
  └─ AudioConverter (public API)
       └─ FFI bindings (generated with ffigen)
            └─ libsu3_audio_core (my C wrapper, src/)
                 ├─ libavformat   … reading and writing containers
                 ├─ libavcodec    … decoding / encoding
                 ├─ libswresample … sample rate and sample format conversion
                 └─ libmp3lame    … MP3 encoding
```

- Keep the C wrapper's public functions to a minimum (draft):
  - `su3_probe(path, out_info)` … read input information
  - `su3_convert_start(in_path, out_path, options, progress_cb) -> job_id` … start conversion on a worker thread
  - `su3_convert_cancel(job_id)` … set the cancel flag
  - `su3_last_error(job_id)` … error code and message
- Send progress and completion from the worker thread back to Dart with `NativeCallable.listener`.
- Expose them on the Dart side as a `Future` plus a progress callback (do not use the approach of blocking an Isolate with synchronous FFI calls).
- Generate the bindings from the C header with `ffigen` and commit the generated code to the repository.

### 5.3 Required FFmpeg components (initial scope)

| Category | Enabled |
|---|---|
| Demuxers | mp3, mov/mp4 (m4a), asf (wma), wav, aac (ADTS) |
| Muxers | mp3, ipod/mp4 (m4a), asf (wma), wav, adts (aac) |
| Decoders | mp3, aac, wmav1, wmav2, pcm_* |
| Encoders | libmp3lame, aac (FFmpeg built-in), wmav2, pcm_s16le / pcm_s24le / pcm_s32le / pcm_f32le |
| Parsers | mpegaudio, aac |
| Libraries | libavformat, libavcodec, libswresample, libavutil only |
| Protocols | file only |
| Disabled | Start from `--disable-everything` and enable only the above. Disable all video, filters (libavfilter), devices, networking, the `ffmpeg` / `ffprobe` / `ffplay` executables, and GPL / nonfree |

### 5.4 Licensing

- **LGPL configuration only** (no `--enable-gpl` / `--enable-nonfree`).
- Do not use `libfdk-aac` (non-free). Use FFmpeg's built-in `aac` encoder for AAC.
- Use `libmp3lame` (LGPL) for MP3 encoding.
- The C wrapper (`libsu3_audio_core`) follows the package's own license. Link FFmpeg / LAME **dynamically** to meet LGPL's relinking requirement.
- List the bundled components, their licenses, versions and source locations in the package README and a `licenses/` directory. The app provides a license screen (e.g. `showLicensePage`) and registers FFmpeg / LAME with `LicenseRegistry`.

---

## 6. Distributing the FFmpeg binaries (proposal)

### 6.1 Options considered

| Option | Description | Pros | Cons |
|---|---|---|---|
| A. Bundle prebuilt binaries in the pub package | Include artifacts built in CI when publishing | Nothing extra for package users. Builds work offline. Simple | Larger package size. Committing binaries to git bloats the history |
| B. Download from GitHub Releases at the user's build time | Fetch during build via podspec / Gradle / CMake | Lightweight package | Users' builds need network access. Handling download failures is complex. Also scores worse on pub.dev |
| C. Compile from source at the user's build time | Build FFmpeg in a build hook | No binaries to distribute | Users need each OS toolchain (NDK, MSYS2, etc.). Builds take tens of minutes. Not realistic |

### 6.2 Recommended: Option A (CI build → stored in Releases → bundled at publish time)

```
[Build scripts in the repo]          [GitHub Actions]                  [pub.dev]
build/ffmpeg/build_ios.sh       ──▶  Build on tag push    ──▶  Artifacts  ──▶  Fetched and bundled
build/ffmpeg/build_android.sh        (runner per OS)           in Releases     at publish time
build/ffmpeg/build_macos.sh
build/ffmpeg/build_windows.sh
```

1. **Keep the build scripts in the repository** (`build/ffmpeg/`). Pin the FFmpeg and LAME versions in `build/versions.env` and verify the checksums of the source tarballs.
2. **Build with GitHub Actions**:
   - iOS / macOS: macOS runner
   - Android: Ubuntu runner + NDK
   - Windows: Windows runner + MSYS2 (MinGW) or MSVC
3. **Store the artifacts in GitHub Releases** and **do not commit them to git** (exclude them with `.gitignore`). During development, fetch them from Releases with `tool/fetch_prebuilt.sh`.
4. **Bundle them only when publishing to pub**: the publish workflow fetches the artifacts, and `.pubignore` does not exclude them, so they are included in the package. Users just run `flutter pub add`.
5. **LGPL compliance**: attach the build scripts, configure options and source locations to the same Release so anyone can rebuild identical binaries.

### 6.3 Artifact format per platform

| OS | Format | Architectures | How it is integrated |
|---|---|---|---|
| iOS / iPadOS | XCFramework of dynamic `.framework`s | arm64 (device), arm64 + x86_64 (simulator) | `vendored_frameworks` in the podspec |
| macOS | XCFramework of dynamic `.framework`s | arm64 + x86_64 (Universal) | `vendored_frameworks` in the podspec |
| Android | `.so` | arm64-v8a, armeabi-v7a, x86_64 | `android/src/main/jniLibs/` |
| Windows | `.dll` | x64 | `bundled_libraries` in CMake |

### 6.4 Expected size and things to check

- A minimal audio-only build is expected to be a few MB per architecture. Even the total across all OSes and ABIs should stay within pub.dev's upload limit, but **measure it after the first build and consider switching to Option B if it exceeds the limit**.
- Store distribution strips unneeded ABIs (ABI splits in Android App Bundles, app thinning on the App Store), so the impact on end users' download size is small.
- The C wrapper (`libsu3_audio_core`) is small, so it is compiled from source in each OS's plugin build (CMake / podspec) instead of being bundled as a binary (decision #17). Only FFmpeg and LAME are prebuilt binaries.

---

## 7. Development steps

### Step 0: Claude Code environment setup (do this first in each repository)

- Following §10, create `.claude/agents/`, `.claude/skills/`, `.claude/hooks/`, `.claude/settings.json` and `CLAUDE.md`.
- When done, **report the list of files created and the role of each, then wait for Su's review before moving on to Step 1 / Step 2**.
- During Steps 1 and 2, actively use the agents and skills from §10.

### Step 1: `su3_flutter_audio_converter` (Flutter FFI plugin package)

- Targets: iOS, Android, macOS, Windows
- Template: `flutter create --template=plugin_ffi`
- Milestones:
  1. Get the minimal FFmpeg build scripts working on one OS (macOS)
  2. Convert one path, wav → mp3, with the C wrapper (macOS)
  3. Convert from the example app via `dart:ffi` (macOS)
  4. Build and verify on the remaining three OSes (iOS, Android, Windows)
  5. Implement all 5×5 paths, bitrate constraints, cancellation and progress
  6. Build the binaries with GitHub Actions and store them in Releases
  7. Publish to pub.dev
- API to provide (draft):

```dart
enum AudioFormat { mp3, m4a, wma, wav, aac }

class ConvertOptions {
  final AudioFormat outputFormat;
  final int? bitrateKbps;   // Default 128. Ignored for wav. Values not in supportedBitrates are an error
  // Planned for later: bool preserveMetadata
}

abstract class AudioConverter {
  /// Converts the input file and returns the path actually written
  Future<String> convert({
    required String inputPath,
    required String outputPath,
    required ConvertOptions options,
    void Function(double progress)? onProgress, // 0.0–1.0
    CancelToken? cancelToken,
  });

  /// Selectable bitrates for each output format (empty list for wav)
  /// Options: 128 / 192 / 256 / 320
  List<int> supportedBitrates(AudioFormat format, {AudioInfo? input});

  /// Information about the input file (format, duration, sample rate, channels, bitrate)
  Future<AudioInfo> probe(String inputPath);
}
```

- Include the numbered-file-name resolution as a utility in the package (e.g. `resolveUniqueOutputPath(dir, baseName, format)`).
- Use typed exceptions for errors (e.g. `UnsupportedFormatException`, `UnsupportedBitrateException`, `CorruptedFileException`, `ConversionCancelledException`).
- Provide an example app in `example/` that runs on all OSes (Windows is verified here).
- Tests:
  - Verify the 5×5 conversion matrix on each OS (put short, self-made audio clips in `example/assets/fixtures/`)
  - Read the output back with `probe` and check format, duration (with tolerance), bitrate and sample rate
  - Make sure no temporary or partial output files remain after cancellation
  - Check the C wrapper for memory leaks (AddressSanitizer on macOS / Linux)
- pub.dev requirements: README (including the donation link), CHANGELOG, LICENSE, license notices for bundled libraries, and a check of the `pana` score.

### Step 2: `audio-converter-crossplatform-app` (iOS / iPadOS, macOS, Android)

- Add the Step 1 package as a dependency and implement the app.
- Use the display name and Bundle ID / Application ID from §2.1.
- Screens (minimum):
  1. File list (selected files with each file's format, duration and status)
  2. Output settings (format and bitrate; default 128 kbps)
  3. Conversion progress (per file and overall; cancel)
  4. Done (choose destination → save results; clearly show files that were given a number)
  5. About (licenses, privacy policy) — no donation link
- Selecting and saving files:
  - Convert in the app's temporary directory, then copy to the selected destination at the end
  - Android: write to a content URI via SAF (`ACTION_OPEN_DOCUMENT_TREE`)
  - iOS / iPadOS: folder selection / export with `UIDocumentPickerViewController` (security-scoped URLs)
  - macOS: directory selection with NSOpenPanel
- Languages: Japanese and English
- Put the donation link (Buy Me A Coffee) in the README.
- Provide a privacy policy page (stating that no data is collected).

---

## 8. Decisions and open items

### 8.1 Decisions

| # | Item | Decision |
|---|---|---|
| 1 | Conversion engine | Build a minimal FFmpeg from scratch and bundle it with the package |
| 2 | Dart bridge | `dart:ffi` (via my own C wrapper) |
| 3 | Binary distribution | CI build → stored in GitHub Releases → bundled at pub publish time (§6.2) |
| 4 | Bitrate | 128 / 192 / 256 / 320 kbps, default 128, narrowed per format |
| 5 | 3GP | Out of scope (input and output) |
| 6 | WAV output | Keep the input's sample rate and channel count (16-bit for compressed input) |
| 7 | Metadata | Not carried over in the initial version (planned for later) |
| 8 | Same-format conversion | Allowed |
| 9 | File name collisions | Append a number |
| 10 | Donation link | Not in the app; only in the GitHub README |
| 11 | Repository names | Package `su3_flutter_audio_converter` / app `audio-converter-crossplatform-app` |
| 12 | App display name | Audio Converter for Crossplatform |
| 13 | Bundle ID / Application ID | `su3hokkaido.audioconverter.com` |
| 14 | Store listing name and home-screen name | `Audio Converter by Su3` (the display name in #12 stays the long form) |
| 15 | Bundle ID / Application ID | Confirmed as `su3hokkaido.audioconverter.com` (cannot change after publishing) |
| 16 | WMA 320 kbps | Not provided. WMA offers 128 / 192 / 256 |
| 17 | C wrapper distribution | Compile `libsu3_audio_core` from source in each plugin build (CMake for Android/Windows, podspec for iOS/macOS). Reasons: it is small, avoids per-ABI wrapper binaries, matches the `plugin_ffi` template, and keeps debugging and AddressSanitizer simple. Only FFmpeg and LAME are prebuilt |
| 18 | Package license | MIT |
| 19 | Branch strategy and release tooling | `main` / `develop` with `feature/...` branches. changesets does not support Dart, so release-please (`dart` release type, Conventional Commits) is the planned tool; set up at the publish milestone |
| 20 | Lossy outputs and channels | MP3, M4A, AAC and WMA outputs are at most stereo; input with 3 or more channels is mixed down. WAV keeps the input channel count |
| 21 | Unsupported sample rates | When the encoder does not support the input sample rate, the nearest supported rate is used (e.g. 96 kHz -> 48 kHz for MP3 and WMA) |
| 22 | 8-bit PCM input | 8-bit PCM WAV input produces 16-bit WAV output (no 8-bit PCM encoder is built) |
| 23 | Windows FFmpeg build | `build/ffmpeg/build_windows.sh` run in MSYS2 with the MSVC toolchain (`--toolchain=msvc`, x64); LAME is compiled from its unmodified sources with `cl` and without SSE. Outputs go to the git-ignored `prebuilt/windows/{bin,lib,include}` |
| 24 | iOS minimum version | iOS 15.0 (raised from Flutter's 13.0, because Xcode 27 supports deployment targets from 15.0). Set in `build/versions.env`, the podspec and the example Podfile |
| 25 | Android build inputs | The prebuilt `.so` files are built with NDK 27.0.12077973 and API level 24 (`build/versions.env`); an app using a different NDK is accepted because the wrapper and FFmpeg use only the C API. `android/build.gradle` limits ABIs to arm64-v8a, armeabi-v7a and x86_64 (32-bit x86 is not built) |
| 26 | Prebuilt Release workflow | `.github/workflows/prebuilt.yml` builds each OS on its own runner and creates a GitHub Release on a `prebuilt-v<N>` tag (must equal `PREBUILT_TAG` in `build/versions.env`); `workflow_dispatch` only produces workflow artifacts. Release assets: `su3-prebuilt-{macos,ios,android,windows}.tar.gz` (repository-relative paths, extracted at the repository root by `tool/fetch_prebuilt.sh`), the FFmpeg and LAME source tarballs, `su3-build-scripts.tar.gz`, `BUILD-INFO.txt`, `SHA256SUMS`. Prebuilt tags are independent of the package version |
| 27 | First release | pub.dev package 0.1.0 with all four platforms; Windows is marked experimental in the README until it has run on a Windows machine. The 0.1.0 version and `CHANGELOG.md` come from release-please (forced with `release-as` in its config for the first release) (`.github/workflows/release-please.yml`); the publish itself is run by hand after `tool/fetch_prebuilt.sh`. `.pubignore` replaces `.gitignore` for publishing so the prebuilt libraries are included; `licenses/` holds the FFmpeg and LAME license texts |

### 8.2 Open items

None. All items were decided; see §8.1 #14 to #19.

---

## 9. Instructions for Claude Code (both repositories)

- Do not implement guesses for unclear points or spec branches; raise them as questions under §8.2.
- Do not add code or packages that access the network (CI at build time excepted).
- Do not add GPL or non-free dependencies. Report the license whenever you add a dependency.
- Start FFmpeg's configure from `--disable-everything`, and report the reason if you enable any component not listed in §5.3.
- Keep each OS's permission settings (Info.plist / entitlements / AndroidManifest) to the minimum.
- Keep `flutter analyze` and `flutter test` passing after every change.
- Always complete Step 0 (§10) and get Su's review before starting implementation.

---

## 10. Claude Code environment (created in Step 0)

### 10.1 Background

- Locations and formats (current Claude Code behavior):

| Type | Location | Format |
|---|---|---|
| Subagents | `.claude/agents/<name>.md` | YAML frontmatter (`name`, `description`, `tools`; `model` if needed) + body as the system prompt |
| Skills | `.claude/skills/<name>/SKILL.md` (+ supporting files) | YAML frontmatter (`name`, `description`; `disable-model-invocation: true` to make it user-only) + instructions |
| Hooks | Registered under `hooks` in `.claude/settings.json`. Scripts live in `.claude/hooks/` | Register a `matcher` and a command for events such as `PreToolUse` / `PostToolUse` / `Stop`. Exit code 2 blocks the action and stderr is returned to Claude |

- `.claude/hooks/` is not a directory Claude Code reads automatically. Use it as the place for scripts, and reference them from `settings.json` as `"$CLAUDE_PROJECT_DIR"/.claude/hooks/<script>`.
- The specification may change, so check the format against the official Claude Code docs (subagents, skills, hooks) before creating these files.
- The two repositories are published independently, so **create and commit `.claude/` in each repository** (shared items such as `code-reviewer` and the formatting hook go in both).
- Write hook scripts in bash + `jq`. If `jq` is missing, print a warning and let the action through (do not block development).
- `.claude/settings.local.json` is for personal settings. Add it to `.gitignore`.

### 10.2 Shared by both repositories

#### Agents

| name | Role | tools |
|---|---|---|
| `code-reviewer` | Reviews Dart / C changes for correctness, memory safety (C), error handling, and violations of the constraints in §5 and §9 (networking, GPL, unnecessary permissions). Every finding includes a suggested fix | Read, Grep, Glob (read-only) |

#### Hooks

| Event | matcher | Script | Behavior |
|---|---|---|---|
| PostToolUse | `Edit\|Write` | `format-on-save.sh` | Runs `dart format` on `.dart` files and `clang-format` (if available) on `.c` / `.h` files |
| PreToolUse | `Bash` | `guard-bash.sh` | Blocks irreversible actions: `pub publish` (except `--dry-run`), `git push --force`, and store upload commands |
| Stop | − | `verify-on-stop.sh` | If Dart files changed, runs `flutter analyze` and exits with 2 on failure so Claude keeps fixing. Does nothing when `stop_hook_active` in the input is true (prevents infinite loops) |

### 10.3 For `su3_flutter_audio_converter`

#### Agents (`.claude/agents/`)

| name | Role | tools |
|---|---|---|
| `ffmpeg-build-engineer` | Writes and maintains the FFmpeg / LAME cross-compile scripts (iOS / macOS XCFramework, Android NDK, Windows MSYS2 / MSVC) and the GitHub Actions workflows. Strictly follows the minimal configuration in §5.3 and the license constraints in §5.4 | Read, Edit, Write, Bash, Grep, Glob |
| `ffi-native-engineer` | Implements the C wrapper (`libsu3_audio_core`), the `ffigen` setup, progress notification via `NativeCallable.listener`, cancellation and memory management | Read, Edit, Write, Bash, Grep, Glob |
| `audio-test-engineer` | 5×5 conversion matrix tests, bitrate constraint tests, cancellation and temp-file cleanup tests, and generating test audio clips (self-made, short) | Read, Edit, Write, Bash, Grep, Glob |
| `license-auditor` | Audits the licenses of FFmpeg configure options, bundled libraries and pubspec dependencies. Checks for GPL / nonfree, missing license notices and LGPL dynamic-linking requirements, and reports (does not fix) | Read, Grep, Glob, Bash |

#### Skills (`.claude/skills/`)

| name | Content | Invoked by |
|---|---|---|
| `ffmpeg-build` | Per-OS build steps, the configure options matching §5.3 (supporting file `configure-flags.md`), where artifacts go (§6.3), and measuring size after the build | Claude / user |
| `regenerate-bindings` | Regenerates the bindings with `ffigen` after a C header change, reviews the diff and runs `flutter analyze` | Claude / user |
| `conversion-matrix-test` | Runs the 5×5 × bitrate conversions and reports the `probe` results as a table | Claude / user |
| `add-audio-format` | Steps for adding a format (`AudioFormat`, configure options, bitrate table, tests, README). For adding 3GP later | User only |
| `release-package` | Pre-publish checks for pub.dev: CHANGELOG and version, binaries fetched, `licenses/` updated, `pana`, `dart pub publish --dry-run`. **Su runs the actual publish manually** | User only (`disable-model-invocation: true`) |

#### Hooks (in addition to the shared ones)

| Event | matcher | Script | Behavior |
|---|---|---|---|
| PreToolUse | `Bash` | `guard-bash.sh` (extends the shared version) | Blocks commands containing `--enable-gpl` / `--enable-nonfree` / `libfdk` |
| PreToolUse | `Edit\|Write` | `guard-protected-files.sh` | Blocks direct edits to generated code (ffigen output) and bundled binaries (`*.xcframework`, `jniLibs/`, `*.dll`). They must be updated by regenerating or rebuilding |
| PostToolUse | `Edit\|Write` | `check-dependencies.sh` | When `pubspec.yaml` changes, lists the added dependencies and prompts a license check |

### 10.4 For `audio-converter-crossplatform-app`

#### Agents (`.claude/agents/`)

| name | Role | tools |
|---|---|---|
| `flutter-ui-engineer` | The screens from Step 2 in §7, state management, progress and cancel UI, bitrate selection (driven by `supportedBitrates`), Japanese and English localization | Read, Edit, Write, Bash, Grep, Glob |
| `platform-integration-engineer` | File selection and destination selection (SAF, security-scoped URLs, NSOpenPanel), temp-file management, numbered file names, macOS sandbox settings | Read, Edit, Write, Bash, Grep, Glob |
| `store-release-reviewer` | Pre-submission audit (does not fix): permissions (INTERNET, etc.), entitlements, Apple's privacy manifest, App Privacy / Data safety answers, any in-app donation or external-payment links, listing-name length, Bundle ID / Application ID | Read, Grep, Glob |

#### Skills (`.claude/skills/`)

| name | Content | Invoked by |
|---|---|---|
| `add-l10n-string` | Adds strings to the ARB files (ja / en) and runs `flutter gen-l10n` | Claude / user |
| `platform-permission-audit` | Lists the permissions in Info.plist, entitlements and AndroidManifest, and reports differences from the least-privilege policy in §4 | Claude / user |
| `store-release-check` | Runs the pre-submission checklist with `store-release-reviewer` and reports the results | User only |
| `release-build` | Release build steps for iOS (ipa), macOS and Android (aab), plus post-build checks. **Su uploads to the stores manually** | User only (`disable-model-invocation: true`) |

#### Hooks (in addition to the shared ones)

| Event | matcher | Script | Behavior |
|---|---|---|---|
| PreToolUse | `Edit\|Write` | `guard-offline-policy.sh` | Blocks: adding `android.permission.INTERNET` to `android/app/src/main/AndroidManifest.xml`, adding network entitlements to `macos/Runner/Release.entitlements`, and adding donation links such as `buymeacoffee` under `lib/` |

- The Flutter template's `src/debug` / `src/profile` AndroidManifest files and `DebugProfile.entitlements` already contain network settings for hot reload. Exclude them from blocking (protect only the release settings).

### 10.5 Example files

#### Subagent (`.claude/agents/license-auditor.md`)

```markdown
---
name: license-auditor
description: Audits the licenses of FFmpeg configure options, bundled binaries and pubspec dependencies. Use when adding dependencies, changing build scripts, or before a release.
tools: Read, Grep, Glob, Bash
---

You are the open-source license auditor. You only report; you do not make changes.

Check:
1. FFmpeg's configure does not include --enable-gpl / --enable-nonfree / libfdk-aac
2. Enabled components stay within audio-converter-context.en.md §5.3
3. FFmpeg / LAME are dynamically linked (LGPL relinking requirement)
4. licenses/ and the README list each bundled component's license, version and source location
5. The license of every dependency in pubspec.yaml (report any GPL-family license as critical)

Report the results as a table of "OK / Needs fixing (with severity)".
```

#### Skill (`.claude/skills/release-package/SKILL.md`)

```markdown
---
name: release-package
description: Runs the pre-publish checks for su3_flutter_audio_converter on pub.dev
disable-model-invocation: true
---

1. Check that CHANGELOG.md and the version in pubspec.yaml match
2. Check with tool/fetch_prebuilt.sh that binaries for all OSes are present
3. Run the audit with the license-auditor subagent
4. Run `flutter analyze` and `flutter test`
5. Run `dart pub global run pana` and report any lost points
6. Run `dart pub publish --dry-run` and report the package size and warnings

Do not run the actual `dart pub publish`. Summarize the results for Su and stop.
```

#### Hook registration (`.claude/settings.json`, package)

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{ "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/guard-bash.sh" }]
      },
      {
        "matcher": "Edit|Write",
        "hooks": [{ "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/guard-protected-files.sh" }]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/format-on-save.sh" },
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/check-dependencies.sh" }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [{ "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/verify-on-stop.sh" }]
      }
    ]
  }
}
```

#### Hook script (`.claude/hooks/guard-bash.sh`, package)

```bash
#!/usr/bin/env bash
# PreToolUse(Bash): block irreversible actions and commands that would break the license policy
set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "warning: jq not found, skipping guard-bash.sh" >&2
  exit 0
fi

cmd=$(jq -r '.tool_input.command // ""')

block() { echo "BLOCKED: $1" >&2; exit 2; }

case "$cmd" in
  *--enable-gpl*|*--enable-nonfree*|*libfdk*)
    block "GPL / nonfree components are not allowed (§5.4)" ;;
esac

if echo "$cmd" | grep -Eq '(dart|flutter) pub publish' && ! echo "$cmd" | grep -q -- '--dry-run'; then
  block "Su runs pub publish manually. Only --dry-run is allowed"
fi

if echo "$cmd" | grep -Eq 'git push.*(--force|-f( |$))'; then
  block "Force push is not allowed"
fi

exit 0
```

- Make the scripts executable (`chmod +x .claude/hooks/*.sh`).
- After creating each hook, feed it test input JSON and confirm both the cases that should be blocked and the cases that should pass.
