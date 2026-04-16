#!/usr/bin/env bash
# docker_api_test.sh — Docker socket API tests
# Tests container lifecycle and volume mount functionality via the Docker Unix socket API.

set -euo pipefail

DOCKER_SOCK="/var/run/docker.sock"
RESULTS_FILE="$(pwd)/docker_api_results.json"

# ──────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────

log()  { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*"; }
fail() { echo "[ERROR] $*" >&2; exit 1; }

docker_curl() {
  curl -s --unix-socket "$DOCKER_SOCK" "$@"
}

# Append a single result object to the JSON results file.
# Usage: append_result <test_name> <status> <detail>
append_result() {
  local test_name="$1"
  local status="$2"
  local detail="$3"
  local timestamp
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  # Bootstrap file with an empty array if it doesn't exist.
  if [[ ! -f "$RESULTS_FILE" ]]; then
    echo "[]" > "$RESULTS_FILE"
  fi

  # Use Python (always available) to safely append JSON.
  python3 - <<EOF
import json, sys

path = "$RESULTS_FILE"
with open(path) as fh:
    data = json.load(fh)

data.append({
    "test": "$test_name",
    "status": "$status",
    "detail": """$detail""",
    "timestamp": "$timestamp"
})

with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
EOF
}

# ──────────────────────────────────────────────
# test_container_lifecycle
# ──────────────────────────────────────────────

test_container_lifecycle() {
  log "=== test_container_lifecycle ==="

  # 1. Create container
  log "Creating alpine container..."
  local create_response
  create_response="$(docker_curl \
    -X POST "http://localhost/containers/create" \
    -H "Content-Type: application/json" \
    -d '{"Image":"alpine","Cmd":["cat","/etc/os-release"]}')"

  local container_id
  container_id="$(echo "$create_response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Id',''))")"

  if [[ -z "$container_id" ]]; then
    warn "Failed to create container. Response: $create_response"
    append_result "test_container_lifecycle" "FAIL" "Container creation failed: $create_response"
    return 1
  fi
  log "Container created: ${container_id:0:12}"

  # 2. Start container
  log "Starting container..."
  local start_http_code
  start_http_code="$(docker_curl \
    -o /dev/null -w "%{http_code}" \
    -X POST "http://localhost/containers/${container_id}/start")"

  if [[ "$start_http_code" != "204" && "$start_http_code" != "304" ]]; then
    warn "Unexpected start HTTP code: $start_http_code"
    append_result "test_container_lifecycle" "FAIL" "Container start returned HTTP $start_http_code"
    docker_curl -X DELETE "http://localhost/containers/${container_id}?force=true" >/dev/null 2>&1 || true
    return 1
  fi
  log "Container started (HTTP $start_http_code)"

  # 3. Wait for container to exit
  log "Waiting for container to finish..."
  local wait_response
  wait_response="$(docker_curl \
    -X POST "http://localhost/containers/${container_id}/wait")"
  local exit_code
  exit_code="$(echo "$wait_response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('StatusCode','?'))")"
  log "Container exited with status code: $exit_code"

  # 4. Retrieve logs
  log "Fetching container logs..."
  local logs
  logs="$(docker_curl "http://localhost/containers/${container_id}/logs?stdout=true&stderr=true")"
  # Strip Docker log stream framing (8-byte header per chunk) using Python
  local clean_logs
  clean_logs="$(echo "$logs" | python3 -c "
import sys
data = sys.stdin.buffer.read()
out = []
i = 0
while i < len(data):
    if i + 8 > len(data):
        break
    size = int.from_bytes(data[i+4:i+8], 'big')
    chunk = data[i+8:i+8+size]
    out.append(chunk.decode('utf-8', errors='replace'))
    i += 8 + size
print(''.join(out), end='')
" 2>/dev/null || printf '%s' "$logs")"
  log "Logs received:"
  echo "$clean_logs"

  # 5. Remove container
  log "Removing container..."
  local remove_http_code
  remove_http_code="$(docker_curl \
    -o /dev/null -w "%{http_code}" \
    -X DELETE "http://localhost/containers/${container_id}")"

  if [[ "$remove_http_code" != "204" ]]; then
    warn "Unexpected remove HTTP code: $remove_http_code"
    append_result "test_container_lifecycle" "FAIL" "Container remove returned HTTP $remove_http_code"
    return 1
  fi
  log "Container removed (HTTP $remove_http_code)"

  local detail
  detail="Container lifecycle OK — exit_code=${exit_code} logs_snippet=$(echo "$clean_logs" | head -2 | tr '\n' ' ')"
  append_result "test_container_lifecycle" "PASS" "$detail"
  log "test_container_lifecycle PASSED"
}

