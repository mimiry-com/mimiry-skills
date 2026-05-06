#!/bin/bash
# mirc — CLI helper for Mimiry compute sessions and volumes
#
# Usage: mirc <namespace> <command> [options]
#
# Top-level:
#   auth                          Authenticate and print token info
#   session <subcommand>          Compute session operations
#   volume  <subcommand>          Block volume operations
#
# Session subcommands:
#   session create                Create a new compute session
#   session list                  List sessions (filter by state/operation/time)
#   session status <id>           Show session status and details
#   session logs   <id> [-n N]    Get session logs (default last 50 lines)
#   session ssh    <id>           SSH into a running session
#   session terminate <id>        Terminate a session
#   session availability          Check GPU availability (public, no auth needed)
#   session balance               Show current credit balance
#
# Volume subcommands:
#   volume create                 Create a persistent block volume
#   volume list                   List volumes (filter by state/operation/time)
#   volume status <id>            Show volume details
#   volume extend <id>            Extend (resize) a volume
#   volume delete <id>            Delete a volume
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
Usage: mirc <namespace> <command> [options]

Top-level:
  auth                       Authenticate and print token info
  install                    Symlink mirc into a user-space PATH directory
  session <subcommand>       Compute session operations
  volume  <subcommand>       Block volume operations

Global options:
  --key <path>    Path to SSH key (required on first use, remembered after)
  --help          Show this help message

install options:
  --prefix DIR    PATH directory to put the symlink in (default: ~/.local/bin)
  --force         Overwrite an existing symlink/file

Session subcommands:
  session create [opts]              Create a new compute session
  session list   [filter opts]       List sessions
  session status <id>                Show session status and details
  session logs   <id> [-n N]         Get session logs (default 50 lines)
  session ssh    <id>                SSH into a running session
  session terminate <id> [--wait]    Terminate a session
  session availability [opts]        Check GPU availability
  session balance                    Show current credit balance

Volume subcommands:
  volume create [opts]               Create a persistent block volume
  volume list   [filter opts]        List volumes
  volume status <id>                 Show volume details
  volume extend <id> --size-gb N     Extend (resize) a volume
  volume delete <id> [--wait]        Delete a volume

session create options:
  --name NAME             Session name (required, 1-64 chars)
  --image URI             Container image URI (required)
  --gpu  TYPE             GPU type, e.g. T4, A100, H100_SXM (required)
  --command CMD           Command to run (omit for interactive)
  --provider PROV         Provider hint (e.g. verda)
  --location LOC          Location hint (e.g. FIN-01)
  --gpu-count N           Number of GPUs (default 1)
  --env KEY=VALUE         Environment variable (repeatable)
  --volume NAME:PATH      Mount a block volume at PATH (repeatable)
  --auto-terminate MODE   on_complete | on_success | never
  --no-ssh                Disable SSH access
  --max-duration SECS     Max session duration in seconds
  --wait                  Block until state=started and SSH is ready

session list / volume list filter options:
  --state CSV             Inclusion list, e.g. "started,provisioned"
  --state-not CSV         Exclusion list
  --operation CSV         Primary operation inclusion (e.g. "starting,stopping")
  --operation-not CSV     Primary operation exclusion
  --updated-after RFC3339 e.g. 2026-05-03T10:00:00Z
  --updated-before RFC3339

volume create options:
  --name NAME             Volume name (required)
  --size-gb N             Size in GB (required)
  --provider PROV         Provider hint (e.g. verda)
  --location LOC          Location hint (e.g. FIN-01)
  --wait                  Block until state=provisioned

volume extend options:
  --size-gb N             New size in GB (must be larger than current)

session availability options:
  --provider PROV         Filter by provider
  --location LOC          Filter by location
  --family FAM            Filter by GPU family (comma-separated)
  --form-factor FF        Filter by form factor (e.g. SXM)
  --min-vram N            Minimum VRAM in GB
  --include-all           Include unavailable GPUs
  --include-cpu           Include CPU-only offerings (filtered out by default)
  --detail full           Show full details
  --cheapest              Print just the single cheapest matching offering
                          (one human-readable line, or JSON with --json)
  --json                  Machine-readable output (only with --cheapest)

Session state values:
  submitted, provisioned, started, completed, failed,
  stopped, provision_failed, terminated

Session operation values (primary, for filters):
  provisioning, starting, stopping, terminating

