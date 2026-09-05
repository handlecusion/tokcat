#!/usr/bin/env bash
# Wrap up a merged harness PR: clear the harness labels off the linked issue and
# close it. Idempotent — safe to run twice on the same PR.
#
#   GH_TOKEN  a token with issues:write on this repo
#   GH_REPO   owner/name
#
# Usage: finish.sh <pr-number>
#
# Two call sites, because a merge reaches us two ways (see claude-merge-gate.yml):
#   • the gate merged the PR itself in-step (CI was already green)
#   • GitHub auto-merged it later and the `pull_request_target: closed` event
#     brought us back
set -euo pipefail

pr="${1:?pr number}"
: "${GH_REPO:?GH_REPO is not set}"

body=$(gh api "repos/$GH_REPO/pulls/$pr" --jq '.body // ""')
head=$(gh api "repos/$GH_REPO/pulls/$pr" --jq '.head.ref // ""')

# The marker the session writes into every PR body is authoritative; the branch
# name is the fallback for a PR whose body was edited.
issue=$(printf '%s' "$body" | grep -oE 'claude-harness[^>]*issue=[0-9]+' | grep -oE '[0-9]+$' | head -1 || true)
[ -n "$issue" ] || issue=$(printf '%s' "$head" | grep -oE 'issue-[0-9]+$' | grep -oE '[0-9]+' || true)
[ -n "$issue" ] || { echo "no linked issue in PR #$pr body/branch — nothing to finish"; exit 0; }

# `claude` goes too: leaving the trigger label on a closed issue makes a re-run
# ("remove, then re-add") look like a no-op.
for label in 'claude' 'claude%3Apr-open' 'claude%3Arunning' 'claude%3Aneeds-info'; do
  gh api -X DELETE "repos/$GH_REPO/issues/$issue/labels/$label" --silent 2>/dev/null || true
done

state=$(gh api "repos/$GH_REPO/issues/$issue" --jq .state)
if [ "$state" = "open" ]; then
  gh api -X POST "repos/$GH_REPO/issues/$issue/comments" \
    -f body="$(printf '✅ **Claude harness** — PR #%s가 main에 머지되어 이 이슈를 닫습니다.\n\n<!-- claude-harness kind=MERGE_GATE issue=%s -->' "$pr" "$issue")" --silent
  gh api -X PATCH "repos/$GH_REPO/issues/$issue" -f state=closed -f state_reason=completed --silent
  echo "closed #$issue, harness labels cleared"
else
  echo "#$issue already $state, harness labels cleared"
fi
