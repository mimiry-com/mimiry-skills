#!/bin/bash
# mirc — CLI helper for Mimiry compute sessions
#
# Usage: mirc <command> [options]
#
# Commands:
#   auth        Authenticate and print token info
#   list        List all sessions
#   status      Show session status and details
#   logs        Get session logs
#   ssh         SSH into a running session
#   terminate   Terminate a session
#   balance     Show current balance
#
# First invocation requires --key <path>. The key path is remembered
# for subsequent commands. Token is cached and auto-refreshed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOKEN_FILE="/tmp/mirc-token-$(id -u)"
KEY_FILE="/tmp/mirc-key-$(id -u)"
API_BASE="https://softlaunch.mimiry.com"
API="${API_BASE}/api/compute/v1"
TOKEN_MAX_AGE=3300  # 55 minutes

# ── Helpers ──────────────────────────────────────────────────────────

die()  { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not found"; }

usage() {
    cat <<'EOF'
Usage: mirc <command> [options]

Commands:
  auth                 Authenticate and print token info
  list                 List all sessions
  status  <id>         Show session status and details
  logs    <id> [-n N]  Get session logs (default: last 50 lines)
  ssh     <id>         SSH into a running session
  terminate <id>       Terminate a session
  balance              Show current balance

Options:
  --key <path>    Path to SSH key (required on first use, remembered after)
  --help          Show this help message

Examples:
  mirc auth --key ~/.ssh/mimiry
  mirc list
  mirc status abc123
  mirc logs abc123 -n 100
  mirc ssh abc123
  mirc terminate abc123
EOF
    exit 0
}

# Resolve the SSH key path. --key flag takes priority, then cached path.
resolve_key() {
    if [ -n "${OPT_KEY:-}" ]; then
        # Strip .pub if provided
        SSH_KEY="${OPT_KEY%.pub}"
    elif [ -f "$KEY_FILE" ]; then
        SSH_KEY="$(cat "$KEY_FILE")"
    else
        die "no SSH key configured. Run: mirc auth --key <path>"
    fi

    [ -f "$SSH_KEY" ] || die "SSH private key not found: $SSH_KEY"
    [ -f "${SSH_KEY}.pub" ] || die "public key not found: ${SSH_KEY}.pub"

    # Persist for next time
    echo "$SSH_KEY" > "$KEY_FILE"
}

# Ensure we have a valid (non-expired) token. Authenticates if needed.
ensure_token() {
    resolve_key

    # Check cached token age
    if [ -f "$TOKEN_FILE" ]; then
        local cached_time
        cached_time=$(head -1 "$TOKEN_FILE")
        local now
        now=$(date +%s)
        local age=$(( now - cached_time ))
        if [ "$age" -lt "$TOKEN_MAX_AGE" ]; then
            MIMIRY_TOKEN=$(tail -1 "$TOKEN_FILE")
            return
        fi
    fi

    # Authenticate
    need ssh-keygen; need openssl; need curl; need jq

    local fingerprint timestamp nonce tmpfile signature response token
    fingerprint=$(ssh-keygen -lf "${SSH_KEY}.pub" | awk '{print $2}')
    timestamp=$(date +%s)
    nonce=$(openssl rand -hex 16)

    tmpfile=$(mktemp)
    printf '%s\n%s\n%s' "$fingerprint" "$timestamp" "$nonce" > "$tmpfile"
    ssh-keygen -Y sign -f "$SSH_KEY" -n mimiry-auth "$tmpfile" 2>/dev/null
    signature=$(base64 -w0 "${tmpfile}.sig")
    rm -f "$tmpfile" "${tmpfile}.sig"

    response=$(curl -s -X POST "${API_BASE}/api/v1/auth/token" \
        -H "X-SSH-Fingerprint: $fingerprint" \
        -H "X-SSH-Signature: $signature" \
        -H "X-SSH-Timestamp: $timestamp" \
        -H "X-SSH-Nonce: $nonce" \
        -H "Content-Type: application/json" \
        -d '{"expires_in": 3600}')

    token=$(echo "$response" | jq -r '.access_token // empty')
    [ -n "$token" ] || die "authentication failed: $(echo "$response" | jq -r '.message // .error // "unknown error"')"

    MIMIRY_TOKEN="$token"
    echo "$timestamp" > "$TOKEN_FILE"
    echo "$token" >> "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    echo "Authenticated (fingerprint: $fingerprint)" >&2
}

api_get()    { curl -sf "$API$1" -H "Authorization: Bearer $MIMIRY_TOKEN"; }
api_delete() { curl -sf -X DELETE "$API$1" -H "Authorization: Bearer $MIMIRY_TOKEN"; }

# ── Commands ─────────────────────────────────────────────────────────

cmd_auth() {
    ensure_token
    echo "Token cached at $TOKEN_FILE (valid ~55 min)"
}

cmd_list() {
    ensure_token
    api_get "/sessions" | jq .
}

cmd_status() {
    [ -n "${1:-}" ] || die "usage: mirc status <session_id>"
    ensure_token
    api_get "/sessions/$1" | jq .
}

cmd_logs() {
    local id="" lines=50
    while [ $# -gt 0 ]; do
        case "$1" in
            -n) lines="${2:?'-n' requires a number}"; shift 2 ;;
            *)  id="$1"; shift ;;
        esac
    done
    [ -n "$id" ] || die "usage: mirc logs <session_id> [-n N]"
    ensure_token

    local resp http_code
    resp=$(curl -s -w '\n%{http_code}' "$API/sessions/$id/logs?tail=$lines" \
        -H "Authorization: Bearer $MIMIRY_TOKEN")
    http_code=$(echo "$resp" | tail -1)
    resp=$(echo "$resp" | sed '$d')

    case "$http_code" in
        200) echo "$resp" | jq -r '.logs' ;;
        503) echo "VM is still setting up — try again in a few seconds" >&2; exit 1 ;;
        409) echo "Session is not running (check status with: mirc status $id)" >&2; exit 1 ;;
        *)   echo "error (HTTP $http_code): $(echo "$resp" | jq -r '.message // .error // .')" >&2; exit 1 ;;
    esac
}

