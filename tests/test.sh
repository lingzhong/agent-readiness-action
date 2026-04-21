#!/usr/bin/env bash
# shellcheck shell=bash
#
# End-to-end test driver for scripts/check-readiness.sh.
#
# Spins up tests/mock-server.sh on a local port, runs the script against it
# with various INPUT_* env combinations, and asserts exit codes + output
# contents. Runs on ubuntu-latest and macos-latest in CI.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT="$ROOT/scripts/check-readiness.sh"

PORT="${AR_TEST_PORT:-8765}"
ENDPOINT="http://127.0.0.1:${PORT}"

FAIL_COUNT=0
PASS_COUNT=0

cleanup() {
  if [[ -n "${MOCK_PID:-}" ]]; then
    kill "$MOCK_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true
  fi
  rm -f "$TMP_OUTPUT" "$TMP_LOG"
}

TMP_OUTPUT="$(mktemp)"
TMP_LOG="$(mktemp)"
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Start mock server
# ---------------------------------------------------------------------------

bash "$HERE/mock-server.sh" "$PORT" "$HERE/fixtures" &
MOCK_PID=$!

# Wait for the mock to accept connections (up to 5s).
for _ in $(seq 1 50); do
  if curl -sS -o /dev/null --max-time 1 -X POST \
      -H 'Content-Type: application/json' \
      -d '{"url":"https://example.com#level=0"}' \
      "$ENDPOINT"; then
    break
  fi
  sleep 0.1
done

# ---------------------------------------------------------------------------
# Test runner helpers
# ---------------------------------------------------------------------------

