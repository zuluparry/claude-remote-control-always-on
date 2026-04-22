---
name: claude-remote-control-always-on
description: |
  Run `claude remote-control` as an always-on macOS LaunchAgent so a Claude Code session
  is permanently available in the Claude iOS app's Code tab (phone tap-in). Use when:
  (1) wiring `claude remote-control --name "X"` into a macOS LaunchAgent,
  (2) `claude remote-control` under launchd fails with "An unknown error occurred (Unexpected)",
  (3) "Remote Control requires a full-scope login token" error from a plist-launched claude,
  (4) "You must be logged in to use Remote Control" when claude.ai session exists,
  (5) "Workspace not trusted" error from a LaunchAgent-spawned claude,
  (6) "low max file descriptors (Unexpected)" under launchd,
  (7) iPhone's Claude app Code tab loses the session every time the terminal closes,
  (8) building `/spawn-session` / `/kill-session` slash commands for ephemeral sub-sessions.
  Covers six specific launchd blockers, the tmux-pseudo-TTY fix, and companion slash-command
  patterns for ephemeral session spawning from the phone.
author: Claude Code
version: 1.0.0
date: 2026-04-22
---

# Claude Remote Control as an Always-On macOS LaunchAgent

## Problem

`claude remote-control --name "X"` is how Claude Code exposes a local session to the
Claude iOS app's Code tab ("Remote control" sessions on the phone). The command is
designed to run in an interactive terminal. If you close the terminal, the session
dies, the phone loses access, and `claude` must be manually restarted.

Wrapping it in a macOS LaunchAgent so it auto-starts at login, survives reboots,
and self-heals on crash sounds like a five-minute plist. In practice there are
**six separate, silently-failing blockers**. All are undocumented in Anthropic's
Claude Code docs as of 2.1.114 (April 2026). This skill lists each and its fix,
plus a companion pattern of three slash commands for ephemeral session spawning
from the phone.

## Trigger Conditions

Use this skill when :

- Designing an always-on Claude Code phone surface on macOS
- A LaunchAgent running `claude remote-control` exits with code 1 and stderr is either empty or shows a generic message
- You see "An unknown error occurred (Unexpected)" from a plist-spawned `claude`
- You see "Remote Control requires a full-scope login token" when you thought you were logged in
- You need the iPhone Claude app's Code tab to show a named session 24/7 without keeping a Mac terminal open

## Solution Architecture

Three components, in this order :

1. **A plist at `~/Library/LaunchAgents/<bundle-id>.plist`** that launchd manages.
2. **A wrapper shell script** that the plist invokes. The wrapper does `cd` + spawns a detached tmux session + monitors it, exiting non-zero if tmux dies so launchd respawns.
3. **A tmux session** hosting `claude remote-control --name "Command Centre"` with a pseudo-TTY.

Flow :

```
launchd  →  wrapper.sh  →  tmux new-session -d  →  claude remote-control --name "Command Centre"
(boots)     (cd + spawn)    (pseudo-TTY host)     (the actual remote-control process)
```

## The Six Blockers and Their Fixes

### Blocker 1 : Long-lived OAuth tokens rejected

**Symptom:** `Error: Remote Control requires a full-scope login token. Long-lived tokens (from 'claude setup-token' or CLAUDE_CODE_OAUTH_TOKEN) are limited to inference-only for security reasons.`

**Cause:** The claude CLI's Remote Control subcommand deliberately rejects the long-lived OAuth tokens used by headless dispatch (e.g., `claude -p` jobs). It requires the full-scope session token produced by `claude auth login` (the claude.ai web-auth flow).

**Fix:** Do NOT inherit `CLAUDE_CODE_OAUTH_TOKEN` in the LaunchAgent. launchd starts with a clean environment by default, so simply don't set it in the plist's `EnvironmentVariables` dict. The on-disk claude.ai session from a prior `claude auth login` run will be used automatically.

**Verify:** with the long-lived token stripped, `env -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH claude auth status` must report `"authMethod": "claude.ai"` and `"loggedIn": true`.

### Blocker 2 : File descriptor limit

