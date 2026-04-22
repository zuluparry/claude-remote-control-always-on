#!/bin/bash
# Install Claude Remote Control as an always-on macOS LaunchAgent.
# Prompts for user-specific values, substitutes into templates, bootstraps launchd.
#
# Usage : ./install.sh
# Uninstall : ./install.sh --uninstall

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}==>${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
warn()    { echo -e "${YELLOW}⚠${NC} $1"; }
error()   { echo -e "${RED}✗${NC} $1" >&2; }

uninstall() {
    info "Uninstalling Claude Remote Control (Command Centre)..."

    read -r -p "Bundle ID to uninstall [e.g., com.example.command-centre]: " BUNDLE_ID
    [ -z "$BUNDLE_ID" ] && { error "Bundle ID required"; exit 1; }

    launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || warn "LaunchAgent not loaded (already gone?)"
    /opt/homebrew/bin/tmux kill-session -t command-centre 2>/dev/null || true
    pkill -9 -f "claude remote-control" 2>/dev/null || true

    rm -f "$HOME/Library/LaunchAgents/${BUNDLE_ID}.plist"
    rm -rf "$HOME/scripts/command-centre"
    rm -f "$HOME/.claude/commands/spawn-session.md"
    rm -f "$HOME/.claude/commands/kill-session.md"
    rm -f "$HOME/.claude/commands/list-sessions.md"
    rm -rf "$HOME/.claude/skills/claude-remote-control-always-on"

    success "Uninstalled. Logs kept in $HOME/Library/Logs/command-centre/ for audit (delete manually if wanted)."
}

if [ "${1:-}" = "--uninstall" ]; then
    uninstall
    exit 0
fi

# === Pre-flight checks ===
info "Pre-flight checks..."

[ "$(uname)" = "Darwin" ] || { error "This installer is macOS-only (Darwin)"; exit 1; }

if ! command -v tmux >/dev/null 2>&1; then
    error "tmux is required. Install with: brew install tmux"
    exit 1
fi
TMUX_BIN="$(command -v tmux)"
success "tmux found at $TMUX_BIN"

if ! command -v claude >/dev/null 2>&1; then
    error "claude CLI not found in PATH. Install Claude Code first."
    exit 1
fi
CLAUDE_BIN_DEFAULT="$(command -v claude)"
success "claude CLI found at $CLAUDE_BIN_DEFAULT"

# Check auth state : must have claude.ai session (not just long-lived token)
AUTH_STATUS=$(env -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH claude auth status 2>&1 || true)
if ! echo "$AUTH_STATUS" | grep -q '"authMethod": "claude.ai"'; then
    error "You must run 'claude auth login' first. Remote Control requires a full-scope claude.ai session."
    error "Current auth status:"
    echo "$AUTH_STATUS" | head -10
    exit 1
fi
success "claude.ai session present"

# === Prompt for config ===
info "Configuration (press Enter to accept defaults)..."

DEFAULT_BUNDLE_ID="com.$(whoami).command-centre"
read -r -p "Bundle ID [$DEFAULT_BUNDLE_ID]: " BUNDLE_ID
BUNDLE_ID="${BUNDLE_ID:-$DEFAULT_BUNDLE_ID}"

read -r -p "Claude binary path [$CLAUDE_BIN_DEFAULT]: " CLAUDE_BIN
CLAUDE_BIN="${CLAUDE_BIN:-$CLAUDE_BIN_DEFAULT}"

DEFAULT_WORK_DIR="$HOME/Documents/Claude Code"
if [ ! -d "$DEFAULT_WORK_DIR" ]; then DEFAULT_WORK_DIR="$HOME"; fi
read -r -p "Working directory (a trusted claude workspace) [$DEFAULT_WORK_DIR]: " WORK_DIR
WORK_DIR="${WORK_DIR:-$DEFAULT_WORK_DIR}"

read -r -p "Session display name [Command Centre]: " SESSION_NAME
SESSION_NAME="${SESSION_NAME:-Command Centre}"

LOG_DIR="$HOME/Library/Logs/command-centre"
mkdir -p "$LOG_DIR"

WRAPPER_PATH="$HOME/scripts/command-centre/run.sh"
mkdir -p "$(dirname "$WRAPPER_PATH")"

PLIST_PATH="$HOME/Library/LaunchAgents/${BUNDLE_ID}.plist"

# PATH to inherit in the LaunchAgent (must include claude binary's directory)
CLAUDE_BIN_DIR="$(dirname "$CLAUDE_BIN")"
PATH_FOR_PLIST="$CLAUDE_BIN_DIR:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin"

info "Summary:"
echo "  Bundle ID     : $BUNDLE_ID"
echo "  Claude binary : $CLAUDE_BIN"
echo "  tmux binary   : $TMUX_BIN"
echo "  Working dir   : $WORK_DIR"
echo "  Session name  : $SESSION_NAME"
echo "  Log dir       : $LOG_DIR"
echo "  Wrapper       : $WRAPPER_PATH"
echo "  Plist         : $PLIST_PATH"

read -r -p "Proceed? [Y/n] " CONFIRM
CONFIRM="${CONFIRM:-Y}"
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    warn "Aborted."
    exit 0
fi

# === Substitute templates ===
info "Writing wrapper script..."
sed \
    -e "s|__LOG_DIR__|${LOG_DIR}|g" \
    -e "s|__WORK_DIR__|${WORK_DIR}|g" \
    -e "s|__TMUX_BIN__|${TMUX_BIN}|g" \
    -e "s|__CLAUDE_BIN__|${CLAUDE_BIN}|g" \
    -e "s|__SESSION_NAME__|${SESSION_NAME}|g" \
    "$REPO_ROOT/templates/run.sh.template" > "$WRAPPER_PATH"
chmod +x "$WRAPPER_PATH"
success "Wrote $WRAPPER_PATH"

info "Writing plist..."
sed \
    -e "s|__BUNDLE_ID__|${BUNDLE_ID}|g" \
    -e "s|__WRAPPER_PATH__|${WRAPPER_PATH}|g" \
    -e "s|__LOG_DIR__|${LOG_DIR}|g" \
    -e "s|__PATH__|${PATH_FOR_PLIST}|g" \
    -e "s|__HOME__|${HOME}|g" \
    -e "s|__USER__|$(whoami)|g" \
    "$REPO_ROOT/templates/command-centre.plist.template" > "$PLIST_PATH"
success "Wrote $PLIST_PATH"

# === Install skills + commands ===
info "Installing skill and slash commands..."
mkdir -p "$HOME/.claude/skills/claude-remote-control-always-on"
cp "$REPO_ROOT/skills/claude-remote-control-always-on/SKILL.md" "$HOME/.claude/skills/claude-remote-control-always-on/SKILL.md"

mkdir -p "$HOME/.claude/commands"
for cmd in spawn-session kill-session list-sessions; do
    sed \
        -e "s|__CLAUDE_BIN__|${CLAUDE_BIN}|g" \
        -e "s|__TMUX_BIN__|${TMUX_BIN}|g" \
        -e "s|__WORK_DIR__|${WORK_DIR}|g" \
        -e "s|__LOG_DIR__|${LOG_DIR}|g" \
        "$REPO_ROOT/commands/${cmd}.md" > "$HOME/.claude/commands/${cmd}.md"
done
success "Skill and slash commands installed"

# === Bootstrap LaunchAgent ===
info "Bootstrapping LaunchAgent..."
launchctl bootout "gui/$(id -u)/${BUNDLE_ID}" 2>/dev/null || true
sleep 1
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
sleep 6

# === Verify ===
info "Verifying..."
if launchctl list | grep -q "${BUNDLE_ID}"; then
    PID_LINE=$(launchctl list | grep "${BUNDLE_ID}")
    PID=$(echo "$PID_LINE" | awk '{print $1}')
    EXIT_CODE=$(echo "$PID_LINE" | awk '{print $2}')
    if [ "$PID" = "-" ]; then
        warn "LaunchAgent registered but process not running. Last exit code: $EXIT_CODE"
        warn "Check logs: $LOG_DIR/command-centre-wrapper.log and $LOG_DIR/command-centre.tmux.log"
    else
        success "LaunchAgent running at PID $PID"
    fi
else
    error "LaunchAgent did not register. See $LOG_DIR/command-centre.stderr for details."
    exit 1
fi

if "$TMUX_BIN" has-session -t command-centre 2>/dev/null; then
    success "tmux session 'command-centre' alive"
else
    warn "tmux session not yet up. Wait 10 more seconds and check: $TMUX_BIN ls"
fi

ENV_URL=$(grep -o 'https://claude.ai/code?environment=env_[A-Za-z0-9]*' "$LOG_DIR/command-centre.tmux.log" 2>/dev/null | head -1 || true)
if [ -n "$ENV_URL" ]; then
    success "Environment registered: $ENV_URL"
fi

# === Done ===
echo ""
success "Installation complete."
echo ""
echo "Next steps:"
echo "  1. Open the Claude iOS app → Code tab"
echo "  2. Look for '$SESSION_NAME' in the list (or open the URL above)"
echo "  3. Tap in and send a test message"
echo ""
echo "Manage:"
echo "  Restart  : launchctl kickstart -k gui/\$(id -u)/${BUNDLE_ID}"
echo "  Stop     : launchctl bootout gui/\$(id -u)/${BUNDLE_ID}"
echo "  Uninstall: $REPO_ROOT/install.sh --uninstall"
echo ""
echo "Once running, from the phone's Command Centre session you can type:"
echo "  /spawn-session <name>   : start a new ephemeral session"
echo "  /kill-session <name>    : stop one"
echo "  /list-sessions          : see all active"
