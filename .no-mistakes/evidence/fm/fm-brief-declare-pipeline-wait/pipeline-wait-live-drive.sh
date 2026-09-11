#!/usr/bin/env bash
# Live end-to-end drive of the declared-pipeline-wait obligation added to the
# generated no-mistakes ship brief.
#
#   1. Firstmate scaffolds a real no-mistakes brief with bin/fm-brief.sh.
#   2. A REAL tmux window (private socket) runs a long silent command, standing
#      in for the blocking `no-mistakes axi run` the brief talks about.
#   3. The REAL supervision watcher (bin/fm-watch.sh) polls that window.
#
#   Arm A - the worker ignores the brief: the pane is silent, the watcher
#           escalates a "possible wedge" stale wake (the reported false alarm).
#   Arm B - the worker follows the brief's new sentence and declares the wait
#           first: the same silent pane is absorbed, no wake, no wedge timer.
set -u

ROOT=${ROOT_OVERRIDE:-/home/dev/.no-mistakes/worktrees/222d8f0053d8/01M27HAWF6CY9TFRCFQW86P6T0}
. "$ROOT/tests/wake-helpers.sh"

file_mtime() { stat -c %Y "$1" 2>/dev/null; }
wait_poll_cycle() {  # <state> <pid> [limit]
  local state=$1 pid=$2 limit=${3:-300} beat first now i=0
  beat="$state/.last-watcher-beat"; rm -f "$beat"; first=""
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    first=$(file_mtime "$beat"); [ -n "$first" ] && break
    sleep 0.1; i=$((i + 1))
  done
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(file_mtime "$beat")
    [ -n "$now" ] && [ "$now" != "$first" ] && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}
