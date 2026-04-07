# Mimiry Skills

Packaged [agent skills](https://skills.sh/) for the [Mimiry](https://mimiry.com) GPU compute platform. Each skill extends your agent with specialized capabilities for launching, managing, and monitoring GPU sessions.

## Install

Install a specific skill:

```bash
npx skills add mimiry-com/mimiry-skills@mimiry-softlaunch
```

## Available Skills

### mimiry-softlaunch

Early-access skill for Mimiry's softlaunch GPU compute environment. This targets the early beta at `softlaunch.mimiry.com` — APIs, pricing, and features may change.

**The skill let you:**

- Launch a GPU compute session from your agent
- Train a model, run inference, or experiment on a GPU
- Check your Mimiry balance, quota, or session status
- SSH into a running container for interactive work
- Manage sessions — view logs, list, get status, and terminate

**Covers:**

- Session lifecycle — create, poll, monitor, terminate
- GPU image selection — PyTorch, TensorFlow, CUDA, or custom container images
- SSH signature-based authentication with the Mimiry API
- Balance and quota management
- Interactive and batch job workflows
- `mirc` CLI helper for managing sessions outside your agent

**Prerequisites:**

- An SSH key registered at [softlaunch.mimiry.com](https://softlaunch.mimiry.com)
- `curl`, `jq`, `ssh-keygen`, and `openssl`
- You need to be invited, in order to register in the softlaunch release

### mirc CLI

The `mimiry-softlaunch` skill bundles `mirc`, a standalone CLI for managing sessions directly from your terminal. After installing the skill, add an alias:

```bash
alias mirc='~/.agents/skills/mimiry-softlaunch/scripts/mirc.sh'
```

```
mirc auth --key ~/.ssh/mimiry       # Authenticate (required on first use)
mirc list                           # List all sessions
mirc list --state started           # Filter by state
mirc status <session_id>            # Session details
mirc logs <session_id> -n 100       # Tail logs
mirc ssh <session_id>               # SSH into a running session
mirc terminate <session_id>         # Terminate a session
mirc balance                        # Check account balance
```

The `--key` flag is only needed once — the path is cached for subsequent calls. Tokens are cached and auto-refreshed.

## License

MIT
