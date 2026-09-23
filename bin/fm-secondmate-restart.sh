#!/usr/bin/env bash
# Restart second mates onto the current instruction surface and launch-time
# wiring, persisting their open records first.
#
# Usage: fm-secondmate-restart.sh <secondmate-id>... [--help]
#
# This is the executable half of /updatefirstmate's reload step. A running agent
# holds AGENTS.md and every skill it has loaded frozen from launch, and no
# verified harness offers a reload, so a re-read steer cannot replace either -
# it appends a second copy of the mate's own job description with no defined
# precedence. Replacing the agent is the only mechanism that guarantees the new
# bytes are the ones read, and the only one that re-resolves the launch-time
# wiring - harness, model, effort, turn-end hooks, and every other flag a harness
# reads once at startup. That second half is why the update pass sends every live
# mate here, including one whose HOME was already on the target commit: whether
# the running AGENT is on it is a different question, answered by the staleness
# read below from what that agent's own session recorded when it started.
#
# The cost of that guarantee is the conversation, so nothing is spent on a mate
# that does not need it. Before anything else, each mate's staleness is read
# (bin/fm-secondmate-health.sh stale): a mate whose running session recorded the
# instruction surface its home is on now is reported `current` and left alone.
# A stale mate, or one whose launch revision cannot be proven, goes on through
# two phases, the first of which is a GATE, not a courtesy:
#
#   A. PERSIST. Every mate is asked, in one marked request, to durably record the
#      open work it holds only in conversation - a task for each unfiled open
#      record, including a captain call it formed but never registered, and a
#      status correction for each task whose recorded state is now stale. That is
#      the /stow skill's "Open-record persistence" contract and nothing else from
#      it: no memory, learnings, or captain-preference sweep, which would make
#      every instruction update cost far more than the reload it is paying for.
#      All requests go out before any restart, so a slow mate delays only its own
#      restart instead of serializing the fleet behind it.
#   B. RESTART. Only after that mate's own correlated answer lands on the parent
#      channel. The gate is that answer, never a wall clock, so a mate that is
#      mid-turn queues the request behind that turn; the bound below exists to
#      end the wait, not to authorize a restart without the answer. A timeout
#      deliberately leaves that unanswered expectation open: it is a genuine
#      open loop owned by the ordinary pending-reply recovery ladder, not state
#      this restart pass may close.
#      After the answer, the mate's busy state is read (fm-secondmate-health.sh
#      idle). A provably busy mate is never restarted: it is reported
#      `deferred` and keeps running untouched, and a later staleness read - the
#      next update pass or the primary's check before that home's next
#      dispatch - picks it up again. Only a proven idle verdict permits restart.
#      Unknown, unreadable, and remote-unknown states defer with a re-read nudge.
#      Containment was approved by firstmate on 2026-09-23 pending follow-up
#      task fm-secondmate-busy-state-arming. Deferral is expected for every
#      local mate needing a restart until secondmate busy records are armed.
#   C. VERIFY. A relaunch is reported `restarted` only after
#      fm-secondmate-health.sh verify proves the replacement's agent alive, the
#      home lock held by a new live session, and that session reporting the
#      intended instruction surface. Anything less - including a lock collision
#      with the previous session - is reported as an unknown outcome.
#
# A mate whose persist answer did not arrive or whose runtime cannot prove a
# restart gets the ordinary re-read nudge and is reported as a nudge, never as a
# clean reload. Once a relaunch is attempted, any failed or ambiguous result is
# reported as unknown rather than attributing it to either incarnation.
#
# Local mates restart through bin/fm-control.sh <id> relaunch. Remote mates
# receive persistence requests and re-read nudges over their host transport;
# their unknown idle state defers restart.
#
# Nothing here forces, stashes, or discards anything. bin/fm-control.sh owns the
# restart transaction, its checkpoint, its journal, and its rollback; a refusal
# before the agent is stopped leaves the mate running exactly as it was.
#
# Restart candidacy itself belongs to bin/fm-update.sh, which knows which homes
# the update pass actually left on the target commit; this command re-checks
# capability on its own argv rather than trusting a caller's list.
#
# Environment knobs:
#   FM_SECONDMATE_PERSIST_WAIT  seconds to wait for one mate's persist answer (900)
#   FM_SECONDMATE_PERSIST_POLL  seconds between checks of that answer (5)
#   FM_SECONDMATE_VERIFY_WAIT and FM_SECONDMATE_VERIFY_POLL bound the
#   replacement verification (bin/fm-secondmate-health.sh owns them).
#
# Per-mate lines: `current:`, `restarted: <id> (<harness>) while idle`,
# `deferred:`, `nudged:`, or `unreached:`, then one `summary:` line.
#
# Exit status: 0 every named mate restarted or was already current; 3 at least
# one was deferred, nudged, or left unreached and every mate was still accounted
# for; 1 the input itself is unusable; 2 invalid use.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  sed -n '2,${/^#/!q;s/^# \{0,1\}//;p;}' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') usage >&2; exit 2 ;;
esac