# ──────────────────────────────────────────────
# test_volume_mount
# ──────────────────────────────────────────────

test_volume_mount() {
  log "=== test_volume_mount ==="

  # Create container with /etc bind-mounted read-only
  log "Creating container with /etc bind-mount..."
  local create_response
  create_response="$(docker_curl \
    -X POST "http://localhost/containers/create" \
    -H "Content-Type: application/json" \
    -d '{
      "Image": "alpine",
      "Cmd": ["ls", "-la", "/hostetc"],
      "HostConfig": {
        "Binds": ["/etc:/hostetc:ro"]
      }
    }')"

  local container_id
  container_id="$(echo "$create_response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Id',''))")"

  if [[ -z "$container_id" ]]; then
    warn "Failed to create volume-mount container. Response: $create_response"
    append_result "test_volume_mount" "FAIL" "Container creation failed: $create_response"
    return 1
  fi
  log "Container created: ${container_id:0:12}"

  # Start container
  log "Starting container..."
  local start_http_code
  start_http_code="$(docker_curl \
    -o /dev/null -w "%{http_code}" \
    -X POST "http://localhost/containers/${container_id}/start")"

  if [[ "$start_http_code" != "204" && "$start_http_code" != "304" ]]; then
    warn "Unexpected start HTTP code: $start_http_code"
    append_result "test_volume_mount" "FAIL" "Container start returned HTTP $start_http_code"
    docker_curl -X DELETE "http://localhost/containers/${container_id}?force=true" >/dev/null 2>&1 || true
    return 1
  fi

  # Wait for container to exit
  log "Waiting for container to finish..."
  local wait_response
  wait_response="$(docker_curl -X POST "http://localhost/containers/${container_id}/wait")"
  local exit_code
  exit_code="$(echo "$wait_response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('StatusCode','?'))")"
  log "Container exited with status code: $exit_code"

  # Get logs to confirm bind-mount worked
  log "Fetching logs..."
  local logs
  logs="$(docker_curl "http://localhost/containers/${container_id}/logs?stdout=true&stderr=true")"
  local clean_logs
  clean_logs="$(echo "$logs" | python3 -c "
import sys
data = sys.stdin.buffer.read()
out = []
i = 0
while i < len(data):
    if i + 8 > len(data):
        break
    size = int.from_bytes(data[i+4:i+8], 'big')
    chunk = data[i+8:i+8+size]
    out.append(chunk.decode('utf-8', errors='replace'))
    i += 8 + size
print(''.join(out), end='')
" 2>/dev/null || printf '%s' "$logs")"
  log "Volume-mount logs:"
  echo "$clean_logs"

  # Remove container
  log "Removing container..."
  docker_curl -o /dev/null \
    -X DELETE "http://localhost/containers/${container_id}" >/dev/null 2>&1 || true

  if [[ "$exit_code" -eq 0 ]] 2>/dev/null; then
    local detail
    detail="Volume mount OK — /etc bind-mounted as /hostetc:ro; ls output snippet: $(echo "$clean_logs" | head -3 | tr '\n' ' ')"
    append_result "test_volume_mount" "PASS" "$detail"
    log "test_volume_mount PASSED"
  else
    append_result "test_volume_mount" "FAIL" "Container exited with code $exit_code; logs: $clean_logs"
    warn "test_volume_mount FAILED (exit code $exit_code)"
    return 1
  fi
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────

pull_image_if_missing() {
  local image="$1"
  local tag="${2:-latest}"
  log "Checking for image ${image}:${tag}..."
  local count
  count="$(docker_curl "http://localhost/images/${image}:${tag}/json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(0 if 'message' in d else 1)")"
  if [[ "$count" == "0" ]]; then
    log "Pulling ${image}:${tag} ..."
    docker_curl -X POST "http://localhost/images/create?fromImage=${image}&tag=${tag}" | tail -1
  else
    log "Image ${image}:${tag} already present."
  fi
}

main() {
  log "Docker socket: $DOCKER_SOCK"
  log "Results file:  $RESULTS_FILE"

  if [[ ! -S "$DOCKER_SOCK" ]]; then
    fail "Docker socket not found at $DOCKER_SOCK"
  fi

  pull_image_if_missing alpine latest

  local overall_status=0

  test_container_lifecycle || overall_status=1
  test_volume_mount        || overall_status=1

  log ""
  log "Results written to: $RESULTS_FILE"
  python3 -m json.tool "$RESULTS_FILE" 2>/dev/null || cat "$RESULTS_FILE"

  if [[ $overall_status -ne 0 ]]; then
    fail "One or more tests failed — see $RESULTS_FILE for details."
  fi

  log "All tests passed."
}

main "$@"
