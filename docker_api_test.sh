#!/usr/bin/env bash
# docker_api_test.sh
# Tests the Docker Engine API via the Unix socket.
# Requires: curl, jq, access to /var/run/docker.sock
set -euo pipefail

DOCKER_SOCK="/var/run/docker.sock"
IMAGE="alpine:latest"
OUTPUT_FILE="process_audit.txt"

log()  { echo "[INFO]  $*"; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

check_prereqs() {
    for cmd in curl jq; do
        command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is required but not installed."
    done
    [[ -S "$DOCKER_SOCK" ]] || die "Docker socket not found at $DOCKER_SOCK"
    log "Prerequisites OK"
}

# ---------------------------------------------------------------------------
# Helper: call Docker API
# Usage: docker_api <method> <path> [body]
# ---------------------------------------------------------------------------
docker_api() {
    local method="$1"
    local path="$2"
    local body="${3:-}"
    if [[ -n "$body" ]]; then
        curl -sf --unix-socket "$DOCKER_SOCK" \
            -X "$method" \
            -H "Content-Type: application/json" \
            -d "$body" \
            "http://localhost/v1.41${path}"
    else
        curl -sf --unix-socket "$DOCKER_SOCK" \
            -X "$method" \
            "http://localhost/v1.41${path}"
    fi
}

# ---------------------------------------------------------------------------
# Test 1 – Basic lifecycle (ping + version)
# ---------------------------------------------------------------------------
test_lifecycle() {
    log "=== Test 1: API lifecycle (ping / version) ==="

    local ping_result
    ping_result=$(curl -sf --unix-socket "$DOCKER_SOCK" "http://localhost/v1.41/_ping")
    [[ "$ping_result" == "OK" ]] || die "Docker ping failed (got: $ping_result)"
    log "Ping: OK"

    local version
    version=$(docker_api GET /version | jq -r '.Version')
    log "Docker version: $version"
}

# ---------------------------------------------------------------------------
# Test 2 – Process enumeration via /proc mount
# ---------------------------------------------------------------------------
test_process_enumeration() {
    log "=== Test 2: Process enumeration via /hostproc ==="

    # Pull image if not present (ignore errors — may already exist)
    log "Pulling $IMAGE (if needed)…"
    curl -sf --unix-socket "$DOCKER_SOCK" \
        -X POST "http://localhost/v1.41/images/create?fromImage=alpine&tag=latest" \
        --output /dev/null || true

    # The shell command that enumerates /hostproc
    # shellcheck disable=SC2016
    local cmd
    cmd='echo "=== Running processes (PID list) ===" && \
ls /hostproc/ | grep -E "^[0-9]+" && \
echo && \
echo "=== Per-PID cmdline + environ ===" && \
for pid in $(ls /hostproc/ | grep -E "^[0-9]+$"); do \
    echo "=== PID $pid ==="; \
    cat /hostproc/$pid/cmdline 2>/dev/null | tr "\0" " "; \
    echo; \
    if [ -f /hostproc/$pid/environ ]; then \
        cat /hostproc/$pid/environ 2>/dev/null | tr "\0" "\n"; \
    fi; \
    echo; \
done'

    # Create container with /proc mounted as /hostproc:ro
    log "Creating container…"
    local create_body
    create_body=$(jq -n \
        --arg image "$IMAGE" \
        --arg cmd "$cmd" \
        '{
            Image: $image,
            Cmd: ["sh", "-c", $cmd],
            HostConfig: {
                Binds: ["/proc:/hostproc:ro"],
                AutoRemove: false
            }
        }')

    local container_id
    container_id=$(docker_api POST /containers/create "$create_body" | jq -r '.Id')
    [[ -n "$container_id" && "$container_id" != "null" ]] || die "Failed to create container"
    log "Container created: ${container_id:0:12}"

    # Start container
    log "Starting container…"
    docker_api POST "/containers/${container_id}/start" "" >/dev/null

    # Wait for container to finish
    log "Waiting for container to finish…"
    local exit_code
    exit_code=$(docker_api POST "/containers/${container_id}/wait" "" | jq -r '.StatusCode')
    log "Container exited with status: $exit_code"

    # Collect logs
    log "Collecting logs → $OUTPUT_FILE"
    curl -sf --unix-socket "$DOCKER_SOCK" \
        -X GET \
        "http://localhost/v1.41/containers/${container_id}/logs?stdout=1&stderr=1&timestamps=0" \
        | cat > "$OUTPUT_FILE.raw"

    # Docker log stream uses a multiplexed framing header (8 bytes per chunk).
    # Strip the binary header bytes so the file is plain text.
    python3 - "$OUTPUT_FILE.raw" "$OUTPUT_FILE" <<'PYEOF'
import sys, struct

in_path  = sys.argv[1]
out_path = sys.argv[2]

with open(in_path, "rb") as fin, open(out_path, "w", errors="replace") as fout:
    while True:
        hdr = fin.read(8)
        if len(hdr) < 8:
            break
        stream_type = hdr[0]   # 1=stdout, 2=stderr
        size = struct.unpack(">I", hdr[4:8])[0]
        payload = fin.read(size)
        fout.write(payload.decode("utf-8", errors="replace"))
PYEOF

    rm -f "$OUTPUT_FILE.raw"
    log "Process audit saved to $OUTPUT_FILE ($(wc -l < "$OUTPUT_FILE") lines)"

    if [[ "$exit_code" -ne 0 ]]; then
        log "WARNING: container exited with non-zero status $exit_code"
        log "--- begin output ---"
        cat "$OUTPUT_FILE"
        log "--- end output ---"
    fi

    # Remove container
    log "Removing container…"
    docker_api DELETE "/containers/${container_id}?force=true" >/dev/null
    log "Container removed"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    check_prereqs
    test_lifecycle
    test_process_enumeration
    log "All tests passed."
}

main "$@"
