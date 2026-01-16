#!/bin/bash
# Inject Claude Code credentials using 1Password CLI
#
# This script retrieves credentials from 1Password and creates
# a temporary credentials file for mounting into the container.
#
# Prerequisites:
#   - 1Password CLI (op) installed and configured
#   - Credentials stored in 1Password with the expected structure
#
# See SECURE_CLAUDE_CODE.md Design 3 for details.

set -e

# Configuration
OP_VAULT="${OP_VAULT:-Private}"
OP_ITEM="${OP_ITEM:-Claude Code}"
OUTPUT_FILE="${1:-/tmp/claude-credentials-$$.json}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[1password]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[1password]${NC} $1"; }
log_error() { echo -e "${RED}[1password]${NC} $1" >&2; }

# Check if 1Password CLI is installed
if ! command -v op &>/dev/null; then
    log_error "1Password CLI (op) is not installed."
    log_error "Install from: https://developer.1password.com/docs/cli/get-started/"
    exit 1
fi

# Check if signed in
if ! op account list &>/dev/null; then
    log_warn "Not signed in to 1Password. Attempting sign-in..."
    if ! op signin; then
        log_error "Failed to sign in to 1Password"
        exit 1
    fi
fi

log_info "Retrieving credentials from 1Password..."
log_info "Vault: $OP_VAULT"
log_info "Item: $OP_ITEM"

# Try to retrieve the credentials
# Expected 1Password item structure:
#   - accessToken (field)
#   - refreshToken (field)
#   - expiresAt (field)

ACCESS_TOKEN=$(op item get "$OP_ITEM" --vault "$OP_VAULT" --fields "accessToken" 2>/dev/null) || true
REFRESH_TOKEN=$(op item get "$OP_ITEM" --vault "$OP_VAULT" --fields "refreshToken" 2>/dev/null) || true
EXPIRES_AT=$(op item get "$OP_ITEM" --vault "$OP_VAULT" --fields "expiresAt" 2>/dev/null) || true

if [[ -z "$ACCESS_TOKEN" ]]; then
    log_error "Could not retrieve accessToken from 1Password"
    log_error "Ensure the item '$OP_ITEM' exists in vault '$OP_VAULT'"
    log_error "with fields: accessToken, refreshToken, expiresAt"
    exit 1
fi

# Create the credentials file
log_info "Creating credentials file: $OUTPUT_FILE"

cat > "$OUTPUT_FILE" << EOF
{
  "claudeAiOauth": {
    "accessToken": "$ACCESS_TOKEN",
    "refreshToken": "$REFRESH_TOKEN",
    "expiresAt": $EXPIRES_AT
  }
}
EOF

# Set restrictive permissions
chmod 600 "$OUTPUT_FILE"

log_info "Credentials file created successfully"
log_info "File: $OUTPUT_FILE"
log_warn "Remember to delete this file after use!"

# Output the path for use in scripts
echo "$OUTPUT_FILE"
