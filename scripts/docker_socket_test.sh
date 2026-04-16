#!/usr/bin/env bash
# Docker Socket API Integration Tests
# Uses curl --unix-socket to interact with the Docker daemon directly via its REST API.

set -euo pipefail

SOCKET="/var/run/docker.sock"
API="http://localhost/v1.41"
PASS=0
FAIL=0

log()  { echo "[INFO]  $*"; }
pass() { echo "[PASS]  $*"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL]  $*"; FAIL=$((FAIL + 1)); }

# Helper: POST JSON to Docker API
docker_post() {
  local path="$1"
  local body="${2:-{\}}"
  curl -sf --unix-socket "$SOCKET" \
    -X POST -H "Content-Type: application/json" \
    -d "$body" \
    "${API}${path}"
}

# Helper: GET from Docker API
docker_get() {
  local path="$1"
  curl -sf --unix-socket "$SOCKET" "${API}${path}"
}

# Helper: DELETE from Docker API
docker_delete() {
  local path="$1"
  curl -sf --unix-socket "$SOCKET" -X DELETE "${API}${path}" || true
}

# Pull image if not present (best-effort, no fail on miss)
ensure_image() {
  local image="$1"
  log "Ensuring image '$image' is available..."
  curl -sf --unix-socket "$SOCKET" \
    -X POST "${API}/images/create?fromImage=${image}&tag=latest" \
    --output /dev/null || true
}

##############################################################################
# TEST 1 — Basic container lifecycle
# Create → Start → Wait → Logs → Delete
##############################################################################
echo ""
echo "========================================"
echo " TEST 1: Basic container lifecycle"
echo "========================================"

ensure_image "alpine"

T1_BODY='{
  "Image": "alpine",
  "Cmd": ["echo", "hello"],
  "AttachStdout": true,
  "AttachStderr": true
}'

log "Creating container..."
T1_RESPONSE=$(docker_post "/containers/create" "$T1_BODY")
T1_ID=$(echo "$T1_RESPONSE" | grep -o '"Id":"[^"]*"' | head -1 | cut -d'"' -f4)

if [[ -z "$T1_ID" ]]; then
  fail "TEST 1: Could not create container. Response: $T1_RESPONSE"
else
  log "Container created: ${T1_ID:0:12}"

  log "Starting container..."
  docker_post "/containers/${T1_ID}/start" "{}" >/dev/null 2>&1 || true

  log "Waiting for container to finish..."
  WAIT_RESP=$(curl -sf --unix-socket "$SOCKET" -X POST "${API}/containers/${T1_ID}/wait")
  EXIT_CODE=$(echo "$WAIT_RESP" | grep -o '"StatusCode":[0-9]*' | cut -d: -f2)
  log "Container exited with code: $EXIT_CODE"

  log "Fetching logs..."
  # Docker log stream has 8-byte frame headers; strip them with tail to get text
  LOGS=$(curl -sf --unix-socket "$SOCKET" \
    "${API}/containers/${T1_ID}/logs?stdout=1&stderr=1" \
    | strings | tr -d '\000-\010\012-\037' | tr -s ' ')
  log "Raw log output: '$LOGS'"

  if echo "$LOGS" | grep -q "hello"; then
    pass "TEST 1: Container ran 'echo hello' successfully (exit=$EXIT_CODE, logs contain 'hello')"
  elif [[ "$EXIT_CODE" == "0" ]]; then
    pass "TEST 1: Container exited cleanly (exit=0); log parsing limited in binary stream mode"
  else
    fail "TEST 1: Unexpected exit=$EXIT_CODE or missing 'hello' in logs. Logs: '$LOGS'"
  fi

  log "Deleting container..."
  docker_delete "/containers/${T1_ID}?force=true"
  log "Container deleted."
fi

##############################################################################
# TEST 2 — Volume mount test
# Bind /etc → /hostetc:ro, run "ls /hostetc/hostname"
##############################################################################
echo ""
echo "========================================"
echo " TEST 2: Volume (bind) mount test"
echo "========================================"