Volume state values:
  submitted, provisioned, failed, deleted

Volume operation values (primary, for filters):
  provisioning, resizing, deleting

Examples:
  mirc install                              # symlink ~/.local/bin/mirc
  mirc install --prefix ~/bin --force
  mirc auth --key ~/.ssh/mimiry
  mirc session create --name training --image nvcr.io/nvidia/pytorch:24.01-py3 --gpu T4
  mirc session list --state started
  mirc session list --state-not terminated,completed --updated-after 2026-05-01T00:00:00Z
  mirc session list --operation starting
  mirc session status abc123
  mirc session ssh abc123
  mirc session terminate abc123 --wait
  mirc session availability --family H100 --provider verda
  mirc session availability --cheapest --provider verda --json
  mirc session balance
  mirc volume create --name data1 --size-gb 100 --wait
  mirc volume list --state provisioned
  mirc volume extend vol-abc --size-gb 200
  mirc volume delete vol-abc --wait

Demo: cheapest GPU + persistent volume + interactive session
  pick=$(mirc session availability --cheapest --provider verda --json)
  gpu=$(echo "$pick"  | jq -r .gpu)
  loc=$(echo "$pick"  | jq -r .location)
  mirc volume create --name demo-vol --size-gb 10 --location "$loc" --wait
  mirc session create \
      --name demo --image docker.io/nvidia/cuda:12.2.0-base-ubuntu22.04 \
      --gpu "$gpu" --provider verda --location "$loc" \
      --volume demo-vol:/data --auto-terminate never \
      --command 'nvidia-smi | tee /data/nvidia-smi-log; sleep infinity' \
      --wait
EOF
    exit 0
}

# URL-encode a value while preserving comma (used as filter separator).
urlencode() {
    local val="$1" out="" c i
    for (( i=0; i<${#val}; i++ )); do
        c="${val:$i:1}"
        case "$c" in
            [a-zA-Z0-9._~,-]) out+="$c" ;;
            *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
        esac
    done
    printf '%s' "$out"
}

# Resolve the SSH key path. --key flag takes priority, then cached path.
resolve_key() {
    if [ -n "${OPT_KEY:-}" ]; then
        SSH_KEY="${OPT_KEY%.pub}"
    elif [ -f "$KEY_FILE" ]; then
        SSH_KEY="$(cat "$KEY_FILE")"
    else
        die "no SSH key configured. Run: mirc auth --key <path>"
    fi

    [ -f "$SSH_KEY" ] || die "SSH private key not found: $SSH_KEY"
    [ -f "${SSH_KEY}.pub" ] || die "public key not found: ${SSH_KEY}.pub"

    echo "$SSH_KEY" > "$KEY_FILE"
}

# Ensure we have a valid (non-expired) token. Authenticates if needed.
ensure_token() {
    resolve_key

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

# Build a query string from list filter flags. Sets QS variable.
parse_list_filters() {
    local state="" state_not="" operation="" operation_not="" updated_after="" updated_before=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --state)           state="${2:?'--state' requires a value}"; shift 2 ;;
            --state-not)       state_not="${2:?'--state-not' requires a value}"; shift 2 ;;
            --operation)       operation="${2:?'--operation' requires a value}"; shift 2 ;;
            --operation-not)   operation_not="${2:?'--operation-not' requires a value}"; shift 2 ;;
            --updated-after)   updated_after="${2:?'--updated-after' requires a value}"; shift 2 ;;
            --updated-before)  updated_before="${2:?'--updated-before' requires a value}"; shift 2 ;;
            *) die "unknown filter option: $1" ;;
        esac
    done
    QS=""
    [ -n "$state" ]          && QS="${QS}&state=$(urlencode "$state")"
    [ -n "$state_not" ]      && QS="${QS}&state_not=$(urlencode "$state_not")"
    [ -n "$operation" ]      && QS="${QS}&operation=$(urlencode "$operation")"
    [ -n "$operation_not" ]  && QS="${QS}&operation_not=$(urlencode "$operation_not")"
    [ -n "$updated_after" ]  && QS="${QS}&updated_after=$(urlencode "$updated_after")"
    [ -n "$updated_before" ] && QS="${QS}&updated_before=$(urlencode "$updated_before")"
    if [ -n "$QS" ]; then QS="?${QS:1}"; fi
}