# SIGTERM, never SIGKILL: fm-watch.sh traps TERM and runs its recovery-state
# cleanup on the way out. A killed -9 watcher leaves a pending downtime marker,
# and the next watcher then wakes on "check: rearm-resurface" before it ever
# reaches the stale scan this drive is about.
reap() {
  local pid=$1 i=0
  kill "$pid" 2>/dev/null || true
  while [ "$i" -lt 50 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}
# Acknowledge whatever the watcher left in the durable wake queue, so the next
# round starts from a clean queue instead of re-surfacing the previous one.
ack_stopped_cycle() {  # <state>
  local state=$1 err sequence generation
  err="$state/.ack.err"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$sequence" \
    --recovery-generation "$generation"
}
seen_sig_of() { stat -c '%s:%Y' "$1" 2>/dev/null; }

TMP_ROOT=$(fm_test_tmproot fm-pipeline-wait-live)
RUN="$TMP_ROOT/run"; mkdir -p "$RUN/data" "$RUN/worktree"
REAL_TMUX=$(command -v tmux) || { echo "no tmux"; exit 1; }
SOCKET="fm-pipewait-live-$$"
SHIM="$RUN/shim"; mkdir -p "$SHIM"
cat > "$SHIM/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM/tmux"
make_fake_crew_state "$SHIM" >/dev/null   # hermetic crew-state read: no live no-mistakes daemon here
PATH="$SHIM:$PATH"; export PATH
cleanup() { "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "### 1. firstmate scaffolds the no-mistakes brief"
FM_HOME="$RUN" "$ROOT/bin/fm-brief.sh" pipe-demo acme-app --mode no-mistakes
BRIEF="$RUN/data/pipe-demo/brief.md"
echo
echo "--- the sentence the crewmate reads in its brief:"
grep -F 'Before every pipeline call' "$BRIEF"
VERB=$(sed -n 's/.*append `\([a-z-]*\): {which call you are waiting on}`.*/\1/p' "$BRIEF")
echo "--- declared-external-wait verb the brief rendered: $VERB"
echo
echo "### 2. one real tmux server, one live silent pane per arm"
tmux new-session -d -s fmlive -x 200 -y 50

# setup_arm <arm> -> echoes state dir; window runs a real long silent command.
setup_arm() {  # <arm>
  local arm=$1 state win
  state="$RUN/$arm-state"; mkdir -p "$state"
  win="fmlive:fm-$arm"
  tmux new-window -t fmlive -n "fm-$arm"
  tmux send-keys -t "$win" 'clear; printf "> no-mistakes axi run --intent ...\n"; sleep 900' Enter
  printf 'window=%s\nkind=ship\nharness=pi\nworktree=%s\n' "$win" "$RUN/worktree" > "$state/$arm.meta"
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$arm")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$arm" busy --gen "$gen" \
    --source pi-ext --event agent-start >/dev/null
  printf '%s\n' "$state"
}

start_watch() {  # <state> <out> <stale-escalate-secs>
  FM_STATE_OVERRIDE="$1" FM_CREW_STATE_BIN="$SHIM/fm-crew-state.sh" \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS="$3" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" > "$2" &
  WPID=$!
}

export FM_FAKE_CREW_STATE='state: unknown · source: none · no run attributed to this crew'

# ---------------------------------------------------------------- Arm A ------
echo
echo "### ARM A - the worker never declares the wait"
A=$(setup_arm armA); AWIN="fmlive:fm-armA"; AKEY=$(printf '%s' "$AWIN" | tr ':/.' '___')
sleep 1
echo "--- live pane the watcher is looking at:"
tmux capture-pane -p -t "$AWIN" | grep -v '^[[:space:]]*$' | sed 's/^/    /'
printf 'working: handed the change to no-mistakes\n' > "$A/armA.status"
echo "--- status log:"; sed 's/^/    /' "$A/armA.status"
printf '%s' "$(seen_sig_of "$A/armA.status")" > "$A/.seen-armA_status"
touch -t 200001010000 "$A/armA.meta"     # no completed turn for a long stretch
outA="$RUN/watchA.out"
start_watch "$A" "$outA" 999
wait_poll_cycle "$A" "$WPID" || echo "    (watcher exited during first cycle)"
echo "    wedge timer started on first sight: $([ -s "$A/.stale-since-$AKEY" ] && echo yes || echo no)"
reap "$WPID"
ack_stopped_cycle "$A" >/dev/null 2>&1 || true
echo "$(( $(date +%s) - 500 ))" > "$A/.stale-since-$AKEY"   # the silence keeps going
: > "$outA"
start_watch "$A" "$outA" 240
wait_for_exit "$WPID" 150 >/dev/null 2>&1 || true
reap "$WPID"
echo "--- what supervision does with the undeclared silence:"
sed 's/^/    /' "$outA"

# ---------------------------------------------------------------- Arm B ------
echo
echo "### ARM B - the worker obeys the brief and declares the wait first"
B=$(setup_arm armB); BWIN="fmlive:fm-armB"; BKEY=$(printf '%s' "$BWIN" | tr ':/.' '___')
sleep 1
echo "--- live pane the watcher is looking at:"
tmux capture-pane -p -t "$BWIN" | grep -v '^[[:space:]]*$' | sed 's/^/    /'
printf 'working: handed the change to no-mistakes\n' > "$B/armB.status"
printf '%s: no-mistakes axi run, waiting for the pipeline to return\n' "$VERB" >> "$B/armB.status"
echo "--- status log (last line written per the brief's instruction):"
sed 's/^/    /' "$B/armB.status"
printf '%s' "$(seen_sig_of "$B/armB.status")" > "$B/.seen-armB_status"
touch -t 200001010000 "$B/armB.meta"
export FM_FAKE_CREW_STATE="state: $VERB · source: status-log · waiting for the pipeline to return"
outB="$RUN/watchB.out"
start_watch "$B" "$outB" 240
if wait_poll_cycle "$B" "$WPID"; then alive=yes; else alive=no; fi
echo "    watcher completed a full poll and kept supervising: $alive"
echo "    wedge timer started: $([ -s "$B/.stale-since-$BKEY" ] && echo yes || echo no)"
echo "    wake queued for firstmate: $([ -s "$B/.wake-queue" ] && echo yes || echo no)"
# Keep the silence going past the same wedge threshold that escalated arm A.
echo "$(( $(date +%s) - 500 ))" > "$B/.stale-since-$BKEY"
wait_poll_cycle "$B" "$WPID" >/dev/null 2>&1 || true
wait_poll_cycle "$B" "$WPID" >/dev/null 2>&1 || true
echo "    after a further 500s of silence, watcher still supervising: $(kill -0 "$WPID" 2>/dev/null && echo yes || echo no)"
echo "    wake queued for firstmate: $([ -s "$B/.wake-queue" ] && echo yes || echo no)"
reap "$WPID"
echo "--- what supervision does with the declared wait (empty = firstmate never woken):"
sed 's/^/    /' "$outB"

# ---------------------------------------------------------------- Arm C ------
# The repeat shape: the first declared wait does NOT cover the resume call. A
# returning gate makes the worker append needs-decision:, which replaces the
# declared wait as the last status line. The brief says "before EVERY pipeline
# call ... or a `respond` that resumes one", so the worker must declare again.
echo
echo "### ARM C - gate returned, decision answered, worker now blocks on the resume call"
C=$(setup_arm armC); CWIN="fmlive:fm-armC"; CKEY=$(printf '%s' "$CWIN" | tr ':/.' '___')
sleep 1
{ printf '%s: no-mistakes axi run, waiting for the pipeline to return\n' "$VERB"
  printf 'needs-decision: ask-user gate on the review finding, options A or B\n'; } > "$C/armC.status"
echo "--- status log after the gate returned:"; sed 's/^/    /' "$C/armC.status"
printf '%s' "$(seen_sig_of "$C/armC.status")" > "$C/.seen-armC_status"
touch -t 200001010000 "$C/armC.meta"
export FM_FAKE_CREW_STATE='state: parked · source: status-log · ask-user gate open'
outC="$RUN/watchC.out"
echo "--- C1: firstmate answered, the worker blocks on the resume call WITHOUT re-declaring"
start_watch "$C" "$outC" 999
wait_poll_cycle "$C" "$WPID" || echo "    (watcher exited during first cycle)"
echo "    wedge timer started (the earlier declaration no longer covers it): $([ -s "$C/.stale-since-$CKEY" ] && echo yes || echo no)"
reap "$WPID"
ack_stopped_cycle "$C" >/dev/null 2>&1 || true
echo "$(( $(date +%s) - 500 ))" > "$C/.stale-since-$CKEY"
: > "$outC"
start_watch "$C" "$outC" 240
wait_for_exit "$WPID" 150 >/dev/null 2>&1 || true
reap "$WPID"
echo "    supervision:"; sed 's/^/      /' "$outC"
ack_stopped_cycle "$C" >/dev/null 2>&1 || true

echo "--- C2: same pane, worker re-declares before the resume call as the brief requires"
rm -f "$C/.stale-$CKEY" "$C/.stale-since-$CKEY" "$C/.wedge-escalations-$CKEY" \
      "$C/.paused-$CKEY" "$C/.paused-rechecked-$CKEY" "$C/.paused-resurfaced-$CKEY"
printf '%s: no-mistakes axi respond, resuming the run with the decision\n' "$VERB" >> "$C/armC.status"
sed 's/^/    /' "$C/armC.status"
printf '%s' "$(seen_sig_of "$C/armC.status")" > "$C/.seen-armC_status"
export FM_FAKE_CREW_STATE="state: $VERB · source: status-log · resuming the run with the decision"
: > "$outC"
start_watch "$C" "$outC" 240
if wait_poll_cycle "$C" "$WPID"; then aliveC=yes; else aliveC=no; fi
echo "    watcher completed a full poll and kept supervising: $aliveC"
echo "    wedge timer started: $([ -s "$C/.stale-since-$CKEY" ] && echo yes || echo no)"
echo "    supervision output (empty = firstmate never woken): [$(cat "$outC")]"
reap "$WPID"
echo "[end]"

