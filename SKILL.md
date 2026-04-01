---
name: mimiry-compute
description: >
  Launch and manage GPU compute sessions on the Mimiry platform. Use this skill
  whenever the user wants to run a GPU job, start a compute session, train a
  model on Mimiry, launch a container on a GPU, check their Mimiry balance,
  manage running sessions, or build a compute job script. Also triggers when the
  user mentions Mimiry compute, GPU sessions, SSH-ing into a session, or asks to
  "run this on a GPU" or "launch a training job". Covers both quick one-liners
  and interactive job-building workflows.
---

# Mimiry Compute — Build, Launch & Manage GPU Jobs

This skill covers two concerns:

1. **API operations** (always available) — auth, list sessions, get status,
   logs, terminate, check balance/quota
2. **Job building** (when creating something new) — choose an image strategy,
   pick an implementation language, generate the job script, and launch it

---

## Prerequisites

Before any API operation, verify the user has a registered SSH key. Ask:

> Do you have an SSH key registered on your Mimiry account?

**If yes** — ask for the path to the key (there is no default). The auth
script accepts either the private key path or the `.pub` path — it
normalizes automatically.

**If no** — walk them through setup:

1. **Generate a key** (if they don't have one):
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/mimiry -C "mimiry-compute"
   ```
2. **Register it on Mimiry** — the user must add the public key
   (`~/.ssh/mimiry.pub`) through the Mimiry portal. There is currently no
   API for key registration. Direct them to:
   `https://softlaunch.mimiry.com` → Profile → SSH Keys → Add Key
3. Once the key is registered, proceed with the key path they chose.

The same SSH key serves two purposes: authenticating with the API (signature
exchange) and SSH access into running sessions.

**Other requirements:** `curl`, `jq`, `ssh-keygen`, and `openssl` must be
available on the user's system.

---

## Part 1: API Operations (Always Available)

These are the building blocks used by everything else.

### Authentication

The auth algorithm uses SSH signature exchange (not a simple API key). **Always
use the bundled auth script** — do not re-implement the signing logic inline.
The algorithm has several non-obvious details (message format, namespace,
file-based signing) that are easy to get wrong.

```bash
source $HOME/.claude/skills/mimiry-compute/scripts/mimiry-auth.sh <ssh_key_path>
# Exports: MIMIRY_TOKEN, MIMIRY_API
```

Tokens expire after 1 hour — re-authenticate if you get 401s.

**API base:** `https://softlaunch.mimiry.com`
**Compute prefix:** `/api/compute/v1`

> **CRITICAL — Shell state does not persist between Bash tool calls.**
> Each time you use the Bash tool, it spawns a **new shell**. Variables
> exported by `source` in one Bash call do NOT exist in the next one.
> You MUST chain the `source` command with every API call using `&&` in
> a **single** Bash invocation. Never run `source` in one Bash call and
> then use `$MIMIRY_API` / `$MIMIRY_TOKEN` in a separate Bash call.

### Common Operations

> **These commands are for the agent's own shell.** Always include the
> `source` line. **Never copy these verbatim into user-facing output** —
> the variables won't exist in the user's terminal. When printing
> commands for the user, follow the "After Session Creation" section.

Every API call must be chained with `source` in a single Bash invocation:

**Check balance** (do this before creating sessions):
```bash
source $HOME/.claude/skills/mimiry-compute/scripts/mimiry-auth.sh <ssh_key_path> && \
  curl -s "${MIMIRY_API}/balance" -H "Authorization: Bearer $MIMIRY_TOKEN" | jq .
```

**List sessions:**
```bash
source $HOME/.claude/skills/mimiry-compute/scripts/mimiry-auth.sh <ssh_key_path> && \
  curl -s "${MIMIRY_API}/sessions" -H "Authorization: Bearer $MIMIRY_TOKEN" | jq .
```

**Get session details:**
```bash
source $HOME/.claude/skills/mimiry-compute/scripts/mimiry-auth.sh <ssh_key_path> && \
  curl -s "${MIMIRY_API}/sessions/$SESSION_ID" -H "Authorization: Bearer $MIMIRY_TOKEN" | jq .
```

**Get logs** (session must be `running`):
```bash
source $HOME/.claude/skills/mimiry-compute/scripts/mimiry-auth.sh <ssh_key_path> && \
  curl -s "${MIMIRY_API}/sessions/$SESSION_ID/logs?tail=50" \
    -H "Authorization: Bearer $MIMIRY_TOKEN" | jq -r '.logs'
```
- HTTP 503 → VM still setting up, retry after `retry_after_seconds`
- HTTP 409 → session not running, check status first

**Terminate session:**
```bash
source $HOME/.claude/skills/mimiry-compute/scripts/mimiry-auth.sh <ssh_key_path> && \
  curl -s -X DELETE "${MIMIRY_API}/sessions/$SESSION_ID" \
    -H "Authorization: Bearer $MIMIRY_TOKEN" | jq .
```

**Check quota:**
```bash
source $HOME/.claude/skills/mimiry-compute/scripts/mimiry-auth.sh <ssh_key_path> && \
  curl -s "${MIMIRY_API}/quota" -H "Authorization: Bearer $MIMIRY_TOKEN" | jq .
```

**Transaction history:**
```bash
source $HOME/.claude/skills/mimiry-compute/scripts/mimiry-auth.sh <ssh_key_path> && \
  curl -s "${MIMIRY_API}/transactions" -H "Authorization: Bearer $MIMIRY_TOKEN" | jq .
```

---

## Part 2: Job Building (When Creating Something New)

When the user wants to create a new compute job, gather the required
information through natural conversation. **Do not use `AskUserQuestion`
with fixed option lists** — instead, ask plain questions and let the user
respond in their own words. This produces a better experience because
users often provide multiple answers at once, clarify context, or ask
follow-up questions that rigid option menus can't accommodate.

### What to gather

Work through these in conversation, adapting to what the user has already
told you (they may have answered several in their initial request):

1. **SSH key path** — needed for auth and session SSH access
2. **Image** — what container to run. Suggest common options if they're
   unsure:
   - PyTorch: `nvcr.io/nvidia/pytorch:24.01-py3`
   - TensorFlow: `nvcr.io/nvidia/tensorflow:24.01-tf2-py3`
   - Plain CUDA: `nvcr.io/nvidia/cuda:12.3.1-devel-ubuntu22.04`
   - Or any public image URI / custom Dockerfile
3. **GPU type** — default to T4 (cheapest) unless they need more power
4. **What to run** — a command/script, or interactive SSH access?
5. **Session name** — suggest a sensible default based on the image/task

Optional (only ask if relevant to what the user described):
- Environment variables
- Auto-terminate behavior (default: `true` if command, `false` if interactive)
- Billing account (only for org billing)

Once you have enough information, authenticate, create the session, poll
until running, and print management commands per "After Session Creation".

---

## Creating the Session

> **Agent-internal code** — do not print this block to the user.
> Remember: `source` MUST be in the same Bash call as the API request.

Regardless of how decisions were made, the session creation call looks like:

```bash
source $HOME/.claude/skills/mimiry-compute/scripts/mimiry-auth.sh <ssh_key_path> && \
  PUB_KEY=$(cat "<ssh_key_path>.pub") && \
  curl -s -X POST "${MIMIRY_API}/sessions" \
    -H "Authorization: Bearer $MIMIRY_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
      "name": "<session_name>",
      "image": {"uri": "<image_uri>"},
      "gpu": {"types": ["<gpu_type>"], "count": 1},
      "ssh_enabled": true,
      "ssh_public_key": "'"$PUB_KEY"'",
      "command": "<command_or_null>",
      "auto_terminate": <true|false>,
      "environment_vars": {<optional_env_vars>}
    }' | jq .
```

**Field guide:**

| Field | When | Value |
|-------|------|-------|
| `command` | User has a script to run | The command string |
| `command` | Interactive access | Omit entirely |
| `auto_terminate` | Has a command | `true` or `{"mode":"on_complete"}` |
| `auto_terminate` | Interactive / long-running | `false` or `{"mode":"never"}` |
| `auto_terminate` | Only terminate on success | `{"mode":"on_success"}` |
| `ssh_public_key` | Always required | Contents of `<key>.pub` |
| `gpu.types` | User doesn't specify | `["T4"]` (cheapest) |
| `environment_vars` | User needs env config | `{"KEY": "value", ...}` |
| `billing.account_type` | Org billing | `"org"` + `account_id` |

## Session Lifecycle

Two dimensions:
- **`state`** (durable milestone): `submitted → provisioned → started → completed/failed/stopped → terminated`
- **`status`** (transient): `provisioning`, `starting_container`, `running`, `stopping_container`, `terminating`

```
POST /sessions → state:submitted → state:provisioned → state:started → state:completed
                 status:provisioning  status:starting_container  status:running      ↓
                                                                               state:terminated
                                              DELETE /sessions/{id}
                                                     ↓
                                              state:stopped → state:terminated

On error at any stage → state:failed or state:provision_failed
```

Poll every 5 seconds until `started` (agent-internal, not user-facing).
The entire loop MUST be in a single Bash call that starts with `source`:
```bash
source $HOME/.claude/skills/mimiry-compute/scripts/mimiry-auth.sh <ssh_key_path> && \
  while true; do
    RESP=$(curl -s "${MIMIRY_API}/sessions/$SESSION_ID" \
      -H "Authorization: Bearer $MIMIRY_TOKEN")
    STATE=$(echo "$RESP" | jq -r '.state')
    echo "State: $STATE"
    case "$STATE" in
      started) break ;;
      failed|provision_failed) echo "FAILED: $(echo $RESP | jq -r '.error')"; break ;;
      completed|terminated|stopped) echo "Session ended unexpectedly"; break ;;
    esac
    sleep 5
  done
```

Once running, extract SSH details from `$RESP` (still in the same shell)
and then print **user-facing management commands** per the "After Session
Creation" section below. Include the SSH command with resolved values:
```bash
# Extract from $RESP (in the same Bash call as the polling loop above):
SSH_HOST=$(echo "$RESP" | jq -r '.ssh.host')

# Then print for the user (with actual values substituted):
# ssh -i <key_path> -o StrictHostKeyChecking=no <host>
# Plus the mirc helper commands — see "After Session Creation"
```

> **Note:** SSH sessions connect through the ssh-proxy on port 22 (the
> default SSH port), which lands users directly inside their container.
> No special port or username is needed — just `ssh -i <key> <host>`.

---

## After Session Creation

Once a session is running, print management commands the user can copy-paste
into their terminal. There is a **critical rule**: never print commands that
contain unresolved shell variables like `${MIMIRY_API}` or `$MIMIRY_TOKEN` —
those only exist inside the agent's shell, not in the user's terminal. Either
use the `mirc` helper (which handles auth internally) or print fully
resolved URLs with the auth source command included.

### Default: Quick Commands (mirc helper)

Print these by default. Replace `<session_id>` and `<key_path>` with the
actual values from the session that was just created:

```
# Manage your session (run in any terminal):
mirc status <session_id> --key <key_path>
mirc logs <session_id>
mirc ssh <session_id>
mirc terminate <session_id>
```

The `--key` flag is only needed on the first command — the path is cached
for subsequent calls. If the user has already run a `mirc` command in this
terminal session, `--key` can be omitted entirely.

The helper script lives at:
`$HOME/.claude/skills/mimiry-compute/scripts/mirc.sh`

If the user hasn't added it to their PATH, print the full path on first use.
For convenience, suggest:
```bash
alias mirc='$HOME/.claude/skills/mimiry-compute/scripts/mirc.sh'
```

### Alternative: Raw API Commands

Print these when the user asks about automation, pipelines, CI/CD, or wants
to understand what's happening under the hood. Always include the auth source
command so the variables are defined:

```bash
# Authenticate (sets $MIMIRY_TOKEN for 1 hour, re-run to refresh):
source $HOME/.claude/skills/mimiry-compute/scripts/mimiry-auth.sh <key_path>

# Check status:
curl -s "https://softlaunch.mimiry.com/api/compute/v1/sessions/<session_id>" \
  -H "Authorization: Bearer $MIMIRY_TOKEN" | jq .

# Get logs:
curl -s "https://softlaunch.mimiry.com/api/compute/v1/sessions/<session_id>/logs?tail=50" \
  -H "Authorization: Bearer $MIMIRY_TOKEN" | jq -r '.logs'

# Terminate:
curl -s -X DELETE "https://softlaunch.mimiry.com/api/compute/v1/sessions/<session_id>" \
  -H "Authorization: Bearer $MIMIRY_TOKEN" | jq .
```

Note: in raw commands, always use the fully resolved URL
(`https://softlaunch.mimiry.com/api/compute/v1/...`), never `${MIMIRY_API}`.
The only variable that's acceptable is `$MIMIRY_TOKEN` because the `source`
command on the line above defines it.

### Token Expiry Guidance

Tokens last 1 hour. When printing post-session commands, mention:
- The `mirc` helper auto-refreshes tokens (no action needed)
- For raw API commands, re-run the `source` command to get a fresh token
- If a command returns HTTP 401, the token has expired

---

## Error Reference

| Error | Meaning | Fix |
|-------|---------|-----|
| `Invalid SSH signature` | Auth algorithm wrong | Ensure the bundled auth script is being used |
| `Timestamp expired` | Clock drift > 5 min | Sync system clock |
| `SSH key not registered` | Key not on account | Register key in Mimiry portal |
| `insufficient_balance` | No credits | Ask admin to add credits |
| `no_balance` | No billing account | Ask admin to create one |
| `vm_setup_in_progress` (503) | VM booting | Retry after `retry_after_seconds` |
| `invalid_state` (409) | Wrong session state for operation | Check session status |

## Tips

- Always `source` the auth script AND the API call in the **same** Bash tool
  invocation (chained with `&&`). Shell state does not persist between calls.
- The same SSH key authenticates with the API and provides session SSH access
- Billing runs from provisioning to termination — remind users to terminate
  idle sessions
- T4 is the cheapest GPU; suggest it unless the user needs more power
- When generating scripts for the user, include error handling for common
  failure modes (402 insufficient balance, 429 quota exceeded)
- **Exploration vs. automation**: Default to `mirc` helper commands for
  interactive use. Switch to raw curl commands when the user mentions
  pipelines, CI/CD, scripting, or automation — and always include the full
  auth `source` command so the commands are self-contained
- **Never print unresolved variables** in user-facing commands. `${MIMIRY_API}`
  and `$MIMIRY_TOKEN` only exist inside the agent's shell session. See the
  "After Session Creation" section for the correct patterns
