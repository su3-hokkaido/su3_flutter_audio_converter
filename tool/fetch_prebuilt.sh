#!/usr/bin/env bash
# Download the prebuilt FFmpeg and LAME libraries from the GitHub Release named by PREBUILT_TAG in
# build/versions.env and extract them into the repository (docs/project_plan.md section 6.2).
# The binaries are git-ignored; this is the development-time alternative to building them locally.
#
#   tool/fetch_prebuilt.sh                    all platforms
#   tool/fetch_prebuilt.sh macos ios          only the listed platforms (macos ios android windows)
#
# The archives are checked against the SHA256SUMS file of the same Release. That detects corrupted
# downloads; it does not protect against a tampered Release, so build locally when that matters.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../build/versions.env
source "$root/build/versions.env"

platforms=("$@")
[ ${#platforms[@]} -gt 0 ] || platforms=(macos ios android windows)

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# SU3_PREBUILT_BASE_URL overrides the location (used to test this script against local files).
base="${SU3_PREBUILT_BASE_URL:-https://github.com/$PREBUILT_REPO/releases/download/$PREBUILT_TAG}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# HTTPS only; file:// is allowed solely when the location is overridden for local tests.
proto='=https'
[ -z "${SU3_PREBUILT_BASE_URL:-}" ] || proto='=https,file'
fetch() { curl -fsSL --retry 3 --proto "$proto" -o "$2" "$1"; }

# Refuse an archive that would write outside the directories of its platform (the checksum comes
# from the same Release, so it does not vouch for the content).
check_members() { # check_members <archive> <platform>
  local archive="$1" platform="$2" member target
  while IFS= read -r member; do
    case "$member" in /*|*..*) echo "error: unsafe path '$member' in $archive" >&2; return 1 ;; esac
    case "$platform:$member" in
      macos:macos/Frameworks|macos:macos/Frameworks/*) ;;
      ios:ios/Frameworks|ios:ios/Frameworks/*) ;;
      android:android|android:android/src|android:android/src/main|android:android/src/main/jniLibs|android:android/src/main/jniLibs/*) ;;
      *:prebuilt|*:prebuilt/*) ;;
      *) echo "error: unexpected path '$member' in $archive" >&2; return 1 ;;
    esac
  done < <(tar -tzf "$archive")
  # Symbolic links (macOS frameworks) must stay relative and inside the archive.
  while IFS= read -r target; do
    case "$target" in /*|*..*) echo "error: unsafe link target '$target' in $archive" >&2; return 1 ;; esac
  done < <(tar -tvzf "$archive" | awk '/^l/ {for (i = 1; i <= NF; i++) if ($i == "->") {print $(i + 1); break}}')
}

fetch "$base/SHA256SUMS" "$tmp/SHA256SUMS"

for platform in "${platforms[@]}"; do
  case "$platform" in
    macos|ios|android|windows) ;;
    *) echo "error: unknown platform $platform" >&2; exit 1 ;;
  esac
  name="su3-prebuilt-$platform.tar.gz"
  fetch "$base/$name" "$tmp/$name"
  expected="$(awk -v n="$name" '$2 == n || $2 == "*" n {print $1}' "$tmp/SHA256SUMS")"
  [ -n "$expected" ] || { echo "error: $name is not listed in SHA256SUMS" >&2; exit 1; }
  actual="$(sha256 "$tmp/$name")"
  if [ "$actual" != "$expected" ]; then
    echo "error: checksum mismatch for $name (expected $expected, actual $actual)" >&2
    exit 1
  fi
  check_members "$tmp/$name" "$platform"
  tar -xzf "$tmp/$name" -C "$root"
  echo "ok: $name ($PREBUILT_TAG)"
done
