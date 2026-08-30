#!/usr/bin/env bash
# Fire the Claude harness routine with a payload file and print the new session.
#
#   CLAUDE_ROUTINE_FIRE_URL   https://api.anthropic.com/v1/claude_code/routines/trig_.../fire
#   CLAUDE_ROUTINE_FIRE_TOKEN per-routine bearer token (sk-ant-oat01-...), scoped to firing
#                             this one routine — it can read nothing.
#
# Usage: fire.sh payload.txt
# Prints the raw JSON response on stdout; when GITHUB_OUTPUT is set, also writes
# session_id / session_url step outputs. Retries 429/5xx with backoff.
set -euo pipefail

payload_file="${1:?payload file}"
: "${CLAUDE_ROUTINE_FIRE_URL:?CLAUDE_ROUTINE_FIRE_URL is not set (repo secret)}"
: "${CLAUDE_ROUTINE_FIRE_TOKEN:?CLAUDE_ROUTINE_FIRE_TOKEN is not set (repo secret)}"

case "$CLAUDE_ROUTINE_FIRE_URL" in
  https://api.anthropic.com/v1/claude_code/routines/trig_*/fire) ;;
  *) echo "::error::CLAUDE_ROUTINE_FIRE_URL does not look like a routine fire URL" >&2; exit 2 ;;
esac

chars=$(wc -m < "$payload_file" | tr -d ' ')
if [ "$chars" -gt 65536 ]; then
  echo "::error::payload is $chars chars; API limit is 65536" >&2
  exit 2
fi

body_file=$(mktemp)
resp_file=$(mktemp)
trap 'rm -f "$body_file" "$resp_file"' EXIT
jq -Rs '{text: .}' "$payload_file" > "$body_file"

attempt=0
max_attempts=4
while :; do
  attempt=$((attempt + 1))
  http=$(curl -sS --connect-timeout 15 --max-time 90 -o "$resp_file" -w '%{http_code}' -X POST "$CLAUDE_ROUTINE_FIRE_URL" \
    -H "Authorization: Bearer $CLAUDE_ROUTINE_FIRE_TOKEN" \
    -H "anthropic-version: 2023-06-01" \
    -H "anthropic-beta: experimental-cc-routine-2026-04-01" \
    -H "Content-Type: application/json" \
    --data-binary @"$body_file") || true
  # curl prints 000 (or nothing) when the connection itself fails — normalise so it retries.
  case "$http" in [0-9][0-9][0-9]) ;; *) http=000 ;; esac

  if [ "$http" = "200" ]; then
    break
  fi
  echo "fire attempt $attempt → HTTP $http: $(head -c 600 "$resp_file")" >&2
  # /fire is not idempotent: a retry after an ambiguous failure could start a second
  # session. Retry only where the request provably did not start one: 429 (refused),
  # 503 (overloaded, documented as retryable) and 000 (no HTTP response at all).
  case "$http" in
    429|503|000)
      if [ "$attempt" -ge "$max_attempts" ]; then
        echo "::error::routine fire failed after $attempt attempts (HTTP $http)" >&2
        exit 1
      fi
      wait=$((attempt * attempt * 5))
      ra=$(grep -i '^retry-after:' "$resp_file" 2>/dev/null | head -1 | tr -dc '0-9')
      [ -n "$ra" ] && [ "$ra" -gt "$wait" ] && [ "$ra" -le 300 ] && wait=$ra
      sleep "$wait"
      ;;
    *)
      echo "::error::routine fire rejected (HTTP $http). 401=token mismatch, 400=paused routine or bad header, 404=routine gone, 5xx=ambiguous — check claude.ai/code before re-labeling." >&2
      exit 1
      ;;
  esac
done

cat "$resp_file"
echo
session_id=$(jq -r '.claude_code_session_id // empty' "$resp_file")
session_url=$(jq -r '.claude_code_session_url // empty' "$resp_file")
if [ -z "$session_id" ] || [ -z "$session_url" ]; then
  echo "::error::fire response lacks session id/url" >&2
  exit 1
fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "session_id=$session_id"
    echo "session_url=$session_url"
  } >> "$GITHUB_OUTPUT"
fi
