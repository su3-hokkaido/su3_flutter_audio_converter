#!/usr/bin/env bash
# Regenerates test/fixtures/tone.{wav,mp3,wma,m4a,aac} (see test/fixtures/README.md).
#
# WAV, MP3 and WMA come from tool/make_fixtures.c, which links the package's native core against
# the prebuilt macOS FFmpeg libraries. M4A and AAC (ADTS) are made from the WAV with the macOS
# /usr/bin/afconvert, so they are real-world encoder output rather than our own encoder's.
#
# Needs build/ffmpeg/build_macos.sh and package_macos.sh to have been run.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
lib="$root/build/work/out/macos/lib"
include="$root/prebuilt/include"
out="$root/test/fixtures"
work="$root/build/work/fixtures"

[ -d "$lib" ] || { echo "error: run build/ffmpeg/build_macos.sh first" >&2; exit 1; }
[ -d "$include" ] || { echo "error: run build/ffmpeg/package_macos.sh first" >&2; exit 1; }

mkdir -p "$out" "$work"
clang -std=c11 -O1 -Wall -Wextra -I"$include" \
  "$root/src/su3_flutter_audio_converter.c" "$root/tool/make_fixtures.c" \
  -L"$lib" -lavformat -lavcodec -lswresample -lavutil -lm \
  -Wl,-rpath,"$lib" -o "$work/make_fixtures"
"$work/make_fixtures" "$out"

rm -f "$out/tone.m4a" "$out/tone.aac"
/usr/bin/afconvert -f m4af -d aac -b 64000 "$out/tone.wav" "$out/tone.m4a"
/usr/bin/afconvert -f adts -d aac -b 64000 "$out/tone.wav" "$out/tone.aac"

ls -l "$out"
