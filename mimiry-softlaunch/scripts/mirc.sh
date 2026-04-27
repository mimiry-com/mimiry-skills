#!/bin/bash
# mirc — CLI helper for Mimiry compute sessions
#
# Usage: mirc <command> [options]
#
# Commands:
#   auth         Authenticate and print token info
#   create       Create a new compute session
#   list         List all sessions
#   status       Show session status and details
#   logs         Get session logs
#   ssh          SSH into a running session
#   terminate    Terminate a session
#   availability Check GPU availability (public, no auth needed)
#   balance      Show current balance
#
# First invocation requires --key <path>. The key path is remembered
# for subsequent commands. Token is cached and auto-refreshed.

set -euo pipefail

SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
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
  auth                      Authenticate and print token info
  create                    Create a new compute session
  list  [--state S]         List sessions (filter: started, terminated, etc.)
  status  <id>              Show session status and details
  logs    <id> [-n N]       Get session logs (default: last 50 lines)
  ssh     <id>              SSH into a running session
  terminate <id>            Terminate a session
  availability [options]    Check GPU availability (GPUs only by default)
  balance                   Show current balance

Global options:
  --key <path>    Path to SSH key (required on first use, remembered after)
  --help          Show this help message

Create options:
  --name NAME             Session name (required, 1-64 chars)
  --image URI             Container image URI (required)
  --gpu TYPE              GPU type, e.g. T4, A100, H100_SXM (required)
  --command CMD           Command to run (omit for interactive)
  --provider PROV         Provider hint (e.g. verda)
  --location LOC          Location hint (e.g. FIN-01)
  --gpu-count N           Number of GPUs (default: 1)
  --env KEY=VALUE         Environment variable (repeatable)
  --auto-terminate MODE   on_complete, on_success, or never
  --no-ssh                Disable SSH access
  --max-duration SECS     Max session duration in seconds

Availability options:
  --provider PROV         Filter by provider
  --location LOC          Filter by location
  --family FAM            Filter by GPU family (comma-separated)
  --form-factor FF        Filter by form factor (e.g. SXM)
  --min-vram N            Minimum VRAM in GB
  --include-all           Include unavailable GPUs
  --include-cpu           Include CPU-only offerings (filtered out by default)
  --detail full           Show full details

Examples:
  mirc auth --key ~/.ssh/mimiry
  mirc create --name training --image nvcr.io/nvidia/pytorch:24.01-py3 --gpu T4
  mirc create --name job1 --image myimage:latest --gpu A100 --command "python train.py"
  mirc list
  mirc list --state started
  mirc status abc123
  mirc logs abc123 -n 100
  mirc ssh abc123
  mirc terminate abc123
  mirc availability
  mirc availability --family H100 --provider verda
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
api_post()   { curl -sf -X POST "$API$1" -H "Authorization: Bearer $MIMIRY_TOKEN" -H "Content-Type: application/json" -d "$2"; }
api_delete() { curl -sf -X DELETE "$API$1" -H "Authorization: Bearer $MIMIRY_TOKEN"; }

# ── Commands ─────────────────────────────────────────────────────────

