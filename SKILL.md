---
name: cmux-claude-monitor
description: Auto-approve Claude Code, OMC, and Codex confirmation prompts in cmux or any terminal (via tmux) using background polling scripts
category: devops
triggers:
  - "monitor cmux"
  - "auto-approve claude"
  - "watch pane"
  - "cmux yes"
  - "ghostty auto approve"
  - "tmux claude monitor"
  - "monitor ghostty"
---

# cmux Claude Code Auto-Approve Monitor (v9)

Background bash script that polls cmux panes running Claude Code/OMC/Codex and automatically presses Enter on confirmation prompts. Current version: v9 — **auto-detects all workspaces and surfaces** at startup, circuit breaker for per-pane failures, and **self-healing restart** when ALL panes experience socket degradation. v9 adds: if every pane fails for 3 consecutive cycles (6s), the monitor `exec`s itself to get a fresh cmux socket connection. v8 fixed the critical v7 bug where `detect_targets()` never parsed surface IDs from `cmux tree`.

## Quick Start

**CRITICAL: Never use `&` inside a foreground `terminal()` call.** The foreground shell exits when the `terminal()` call returns, and the kernel sends SIGHUP to all its children, killing your monitor silently. Deploy ONLY via Hermes `background=true` mode (no trailing `&`):

**cmux:**
```bash
# Hermes will call this with background=true — do NOT add &
bash scripts/monitor_cmux.sh   # from skill directory
# Or deploy to /tmp first:
cp scripts/monitor_cmux.sh /tmp/
bash /tmp/monitor_cmux.sh
```

**Ghostty / any terminal via tmux:**
```bash
# First, inside the terminal:  tmux new -s claude && claude
# Then from hermes (background=true, no &):
bash scripts/monitor_ghostty.sh claude
```

## How It Works

Claude Code confirmation prompts use a numbered menu:
```
 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don't ask again
   3. No
```

Since "1. Yes" is the default, pressing Enter auto-approves. The monitor:
1. **Auto-detects all workspaces and surfaces** at startup via `cmux list-workspaces` and `cmux tree` — no manual target configuration needed
2. Polls `timeout 5 cmux read-screen --lines 20` every 2 seconds per pane
3. Greps for trigger phrases (`do you want to proceed/make/…`, `❯.*[Yy]es`, etc.)
4. **Excludes permanent status-bar text** that looks like a prompt but isn't (e.g., OMC's `⏵⏵ accept edits on` status line — see Pitfalls)
5. Content-hashes the **full** read-screen output to avoid double-fire (**do NOT use `tail -6` — see Pitfalls**)
6. Enforces a 15-second cooldown per pane as defense-in-depth against hash collisions
7. Sends `Enter` via `cmux send-key`
8. **Circuit breaker**: if a pane fails 3 consecutive read-screen calls, stop polling it for 60s (prevents log spam and wasted cycles on stale panes). After 60s, auto-retry; success resets the breaker.
9. **Self-healing (v9)**: if ALL panes are dead for 3 consecutive polling cycles (no successful reads across any pane, ~6 seconds), the monitor `exec`s itself to obtain a fresh cmux socket connection. This handles the 22-hour socket degradation issue — the monitor detects total failure and restarts without human intervention. Per-pane failures (e.g., a closed workspace) are handled by the circuit breaker alone; self-healing only triggers on global socket failure. Full reproduction and verification in `references/cmux-socket-degradation.md`.

## OMC / Codex Considerations

OMC (OpenAI Model Computer) and Codex (OMX) share Claude Code's confirmation patterns, but add their own UI chrome that can cause false positives:

### Permanent Status Bar False Positive

OMC displays a permanent status line like `⏵⏵ accept edits on · N shells` in its bottom bar. This is a **mode indicator**, NOT a confirmation prompt. It appears continuously regardless of whether edits are pending. The grep pattern MUST exclude this — match only transient confirmation dialogs in the main content area, never the status bar.

### Feedback Dialog

