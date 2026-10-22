#!/usr/bin/env bash
# PostToolUse(Edit|Write): format .dart with `dart format` and .c/.h with clang-format (if available)
set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "warning: jq not found, skipping format-on-save.sh" >&2
  exit 0
fi

file=$(jq -r '.tool_input.file_path // ""')
[ -z "$file" ] && exit 0
[ -f "$file" ] || exit 0

case "$file" in
  *.dart)
    # Generated bindings are never reformatted by hand
    case "$file" in
      *_bindings_generated.dart|*.g.dart) exit 0 ;;
    esac
    if command -v dart >/dev/null 2>&1; then
      dart format "$file" >/dev/null 2>&1 || true
    else
      echo "warning: dart not found, skipping format" >&2
    fi
    ;;
  *.c|*.h)
    if command -v clang-format >/dev/null 2>&1; then
      clang-format -i "$file" >/dev/null 2>&1 || true
    fi
    ;;
esac

exit 0