# ── auth ─────────────────────────────────────────────────────────────

cmd_auth() {
    ensure_token
    echo "Token cached at $TOKEN_FILE (valid ~55 min)"
}

# ── install ──────────────────────────────────────────────────────────

# Place a `mirc` symlink in a user-space PATH directory so the script can be
# invoked by name. The symlink points at the canonical install location
# ($HOME/.claude/skills/mimiry-softlaunch/scripts/mirc.sh). If that file
# doesn't exist yet, the running script copies itself there first — so
# `mirc install` works straight out of a fresh repo checkout.
cmd_install() {
    local prefix="$HOME/.local/bin"
    local force=false
    local canonical="$HOME/.claude/skills/mimiry-softlaunch/scripts/mirc.sh"

    while [ $# -gt 0 ]; do
        case "$1" in
            --prefix) prefix="${2:?'--prefix' requires a path}"; shift 2 ;;
            --force)  force=true; shift ;;
            *)        die "unknown option for install: $1" ;;
        esac
    done

    local link="$prefix/mirc"
    local self
    self=$(realpath "${BASH_SOURCE[0]}")

    # Make sure the canonical install location holds a copy of mirc. If it's
    # missing, copy ourselves there. If it exists but differs from the running
    # script, leave it alone unless --force is given (avoids surprise overwrite
    # of a user-edited canonical copy).
    mkdir -p "$(dirname "$canonical")"
    if [ ! -f "$canonical" ]; then
        cp "$self" "$canonical"
        chmod +x "$canonical"
        echo "Copied $self → $canonical" >&2
    elif ! cmp -s "$canonical" "$self"; then
        if [ "$force" = true ]; then
            cp "$self" "$canonical"
            chmod +x "$canonical"
            echo "Overwrote $canonical with $self (--force)" >&2
        else
            echo "note: $canonical exists and differs in content from $self." >&2
            echo "      keeping the existing copy. Re-run with --force to overwrite." >&2
        fi
    fi

    mkdir -p "$prefix"

    # Decide what to do with whatever currently lives at $link.
    if [ -L "$link" ]; then
        local current
        current=$(readlink "$link")
        if [ "$current" = "$canonical" ]; then
            echo "Already installed: $link → $canonical" >&2
        elif [ "$force" = true ]; then
            rm -f "$link"
            ln -s "$canonical" "$link"
            echo "Replaced symlink: $link → $canonical (was → $current)" >&2
        else
            die "$link is a symlink to $current. Re-run with --force to replace."
        fi
    elif [ -e "$link" ]; then
        if [ "$force" = true ]; then
            rm -f "$link"
            ln -s "$canonical" "$link"
            echo "Replaced regular file: $link → $canonical" >&2
        else
            die "$link exists and is not a symlink. Re-run with --force to replace."
        fi
    else
        ln -s "$canonical" "$link"
        echo "Installed: $link → $canonical" >&2
    fi

    # PATH check — the symlink is useless if the prefix isn't on PATH.
    case ":$PATH:" in
        *":$prefix:"*) ;;
        *)
            echo "" >&2
            echo "warn: $prefix is not on PATH. Add to your shell rc:" >&2
            echo "  export PATH=\"$prefix:\$PATH\"" >&2
            ;;
    esac
}

# ── session subcommands ──────────────────────────────────────────────