run_case() {
  # run_case <name> <expected_exit> <env-assignments...> -- <grep-patterns...>
  local name="$1" expected_exit="$2"
  shift 2

  local envs=() patterns=() in_patterns=0
  while (( $# > 0 )); do
    if [[ "$1" == "--" ]]; then
      in_patterns=1
      shift
      continue
    fi
    if (( in_patterns )); then
      patterns+=("$1")
    else
      envs+=("$1")
    fi
    shift
  done

  : >"$TMP_OUTPUT"
  : >"$TMP_LOG"

  local actual_exit=0
  env -i PATH="$PATH" HOME="$HOME" \
    GITHUB_OUTPUT="$TMP_OUTPUT" \
    "${envs[@]}" \
    bash "$SCRIPT" >"$TMP_LOG" 2>&1 || actual_exit=$?

  if [[ "$actual_exit" -ne "$expected_exit" ]]; then
    printf 'FAIL %s: expected exit %d, got %d\n' "$name" "$expected_exit" "$actual_exit"
    printf -- '--- stdout/stderr ---\n'
    cat "$TMP_LOG"
    printf -- '--- outputs ---\n'
    cat "$TMP_OUTPUT"
    printf -- '---\n'
    FAIL_COUNT=$((FAIL_COUNT + 1))
    return
  fi

  local haystack
  haystack="$(cat "$TMP_LOG" "$TMP_OUTPUT")"
  for p in "${patterns[@]}"; do
    if ! grep -q -- "$p" <<<"$haystack"; then
      printf 'FAIL %s: expected pattern not found: %s\n' "$name" "$p"
      printf -- '--- combined ---\n%s\n---\n' "$haystack"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      return
    fi
  done

  printf 'PASS %s\n' "$name"
  PASS_COUNT=$((PASS_COUNT + 1))
}

# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

# 1. Level 4 >= min 4 -> pass
run_case "level-4-passes-at-min-4" 0 \
  "INPUT_URL=http://127.0.0.1:${PORT}/target#level=4" \
  "INPUT_MIN_LEVEL=4" \
  "INPUT_SCANNER_ENDPOINT=${ENDPOINT}" \
  "INPUT_WAIT_FOR_URL=false" \
  -- \
  "level=4" \
  "passed=true"

# 2. Level 2 < min 4 -> fail hard with annotation, including levelName and
# nextLevel guidance (the scanner tells us to fix markdownNegotiation to
# reach level 3).
run_case "level-2-fails-at-min-4" 1 \
  "INPUT_URL=http://127.0.0.1:${PORT}/target#level=2" \
  "INPUT_MIN_LEVEL=4" \
  "INPUT_SCANNER_ENDPOINT=${ENDPOINT}" \
  "INPUT_WAIT_FOR_URL=false" \
  "GITHUB_ACTIONS=true" \
  -- \
  "passed=false" \
  "level=2" \
  "Agent Readiness regression" \
  "Bot-Aware" \
  "markdownNegotiation"

# 3. Level 0 < default min 2 -> fail; annotation names the missing artifacts
# that would bring the site to level 1 (sitemap, linkHeaders).
run_case "level-0-fails-at-default-min-2" 1 \
  "INPUT_URL=http://127.0.0.1:${PORT}/target#level=0" \
  "INPUT_SCANNER_ENDPOINT=${ENDPOINT}" \
  "INPUT_WAIT_FOR_URL=false" \
  -- \
  "passed=false" \
  "Not Ready" \
  "sitemap" \
  "linkHeaders"

# 4. Level 0 at min 0 -> pass (threshold comparison sanity)
run_case "level-0-passes-at-min-0" 0 \
  "INPUT_URL=http://127.0.0.1:${PORT}/target#level=0" \
  "INPUT_MIN_LEVEL=0" \
  "INPUT_SCANNER_ENDPOINT=${ENDPOINT}" \
  "INPUT_WAIT_FOR_URL=false" \
  -- \
  "passed=true"

# 4b. Level 3 synthesized fixture passes at min 3 and surfaces levelName.
run_case "level-3-passes-at-min-3" 0 \
  "INPUT_URL=http://127.0.0.1:${PORT}/target#level=3" \
  "INPUT_MIN_LEVEL=3" \
  "INPUT_SCANNER_ENDPOINT=${ENDPOINT}" \
  "INPUT_WAIT_FOR_URL=false" \
  -- \
  "passed=true" \
  "level=3" \
  "Agent-Readable"

# 4c. Level 4 real-world lingzhong capture — shape-regression guard. If the
# scanner changes its response schema, this test flags it before users hit
# the parser fallback.
run_case "level-4-real-capture-shape" 0 \
  "INPUT_URL=http://127.0.0.1:${PORT}/target#level=4" \
  "INPUT_MIN_LEVEL=4" \
  "INPUT_SCANNER_ENDPOINT=${ENDPOINT}" \
  "INPUT_WAIT_FOR_URL=false" \
  -- \
  "passed=true" \
  "level=4" \
  "Agent-Integrated"

# 4d. Level 5 real-world Agent-Native capture — shape-regression guard.
run_case "level-5-passes-at-min-5" 0 \
  "INPUT_URL=http://127.0.0.1:${PORT}/target#level=5" \
  "INPUT_MIN_LEVEL=5" \
  "INPUT_SCANNER_ENDPOINT=${ENDPOINT}" \
  "INPUT_WAIT_FOR_URL=false" \
  -- \
  "passed=true" \
  "level=5" \
  "Agent-Native"

# 4e. Level 4 at min 5 -> fail with nextLevel guidance toward Agent-Native.
run_case "level-4-fails-at-min-5" 1 \
  "INPUT_URL=http://127.0.0.1:${PORT}/target#level=4" \
  "INPUT_MIN_LEVEL=5" \
  "INPUT_SCANNER_ENDPOINT=${ENDPOINT}" \
  "INPUT_WAIT_FOR_URL=false" \
  "GITHUB_ACTIONS=true" \
  -- \
  "passed=false" \
  "Agent-Integrated" \
  "oauthProtectedResource"

# 5. Malformed scanner response, default (soft-fail) -> exit 0 with warn
run_case "malformed-soft-fails" 0 \
  "INPUT_URL=http://127.0.0.1:${PORT}/target#malformed" \
  "INPUT_SCANNER_ENDPOINT=${ENDPOINT}" \
  "INPUT_WAIT_FOR_URL=false" \
  -- \
  "passed=false"

# 6. Malformed scanner response, strict -> exit 1
run_case "malformed-hard-fails-when-strict" 1 \
  "INPUT_URL=http://127.0.0.1:${PORT}/target#malformed" \
  "INPUT_SCANNER_ENDPOINT=${ENDPOINT}" \
  "INPUT_WAIT_FOR_URL=false" \
  "INPUT_FAIL_ON_SCANNER_UNAVAILABLE=true" \
  -- \
  "passed=false"

# 7. Scanner 500, default -> soft-fail
run_case "scanner-500-soft-fails" 0 \
  "INPUT_URL=http://127.0.0.1:${PORT}/target#scanner-500" \
  "INPUT_SCANNER_ENDPOINT=${ENDPOINT}" \
  "INPUT_WAIT_FOR_URL=false" \
  "INPUT_SCANNER_RETRIES=0" \
  -- \
  "passed=false"

# 8. Scanner 500, strict -> hard-fail
run_case "scanner-500-hard-fails-when-strict" 1 \
  "INPUT_URL=http://127.0.0.1:${PORT}/target#scanner-500" \
  "INPUT_SCANNER_ENDPOINT=${ENDPOINT}" \
  "INPUT_WAIT_FOR_URL=false" \
  "INPUT_SCANNER_RETRIES=0" \
  "INPUT_FAIL_ON_SCANNER_UNAVAILABLE=true" \
  -- \
  "passed=false"

# 9. URL unreachable within wait-timeout -> hard fail
# Use 192.0.2.1 (TEST-NET-1) which is non-routable by RFC 5737.
run_case "url-unreachable-hard-fails" 1 \
  "INPUT_URL=http://192.0.2.1/target" \
  "INPUT_SCANNER_ENDPOINT=${ENDPOINT}" \
  "INPUT_WAIT_FOR_URL=true" \
  "INPUT_WAIT_TIMEOUT=2" \
  "INPUT_WAIT_INTERVAL=1" \
  -- \
  "passed=false" \
  "unreachable"

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"

if (( FAIL_COUNT > 0 )); then
  exit 1
fi