if [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-secondmate-restart refuses to resolve second mates without an explicit firstmate home" >&2
  exit 1
fi
[ -d "$FM_HOME" ] || { echo "error: FM_HOME '$FM_HOME' is not a directory" >&2; exit 1; }
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
[ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing; fm-secondmate-restart cannot resolve second mates for FM_HOME '$FM_HOME'" >&2; exit 1; }

# shellcheck source=bin/fm-secondmate-restart-lib.sh
. "$SCRIPT_DIR/fm-secondmate-restart-lib.sh"
# shellcheck source=bin/fm-secondmate-nudge-lib.sh
. "$SCRIPT_DIR/fm-secondmate-nudge-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"

PERSIST_WAIT=${FM_SECONDMATE_PERSIST_WAIT:-900}
PERSIST_POLL=${FM_SECONDMATE_PERSIST_POLL:-5}
case "$PERSIST_WAIT" in ''|*[!0-9]*) echo "error: FM_SECONDMATE_PERSIST_WAIT must be a non-negative integer: $PERSIST_WAIT" >&2; exit 2 ;; esac
case "$PERSIST_POLL" in ''|*[!0-9]*|0) echo "error: FM_SECONDMATE_PERSIST_POLL must be a positive integer: $PERSIST_POLL" >&2; exit 2 ;; esac

IDS=()
for arg in "$@"; do
  case "$arg" in
    -*) echo "error: unexpected argument '$arg'" >&2; usage >&2; exit 2 ;;
  esac
  # /updatefirstmate's action line names each mate by its fm-<id> selector; the
  # bare id is equally acceptable so a hand-run stays natural.
  id=${arg#fm-}
  case "$id" in ''|*[!A-Za-z0-9._-]*) echo "error: invalid second mate id: $arg" >&2; exit 2 ;; esac
  case " ${IDS[*]:-} " in
    *" $id "*) continue ;;
  esac
  IDS+=("$id")
done
[ "${#IDS[@]}" -gt 0 ] || { usage >&2; exit 2; }

# Per-mate pass state, kept as parallel indexed arrays so this stays bash-3.2
# safe. PLAN is the phase the mate reached: persist-sent, or fallback with the
# reason already decided.
PLAN=()
REASON=()
CORR=()
DEADLINE=()
HARNESS=()
RESTART_PID=()
RESTART_RESULT=()
PRIOR_PID=()
EXPECT_INSTR=()

restarted_count=0
current_count=0
deferred_count=0
nudged_count=0
unreached_count=0

# The first line of a command's output that carries anything, flattened to one
# readable line with its "error: " prefix dropped. A refusal's own words are the
# most useful thing this report can carry, and its first line is often blank.
first_reported_line() {  # <text>
  printf '%s\n' "$1" | sed -n '/./{s/^error: //;s/[[:space:]]\{1,\}/ /g;p;q;}'
}

