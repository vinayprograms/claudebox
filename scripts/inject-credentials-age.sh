#!/bin/bash
# Inject Claude Code credentials using age encryption
#
# This script decrypts credentials from an age-encrypted file
# and creates a temporary credentials file for mounting into the container.
#
# Prerequisites:
#   - age installed (https://github.com/FiloSottile/age)
#   - Credentials encrypted with: age -p -o ~/.claude/credentials.json.age ~/.claude/.credentials.json
#
# See SECURE_CLAUDE_CODE.md Design 3 for details.

set -e

# Configuration
ENCRYPTED_FILE="${CLAUDE_CREDENTIALS_FILE:-$HOME/.claude/credentials.json.age}"
OUTPUT_FILE="${1:-}"

# Use tmpfs if available for secure temporary storage
if [[ -d "/dev/shm" ]]; then
    TEMP_DIR="/dev/shm"
elif [[ -d "/run/user/$UID" ]]; then
    TEMP_DIR="/run/user/$UID"
else
    TEMP_DIR="/tmp"
fi

if [[ -z "$OUTPUT_FILE" ]]; then
    OUTPUT_FILE="$TEMP_DIR/claude-credentials-$$.json"
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[age]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[age]${NC} $1"; }
log_error() { echo -e "${RED}[age]${NC} $1" >&2; }

# Check if age is installed
if ! command -v age &>/dev/null; then
    log_error "age is not installed."
    log_error "Install with:"
    log_error "  Linux:  apt install age / dnf install age"
    log_error "  macOS:  brew install age"
    log_error "  Windows: scoop install age / winget install age"
    exit 1
fi

# Check if encrypted file exists
if [[ ! -f "$ENCRYPTED_FILE" ]]; then
    log_error "Encrypted credentials file not found: $ENCRYPTED_FILE"
    log_error ""
    log_error "To create an encrypted credentials file:"
    log_error "  age -p -o $ENCRYPTED_FILE ~/.claude/.credentials.json"
    log_error ""
    log_error "Or set CLAUDE_CREDENTIALS_FILE to point to your encrypted file."
    exit 1
fi

log_info "Decrypting credentials from: $ENCRYPTED_FILE"
log_info "Output: $OUTPUT_FILE"

# Decrypt the file (age will prompt for passphrase)
if ! age -d -o "$OUTPUT_FILE" "$ENCRYPTED_FILE"; then
    log_error "Failed to decrypt credentials"
    rm -f "$OUTPUT_FILE" 2>/dev/null
    exit 1
fi

# Set restrictive permissions
chmod 600 "$OUTPUT_FILE"

# Validate the JSON structure
if ! jq -e '.claudeAiOauth.accessToken' "$OUTPUT_FILE" &>/dev/null; then
    log_warn "Credentials file may not have the expected structure"
    log_warn "Expected: { \"claudeAiOauth\": { \"accessToken\": \"...\", ... } }"
fi

log_info "Credentials decrypted successfully"
log_warn "File stored in: $OUTPUT_FILE"
log_warn "This file will be automatically cleaned up when the container exits."

# Output the path for use in scripts
echo "$OUTPUT_FILE"
