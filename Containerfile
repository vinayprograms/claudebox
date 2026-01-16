# Alpine container for running Claude Code in isolation
# See SECURE_CLAUDE_CODE.md for complete security documentation
FROM alpine:3.21

#######################################
# Base Setup

# Install required packages:
# - openssh-client for git SSH operations
# - build-base for native npm modules
# - graphviz for graphviz-mcp (dot command)
# - jq for MCP validation and graphviz-mcp script
# - shadow for managing non-root users
# - inotify-tools for log monitoring (optional)
RUN apk add --no-cache \
    nodejs npm git bash vim openssh-client curl \
    build-base graphviz jq shadow

# Create non-root users:
# claude - supervisory user that owns configuration files
# claude-agent - restricted runtime user for Claude Code execution
RUN adduser -D -s /bin/bash -g claude claude && \
    adduser -D -s /bin/false -g claude claude-agent && \
    mkdir /workspace && \
    chown -R claude:claude /home/claude && \
    chown -R claude-agent:claude /home/claude-agent && \
    chown -R claude-agent:claude /workspace

#######################################
# Install Claude Code and Go (for MCPs)

# Install Claude Code globally
# SECURITY: --ignore-scripts prevents post-install scripts from running
#           This mitigates supply chain attacks via malicious npm packages
RUN npm install -g --ignore-scripts @anthropic-ai/claude-code

# Install Go from official source
ENV GO_VERSION=1.25.5
RUN ARCH=$(uname -m) && \
    case "$ARCH" in \
        x86_64) GOARCH="amd64" ;; \
        aarch64|arm64) GOARCH="arm64" ;; \
        *) echo "Unsupported architecture: $ARCH" && exit 1 ;; \
    esac && \
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${GOARCH}.tar.gz" | tar -C /usr/local -xzf -
ENV PATH="/usr/local/go/bin:${PATH}"
RUN mkdir -p /home/claude/go/bin && chown -R claude:claude /home/claude/go
# Set up Go environment for claude user
ENV GOPATH=/home/claude/go
ENV PATH="${GOPATH}/bin:${PATH}"

#######################################
# Security Hardening

# Remove attack tools with no legitimate development use
# These tools are commonly used for network attacks and data exfiltration
# Note: curl/wget are kept as they're useful for dev and controlled by proxy
RUN rm -f /usr/bin/nc /usr/bin/netcat /usr/bin/ncat 2>/dev/null || true && \
    rm -f /usr/bin/socat /usr/bin/telnet 2>/dev/null || true && \
    rm -f /usr/bin/nmap /usr/bin/tcpdump 2>/dev/null || true && \
    echo "Attack tools removed (if they existed)"

# Create log directory for command auditing
RUN mkdir -p /var/log/claudebox && \
    chown claude-agent:claude /var/log/claudebox && \
    chmod 750 /var/log/claudebox

# Create git hooks directory
RUN mkdir -p /etc/git-hooks && \
    chmod 755 /etc/git-hooks

# Copy git hooks
COPY scripts/git-hooks/pre-push /etc/git-hooks/pre-push
RUN chmod 755 /etc/git-hooks/pre-push

# Copy MCP validation script
COPY scripts/validate-stdio-mcp.sh /usr/local/bin/validate-stdio-mcp
RUN chmod 755 /usr/local/bin/validate-stdio-mcp

# Copy command logging profile
COPY scripts/claudebox-audit.sh /etc/profile.d/claudebox-audit.sh
RUN chmod 644 /etc/profile.d/claudebox-audit.sh

#######################################
# User Account Separation (claude owns config, claude-agent runs code)

# Create claude's config directory (supervisor owns this)
RUN mkdir -p /home/claude/.claude && \
    chown -R claude:claude /home/claude/.claude && \
    chmod 750 /home/claude/.claude

# Create claude-agent's directory with symlinks to claude's config
# This allows claude-agent to READ config but not WRITE to it
RUN mkdir -p /home/claude-agent/.claude/projects && \
    ln -s /home/claude/.claude/settings.json /home/claude-agent/.claude/settings.json && \
    ln -s /home/claude/.claude/settings.local.json /home/claude-agent/.claude/settings.local.json && \
    ln -s /home/claude/.claude/.credentials.json /home/claude-agent/.claude/.credentials.json && \
    chown -R claude-agent:claude /home/claude-agent/.claude && \
    chown -h claude-agent:claude /home/claude-agent/.claude/settings.json && \
    chown -h claude-agent:claude /home/claude-agent/.claude/settings.local.json && \
    chown -h claude-agent:claude /home/claude-agent/.claude/.credentials.json

#######################################
# Git Configuration

# System-wide git config for security
RUN git config --system credential.helper "" && \
    git config --system url."https://github.com/".insteadOf "git@github.com:" && \
    git config --system url."https://gitlab.com/".insteadOf "git@gitlab.com:" && \
    git config --system core.hooksPath "/etc/git-hooks" && \
    git config --system push.default "nothing"

#######################################
# Karya MCP servers

# Switch to claude user for installing Go tools
USER claude
WORKDIR /home/claude

# Install karya MCP servers (note, todo, zet) from source
RUN git clone https://github.com/vinayprograms/karya.git /tmp/karya && \
    cd /tmp/karya && \
    go install ./cmd/note && \
    go install ./cmd/todo && \
    go install ./cmd/zet && \
    rm -rf /tmp/karya

# Install Go language server for LSP support
RUN go install golang.org/x/tools/gopls@latest

# Create MCP scripts directory for graphviz-mcp
RUN mkdir -p /home/claude/.local/share/crush/mcp

#######################################
# Finalize

# Create entrypoint script
USER root
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh

WORKDIR /workspace
USER claude-agent

# Use custom entrypoint that validates MCPs and sets up logging
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["claude", "--dangerously-skip-permissions"]
