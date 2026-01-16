#!/bin/bash
# Set up Claude Code credentials for secure storage
#
# This script helps you:
# 1. Encrypt existing credentials with age
# 2. Store credentials in 1Password
#
# See SECURE_CLAUDE_CODE.md Design 3 for details.

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[setup]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[setup]${NC} $1"; }
log_error() { echo -e "${RED}[setup]${NC} $1" >&2; }
log_header() { echo -e "${CYAN}=== $1 ===${NC}"; }

CREDENTIALS_FILE="${HOME}/.claude/.credentials.json"
ENCRYPTED_FILE="${HOME}/.claude/credentials.json.age"

echo ""
log_header "Claude Code Credentials Setup"
echo ""
echo "This script will help you securely store your Claude Code credentials."
echo ""

# Check if credentials file exists
if [[ ! -f "$CREDENTIALS_FILE" ]]; then
    log_error "Credentials file not found: $CREDENTIALS_FILE"
    log_error ""
    log_error "Please run Claude Code first to authenticate and create credentials:"
    log_error "  claude"
    log_error ""
    log_error "After authenticating, run this script again."
    exit 1
fi

log_info "Found credentials file: $CREDENTIALS_FILE"
echo ""

# Check available methods
HAS_AGE=false
HAS_1PASSWORD=false

if command -v age &>/dev/null; then
    HAS_AGE=true
fi

if command -v op &>/dev/null; then
    HAS_1PASSWORD=true
fi

if [[ "$HAS_AGE" != "true" ]] && [[ "$HAS_1PASSWORD" != "true" ]]; then
    log_error "Neither 'age' nor '1Password CLI (op)' is installed."
    log_error ""
    log_error "Install one of the following:"
    log_error "  age: brew install age (macOS) / apt install age (Linux)"
    log_error "  1Password CLI: https://developer.1password.com/docs/cli/get-started/"
    exit 1
fi

# Present options
echo "Available credential storage methods:"
echo ""

if [[ "$HAS_1PASSWORD" == "true" ]]; then
    echo "  1) 1Password (recommended if you use 1Password)"
fi

if [[ "$HAS_AGE" == "true" ]]; then
    echo "  2) age encryption (passphrase-based)"
fi

echo "  q) Quit"
echo ""

read -p "Choose a method: " choice

case "$choice" in
    1)
        if [[ "$HAS_1PASSWORD" != "true" ]]; then
            log_error "1Password CLI is not installed"
            exit 1
        fi

        log_header "Setting up 1Password storage"
        echo ""

        # Check if signed in
        if ! op account list &>/dev/null; then
            log_warn "Not signed in to 1Password. Please sign in:"
            op signin
        fi

        # Get vault name
        read -p "Enter vault name [Private]: " vault
        vault="${vault:-Private}"

        # Read credentials
        ACCESS_TOKEN=$(jq -r '.claudeAiOauth.accessToken' "$CREDENTIALS_FILE")
        REFRESH_TOKEN=$(jq -r '.claudeAiOauth.refreshToken' "$CREDENTIALS_FILE")
        EXPIRES_AT=$(jq -r '.claudeAiOauth.expiresAt' "$CREDENTIALS_FILE")

        log_info "Creating 1Password item 'Claude Code' in vault '$vault'..."

        # Create the item
        op item create \
            --category="API Credential" \
            --title="Claude Code" \
            --vault="$vault" \
            "accessToken[text]=$ACCESS_TOKEN" \
            "refreshToken[text]=$REFRESH_TOKEN" \
            "expiresAt[text]=$EXPIRES_AT"

        log_info "Credentials stored in 1Password!"
        echo ""
        log_warn "You can now delete the plaintext credentials file:"
        log_warn "  rm $CREDENTIALS_FILE"
        echo ""
        log_info "To use these credentials with claudebox:"
        log_info "  export OP_VAULT=\"$vault\""
        log_info "  export OP_ITEM=\"Claude Code\""
        log_info "  ./claudebox"
        ;;

    2)
        if [[ "$HAS_AGE" != "true" ]]; then
            log_error "age is not installed"
            exit 1
        fi

        log_header "Setting up age encryption"
        echo ""

        if [[ -f "$ENCRYPTED_FILE" ]]; then
            log_warn "Encrypted file already exists: $ENCRYPTED_FILE"
            read -p "Overwrite? [y/N]: " confirm
            if [[ "$confirm" != "y" ]] && [[ "$confirm" != "Y" ]]; then
                log_info "Aborted."
                exit 0
            fi
        fi

        log_info "Encrypting credentials..."
        log_info "You will be prompted to enter a passphrase."
        echo ""

        age -p -o "$ENCRYPTED_FILE" "$CREDENTIALS_FILE"

        log_info "Credentials encrypted successfully!"
        log_info "Encrypted file: $ENCRYPTED_FILE"
        echo ""
        log_warn "You can now delete the plaintext credentials file:"
        log_warn "  rm $CREDENTIALS_FILE"
        echo ""
        log_info "To use these credentials with claudebox:"
        log_info "  export CLAUDE_CREDENTIALS_FILE=\"$ENCRYPTED_FILE\""
        log_info "  ./claudebox"
        ;;

    q|Q)
        log_info "Aborted."
        exit 0
        ;;

    *)
        log_error "Invalid choice"
        exit 1
        ;;
esac

echo ""
log_header "Setup Complete"
