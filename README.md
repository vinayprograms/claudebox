# Claudebox

A security-hardened container for running Claude Code with network isolation, filesystem restrictions, and audit logging.

## Features

- **Network isolation** - All traffic routes through an allowlist proxy
- **Read-only filesystem** - Container can't persist malware
- **Dropped capabilities** - No privilege escalation
- **Resource limits** - CPU, memory, PIDs capped
- **Credential isolation** - Auth tokens mounted read-only
- **Git push protection** - Pre-push hook blocks pushes by default
- **Works with Podman and Docker**

## Prerequisites

- [Podman](https://podman.io/) or [Docker](https://www.docker.com/)
- Claude Code account (for authentication)

## Quick Start

```bash
# Clone the repo
git clone https://github.com/vinayprograms/claudebox.git
cd claudebox

# Run claudebox (first run will prompt for authentication)
./claudebox
```

On first run, claudebox runs in "setup mode" to allow authentication. After authenticating, restart to enable secured mode with read-only credentials.

## Usage

```bash
./claudebox                  # Run with full security (proxy enabled)
./claudebox --no-proxy       # Run without network proxy
./claudebox --shell          # Start a shell instead of Claude Code
./claudebox --build-only     # Only build containers, don't run
./claudebox -- --help        # Pass arguments to Claude Code
```

## Directory Structure

```
claudebox/
├── claudebox                 # Main wrapper script
├── Containerfile             # Container image definition
├── proxy/                    # Squid proxy configuration
│   ├── Containerfile
│   └── squid.conf
├── proxy-allowlist.conf      # Domains Claude Code can access
├── seccomp-profile.json      # Syscall restrictions (Podman)
├── scripts/                  # Helper scripts
├── claude-config/            # [gitignored] Persistent config
└── claudebox-logs/           # [gitignored] Audit logs
```

## Network Allowlist

Edit `proxy-allowlist.conf` to control which domains Claude Code can access:

```conf
# Required for Claude Code
.anthropic.com
.claude.ai

# Git hosting
github.com
gitlab.com

# Add your domains
# api.yourcompany.com
```

## What Persists Between Sessions

| Data | Persisted | Location |
|------|-----------|----------|
| Credentials | Yes (ro) | `claude-config/.claude/.credentials.json` |
| Settings | Yes (ro) | `claude-config/.claude/settings*.json` |
| Conversation history | Yes (rw) | `claude-config/.claude/history.jsonl` |
| Project settings | Yes (rw) | `claude-config/.claude/projects/` |
| Todos | Yes (rw) | `claude-config/.claude/todos/` |
| Debug logs | No | Ephemeral |
| Statsig cache | No | Ephemeral |

## Security Notes

- The workspace (current directory) is mounted read-write
- Credentials are mounted read-only after initial setup
- Git pushes are blocked by default (review changes, push manually)
- See [CONFIG_SECURITY_GUIDE.md](design/CONFIG_SECURITY_GUIDE.md) for security details

## Troubleshooting

**Container hangs on startup**
- The `.claude` directory may have accumulated too much state
- Delete `claude-config/.claude/debug/` and `claude-config/.claude/statsig/`

**"No running container runtime found"**
- Start Podman: `podman machine start`
- Or start Docker Desktop

**Network requests failing**
- Check `proxy-allowlist.conf` for the required domain
- Try `./claudebox --no-proxy` to bypass the proxy

## License

MIT
