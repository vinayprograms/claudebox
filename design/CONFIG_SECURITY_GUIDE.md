# Claude Code Security Guide

Security reference for engineers using claudebox.

---

## What Claudebox Handles

Claudebox already provides:

- **Network isolation** - all traffic goes through allowlist proxy (primary security boundary)
- **Payload size limit** - max 50MB per request to prevent bulk exfiltration
- **Read-only filesystem** - container can't persist malware
- **Dropped capabilities** - no privilege escalation
- **Seccomp filtering** - dangerous syscalls blocked (Podman only)
- **Credential isolation** - tokens stored separately from workspace

You don't need to manually configure most runtime protections.

---

## What You Still Need to Watch

### 1. Proxy Allowlist

The proxy controls what Claude Code can reach. Review `proxy/allowlist.conf` before adding domains.

**Be cautious with:**
- Wildcard domains (`.example.com`)
- Domains that host user content (paste sites, gists)
- Anything Claude could use to exfiltrate data

### 2. Project Configs in Your Repo

Claudebox mounts your workspace read-write. Malicious configs in the repo still execute:

- `.claude/settings.json` - can grant broad permissions
- `.mcp.json` - can point to attacker-controlled servers
- `CLAUDE.md` - can contain prompt injection

**Quick audit before running:**
```bash
cat .claude/settings.json .mcp.json CLAUDE.md 2>/dev/null
```

**Red flags:**
- `"allow": ["Bash(*)"]`
- `"defaultMode": "bypassPermissions"`
- Unknown MCP server URLs
- `CLAUDE.md` with "ignore previous instructions"

### 3. MCP Servers

MCP servers run inside the container with the same permissions as Claude Code.

- Only add trusted servers to your config
- Prefer stdio-based servers over network-based
- Anthropic does not audit third-party MCP servers

### 4. Plugins

**Plugins are a significant attack vector.** They run with the same permissions as Claude Code and can:

- Read and modify any file in your workspace
- Execute arbitrary shell commands
- Access environment variables and credentials
- Exfiltrate data through allowed network endpoints

**Before installing any plugin:**
1. Check the source - is it from a known, trusted author?
2. Review the code - what does it actually do?
3. Check permissions - what hooks does it install?
4. Search for reports - has anyone flagged it as malicious?

**Red flags in plugins:**
- Obfuscated or minified code
- Network calls to unknown endpoints
- Hooks that run on every command
- Requests for broad file access

Claudebox cannot protect you from malicious plugins you choose to install.

A warning banner is displayed at startup when plugins are detected. Use `--skip-plugin-warning` to skip the confirmation prompt (banner still shown).

### 5. Git Operations

The `pre-push` hook blocks pushes by default. If you need to push:

1. Review changes carefully
2. Push manually from outside the container, or
3. Understand you're bypassing a safety control

---

## First-Time Setup

On first run, claudebox runs in "setup mode" with writable credentials. After authentication:

1. Restart claudebox
2. It switches to "secured mode" (credentials isolated from workspace)
3. Credentials are stored in `claude-config/` separate from your project

---

## When to Use `--no-proxy`

The `--no-proxy` flag disables network filtering. Only use it when:

- Debugging network issues
- Working with internal services not on the allowlist
- You fully trust the code you're working with

---

## References

- [Official Security Docs](https://docs.anthropic.com/en/docs/claude-code/security)
- [MCP Integration](https://docs.anthropic.com/en/docs/claude-code/mcp)
- [GitHub Security Advisories](https://github.com/anthropics/claude-code/security/advisories)