OMC periodically shows a feedback prompt:
```
● How is Claude doing this session? (optional)
  1: Bad    2: Fine   3: Good   0: Dismiss
```
This intercepts keystrokes and must be auto-dismissed. Send `cmux send "0"` (not `send-key` — text characters use `send`, named keys use `send-key`) followed by `Enter` to dismiss and return to the actual prompt.

### Confirmation Patterns (Unknown)

OMC's actual edit-acceptance dialog pattern is not yet observed in the wild. When seen, add its trigger phrase to the monitor. Until then, the monitor handles standard Claude Code prompts only — OMC-specific confirmations may need manual approval.

## Deploying

**Always kill stale monitors first.** Multiple instances conflict silently — the old one holds the cmux socket, the new one gets broken-pipe errors on `read-screen`. The v9 script auto-detects all workspaces at startup and self-heals on global socket failure, so no manual intervention is needed after deployment.

```bash
# 1. Kill any existing monitors
pkill -f monitor_cmux.sh 2>/dev/null
sleep 1
# Verify no leftovers
ps aux | grep '[m]onitor_cmux'   # should be empty

# 2. Deploy (Hermes must use background=true, no &)
cp scripts/monitor_cmux.sh /tmp/
bash /tmp/monitor_cmux.sh    # Hermes must call with background=true, no &
```

After deploying, **wait 10s and verify**:

```bash
tail -30 /tmp/cmux_monitor.log | grep -E 'started|heartbeat|ENTER|FAILED|CIRCUIT'
```
All target panes should show heartbeat or activity. If only some appear, the monitor is partially degraded — kill and redeploy.

### Script Configuration

The v9 script auto-detects all workspaces and their focused surfaces at startup via `cmux list-workspaces` and `cmux tree`. No manual `TARGETS` configuration needed.

**To exclude a workspace**, add its name to the `EXCLUDE_NAMES` array at the top of the script:

```bash
# Workspace names to skip (e.g. the hermes agent pane itself, to avoid false positives)
EXCLUDE_NAMES=("hermes")
```

The script auto-handles:
- Claude Code confirmation prompts (Enter to approve default "Yes")
- OMC feedback dialog ("How is Claude doing?" → auto-dismiss with 0+Enter)
- OMC permanent status-bar exclusion (skips "accept edits on" mode indicator)

## Excluding Workspaces

To find workspace names:
```bash
cmux list-workspaces
# Output: workspace:1  projects, workspace:2  paper review, workspace:3  hermes
```

Add the name (case-sensitive) to `EXCLUDE_NAMES` in the script. The default excludes the hermes agent pane to prevent false positives from agent output text containing confirmation keywords like "proceed" or "confirm".

## Key cmux Commands

```
cmux list-workspaces                              # list all workspaces
cmux tree --workspace workspace:N                 # show pane/surface tree
cmux read-screen --workspace W --surface S --lines N  # read last N lines
cmux send-key --workspace W --surface S "Enter"       # press a key
cmux new-pane --workspace W --direction right          # open new terminal pane
```

## Ghostty / Any Terminal via tmux

When cmux is unusable (broken CLI) or the user is in a different terminal emulator like Ghostty, use tmux as the control intermediary. Ghostty is GPU-rendered and does NOT expose terminal text via Accessibility APIs — `osascript` keystrokes work but screen-reading does not.

### Setup (User Side)

```bash
# Inside Ghostty (or any terminal):
tmux new -s claude
claude    # run Claude Code inside tmux
```

### Deploy Monitor

```bash
# Start the tmux-based monitor (from hermes, background=true, no &)
bash /tmp/monitor_ghostty.sh claude
# Script path in skill: scripts/monitor_ghostty.sh
```

### How It Works

Same detection logic as the cmux monitor, but uses tmux commands:

| cmux command | tmux equivalent |
|---|---|
| `cmux read-screen --workspace W --surface S --lines N` | `tmux capture-pane -t SESSION -p -S -N` |
| `cmux send-key --workspace W --surface S "Enter"` | `tmux send-keys -t SESSION Enter` |
| `cmux list-workspaces` | `tmux list-sessions` |