# Send the ordinary re-read steer to a mate this pass will not restart, and say
# plainly which it was. A nudge is a partial reload and is never reported as more.
fall_back_to_nudge() {  # <id> <reason>
  local id=$1 reason=$2 out
  if out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-send.sh" "$id" "$FM_SECOND_MATE_NUDGE_MESSAGE" 2>&1); then
    nudged_count=$((nudged_count + 1))
    printf 'nudged: %s: %s\n' "$id" "$reason"
  else
    unreached_count=$((unreached_count + 1))
    printf 'unreached: %s: %s; the re-read message could not be delivered either: %s\n' \
      "$id" "$reason" "$(first_reported_line "$out")"
  fi
}

report_unreached() {  # <id> <reason>
  unreached_count=$((unreached_count + 1))
  printf 'unreached: %s: %s\n' "$1" "$2"
}

restart_mate() {  # <array-index>
  local i=$1 id restart_out restart_rc restart_reason ran_on verify_out
  id=${IDS[$i]}
  restart_out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-control.sh" "$id" relaunch 2>&1)
  restart_rc=$?
  if [ "$restart_rc" -eq 0 ]; then
    ran_on=$(printf '%s\n' "$restart_out" | sed -n 's/^relaunched .* harness=\([^ ]*\).*/\1/p' | tail -1)
    [ -n "$ran_on" ] || ran_on=${HARNESS[i]}
    if ! verify_out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/fm-secondmate-health.sh" verify "$id" \
      ${PRIOR_PID[i]:+--prior-pid "${PRIOR_PID[i]}"} \
      --expect-instr "${EXPECT_INSTR[i]}" 2>&1); then
      restart_reason=$(first_reported_line "$verify_out")
      restart_reason=${restart_reason#"unknown $id: "}
      report_unreached "$id" "the restart outcome is unknown: it was relaunched, but the replacement was not verified healthy: ${restart_reason:-no reason reported}"
      return
    fi
    printf 'restarted: %s (%s) while idle; %s\n' "$id" "$ran_on" \
      "$(first_reported_line "$verify_out")"
    return
  fi

  restart_reason=$(first_reported_line "$restart_out")
  [ -n "$restart_reason" ] || restart_reason="the restart failed without a reported reason"
  report_unreached "$id" "the restart outcome is unknown: $restart_reason"
}

launch_restart() {  # <array-index>
  local i=$1 result tmp
  result="$RESULT_DIR/$i.result"
  tmp="$result.tmp"
  ( trap - EXIT; restart_mate "$i" > "$tmp"; mv -f "$tmp" "$result" ) &
  RESTART_PID[i]=$!
  RESTART_RESULT[i]=$result
  PLAN[i]=restarting
  restart_active_count=$((restart_active_count + 1))
}

restart_if_idle() {  # <array-index>
  local i=$1 verdict
  verdict=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-secondmate-health.sh" idle "${IDS[$i]}" 2>/dev/null | head -1) || verdict=""
  [ -n "$verdict" ] || verdict="unknown unreadable"
  case "${verdict%% *}" in
    busy)
      deferred_count=$((deferred_count + 1))
      printf 'deferred: %s: busy (%s), so it was not restarted; its open work is written down and it keeps running until a later pass finds it idle\n' \
        "${IDS[$i]}" "${verdict#* }"
      PLAN[i]="done"
      ;;
    dead)
      report_unreached "${IDS[$i]}" "its endpoint is gone (${verdict#* }), so there is no agent to restart; startup recovery owns it"
      PLAN[i]="done"
      ;;
    idle) launch_restart "$i" ;;
    *)
      deferred_count=$((deferred_count + 1))
      printf 'deferred: %s: idle not provable (%s), so it was not restarted\n' "${IDS[$i]}" "${verdict#* }"
      fall_back_to_nudge "${IDS[$i]}" "idle not provable (${verdict#* })"
      PLAN[i]="done"
      ;;
  esac
}

