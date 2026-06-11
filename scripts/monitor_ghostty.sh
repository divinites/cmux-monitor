#!/bin/bash
# Auto-approve Claude Code prompts in Ghostty (or any terminal) via tmux
# v2: full-screen hash, 15s cooldown, broader grep, error logging
# Requires: tmux session with Claude Code running
#
# Usage: bash monitor_ghostty.sh [session_name]

SESSION="${1:-claude}"
LOG="/tmp/ghostty_monitor.log"
echo "=== Monitor PID=$$ starting at $(date) for tmux session: $SESSION ===" | tee -a "$LOG"

last_hash=""
last_enter=0

while true; do
  # Check if tmux session exists
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    sleep 3
    continue
  fi

  # Capture last 15 lines of the pane
  screen=$(tmux capture-pane -t "$SESSION" -p -S -15 2>&1)
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "[$(date '+%H:%M:%S')] capture-pane FAILED rc=$rc: $(echo "$screen" | head -1)" >> "$LOG"
    sleep 3
    continue
  fi

  # Check for Claude Code confirmation prompts
  if echo "$screen" | grep -qiE '(do you want to (proceed|continue|run|execute|confirm|apply|make)|proceed\?|continue\?|yes/no|\[y/n\]|\(y/n\)|accept\?|approve\?|❯.*[Yy]es)' 2>/dev/null; then
    # Hash FULL screen to avoid collisions from identical menu chrome
    h=$(echo "$screen" | md5 2>/dev/null || echo "$screen" | shasum -a 256 | cut -d' ' -f1)
    now=$(date +%s)

    # Dedup by hash AND 15s cooldown
    if [ "$h" = "$last_hash" ]; then
      continue
    fi
    if [ $(( now - last_enter )) -lt 15 ]; then
      continue
    fi

    last_hash="$h"
    last_enter=$now
    echo "[$(date '+%H:%M:%S')] Detected prompt → sending Enter" | tee -a "$LOG"
    tmux send-keys -t "$SESSION" Enter 2>&1 >> "$LOG"
  fi

  sleep 3
done