cmd_session_create() {
    local name="" image="" gpu="" command="" provider="" location=""
    local gpu_count=1 auto_terminate="" no_ssh=false max_duration=""
    local wait_flag=false
    local -a env_vars=()
    local -a volumes=()

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
            --volume)         volumes+=("${2:?'--volume' requires NAME:MOUNT_PATH}"); shift 2 ;;
            --auto-terminate) auto_terminate="${2:?'--auto-terminate requires a mode'}"; shift 2 ;;
            --no-ssh)         no_ssh=true; shift ;;
            --max-duration)   max_duration="${2:?'--max-duration' requires a value}"; shift 2 ;;
            --wait)           wait_flag=true; shift ;;
            *)                die "unknown option for session create: $1" ;;
        esac
    done

    [ -n "$name" ]  || die "session create requires --name"
    [ -n "$image" ] || die "session create requires --image"
    [ -n "$gpu" ]   || die "session create requires --gpu"

    need jq
    ensure_token
    resolve_key

    local pub_key
    pub_key=$(cat "${SSH_KEY}.pub")

    if [ -z "$auto_terminate" ]; then
        if [ -n "$command" ]; then auto_terminate="on_complete"; else auto_terminate="never"; fi
    fi

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
    if [ ${#volumes[@]} -gt 0 ]; then
        local vols_json="[]"
        for spec in "${volumes[@]}"; do
            local vname="${spec%%:*}"
            local vpath="${spec#*:}"
            [ -n "$vname" ] && [ "$vname" != "$spec" ] || die "--volume must be NAME:MOUNT_PATH (got: $spec)"
            [ -n "$vpath" ] || die "--volume must be NAME:MOUNT_PATH (got: $spec)"
            vols_json=$(echo "$vols_json" | jq --arg n "$vname" --arg p "$vpath" \
                '. + [{volume_name: $n, mount_path: $p}]')
        done
        json=$(echo "$json" | jq --argjson v "$vols_json" '. + {volume_mounts: $v}')
    fi

    local resp http_code session_id
    resp=$(curl -s -w '\n%{http_code}' -X POST "$API/sessions" \
        -H "Authorization: Bearer $MIMIRY_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$json")
    http_code=$(echo "$resp" | tail -1)
    resp=$(echo "$resp" | sed '$d')

    case "$http_code" in
        202)
            session_id=$(echo "$resp" | jq -r '.id')
            echo "Session created: $session_id" >&2
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

    if [ "$wait_flag" = false ]; then
        echo "" >&2
        echo "Next steps:" >&2
        echo "  mirc session status $session_id     # check progress" >&2
        echo "  mirc session ssh $session_id         # connect when running" >&2
        echo "  mirc session logs $session_id        # view container logs" >&2
        echo "  mirc session terminate $session_id   # stop the session" >&2
        echo "$resp" | jq .
        return
    fi

    # --wait: poll until state=started AND ssh.host populated, or fail on
    # terminal/error states. Refresh the token periodically since boot can
    # exceed the JWT lifetime.
    echo "Waiting for session to reach state=started + SSH ready ..." >&2
    local start_ts now elapsed state operation ssh_host
    local first_404_elapsed=-1 ever_seen_200=false
    start_ts=$(date +%s)
    local last_refresh=$start_ts
    local timeout_secs=900
    while :; do
        now=$(date +%s)
        elapsed=$(( now - start_ts ))
        if (( now - last_refresh > 1800 )); then
            ensure_token
            last_refresh=$now
        fi
        local resp http_code detail
        resp=$(curl -s -w '\n%{http_code}' "$API/sessions/$session_id" \
            -H "Authorization: Bearer $MIMIRY_TOKEN") || resp=""
        http_code=$(echo "$resp" | tail -1)
        detail=$(echo "$resp" | sed '$d')
        case "$http_code" in
            200)
                ever_seen_200=true
                state=$(echo "$detail" | jq -r '.state // "unknown"')
                operation=$(echo "$detail" | jq -r '.operation // ""')
                ssh_host=$(echo "$detail" | jq -r '.ssh.host // empty')
                case "$state" in
                    failed|provision_failed|terminated|stopped)
                        echo "" >&2
                        echo "$detail" | jq . >&2
                        die "session reached terminal state=$state before becoming ready"
                        ;;
                    started)
                        if [ -n "$ssh_host" ]; then
                            printf "\rstate=%-12s operation=%-30s (%ds) — ready\n" "$state" "$operation" "$elapsed" >&2
                            echo "$detail" | jq .
                            return
                        fi
                        ;;
                esac
                printf "\rstate=%-12s operation=%-30s (%ds)" "$state" "$operation" "$elapsed" >&2
                ;;
            401)
                ensure_token
                last_refresh=$now
                printf "\rrefreshed token (%ds)" "$elapsed" >&2
                ;;
            404)
                if [ "$ever_seen_200" = false ]; then
                    if (( first_404_elapsed < 0 )); then first_404_elapsed=$elapsed; fi
                    local nf_age=$(( elapsed - first_404_elapsed ))
                    if (( nf_age >= 60 )); then
                        echo "" >&2
                        die "GET /sessions/$session_id has been HTTP 404 for ${nf_age}s — session create likely never reached the cache. Run: mirc session list"
                    fi
                    printf "\rwaiting (HTTP 404 — not yet in cache, %ds)" "$nf_age" >&2
                else
                    echo "" >&2
                    die "GET /sessions/$session_id is now 404 after previously being visible"
                fi
                ;;
            *)
                printf "\rGET /sessions/%s → HTTP %s (%ds)" "$session_id" "$http_code" "$elapsed" >&2
                ;;
        esac
        if (( elapsed >= timeout_secs )); then
            echo "" >&2
            die "timed out after ${timeout_secs}s waiting for session to start"
        fi
        sleep 5
    done
}

