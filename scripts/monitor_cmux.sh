#!/bin/bash
# cmux OMC/Claude Code auto-approve monitor v8
# v8: fix missing cmux tree surface parsing in detect_targets (v7 bug: $sfs never set)
# v6: circuit breaker + feedback dedup + read-screen timeout
# v5: circuit breaker for read-screen failures
# v4: feedback dedup + status-bar exclusion + full-screen hash
LOG="/tmp/cmux_monitor.log"
echo "=== Monitor PID=$$ started $(date) ===" >> "$LOG"

# Workspace names to exclude from monitoring (case-sensitive substrings)
# Default: exclude the hermes agent pane to avoid false positives from agent
# text containing confirmation keywords like "proceed" or "confirm".
EXCLUDE_NAMES=("hermes")

# ----- Auto-detect all workspaces and surfaces -----
detect_targets() {
  TARGET_WS=() TARGET_SF=()
  local ws_ids=$(cmux list-workspaces 2>&1 | grep -oE 'workspace:[0-9]+' | sort -t: -k2 -n | uniq)
  for ws in $ws_ids; do
    local ws_num=${ws#workspace:}
    # Get workspace name for exclusion check
    local ws_name=$(cmux list-workspaces 2>&1 | grep "^[ *]*$ws " | sed "s/^[ *]*$ws  //" | sed 's/ \[selected\]$//')

    # Check exclusion list
    local excluded=0
    for ex in "${EXCLUDE_NAMES[@]}"; do
      [[ "$ws_name" == *"$ex"* ]] && excluded=1 && break
    done
    if [ "$excluded" -eq 1 ]; then
      echo "[$(date '+%H:%M:%S')] excluded workspace:$ws_num ($ws_name)" >> "$LOG"
      continue
    fi

    # Get surface IDs from cmux tree
    local sfs=$(cmux tree --workspace "$ws" 2>&1 | grep -oE 'surface:[0-9]+' | sort -t: -k2 -n | uniq)
    for sf in $sfs; do
      TARGET_WS+=("${ws#workspace:}")
      TARGET_SF+=("${sf#surface:}")
      echo "[$(date '+%H:%M:%S')] detected workspace:${ws#workspace:} surface:${sf#surface:}" >> "$LOG"
    done
  done
  echo "[$(date '+%H:%M:%S')] total targets: ${#TARGET_WS[@]}" >> "$LOG"
}

detect_targets
TARGET_COUNT=${#TARGET_WS[@]}
if [ "$TARGET_COUNT" -eq 0 ]; then
  echo "[$(date '+%H:%M:%S')] FATAL: no workspaces found" >> "$LOG"
  exit 1
fi

poll_count=0
global_fail_streak=0   # consecutive cycles where all panes failed or were breaker-skipped
any_success=0          # set to 1 if any pane had a successful read

while true; do
  now=$(date +%s)
  poll_count=$((poll_count+1))
  any_success=0

  for ((i=0; i<TARGET_COUNT; i++)); do
    ws_num=${TARGET_WS[$i]}
    sf_num=${TARGET_SF[$i]}
    key="w${ws_num}s${sf_num}"

    # ---- Circuit breaker ----
    eval "bt=\$breaker_ts_${key}"
    bt=${bt:-0}
    if [ "$bt" != "0" ] && [ $(( now - bt )) -lt 60 ]; then
      continue  # breaker open: skip
    fi

    # ---- Read screen ----
    screen=$(timeout 5 cmux read-screen --workspace "workspace:$ws_num" --surface "surface:$sf_num" --lines 20 2>&1)
    rc=$?

    if [ $rc -ne 0 ]; then
      eval "fc=\$fail_cnt_${key}"
      fc=${fc:-0}
      fc=$(( fc + 1 ))
      eval "fail_cnt_${key}=$fc"
      echo "[$(date '+%H:%M:%S')] w${ws_num}s${sf_num} FAILED rc=$rc (fail#$fc)" >> "$LOG"
      if [ $fc -ge 3 ]; then
        eval "breaker_ts_${key}=$now"
        echo "[$(date '+%H:%M:%S')] w${ws_num}s${sf_num} CIRCUIT BREAKER OPEN" | tee -a "$LOG"
      fi
      continue
    fi

    # ---- Reset failure / breaker on success ----
    any_success=1
    eval "fail_cnt_${key}=0"
    eval "breaker_ts_${key}=0"

    # Heartbeat: every ~60s
    if [ $(( poll_count % 30 )) -eq 0 ]; then
      echo "[$(date '+%H:%M:%S')] w${ws_num}s${sf_num} heartbeat (${#screen} chars)" >> "$LOG"
    fi

    # ---- Check 1: "How is Claude doing?" feedback -> dismiss ----
    if echo "$screen" | grep -q "How is Claude doing this session"; then
      h=$(echo "$screen" | md5 2>/dev/null)
      skip=0
      eval "lh=\$last_fb_hash_${key}"; eval "lt=\$last_fb_time_${key}"
      lh=${lh:-}; lt=${lt:-0}
      [ "$h" = "$lh" ] && [ $(( now - lt )) -lt 30 ] && skip=1
      if [ $skip -eq 0 ]; then
        eval "last_fb_hash_${key}=\"$h\""; eval "last_fb_time_${key}=$now"
        echo "[$(date '+%H:%M:%S')] w${ws_num}s${sf_num} FEEDBACK -> dismiss" | tee -a "$LOG"
        cmux send --workspace "workspace:$ws_num" --surface "surface:$sf_num" "0" 2>&1 >> "$LOG"
        sleep 0.5
        cmux send-key --workspace "workspace:$ws_num" --surface "surface:$sf_num" "Enter" 2>&1 >> "$LOG"
      fi
      continue
    fi

    # ---- Check 2: Real confirmation prompts (not status bar) ----
    # Matches Claude Code (❯ 1. Yes), Codex (› 1. Yes, proceed), and common patterns
    if echo "$screen" | grep -qiE '(do you want to (proceed|continue|run|execute|confirm|apply|make)|would you like to|proceed\?|continue\?|yes/no|\[y/n\]|\(y/n\)|accept\?|approve\?|confirm\?|[❯›].*[Yy]es|press enter to confirm)' 2>/dev/null; then
      match_line=$(echo "$screen" | grep -inE '(do you want to (proceed|continue|run|execute|confirm|apply|make)|would you like to|proceed\?|continue\?|yes/no|\[y/n\]|\(y/n\)|accept\?|approve\?|confirm\?|[❯›].*[Yy]es|press enter to confirm)' 2>/dev/null | head -1)
      if echo "$match_line" | grep -q "accept edits on"; then
        continue  # skip OMC status bar
      fi

      h=$(echo "$screen" | md5 2>/dev/null)

      # Hash dedup + 15s cooldown
      eval "lh=\$last_hash_${key}"; eval "le=\$last_enter_${key}"
      lh=${lh:-}; le=${le:-0}
      [ "$h" = "$lh" ] && continue
      [ $(( now - le )) -lt 15 ] && continue
      eval "last_hash_${key}=\"$h\""; eval "last_enter_${key}=$now"

      echo "[$(date '+%H:%M:%S')] w${ws_num}s${sf_num} >>> ENTER <<< $match_line" | tee -a "$LOG"
      cmux send-key --workspace "workspace:$ws_num" --surface "surface:$sf_num" "Enter" 2>&1 >> "$LOG"
    fi
  done

  # ---- Self-healing ----
  if [ "$any_success" -eq 0 ]; then
    # Path 1: ALL panes dead → restart to get fresh socket
    global_fail_streak=$(( global_fail_streak + 1 ))
    if [ $global_fail_streak -ge 3 ]; then
      echo "[$(date '+%H:%M:%S')] ALL panes dead for ${global_fail_streak} cycles (${TARGET_COUNT} targets) — restarting monitor" | tee -a "$LOG"
      exec bash "$0"
    fi
  else
    global_fail_streak=0
    # Path 2: Check for stale workspaces (single pane failing too long)
    for ((i=0; i<TARGET_COUNT; i++)); do
      key="w${TARGET_WS[$i]}s${TARGET_SF[$i]}"
      eval "fc=\$fail_cnt_${key}"
      fc=${fc:-0}
      if [ $fc -ge 15 ]; then
        echo "[$(date '+%H:%M:%S')] w${TARGET_WS[$i]}s${TARGET_SF[$i]} stale (fail_cnt=$fc) — re-detecting targets" >> "$LOG"
        detect_targets
        TARGET_COUNT=${#TARGET_WS[@]}
        # Reset all per-pane state
        for ((j=0; j<TARGET_COUNT; j++)); do
          k2="w${TARGET_WS[$j]}s${TARGET_SF[$j]}"
          eval "fail_cnt_${k2}=0"
          eval "breaker_ts_${k2}=0"
          eval "last_hash_${k2}="
          eval "last_enter_${k2}=0"
          eval "last_fb_hash_${k2}="
          eval "last_fb_time_${k2}=0"
        done
        break  # Only re-detect once per cycle
      fi
    done
  fi

  sleep 2
done
