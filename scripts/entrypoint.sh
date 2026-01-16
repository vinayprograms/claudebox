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

# Validate stdio MCP servers if config exists
if [[ -f "/workspace/.mcp.json" ]]; then
    log_info "Validating MCP configuration..."
    if ! /usr/local/bin/validate-stdio-mcp /workspace/.mcp.json; then
        log_error "MCP validation failed. Aborting."
        exit 1
    fi
fi

# Check if credentials are available
if [[ ! -f "/home/claude/.claude/.credentials.json" ]] && \
   [[ -z "$ANTHROPIC_API_KEY" ]]; then
    log_warn "No credentials found. You may need to authenticate."
    log_warn "Mount credentials to /home/claude/.claude/.credentials.json"
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

# Source audit logging if available
if [[ -f "/etc/profile.d/claudebox-audit.sh" ]]; then
    source /etc/profile.d/claudebox-audit.sh
fi

# Execute the command passed to the container
exec "$@"
