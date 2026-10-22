# M6: build the prebuilt libraries in GitHub Actions and store them in Releases

Scope: `docs/project_plan.md` §7 Step 1 milestone 6 and §6.2 steps 2, 3 and 5. Bundling into the pub
package (§6.2 step 4, `.pubignore`) belongs to M7.

STATUS: the workflow has not been run. `tool/fetch_prebuilt.sh` and `package_release.sh` were tested
locally against the macOS, iOS and Android builds (including a checksum mismatch and a missing
asset). The Windows job runs `build_windows.sh`, which has never been run either.

## Decisions (Su, 2026-10-22; recorded as §8.1 #26)

- Release tags are dedicated `prebuilt-v<N>`, independent of the package version. `PREBUILT_TAG` in
  `build/versions.env` names the Release a commit uses; bump `N` whenever the FFmpeg/LAME versions,
  configure options or deployment targets change.
- Triggers: push of a `prebuilt-v*` tag (build and create the Release) and `workflow_dispatch`
  (build only, archives kept as workflow artifacts for 14 days).

## Files

- `.github/workflows/prebuilt.yml`: jobs `macos`, `ios`, `android`, `windows` (one runner each) and
  `release` (tag pushes only, after all four succeed).
- `build/ffmpeg/package_release.sh <platform>`: `build/work/release/su3-prebuilt-<platform>.tar.gz`
  with repository-relative paths.
- `tool/fetch_prebuilt.sh [platform...]`: downloads `SHA256SUMS` and the archives of the Release
  named by `PREBUILT_TAG`, verifies them and extracts at the repository root.
  `SU3_PREBUILT_BASE_URL` overrides the location (used for testing against local files).
- `build/versions.env`: `PREBUILT_REPO`, `PREBUILT_TAG`.

## Release contents

| Asset | Content |
|---|---|
| `su3-prebuilt-macos.tar.gz` | `macos/Frameworks/*.xcframework`, `prebuilt/include` |
| `su3-prebuilt-ios.tar.gz` | `ios/Frameworks/*.xcframework`, `prebuilt/include` |
| `su3-prebuilt-android.tar.gz` | `android/src/main/jniLibs/<abi>/*.so`, `prebuilt/include` |
| `su3-prebuilt-windows.tar.gz` | `prebuilt/windows/{bin,lib,include}` |
| `ffmpeg-<v>.tar.xz`, `lame-<v>.tar.gz` | the exact sources (checksum verified by `fetch_sources.sh`) |
| `su3-build-scripts.tar.gz` | `build/` (scripts, `versions.env`) and `LICENSE` at the tagged commit |
| `BUILD-INFO.txt` | LGPL statement, commit, how to rebuild (also the Release notes) |
| `SHA256SUMS` | checksums of all of the above |

Every platform archive also contains `prebuilt/licenses/{ffmpeg,lame}/` (the LGPL texts and `LICENSE.md`
from the verified source tarballs; added after the license audit). The `licenses/` directory and the
README component table of §5.4 are still M7 work.

Local archive sizes: macOS 2.4 MB, iOS 3.4 MB, Android 3.5 MB (Windows not measured).

## Job notes

- macOS also runs `tool/run_native_tests_macos.sh` (ASan/UBSan) against the fresh libraries.
- Android installs the NDK from `build/versions.env` with `sdkmanager`.
- Windows: `git config core.autocrlf false` before checkout (the scripts need LF),
  `ilammy/msvc-dev-cmd` (x64), then `msys2/setup-msys2` with `path-type: inherit`. The build step
  puts the directory of `cl` first on PATH so that `build_windows.sh` sees the MSVC `link.exe`
  instead of MSYS2's `/usr/bin/link`. The log and FFmpeg's `config.log` are uploaded even on
  failure. Expect fixes here; iterate with `workflow_dispatch` before pushing the tag.
- The `release` job refuses a tag that differs from `PREBUILT_TAG`, so a Release always matches the
  `versions.env` of the commit that was built.
- Actions are pinned by commit SHA like the existing workflows (Dependabot keeps them current).
  Tags were resolved with `git ls-remote`; the one-before-latest release of each was chosen.

## Review follow-ups

- `fetch_prebuilt.sh` checks every archive member before extracting (allowed prefixes per platform,
  no absolute or `..` paths, relative link targets only) and uses `--proto =https`.
- `su3-build-scripts.tar.gz` also holds `tool/`.
- A tag is used once; a failed `release` job needs the tag deleted (or `prebuilt-v<N+1>`), so the
  build must be tried with `workflow_dispatch` first. Not done: Release without Windows.
- Not done: removing files that a newer Release dropped (extraction only overwrites); delete the
  git-ignored directories before fetching when that matters.

## Integrity

`SHA256SUMS` comes from the same Release as the archives, so `fetch_prebuilt.sh` detects corrupted
downloads but not a tampered Release. Pinning per-asset hashes in the repository would need a
commit after every Release; not done.

## Steps for Su (maintainer actions, not run by Claude)

1. Merge this change into `develop` (the workflow runs from the default branch for
   `workflow_dispatch`; if it is not listed in the Actions tab yet, it must reach `main`).
2. Run the **Prebuilt** workflow manually; fix the Windows job first if it fails.
3. Tag the commit and push the tag; the Release is created by the workflow:
   `git tag prebuilt-v1 && git push origin prebuilt-v1`.
4. Check the Release assets and try `tool/fetch_prebuilt.sh` on a clean checkout.

## Not covered

- Fetching the prebuilt libraries in `ci.yml` and running the integration tests there: the
  integration tests need devices or emulators, so CI keeps format, analyze and unit tests.
- `.pubignore`, `licenses/` and the publish workflow (M7).