cmd_create() {
    local name="" image="" gpu="" command="" provider="" location=""
    local gpu_count=1 auto_terminate="" no_ssh=false max_duration=""
    local -a env_vars=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --name)           name="${2:?'--name' requires a value}"; shift 2 ;;
            --image)          image="${2:?'--image' requires a value}"; shift 2 ;;
            --gpu)            gpu="${2:?'--gpu' requires a value}"; shift 2 ;;
            --command)        command="${2:?'--command' requires a value}"; shift 2 ;;
            --provider)       provider="${2:?'--provider' requires a value}"; shift 2 ;;
            --location)       location="${2:?'--location' requires a value}"; shift 2 ;;
            --gpu-count)      gpu_count="${2:?'--gpu-count' requires a value}"; shift 2 ;;
            --env)            env_vars+=("${2:?'--env' requires KEY=VALUE}"); shift 2 ;;
            --auto-terminate) auto_terminate="${2:?'--auto-terminate requires a mode'}"; shift 2 ;;
            --no-ssh)         no_ssh=true; shift ;;
            --max-duration)   max_duration="${2:?'--max-duration' requires a value}"; shift 2 ;;
            *)                die "unknown option for create: $1" ;;
        esac
    done

    [ -n "$name" ]  || die "create requires --name"
    [ -n "$image" ] || die "create requires --image"
    [ -n "$gpu" ]   || die "create requires --gpu"

    need jq
    ensure_token
    resolve_key

    local pub_key
    pub_key=$(cat "${SSH_KEY}.pub")

    # Determine auto-terminate behavior
    if [ -z "$auto_terminate" ]; then
        if [ -n "$command" ]; then
            auto_terminate="on_complete"
        else
            auto_terminate="never"
        fi
    fi

    # Build JSON with jq
    local json
    json=$(jq -n \
        --arg name "$name" \
        --arg image "$image" \
        --arg gpu "$gpu" \
        --argjson gpu_count "$gpu_count" \
        --arg key "$pub_key" \
        --arg at_mode "$auto_terminate" \
        '{
            name: $name,
            image: {uri: $image},
            gpu: {types: [$gpu], count: $gpu_count},
            ssh_public_key: $key,
            auto_terminate: {mode: $at_mode}
        }')

    # Add optional fields
    if [ -n "$command" ]; then
        json=$(echo "$json" | jq --arg cmd "$command" '. + {command: $cmd}')
    fi
    if [ "$no_ssh" = true ]; then
        json=$(echo "$json" | jq '. + {ssh_enabled: false}')
    fi
    if [ -n "$provider" ]; then
        json=$(echo "$json" | jq --arg p "$provider" '.gpu.provider = $p')
    fi
    if [ -n "$location" ]; then
        json=$(echo "$json" | jq --arg l "$location" '.gpu.location = $l')
    fi
    if [ -n "$max_duration" ]; then
        json=$(echo "$json" | jq --argjson d "$max_duration" '. + {max_duration: $d}')
    fi
    if [ ${#env_vars[@]} -gt 0 ]; then
        local env_json="{}"
        for kv in "${env_vars[@]}"; do
            local k="${kv%%=*}"
            local v="${kv#*=}"
            env_json=$(echo "$env_json" | jq --arg k "$k" --arg v "$v" '. + {($k): $v}')
        done
        json=$(echo "$json" | jq --argjson ev "$env_json" '. + {environment_vars: $ev}')
    fi

    local resp http_code
    resp=$(curl -s -w '\n%{http_code}' -X POST "$API/sessions" \
        -H "Authorization: Bearer $MIMIRY_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$json")
    http_code=$(echo "$resp" | tail -1)
    resp=$(echo "$resp" | sed '$d')

    case "$http_code" in
        202)
            local session_id
            session_id=$(echo "$resp" | jq -r '.id')
            echo "Session created: $session_id" >&2
            echo "" >&2
            echo "Next steps:" >&2
            echo "  mirc status $session_id     # check progress" >&2
            echo "  mirc ssh $session_id         # connect when running" >&2
            echo "  mirc logs $session_id        # view container logs" >&2
            echo "  mirc terminate $session_id   # stop the session" >&2
            echo "$resp" | jq .
            ;;
        402)
            echo "error: insufficient balance" >&2
            echo "$resp" | jq . >&2
            exit 1
            ;;
        *)
            echo "error (HTTP $http_code): $(echo "$resp" | jq -r '.message // .error // .')" >&2
            exit 1
            ;;
    esac
}

cmd_auth() {
    ensure_token
    echo "Token cached at $TOKEN_FILE (valid ~55 min)"
}

cmd_list() {
    local state=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --state|-s) state="${2:?'--state' requires a value}"; shift 2 ;;
            *)          die "unknown option for list: $1" ;;
        esac
    done
    ensure_token
    local endpoint="/sessions"
    if [ -n "$state" ]; then
        endpoint="/sessions?state=$state"
    fi
    api_get "$endpoint" | jq .
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

    local resp host user port
    resp=$(api_get "/sessions/$1") || die "failed to get session details"
    host=$(echo "$resp" | jq -r '.ssh.host // empty')
    user=$(echo "$resp" | jq -r '.ssh.username // empty')
    port=$(echo "$resp" | jq -r '.ssh.port // empty')

    [ -n "$host" ] || die "session $1 has no SSH host (status: $(echo "$resp" | jq -r '.status'))"

    local port_args=()
    if [ -n "$port" ] && [ "$port" != "22" ]; then
        port_args=(-p "$port")
    fi

    local target="$host"
    if [ -n "$user" ]; then target="${user}@${host}"; fi

    echo "Connecting to $target (port ${port:-22}) ..." >&2
    exec ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "${port_args[@]+"${port_args[@]}"}" "$target"
}