The script polls every 3 seconds, detects the same Claude Code prompt patterns, uses MD5 hashing to prevent double-fire, and sends Enter.

### Ghostty-Specific Notes

- **AppleScript keystrokes work** — `osascript -e 'tell app "System Events" to tell process "Ghostty" to keystroke ...'` can send keys, but CANNOT read screen content (Ghostty renders with Metal, no accessibility text).
- **Window properties inaccessible** — `osascript -e 'tell app "Ghostty" to get bounds of window 1'` fails; Ghostty doesn't expose standard AppleScript window properties.
- **CGWindowList also blocked** — Quartz window enumeration is denied in hermes sandbox.
- **screencapture unavailable** — `screencapture -l` and `screencapture -C` both fail in the hermes environment (no display access).

**Bottom line**: tmux is the only reliable way to programmatically read screen + send keys in Ghostty.

### Verifying Monitor Health

After deploying, wait 10 seconds, then check:

```bash
# Confirm all panes are being polled
tail -20 /tmp/cmux_monitor.log | grep -E 'heartbeat|POLL OK|ENTER|FAILED|FEEDBACK'

# The startup log shows which workspaces were detected (and excluded)
tail -30 /tmp/cmux_monitor.log | grep -E 'detected|excluded|total targets'
```

### Quick Diagnostic When Approvals Stop Working

```bash
# 1. Check if monitor is alive
ps aux | grep '[m]onitor_cmux'

# 2. Check recent log activity
tail -30 /tmp/cmux_monitor.log

# 3. Look for circuit breaker events (partial degradation)
grep 'CIRCUIT BREAKER' /tmp/cmux_monitor.log | tail -5

# 4. Check for self-healing restarts (v9)
grep 'restarting monitor' /tmp/cmux_monitor.log | tail -3
# If present: socket degraded → v9 auto-restarted. Check current state with step 2.
# If absent but all panes show CIRCUIT BREAKER OPEN: v9 self-healing should trigger within ~6s.

# 5. ZOMBIE DETECTION: process alive but log stopped (ALL panes dead simultaneously)
#    Symptom: ps shows monitor running, but `tail -f /tmp/cmux_monitor.log` has no new
#    output for >2 minutes while no self-healing restart is logged.
#    Fix: kill <PID> and redeploy (v9 self-healing missed this edge case).
```

## Troubleshooting When CLI Is Broken

The cmux CLI can enter a state where **all commands return `Broken pipe (errno 32)`** even though the daemon is running and the socket exists. The socket itself may still respond to raw connections (e.g., `nc -U` returns "Access denied"), but the CLI cannot use it. Restarting cmux (`pkill cmux; open -a cmux`) does not always fix this — it's a cmux-level bug.

### Fallback 1: AppleScript Diagnostics

When the CLI is broken, cmux is still scriptable via AppleScript:

```bash
# Check if cmux is alive and what window is focused
osascript -e 'tell application "cmux" to get name of every window'

# Get window properties (includes selected tab)
osascript -e 'tell application "cmux" to get properties of window 1'

# Get selected tab and its focused terminal
osascript -e '
tell application "cmux"
  set t to selected tab of window 1
  get properties of t
  get properties of focused terminal of t
end tell'
```

AppleScript can read window/tab/terminal metadata (name, working directory, IDs) but CANNOT read terminal text content or send keystrokes.

### Fallback 2: Process-Tree Debugging

When you can't read the screen, inspect cmux's child processes to see what's running inside its terminals:

```bash
# Find cmux daemon PID
CMUX_PID=$(pgrep -f '/Applications/cmux.app/Contents/MacOS/cmux')

# See all child processes (including grandchildren via PPID)
ps -eo pid,ppid,stat,etime,command | awk -v p=$CMUX_PID '$2==p || $3==p'

# Find the login shell and its children
LOGIN_PID=$(ps -eo pid,ppid,command | awk -v p=$CMUX_PID '$3==p && /login/ {print $1}')
pgrep -P $LOGIN_PID
```

