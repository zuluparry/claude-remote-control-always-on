# The Six Blockers

This document describes each of the six non-obvious failures you hit when trying to run `claude remote-control` under a macOS LaunchAgent, and the exact fix for each. The `install.sh` script handles all of them automatically, but you may want to understand them if you're debugging or adapting the pattern.

All blockers verified on macOS 14 / Claude Code 2.1.114 / April 2026.

---

## Blocker 1 : `claude remote-control` rejects long-lived OAuth tokens

### Symptom

```
Error: Remote Control requires a full-scope login token. Long-lived tokens
(from 'claude setup-token' or CLAUDE_CODE_OAUTH_TOKEN) are limited to
inference-only for security reasons. Run 'claude auth login' to use
Remote Control.
```

### Cause

The `claude` CLI supports two auth methods :

- **Long-lived OAuth token** (from `claude setup-token` or the `CLAUDE_CODE_OAUTH_TOKEN` env var). Inference-only by Anthropic security policy.
- **`claude.ai` session token** (from `claude auth login`, which opens a browser). Full-scope.

Remote Control specifically requires the full-scope one. If both are present in the environment, the long-lived one wins and Remote Control refuses.

### Fix

Don't pass `CLAUDE_CODE_OAUTH_TOKEN` to the LaunchAgent. launchd starts processes with a clean environment by default, so as long as you don't explicitly set it in the plist's `EnvironmentVariables` dict, you're fine.

### Verify

```bash
env -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH claude auth status
```

Must print `"authMethod": "claude.ai"` and `"loggedIn": true`. If not, run `claude auth login` first.

---

## Blocker 2 : File descriptor limit

### Symptom

```
error: An unknown error occurred, possibly due to low max file descriptors (Unexpected)

Current limit: 256
```

### Cause

launchd's default `NumberOfFiles` soft limit is 256. Claude (especially with MCP servers, which each open sockets and files) needs many more.

### Fix

In the plist, set :

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

---

## Blocker 3 : `USER` and `LOGNAME` missing

### Symptom

Wrapper runs fine, but `claude auth status` inside it reports :

```json
{"loggedIn": false, "authMethod": "none"}
```

…even though an interactive terminal shows the user is logged in with `"authMethod": "claude.ai"`.

### Cause

The on-disk `claude.ai` session lookup (Keychain-backed) requires `USER` and `LOGNAME` env vars in addition to `HOME`. Without them, the lookup returns no match.

### Fix

Set both explicitly in the plist's `EnvironmentVariables` dict :

```xml
<key>USER</key>
<string>your-username</string>
<key>LOGNAME</key>
<string>your-username</string>
```

(Along with `HOME` and `PATH`.)

---

## Blocker 4 : `WorkingDirectory` hits macOS TCC on `~/Documents/`

### Symptom

```
shell-init: error retrieving current directory: getcwd: cannot access parent directories: Operation not permitted
pwd: error retrieving current directory: getcwd: cannot access parent directories: Operation not permitted
```

…and the claude process then fails with a generic error.

### Cause

Even with Full Disk Access granted to `/bin/bash`, the plist's `<key>WorkingDirectory</key>` directive causes launchd to `chdir()` into the path BEFORE handing off to the user's shell. That pre-handoff `chdir` is subject to macOS TCC (Transparency, Consent, Control) on protected folders like `~/Documents/`, `~/Downloads/`, `~/Desktop/`. TCC silently blocks it.

### Fix

Omit `<key>WorkingDirectory</key>` from the plist entirely. Let launchd start the wrapper from `/`, and have the wrapper `cd` into the desired directory after it's running. The wrapper has FDA via its inherited process lineage and succeeds where launchd's pre-`chdir` fails.

---

## Blocker 5 : "Workspace not trusted"

### Symptom

```
Error: Workspace not trusted. Please run 'claude' in / first to review and accept the workspace trust dialog.
```

### Cause

`claude` maintains a list of "trusted workspaces" (directories where the user has previously consented to let claude run). Fresh directories aren't trusted. `/` (root) is never trusted.

When the wrapper starts from `/` (because you omitted `WorkingDirectory` per Blocker 4), claude refuses.

### Fix

The wrapper must `cd` to a previously-trusted directory (one where the user has run `claude` interactively before and accepted the trust dialog) BEFORE executing `claude remote-control`. Typical choice : the user's main project / working directory.

Chain with `|| exit 1` so a failed `cd` kills the wrapper and launchd surfaces the error cleanly :

```bash
cd "/Users/YOURNAME/Documents/Claude Code" || { echo "cd failed" >&2; exit 1; }
```

---

## Blocker 6 : launchd provides no TTY (the only non-obvious one)

### Symptom

After fixing all of Blockers 1-5, the plist still fails with :

```
error: An unknown error occurred (Unexpected)
```

…and when you run the EXACT SAME wrapper manually from a terminal with the EXACT SAME env, it works perfectly. Under launchd, silent exit.

### Cause

`claude remote-control` uses interactive terminal features (ANSI escape sequences for status UI, stdin-based hotkeys like "space to show QR"). Under launchd there is no controlling TTY. claude detects this and exits with the unhelpful generic error rather than a specific "no TTY" message.

### Fix

Wrap `claude remote-control` inside `tmux new-session -d` instead of invoking it directly. tmux provides a pseudo-TTY that claude is happy to run inside.

```bash
tmux new-session -d -s "command-centre" -c "/path/to/trusted/dir" \
    "claude remote-control --name 'Command Centre' 2>&1 | tee -a /path/to/log"
```

Launchd manages tmux's lifecycle via `KeepAlive=true` ; the wrapper script monitors the tmux session and exits non-zero if it dies, which triggers launchd to respawn the wrapper, which starts a fresh tmux session.

---

## Why these are undocumented

As of April 2026, Anthropic's Claude Code documentation covers `claude remote-control` as a command-line tool. It does not mention :

- Running it under launchd
- The long-lived token rejection
- Fd limit interaction
- The `USER` / `LOGNAME` / Keychain lookup dependency
- TCC on `WorkingDirectory`
- The workspace-trust requirement
- The TTY requirement

Community writeups as of the research date for this project covered adjacent topics (Happy Coder, Agent Bar, Tactic Remote, Claude-Code-Remote) but none the specific "always-on LaunchAgent + tmux" pattern.

This document and the accompanying installer close that gap.

## References

- [`claude` CLI documentation](https://docs.claude.com/en/docs/claude-code)
- `man launchd.plist` — `SoftResourceLimits`, `KeepAlive`, `ThrottleInterval`, `ProcessType`
- `man tmux` — `new-session -d`, `has-session`, detached TTY pattern
- [Apple TCC developer docs](https://developer.apple.com/documentation/devicemanagement/privacypreferencespolicycontrol)
