# Claudebox Design Document

A secure, containerized environment for running Claude Code with defense-in-depth protections.

**Target Audience:** Product Engineers
**Last Updated:** January 2026

---

## Overview

### What is Claudebox?

Claudebox runs Claude Code inside a security-hardened container. It protects against supply chain attacks, data exfiltration, and other threats that could arise from compromised NPM dependencies.

### Why Do We Need It?

Claude Code depends on the NPM ecosystem, which has a history of supply chain security issues:
- Compromised packages can exfiltrate sensitive data
- Malicious code can phone home to command-and-control servers
- Backdoors can be installed without user knowledge

Claudebox ensures that **even if a dependency is compromised**, it cannot:
- Access the internet (except allowlisted domains)
- Read files outside your project
- Modify system configuration
- Steal credentials

### Design Principle

> **Deny by default, allow by exception.**

Every entry and exit point is locked down. Access is granted only to explicitly allowed resources.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              HOST MACHINE                                │
│                                                                         │
│  ┌─────────────────┐     ┌─────────────────────────────────────────┐   │
│  │  Your Project   │     │         Claudebox Installation          │   │
│  │  (workspace)    │     │  - claudebox script                     │   │
│  │                 │     │  - proxy-allowlist.conf                 │   │
│  │  /my-project    │     │  - security profiles                    │   │
│  └────────┬────────┘     └─────────────────────────────────────────┘   │
│           │                                                             │
│           │ mounted as /workspace                                       │
│           ▼                                                             │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                    INTERNAL NETWORK (isolated)                   │   │
│  │                                                                  │   │
│  │  ┌──────────────────────┐      ┌──────────────────────────┐     │   │
│  │  │  CLAUDE CODE         │      │  PROXY CONTAINER         │     │   │
│  │  │  CONTAINER           │ HTTP │  (squid)                 │     │   │
│  │  │                      │─────▶│                          │     │   │
│  │  │  - Read-only FS      │      │  - Domain allowlist      │     │   │
│  │  │  - No internet       │      │  - Request logging       │     │   │
│  │  │  - Capabilities      │      │  - Rate limiting         │     │   │
│  │  │    dropped           │      │                          │     │   │
│  │  └──────────────────────┘      └────────────┬─────────────┘     │   │
│  │                                              │                   │   │
│  └──────────────────────────────────────────────┼───────────────────┘   │
│                                                 │                       │
│                                                 │ HTTPS (allowlist only)│
│                                                 ▼                       │
└─────────────────────────────────────────────────────────────────────────┘
                                                  │
                                                  ▼
                                            [ INTERNET ]
                                         (anthropic.com,
                                          github.com, etc.)
```

---

## Key Components

### 1. Main Script (`claudebox`)

The orchestration script that:
- Builds container images
- Manages the proxy container lifecycle
- Configures security settings
- Mounts your project as the workspace

**Usage:**
```bash
# Run Claude Code in your project
cd /path/to/your/project
/path/to/claudebox/claudebox

# Or with options
./claudebox --no-proxy      # Skip proxy (less secure)
./claudebox --shell         # Debug: get a shell instead
./claudebox -- --help       # Pass args to Claude Code
```

### 2. Claude Code Container

The main container where Claude Code runs. Security features:

| Feature | Purpose |
|---------|---------|
| Read-only filesystem | Prevents malware installation |
| Dropped capabilities | No privilege escalation |
| Seccomp profile | Blocks dangerous syscalls |
| Resource limits | Prevents resource exhaustion |
| No direct internet | All traffic through proxy |

### 3. Proxy Container

A Squid proxy that controls all network access:

| Feature | Purpose |
|---------|---------|
| Domain allowlist | Only approved sites reachable |
| Request logging | Audit trail for all requests |
| Rate limiting | Prevents bulk data exfiltration |
| HTTPS only | No unencrypted traffic |

### 4. Configuration Files

| File | Purpose |
|------|---------|
| `proxy-allowlist.conf` | Domains Claude can access |
| `seccomp-profile.json` | Syscalls to block |
| `claude-config/` | Persistent Claude settings |

---

## How It Works

### Startup Flow

```
1. User runs: ./claudebox
                │
2. Build containers (if needed)
                │
3. Create internal network
                │
4. Start proxy container
   └─ Connects to internal + external networks
                │
5. Start Claude Code container
   └─ Connects to internal network ONLY
   └─ Mounts current directory as /workspace
   └─ Mounts credentials (read-only)
                │
6. Claude Code runs with:
   └─ HTTP_PROXY=http://proxy:3128
   └─ No direct internet access
```

### Request Flow

```
Claude Code                 Proxy                    Internet
    │                         │                          │
    │  curl api.anthropic.com │                          │
    │────────────────────────▶│                          │
    │                         │ Check allowlist          │
    │                         │ ✓ anthropic.com allowed  │
    │                         │─────────────────────────▶│
    │                         │◀─────────────────────────│
    │◀────────────────────────│                          │
    │                         │                          │
    │  curl evil.com          │                          │
    │────────────────────────▶│                          │
    │                         │ Check allowlist          │
    │  HTTP 403 Forbidden     │ ✗ evil.com NOT allowed   │
    │◀────────────────────────│                          │
