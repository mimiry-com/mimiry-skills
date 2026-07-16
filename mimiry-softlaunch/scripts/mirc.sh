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
# API_BASE defaults to softlaunch (mirc's canonical target) but is
# overridable via MIMIRY_API_BASE for cross-instance testing:
#   MIMIRY_API_BASE=https://beta.mimiry.com mirc <cmd>
# Also flushes the cached JWT + key-path when the base changes, so a
# stale token from a different instance can't cause silent auth errors.
API_BASE="${MIMIRY_API_BASE:-https://softlaunch.mimiry.com}"
if [ -n "${MIMIRY_API_BASE:-}" ]; then
    # Non-default target — segregate token/key cache per host so switching
    # instances doesn't leak state across.
    _api_host="$(echo "$API_BASE" | sed 's|^https\?://||; s|/.*$||')"
    TOKEN_FILE="/tmp/mirc-token-$(id -u)-${_api_host}"
    KEY_FILE="/tmp/mirc-key-$(id -u)-${_api_host}"
fi
API="${API_BASE}/api/compute/v1"
AUTH_API="${API_BASE}/api/auth/v1"
TOKEN_MAX_AGE=3300  # 55 minutes

# ── Helpers ──────────────────────────────────────────────────────────

die()  { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not found"; }

# ── help system ──────────────────────────────────────────────────────
# Help is hierarchical:
#   mirc --help                          → top_help
#   mirc <namespace> --help              → <namespace>_help (subcommands)
#   mirc <namespace> <command> --help    → <namespace>_<command>_help
# Each helper prints to stdout and exits 0. _has_help_flag is the gate
# that callers test before parsing real arguments.

_has_help_flag() {
    for arg in "$@"; do
        case "$arg" in --help|-h) return 0 ;; esac
    done
    return 1
}

top_help() {
    cat <<'EOF'
Usage: mirc <command> [args...]

mirc — CLI for the Mimiry compute platform. Auth, manage GPU compute
sessions and persistent block volumes, query GPU availability.

Commands:
  auth                   Authenticate and print token info
  install                Symlink mirc into a user-space PATH directory
  session <subcommand>   Compute session operations
  volume  <subcommand>   Block volume operations
  ssh     <subcommand>   Register SSH keys via the guided 2FA flow

Global options:
  --key <path>    Path to SSH key (required on first use, remembered after)
  --help, -h      Show this help message (works at every level)

Discover more:
  mirc auth --help
  mirc install --help
  mirc session --help          # list session subcommands
  mirc volume --help           # list volume subcommands
  mirc session create --help   # detailed help for one command

Quick examples:
  mirc install                                       # symlink to ~/.local/bin/mirc
  mirc auth --key ~/.ssh/mimiry
  mirc session list --state started
  mirc volume create --name data1 --size-gb 100 --wait
  mirc session availability --cheapest --provider verda --json

Demo — cheapest GPU + persistent volume + interactive session:
  pick=$(mirc session availability --cheapest --provider verda --json)
  gpu=$(echo "$pick" | jq -r .gpu)
  loc=$(echo "$pick" | jq -r .location)
  mirc volume create --name demo-vol --size-gb 100 --location "$loc" --wait
  mirc session create \
      --name demo --image docker.io/nvidia/cuda:12.2.0-base-ubuntu22.04 \
      --gpu "$gpu" --provider verda --location "$loc" \
      --volume demo-vol:/data --auto-terminate never \
      --command 'nvidia-smi | tee /data/nvidia-smi-log; sleep infinity' \
      --wait
EOF
    exit 0
}

auth_help() {
    cat <<'EOF'
Usage: mirc auth [--key <path>]

Authenticate to the platform via SSH-key signature and cache the resulting
JWT for ~55 minutes. The --key path is remembered for subsequent commands;
you only need to pass it on first use or when changing keys.

Options:
  --key <path>    Path to your SSH private key (the public key must be
                  registered with the platform).

Example:
  mirc auth --key ~/.ssh/mimiry
EOF
    exit 0
}

install_help() {
    cat <<'EOF'
Usage: mirc install [--prefix DIR] [--force]

Symlinks mirc into a user-space PATH directory so you can invoke it by
name from any shell. Idempotent — re-running with no flags is a no-op
when the symlink already points at the canonical install location.

Options:
  --prefix DIR    PATH directory to put the symlink in (default: ~/.local/bin)
  --force         Overwrite an existing symlink or regular file at <prefix>/mirc

Examples:
  mirc install
  mirc install --prefix ~/bin --force
EOF
    exit 0
}

session_help() {
    cat <<'EOF'
Usage: mirc session <subcommand> [args...]

Compute session operations.

Subcommands:
  create [opts]              Create a new compute session
  list   [filter opts]       List sessions (paginated, filterable)
  status <id>                Show session status and details
  logs   <id> [-n N]         Tail container logs (default 50 lines)
  ssh    <id>                SSH into a running session
  terminate <id> [--wait]    Terminate a session
  availability [opts]        Check GPU availability and pricing
  balance                    Show current credit balance

State values:     submitted, provisioned, started, completed, failed,
                  stopped, provision_failed, terminated
Operation values: provisioning, starting, stopping, terminating
                  (primary values; backend prefix-matches compounds)

Run `mirc session <subcommand> --help` for details on a specific command.
EOF
    exit 0
}

