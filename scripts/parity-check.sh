#!/usr/bin/env bash
# Parity harness: run the Rust usage_dump and the Swift tokcat-dump on this
# machine's real data and diff the results (ints exact, floats within 1e-6).
#
# Usage: scripts/parity-check.sh [--year YYYY] [--clients a,b]
#
# All ten client parsers are compared by default; both binaries are
# restricted with --clients. Live logs can grow between the two invocations,
# so a mismatch is retried up to 3 times before failing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
YEAR=""
CLIENTS="claude,codex,cursor,opencode,gemini,copilot,amp,droid,hermes,grok"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --year)
      YEAR="${2:?--year requires a value}"
      shift 2
      ;;
    --clients)
      CLIENTS="${2:?--clients requires a value}"
      shift 2
      ;;
    *)
      echo "usage: parity-check.sh [--year YYYY] [--clients a,b]" >&2
      exit 2
      ;;
  esac
done

echo "[parity] building rust usage_dump..." >&2
(cd "$ROOT/src-tauri" && cargo build --offline --quiet --bin usage_dump)
echo "[parity] building swift tokcat-dump..." >&2
(cd "$ROOT/native/LocalPackage" && swift build -c release --product tokcat-dump 1>&2)

RUST_BIN="$ROOT/src-tauri/target/debug/usage_dump"
SWIFT_BIN="$(cd "$ROOT/native/LocalPackage" && swift build -c release --show-bin-path)/tokcat-dump"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ARGS=(graph --clients "$CLIENTS")
if [[ -n "$YEAR" ]]; then
  ARGS+=(--year "$YEAR")
fi

for attempt in 1 2 3; do
  # Back-to-back runs to minimize the window in which live logs can grow.
  "$RUST_BIN" "${ARGS[@]}" > "$TMP/rust.json"
  "$SWIFT_BIN" "${ARGS[@]}" > "$TMP/swift.json"
  if python3 "$ROOT/scripts/parity_normalize.py" "$TMP/rust.json" "$TMP/swift.json"; then
    echo "[parity] PASS (attempt $attempt, year='${YEAR:-all}', clients=$CLIENTS)"
    exit 0
  fi
  echo "[parity] attempt $attempt diverged; retrying in case logs moved..." >&2
done

trap - EXIT
echo "[parity] FAIL after 3 attempts; dumps kept in $TMP for inspection" >&2
exit 1
