#!/usr/bin/env bash
# Download the pinned FFmpeg and LAME source tarballs into build/work/src and verify their SHA-256.
# Network access happens here at build time only (docs/project_plan.md section 9).
#
#   build/ffmpeg/fetch_sources.sh                    download and verify
#   build/ffmpeg/fetch_sources.sh --print-checksums  download and print the checksums to pin
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../versions.env
source "$root/build/versions.env"
src="$root/build/work/src"
mkdir -p "$src"

print_only=false
[ "${1:-}" = "--print-checksums" ] && print_only=true

sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }

fetch() {
  local name="$1" url="$2" expected="$3"
  local file="$src/$(basename "$url")"
  [ -f "$file" ] || curl -fL --retry 3 -o "$file" "$url"
  local actual
  actual="$(sha256 "$file")"
  if $print_only; then
    echo "${name}_SHA256=$actual"
  elif [ -z "$expected" ]; then
    echo "error: ${name}_SHA256 is empty in build/versions.env (actual: $actual)" >&2
    exit 1
  elif [ "$actual" != "$expected" ]; then
    echo "error: checksum mismatch for $file (expected $expected, actual $actual)" >&2
    exit 1
  else
    echo "ok: $file"
  fi
}

fetch FFMPEG "$FFMPEG_URL" "$FFMPEG_SHA256"
fetch LAME "$LAME_URL" "$LAME_SHA256"