session_create_help() {
    cat <<'EOF'
Usage: mirc session create --name NAME --image URI (--gpu TYPE | <criteria>) [opts]

Create a new compute session. By default returns immediately with the
session id; pass --wait to block until SSH is ready.

The server picks a GPU either from an explicit --gpu list or from criteria
filters. With criteria, on capacity failure at the locked location the
server retries with the next-best candidate (up to --max-attempts).

Required:
  --name NAME             Session name (1-64 chars)
  --image URI             Container image URI
  (one of:)
    --gpu  TYPE[,TYPE…]   Explicit GPU type list, in preference order
    --family FAM[,FAM…]   Criteria: GPU family (e.g. H100,A100), in pref order
    --min-vram N          Criteria: minimum VRAM in GB
    --form-factor FF      Criteria: PCIe or SXM

Optional:
  --command CMD           Command to run (omit for interactive shell)
  --provider PROV         Provider hint (e.g. verda)
  --location LOC          Location hint (e.g. FIN-01)
  --gpu-count N           Number of GPUs (default 1)
  --env KEY=VALUE         Environment variable (repeatable)
  --volume NAME:PATH      Mount a block volume at PATH (repeatable)
  --auto-terminate MODE   on_complete | on_success | never
  --no-ssh                Disable SSH access
  --max-duration SECS     Max session duration in seconds
  --priority KEY[,KEY…]   Ordered sort keys: PRICE | GPU | FAMILY |
                          FORM_FACTOR | VRAM. Default ["GPU"] when --gpu
                          is the only criterion; ["PRICE"] otherwise.
  --cheapest              Shortcut for --priority PRICE
  --max-attempts N        Retry cap on provider capacity errors (default 3)
  --max-price EUR         Reject candidates above this hourly rate (EUR,
                          post-margin — same number availability shows)
  --wait                  Block until state=started and SSH is ready

GPU naming:
  Mimiry canonical names follow the pattern {Family}_{Vram}G_{FormFactor}.
  Examples: T4_16G_PCIe, A100_80G_SXM, H100_80G_SXM, H200_141G_SXM.
  Legacy short forms (T4, A100_80G, H100) continue to work — api-compute
  translates them at the API boundary. New scripts should prefer the
  canonical form for clarity.
  Full spec: plans/architecture/GPU-NAMING-STANDARD.md

Examples:
  # Canonical (preferred):
  mirc session create --name training --image nvcr.io/nvidia/pytorch:24.01-py3 --gpu T4_16G_PCIe
  mirc session create --name explore --image docker.io/nvidia/cuda:12.2.0-base-ubuntu22.04 \
      --gpu A100_80G_SXM --provider verda --wait
  # Criteria-based (server picks the specific canonical name):
  mirc session create --name h100-train --image nvcr.io/nvidia/pytorch:24.01-py3 \
      --family H100 --min-vram 80 --priority PRICE
  mirc session create --name demo --image docker.io/nvidia/cuda:12.2.0-base-ubuntu22.04 \
      --gpu RTX_96G --provider verda --location FIN-03 \
      --volume data1:/data --auto-terminate never --wait
  # Legacy short forms (still accepted — translated to canonical at API entry):
  mirc session create --name training --image nvcr.io/nvidia/pytorch:24.01-py3 --gpu T4
  mirc session create --name explore --image docker.io/nvidia/cuda:12.2.0-base-ubuntu22.04 \
      --cheapest --provider verda --location FIN-02 --wait
EOF
    exit 0
}

session_list_help() {
    cat <<'EOF'
Usage: mirc session list [filter opts]

List sessions (paginated, sorted newest-first). Default filter excludes
no states — pass an explicit --state or --state-not if you want to narrow.

Filter options:
  --state CSV             Inclusion list, e.g. "started,provisioned"
  --state-not CSV         Exclusion list
  --operation CSV         Primary operation inclusion (e.g. "starting,stopping")
  --operation-not CSV     Primary operation exclusion
  --updated-after RFC3339 e.g. 2026-05-03T10:00:00Z
  --updated-before RFC3339
  --all                   Sugar for --state with every session state.
                          Bypasses any future default-hide rules. A trailing
                          --state / --state-not still wins.

Pagination options:
  --limit N               Page size, 1-100, default 50
  --offset N              Skip the first N items

Examples:
  mirc session list
  mirc session list --state started
  mirc session list --state-not terminated,completed --updated-after 2026-05-01T00:00:00Z
  mirc session list --operation starting
  mirc session list --all
EOF
    exit 0
}

session_status_help() {
    cat <<'EOF'
Usage: mirc session status <session_id>

Print full session details (state, operation, ssh endpoint, billing,
events) as JSON.

Example:
  mirc session status 4ed5acf3-b78f-4e5a-bd37-362c418b64fa
EOF
    exit 0
}

session_logs_help() {
    cat <<'EOF'
Usage: mirc session logs <session_id> [-n N]

Tail the session's container logs.

Options:
  -n N            Number of lines from the end (default 50)
  -f, --follow    Stream new lines as they arrive; stop on terminal state.

Example:
  mirc session logs 4ed5acf3-... -n 200
  mirc session logs 4ed5acf3-... --follow
EOF
    exit 0
}

session_ssh_help() {
    cat <<'EOF'
Usage: mirc session ssh <session_id>

Open an interactive SSH connection to a running session, using the SSH
key cached during `mirc auth`.

Example:
  mirc session ssh 4ed5acf3-b78f-4e5a-bd37-362c418b64fa
EOF
    exit 0
}

session_terminate_help() {
    cat <<'EOF'
Usage: mirc session terminate <session_id> [--wait]

Terminate a session. Returns immediately by default; pass --wait to
block until the session reaches a terminal state.

Example:
  mirc session terminate 4ed5acf3-... --wait
EOF
    exit 0
}

