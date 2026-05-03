#!/usr/bin/env bash
# At session start (and on /clear, resume), fetch origin and if the current
# branch is merged (PR=MERGED or upstream=[gone]), auto-cleanup: checkout
# master, pull --rebase, delete the merged branch. Output goes to stdout and
# is injected into the model's context per Claude Code SessionStart semantics.
# See docs/adr/0011-mechanical-branch-discipline-gate.md.
set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0
command -v gh >/dev/null 2>&1 || exit 0

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$repo_root" || exit 0

branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || exit 0

git fetch --prune origin >/dev/null 2>&1 || exit 0

[[ "$branch" == "master" ]] && exit 0

upstream_status=$(git for-each-ref --format='%(upstream:track)' "refs/heads/$branch" 2>/dev/null) || exit 0

merged=0
if [[ "$upstream_status" == "[gone]" ]]; then
  merged=1
else
  pr_state=$(gh pr view "$branch" --json state -q .state 2>/dev/null) || true
  [[ "${pr_state:-}" == "MERGED" ]] && merged=1
fi

[[ "$merged" -eq 1 ]] || exit 0

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Branch \`$branch\` is merged but working tree is dirty. Skipping auto-cleanup; stash or commit then clean up manually."
  exit 0
fi

echo "Branch \`$branch\` is merged. Auto-cleaning up: checkout master, pull --rebase, delete branch."

git checkout master >/dev/null 2>&1
if ! git pull --rebase origin master >/dev/null 2>&1; then
  echo "Rebase conflict on master; aborting rebase. Branch \`$branch\` NOT deleted."
  git rebase --abort 2>/dev/null || true
  exit 0
fi
git branch -D "$branch" >/dev/null 2>&1
echo "Cleanup complete. On master, current with origin/master."

exit 0
