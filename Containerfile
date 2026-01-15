# Alpine container for running Claude Code in isolation
FROM docker.io/library/alpine:3.21

# Install required packages:
# - nodejs/npm for Claude Code
# - git for version control operations
# - bash for better shell compatibility
# - openssh-client for git SSH operations
# - curl for network operations
# - build-base for native npm modules
# - graphviz for graphviz-mcp (dot command)
# - jq for graphviz-mcp script
RUN apk add --no-cache \
    nodejs \
    npm \
    git \
    bash \
    vim \
    openssh-client \
    curl \
    build-base \
    graphviz \
    jq

# Install Go from official source (architecture-agnostic)
ENV GO_VERSION=1.25.5
RUN ARCH=$(uname -m) && \
    case "$ARCH" in \
        x86_64) GOARCH="amd64" ;; \
        aarch64|arm64) GOARCH="arm64" ;; \
        *) echo "Unsupported architecture: $ARCH" && exit 1 ;; \
    esac && \
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${GOARCH}.tar.gz" | tar -C /usr/local -xzf -
ENV PATH="/usr/local/go/bin:${PATH}"

# Install Claude Code globally
RUN npm install -g @anthropic-ai/claude-code

# Create non-root user for safety
RUN adduser -D -s /bin/bash claude && \
    chown -R claude:claude /home/claude

# Set up Go environment for claude user
ENV GOPATH=/home/claude/go
ENV PATH="${GOPATH}/bin:${PATH}"

# Create workspace and go directories
RUN mkdir -p /workspace && chown claude:claude /workspace
RUN mkdir -p /home/claude/go/bin && chown -R claude:claude /home/claude/go
RUN mkdir -p /workspace/zet && chown claude:claude /workspace/zet

# Switch to non-root user
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

WORKDIR /workspace

ENTRYPOINT ["/bin/bash"]