session_availability_help() {
    cat <<'EOF'
Usage: mirc session availability [opts]

Check GPU availability and pricing across providers.

Options:
  --provider PROV         Filter by provider (e.g. verda, gcp)
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

Examples:
  mirc session availability --family H100 --provider verda
  mirc session availability --cheapest --provider verda --json
EOF
    exit 0
}

session_balance_help() {
    cat <<'EOF'
Usage: mirc session balance

Print the authenticated user's current credit balance, currency, and
estimated burn rate.
EOF
    exit 0
}

volume_help() {
    cat <<'EOF'
Usage: mirc volume <subcommand> [args...]

Block volume operations. Volumes are persistent across sessions and
mounted on session create via `--volume NAME:PATH`.

Subcommands:
  create [opts]              Create a persistent block volume
  list   [filter opts]       List volumes (paginated, filterable)
  status <id>                Show volume details
  extend <id> --size-gb N    Extend (resize) a volume
  delete <id> [--wait]       Delete a volume

State values:     submitted, provisioned, failed, deleted
Operation values: provisioning, resizing, deleting
                  (primary values; backend prefix-matches compounds)

Default `volume list` hides deleted volumes. Pass --state deleted (or
include it in --state) to see history. Ownership of a deleted volume
stays with the org for the retention period.

Run `mirc volume <subcommand> --help` for details on a specific command.
EOF
    exit 0
}

volume_create_help() {
    cat <<'EOF'
Usage: mirc volume create --name NAME --size-gb N [opts]

Create a persistent block volume.

Required:
  --name NAME             Volume name (unique within the org)
  --size-gb N             Size in GB (provider minimum applies — Verda: 100)

Optional:
  --provider PROV         Provider hint (e.g. verda)
  --location LOC          Location hint (e.g. FIN-01) — should match
                          the location of any session you plan to attach to
  --wait                  Block until state=provisioned

Examples:
  mirc volume create --name data1 --size-gb 100 --wait
  mirc volume create --name demo-vol --size-gb 100 --provider verda --location FIN-03 --wait
EOF
    exit 0
}

volume_list_help() {
    cat <<'EOF'
Usage: mirc volume list [filter opts]

List volumes (paginated, sorted newest-first). Default hides deleted
volumes — pass --all (or --state with deleted in it) to see history.

Filter options:
  --state CSV             Inclusion list, e.g. "provisioned,deleted"
  --state-not CSV         Exclusion list
  --operation CSV         Primary operation inclusion (e.g. "deleting")
  --operation-not CSV     Primary operation exclusion
  --updated-after RFC3339
  --updated-before RFC3339
  --all                   Sugar for --state with every volume state — same
                          as `--state submitted,provisioned,failed,deleted`.
                          Short-circuits the default state_not=deleted filter.
                          A trailing --state / --state-not still wins.

Pagination options:
  --limit N               Page size, 1-100, default 50
  --offset N              Skip the first N items

Examples:
  mirc volume list                       # active volumes only (default hides deleted)
  mirc volume list --all                 # active + history
  mirc volume list --state deleted       # history only
  mirc volume list --all --state-not deleted   # same as the default
  mirc volume list --state provisioned,deleted
EOF
    exit 0
}

volume_status_help() {
    cat <<'EOF'
Usage: mirc volume status <volume_id>

Print full volume details (state, operation, size, provider id,
attached_to, billing) as JSON. Works for deleted volumes too — the
per-volume cache key is preserved for the retention period.

Example:
  mirc volume status cd2d52f6-708d-48bd-92f7-2699951d8f38
EOF
    exit 0
}

volume_extend_help() {
    cat <<'EOF'
Usage: mirc volume extend <volume_id> --size-gb N

Increase the size of a volume. New size must be strictly larger than
the current size; volumes cannot be shrunk.

Required:
  --size-gb N    New size in GB

Example:
  mirc volume extend vol-abc --size-gb 200
EOF
    exit 0
}

volume_delete_help() {
    cat <<'EOF'
Usage: mirc volume delete <volume_id> [--wait]

Delete a volume. Returns immediately by default; pass --wait to block
until the volume reaches state=deleted (or 404). Deleted volumes stay
queryable via `mirc volume status` and `mirc volume list --state deleted`
for the retention period.

Example:
  mirc volume delete cd2d52f6-... --wait
EOF
    exit 0
}

# Entry-point dispatch when no subcommand was supplied; prints top help.
usage() { top_help; }

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

# Build a query string from list filter + pagination flags. Sets QS.
# All `list` commands route through this so the flag set stays uniform —
# see API-CONVENTIONS-LIST.md.
parse_list_filters() {
    local state="" state_not="" operation="" operation_not=""
    local updated_after="" updated_before=""
    local limit="" offset=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --state)           state="${2:?'--state' requires a value}"; shift 2 ;;
            --state-not)       state_not="${2:?'--state-not' requires a value}"; shift 2 ;;
            --operation)       operation="${2:?'--operation' requires a value}"; shift 2 ;;
            --operation-not)   operation_not="${2:?'--operation-not' requires a value}"; shift 2 ;;
            --updated-after)   updated_after="${2:?'--updated-after' requires a value}"; shift 2 ;;
            --updated-before)  updated_before="${2:?'--updated-before' requires a value}"; shift 2 ;;
            --limit)           limit="${2:?'--limit' requires a value}"; shift 2 ;;
            --offset)          offset="${2:?'--offset' requires a value}"; shift 2 ;;
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
    [ -n "$limit" ]          && QS="${QS}&limit=$(urlencode "$limit")"
    [ -n "$offset" ]          && QS="${QS}&offset=$(urlencode "$offset")"
    if [ -n "$QS" ]; then QS="?${QS:1}"; fi
}