cmd_session_list() {
    parse_list_filters "$@"
    ensure_token
    api_get "/sessions${QS}" | jq .
}

cmd_session_status() {
    [ -n "${1:-}" ] || die "usage: mirc session status <session_id>"
    ensure_token
    api_get "/sessions/$1" | jq .
}

cmd_session_logs() {
    local id="" lines=50
    while [ $# -gt 0 ]; do
        case "$1" in
            -n) lines="${2:?'-n' requires a number}"; shift 2 ;;
            *)  id="$1"; shift ;;
        esac
    done
    [ -n "$id" ] || die "usage: mirc session logs <session_id> [-n N]"
    ensure_token

    local resp http_code
    resp=$(curl -s -w '\n%{http_code}' "$API/sessions/$id/logs?tail=$lines" \
        -H "Authorization: Bearer $MIMIRY_TOKEN")
    http_code=$(echo "$resp" | tail -1)
    resp=$(echo "$resp" | sed '$d')

    case "$http_code" in
        200) echo "$resp" | jq -r '.logs' ;;
        503) echo "VM is still setting up — try again in a few seconds" >&2; exit 1 ;;
        409) echo "Session is not running (check: mirc session status $id)" >&2; exit 1 ;;
        *)   echo "error (HTTP $http_code): $(echo "$resp" | jq -r '.message // .error // .')" >&2; exit 1 ;;
    esac
}

cmd_session_ssh() {
    [ -n "${1:-}" ] || die "usage: mirc session ssh <session_id>"
    ensure_token
    resolve_key

    local resp host user port
    resp=$(api_get "/sessions/$1") || die "failed to get session details"
    host=$(echo "$resp" | jq -r '.ssh.host // empty')
    user=$(echo "$resp" | jq -r '.ssh.username // empty')
    port=$(echo "$resp" | jq -r '.ssh.port // empty')

    [ -n "$host" ] || die "session $1 has no SSH host (state: $(echo "$resp" | jq -r '.state'), operation: $(echo "$resp" | jq -r '.operation // ""'))"

    local port_args=()
    if [ -n "$port" ] && [ "$port" != "22" ]; then
        port_args=(-p "$port")
    fi

    local target="$host"
    if [ -n "$user" ]; then target="${user}@${host}"; fi

    echo "Connecting to $target (port ${port:-22}) ..." >&2
    exec ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "${port_args[@]+"${port_args[@]}"}" "$target"
}

cmd_session_terminate() {
    local id="" wait_flag=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --wait) wait_flag=true; shift ;;
            -*)     die "unknown option for session terminate: $1" ;;
            *)      id="$1"; shift ;;
        esac
    done
    [ -n "$id" ] || die "usage: mirc session terminate <session_id> [--wait]"
    ensure_token
    api_delete "/sessions/$id" | jq . 2>/dev/null || true
    echo "Terminate request sent for $id" >&2

    [ "$wait_flag" = true ] || return

    echo "Waiting for session to reach terminal state ..." >&2
    local start_ts now elapsed state operation detail timeout_secs=300
    start_ts=$(date +%s)
    while :; do
        now=$(date +%s)
        elapsed=$(( now - start_ts ))
        local resp http_code
        resp=$(curl -s -w '\n%{http_code}' "$API/sessions/$id" \
            -H "Authorization: Bearer $MIMIRY_TOKEN")
        http_code=$(echo "$resp" | tail -1)
        detail=$(echo "$resp" | sed '$d')
        if [ "$http_code" = "404" ]; then
            printf "\rsession removed (%ds)\n" "$elapsed" >&2
            return
        fi
        state=$(echo "$detail"     | jq -r '.state // "unknown"')
        operation=$(echo "$detail" | jq -r '.operation // ""')
        case "$state" in
            terminated|completed|failed|stopped|provision_failed)
                printf "\rstate=%-12s operation=%-30s (%ds)\n" "$state" "$operation" "$elapsed" >&2
                return
                ;;
        esac
        if (( elapsed >= timeout_secs )); then
            echo "" >&2
            die "timed out after ${timeout_secs}s (last state=$state, operation=$operation)"
        fi
        printf "\rstate=%-12s operation=%-30s (%ds)" "$state" "$operation" "$elapsed" >&2
        sleep 3
    done
}