harvest_restarts() {
  local i out worker_state
  i=0
  while [ "$i" -lt "${#IDS[@]}" ]; do
    if [ "${PLAN[i]}" != restarting ]; then
      i=$((i + 1))
      continue
    fi
    if [ -f "${RESTART_RESULT[i]}" ]; then
      wait "${RESTART_PID[i]}" 2>/dev/null || true
      out=$(cat "${RESTART_RESULT[i]}")
    else
      if kill -0 "${RESTART_PID[i]}" 2>/dev/null; then
        worker_state=$(ps -p "${RESTART_PID[i]}" -o stat= 2>/dev/null || true)
        case "$worker_state" in
          Z*) ;;
          *)
            i=$((i + 1))
            continue
            ;;
        esac
      fi
      wait "${RESTART_PID[i]}" 2>/dev/null || true
      if [ -f "${RESTART_RESULT[i]}" ]; then
        out=$(cat "${RESTART_RESULT[i]}")
      else
        out="unreached: ${IDS[$i]}: the restart worker exited before publishing an outcome"
      fi
    fi
    printf '%s\n' "$out"
    case "$out" in
      restarted:*)
        restarted_count=$((restarted_count + 1))
        ;;
      nudged:*) nudged_count=$((nudged_count + 1)) ;;
      *) unreached_count=$((unreached_count + 1)) ;;
    esac
    PLAN[i]="done"
    restart_active_count=$((restart_active_count - 1))
    i=$((i + 1))
  done
}

# --- phase A: persist ------------------------------------------------------
# Every request goes out before any restart, so the fleet persists concurrently
# and one busy mate delays only itself.

i=0
while [ "$i" -lt "${#IDS[@]}" ]; do
  id=${IDS[$i]}
  PLAN[i]="fallback"
  REASON[i]=""
  CORR[i]=""
  DEADLINE[i]=""
  HARNESS[i]=""
  PRIOR_PID[i]=""
  EXPECT_INSTR[i]=""
  # Staleness first: a mate already running its home's current instruction
  # surface has nothing to gain from spending its conversation.
  stale_out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-secondmate-health.sh" stale "$id" 2>/dev/null) || stale_out=""
  case "$stale_out" in
    "current $id "*)
      PLAN[i]="current"
      REASON[i]="already running its home's current instructions (${stale_out#current "$id" }); nothing to restart"
      i=$((i + 1))
      continue
      ;;
  esac
  PRIOR_PID[i]=$(printf '%s\n' "$stale_out" | sed -n 's/.* lock_pid=\([0-9]*\) head_instr=.*/\1/p')
  EXPECT_INSTR[i]=$(printf '%s\n' "$stale_out" | sed -n 's/.* head_instr=\([^ ]*\)$/\1/p')
  if ! fm_secondmate_restart_capable "$STATE/$id.meta"; then
    REASON[i]=$FM_SECONDMATE_RESTART_REASON
    i=$((i + 1))
    continue
  fi
  if [ -z "${EXPECT_INSTR[i]}" ]; then
    REASON[i]="the intended instruction identity could not be read, so it was not restarted"
    i=$((i + 1))
    continue
  fi
  HARNESS[i]=$FM_SECONDMATE_RESTART_HARNESS

  if ! corr=$(fm_pending_reply_create "$FM_HOME" "$STATE" "$id" \
    "$FM_SECONDMATE_PERSIST_REQUEST"); then
    REASON[i]="its answer about the open work cannot be tracked, so a clean reload could not be proven"
    i=$((i + 1))
    continue
  fi
  if ! send_out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    FM_PENDING_REPLY_EXISTING_CORR="$corr" \
    "$SCRIPT_DIR/fm-send.sh" "$id" "$FM_SECONDMATE_PERSIST_REQUEST" 2>&1); then
    fm_pending_reply_discard_undelivered "$STATE" "$corr" >/dev/null 2>&1 || true
    REASON[i]="the request to write down its open work could not be delivered: $(first_reported_line "$send_out")"
    i=$((i + 1))
    continue
  fi
  CORR[i]=$corr
  DEADLINE[i]=$(($(date +%s) + PERSIST_WAIT))
  PLAN[i]="persisted-pending"
  i=$((i + 1))