**Symptom:** `error: An unknown error occurred, possibly due to low max file descriptors (Unexpected)` with `Current limit: 256`.

**Cause:** launchd's default `NumberOfFiles` is 256. claude (especially with MCP servers spawned) needs many more.

**Fix:** Add to the plist :

```xml
<key>SoftResourceLimits</key>
<dict>
    <key>NumberOfFiles</key>
    <integer>65536</integer>
</dict>
<key>HardResourceLimits</key>
<dict>
    <key>NumberOfFiles</key>
    <integer>65536</integer>
</dict>
```

### Blocker 3 : USER and LOGNAME required for auth lookup

**Symptom:** With only `HOME` set, `claude auth status` reports `{"loggedIn": false, "authMethod": "none"}` even though an interactive terminal shows the user is logged in.

**Cause:** The claude.ai session token lookup on disk (likely Keychain-backed) needs `USER` and `LOGNAME` in the environment to resolve.

**Fix:** Explicitly set both in the plist :

```xml
<key>EnvironmentVariables</key>
<dict>
    <key>HOME</key>
    <string>/Users/CHRIS</string>
    <key>USER</key>
    <string>CHRIS</string>
    <key>LOGNAME</key>
    <string>CHRIS</string>
    <key>PATH</key>
    <string>/Users/CHRIS/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
</dict>
```

### Blocker 4 : `WorkingDirectory` hits macOS TCC on `~/Documents/`

**Symptom:** `shell-init: error retrieving current directory: getcwd: cannot access parent directories: Operation not permitted`.

**Cause:** Even with Full Disk Access granted to `/bin/bash`, setting `<key>WorkingDirectory</key>` to a path inside `~/Documents/`, `~/Downloads/`, or `~/Desktop/` causes launchd's initial `chdir` to fail due to macOS TCC (Transparency, Consent, Control) policy on protected folders.

**Fix:** Omit `WorkingDirectory` entirely from the plist. Let launchd start the wrapper from `/`, and have the wrapper `cd` into the desired directory after the process is running. The wrapper has FDA via the interactive terminal lineage and succeeds where launchd's pre-chdir fails.

### Blocker 5 : "Workspace not trusted" when starting from `/`

**Symptom:** `Error: Workspace not trusted. Please run 'claude' in / first to review and accept the workspace trust dialog.`

**Cause:** `claude remote-control` refuses to run in directories that haven't been marked trusted. `/` (the root directory) is never trusted.

**Fix:** The wrapper must `cd` into a previously-trusted directory (one where the user has run `claude` interactively before, triggering the workspace-trust dialog) BEFORE executing `claude remote-control`. Typically the user's working project root. Chain the `cd` with `|| exit 1` so a failed `cd` kills the wrapper (letting launchd surface the error cleanly).

### Blocker 6 : launchd provides no controlling TTY (the only non-obvious one)

**Symptom:** After fixing all of blockers 1-5, the plist still fails with the generic `error: An unknown error occurred (Unexpected)`. When you run the EXACT SAME wrapper script with the EXACT SAME env manually from a terminal, it works. Under launchd, it silently exits.

**Cause:** `claude remote-control` uses interactive terminal features (ANSI escape sequences, stdin-based hotkeys like "space to show QR"). Under launchd there is no controlling TTY. claude detects this and exits with the unhelpful generic error rather than a specific "no TTY" message.

**Fix (the key insight of this skill):** Wrap `claude remote-control` inside `tmux new-session -d` instead of invoking it directly. tmux provides a pseudo-TTY. claude runs happily inside it. The wrapper script monitors the tmux session and exits non-zero if tmux dies, which triggers launchd's `KeepAlive` to respawn the wrapper, which starts a fresh tmux. Full self-heal.

```bash
/opt/homebrew/bin/tmux new-session -d \
    -s "session-name" \
    -c "/path/to/trusted/dir" \
    "/path/to/claude remote-control --name \"Display Name\" 2>&1 | tee -a /path/to/log"
```

## Reference Implementation