# ── auth ─────────────────────────────────────────────────────────────

cmd_auth() {
    _has_help_flag "$@" && auth_help
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
    _has_help_flag "$@" && install_help
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
    _has_help_flag "$@" && session_create_help
    local name="" image="" gpu="" command="" provider="" location=""
    local gpu_count=1 auto_terminate="" no_ssh=false max_duration=""
    local wait_flag=false
    local family="" min_vram="" form_factor="" priority="" max_attempts="" max_price=""
    local cheapest=false
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
            --family)         family="${2:?'--family' requires a value}"; shift 2 ;;
            --min-vram)       min_vram="${2:?'--min-vram' requires a value}"; shift 2 ;;
            --form-factor)    form_factor="${2:?'--form-factor' requires a value}"; shift 2 ;;
            --priority)       priority="${2:?'--priority' requires a value}"; shift 2 ;;
            --max-attempts)   max_attempts="${2:?'--max-attempts' requires a value}"; shift 2 ;;
            --max-price)      max_price="${2:?'--max-price' requires a value in EUR}"; shift 2 ;;
            --cheapest)       cheapest=true; shift ;;
            --wait)           wait_flag=true; shift ;;
            *)                die "unknown option for session create: $1" ;;
        esac
    done

    if [ "$cheapest" = true ]; then
        if [ -n "$priority" ]; then
            die "--cheapest is shorthand for --priority PRICE; pick one"
        fi
        priority="PRICE"
    fi

    [ -n "$name" ]  || die "session create requires --name"
    [ -n "$image" ] || die "session create requires --image"
    if [ -z "$gpu" ] && [ -z "$family" ] && [ -z "$min_vram" ] && [ -z "$form_factor" ] && [ -z "$priority" ]; then
        die "session create requires --gpu, --cheapest, --priority, or at least one of --family / --min-vram / --form-factor"
    fi

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
        --argjson gpu_count "$gpu_count" \
        --arg key "$pub_key" \
        --arg at_mode "$auto_terminate" \
        '{
            name: $name,
            image: {uri: $image},
            gpu: {count: $gpu_count},
            ssh_public_key: $key,
            auto_terminate: {mode: $at_mode}
        }')

    # GPU selectors — each as a list. --gpu / --family / --form-factor accept
    # comma-separated values where order = preference. --min-vram is a single
    # int (wrapped as a single-element list to match the API's []int shape).
    if [ -n "$gpu" ]; then
        json=$(echo "$json" | jq --arg v "$gpu" '.gpu.types = ($v | split(","))')
    fi
    if [ -n "$family" ]; then
        json=$(echo "$json" | jq --arg v "$family" '.gpu.family = ($v | split(","))')
    fi
    if [ -n "$form_factor" ]; then
        json=$(echo "$json" | jq --arg v "$form_factor" '.gpu.form_factor = ($v | split(","))')
    fi
    if [ -n "$min_vram" ]; then
        json=$(echo "$json" | jq --argjson v "$min_vram" '.gpu.vram_gb = [$v]')
    fi
    if [ -n "$priority" ]; then
        json=$(echo "$json" | jq --arg v "$priority" '.gpu.priority = ($v | split(","))')
    fi
    if [ -n "$max_attempts" ]; then
        json=$(echo "$json" | jq --argjson v "$max_attempts" '.gpu.max_attempts = $v')
    fi
    if [ -n "$max_price" ]; then
        json=$(echo "$json" | jq --argjson v "$max_price" '.gpu.max_hourly_rate = $v')
    fi

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
                    failed|provision_failed)
                        # Hard failure — VM never made it to a useful state.
                        echo "" >&2
                        echo "$detail" | jq . >&2
                        die "session reached terminal state=$state before becoming ready"
                        ;;
                    completed|terminated|stopped)
                        # Session ran AND finished while we were polling — for
                        # auto_terminate=on_complete with a short --command,
                        # the container can exit between two of our poll cycles.
                        # Treat as success when exit_code=0 (or absent); show
                        # the full record so the caller sees what happened.
                        local exit_code
                        exit_code=$(echo "$detail" | jq -r '.exit_code // "null"')
                        if [ "$exit_code" = "0" ] || [ "$exit_code" = "null" ]; then
                            printf "\rstate=%-12s operation=%-30s (%ds) — finished\n" "$state" "$operation" "$elapsed" >&2
                            echo "$detail" | jq .
                            return
                        fi
                        echo "" >&2
                        echo "$detail" | jq . >&2
                        die "session reached terminal state=$state with exit_code=$exit_code"
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
    _has_help_flag "$@" && session_list_help
    # --all is a CLI sugar: short-circuits any backend default state filter
    # by passing every documented session state explicitly. A trailing
    # --state / --state-not still wins (last-write-wins in parse_list_filters),
    # so `--all --state-not terminated` reads as "everything except terminated".
    local args=()
    for a in "$@"; do
        case "$a" in
            --all) args+=(--state "submitted,provisioned,started,completed,failed,stopped,provision_failed,terminated") ;;
            *)     args+=("$a") ;;
        esac
    done
    parse_list_filters "${args[@]+"${args[@]}"}"
    ensure_token
    api_get "/sessions${QS}" | jq .
}

cmd_session_status() {
    _has_help_flag "$@" && session_status_help
    [ -n "${1:-}" ] || die "usage: mirc session status <session_id>"
    ensure_token
    api_get "/sessions/$1" | jq .
}