cmd_session_availability() {
    local provider="" location="" family="" form_factor="" min_vram=""
    local include_all=false include_cpu=false detail=""
    local cheapest=false as_json=false

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
            --cheapest)    cheapest=true; shift ;;
            --json)        as_json=true; shift ;;
            *)             die "unknown option for session availability: $1" ;;
        esac
    done

    local qs=""
    [ -n "$family" ]      && qs="${qs}&gpu_family=${family}"
    [ -n "$form_factor" ] && qs="${qs}&form_factor=${form_factor}"
    [ -n "$min_vram" ]    && qs="${qs}&min_vram_gb=${min_vram}"
    [ -n "$location" ]    && qs="${qs}&location=${location}"
    [ -n "$detail" ]      && qs="${qs}&detail=${detail}"
    [ "$include_all" = true ] && qs="${qs}&available_only=false"

    if [ -n "$qs" ]; then qs="?${qs:1}"; fi

    local result
    result=$(curl -sf "${API}/availability${qs}")

    if [ -n "$provider" ]; then
        result=$(echo "$result" | jq --arg p "$provider" '
            .gpu_models |= [.[] | select(.providers | any(.provider == $p))]')
    fi
    if [ "$include_cpu" = false ]; then
        result=$(echo "$result" | jq '
            .gpu_models |= [.[] | select((.vram_gb // 0) > 0)]')
    fi

    if [ "$cheapest" = false ]; then
        echo "$result" | jq .
        return
    fi

    # --cheapest: flatten to one row per (gpu, provider, location), filter by
    # --provider if given, sort by hourly_rate, return the top row.
    local pick
    pick=$(echo "$result" | jq --arg p "$provider" '
        [ .gpu_models[]
          | select(.available == true and (.vram_gb // 0) > 0)
          | .name as $gpu | .display_name as $disp | .vram_gb as $vram
          | .currency as $cur
          | .providers[]
          | select(($p == "") or (.provider == $p))
          | .provider as $prov | .hourly_rate as $rate
          | .locations[]
          | { gpu: $gpu, display_name: $disp, vram_gb: $vram,
              provider: $prov, hourly_rate: $rate, currency: $cur, location: . } ]
        | sort_by(.hourly_rate)
        | .[0] // empty')

    if [ -z "$pick" ] || [ "$pick" = "null" ]; then
        die "no available GPU offerings match the filter"
    fi

    if [ "$as_json" = true ]; then
        echo "$pick" | jq -c .
    else
        echo "$pick" | jq -r '
            "\(.display_name) (\(.gpu))  provider=\(.provider)  location=\(.location)  \(.currency) \(.hourly_rate)/hr"'
    fi
}

cmd_session_balance() {
    ensure_token
    api_get "/balance" | jq .
}

# Dispatch a session subcommand.
cmd_session() {
    local sub="${1:-}"
    [ -n "$sub" ] || die "usage: mirc session <subcommand> [options]"
    shift
    case "$sub" in
        create)       cmd_session_create "$@" ;;
        list|ls)      cmd_session_list "$@" ;;
        status)       cmd_session_status "$@" ;;
        logs)         cmd_session_logs "$@" ;;
        ssh)          cmd_session_ssh "$@" ;;
        terminate)    cmd_session_terminate "$@" ;;
        availability) cmd_session_availability "$@" ;;
        balance)      cmd_session_balance "$@" ;;
        *) die "unknown session subcommand: $sub (run 'mirc --help' for usage)" ;;
    esac
}

# ── volume subcommands ───────────────────────────────────────────────