### The plist : `~/Library/LaunchAgents/<bundle-id>.command-centre.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>io.example.command-centre</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/Users/CHRIS/scripts/command-centre/run.sh</string>
    </array>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/Users/CHRIS/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin</string>
        <key>HOME</key>
        <string>/Users/CHRIS</string>
        <key>USER</key>
        <string>CHRIS</string>
        <key>LOGNAME</key>
        <string>CHRIS</string>
    </dict>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>ThrottleInterval</key>
    <integer>30</integer>

    <key>ProcessType</key>
    <string>Background</string>

    <key>SoftResourceLimits</key>
    <dict>
        <key>NumberOfFiles</key>
        <integer>65536</integer>
    </dict>

    <key>HardResourceLimits</key>
    <dict>
        <key>NumberOfFiles</key>
        <integer>65536</integer>
    </dict>

    <key>StandardOutPath</key>
    <string>/Users/CHRIS/Library/Logs/command-centre.stdout</string>

    <key>StandardErrorPath</key>
    <string>/Users/CHRIS/Library/Logs/command-centre.stderr</string>
</dict>
</plist>
```

Key points : no `WorkingDirectory`, no `CLAUDE_CODE_OAUTH_TOKEN`, USER+LOGNAME set, fd limit raised.

### The wrapper : `~/scripts/command-centre/run.sh`

```bash
#!/bin/bash
# Start claude remote-control inside a detached tmux session.
# tmux provides the pseudo-TTY that claude remote-control needs under launchd.
set -u
LOG=/Users/CHRIS/Library/Logs/command-centre-wrapper.log
echo "=== $(date) starting ===" >> "$LOG"
cd "/Users/CHRIS/Documents/Claude Code" || { echo "cd failed" >> "$LOG"; exit 1; }

TMUX=/opt/homebrew/bin/tmux
SESSION="command-centre"

# If session already exists (e.g., fast restart), do nothing
if "$TMUX" has-session -t "$SESSION" 2>/dev/null; then
    echo "tmux session $SESSION already exists, keeping wrapper alive" >> "$LOG"
    sleep infinity
fi

# Start claude inside detached tmux
CLAUDE_LOG=/Users/CHRIS/Library/Logs/command-centre.tmux.log
"$TMUX" new-session -d -s "$SESSION" -c "/Users/CHRIS/Documents/Claude Code" \
    "/Users/CHRIS/.local/bin/claude remote-control --name 'Command Centre' 2>&1 | tee -a '$CLAUDE_LOG'"

echo "tmux session started" >> "$LOG"

# Monitor: if session dies, exit non-zero so launchd respawns
while "$TMUX" has-session -t "$SESSION" 2>/dev/null; do
    sleep 15
done
echo "=== $(date) tmux session died, exiting for launchd respawn ===" >> "$LOG"
exit 1
```

### Bootstrapping

```bash
chmod +x ~/scripts/command-centre/run.sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/io.example.command-centre.plist
launchctl list | grep command-centre   # should show a PID, not '-'
tmux ls                                 # should show 'command-centre: 1 windows'
```

### Diagnostics

```bash
# Live status
launchctl list | grep command-centre
tmux ls
pgrep -af "claude remote-control"
tail -30 ~/Library/Logs/command-centre.tmux.log
tail -30 ~/Library/Logs/command-centre-wrapper.log

# Clean restart
launchctl kickstart -k gui/$(id -u)/io.example.command-centre

