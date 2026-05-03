#!/usr/bin/env bash
# Block Edit/Write/MultiEdit on src/** while on an issue branch (^[0-9]+-)
# until /tdd has been invoked in the current Claude Code session.
# See docs/adr/0009-mechanical-tdd-gate.md.
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "tdd-gate: jq not in PATH; allowing edit (harness self-disabled)" >&2
  exit 0
fi

payload=$(cat)
file_path=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty')
transcript_path=$(printf '%s' "$payload" | jq -r '.transcript_path // empty')

[[ -z "$file_path" ]] && exit 0

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

case "$file_path" in
  "$repo_root"/*) rel_path="${file_path#"$repo_root"/}" ;;
  /*) exit 0 ;;
  *) rel_path="$file_path" ;;
esac

case "$rel_path" in
  src/*) ;;
  *) exit 0 ;;
esac

branch=$(git -C "$repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null) || exit 0
[[ "$branch" =~ ^[0-9]+- ]] || exit 0

[[ -n "$transcript_path" && -r "$transcript_path" ]] || exit 0

if jq -r '.message.content[]? | select(.type == "tool_use" and .name == "Skill" and .input.skill == "tdd") | "found"' "$transcript_path" 2>/dev/null | grep -q .; then
  exit 0
fi

cat >&2 <<EOF
Edit blocked: $rel_path is under src/ on issue branch $branch.

ADR 0009 requires /tdd invocation before any source-code edit on an issue
branch. Invoke /tdd to start the red-green-refactor cycle — you will be
prompted to confirm the test list and interface design first — then
re-attempt this edit.
EOF
exit 2