cmd_session_logs() {
    _has_help_flag "$@" && session_logs_help
    local id="" lines=50 follow=false
    while [ $# -gt 0 ]; do
        case "$1" in
            -n) lines="${2:?'-n' requires a number}"; shift 2 ;;
            -f|--follow) follow=true; shift ;;
            *)  id="$1"; shift ;;
        esac
    done
    [ -n "$id" ] || die "usage: mirc session logs <session_id> [-n N] [-f|--follow]"
    ensure_token

    if [ "$follow" = false ]; then
        # Single-shot — current behavior.
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
        return
    fi

    # --follow: poll every 2s; print only NEW lines; stop on terminal state.
    # Each rendered line starts `YYYY-MM-DDTHH:MM:SS.mmmZ ` — we parse that
    # to track our cursor and skip lines we've already shown.
    #
    # tail=2000 stays comfortably under Loki's default max_entries_limit_per_query
    # (5000) so the request never trips a 503 from the log store.
    local last_ts=""
    local terminal_pat='^(completed|terminated|failed|provision_failed|stopped)$'
    while :; do
        ensure_token

        local logs_resp logs_code logs_body
        logs_resp=$(curl -s -w '\n%{http_code}' "$API/sessions/$id/logs?tail=2000" \
            -H "Authorization: Bearer $MIMIRY_TOKEN")
        logs_code=$(echo "$logs_resp" | tail -1)
        logs_body=$(echo "$logs_resp" | sed '$d')

        if [ "$logs_code" = "200" ]; then
            local new_lines
            if [ -z "$last_ts" ]; then
                new_lines=$(echo "$logs_body" | jq -r '.logs // empty')
            else
                # Skip every line with timestamp <= last_ts (cursor advances
                # past dupes the server may legitimately return).
                new_lines=$(echo "$logs_body" | jq -r '.logs // empty' | awk -v c="$last_ts" '$1 > c { print }')
            fi
            if [ -n "$new_lines" ]; then
                echo "$new_lines"
                last_ts=$(echo "$new_lines" | tail -1 | awk '{print $1}')
            fi
        elif [ "$logs_code" != "503" ]; then
            # 503 is logs-store-temporarily-unavailable; quietly retry. Any
            # other non-200 is a real error worth surfacing.
            echo "follow: HTTP $logs_code — $(echo "$logs_body" | jq -r '.message // .error // .')" >&2
        fi

        # Check session state — stop on terminal.
        local state_resp state
        state_resp=$(curl -s "$API/sessions/$id" -H "Authorization: Bearer $MIMIRY_TOKEN")
        state=$(echo "$state_resp" | jq -r '.state // "unknown"')
        if [[ "$state" =~ $terminal_pat ]]; then
            return
        fi

        sleep 2
    done
}

cmd_session_ssh() {
    _has_help_flag "$@" && session_ssh_help
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
    _has_help_flag "$@" && session_terminate_help
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
    _has_help_flag "$@" && session_availability_help
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
    _has_help_flag "$@" && session_balance_help
    ensure_token
    api_get "/balance" | jq .
}

# Dispatch a session subcommand. Recognises --help / -h / no-args / `help`
# at the namespace level and prints session_help; defers per-command help
# to the individual cmd_session_* functions.
cmd_session() {
    local sub="${1:-}"
    case "$sub" in
        ""|--help|-h|help) session_help ;;
    esac
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
        *) die "unknown session subcommand: $sub (run 'mirc session --help' for the list)" ;;
    esac
}

# ── volume subcommands ───────────────────────────────────────────────

cmd_volume_create() {
    _has_help_flag "$@" && volume_create_help
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
    _has_help_flag "$@" && volume_list_help
    # --all is a CLI sugar: short-circuits the backend's default
    # state_not=deleted filter by passing every documented volume state
    # explicitly. A trailing --state / --state-not still wins, so
    # `--all --state-not deleted` reads as "everything except deleted".
    local args=()
    for a in "$@"; do
        case "$a" in
            --all) args+=(--state "submitted,provisioned,failed,deleted") ;;
            *)     args+=("$a") ;;
        esac
    done
    parse_list_filters "${args[@]+"${args[@]}"}"
    ensure_token
    api_get "/volumes${QS}" | jq .
}

cmd_volume_status() {
    _has_help_flag "$@" && volume_status_help
    [ -n "${1:-}" ] || die "usage: mirc volume status <volume_id>"
    ensure_token
    api_get "/volumes/$1" | jq .
}

cmd_volume_extend() {
    _has_help_flag "$@" && volume_extend_help
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
    _has_help_flag "$@" && volume_delete_help
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

# Dispatch a volume subcommand. Same pattern as cmd_session.
cmd_volume() {
    local sub="${1:-}"
    case "$sub" in
        ""|--help|-h|help) volume_help ;;
    esac
    shift
    case "$sub" in
        create)    cmd_volume_create "$@" ;;
        list|ls)   cmd_volume_list "$@" ;;
        status)    cmd_volume_status "$@" ;;
        extend)    cmd_volume_extend "$@" ;;
        delete)    cmd_volume_delete "$@" ;;
        *) die "unknown volume subcommand: $sub (run 'mirc volume --help' for the list)" ;;
    esac
}

# ── ssh subcommands ──────────────────────────────────────────────────

ssh_help() {
    cat <<'EOF'
Usage: mirc ssh <subcommand> [args...]

SSH-key management via the platform's guided registration flow.

Subcommands:
  register --title NAME [--name SLUG] [--key PATH] [--yes]
                                       Register a new SSH public key. Generates
                                       a Mimiry-dedicated ed25519 key by default
                                       (never overwrites). --key PATH to reuse
                                       an existing key. Requires portal 2FA.

Run `mirc ssh <subcommand> --help` for details.
EOF
    exit 0
}

