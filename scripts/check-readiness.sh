#!/usr/bin/env bash
# shellcheck shell=bash
#
# check-readiness.sh
#
# Gate CI on a site's agent-readiness level by calling an external scanner
# (default https://isitagentready.com/api/scan) and comparing the reported
# level to a minimum threshold.
#
# Reads configuration from INPUT_* environment variables (GitHub Actions
# convention). When $GITHUB_OUTPUT is set, writes outputs there. When
# $GITHUB_ACTIONS=true and INPUT_ANNOTATIONS=true, emits ::error:: /
# ::warning:: workflow commands. Otherwise logs to stderr only.
#
# This script is intended to be invoked by action.yml. Running it standalone
# is supported on a best-effort basis for local development.
#
# Exit codes:
#   0  pass, or scanner-unavailable + fail-on-scanner-unavailable=false
#   1  level regression, URL unreachable, or scanner-unavailable + strict
#   2  missing URL input, or missing required dependency (curl/jq)

set -euo pipefail

# ---------------------------------------------------------------------------
# Input parsing
# ---------------------------------------------------------------------------

URL="${INPUT_URL:-${URL:-}}"
MIN_LEVEL="${INPUT_MIN_LEVEL:-2}"
WAIT_FOR_URL="${INPUT_WAIT_FOR_URL:-true}"
WAIT_TIMEOUT="${INPUT_WAIT_TIMEOUT:-60}"
WAIT_INTERVAL="${INPUT_WAIT_INTERVAL:-3}"
SCANNER_ENDPOINT="${INPUT_SCANNER_ENDPOINT:-https://isitagentready.com/api/scan}"
SCANNER_RETRIES="${INPUT_SCANNER_RETRIES:-3}"
SCANNER_RETRY_DELAY="${INPUT_SCANNER_RETRY_DELAY:-5}"
FAIL_ON_SCANNER_UNAVAILABLE="${INPUT_FAIL_ON_SCANNER_UNAVAILABLE:-false}"
ANNOTATIONS="${INPUT_ANNOTATIONS:-true}"

if [[ -z "$URL" ]]; then
  echo "error: url is required (set INPUT_URL or URL)" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

log()  { printf '[agent-readiness] %s\n' "$*" >&2; }

annotations_on() {
  [[ "$ANNOTATIONS" == "true" && "${GITHUB_ACTIONS:-}" == "true" ]]
}

# GitHub workflow commands use :: as delimiter; data values must escape %, \r, \n.
# Ref: https://docs.github.com/en/actions/using-workflow-and-action-commands
escape_cmd_data() {
  local s="$1"
  s="${s//%/%25}"
  s="${s//$'\r'/%0D}"
  s="${s//$'\n'/%0A}"
  printf '%s' "$s"
}

emit_error() {
  local title="$1" body="$2"
  if annotations_on; then
    printf '::error title=%s::%s\n' \
      "$(escape_cmd_data "$title")" \
      "$(escape_cmd_data "$body")"
  else
    log "ERROR: $title — $body"
  fi
}

emit_warning() {
  local title="$1" body="$2"
  if annotations_on; then
    printf '::warning title=%s::%s\n' \
      "$(escape_cmd_data "$title")" \
      "$(escape_cmd_data "$body")"
  else
    log "WARN: $title — $body"
  fi
}

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

# Max size per GitHub Actions output value (~1 MB). We truncate at 900_000 to
# leave headroom for the heredoc framing.
readonly MAX_OUTPUT_BYTES=900000

set_output() {
  local name="$1" value="$2"
  local target="${GITHUB_OUTPUT:-/dev/stdout}"
  # Prefer the simple name=value form for safe single-line values; fall back
  # to heredoc framing when the value contains a newline (raw response body
  # is the main case).
  if [[ "$value" != *$'\n'* ]]; then
    printf '%s=%s\n' "$name" "$value" >>"$target"
    return
  fi
  local delim="__AR_${name//-/_}_EOF_$$_${RANDOM}${RANDOM}"
  {
    printf '%s<<%s\n' "$name" "$delim"
    printf '%s\n' "$value"
    printf '%s\n' "$delim"
  } >>"$target"
}

