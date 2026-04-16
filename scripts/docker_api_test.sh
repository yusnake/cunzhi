#!/usr/bin/env bash
# Docker Socket API Container Lifecycle Test
# Tests the full lifecycle: pull -> create -> start -> wait -> logs -> delete
# Saves all output to docker_api_results.json

set -uo pipefail

SOCKET="/var/run/docker.sock"
API="http://localhost/v1.41"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_FILE="${SCRIPT_DIR}/../docker_api_results.json"
TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >&2; }

# ── 1. Pull alpine:latest ──────────────────────────────────────────────────────
log "Step 1: Pulling alpine:latest ..."
curl -s --unix-socket "$SOCKET" \
  -X POST \
  "${API}/images/create?fromImage=alpine&tag=latest" \
  > "$TMPDIR_WORK/pull.txt"
log "Pull response received ($(wc -c < "$TMPDIR_WORK/pull.txt") bytes)"
cat "$TMPDIR_WORK/pull.txt" >&2

# ── 2. Create container ────────────────────────────────────────────────────────
log "Step 2: Creating container ..."

# Use Python to build valid JSON — avoids shell quoting/escaping pitfalls.
python3 -c "
import json
cmd = (
    'for pid in \$(ls /hostproc | grep -E \"^[0-9]+\$\"); do '
    'echo \"=== PID \$pid ===\"; '
    'cat /hostproc/\$pid/cmdline 2>/dev/null | tr \"\\\\000\" \" \"; '
    'echo; '
    'cat /hostproc/\$pid/environ 2>/dev/null | tr \"\\\\000\" \"\\\\n\"; '
    'done'
)
body = {
    'Image': 'alpine',
    'Cmd': ['sh', '-c', cmd],
    'HostConfig': {'Binds': ['/proc:/hostproc:ro']}
}
print(json.dumps(body))
" > "$TMPDIR_WORK/create_body.json"

curl -s --unix-socket "$SOCKET" \
  -X POST \
  -H "Content-Type: application/json" \
  -d @"$TMPDIR_WORK/create_body.json" \
  "${API}/containers/create" \
  > "$TMPDIR_WORK/create.json"

log "Create response: $(cat "$TMPDIR_WORK/create.json")"

CONTAINER_ID=$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d['Id'])" < "$TMPDIR_WORK/create.json")
if [[ -z "$CONTAINER_ID" ]]; then
  log "ERROR: Failed to get container ID"
  exit 1
fi
log "Container ID: $CONTAINER_ID"

# ── 3. Start container ─────────────────────────────────────────────────────────
log "Step 3: Starting container ..."
curl -s --unix-socket "$SOCKET" \
  -X POST \
  "${API}/containers/${CONTAINER_ID}/start" \
  > "$TMPDIR_WORK/start.txt"
log "Start response: $(cat "$TMPDIR_WORK/start.txt" || echo '<empty - 204 No Content>')"

# ── 4. Wait for container to finish ───────────────────────────────────────────
log "Step 4: Waiting for container to finish ..."
curl -s --unix-socket "$SOCKET" \
  -X POST \
  "${API}/containers/${CONTAINER_ID}/wait" \
  > "$TMPDIR_WORK/wait.json"
log "Wait response: $(cat "$TMPDIR_WORK/wait.json")"

EXIT_CODE=$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('StatusCode','unknown'))" < "$TMPDIR_WORK/wait.json" 2>/dev/null || echo "unknown")
log "Container exit code: $EXIT_CODE"

# ── 5. Get logs ────────────────────────────────────────────────────────────────
log "Step 5: Fetching container logs ..."
# Docker multiplexed log stream: strip 8-byte binary frame headers with strings(1)
curl -s --unix-socket "$SOCKET" \
  "${API}/containers/${CONTAINER_ID}/logs?stdout=true&stderr=true" \
  > "$TMPDIR_WORK/logs_raw.bin"

strings "$TMPDIR_WORK/logs_raw.bin" > "$TMPDIR_WORK/logs.txt" || true
LOG_LINES=$(wc -l < "$TMPDIR_WORK/logs.txt")
log "Logs captured: $LOG_LINES lines"
head -20 "$TMPDIR_WORK/logs.txt" >&2

# ── 6. Delete container ────────────────────────────────────────────────────────
log "Step 6: Deleting container ..."
curl -s --unix-socket "$SOCKET" \
  -X DELETE \
  "${API}/containers/${CONTAINER_ID}" \
  > "$TMPDIR_WORK/delete.txt"
log "Delete response: $(cat "$TMPDIR_WORK/delete.txt" || echo '<empty - 204 No Content>')"

# ── Save results to JSON ───────────────────────────────────────────────────────
log "Saving results to $RESULTS_FILE ..."

python3 - "$TMPDIR_WORK" "$CONTAINER_ID" "$EXIT_CODE" "$RESULTS_FILE" <<'PYEOF'
import json, sys, os

tmpdir       = sys.argv[1]
container_id = sys.argv[2]
exit_code    = sys.argv[3]
out_path     = sys.argv[4]

def read(name, binary=False):
    p = os.path.join(tmpdir, name)
    if not os.path.exists(p):
        return ""
    mode = "rb" if binary else "r"
    with open(p, mode) as f:
        return f.read()

def parse_json_lines(text):
    out = []
    for line in text.strip().splitlines():
        line = line.strip()
        if line:
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                out.append(line)
    return out

pull_text   = read("pull.txt")
create_text = read("create.json")
start_text  = read("start.txt")
wait_text   = read("wait.json")
logs_text   = read("logs.txt")
delete_text = read("delete.txt")

results = {
    "test":      "docker_socket_api_container_lifecycle",
    "timestamp": __import__("datetime").datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "steps": {
        "pull": {
            "description": "Pull alpine:latest via Docker socket API",
            "url":         "POST /v1.41/images/create?fromImage=alpine&tag=latest",
            "response":    parse_json_lines(pull_text),
        },
        "create": {
            "description": "Create container with /proc bind-mounted read-only",
            "url":         "POST /v1.41/containers/create",
            "response":    json.loads(create_text) if create_text.strip() else {},
            "container_id": container_id,
        },
        "start": {
            "description": "Start container",
            "url":         f"POST /v1.41/containers/{container_id}/start",
            "response":    start_text.strip() or "(204 No Content)",
        },
        "wait": {
            "description": "Wait for container to complete",
            "url":         f"POST /v1.41/containers/{container_id}/wait",
            "response":    json.loads(wait_text) if wait_text.strip() else {},
            "exit_code":   int(exit_code) if exit_code.isdigit() else exit_code,
        },
        "logs": {
            "description": "Retrieve container stdout/stderr logs",
            "url":         f"GET /v1.41/containers/{container_id}/logs?stdout=true&stderr=true",
            "output":      logs_text,
        },
        "delete": {
            "description": "Delete container",
            "url":         f"DELETE /v1.41/containers/{container_id}",
            "response":    delete_text.strip() or "(204 No Content)",
        },
    },
    "result": "success" if exit_code == "0" else f"completed_with_exit_code_{exit_code}",
}

with open(out_path, "w") as f:
    json.dump(results, f, indent=2)

print(json.dumps(results, indent=2))
PYEOF

log "Done. Results saved to $RESULTS_FILE"