cmd_terminate() {
    [ -n "${1:-}" ] || die "usage: mirc terminate <session_id>"
    ensure_token
    api_delete "/sessions/$1" | jq .
    echo "Terminate request sent for $1" >&2
}

cmd_availability() {
    local provider="" location="" family="" form_factor="" min_vram=""
    local include_all=false include_cpu=false detail=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --provider)    provider="${2:?'--provider' requires a value}"; shift 2 ;;
            --location)    location="${2:?'--location' requires a value}"; shift 2 ;;
            --family)      family="${2:?'--family' requires a value}"; shift 2 ;;
            --form-factor) form_factor="${2:?'--form-factor' requires a value}"; shift 2 ;;
            --min-vram)    min_vram="${2:?'--min-vram' requires a value}"; shift 2 ;;
            --include-all) include_all=true; shift ;;
            --include-cpu) include_cpu=true; shift ;;
            --detail)      detail="${2:?'--detail' requires a value}"; shift 2 ;;
            *)             die "unknown option for availability: $1" ;;
        esac
    done

    # Build query string
    local qs=""
    [ -n "$family" ]      && qs="${qs}&gpu_family=${family}"
    [ -n "$form_factor" ] && qs="${qs}&form_factor=${form_factor}"
    [ -n "$min_vram" ]    && qs="${qs}&min_vram_gb=${min_vram}"
    [ -n "$location" ]    && qs="${qs}&location=${location}"
    [ -n "$detail" ]      && qs="${qs}&detail=${detail}"
    [ "$include_all" = true ] && qs="${qs}&available_only=false"

    # Remove leading & and prepend ?
    if [ -n "$qs" ]; then
        qs="?${qs:1}"
    fi

    # Public endpoint — no auth required
    local result
    result=$(curl -sf "${API}/availability${qs}")

    # Client-side filters
    # Filter by provider if requested (API doesn't have this param)
    if [ -n "$provider" ]; then
        result=$(echo "$result" | jq --arg p "$provider" '
            .gpu_models |= [.[] | select(.providers | any(.provider == $p))]')
    fi

    # Filter out CPU-only offerings (vram_gb == 0 or null) unless --include-cpu
    if [ "$include_cpu" = false ]; then
        result=$(echo "$result" | jq '
            .gpu_models |= [.[] | select((.vram_gb // 0) > 0)]')
    fi

    echo "$result" | jq .
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
    # Once we have a command, pass everything else through — except global flags
    if [ -n "$CMD" ]; then
        case "$1" in
            --key) OPT_KEY="${2:?'--key' requires a path}"; shift 2 ;;
            *)     CMD_ARGS+=("$1"); shift ;;
        esac
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
    create)    cmd_create "${CMD_ARGS[@]+"${CMD_ARGS[@]}"}" ;;
    list|ls)   cmd_list "${CMD_ARGS[@]+"${CMD_ARGS[@]}"}" ;;
    status)    cmd_status "${CMD_ARGS[@]+"${CMD_ARGS[@]}"}" ;;
    logs)      cmd_logs "${CMD_ARGS[@]+"${CMD_ARGS[@]}"}" ;;
    ssh)       cmd_ssh "${CMD_ARGS[@]+"${CMD_ARGS[@]}"}" ;;
    terminate)    cmd_terminate "${CMD_ARGS[@]+"${CMD_ARGS[@]}"}" ;;
    availability) cmd_availability "${CMD_ARGS[@]+"${CMD_ARGS[@]}"}" ;;
    balance)      cmd_balance "${CMD_ARGS[@]+"${CMD_ARGS[@]}"}" ;;
    help)      usage ;;
    *)         die "unknown command: $CMD (run 'mirc --help' for usage)" ;;
esac