truncate_for_output() {
  local value="$1"
  if (( ${#value} > MAX_OUTPUT_BYTES )); then
    printf '%s\n…[truncated %d bytes]' \
      "${value:0:MAX_OUTPUT_BYTES}" \
      "$(( ${#value} - MAX_OUTPUT_BYTES ))"
  else
    printf '%s' "$value"
  fi
}

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------

for cmd in curl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    emit_error "Missing dependency" "$cmd not found on PATH. Install $cmd in a prior step."
    exit 2
  fi
done

# ---------------------------------------------------------------------------
# Step 1: wait for target URL to be reachable
# ---------------------------------------------------------------------------

wait_for_url() {
  local deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
  local attempt=0
  log "waiting for $URL to be reachable (timeout ${WAIT_TIMEOUT}s)"
  while :; do
    attempt=$(( attempt + 1 ))
    if curl -sS --fail --max-time 10 -o /dev/null "$URL" 2>/dev/null; then
      log "reachable after ${attempt} attempt(s)"
      return 0
    fi
    if (( $(date +%s) >= deadline )); then
      return 1
    fi
    sleep "$WAIT_INTERVAL"
  done
}

if [[ "$WAIT_FOR_URL" == "true" ]]; then
  if ! wait_for_url; then
    emit_error "Target URL unreachable" \
      "$URL did not respond within ${WAIT_TIMEOUT}s."
    set_output "level" ""
    set_output "passed" "false"
    set_output "response" ""
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Step 2: call the scanner with retries
# ---------------------------------------------------------------------------

call_scanner() {
  # Stdout: response body. Exit code: curl's.
  curl -sS --fail \
    --max-time 30 \
    -X POST \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json' \
    -d "$(jq -n --arg url "$URL" '{url: $url}')" \
    "$SCANNER_ENDPOINT"
}

scanner_response=""
scanner_ok=false
for ((i = 0; i <= SCANNER_RETRIES; i++)); do
  if response=$(call_scanner 2>&1); then
    scanner_response="$response"
    scanner_ok=true
    break
  fi
  if (( i < SCANNER_RETRIES )); then
    log "scanner call failed (attempt $((i + 1))/$((SCANNER_RETRIES + 1))); retrying in ${SCANNER_RETRY_DELAY}s"
    sleep "$SCANNER_RETRY_DELAY"
  else
    log "scanner call failed (final attempt): $response"
  fi
done

if [[ "$scanner_ok" != "true" ]]; then
  set_output "level" ""
  set_output "passed" "false"
  set_output "response" ""
  if [[ "$FAIL_ON_SCANNER_UNAVAILABLE" == "true" ]]; then
    emit_error "Scanner unavailable" \
      "Could not reach $SCANNER_ENDPOINT after $((SCANNER_RETRIES + 1)) attempt(s). Set fail-on-scanner-unavailable: false to soft-fail."
    exit 1
  fi
  emit_warning "Scanner unavailable" \
    "Could not reach $SCANNER_ENDPOINT; passing the gate because fail-on-scanner-unavailable=false. Investigate before the next deploy."
  exit 0
fi

# ---------------------------------------------------------------------------
# Step 3: parse response and gate
# ---------------------------------------------------------------------------

# Validate JSON up front so a malformed response follows the same path as a
# scanner 500.
if ! printf '%s' "$scanner_response" | jq -e . >/dev/null 2>&1; then
  set_output "level" ""
  set_output "passed" "false"
  set_output "response" "$(truncate_for_output "$scanner_response")"
  if [[ "$FAIL_ON_SCANNER_UNAVAILABLE" == "true" ]]; then
    emit_error "Scanner returned malformed response" \
      "Response is not valid JSON. Raw response available in step output 'response'."
    exit 1
  fi
  emit_warning "Scanner returned malformed response" \
    "Response is not valid JSON; passing the gate because fail-on-scanner-unavailable=false."
  exit 0
fi

# Extract gate-relevant fields. Schema reference: see tests/fixtures/ for
# shape-faithful captures keyed by level.
level="$(jq -r '.level // empty' <<<"$scanner_response")"
level_name="$(jq -r '.levelName // empty' <<<"$scanner_response")"

truncated_response="$(truncate_for_output "$scanner_response")"
set_output "response" "$truncated_response"

if [[ -z "$level" || ! "$level" =~ ^[0-9]+$ ]]; then
  set_output "level" ""
  set_output "passed" "false"
  if [[ "$FAIL_ON_SCANNER_UNAVAILABLE" == "true" ]]; then
    emit_error "Scanner response missing level field" \
      "Response JSON did not include a numeric .level. Raw response available in step output 'response'."
    exit 1
  fi
  emit_warning "Scanner response missing level field" \
    "Response JSON did not include a numeric .level; passing the gate because fail-on-scanner-unavailable=false."
  exit 0
fi

set_output "level" "$level"

# Human-readable suffix used in both pass and fail paths.
if [[ -n "$level_name" ]]; then
  level_display="level $level ($level_name)"
else
  level_display="level $level"
fi

if (( level < MIN_LEVEL )); then
  set_output "passed" "false"

  # nextLevel is the scanner's curated "what to fix next" guidance. Surface
  # it directly in the annotation so the developer sees actionable items
  # without needing to open the raw JSON.
  next_target="$(jq -r '.nextLevel.target // empty' <<<"$scanner_response")"
  next_name="$(jq -r '.nextLevel.name // empty' <<<"$scanner_response")"
  next_reqs="$(jq -r '
    .nextLevel.requirements // []
    | map("  - " + (.check // "?") + ": " + (.description // .shortPrompt // ""))
    | join("\n")
  ' <<<"$scanner_response")"

  title="Agent Readiness regression: $level_display < min $MIN_LEVEL"
  body="Detected $level_display (expected >= $MIN_LEVEL)."
  if [[ -n "$next_target" ]]; then
    next_display="level $next_target"
    [[ -n "$next_name" ]] && next_display="$next_display ($next_name)"
    if [[ -n "$next_reqs" ]]; then
      body="${body}
To reach $next_display, fix:
$next_reqs"
    else
      body="${body} Next target: $next_display."
    fi
  fi
  body="${body}
Raw response in step output 'response'."

  emit_error "$title" "$body"
  exit 1
fi

set_output "passed" "true"
log "pass: $level_display >= min $MIN_LEVEL"
exit 0