cmd_volume_create() {
    local name="" size_gb="" provider="" location="" wait_flag=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --name)     name="${2:?'--name' requires a value}"; shift 2 ;;
            --size-gb)  size_gb="${2:?'--size-gb' requires a value}"; shift 2 ;;
            --provider) provider="${2:?'--provider' requires a value}"; shift 2 ;;
            --location) location="${2:?'--location' requires a value}"; shift 2 ;;
            --wait)     wait_flag=true; shift ;;
            *) die "unknown option for volume create: $1" ;;
        esac
    done
    [ -n "$name" ]    || die "volume create requires --name"
    [ -n "$size_gb" ] || die "volume create requires --size-gb"

    need jq
    ensure_token

    local json
    json=$(jq -n --arg name "$name" --argjson size_gb "$size_gb" \
        '{name: $name, size_gb: $size_gb}')
    [ -n "$provider" ] && json=$(echo "$json" | jq --arg p "$provider" '. + {provider: $p}')
    [ -n "$location" ] && json=$(echo "$json" | jq --arg l "$location" '. + {location: $l}')

    local resp http_code vol_id
    resp=$(curl -s -w '\n%{http_code}' -X POST "$API/volumes" \
        -H "Authorization: Bearer $MIMIRY_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$json")
    http_code=$(echo "$resp" | tail -1)
    resp=$(echo "$resp" | sed '$d')

    case "$http_code" in
        200|201|202)
            vol_id=$(echo "$resp" | jq -r '.id // empty')
            [ -n "$vol_id" ] || die "create succeeded (HTTP $http_code) but no id in response"
            echo "Volume created: $vol_id" >&2
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

    if [ "$wait_flag" = false ]; then
        echo "" >&2
        echo "Next steps:" >&2
        echo "  mirc volume status $vol_id     # check progress" >&2
        echo "  mirc volume extend $vol_id --size-gb N  # resize" >&2
        echo "  mirc volume delete $vol_id     # delete" >&2
        echo "$resp" | jq .
        return
    fi

    echo "Waiting for volume to reach state=provisioned ..." >&2
    local start_ts now elapsed state operation timeout_secs=300
    local first_404_elapsed=-1 ever_seen_200=false
    start_ts=$(date +%s)
    while :; do
        now=$(date +%s)
        elapsed=$(( now - start_ts ))
        local resp http_code detail
        resp=$(curl -s -w '\n%{http_code}' "$API/volumes/$vol_id" \
            -H "Authorization: Bearer $MIMIRY_TOKEN") || resp=""
        http_code=$(echo "$resp" | tail -1)
        detail=$(echo "$resp" | sed '$d')
        case "$http_code" in
            200)
                ever_seen_200=true
                state=$(echo "$detail"     | jq -r '.state // "unknown"')
                operation=$(echo "$detail" | jq -r '.operation // ""')
                case "$state" in
                    provisioned)
                        printf "\rstate=%-12s operation=%-20s (%ds) — ready\n" "$state" "$operation" "$elapsed" >&2
                        echo "$detail" | jq .
                        return
                        ;;
                    failed)
                        echo "" >&2
                        echo "$detail" | jq . >&2
                        die "volume reached state=failed"
                        ;;
                esac
                printf "\rstate=%-12s operation=%-20s (%ds)" "$state" "$operation" "$elapsed" >&2
                ;;
            401)
                ensure_token
                printf "\rrefreshed token (%ds)" "$elapsed" >&2
                ;;
            404)
                if [ "$ever_seen_200" = false ]; then
                    if (( first_404_elapsed < 0 )); then first_404_elapsed=$elapsed; fi
                    local nf_age=$(( elapsed - first_404_elapsed ))
                    if (( nf_age >= 60 )); then
                        echo "" >&2
                        die "GET /volumes/$vol_id has been HTTP 404 for ${nf_age}s — volume create likely never reached the cache. Run: mirc volume list"
                    fi
                    printf "\rwaiting (HTTP 404 — not yet in cache, %ds)" "$nf_age" >&2
                else
                    echo "" >&2
                    die "GET /volumes/$vol_id is now 404 after previously being visible — volume disappeared"
                fi
                ;;
            *)
                printf "\rGET /volumes/%s → HTTP %s (%ds)" "$vol_id" "$http_code" "$elapsed" >&2
                ;;
        esac
        if (( elapsed >= timeout_secs )); then
            echo "" >&2
            die "timed out after ${timeout_secs}s waiting for volume to provision"
        fi
        sleep 3
    done
}

cmd_volume_list() {
    parse_list_filters "$@"
    ensure_token
    api_get "/volumes${QS}" | jq .
}

