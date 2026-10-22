#!/usr/bin/env bash
# PreToolUse(Edit|Write): block direct edits to generated code (ffigen output) and bundled binaries.
# They must be updated by regenerating (ffigen) or rebuilding (build/ffmpeg scripts).
set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "warning: jq not found, skipping guard-protected-files.sh" >&2
  exit 0
fi

file=$(jq -r '.tool_input.file_path // ""')
[ -z "$file" ] && exit 0

block() { echo "BLOCKED: $1 ($file)" >&2; exit 2; }

case "$file" in
  *_bindings_generated.dart|*.g.dart)
    block "Generated ffigen output; change the C header and run the regenerate-bindings skill" ;;
  *.xcframework|*.xcframework/*)
    block "Bundled binary; rebuild with build/ffmpeg scripts or fetch with tool/fetch_prebuilt.sh" ;;
  */jniLibs/*)
    block "Bundled binary; rebuild with build/ffmpeg scripts or fetch with tool/fetch_prebuilt.sh" ;;
  *.dll|*.so|*.dylib|*.a)
    block "Bundled binary; rebuild with build/ffmpeg scripts or fetch with tool/fetch_prebuilt.sh" ;;
esac

exit 0
