---
description: Spawn a new Claude Code Remote Control session on this Mac so it appears in the phone's Code tab. Ephemeral by default (dies on reboot). Pass a session name as the argument.
---

# /spawn-session — Start a new remote-control session

**Usage:** `/spawn-session <session name>`

Examples :
- `/spawn-session Email Triage`
- `/spawn-session Urgent Tickets`
- `/spawn-session hubspot-backfill`

**What it does:** starts `claude remote-control --name "<name>"` inside a detached tmux session on this Mac. Within ~5 seconds the new session appears in the Claude iOS Code tab. Tap in from the phone.

**Scope:** tmux-only. Session dies on reboot or explicit `/kill-session`. The persistent Command Centre session is the always-on one managed by launchd ; spawned sessions are task-specific.

## Steps

### 1. Parse the argument

The argument after `/spawn-session` is the session's display name. Take it verbatim as `DISPLAY_NAME`. If no argument is given, stop and ask : "What should I call this session?".

Slugify `DISPLAY_NAME` to `SLUG` :
- Lowercase
- Spaces → hyphens
- Strip anything that isn't `a-z0-9-`
- Collapse multiple hyphens into one
- Strip leading / trailing hyphens

Example : `Hotspot Leeds` → `hotspot-leeds`. Tmux session will be `session-hotspot-leeds`.

### 2. Pre-flight checks

```bash
TMUX_BIN="__TMUX_BIN__"
CLAUDE_BIN="__CLAUDE_BIN__"
LOG_DIR="__LOG_DIR__"

if "$TMUX_BIN" has-session -t "session-$SLUG" 2>/dev/null; then
    echo "A session called $DISPLAY_NAME already exists. Use /kill-session $DISPLAY_NAME first, or pick a different name."
    exit 1
fi

[ -x "$CLAUDE_BIN" ] || { echo "claude CLI not found at $CLAUDE_BIN"; exit 1; }
[ -x "$TMUX_BIN" ]   || { echo "tmux not found at $TMUX_BIN"; exit 1; }
```

### 3. Spawn the tmux session

```bash
"$TMUX_BIN" new-session -d \
    -s "session-$SLUG" \
    -c "__WORK_DIR__" \
    "$CLAUDE_BIN remote-control --name \"$DISPLAY_NAME\" 2>&1 | tee -a $LOG_DIR/spawned-session-$SLUG.log"
```

### 4. Wait and verify

```bash
sleep 5
ENV_URL=$(grep -o 'https://claude.ai/code?environment=env_[A-Za-z0-9]*' "$LOG_DIR/spawned-session-$SLUG.log" | head -1)
```

### 5. Report back

Tell the user in this shape :

```
Spawned: <DISPLAY_NAME>
Tmux session: session-<SLUG>
Direct URL: <ENV_URL>
Kill with: /kill-session <DISPLAY_NAME>

Check your phone's Code tab for "<DISPLAY_NAME>" and tap in.
```

If `ENV_URL` is empty after 5 seconds, report : "Session spawned but environment URL not yet registered. Check the Code tab in 10 seconds, or tail the log at $LOG_DIR/spawned-session-<SLUG>.log"

## Edge cases

- **No argument given** : ask for the name, don't assume.
- **Reserved names** : the names "Command Centre" and slug `command-centre` refer to the launchd-managed persistent session. Refuse to spawn with either : "That name is reserved for the persistent Command Centre session managed by launchd."
- **More than 10 spawned sessions active** : warn before proceeding. Each holds resources.

## Related

- `/kill-session <name>` : stop a spawned session
- `/list-sessions` : show all active sessions
