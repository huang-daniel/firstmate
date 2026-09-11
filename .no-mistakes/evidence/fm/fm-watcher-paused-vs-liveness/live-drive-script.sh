#!/usr/bin/env bash
# Live drive of bin/fm-watch.sh against a REAL tmux server and the REAL
# bin/fm-crew-state.sh reader. No fakes: the pane, its agent process, the agent's
# death, and the reconciliation are all real.
set -u

LIVE=/tmp/fm-live-drive
REPO=${REPO:-/home/dev/.no-mistakes/worktrees/222d8f0053d8/01M27CV9REEVN3RGN81X1QZ2QZ}
WATCH="$REPO/bin/fm-watch.sh"
DRAIN="$REPO/bin/fm-wake-drain.sh"
export TMUX_TMPDIR="$LIVE/tmuxsock"
WIN=fmlive:fm-wait
KEY=fmlive_fm-wait
S="$LIVE/state"
FAILED=0

say() {
  printf '\n=== %s\n' "$*"
  local n; n=$(wc -l < "$S/.watch-triage.log" 2>/dev/null) || n=0
  printf '%s\t%s\n' "${n:-0}" "$*" >> "$LIVE/triage-marks.tsv"
}
ok()  { printf '  PASS  %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; FAILED=1; }

agent_pid() {
  local tty; tty=$(tmux display-message -p -t "$WIN" '#{pane_tty}' 2>/dev/null) || return 1
  ps -t "${tty#/dev/}" -o pid=,comm= | awk '$2=="grok"{print $1; exit}'
}
probe_liveness() {
  ( cd "$REPO" && bash -c '. bin/fm-backend.sh; printf "%s" "$(fm_backend_agent_state tmux '"$WIN"')"' )
}
crew_state() { ( cd "$REPO" && FM_STATE_OVERRIDE="$S" bash bin/fm-crew-state.sh wait ); }

start_watch() {  # [extra env assignments]
  : > "$LIVE/watch.out"
  rm -f "$S/.last-watcher-beat"
  env FM_STATE_OVERRIDE="$S" FM_ROOT_OVERRIDE="$LIVE/root" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_PAUSE_RESURFACE_SECS="${PAUSE_SECS:-999}" "$@" \
    bash "$WATCH" > "$LIVE/watch.out" 2>"$LIVE/watch.err" &
  WPID=$!
}
# wait for <n> completed poll cycles; return 1 if the watcher exited first
wait_cycles() {  # <n>
  local want=$1 seen=0 prev="" now i=0
  while [ "$i" -lt 400 ]; do
    kill -0 "$WPID" 2>/dev/null || return 1
    now=$(stat -c %Y "$S/.last-watcher-beat" 2>/dev/null || true)
    if [ -n "$now" ] && [ "$now" != "$prev" ]; then
      [ -n "$prev" ] && seen=$((seen+1))
      prev=$now
      [ "$seen" -ge "$want" ] && return 0
    fi
    sleep 0.1; i=$((i+1))
  done
  return 2
}
wait_exit() {
  local i=0
  while [ "$i" -lt 150 ]; do
    kill -0 "$WPID" 2>/dev/null || { wait "$WPID"; return $?; }
    sleep 0.1; i=$((i+1))
  done
  kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; return 124
}
reap() { kill "$WPID" 2>/dev/null || true; wait "$WPID" 2>/dev/null || true; }
ack() {
  local err="$S/.ack.err" seq gen
  FM_STATE_OVERRIDE="$S" "$DRAIN" >/dev/null 2>"$err" || true
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$gen" ] || return 0
  FM_STATE_OVERRIDE="$S" "$DRAIN" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
}
stale_wakes() {  # [bare]
  [ -s "$S/.wake-queue" ] || { printf '0'; return; }
  awk -F '\t' -v w="$WIN" -v mode="${1:-all}" '
    $3=="stale" && $4==w { if (mode!="bare" || $5=="stale: " w) n++ } END{print n+0}' \
    "$S/.wake-queue" 2>/dev/null
}
prime_seen() {
  printf '%s' "$(stat -c '%s:%Y' "$S/wait.status")" > "$S/.seen-wait_status"
}

# ---------------------------------------------------------------- fixture ---
rm -rf "$S" "$LIVE/root"; mkdir -p "$S" "$LIVE/root"
: > "$LIVE/triage-marks.tsv"
cat > "$S/wait.meta" <<EOF
window=$WIN
kind=ship
harness=grok
backend=tmux
worktree=$LIVE/wt
branch=fm/live-wait
EOF
printf 'paused: waiting on the validation run to return the next gate\n' > "$S/wait.status"
prime_seen

tmux kill-server 2>/dev/null || true
tmux new-session -d -s fmlive -n fm-wait -x 120 -y 40 \
  "printf 'waiting on the validation run to return the next gate\n'; $LIVE/bin/grok --norc --noprofile -c 'trap \"exit 0\" USR1; while :; do read -r -t 3600 _ || true; done'; PS1= exec /bin/bash --norc --noprofile -i"
sleep 1
printf 'real tmux window: %s\n' "$(tmux list-windows -t fmlive -F '#{session_name}:#{window_name} cmd=#{pane_current_command}')"
printf 'declared status line: %s\n' "$(cat "$S/wait.status")"
printf 'reconciled current state: %s' "$(crew_state)"
printf 'pane capture:\n'; tmux capture-pane -p -t "$WIN" | sed -n '1,3p' | sed 's/^/  | /'

# ------------------------------------------------ S1 live paused absorbed ---
say "S1  live declared pause on a real pane is absorbed, not raised as stale"
printf 'agent liveness probe: %s\n' "$(probe_liveness)"
start_watch
if wait_cycles 3; then
  [ ! -s "$LIVE/watch.out" ] && ok "no wake printed over 3 polls" || bad "printed: $(cat "$LIVE/watch.out")"
  [ "$(stale_wakes)" -eq 0 ] && ok "no stale wake queued" || bad "queued $(stale_wakes) stale wakes"
  grep -qF "absorbed stale (paused, awaiting external" "$S/.watch-triage.log" \
    && ok "triage log records a bounded external wait" || bad "triage log missing the external-wait absorb"
  [ -e "$S/.paused-$KEY" ] && ok "pause cadence engaged" || bad "pause cadence flag missing"
  [ ! -e "$S/.stale-since-$KEY" ] && ok "no wedge timer started" || bad "a wedge timer was started"
else
  bad "watcher exited on a live declared pause: $(cat "$LIVE/watch.out")"
fi
reap; ack
ALIVE_CAP=$(tmux capture-pane -p -t "$WIN")

# ------------------------------------------- S2 exit on unchanged capture ---
say "S2  the agent dies behind the same pane text; the exit must surface once"
kill -USR1 "$(agent_pid)"; sleep 1.2
DEAD_CAP=$(tmux capture-pane -p -t "$WIN")
[ "$ALIVE_CAP" = "$DEAD_CAP" ] && ok "pane capture is byte-identical across the death" \
  || bad "pane capture changed across the death"
printf 'agent liveness probe: %s\n' "$(probe_liveness)"
printf 'reconciled current state: %s' "$(crew_state)"
start_watch
if wait_exit; then :; fi
if grep -qF "stale: $WIN" "$LIVE/watch.out"; then ok "watcher surfaced: $(head -1 "$LIVE/watch.out")"; else bad "no stale wake printed: $(cat "$LIVE/watch.out")"; fi
grep -qF "awaiting external" "$LIVE/watch.out" && bad "the exit was dressed as a live external wait" \
  || ok "the surfaced wake does not claim a live external wait"
[ "$(stale_wakes)" -eq 1 ] && ok "exactly 1 stale wake queued" || bad "queued $(stale_wakes) stale wakes"
[ "$(stale_wakes bare)" -eq 1 ] && ok "queued wake is the bare wedge-grade 'stale: <window>'" || bad "queued wake is not bare"
cp "$S/.wake-queue" "$LIVE/queued-exit-wake.tsv" 2>/dev/null || true
ack

# --------------------------------------------------- S3 one-shot bounded ---
say "S3  the same dead pane must not re-surface on later polls"
for r in 1 2 3; do
  start_watch
  if wait_cycles 2; then
    [ ! -s "$LIVE/watch.out" ] && ok "round $r silent" || bad "round $r printed: $(cat "$LIVE/watch.out")"
  else
    bad "round $r re-surfaced: $(cat "$LIVE/watch.out")"
  fi
  reap; ack
done
[ "$(stale_wakes)" -eq 0 ] && ok "no further stale wakes queued" || bad "re-queued $(stale_wakes) stale wakes"
grep -qF "absorbed stale (agent exited under a declared pause" "$S/.watch-triage.log" \
  && ok "triage log records the absorb as an exit" || bad "triage log does not record the absorb as an exit"

# ------------------------------------- S4 inconclusive read must not rearm ---
say "S4  a supervisor poking the abandoned pane must not re-report the exit"
tmux send-keys -t "$WIN" "$LIVE/bin/myprocess --norc --noprofile -c 'trap \"exit 0\" USR1; while :; do read -r -t 3600 _ || true; done'" Enter
sleep 1
printf 'agent liveness probe while poked: %s\n' "$(probe_liveness)"
start_watch
if wait_cycles 3; then
  [ ! -s "$LIVE/watch.out" ] && ok "inconclusive read stayed silent" || bad "printed: $(cat "$LIVE/watch.out")"
else
  bad "inconclusive read surfaced a wake: $(cat "$LIVE/watch.out")"
fi
reap; ack
POKE=$(ps -t "$(tmux display-message -p -t "$WIN" '#{pane_tty}' | sed 's#/dev/##')" -o pid=,comm= | awk '$2=="myprocess"{print $1; exit}')
kill -USR1 "$POKE"; sleep 1.2
printf 'agent liveness probe after the poke ends: %s\n' "$(probe_liveness)"
start_watch
if wait_cycles 3; then
  [ ! -s "$LIVE/watch.out" ] && ok "already-reported exit stayed silent after the poke" || bad "printed: $(cat "$LIVE/watch.out")"
  [ "$(stale_wakes)" -eq 0 ] && ok "no stale wake re-queued after the poke" || bad "re-queued $(stale_wakes)"
else
  bad "the exit re-surfaced after an inconclusive read: $(cat "$LIVE/watch.out")"
fi
reap; ack

# ----------------------------------------------- S5 relaunch then re-exit ---
say "S5  a relaunched crew is absorbed again, and its NEXT exit surfaces afresh"
tmux send-keys -t "$WIN" "$LIVE/bin/grok --norc --noprofile -c 'trap \"exit 0\" USR1; while :; do read -r -t 3600 _ || true; done'" Enter
sleep 1
printf 'agent liveness probe after relaunch: %s\n' "$(probe_liveness)"
start_watch
if wait_cycles 4; then
  [ ! -s "$LIVE/watch.out" ] && ok "relaunched crew absorbed, no wake" || bad "printed: $(cat "$LIVE/watch.out")"
else
  bad "relaunched live crew surfaced: $(cat "$LIVE/watch.out")"
fi
reap; ack
kill -USR1 "$(agent_pid)"; sleep 1.2
printf 'agent liveness probe after the second death: %s\n' "$(probe_liveness)"
start_watch
wait_exit || true
grep -qF "stale: $WIN" "$LIVE/watch.out" && ok "second exit surfaced: $(head -1 "$LIVE/watch.out")" \
  || bad "second exit never surfaced: $(cat "$LIVE/watch.out")"
[ "$(stale_wakes bare)" -eq 1 ] && ok "exactly one bare stale wake for the second exit" || bad "queued $(stale_wakes bare) bare wakes"
ack

# ------------------------------------------- S6 exited recheck wording ------
say "S6  past the long cadence the recheck says the worker has stopped"
back=$(( $(date +%s) - 1200 ))
touch -d "@$back" "$S/wait.status" "$S/.paused-resurfaced-$KEY" 2>/dev/null
prime_seen
PAUSE_SECS=240 start_watch
wait_exit || true
grep -qF "agent exited" "$LIVE/watch.out" && ok "recheck reports the worker has stopped: $(head -1 "$LIVE/watch.out")" \
  || bad "recheck did not report an exit: $(cat "$LIVE/watch.out")"
grep -qF "awaiting external" "$LIVE/watch.out" && bad "recheck claimed a live external wait" \
  || ok "recheck does not claim a live external wait"
cp "$S/.wake-queue" "$LIVE/queued-exit-recheck-wake.tsv" 2>/dev/null || true
ack

# ------------------------------- S7 a rejected queue append keeps the exit ---
say "S7  an exit whose wake the queue rejects must still surface on the next poll"
cp "$S/.watch-triage.log" "$LIVE/watch-triage.log" 2>/dev/null || true
cp "$S/.wake-queue" "$LIVE/wake-queue.tsv" 2>/dev/null || true
rm -rf "$S"; mkdir -p "$S"
cat > "$S/wait.meta" <<EOF
window=$WIN
kind=ship
harness=grok
backend=tmux
worktree=$LIVE/wt
branch=fm/live-wait
EOF
printf 'paused: waiting on the validation run to return the next gate\n' > "$S/wait.status"
prime_seen
: > "$S/.wake-queue"; chmod 0444 "$S/.wake-queue"
printf 'agent liveness probe: %s\n' "$(probe_liveness)"
start_watch
wait_exit; rc=$?
chmod 0644 "$S/.wake-queue"
[ "$rc" -ne 124 ] && ok "watcher stopped after its wake append was rejected (exit $rc)" || bad "watcher never stopped on the rejected append"
[ "$rc" -ne 0 ] && ok "the rejected append was not reported as a delivered wake" || bad "reported a delivered wake the queue rejected"
[ ! -s "$S/.wake-queue" ] && ok "nothing was recorded in the queue" || bad "a rejected append still recorded a wake"
ack
start_watch
wait_exit || true
grep -qF "stale: $WIN" "$LIVE/watch.out" && ok "the exit surfaced on the next poll: $(head -1 "$LIVE/watch.out")" \
  || bad "the exit was silenced for good after a rejected append: $(cat "$LIVE/watch.out")"
[ "$(stale_wakes bare)" -eq 1 ] && ok "exactly one bare stale wake queued on the retry" || bad "queued $(stale_wakes bare) bare wakes"
ack

# ------------------------ S8 a lifted declaration re-arms the exit one-shot ---
say "S8  lifting the declaration re-arms the one-shot, so a later exit surfaces again"
rm -rf "$S"; mkdir -p "$S"
cat > "$S/wait.meta" <<EOF
window=$WIN
kind=ship
harness=grok
backend=tmux
worktree=$LIVE/wt
branch=fm/live-wait
EOF
printf 'paused: waiting on the validation run to return the next gate\n' > "$S/wait.status"
prime_seen
printf 'agent liveness probe: %s\n' "$(probe_liveness)"
start_watch; wait_exit || true
grep -qF "stale: $WIN" "$LIVE/watch.out" && ok "the exit surfaced once and armed the one-shot" || bad "the exit never surfaced: $(cat "$LIVE/watch.out")"
ack
start_watch
if wait_cycles 2; then [ ! -s "$LIVE/watch.out" ] && ok "one-shot holds: the next poll is silent" || bad "printed: $(cat "$LIVE/watch.out")"; else bad "re-surfaced: $(cat "$LIVE/watch.out")"; fi
reap; ack
printf 'working: picked the task back up, the external wait is over\n' >> "$S/wait.status"
prime_seen
printf 'status log now ends: %s\n' "$(tail -1 "$S/wait.status")"
start_watch; wait_exit || true
grep -qF "stale: $WIN" "$LIVE/watch.out" && ok "the lifted declaration surfaces as an ordinary stale" || bad "no ordinary stale after the lift: $(cat "$LIVE/watch.out")"
ack
printf 'paused: waiting on a second external call\n' >> "$S/wait.status"
prime_seen
printf 'status log now ends: %s\n' "$(tail -1 "$S/wait.status")"
start_watch; wait_exit || true
grep -qF "stale: $WIN" "$LIVE/watch.out" && ok "the still-dead worker surfaces again under the new declaration: $(head -1 "$LIVE/watch.out")" \
  || bad "the lift left the exit permanently silenced: $(cat "$LIVE/watch.out")"
ack

printf '\n==== live drive %s ====\n' "$([ "$FAILED" -eq 0 ] && echo PASSED || echo FAILED)"
tmux kill-server 2>/dev/null || true
exit "$FAILED"
