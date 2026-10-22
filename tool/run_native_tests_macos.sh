#!/usr/bin/env bash
# Build and run the native tests (test/native/) against the prebuilt macOS FFmpeg libraries.
# The wrapper and the test program are compiled with AddressSanitizer and UndefinedBehaviorSanitizer
# (docs/project_plan.md section 7, Step 1: check the C wrapper for memory leaks).
#
# Needs build/ffmpeg/build_macos.sh to have been run. Only the host architecture is built.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
lib="$root/build/work/out/macos/lib"
include="$root/prebuilt/include"
work="$root/build/work/native-tests"

[ -d "$lib" ] || { echo "error: run build/ffmpeg/build_macos.sh first" >&2; exit 1; }
[ -d "$include" ] || { echo "error: run build/ffmpeg/package_macos.sh first (it copies the headers)" >&2; exit 1; }

mkdir -p "$work"

compile() { # compile <output> <extra flags...>
  local output="$1"; shift
  clang -std=c11 -g -O1 -Wall -Wextra -Wno-unused-parameter -fno-omit-frame-pointer \
    "$@" -I"$include" \
    "$root/src/su3_flutter_audio_converter.c" "$root/test/native/test_convert.c" \
    -L"$lib" -lavformat -lavcodec -lswresample -lavutil -lm \
    -Wl,-rpath,"$lib" \
    -o "$output"
}

if [ "${1:-}" = "--leaks" ]; then
  # LeakSanitizer does not exist for Apple-silicon macOS, and ASan hides the heap from the system
  # `leaks` tool, so this mode builds without sanitizers and lets `leaks` inspect the process.
  compile "$work/test_convert_leaks"
  cat > "$work/get-task-allow.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>
PLIST
  codesign --force --sign - --entitlements "$work/get-task-allow.plist" "$work/test_convert_leaks"
  MallocStackLogging=1 leaks --atExit -- "$work/test_convert_leaks" "$work"
else
  compile "$work/test_convert" -fsanitize=address,undefined
  "$work/test_convert" "$work"
fi