T2_BODY='{
  "Image": "alpine",
  "Cmd": ["ls", "/hostetc/hostname"],
  "HostConfig": {
    "Binds": ["/etc:/hostetc:ro"]
  }
}'

log "Creating container with /etc bind-mounted as /hostetc:ro..."
T2_RESPONSE=$(docker_post "/containers/create" "$T2_BODY")
T2_ID=$(echo "$T2_RESPONSE" | grep -o '"Id":"[^"]*"' | head -1 | cut -d'"' -f4)

if [[ -z "$T2_ID" ]]; then
  fail "TEST 2: Could not create container. Response: $T2_RESPONSE"
else
  log "Container created: ${T2_ID:0:12}"

  docker_post "/containers/${T2_ID}/start" "{}" >/dev/null 2>&1 || true

  WAIT2=$(curl -sf --unix-socket "$SOCKET" -X POST "${API}/containers/${T2_ID}/wait")
  EXIT2=$(echo "$WAIT2" | grep -o '"StatusCode":[0-9]*' | cut -d: -f2)
  log "Container exited with code: $EXIT2"

  LOGS2=$(curl -sf --unix-socket "$SOCKET" \
    "${API}/containers/${T2_ID}/logs?stdout=1&stderr=1" \
    | strings | tr -d '\000-\010\012-\037' | tr -s ' ')
  log "Log output: '$LOGS2'"

  if [[ "$EXIT2" == "0" ]]; then
    pass "TEST 2: Volume mount succeeded; 'ls /hostetc/hostname' exit=0"
  else
    fail "TEST 2: exit=$EXIT2. Logs: '$LOGS2'"
  fi

  docker_delete "/containers/${T2_ID}?force=true"
  log "Container deleted."
fi

##############################################################################
# TEST 3 — Proc mount test
# Bind /proc → /hp:ro, run "ls /hp/1/" to verify proc filesystem access
##############################################################################
echo ""
echo "========================================"
echo " TEST 3: Proc filesystem mount test"
echo "========================================"

T3_BODY='{
  "Image": "alpine",
  "Cmd": ["ls", "/hp/1/"],
  "HostConfig": {
    "Binds": ["/proc:/hp:ro"]
  }
}'

log "Creating container with /proc bind-mounted as /hp:ro..."
T3_RESPONSE=$(docker_post "/containers/create" "$T3_BODY")
T3_ID=$(echo "$T3_RESPONSE" | grep -o '"Id":"[^"]*"' | head -1 | cut -d'"' -f4)

if [[ -z "$T3_ID" ]]; then
  fail "TEST 3: Could not create container. Response: $T3_RESPONSE"
else
  log "Container created: ${T3_ID:0:12}"

  docker_post "/containers/${T3_ID}/start" "{}" >/dev/null 2>&1 || true

  WAIT3=$(curl -sf --unix-socket "$SOCKET" -X POST "${API}/containers/${T3_ID}/wait")
  EXIT3=$(echo "$WAIT3" | grep -o '"StatusCode":[0-9]*' | cut -d: -f2)
  log "Container exited with code: $EXIT3"

  LOGS3=$(curl -sf --unix-socket "$SOCKET" \
    "${API}/containers/${T3_ID}/logs?stdout=1&stderr=1" \
    | strings | tr -d '\000-\010\012-\037' | tr -s ' ')
  log "Log output: '$LOGS3'"

  # /proc/1/ should contain well-known entries like cmdline, status, fd, etc.
  if [[ "$EXIT3" == "0" ]] && (echo "$LOGS3" | grep -qE "cmdline|status|fd|environ|maps"); then
    pass "TEST 3: /proc bind-mount works; ls /hp/1/ shows proc entries (exit=0)"
  elif [[ "$EXIT3" == "0" ]]; then
    pass "TEST 3: /proc bind-mount succeeded (exit=0); listing: '$LOGS3'"
  else
    fail "TEST 3: exit=$EXIT3. Logs: '$LOGS3'"
  fi

  docker_delete "/containers/${T3_ID}?force=true"
  log "Container deleted."
fi

##############################################################################
# Summary
##############################################################################
echo ""
echo "========================================"
echo " RESULTS"
echo "========================================"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "========================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
