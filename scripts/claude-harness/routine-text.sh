#!/usr/bin/env bash
# Print exactly what belongs in a claude.ai routine's prompt box: the routine's
# bootstrap (from .claude/harness/BOOTSTRAP.md, which ends with the SNAPSHOT
# separator line) followed by the matching prompt file.
#
# Usage: routine-text.sh dispatch|review [> routine.txt]
#
# Paste the output into the routine editor whenever a *_PROMPT.md changes. The
# bootstrap must survive that paste — it is the only copy the session cannot
# have rewritten by a pull request.
set -euo pipefail

kind="${1:?dispatch|review}"
root=$(cd "$(dirname "$0")/../.." && pwd)
bootstrap="$root/.claude/harness/BOOTSTRAP.md"

case "$kind" in
  dispatch) prompt="$root/.claude/harness/ROUTINE_PROMPT.md" ;;
  review)   prompt="$root/.claude/harness/REVIEW_PROMPT.md" ;;
  *) echo "usage: $(basename "$0") dispatch|review" >&2; exit 2 ;;
esac

# The bootstrap copies live in fenced blocks under "## <kind> —" headings; take
# the block that belongs to this kind, up to and including the separator line.
awk -v want="## $kind " '
  index($0, want) == 1 { inSection = 1; next }
  inSection && /^## / { exit }
  inSection && /^```$/ && !inFence { inFence = 1; next }
  inSection && inFence && /^---- SNAPSHOT OF/ { print; exit }
  inSection && inFence { print }
' "$bootstrap" > /tmp/routine-bootstrap.$$

if ! grep -q '^---- SNAPSHOT OF' /tmp/routine-bootstrap.$$; then
  rm -f /tmp/routine-bootstrap.$$
  echo "::error::no bootstrap block for '$kind' in $bootstrap" >&2
  exit 1
fi

cat /tmp/routine-bootstrap.$$
rm -f /tmp/routine-bootstrap.$$
printf '\n'
cat "$prompt"