This reveals: stuck commands, git processes, Claude Code subprocesses — all without needing the cmux CLI. Use `ps -p <pid> -o pid,etime,stat,wchan,command` to check how long a process has been stuck and its wait channel.

### Fallback 3: Direct Process Kill

If a subprocess is stuck and you can't send Ctrl+C via cmux CLI, kill it directly:

```bash
# Kill stuck git/shell sub-processes (use -9 if -15 is ignored)
kill <pid>      # SIGTERM first
kill -9 <pid>   # SIGKILL if unresponsive
```

Claude Code may respawn killed processes if it still needs the information. If so, the root cause (e.g., Dropbox hang) must be addressed.

## Dropbox Git Hang

Git operations on repos inside Dropbox-synced directories can hang indefinitely. This manifests as git subprocesses under cmux that never complete, blocking Claude Code (no shell prompt appears).

**Detection:**
```bash
# Test if git is hanging on a Dropbox repo
timeout 5 git -C /path/to/repo status --porcelain
# Exit code 124 = timed out → git is stuck
```

**Pinpoint the file git is stuck on:**
```bash
lsof -p <git_pid> 2>/dev/null | grep 'REG.*CloudStorage'
# Shows which file git has open for reading (FD 3r on a large file = stuck)
```

**Affected repos on this machine:** `/Users/divinites/Library/CloudStorage/Dropbox/working/*`

**Temporary bandaid** — mark large tracked files as assume-unchanged so `git status` skips them:
```bash
git update-index --assume-unchanged path/to/large_file
```
Does NOT help if the 18 GB `.git/objects/pack/*.pack` file is locked by Dropbox (then even `git cat-file -t HEAD` hangs).

**Workaround:** Pause Dropbox sync before running git operations, or move repos out of Dropbox.

**Full diagnostic playbook:** `references/dropbox-git-hang.md`

## Pitfalls

