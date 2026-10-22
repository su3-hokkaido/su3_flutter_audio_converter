#!/usr/bin/env bash
# PreToolUse(Bash): block irreversible actions and commands that would break the license policy
set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "warning: jq not found, skipping guard-bash.sh" >&2
  exit 0
fi

cmd=$(jq -r '.tool_input.command // ""')

block() { echo "BLOCKED: $1" >&2; exit 2; }

case "$cmd" in
  *--enable-gpl*|*--enable-nonfree*|*libfdk*)
    block "GPL / nonfree components are not allowed (project_plan.md §5.4)" ;;
esac

if echo "$cmd" | grep -Eq '(dart|flutter) pub publish' && ! echo "$cmd" | grep -q -- '--dry-run'; then
  block "Su runs pub publish manually. Only --dry-run is allowed"
fi

if echo "$cmd" | grep -Eq 'git push.*(--force|-f( |$))'; then
  block "Force push is not allowed"
fi

# Store upload commands (App Store Connect / Google Play)
if echo "$cmd" | grep -Eq '(xcrun (altool|notarytool)|fastlane (deliver|supply|pilot)|bundletool .*upload|transporter)'; then
  block "Store uploads are done manually by Su"
fi

exit 0
