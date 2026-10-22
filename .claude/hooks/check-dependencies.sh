#!/usr/bin/env bash
# PostToolUse(Edit|Write): when pubspec.yaml changes, list added dependency lines and ask Claude to
# check their licenses (project_plan.md §9: report the license of every added dependency).
set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "warning: jq not found, skipping check-dependencies.sh" >&2
  exit 0
fi

file=$(jq -r '.tool_input.file_path // ""')
case "$file" in
  */pubspec.yaml|pubspec.yaml) ;;
  *) exit 0 ;;
esac

added=$(git diff -U0 -- "$file" 2>/dev/null | grep -E '^\+[[:space:]]+[a-z_0-9]+:' | sed 's/^+//' || true)
[ -z "$added" ] && exit 0

msg="pubspec.yaml changed. Added or changed entries:
$added
Report the license of each new dependency (pub.dev page) and flag any GPL-family license. Consider running the license-auditor agent."

jq -n --arg msg "$msg" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $msg}}'
exit 0
