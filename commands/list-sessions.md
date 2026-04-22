---
description: List all active Claude Code Remote Control sessions running on this Mac, including the persistent Command Centre and any /spawn-session spawns.
---

# /list-sessions — Show active remote-control sessions

**Usage:** `/list-sessions` (no arguments)

**What it does:** lists every tmux session hosting a `claude remote-control` process on this Mac, so you can see what's running, the resources you're holding, and what to kill.

## Steps

### 1. Enumerate tmux sessions

```bash
TMUX_BIN="__TMUX_BIN__"
LOG_DIR="__LOG_DIR__"

TMUX_OUTPUT=$("$TMUX_BIN" ls 2>&1)
if echo "$TMUX_OUTPUT" | grep -q "no server running"; then
    echo "No tmux server running. No active sessions."
    exit 0
fi
```

### 2. Identify claude remote-control sessions

Expected naming :
- `command-centre` : the launchd-managed persistent session
- `session-<slug>` : sessions spawned via `/spawn-session`

```bash
"$TMUX_BIN" ls -F '#{session_name}|#{session_created}' | while IFS='|' read -r name created; do
    if [ "$name" = "command-centre" ]; then
        type="persistent"
        display_name="Command Centre"
        log_path="$LOG_DIR/command-centre.tmux.log"
    elif [[ "$name" == session-* ]]; then
        type="ephemeral"
        slug="${name#session-}"
        display_name="$slug"
        log_path="$LOG_DIR/spawned-session-$slug.log"
    else
        continue
    fi

    env_url=""
    if [ -f "$log_path" ]; then
        env_url=$(grep -o 'https://claude.ai/code?environment=env_[A-Za-z0-9]*' "$log_path" | head -1)
    fi

    created_human=$(date -r "$created" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$created")
    echo "$display_name|$type|$created_human|$env_url"
done
```

### 3. Report back

Format as a readable table :

```
Active sessions on this Mac:

| Session | Type | Started | URL |
|---|---|---|---|
| Command Centre | persistent | 2026-04-22 11:56 | https://claude.ai/code?environment=env_... |
| Email Triage | ephemeral | 2026-04-22 14:15 | https://claude.ai/code?environment=env_... |

Kill any with: /kill-session <name>
```

If nothing is running :

```
No active sessions.
Command Centre should be running via launchd. Check:
  launchctl list | grep command-centre
```

## Edge cases

- **Command Centre down** (launchd not running it) : flag this loudly. It should always be up.
- **Orphan tmux sessions** (tmux running but claude process died) : flag with a "⚠ process dead" note.
- **Stale log files** for sessions that no longer exist : ignore.

## Related

- `/spawn-session <name>` : start a new session
- `/kill-session <name>` : stop a session
