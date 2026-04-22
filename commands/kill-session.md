---
description: Kill a previously-spawned Claude Code Remote Control session on this Mac. Pass the session name as the argument.
---

# /kill-session — Stop a spawned remote-control session

**Usage:** `/kill-session <session name>`

Examples :
- `/kill-session Email Triage`
- `/kill-session hubspot-backfill`

**What it does:** kills the tmux session that hosts `claude remote-control` for the named session. The session drops off the phone Code tab after the Anthropic backend reaps it.

**Does NOT apply to the persistent Command Centre session.** That one is managed by launchd : killing it via this command would only trigger launchd to respawn it. Use `launchctl bootout gui/$(id -u)/<bundle-id>` for that (and only if you really want to stop it).

## Steps

### 1. Parse the argument

The argument after `/kill-session` is the name used when spawning. Take it verbatim as `DISPLAY_NAME`. If no argument given, run `/list-sessions` first, then stop and ask which to kill.

Slugify `DISPLAY_NAME` to `SLUG` (same rules as `/spawn-session` : lowercase, spaces-to-hyphens, strip non-alphanumeric).

### 2. Safety check

```bash
TMUX_BIN="__TMUX_BIN__"

if [ "$SLUG" = "command-centre" ]; then
    echo "The Command Centre session is the persistent launchd-managed one. Use 'launchctl bootout gui/\$(id -u)/<bundle-id>' if you really mean to stop it."
    exit 1
fi

if ! "$TMUX_BIN" has-session -t "session-$SLUG" 2>/dev/null; then
    echo "No active session called $DISPLAY_NAME (looked for tmux session 'session-$SLUG'). Use /list-sessions to see what's running."
    exit 1
fi
```

### 3. Kill cleanly

```bash
# Graceful first
"$TMUX_BIN" send-keys -t "session-$SLUG" C-c
sleep 2

# Then kill the tmux session
"$TMUX_BIN" kill-session -t "session-$SLUG"
```

### 4. Confirm

```bash
if "$TMUX_BIN" has-session -t "session-$SLUG" 2>/dev/null; then
    echo "WARNING: session-$SLUG still exists. Try: $TMUX_BIN kill-session -t session-$SLUG"
    exit 1
else
    echo "Killed: $DISPLAY_NAME (tmux session-$SLUG). Drops off phone Code tab within a few minutes."
fi
```

## Edge cases

- **No argument given** : don't assume. Run `/list-sessions` first to show options, then ask.
- **Ambiguous match** (multiple slugs start with the same prefix) : list candidates, ask which.
- **Kill fails** : report the exact tmux error and suggest manual `tmux kill-session -t session-<slug>`.

## Related

- `/spawn-session <name>` : start a new session
- `/list-sessions` : show all active sessions
