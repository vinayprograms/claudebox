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
./claudebox                        # Run with full security (proxy enabled)
./claudebox --no-proxy             # Run without network proxy
./claudebox --shell                # Start a shell instead of Claude Code
./claudebox --build-only           # Only build containers, don't run
./claudebox --skip-plugin-warning  # Skip plugin warning prompt (banner still shown)
./claudebox -- --help              # Pass arguments to Claude Code
```

## Directory Structure

```
claudebox/
├── claudebox                 # Main wrapper script
├── Containerfile             # Container image definition
├── proxy/                    # Squid proxy configuration
│   ├── Containerfile
│   └── squid.conf
├── proxy/allowlist.conf      # Domains Claude Code can access
├── seccomp-profile.json      # Syscall restrictions (Podman)
├── scripts/                  # Helper scripts
├── claude-config/            # [gitignored] Persistent config
└── claudebox-logs/           # [gitignored] Audit logs
```

## Network Allowlist

Edit `proxy/allowlist.conf` to control which domains Claude Code can access:

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
| Credentials | Yes (rw) | `claude-config/.claude/.credentials.json` |
| Settings | Yes (ro) | `claude-config/.claude/settings*.json` |
| Conversation history | Yes (rw) | `claude-config/.claude/history.jsonl` |
| Project settings | Yes (rw) | `claude-config/.claude/projects/` |
| Todos | Yes (rw) | `claude-config/.claude/todos/` |
| Session env | Yes (rw) | `claude-config/.claude/session-env/` |
| Plugins | Yes (rw) | `claude-config/.claude/plugins/` (via staging) |
| Debug logs | No | Ephemeral |
| Statsig cache | No | Ephemeral |

## Security Notes

- The workspace (current directory) is mounted read-write
- Credentials are stored separately in `claude-config/` (not in workspace)
- Git pushes are blocked by default (review changes, push manually)
- See [CONFIG_SECURITY_GUIDE.md](design/CONFIG_SECURITY_GUIDE.md) for security details

**Plugin Security Warning**: Plugins from marketplaces run with the same permissions as Claude Code. A malicious plugin can read your files, execute commands, and exfiltrate data. Only install plugins from trusted sources and review plugin code before installation. A warning banner is displayed at startup when plugins are detected.

## Troubleshooting

**File read errors on macOS (Error -35 / EAGAIN)**
- On macOS, both Docker and Podman run containers inside a VM with a file sharing layer (VirtioFS/gRPC-FUSE)
- When Claude Code spawns parallel subagents that read many files simultaneously, this layer can become overwhelmed
- Symptoms: `Unknown system error -35`, failed file reads, commands returning empty results
- **Workarounds:**
  - Use smaller workspaces when possible
  - Retry the operation (transient failures often succeed on retry)
  - Run on Linux (native containers, no VM/file sharing layer)
  - For Docker Desktop: Settings → General → Use "VirtioFS" (more stable than gRPC FUSE)
- This is a known limitation of containerized development on macOS, not specific to claudebox

**Container hangs on startup**
- On macOS, mounting large directories into containers can cause `secd` (keychain service) to spike CPU
- Delete `claude-config/.claude/plugins/`, `claude-config/.claude/debug/`, and `claude-config/.claude/statsig/`
- These directories are ephemeral and will be recreated

**"No running container runtime found"**
- Start Podman: `podman machine start`
- Or start Docker Desktop

**Network requests failing**
- Check `proxy/allowlist.conf` for the required domain
- Try `./claudebox --no-proxy` to bypass the proxy

## Contributing

This project was vibe-coded end-to-end. I provided design guidance, security requirements, and developer experience feedback, while Claude Code (using Opus 4.5) took care of implementation.

Contributions are welcome! If you'd like to contribute:
When contributing code, please use "deny by default, allow by exception" as the foundational principle.

1. **Bug reports & feature requests** - Open an issue describing the problem or idea.
2. **Code contributions** - Fork, make changes, and submit a pull request.
3. **Security issues** - Please report vulnerabilities privately via [GitHub's security reporting](../../security/advisories/new).


## License

Apache-2.0 License. See [LICENSE](LICENSE) for details.
