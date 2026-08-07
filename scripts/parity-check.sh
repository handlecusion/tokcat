#!/usr/bin/env bash
# Parity harness: run the Rust usage_dump and the Swift tokcat-dump on this
# machine's real data and diff the results (ints exact, floats within 1e-6).
#
# Usage: scripts/parity-check.sh [--year YYYY] [--clients a,b] [--snapshot]
#
# All ten client parsers are compared by default; both binaries are
# restricted with --clients. Live logs can grow between the two invocations,
# so a mismatch is retried up to 3 times before failing. --snapshot freezes
# the data first: every source directory is APFS-cloned into a temp HOME
# and both binaries run against the clone (use when agents are writing
# logs concurrently — live mode flaps on the current day otherwise).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
YEAR=""
CLIENTS="claude,codex,cursor,opencode,gemini,copilot,amp,droid,hermes,grok"
SNAPSHOT=0
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
    --snapshot)
      SNAPSHOT=1
      shift
      ;;
    *)
      echo "usage: parity-check.sh [--year YYYY] [--clients a,b] [--snapshot]" >&2
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

# --snapshot: APFS-clone every source dir into a frozen fake HOME. Both
# binaries resolve paths from $HOME/$XDG_*/$*_HOME env, so pointing HOME at
# the clone re-roots everything (including the Orca codex runtime homes
# under Library/Application Support/orca).
if [[ "$SNAPSHOT" == 1 ]]; then
  SNAP="$TMP/home"
  mkdir -p "$SNAP"
  for rel in \
    .claude/projects .claude/transcripts .codex .gemini/tmp .copilot/otel \
    .factory/sessions .hermes .grok .config/tokscale/cursor-cache \
    "Library/Application Support/orca/codex-runtime-home" \
    ".local/share/opencode" ".local/share/amp/threads"; do
    src="$HOME/$rel"
    [[ -e "$src" ]] || continue
    mkdir -p "$SNAP/$(dirname "$rel")"
    cp -Rc "$src" "$SNAP/$rel" 2>/dev/null || cp -R "$src" "$SNAP/$rel"
  done
  export HOME="$SNAP"
  unset CODEX_HOME GROK_HOME HERMES_HOME TOKCAT_CODEX_HOMES XDG_DATA_HOME \
    TOKSCALE_HEADLESS_DIR COPILOT_OTEL_FILE_EXPORTER_PATH 2>/dev/null || true
  echo "[parity] snapshot HOME: $SNAP" >&2
fi

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
