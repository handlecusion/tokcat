#!/usr/bin/env bash
# Daily parity gate runner. The migration plan requires 7 consecutive green
# daily runs on real data before the Rust core may be deleted. Installed as
# a launchd agent (com.handlecusion.tokcat.parity); results append to
# ~/.tokcat-parity.log — check progress with:
#   tail ~/.tokcat-parity.log
# Remove the gate with:
#   launchctl bootout gui/$UID/com.handlecusion.tokcat.parity
#   rm ~/Library/LaunchAgents/com.handlecusion.tokcat.parity.plist
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="$HOME/.tokcat-parity.log"
STAMP="$(date '+%Y-%m-%d %H:%M:%S')"

if out="$("$ROOT/scripts/parity-check.sh" --snapshot 2>&1)"; then
  echo "$STAMP PASS $(echo "$out" | tail -1)" >> "$LOG"
else
  echo "$STAMP FAIL" >> "$LOG"
  echo "$out" | tail -20 | sed 's/^/    /' >> "$LOG"
fi

# Streak summary: consecutive PASS days counted from the end.
streak=0
while IFS= read -r line; do
  case "$line" in
    *" PASS "*) streak=$((streak + 1)) ;;
    *" FAIL"*) streak=0 ;;
  esac
done < "$LOG"
echo "$STAMP streak: $streak consecutive green run(s); gate needs 7" >> "$LOG"