```

### Shutdown Flow

```
1. User exits Claude Code (Ctrl+D or /exit)
                │
2. Claude Code container stops (--rm removes it)
                │
3. Cleanup function runs:
   └─ Check: other claudebox instances running?
      │
      ├─ YES: Keep proxy alive for other instances
      │
      └─ NO: Stop and remove proxy container
```

---

## Directory Structure

```
claudebox/
├── claudebox                 # Main script
├── Containerfile             # Claude Code container definition
├── Dockerfile                # Same as Containerfile
├── proxy-allowlist.conf      # Allowed domains
├── seccomp-profile.json      # Syscall filter
│
├── design/                   # Documentation
│   ├── DESIGN.md             # This file
│   ├── SECURE_CLAUDE_CODE.md # Security architecture
│   └── CONFIG_SECURITY_GUIDE.md
│
├── scripts/                  # Helper scripts
│   ├── entrypoint.sh         # Container entrypoint
│   ├── claudebox-audit.sh    # Command logging
│   ├── validate-stdio-mcp.sh # MCP validation
│   └── git-hooks/
│       └── pre-push          # Git push validation
│
├── proxy/                    # Proxy container
│   ├── Dockerfile
│   ├── squid.conf
│   └── errors/               # Custom error pages
│
├── claude-config/            # [gitignored] Persistent config
│   ├── .claude/              # Claude Code settings
│   └── .claude.json          # Session state
│
└── claudebox-logs/           # [gitignored] Audit logs
```

---

## Security Modes

### Setup Mode (First Run)

When no credentials exist, claudebox runs in setup mode:
- Configuration directory is writable
- Allows initial authentication
- User completes Claude Code onboarding

```
[claudebox] No credentials found - running in SETUP MODE
[claudebox] After authentication, restart to enable secured mode
```

### Secured Mode (Subsequent Runs)

After authentication, claudebox locks down:
- Credentials: **read-only** (can't be modified)
- Settings: **read-only** (can't be tampered)
- Workspace: **read-write** (your project)
- Runtime state: **read-write** (temporary)

```
[claudebox] Existing credentials found - using secured mode
```

---

## Customization

### Adding Allowed Domains

Edit `proxy-allowlist.conf`:

```conf
# Required (don't remove)
.anthropic.com
.claude.ai

# Add your domains
.mycompany.com
api.internal.corp
```

### Resource Limits

Edit the variables at the top of `claudebox`:

```bash
MEMORY_LIMIT="2g"    # Max RAM
CPU_LIMIT="2"        # Max CPU cores
PIDS_LIMIT="256"     # Max processes
```

### MCP Servers

Stdio MCP servers must be allowlisted in `scripts/validate-stdio-mcp.sh`:

```bash
ALLOWED_STDIO=(
    "note"
    "todo"
    "zet"
    "gopls"
    "your-mcp"  # Add yours here
)
```

Network MCP servers are controlled by `proxy-allowlist.conf`.

---

## Multi-Instance Support

Claudebox supports running multiple instances simultaneously:

```bash
# Terminal 1
cd ~/projects/frontend
~/claudebox/claudebox

# Terminal 2
cd ~/projects/backend
~/claudebox/claudebox
```

- Both instances share the same proxy container
- Proxy stays alive while any instance is running
- Proxy stops when the last instance exits

---

## Limitations

| Limitation | Reason |
|------------|--------|
| No `ping` or ICMP | Only HTTP/HTTPS through proxy |
| No direct DNS | Prevents DNS exfiltration |
| No SSH from container | Network isolation |
| Can't install packages | Read-only filesystem |

These are intentional security trade-offs, not bugs.

---

## Troubleshooting

### "Network unreachable"

Claude Code has no direct internet. All requests must go through the proxy.
- Check if domain is in `proxy-allowlist.conf`
- Check if proxy is running: `podman ps | grep claudebox-proxy`

### "Permission denied" on files

The container runs as a non-root user with limited permissions.
- Workspace files should be owned by your user
- Configuration files are read-only by design

### Claude forgets settings on restart

The `~/.claude.json` file must persist. Check that `claude-config/` exists and is writable on the host.

### Proxy keeps running after exit

This is normal if other claudebox instances are running. Check with:
```bash
podman ps --filter "network=claudebox-internal"
```

---

## Related Documents

- [SECURE_CLAUDE_CODE.md](./SECURE_CLAUDE_CODE.md) - Detailed security architecture
- [CONFIG_SECURITY_GUIDE.md](./CONFIG_SECURITY_GUIDE.md) - Configuration file security

---

## Quick Reference

```bash
# Run Claude Code securely
cd /your/project && /path/to/claudebox

# Check what's running
podman ps | grep claudebox

# View proxy logs
podman logs claudebox-proxy

# Stop everything
podman stop claudebox-proxy && podman rm claudebox-proxy

# View audit log
cat claudebox-logs/commands.log
```