# Full stop
launchctl bootout gui/$(id -u)/io.example.command-centre
```

## Companion Pattern : Slash Commands for Ephemeral Sub-Sessions

Once the persistent "Command Centre" session is live, users often want to spawn
short-lived sub-sessions from their phone ("spawn me a session for this Leeds job").
Three slash commands under `~/.claude/commands/` provide this :

- **`/spawn-session <name>`** — wraps `tmux new-session -d -s session-<slug> 'claude remote-control --name "<name>"'`. New env registers within ~5s, appears in phone's Code tab. Ephemeral by default.
- **`/kill-session <name>`** — sends SIGTERM to the tmux session and kills it. Refuses to kill the launchd-managed persistent Command Centre.
- **`/list-sessions`** — enumerates active tmux sessions, reports display name, type (persistent / ephemeral), env URL, start time.

Users invoke them from Command Centre on the phone. Natural-language equivalents
also work ("spawn me a session for Leeds") because Claude interprets intent before
executing. iOS doesn't display slash-command autocomplete in the Code tab, so
users either memorise, type full name blind, or use natural language.

Slug convention : `session-<slug>` tmux session name, with `<slug>` = lowercased
display name with spaces-to-hyphens and non-alphanumeric stripped. Logs go to
`~/Library/Logs/spawned-session-<slug>.log`.

## Verification

End-to-end verification after install :

1. `launchctl list | grep <bundle-id>` shows a running PID (not `-`) and exit code `0`.
2. `tmux ls` shows `command-centre: 1 windows`.
3. `pgrep -af "claude remote-control"` returns at least one PID.
4. The tmux log shows `·✔︎· Connected · Claude Code · HEAD` and an environment URL.
5. On iPhone, open Claude app → Code tab : the named session appears.
6. Send a test message from phone ; within 5 seconds a child claude process (`pgrep -af 'claude --print --sdk-url'`) is spawned and replies.
7. `pkill -f "claude remote-control"` and verify launchd respawns within 30s (wrapper log shows "tmux session died, exiting for launchd respawn" followed by a new `tmux session started`).

If the fresh test fails (no reply from phone), the issue is almost always that the phone tapped into a ghost environment from earlier debug cycles — force-quit the iOS app, reopen, tap the newest entry in the list. Each `claude remote-control` invocation registers a fresh `env_*` ID with Anthropic's backend ; the iOS app caches dead ones until they're reaped.

## Notes

- **Multiple "Command Centre" entries in the phone Code tab** after debugging is expected. Each process-restart registered a new env_id. Ghosts expire after some hours.
- **Every LaunchAgent restart creates a new env_id.** After a reboot the phone will show one new entry. Normal.
- **If launchd cycles rapidly** (crash loop), the phone list will bloat. Diagnose via the wrapper log.
- **Permissions mode** : spawned sessions inherit the default. If you want `bypassPermissions`, add `--permission-mode bypassPermissions` to the claude command in the wrapper or slash-command tmux invocation.
- **Model choice** : whichever `claude remote-control` defaults to on your CLI install. Change per session via the model selector in the iOS chat UI.
- **Auth prerequisite** : must have run `claude auth login` interactively on the Mac mini once before the plist will work. The plist uses the on-disk claude.ai session that login produces.
- **Not supported on macOS versions before 12** : launchd plist format is current as of macOS 14+ but should work on 12-15.

## Related Skills

- `claude-cli-scheduled-dispatch` — the companion skill for `claude -p` (print mode) under launchd. Covers three different blockers (TCC on `~/.claude/`, Background-approval, `---` frontmatter parsing). Reference when setting up scheduled tasks that send one-shot prompts. Orthogonal to this skill : print mode is headless-inference ; remote-control is interactive-session.

## References

- [Claude Code documentation](https://docs.claude.com/en/docs/claude-code) — official CLI docs. Remote Control is mentioned but the LaunchAgent patterns are not.
- [macOS launchd documentation (`man launchd.plist`)](https://www.manpagez.com/man/5/launchd.plist/) — the authoritative reference for plist keys like `SoftResourceLimits`, `KeepAlive`, `ThrottleInterval`, `ProcessType`.
- [tmux manual](https://man.openbsd.org/tmux.1) — for the pseudo-TTY wrapping pattern (`new-session -d`, `has-session`).
- [Apple TCC protection docs](https://developer.apple.com/documentation/devicemanagement/privacypreferencespolicycontrol) — for the `~/Documents/` / Full Disk Access interaction described in Blocker 4.

## Notes on Publication

This skill is a candidate for extraction into a standalone macOS tool / GitHub repo
for broader Claude Code community use. Parameterise `CHRIS` → `${USER}`, `io.example` →
`${DOMAIN}.${APPNAME}`, `/Users/CHRIS/.local/bin/claude` → `$(which claude)`, and ship
with an `install.sh` that handles the launchctl bootstrap and verification.
