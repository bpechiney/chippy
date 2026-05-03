#!/usr/bin/env bash
# After a `gh pr merge` Bash call returns, if the current branch's PR is now
# MERGED, automatically: checkout master, fetch+pull --rebase, delete the merged
# local branch. See docs/adr/0011-mechanical-branch-discipline-gate.md.
set -euo pipefail

if ! command -v jq >/dev/null 2>&1 || ! command -v gh >/dev/null 2>&1; then
  echo "post-merge-cleanup: jq or gh missing; skipping (harness self-disabled)" >&2
  exit 0
fi

payload=$(cat)
command_str=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')

[[ -z "$command_str" ]] && exit 0
[[ "$command_str" == *"gh pr merge"* ]] || exit 0

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$repo_root" || exit 0

branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || exit 0
[[ "$branch" == "master" ]] && exit 0

pr_state=$(gh pr view "$branch" --json state -q .state 2>/dev/null) || {
  echo "post-merge-cleanup: could not fetch PR state for $branch; skipping" >&2
  exit 0
}

[[ "$pr_state" == "MERGED" ]] || exit 0

if [[ -n "$(git status --porcelain)" ]]; then
  echo "post-merge-cleanup: working tree dirty on $branch; skipping. Stash or commit, then run cleanup manually." >&2
  exit 0
fi

echo "post-merge-cleanup: $branch is MERGED — running cleanup" >&2

git checkout master
git fetch origin --prune

if ! git pull --rebase origin master; then
  echo "post-merge-cleanup: rebase conflict on master; aborting rebase. Branch $branch NOT deleted." >&2
  git rebase --abort 2>/dev/null || true
  exit 0
fi

git branch -D "$branch"
echo "post-merge-cleanup: master is current; $branch deleted." >&2
exit 0
