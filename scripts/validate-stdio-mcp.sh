#!/bin/bash
# Validate stdio MCP servers in .mcp.json
# Only checks local (stdio) MCPs - network MCPs are handled by the proxy
#
# See SECURE_CLAUDE_CODE.md Design 5 for details

set -e

# Allowlisted stdio MCP commands
# These are pre-installed binaries that are trusted
ALLOWED_STDIO=(
    "note"
    "todo"
    "zet"
    "gopls"
    "dot"
    # Add more trusted MCP binaries here
)

# Patterns that indicate command injection attempts
DANGEROUS_PATTERNS='(;|\||&&|`|\$\(|curl\s|wget\s|nc\s|netcat\s|bash\s+-c|sh\s+-c)'

MCP_CONFIG="${1:-/workspace/.mcp.json}"

# Exit successfully if no MCP config exists
if [[ ! -f "$MCP_CONFIG" ]]; then
    exit 0
fi

# Check if jq is available
if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required for MCP validation but not installed"
    exit 1
fi

# Validate JSON syntax
if ! jq empty "$MCP_CONFIG" 2>/dev/null; then
    echo "ERROR: Invalid JSON in $MCP_CONFIG"
    exit 1
fi

# Extract stdio MCP commands (those with 'command' but without 'url')
stdio_mcps=$(jq -r '
    .mcpServers // {} | to_entries[] |
    select(.value.command) |
    select(.value.url == null) |
    "\(.key)|\(.value.command)"
' "$MCP_CONFIG" 2>/dev/null || echo "")

if [[ -z "$stdio_mcps" ]]; then
    # No stdio MCPs configured
    exit 0
fi

validation_failed=false

while IFS='|' read -r name cmd; do
    [[ -z "$name" ]] && continue

    base_cmd=$(basename "$cmd")

    # Check if command is in allowlist
    allowed=false
    for allowed_cmd in "${ALLOWED_STDIO[@]}"; do
        if [[ "$base_cmd" == "$allowed_cmd" ]]; then
            allowed=true
            break
        fi
    done

    if [[ "$allowed" != "true" ]]; then
        echo "BLOCKED: Stdio MCP '$name' uses unauthorized command: $cmd"
        echo "         Allowed commands: ${ALLOWED_STDIO[*]}"
        validation_failed=true
        continue
    fi

    # Check for injection patterns in command
    if echo "$cmd" | grep -qE "$DANGEROUS_PATTERNS"; then
        echo "BLOCKED: Stdio MCP '$name' has suspicious command pattern: $cmd"
        validation_failed=true
        continue
    fi

    # Check args for injection patterns
    args=$(jq -r ".mcpServers[\"$name\"].args // [] | .[]" "$MCP_CONFIG" 2>/dev/null || echo "")
    if echo "$args" | grep -qE "$DANGEROUS_PATTERNS"; then
        echo "BLOCKED: Stdio MCP '$name' has suspicious arguments"
        validation_failed=true
        continue
    fi

    echo "OK: Stdio MCP '$name' validated ($base_cmd)"

done <<< "$stdio_mcps"

if [[ "$validation_failed" == "true" ]]; then
    echo ""
    echo "MCP validation failed. See SECURE_CLAUDE_CODE.md Design 5 for details."
    exit 1
fi

exit 0