cmd_ssh() {
    [ -n "${1:-}" ] || die "usage: mirc ssh <session_id>"
    ensure_token
    resolve_key

    local resp host user
    resp=$(api_get "/sessions/$1") || die "failed to get session details"
    host=$(echo "$resp" | jq -r '.ssh.host // empty')
    user=$(echo "$resp" | jq -r '.ssh.username // empty')

    [ -n "$host" ] || die "session $1 has no SSH host (status: $(echo "$resp" | jq -r '.status'))"
    [ -n "$user" ] || die "session $1 has no SSH username"

    echo "Connecting to $user@$host ..." >&2
    exec ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${user}@${host}"
}

cmd_terminate() {
    [ -n "${1:-}" ] || die "usage: mirc terminate <session_id>"
    ensure_token
    api_delete "/sessions/$1" | jq .
    echo "Terminate request sent for $1" >&2
}

cmd_balance() {
    ensure_token
    api_get "/balance" | jq .
}

# ── Argument parsing ─────────────────────────────────────────────────

OPT_KEY=""
CMD=""
CMD_ARGS=()

while [ $# -gt 0 ]; do
    # Once we have a command, pass everything else through (including flags like -n)
    if [ -n "$CMD" ]; then
        CMD_ARGS+=("$1"); shift
        continue
    fi
    case "$1" in
        --help|-h)  usage ;;
        --key)      OPT_KEY="${2:?'--key' requires a path}"; shift 2 ;;
        -*)         die "unknown option: $1" ;;
        *)          CMD="$1"; shift ;;
    esac
done

[ -n "$CMD" ] || usage

case "$CMD" in
    auth)      cmd_auth "${CMD_ARGS[@]+"${CMD_ARGS[@]}"}" ;;
    list|ls)   cmd_list "${CMD_ARGS[@]+"${CMD_ARGS[@]}"}" ;;
    status)    cmd_status "${CMD_ARGS[@]+"${CMD_ARGS[@]}"}" ;;
    logs)      cmd_logs "${CMD_ARGS[@]+"${CMD_ARGS[@]}"}" ;;
    ssh)       cmd_ssh "${CMD_ARGS[@]+"${CMD_ARGS[@]}"}" ;;
    terminate) cmd_terminate "${CMD_ARGS[@]+"${CMD_ARGS[@]}"}" ;;
    balance)   cmd_balance "${CMD_ARGS[@]+"${CMD_ARGS[@]}"}" ;;
    help)      usage ;;
    *)         die "unknown command: $CMD (run 'mirc --help' for usage)" ;;
esac