- **Hermes pane false positives** — when the hermes agent terminal is monitored, its own response text often contains confirmation keywords ("proceed", "confirm", "make", etc.) in quoted or explanatory contexts, triggering spurious Enter presses. The v8 script excludes the hermes workspace by default via `EXCLUDE_NAMES=("hermes")`. If you need to monitor the hermes pane (e.g., for debugging), remove "hermes" from the exclusion list, but expect occasional false approvals.
- **NEVER use `&` in a foreground `terminal()` call** — the `terminal()` shell exits when the call returns, and the kernel SIGHUPs all children, killing your monitor silently. The process table may still show stale PIDs for a few seconds, but the while-loop is dead. Deploy ONLY with Hermes `background=true` and no trailing `&`. If in doubt, verify: `ps aux | grep '[m]onitor_cmux'` should show exactly one `bash` process with high cumulative CPU time (it accumulates 1-2s per minute from polling). A freshly-started monitor showing 0:00.00 CPU after 10 seconds is dead.
- **`pgrep -f monitor_cmux` self-matches** — the pattern `monitor_cmux` appears in its own command line, so `pgrep` always returns at least one PID. Use `ps aux | grep '[m]onitor_cmux'` (the `[m]` bracket trick prevents grep from matching itself) and check with `awk '{print $2}'` for PIDs.
- **Don't use `declare -A`** — the user's bash doesn't support associative arrays well; use plain variables with if/else per pane
- **Claude Code sends "1" not "y"** for numbered menus, but **Enter** is simplest since option 1 is default
- **Content hashing prevents double-fire** — but only if done correctly. Hash the **full `read-screen` output**, never `tail -6`. The bottom 6 lines are identical across different Claude Code prompts (same numbered-menu chrome), causing collisions that block legitimate new prompts. With a correct full-screen hash, the same prompt won't fire twice; with a 15s cooldown, even a hash collision won't cause rapid re-approval.
- **Check the `cmux` path** — it's at `/Applications/cmux.app/Contents/Resources/bin/cmux`, typically in PATH
- **`read-screen` captures only visible lines** — use `--lines 12` or more to ensure the full prompt is captured
- **`send` types text character by character** — use `send-key "Enter"` for the final newline; don't `send "\n"`
- **Broken pipe is not fixable by restart alone** — if cmux CLI returns `Broken pipe (errno 32)`, don't loop restarting. Tried: `kill -9` + `rm cmux.sock` + `open -a cmux` (fresh daemon still broken), removing session JSON files, full state wipe — none fix it. It's a cmux daemon bug. Use AppleScript + process-tree fallbacks instead and tell the user to restart cmux from the GUI when convenient.
- **Dropbox breaks git** — repos under `~/Library/CloudStorage/Dropbox/` can cause git commands (status, branch, rev-parse) to hang silently for minutes. Pause Dropbox or move the repo.
- **Never put a working git repo in Dropbox** — use the bare-repo architecture instead: working tree on local disk, bare remote in Dropbox, data symlinked back. Full migration playbook in `references/dropbox-git-hang.md`.
- **Dropbox dataless files block `mv`** — moving a repo OUT of Dropbox hangs because `mv` must read every file to copy across filesystem boundaries. Make the folder "available offline" in Finder first. No CLI can force-download these files.
- **Multiple monitor instances conflict silently** — if a stale monitor is already running, a new one can't read screens (socket contention), but `2>/dev/null` on the `read-screen` call hides the error. The log will show "Starting monitor" but no approvals. Symptom: confirmation prompt is visible via manual `cmux read-screen` but never gets auto-approved. Fix: `pkill -f monitor_cmux.sh`, manually approve the stuck prompt, then restart. Always `pgrep -af monitor_cmux` before deploying.
- **Don't trust the log alone** — the monitor logs "Starting monitor" on every launch but does NOT log read-screen failures (broken pipe, socket errors swallowed by `2>/dev/null`). To verify it's actually polling: after deploying, wait 4 seconds, then check with `cmux read-screen --workspace W --surface S --lines 12` on each pane manually. If that command works but the log still has no "Enter" lines after a minute with an active prompt, the monitor is blind.
- **CRITICAL: `tail -6 | md5` produces hash collisions** — Claude Code's confirmation UI chrome (the numbered `❯ 1. Yes / 2. … / 3. No` menu) is identical across different prompts. "Do you want to proceed" (bash command) and "Do you want to make this edit" produce the same `tail -6` hash because the bottom 6 lines are just the menu. The dedup then blocks the second prompt forever — it matches, dedup says "already seen," and skips Enter. Fix: **hash the FULL `read-screen` output** (not `tail -6`) and **add a 15-second cooldown** per pane as defense-in-depth. The cooldown prevents rapid re-approval even if a hash somehow collides.
- **Grep must include `make`** — Claude Code uses "Do you want to make this edit" for edit confirmations. The regex must include `(proceed|continue|run|execute|confirm|apply|make)`. Missing verbs silently skip prompts.
- **Monitor log shows MATCH but no ENTER → hash dedup is blocking** — the prompt was detected but dedup killed it. This is the smoking gun for a `tail -6` collision. Check: the log will show repeated MATCH lines with the same hash but no ENTER. Fix: upgrade to v2 (full-screen hash + cooldown).
- **Permanent status-bar text causes false positives** — OMC (and similar tools) display a permanent status bar like `⏵⏵ accept edits on · N shells`. This is NOT a confirmation prompt — it's a mode indicator that appears continuously. If the grep matches this, the monitor will spam Enter every 15 seconds to no effect. Fix: after the regex match, check if the matching line contains `accept edits on` and skip it. The v4 script in `scripts/monitor_cmux.sh` includes this exclusion.
- **Feedback dialogs intercept keystrokes** — OMC occasionally shows `● How is Claude doing this session? (optional)` with options 1-3 and 0 to dismiss. Enter presses go to this dialog instead of the real prompt. The v4 script auto-detects and dismisses this dialog with `cmux send "0"` + Enter.
- **`cmux send-key` vs `cmux send`** — `send-key` only accepts named keys (Enter, Escape, Tab, etc.). Use `cmux send "0"` (no `-key`) to type literal text characters. Sending `send-key "0"` returns `Error: invalid_params: Unknown key`.
- **Stale monitors silently degrade** — a monitor that has been running for days can partially fail: `cmux read-screen` starts returning rc=1 for SOME panes while others keep working. The socket state degrades gradually. The log fills with FAILED spam every 2s but the dying panes get no approvals. The v6 circuit breaker auto-detects this (3 consecutive failures → skip pane for 60s) and logs `CIRCUIT BREAKER OPEN`. If this affects ALL panes, v9 self-healing triggers an automatic restart. For partial degradation (some panes healthy), the circuit breaker keeps log spam contained; manually kill and restart if the dead panes are critical. **Always verify all panes are polling after deploying** — wait 10s, check `tail -20 /tmp/cmux_monitor.log | grep 'heartbeat\\|POLL OK'` for entries from all panes.
- **Long-running monitor eventually dies wholesale (all panes simultaneously)** — after ~20-24 hours of continuous operation, cmux socket degradation can hit ALL panes at once: every `read-screen` returns rc=1, the circuit breaker opens for every pane, and the log stops producing output entirely (no heartbeats, no FAILED lines) while the bash process still shows up in `ps`. This is a silent zombie — the process is alive but producing zero observable work. **Symptom**: `ps aux | grep '[m]onitor_cmux'` shows the process with non-zero cumulative CPU, but `tail -f /tmp/cmux_monitor.log` shows no new entries for minutes. **v9 self-healing**: when all panes are dead for 3 consecutive cycles (~6s), the monitor `exec`s itself, obtaining a fresh cmux socket connection. This handles the 22-hour degradation automatically — no cron job or manual restart needed. If self-healing somehow fails (e.g., cmux daemon itself is broken), fall back to: `kill <PID>`, then redeploy.
- **Stale TARGETS (pre-v7 only)** — v6 and earlier hardcoded workspace IDs which go stale when workspaces are added, removed, or reordered. v7 replaces this with auto-detection at startup. If you see old monitors cycling `FAILED rc=1` → `CIRCUIT BREAKER OPEN` with no heartbeats, the TARGETS are stale. Upgrade to v7, or manually update TARGETS with `cmux list-workspaces` + `cmux tree`.
- **Log file grows unbounded** — the /tmp/cmux_monitor.log gets appended by every monitor instance. Over weeks it can reach 8MB+. Large log files can slow down `>>` appends. Periodically truncate: `echo "=== truncated $(date) ===" > /tmp/cmux_monitor.log`. The v6 script respects existing content (uses `>>`), so truncation after killing the old monitor is safe.
- **Circuit breaker thresholds** — 3 consecutive failures trigger a 60s breaker. This means a transient read-screen failure (like cmux daemon restart) causes at most 3 FAILED log lines, then the pane is skipped for 60s before auto-retry. If the underlying issue (cmux broken pipe bug) is permanent, the breaker cycles: open 60s → retry (fail) → open 60s. Each cycle produces 1 FAILED + 1 OPEN line. This is manageable log volume vs. the old behavior (2 lines/s indefinitely).
- **v7 `detect_targets()` missing surface parsing (FIXED in v8)** — v7 introduced auto-detection of workspaces but the `cmux tree` surface-parsing code was accidentally omitted: the `$sfs` variable was never populated before the `for sf in $sfs` loop, so non-excluded workspaces silently produced 0 targets and the monitor exited with "FATAL: no workspaces found". Symptom: `total targets: 0` in the log despite `cmux list-workspaces` showing multiple workspaces. v8 fix adds `local sfs=$(cmux tree --workspace "$ws" 2>&1 | grep -oE 'surface:[0-9]+' | sort -t: -k2 -n | uniq)` immediately before the for loop.