ssh_register_help() {
    cat <<'EOF'
Usage: mirc ssh register --title NAME [--name SLUG] [--key <public-key-path>] [--yes]

Register a new SSH public key with your account via the guided flow:
  1. mirc generates a fresh ed25519 key pair dedicated to this registration
     (unless --key is passed).
  2. mirc calls the server to open a registration.
  3. You open a portal URL in your browser and complete 2FA.
  4. mirc uploads the public key and signs a server challenge to prove
     ownership of the matching private key.
  5. Server publishes the SSH-key-add event; registration completes.

Required:
  --title NAME         Human-readable name for the key (e.g. "MacBook Pro 2026").

Optional:
  --name SLUG          File-name slug for the generated key pair. Defaults to
                       a slug derived from --title (lowercase, non-alnum → _).
                       Key files land at ~/.ssh/mimiry_<slug>[.pub].
  --key PATH           Skip generation and register an EXISTING public key at
                       PATH. The matching private key (PATH without .pub) is
                       used to sign the ownership challenge. Only use this
                       when you have a real reason to reuse — see security
                       note below.
  --yes                Non-interactive: if the derived key path already
                       exists, reuse it silently instead of prompting.

Security note (why generate by default):
  Reusing a single SSH key for multiple purposes (git hosts, servers,
  platforms) blows the blast radius on compromise: one leak revokes
  access everywhere. Prefer one key per platform. mirc therefore
  generates a Mimiry-dedicated key by default and never overwrites an
  existing key file.

Behaviour:
  - Default: generates ~/.ssh/mimiry_<slug> (private) + .pub
    with `ssh-keygen -t ed25519 -f <path> -N ""` (no passphrase — mirc
    needs unattended access to sign challenges).
  - If ~/.ssh/mimiry_<slug> already exists (from a prior registration)
    mirc REFUSES to overwrite. It prompts to reuse the existing key OR
    asks you to pass --name <different-slug>. Use --yes to reuse
    non-interactively.
  - If --key PATH is supplied, mirc uses that key verbatim and skips
    generation entirely.

Notes:
  - No prior mirc authentication is required (guided flow is device-code
    style — the browser 2FA is what proves identity).
  - If interrupted mid-flow, mirc best-effort cancels the pending
    registration on exit.
  - The server dedups by fingerprint: registering the same public key
    twice returns 409. Use a fresh --name for each distinct registration.

Examples:
  mirc ssh register --title "MacBook Pro 2026"
  # → generates ~/.ssh/mimiry_macbook_pro_2026 + .pub, registers .pub

  mirc ssh register --title "CI Runner" --name ci
  # → generates ~/.ssh/mimiry_ci + .pub

  mirc ssh register --title "Legacy shared" --key ~/.ssh/id_ed25519.pub
  # → registers an existing key file (opt-in path)
EOF
    exit 0
}

# Tracks a pending registration id so the EXIT trap can best-effort cancel
# if the user aborts before completion.
SSH_REGISTER_PENDING_ID=""

_ssh_register_cleanup() {
    local rid="${SSH_REGISTER_PENDING_ID:-}"
    [ -n "$rid" ] || return 0
    SSH_REGISTER_PENDING_ID=""
    # Fire and forget with a short timeout; ignore errors — we're on the way out.
    # Device-flow: the registration_id itself is the bearer (2026-07-15 amendment).
    curl -sS --max-time 2 -X DELETE \
        "${AUTH_API}/ssh-keys/register/${rid}" \
        -H "Authorization: Bearer ${rid}" >/dev/null 2>&1 || true
}

# Extract a human-readable error string from a curl response body (JSON or text).
_ssh_register_err_msg() {
    local body="$1"
    local msg
    msg=$(echo "$body" | jq -r '.message // .error // empty' 2>/dev/null || true)
    if [ -n "$msg" ] && [ "$msg" != "null" ]; then
        printf '%s' "$msg"
    else
        # Not JSON or no error field — print a bounded snippet.
        printf '%s' "$body" | head -c 300
    fi
}

