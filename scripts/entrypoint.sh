#!/bin/bash
# Claudebox entrypoint script
# Performs security validations before starting Claude Code
#
# See SECURE_CLAUDE_CODE.md for complete security documentation

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[claudebox]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[claudebox]${NC} $1"
}

log_error() {
    echo -e "${RED}[claudebox]${NC} $1"
}

# Install custom CA certificate if provided (for TLS inspection proxies like Zscaler)
if [[ "$CUSTOM_CA_CERT" == "1" ]] && [[ -f "/etc/claudebox/custom-ca.crt" ]]; then
    log_info "Installing custom CA certificate..."
    # Copy custom CA to the standard location and run update-ca-certificates
    # Both /usr/local/share/ca-certificates and /etc/ssl/certs are tmpfs at runtime
    cp /etc/claudebox/custom-ca.crt /usr/local/share/ca-certificates/custom-ca.crt
    update-ca-certificates --fresh > /dev/null 2>&1
    # Also set NODE_EXTRA_CA_CERTS for Node.js applications
    export NODE_EXTRA_CA_CERTS=/etc/claudebox/custom-ca.crt
    log_info "Custom CA certificate installed"
fi

# Validate stdio MCP servers if config exists
if [[ -f "/workspace/.mcp.json" ]]; then
    log_info "Validating MCP configuration..."
    if ! /usr/local/bin/validate-stdio-mcp /workspace/.mcp.json; then
        log_error "MCP validation failed. Aborting."
        exit 1
    fi
fi

# Check if credentials are available
if [[ ! -f "$HOME/.claude/.credentials.json" ]] && \
   [[ -z "$ANTHROPIC_API_KEY" ]]; then
    log_warn "No credentials found. You may need to authenticate."
    log_warn "Mount credentials to $HOME/.claude/.credentials.json"
fi

# Warn about plugin security if plugins are present
if [[ -d "$HOME/.claude/plugins" ]] && [[ -n "$(ls -A "$HOME/.claude/plugins" 2>/dev/null)" ]]; then
    echo ""
    echo -e "${YELLOW}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║${NC}  ${RED}⚠  PLUGIN SECURITY WARNING${NC}                                       ${YELLOW} ║${NC}"
    echo -e "${YELLOW}╠════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${YELLOW}║${NC}  Plugins run with FULL Claude Code permissions.                    ${YELLOW}║${NC}"
    echo -e "${YELLOW}║${NC}  A malicious plugin can read files, run commands, and exfiltrate.  ${YELLOW}║${NC}"
    echo -e "${YELLOW}║${NC}                                                                    ${YELLOW}║${NC}"
    echo -e "${YELLOW}║${NC}  Only install plugins from trusted sources.                        ${YELLOW}║${NC}"
    echo -e "${YELLOW}║${NC}  Review plugin code before installation.                           ${YELLOW}║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    if [[ "$SKIP_PLUGIN_WARNING" != "1" ]]; then
        echo -e "Press ${GREEN}Enter${NC} to continue..."
        read -r
    fi
fi

# Log startup
log_info "Starting Claude Code..."
log_info "User: $(whoami)"
log_info "Workspace: /workspace"

# Check proxy configuration
if [[ -n "$HTTP_PROXY" ]]; then
    log_info "Proxy: $HTTP_PROXY"
else
    log_warn "No proxy configured. Network access may be unrestricted."
fi

# Show custom CA status
if [[ "$CUSTOM_CA_CERT" == "1" ]]; then
    log_info "Custom CA: enabled"
fi

# Source audit logging if available
if [[ -f "/etc/profile.d/claudebox-audit.sh" ]]; then
    source /etc/profile.d/claudebox-audit.sh
fi

# Execute the command passed to the container
exec "$@"
