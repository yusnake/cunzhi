#!/usr/bin/env bash
# Docker socket connectivity test for CI/CD pipeline.
# Communicates with the Docker daemon via the Unix socket using curl,
# tests key API endpoints, and saves all responses to docker_api_results.json.

set -euo pipefail

SOCKET="/var/run/docker.sock"
OUTPUT_FILE="${1:-docker_api_results.json}"

# ── helpers ──────────────────────────────────────────────────────────────────

log()  { echo "[docker_api_test] $*" >&2; }
fail() { echo "[docker_api_test] FAIL: $*" >&2; exit 1; }

require_curl() {
  command -v curl >/dev/null 2>&1 || fail "curl is not installed"
}

require_socket() {
  [[ -S "$SOCKET" ]] || fail "Docker socket not found at $SOCKET"
}

query() {
  local endpoint="$1"
  local http_code
  local body

  # Capture HTTP status and body separately
  body=$(curl --silent \
              --unix-socket "$SOCKET" \
              --write-out '\n__HTTP_STATUS__%{http_code}' \
              "http://localhost${endpoint}")

  http_code=$(echo "$body" | tail -n1 | sed 's/.*__HTTP_STATUS__//')
  body=$(echo "$body" | sed '$d')   # strip the status line

  echo "{\"endpoint\": \"${endpoint}\", \"http_status\": ${http_code}, \"body\": ${body}}"
}

# ── pre-flight ────────────────────────────────────────────────────────────────

require_curl
require_socket

log "Docker socket found at $SOCKET"
log "Testing endpoints..."

# ── run tests ─────────────────────────────────────────────────────────────────

info_result=$(query "/info")
containers_result=$(query "/containers/json")
images_result=$(query "/images/json")

log "GET /info          → HTTP $(echo "$info_result"       | grep -o '"http_status": [0-9]*' | grep -o '[0-9]*')"
log "GET /containers/json → HTTP $(echo "$containers_result" | grep -o '"http_status": [0-9]*' | grep -o '[0-9]*')"
log "GET /images/json   → HTTP $(echo "$images_result"     | grep -o '"http_status": [0-9]*' | grep -o '[0-9]*')"

# ── write results ─────────────────────────────────────────────────────────────

timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

cat > "$OUTPUT_FILE" <<JSON
{
  "timestamp": "${timestamp}",
  "socket": "${SOCKET}",
  "results": [
    ${info_result},
    ${containers_result},
    ${images_result}
  ]
}
JSON

log "Results saved to $OUTPUT_FILE"

# ── verify all endpoints returned 2xx ────────────────────────────────────────

all_ok=true
for label in "info" "containers" "images"; do
  case "$label" in
    info)       result="$info_result" ;;
    containers) result="$containers_result" ;;
    images)     result="$images_result" ;;
  esac

  code=$(echo "$result" | grep -o '"http_status": [0-9]*' | grep -o '[0-9]*')
  if [[ "$code" -lt 200 || "$code" -ge 300 ]]; then
    log "  ✗ /${label} returned HTTP $code"
    all_ok=false
  else
    log "  ✓ /${label} returned HTTP $code"
  fi
done

if [[ "$all_ok" == "true" ]]; then
  log "All Docker API tests passed."
  exit 0
else
  fail "One or more Docker API tests failed — see output above."
fi