done

# --- phase B: restart ------------------------------------------------------

RESULT_DIR=$(mktemp -d "$STATE/.secondmate-restart.XXXXXX") || {
  echo "error: could not create restart result directory under $STATE" >&2
  exit 1
}
trap 'rm -rf -- "$RESULT_DIR"' EXIT
pending_count=0
restart_active_count=0
i=0
while [ "$i" -lt "${#IDS[@]}" ]; do
  if [ "${PLAN[i]}" = persisted-pending ]; then
    pending_count=$((pending_count + 1))
  elif [ "${PLAN[i]}" = current ]; then
    current_count=$((current_count + 1))
    printf 'current: %s: %s\n' "${IDS[$i]}" "${REASON[i]}"
    PLAN[i]="done"
  else
    fall_back_to_nudge "${IDS[$i]}" "${REASON[i]}"
    PLAN[i]="done"
  fi
  i=$((i + 1))
done

while [ "$((pending_count + restart_active_count))" -gt 0 ]; do
  now=$(date +%s)
  next_wait=$PERSIST_POLL
  # Resolve every arrived answer before processing any timeout. Delivery of a
  # later fleet request can outlast an earlier mate's deadline under load; that
  # expired mate must not hold an already-confirmed mate behind its fallback.
  i=0
  while [ "$i" -lt "${#IDS[@]}" ]; do
    if [ "${PLAN[i]}" = persisted-pending ] \
      && fm_pending_reply_try_resolve "$STATE" "${CORR[i]}"; then
      pending_count=$((pending_count - 1))
      restart_if_idle "$i"
    fi
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "${#IDS[@]}" ]; do
    if [ "${PLAN[i]}" != persisted-pending ]; then
      i=$((i + 1))
      continue
    fi
    if [ "$now" -ge "${DEADLINE[i]}" ]; then
      # A reply can land after the fleet-wide resolution pass. Recheck at the
      # timeout decision so an answer already on disk wins over the fallback.
      if fm_pending_reply_try_resolve "$STATE" "${CORR[i]}"; then
        pending_count=$((pending_count - 1))
        restart_if_idle "$i"
      else
        fall_back_to_nudge "${IDS[$i]}" \
          "it did not confirm within ${PERSIST_WAIT}s that its open work is written down, so its conversation was not spent"
        PLAN[i]="done"
        pending_count=$((pending_count - 1))
      fi
    else
      remaining=$((DEADLINE[i] - now))
      [ "$remaining" -ge "$next_wait" ] || next_wait=$remaining
    fi
    i=$((i + 1))
  done
  harvest_restarts
  [ "$((pending_count + restart_active_count))" -eq 0 ] || sleep "$next_wait"
done

# --- summary ---------------------------------------------------------------

if [ "$deferred_count" -eq "${#IDS[@]}" ]; then
  printf 'summary: all %d mates deferred; %d received re-read nudges, %d were unreached, and none were reloaded.\n' \
    "$deferred_count" "$nudged_count" "$unreached_count"
else
  printf 'summary: %d of %d restarted while idle, %d already current, %d deferred, %d nudged, %d unreached\n' \
    "$restarted_count" "${#IDS[@]}" "$current_count" "$deferred_count" \
    "$nudged_count" "$unreached_count"
fi
[ "$((deferred_count + nudged_count + unreached_count))" -eq 0 ] || exit 3
exit 0
