#!/usr/bin/env bash
# Block Edit/Write/MultiEdit when on master, or when current branch's upstream
# is [gone] (i.e., the branch was merged and the remote was deleted).
# See docs/adr/0011-mechanical-branch-discipline-gate.md.
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "branch-discipline: jq not in PATH; allowing edit (harness self-disabled)" >&2
  exit 0
fi

payload=$(cat)
file_path=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty')

[[ -z "$file_path" ]] && exit 0

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

case "$file_path" in
  "$repo_root"/*) ;;
  /*) exit 0 ;;
  *) ;;
esac

branch=$(git -C "$repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null) || exit 0

if [[ "$branch" == "master" ]]; then
  cat >&2 <<EOF
Edit blocked: you are on master.

If addressing an issue:
  git fetch origin && git checkout -b <issue-number>-<slug> origin/master

If this is an organic discovery (no issue yet):
  1. File an issue first:  gh issue create
  2. Branch as N-slug:     git fetch origin && git checkout -b <N>-<slug> origin/master

Per CLAUDE.md per-PR loop step 1 and ADR 0011.
EOF
  exit 2
fi

upstream_status=$(git -C "$repo_root" for-each-ref --format='%(upstream:track)' "refs/heads/$branch" 2>/dev/null) || exit 0

if [[ "$upstream_status" == "[gone]" ]]; then
  cat >&2 <<EOF
Edit blocked: branch $branch was merged (upstream is [gone]).

Run cleanup:
  git checkout master && git fetch origin --prune && git pull --rebase origin master && git branch -D $branch

Per ADR 0011.
EOF
  exit 2
fi

exit 0