cmd_volume_status() {
    [ -n "${1:-}" ] || die "usage: mirc volume status <volume_id>"
    ensure_token
    api_get "/volumes/$1" | jq .
}

cmd_volume_extend() {
    local id="" size_gb=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --size-gb) size_gb="${2:?'--size-gb' requires a value}"; shift 2 ;;
            -*)        die "unknown option for volume extend: $1" ;;
            *)         id="$1"; shift ;;
        esac
    done
    [ -n "$id" ]      || die "usage: mirc volume extend <volume_id> --size-gb N"
    [ -n "$size_gb" ] || die "volume extend requires --size-gb"

    need jq
    ensure_token

    local json
    json=$(jq -n --argjson size_gb "$size_gb" '{size_gb: $size_gb}')

    local resp http_code
    resp=$(curl -s -w '\n%{http_code}' -X PATCH "$API/volumes/$id" \
        -H "Authorization: Bearer $MIMIRY_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$json")
    http_code=$(echo "$resp" | tail -1)
    resp=$(echo "$resp" | sed '$d')

    case "$http_code" in
        200|202) echo "$resp" | jq . ;;
        *) echo "error (HTTP $http_code): $(echo "$resp" | jq -r '.message // .error // .')" >&2; exit 1 ;;
    esac
}

cmd_volume_delete() {
    local id="" wait_flag=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --wait) wait_flag=true; shift ;;
            -*)     die "unknown option for volume delete: $1" ;;
            *)      id="$1"; shift ;;
        esac
    done
    [ -n "$id" ] || die "usage: mirc volume delete <volume_id> [--wait]"
    ensure_token
    api_delete "/volumes/$id" | jq . 2>/dev/null || true
    echo "Delete request sent for $id" >&2

    [ "$wait_flag" = true ] || return

    echo "Waiting for volume to reach state=deleted ..." >&2
    local start_ts now elapsed state operation detail timeout_secs=180
    start_ts=$(date +%s)
    while :; do
        now=$(date +%s)
        elapsed=$(( now - start_ts ))
        local resp http_code
        resp=$(curl -s -w '\n%{http_code}' "$API/volumes/$id" \
            -H "Authorization: Bearer $MIMIRY_TOKEN")
        http_code=$(echo "$resp" | tail -1)
        detail=$(echo "$resp" | sed '$d')
        if [ "$http_code" = "404" ]; then
            printf "\rvolume removed (%ds)\n" "$elapsed" >&2
            return
        fi
        state=$(echo "$detail"     | jq -r '.state // "unknown"')
        operation=$(echo "$detail" | jq -r '.operation // ""')
        if [ "$state" = "deleted" ]; then
            printf "\rstate=%-12s operation=%-20s (%ds)\n" "$state" "$operation" "$elapsed" >&2
            return
        fi
        if (( elapsed >= timeout_secs )); then
            echo "" >&2
            die "timed out after ${timeout_secs}s (last state=$state, operation=$operation)"
        fi
        printf "\rstate=%-12s operation=%-20s (%ds)" "$state" "$operation" "$elapsed" >&2
        sleep 3
    done
}

# Dispatch a volume subcommand.
cmd_volume() {
    local sub="${1:-}"
    [ -n "$sub" ] || die "usage: mirc volume <subcommand> [options]"
    shift
    case "$sub" in
        create)    cmd_volume_create "$@" ;;
        list|ls)   cmd_volume_list "$@" ;;
        status)    cmd_volume_status "$@" ;;
        extend)    cmd_volume_extend "$@" ;;
        delete)    cmd_volume_delete "$@" ;;
        *) die "unknown volume subcommand: $sub (run 'mirc --help' for usage)" ;;
    esac
}

# ── Argument parsing ─────────────────────────────────────────────────

OPT_KEY=""
CMD=""
CMD_ARGS=()

while [ $# -gt 0 ]; do
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
    auth)    cmd_auth "${CMD_ARGS[@]+"${CMD_ARGS[@]}"}" ;;
    install) cmd_install "${CMD_ARGS[@]+"${CMD_ARGS[@]}"}" ;;
    session) cmd_session "${CMD_ARGS[@]+"${CMD_ARGS[@]}"}" ;;
    volume)  cmd_volume "${CMD_ARGS[@]+"${CMD_ARGS[@]}"}" ;;
    help)    usage ;;
    *) die "unknown command: $CMD (run 'mirc --help' for usage)" ;;
esac