cmd_ssh_register() {
    _has_help_flag "$@" && ssh_register_help

    local title="" pub_key_path="" name_slug="" assume_yes=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --title) title="${2:?'--title' requires a value}"; shift 2 ;;
            --name)  name_slug="${2:?'--name' requires a value}"; shift 2 ;;
            --key)   pub_key_path="${2:?'--key' requires a path}"; shift 2 ;;
            --yes|-y) assume_yes=1; shift ;;
            *) die "unknown option for ssh register: $1" ;;
        esac
    done

    [ -n "$title" ] || die "ssh register requires --title <name>"

    need curl; need jq; need ssh-keygen; need base64

    # Two paths:
    #  1) --key PATH provided → use that existing key verbatim (opt-in reuse).
    #  2) Default → generate a fresh Mimiry-dedicated key at
    #     ~/.ssh/mimiry_<slug>. Slug from --name, else derived from --title.
    #     Never overwrites an existing file (prompts to reuse or fails).
    if [ -z "$pub_key_path" ]; then
        # Derive slug: lowercase, non-alnum → _, collapse repeats, trim.
        local slug="${name_slug}"
        if [ -z "$slug" ]; then
            slug=$(printf '%s' "$title" \
                | tr '[:upper:]' '[:lower:]' \
                | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//')
            [ -n "$slug" ] || die "cannot derive a key-file slug from --title '$title'; pass --name <slug>"
        fi

        # Ensure ~/.ssh exists with sane perms before generating.
        [ -d "$HOME/.ssh" ] || { mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"; }

        local priv_key_path="$HOME/.ssh/mimiry_${slug}"
        pub_key_path="${priv_key_path}.pub"

        if [ -e "$priv_key_path" ] || [ -e "$pub_key_path" ]; then
            # Existing key on the derived path. NEVER overwrite silently.
            if [ "$assume_yes" -eq 1 ]; then
                echo "Reusing existing key at $priv_key_path (--yes)." >&2
            elif [ -t 0 ]; then
                # Interactive: ask.
                printf 'A key already exists at %s.\n' "$priv_key_path" >&2
                printf 'Reuse it for this registration? [y/N] ' >&2
                local answer
                read -r answer
                case "$answer" in
                    y|Y|yes|YES) : ;;
                    *) die "aborted. Pass --name <different-slug> to generate a fresh key, or --key <path> to reuse a specific existing key." ;;
                esac
            else
                # Non-interactive & no --yes → refuse.
                die "key file already exists at $priv_key_path; refusing to overwrite. Pass --yes to reuse it, --name <different-slug> to generate a fresh one, or --key <path> to point at a specific existing key."
            fi
        else
            # Generate a fresh ed25519 key pair. No passphrase — mirc needs
            # to sign challenges without a prompt.
            echo "Generating new Mimiry-dedicated SSH key at $priv_key_path..." >&2
            if ! ssh-keygen -t ed25519 -f "$priv_key_path" -N "" -C "mirc:${slug}" >/dev/null 2>&1; then
                die "ssh-keygen failed to create $priv_key_path"
            fi
            chmod 600 "$priv_key_path"
            chmod 644 "$pub_key_path"
        fi
    fi

    [ -f "$pub_key_path" ] || die "public key not found: $pub_key_path"
    [ -s "$pub_key_path" ] || die "public key is empty: $pub_key_path"

    local pub_contents
    pub_contents=$(tr -d '\r\n' < "$pub_key_path")
    case "$pub_contents" in
        ssh-*|"ecdsa-"*|"sk-"*) : ;;
        *) die "public key at $pub_key_path does not look like an OpenSSH public key (expected leading 'ssh-*' / 'ecdsa-*' / 'sk-*')" ;;
    esac

    local priv_key_path="${pub_key_path%.pub}"
    [ "$priv_key_path" != "$pub_key_path" ] || die "public key path must end in .pub: $pub_key_path"
    [ -f "$priv_key_path" ] || die "private key not found next to public key: $priv_key_path"

    # Device-flow (2026-07-15 amendment): no prior authentication needed.
    # The whole point of guided registration is to bootstrap the FIRST key
    # for a user who has no other credential. /init is unauthenticated;
    # subsequent calls use the returned registration_id as the bearer.

    # Install cleanup trap for best-effort cancel on abort.
    trap _ssh_register_cleanup EXIT INT TERM

    # ── Step 1: init ────────────────────────────────────────────────
    local uname_s init_body init_json init_code
    uname_s=$(uname -s 2>/dev/null || echo unknown)
    init_body=$(jq -n --arg title "$title" \
                     --arg hint "mirc/0.1 (${uname_s})" \
                     '{title: $title, client_hint: $hint}')

    local resp
    resp=$(curl -sS -w '\n%{http_code}' -X POST \
        "${AUTH_API}/ssh-keys/register/init" \
        -H "Content-Type: application/json" \
        -d "$init_body")
    init_code=$(echo "$resp" | tail -1)
    init_json=$(echo "$resp" | sed '$d')

    case "$init_code" in
        200|201) : ;;
        *)
            die "register init failed (HTTP $init_code): $(_ssh_register_err_msg "$init_json")"
            ;;
    esac

    local reg_id verify_url
    reg_id=$(echo "$init_json" | jq -r '.registration_id // empty')
    verify_url=$(echo "$init_json" | jq -r '.verify_url // empty')
    [ -n "$reg_id" ]     || die "register init returned no registration_id: $init_json"
    [ -n "$verify_url" ] || die "register init returned no verify_url: $init_json"
    SSH_REGISTER_PENDING_ID="$reg_id"

    cat >&2 <<EOF

Registration started (id: $reg_id)

  1. Open in your browser: $verify_url
  2. Complete 2FA verification.
  3. Return here — polling for verification...

