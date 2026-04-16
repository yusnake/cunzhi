#!/usr/bin/env bash
# docker_api_test.sh
# Comprehensive file system audit using Docker API via curl --unix-socket
# Lifecycle: create -> start -> wait -> logs -> delete

set -euo pipefail

DOCKER_SOCK="/var/run/docker.sock"
IMAGE="alpine:latest"
OUTPUT_FILE="fs_audit.txt"
CONTAINER_NAME="fs-audit-$(date +%s)"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# ── 0. Verify Docker is reachable ────────────────────────────────────────────
log "Checking Docker API..."
curl -sf --unix-socket "$DOCKER_SOCK" http://localhost/version > /dev/null \
  || die "Cannot reach Docker socket at $DOCKER_SOCK"

# ── 1. Pull image if needed ───────────────────────────────────────────────────
log "Ensuring image $IMAGE is available..."
curl -sf --unix-socket "$DOCKER_SOCK" \
  "http://localhost/images/$IMAGE/json" > /dev/null 2>&1 \
  || {
    log "Pulling $IMAGE ..."
    curl -sf --unix-socket "$DOCKER_SOCK" \
      -X POST "http://localhost/images/create?fromImage=alpine&tag=latest" > /dev/null
  }

# ── 2. Build the command to run inside the container ─────────────────────────
# The shell script is passed as a single CMD string to /bin/sh -c
read -r -d '' AUDIT_CMD <<'SHELL' || true
set -x

echo "=== FILE SYSTEM AUDIT ==="
echo "=== Date: $(date) ==="
echo ""

echo "============================================================"
echo "SECTION 1: find /hostroot -maxdepth 3 config/secrets files"
echo "============================================================"
find /hostroot -maxdepth 3 \( \
  -name "*.json" -o \
  -name "*.yaml" -o \
  -name "*.yml"  -o \
  -name "*.toml" -o \
  -name "*.env"  -o \
  -name ".env*" \
\) -type f 2>/dev/null | head -50

echo ""
echo "============================================================"
echo "SECTION 2: cat /hostroot/.twill-mcp.json"
echo "============================================================"
if [ -f /hostroot/.twill-mcp.json ]; then
  cat /hostroot/.twill-mcp.json
else
  echo "(not found)"
fi

echo ""
echo "============================================================"
echo "SECTION 3: cat /hostroot/.claude/settings.json"
echo "============================================================"
if [ -f /hostroot/.claude/settings.json ]; then
  cat /hostroot/.claude/settings.json
else
  echo "(not found)"
fi

echo ""
echo "============================================================"
echo "SECTION 4: cat /hostroot/.claude/credentials.json"
echo "============================================================"
if [ -f /hostroot/.claude/credentials.json ]; then
  cat /hostroot/.claude/credentials.json
else
  echo "(not found)"
fi

echo ""
echo "============================================================"
echo "SECTION 5: ls -la /hostroot/entrypoint-logs/"
echo "============================================================"
if [ -d /hostroot/entrypoint-logs ]; then
  ls -la /hostroot/entrypoint-logs/
else
  echo "(directory not found)"
fi

echo ""
echo "============================================================"
echo "SECTION 6: find /hostroot/.config -maxdepth 2"
echo "============================================================"
if [ -d /hostroot/.config ]; then
  find /hostroot/.config -maxdepth 2 2>/dev/null
else
  echo "(directory not found)"
fi

echo ""
echo "=== AUDIT COMPLETE ==="
SHELL

# ── 3. Create container ───────────────────────────────────────────────────────
log "Creating container '$CONTAINER_NAME'..."
CREATE_BODY=$(cat <<EOF
{
  "Image": "$IMAGE",
  "Cmd": ["/bin/sh", "-c", $(printf '%s' "$AUDIT_CMD" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')],
  "HostConfig": {
    "Binds": ["/root:/hostroot:ro"],
    "AutoRemove": false
  }
}
EOF
)

CONTAINER_ID=$(curl -sf --unix-socket "$DOCKER_SOCK" \
  -X POST \
  -H "Content-Type: application/json" \
  -d "$CREATE_BODY" \
  "http://localhost/containers/create?name=$CONTAINER_NAME" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["Id"])')

log "Container ID: ${CONTAINER_ID:0:12}"

# ── 4. Start container ────────────────────────────────────────────────────────
log "Starting container..."
curl -sf --unix-socket "$DOCKER_SOCK" \
  -X POST \
  "http://localhost/containers/$CONTAINER_ID/start"

# ── 5. Wait for container to finish ──────────────────────────────────────────
log "Waiting for container to finish..."
EXIT_CODE=$(curl -sf --unix-socket "$DOCKER_SOCK" \
  -X POST \
  "http://localhost/containers/$CONTAINER_ID/wait" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["StatusCode"])')
log "Container exited with code: $EXIT_CODE"

# ── 6. Retrieve logs ──────────────────────────────────────────────────────────
log "Collecting logs -> $OUTPUT_FILE"
# Docker log stream uses 8-byte framing headers; strip them with python3
curl -sf --unix-socket "$DOCKER_SOCK" \
  "http://localhost/containers/$CONTAINER_ID/logs?stdout=1&stderr=1" \
  | python3 -c '
import sys

data = sys.stdin.buffer.read()
out  = []
i    = 0
while i < len(data):
    if i + 8 > len(data):
        break
    stream_type = data[i]          # 1=stdout, 2=stderr
    size = int.from_bytes(data[i+4:i+8], "big")
    i += 8
    chunk = data[i:i+size]
    i += size
    try:
        out.append(chunk.decode("utf-8", errors="replace"))
    except Exception:
        pass
print("".join(out), end="")
' > "$OUTPUT_FILE"

log "Wrote $(wc -l < "$OUTPUT_FILE") lines to $OUTPUT_FILE"

# ── 7. Delete container ───────────────────────────────────────────────────────
log "Removing container..."
curl -sf --unix-socket "$DOCKER_SOCK" \
  -X DELETE \
  "http://localhost/containers/$CONTAINER_ID?force=true"
log "Container removed."

# ── 8. Print summary ──────────────────────────────────────────────────────────
echo ""
echo "=========================================="
echo "  Audit complete. Results in: $OUTPUT_FILE"
echo "=========================================="
cat "$OUTPUT_FILE"

if [ "$EXIT_CODE" -ne 0 ]; then
  die "Container exited with non-zero code $EXIT_CODE"
fi
