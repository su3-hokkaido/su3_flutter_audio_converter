# M7: prepare the first pub.dev release

Scope: `docs/project_plan.md` §7 Step 1 milestone 7 and §6.2 step 4. Claude prepares the package and
runs only `flutter pub publish --dry-run`; Su runs the actual publish (CLAUDE.md, mutation policy).

## Decisions (Su, 2026-10-22; recorded as §8.1 #27)

- Versioning through release-please (decision #19); publishing to pub.dev stays manual.
- Windows is included in the first release, marked "experimental" in the README: the build is
  checked in CI (`prebuilt.yml`), but nothing has run on a Windows machine.
- First version: 0.1.0.

## What was added

- `licenses/`: license texts of FFmpeg (`COPYING.LGPLv2.1`, `COPYING.LGPLv3`, `LICENSE.md`) and LAME
  (`COPYING`, `LICENSE`) taken from the checksum-verified source tarballs, and `licenses/README.md`
  (versions, licenses, source URLs, relinking notes). README has the same component table.
- `.pubignore`: pub reads it instead of `.gitignore`, so the git-ignored prebuilt libraries
  (`ios/Frameworks`, `macos/Frameworks`, `android/src/main/jniLibs`, `prebuilt/`) are published. It
  excludes `docs/`, `.claude/`, `.github/`, `CLAUDE.md`, the release-please files, generated build
  output (`/build/*` except `build/ffmpeg` and `build/versions.env`, which stay for the LGPL rebuild
  notes) and the example app's generated `.symlinks`, `ephemeral`, `Pods`, `build` (`.symlinks`
  points back at the package and would duplicate the binaries).
- `pubspec.yaml`: `funding` (Buy Me A Coffee) and `topics`.
- `README.md`: install section, minimum OS versions, Windows note, license table; the "work in
  progress" notes are gone.
- `release-please-config.json`, `.release-please-manifest.json` (`0.0.1`) and
  `.github/workflows/release-please.yml`: on every push to `main` it opens or updates the release PR
  (bumps `pubspec.yaml`, writes `CHANGELOG.md`); merging it tags `v0.1.0` and creates the GitHub
  Release. It does not publish.

## Checks run

| Check | Result |
|---|---|
| `flutter pub publish --dry-run` | package 13 MB compressed (macOS, iOS, Android binaries; Windows not fetched yet). Only warning: uncommitted changes |
| `pana` 0.23.12 (on a copy without the example's generated symlinks) | 160/160; platforms Android, iOS, macOS, Windows |
| Contents of the archive | prebuilt libraries, `licenses/`, build scripts included; `docs/`, `.claude/`, `.github/`, generated output excluded |

`pana` run directly on the working tree recurses through `example/ios/.symlinks` and fills the disk;
run it on a clean copy (or after deleting the example's generated directories).

## Release procedure (Su; Claude does not run these)

1. Commit and merge this work through `develop` and `main` as usual.
2. Prebuilt libraries: run the **Prebuilt** workflow manually, fix the Windows job if needed, then
   `git tag prebuilt-v1 && git push origin prebuilt-v1` (see
   `docs/2026-10-22_06_m6-prebuilt-release/design.md`).
3. Release PR: the Release Please workflow opens it on `main`. It needs the repository setting
   Settings > Actions > General > "Allow GitHub Actions to create and approve pull requests" (or the
   `RELEASE_TOKEN` secret). `release-please-config.json` forces `"release-as": "0.1.0"` because the
   history so far is not Conventional Commits. `CHANGELOG.md` is reset to a bare heading, and the
   generated 0.1.0 entry will be nearly empty for the same reason: edit the release PR to list the
   features (all 5x5 conversions, probe, supportedBitrates, cancellation and progress, unique output
   names, four platforms with Windows experimental).
4. Merge the release PR; the tag `v0.1.0` and a GitHub Release appear. Then remove `release-as` from
   `release-please-config.json` (later versions come from the commits) and merge `main` back into
   `develop`.
5. On the tagged commit: `tool/fetch_prebuilt.sh`, then check
   `flutter pub publish --dry-run` (all four platforms present, size, no warnings besides the
   expected ones).
6. Publish by hand with `flutter pub publish`.

## Risks and open points

- The Windows prebuilt libraries do not exist until the Prebuilt workflow has passed; the Windows
  CMake build fails with a clear message without them, so publishing before that breaks Windows
  users (and the pana "Windows" tag would not reflect reality).
- `pub.dev` is the first place where the plugin gets built by other people's toolchains
  (CocoaPods lint, Gradle, MSVC). Consider `flutter pub publish` only after `pod lib lint` and a
  fresh app that depends on the package by path.
- release-please behaviour with the merge-commit history and `release-as` was not exercised.