EOF

    # ── Step 2: poll for portal_verified ───────────────────────────
    local max_polls=150   # 150 × 2s = 5 min
    local poll_i=0
    local state=""
    while [ "$poll_i" -lt "$max_polls" ]; do
        local sresp scode sjson
        sresp=$(curl -sS -w '\n%{http_code}' \
            "${AUTH_API}/ssh-keys/register/${reg_id}/status" \
            -H "Authorization: Bearer ${reg_id}")
        scode=$(echo "$sresp" | tail -1)
        sjson=$(echo "$sresp" | sed '$d')

        if [ "$scode" != "200" ]; then
            die "status poll failed (HTTP $scode): $(_ssh_register_err_msg "$sjson")"
        fi

        state=$(echo "$sjson" | jq -r '.state // empty')
        case "$state" in
            initiated)
                # keep polling
                ;;
            portal_verified|key_submitted|challenge_issued|key_ownership_proven)
                break
                ;;
            expired)
                SSH_REGISTER_PENDING_ID=""  # already terminal server-side
                die "registration expired before portal 2FA was completed. Re-run 'mirc ssh register'."
                ;;
            cancelled)
                SSH_REGISTER_PENDING_ID=""
                die "registration was cancelled."
                ;;
            failed)
                SSH_REGISTER_PENDING_ID=""
                die "registration failed server-side: $(_ssh_register_err_msg "$sjson")"
                ;;
            completed)
                # Nothing left to do — server already advanced past our steps.
                SSH_REGISTER_PENDING_ID=""
                echo "Registration already completed server-side." >&2
                return 0
                ;;
            "")
                die "status response missing 'state' field: $sjson"
                ;;
            *)
                die "unexpected registration state: $state"
                ;;
        esac

        sleep 2
        poll_i=$(( poll_i + 1 ))
    done

    if [ "$state" = "initiated" ] || [ -z "$state" ]; then
        die "timed out waiting for portal 2FA verification (5 min). Re-run 'mirc ssh register' to retry."
    fi

    echo "Portal 2FA verified. Submitting public key..." >&2

    # ── Step 3: submit-key ─────────────────────────────────────────
    local skbody skresp skcode skjson
    skbody=$(jq -n --arg pk "$pub_contents" '{public_key: $pk}')
    skresp=$(curl -sS -w '\n%{http_code}' -X POST \
        "${AUTH_API}/ssh-keys/register/${reg_id}/submit-key" \
        -H "Authorization: Bearer ${reg_id}" \
        -H "Content-Type: application/json" \
        -d "$skbody")
    skcode=$(echo "$skresp" | tail -1)
    skjson=$(echo "$skresp" | sed '$d')

    case "$skcode" in
        200|201) : ;;
        409)
            die "this key is already registered on your account."
            ;;
        *)
            die "submit-key failed (HTTP $skcode): $(_ssh_register_err_msg "$skjson")"
            ;;
    esac

    local challenge_b64 algorithm
    challenge_b64=$(echo "$skjson" | jq -r '.challenge // empty')
    algorithm=$(echo "$skjson" | jq -r '.algorithm // empty')
    [ -n "$challenge_b64" ] || die "submit-key returned no challenge: $skjson"
    [ -n "$algorithm" ]     || die "submit-key returned no algorithm: $skjson"

    echo "Signing server challenge (algorithm=${algorithm})..." >&2

    # ── Step 4: sign challenge with ssh-keygen -Y sign ─────────────
    # Write raw challenge bytes to a temp file; ssh-keygen signs the file
    # contents. The signature lands at <tmpfile>.sig as an armored SSH sig.
    local tmpdir chall_file sig_file sig_b64
    tmpdir=$(mktemp -d)
    chall_file="${tmpdir}/challenge"
    sig_file="${chall_file}.sig"

    if ! printf '%s' "$challenge_b64" | base64 -d > "$chall_file" 2>/dev/null; then
        rm -rf "$tmpdir"
        die "failed to base64-decode server challenge"
    fi

    if ! ssh-keygen -Y sign -f "$priv_key_path" -n "$algorithm" "$chall_file" >/dev/null 2>&1; then
        rm -rf "$tmpdir"
        die "ssh-keygen -Y sign failed. Ensure $priv_key_path is a valid OpenSSH private key."
    fi

    if [ ! -f "$sig_file" ]; then
        rm -rf "$tmpdir"
        die "ssh-keygen produced no signature file at $sig_file"
    fi

    sig_b64=$(base64 < "$sig_file" | tr -d '\n')
    rm -rf "$tmpdir"

    # ── Step 5: prove-ownership ────────────────────────────────────
    local pobody poresp pocode pojson
    pobody=$(jq -n --arg sig "$sig_b64" '{signature: $sig}')
    poresp=$(curl -sS -w '\n%{http_code}' -X POST \
        "${AUTH_API}/ssh-keys/register/${reg_id}/prove-ownership" \
        -H "Authorization: Bearer ${reg_id}" \
        -H "Content-Type: application/json" \
        -d "$pobody")
    pocode=$(echo "$poresp" | tail -1)
    pojson=$(echo "$poresp" | sed '$d')

    case "$pocode" in
        200|201)
            # Server has consumed the registration — clear the pending id so
            # the EXIT trap doesn't try to cancel a completed flow.
            SSH_REGISTER_PENDING_ID=""
            local key_req_id
            key_req_id=$(echo "$pojson" | jq -r '.ssh_key_request_id // empty')
            echo "Key registered successfully." >&2
            if [ -n "$key_req_id" ]; then
                echo "Server request id: $key_req_id" >&2
            fi
            ;;
        400)
            die "signature verification failed. Please retry 'mirc ssh register'."
            ;;
        *)
            die "prove-ownership failed (HTTP $pocode): $(_ssh_register_err_msg "$pojson")"
            ;;
    esac
}

cmd_ssh() {
    local sub="${1:-}"
    case "$sub" in
        ""|--help|-h|help) ssh_help ;;
    esac
    shift
    case "$sub" in
        register) cmd_ssh_register "$@" ;;
        *) die "unknown ssh subcommand: $sub (run 'mirc ssh --help' for the list)" ;;
    esac
}

# ── Argument parsing ─────────────────────────────────────────────────

OPT_KEY=""
CMD=""
CMD_ARGS=()

while [ $# -gt 0 ]; do
    if [ -n "$CMD" ]; then
        case "$1" in
            --key)
                # For 'ssh' subcommands, --key names the public key being
                # registered, not the auth key. Route it to CMD_ARGS.
                if [ "$CMD" = "ssh" ]; then
                    CMD_ARGS+=("$1" "${2:?'--key' requires a path}"); shift 2
                else
                    OPT_KEY="${2:?'--key' requires a path}"; shift 2
                fi
                ;;
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
    ssh)     cmd_ssh "${CMD_ARGS[@]+"${CMD_ARGS[@]}"}" ;;
    help)    usage ;;
    *) die "unknown command: $CMD (run 'mirc --help' for usage)" ;;
esac
