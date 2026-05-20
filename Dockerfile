FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim

# Which hermes-agent revision to install. Accepts any git ref the upstream
# repo publishes — a release tag (recommended for reproducibility) or a
# branch name (`main`) for bleeding edge.
#
# To bump: check https://github.com/NousResearch/hermes-agent/releases for the
# newest tag (format `vYYYY.M.D`, e.g. `v2026.4.23`) and update the default
# below. Use `main` only if you accept that every rebuild can pull arbitrary
# new upstream commits.
ARG HERMES_REF=v2026.5.16

# tini = tiny init that we run as PID 1. Without it, hermes's grandchild
# processes (MCP stdio servers, git, bun, browser daemons spawned by tools)
# reparent to PID 1 when their parents exit and pile up as zombies. After
# weeks of uptime that exhausts the kernel's PID table → "fork: cannot
# allocate memory" and the container dies. tini reaps zombies in the
# background and forwards SIGTERM/SIGINT to our entrypoint so Railway's
# stop signal still triggers our graceful shutdown. Standard container init
# (same as Docker's `--init` flag and Kubernetes' pause container).
#
# Node.js is required only at build time to compile the Hermes React dashboard.
# We strip the source + apt lists afterwards to keep the image lean.
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates git tini && \
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

# Install GitHub CLI so the agent can do `gh pr create`, `gh issue list`,
# clone private repos, etc. when given a GITHUB_TOKEN env var. Static
# binary from the official cli/cli release — pinned for build reproducibility.
ARG GH_VERSION=2.92.0
RUN cd /tmp && \
    curl -sL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" | tar xz && \
    mv "gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh && \
    chmod +x /usr/local/bin/gh && \
    rm -rf "/tmp/gh_${GH_VERSION}_linux_amd64"

# Install xurl (official X / Twitter CLI) so the agent can read AND write
# to X with auto-refreshing OAuth 2.0 tokens. Config + tokens live at
# /data/.xurl (volume-persistent). Bearer token covers reads; OAuth 2.0
# user-context covers writes (post, follow, like, DM). xurl auto-refreshes
# expired access tokens via the stored refresh token, so the agent never
# has to think about expiry.
ARG XURL_VERSION=1.1.1
RUN cd /tmp && \
    curl -sL "https://github.com/xdevplatform/xurl/releases/download/v${XURL_VERSION}/xurl_Linux_x86_64.tar.gz" | tar xz && \
    mv xurl /usr/local/bin/xurl && \
    chmod +x /usr/local/bin/xurl

# Install hermes-agent (provides the `hermes` CLI) and pre-build its React
# dashboard so `hermes dashboard` has nothing to build at runtime.
# Deleting web/ afterwards makes hermes's internal _build_web_ui skip the
# rebuild step (it early-returns when package.json is absent), so container
# startup is fast and no runtime npm dependency is needed.
# NOTE: We expand hermes-agent's `[all]` extra manually here, omitting `[mistral]`.
# Upstream's `[mistral]` pins `mistralai>=2.3.0,<3`, but the `mistralai` project on
# PyPI is currently quarantined (zero installable versions), which makes the full
# `[all]` extra unresolvable. Drop `[mistral]` from our expansion until either
# PyPI restores the package or upstream removes the pin.
RUN git clone --depth 1 --branch ${HERMES_REF} https://github.com/NousResearch/hermes-agent.git /opt/hermes-agent && \
    cd /opt/hermes-agent && \
    uv pip install --system --no-cache -e ".[modal,daytona,vercel,messaging,matrix,cron,cli,dev,tts-premium,slack,pty,honcho,mcp,homeassistant,sms,acp,voice,dingtalk,feishu,google,bedrock,web]" && \
    cd /opt/hermes-agent/web && \
    npm install --silent && \
    npm run build && \
    cd /opt/hermes-agent/ui-tui && \
    npm install --silent --no-fund --no-audit --progress=false && \
    npm run build && \
    rm -rf /opt/hermes-agent/web /opt/hermes-agent/.git /root/.npm

# Defensive patch for delegate_tool.py: validate override_acp_command
# binaries actually exist on PATH before forcing the copilot-acp transport.
# Without this, a model that hallucinates acp_command="copilot" in a
# delegate_task call crashes the subagent and can take the whole gateway
# down. Upstream fix: https://github.com/NousResearch/hermes-agent/pull/27426
# Remove this RUN once the PR merges and HERMES_REF is bumped past it.
COPY patches/delegate_tool_acp_guard.py /tmp/delegate_tool_acp_guard.py
RUN python3 /tmp/delegate_tool_acp_guard.py && rm /tmp/delegate_tool_acp_guard.py

# Why pre-build ui-tui (and why we don't delete it after):
# - The dashboard's embedded Chat tab spawns `node ui-tui/dist/entry.js`
#   on every WebSocket connect to /api/pty.
# - hermes's _make_tui_argv runs `npm install` + `npm run build` via
#   *synchronous* subprocess.run if dist/entry.js is missing or stale —
#   that would block the dashboard's asyncio event loop for 30-60s on
#   the first chat-open, freezing every other request.
# - Pre-building at image time costs ~200-300 MB of node_modules but
#   makes first-chat-open instant and surfaces any build failure here
#   instead of at user request time.
# - We keep ui-tui/ entirely (node_modules + dist + src) so hermes's
#   freshness checks don't trigger a re-install at runtime.

COPY requirements.txt /app/requirements.txt
RUN uv pip install --system --no-cache -r /app/requirements.txt

RUN mkdir -p /data/.hermes

COPY server.py /app/server.py
COPY templates/ /app/templates/
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

ENV HOME=/data
ENV HERMES_HOME=/data/.hermes

# _hermes_ink_bundle_stale() check (which still looks for the old ink-bundle.js filename, but v5.7's build produces entry-exports.js)
# always returns True, triggering a full `npm run build` inside every /chat WebSocket request. Setting HERMES_TUI_DIR routes through the
# early-return path in _make_tui_argv that skips staleness detection entirely. Upstream bug; remove this when v2026.5.x ships the fix.
ENV HERMES_TUI_DIR=/opt/hermes-agent/ui-tui

# tini wraps start.sh so it runs as PID 1's child instead of as PID 1 itself.
# `-g` propagates signals to the whole process group so `docker stop` /
# Railway's SIGTERM cleanly terminates the entire tree, not just start.sh.
ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/app/start.sh"]
