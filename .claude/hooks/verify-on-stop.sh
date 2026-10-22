#!/usr/bin/env bash
# Stop: if Dart files changed, run `flutter analyze`; exit 2 on failure so Claude keeps fixing.
set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "warning: jq not found, skipping verify-on-stop.sh" >&2
  exit 0
fi

input=$(cat)

# Prevent infinite loops: do nothing when this Stop was already triggered by a Stop hook
if [ "$(echo "$input" | jq -r '.stop_hook_active // false')" = "true" ]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0

# Nothing to analyze until the package is scaffolded
[ -f pubspec.yaml ] || exit 0

# Only when Dart files are modified, staged or untracked (read-only git)
if ! git status --porcelain 2>/dev/null | grep -Eq '\.dart$'; then
  exit 0
fi

if ! command -v flutter >/dev/null 2>&1; then
  echo "warning: flutter not found, skipping flutter analyze" >&2
  exit 0
fi

if ! out=$(flutter analyze 2>&1); then
  echo "flutter analyze failed. Fix the issues below:" >&2
  echo "$out" | tail -n 60 >&2
  exit 2
fi

exit 0
