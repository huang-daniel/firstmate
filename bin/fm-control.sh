#!/usr/bin/env bash
# fm-control.sh - the CONTROL PLANE for a firstmate-owned agent: allowlisted
# lifecycle verbs addressed to an exact task id.
#
# Usage: fm-control.sh <task-id> interrupt
#        fm-control.sh <task-id> exit
#        fm-control.sh <task-id> stand-down
#        fm-control.sh <task-id> relaunch [--harness <name>] [--model <name>]
#                                         [--effort <level>] [--require-idle]
#                                         (--note <text> | --note-file <path>)
#        fm-control.sh <task-id> compact
#
# Why this exists, and how it differs from fm-send.sh. bin/fm-send.sh is the
# DATA plane: conversational text for the agent to read, always routing-marked
# for a kind=secondmate target so the reply returns through the status path.
# That marking is right for a message and wrong for a lifecycle command - a
# marked "/quit" arrives as ordinary chat the agent reasons ABOUT instead of
# executing. This script is the control plane: semantic process control with a
# closed verb list, per-harness mechanics owned by an executable adapter
# (bin/fm-control-lib.sh) rather than improvised in agent prose, and a verified
# postcondition for every action. There is deliberately NO arbitrary-text and
# NO generic raw-key entry point here; fm-send remains the only way to send an
# agent something to read.
#
#   interrupt  Deliver the harness's verified interrupt sequence. The agent
#              keeps running. Postcondition: delivery succeeded, the endpoint
#              still exists, and the agent is still alive where the backend can
#              classify that. Cancellation is confirmed only from an adapter-
#              owned acknowledgement and otherwise reported unconfirmed. Busy
#              state is never rewritten as proof of the action.
#   exit       Stop the agent, preserving its terminal endpoint, worktree, and
#              every uncommitted change. Interrupts first when the task reads
#              busy, then submits the harness's exit command. Postcondition:
#              the backend's recovery-grade classifier reports the agent gone.
#              Already-stopped is success (idempotent). An endpoint that reads
#              `missing` is put through the control plane's per-backend absence
#              proof (fm_control_endpoint_absence_verdict) before anything is
#              claimed about it, because `missing` also covers an endpoint that
#              is merely unreachable from this seat. Proof from backend reads
#              exists only on HERDR, whose reads are scoped to the recorded session:
#              proven gone reports `endpoint-gone` rather than
#              `already-stopped`, because the endpoint this verb normally
#              preserves did not survive; a pane that turns out to be there and
#              idle is the ordinary `already-stopped`; one whose agent is back
#              takes the ordinary interrupt-then-exit path. A tmux `missing`
#              refuses unless the stand-down marker proves closure (see below):
#              a task record carries no socket identity for its
#              endpoint, so this verb cannot tell a destroyed window from one on
#              a tmux server it cannot address, and it will not claim a stop it
#              cannot see.
#   stand-down Stand a finished ship worker down: stop its agent exactly as
#              `exit` does, then CLOSE its terminal endpoint so a task held for
#              a merge word does not leave a blank shell behind. Everything
#              else is preserved: the worktree, the task record, the status
#              log, the steering inbox, and the merge poll. Allowed only from
#              the done state with the recorded PR present, and refused before
#              anything is touched otherwise:
#                - kind=ship on a no-mistakes or direct-PR delivery path, with
#                  a recorded pr=;
#                - the status log's current declaration is `done` (an open
#                  decision or blocker, or any later event, refuses);
#                - bin/fm-crew-state.sh reads `done` - so an active validation
#                  run, which it reads as working or parked, always refuses; a
#                  direct-PR task whose agent is already stopped may instead
#                  read `unknown`, since it has no run to attribute;
#                - the worktree has no uncommitted or untracked changes, and
#                  its HEAD is on a remote-tracking branch or is the recorded
#                  pr_head - re-checked after the agent stops and before the
#                  close.
#              Only tmux and herdr are supported (the backends whose agent
#              state is recovery-grade); every other backend refuses and keeps
#              its endpoint. The close goes through bin/fm-backend.sh's
#              fm_backend_close_task_endpoint, the backend's own focus-safe
#              path, and is confirmed by the agent-state classifier reading the
#              endpoint `missing`. Before closing, the record gains
#              `endpoint_closed=<endpoint>`: the durable proof that the
#              endpoint is gone because firstmate closed it. That marker is
#              what lets `exit` and `relaunch` treat the gone endpoint as
#              proven absent even on tmux, so a stood-down task stays
#              relaunchable from its records alone, and bin/fm-teardown.sh
#              treats the already-gone endpoint as an ordinary silent close
#              while still running its full landed-work test. Idempotent: a
#              task already stood down reports `already-closed`.
#              Pool-slot retention and legacy process-lease compatibility are
#              owned by bin/fm-spawn.sh's durable-lease contract.
#   relaunch   Transactionally replace the running agent with a new one, in the
#              SAME worktree - and the same endpoint whenever that endpoint
#              still exists - on the same or a newly chosen
#              harness/model/effort - so switching harness is one ordinary use
#              of this verb. When the recorded endpoint is instead proven gone -
#              under fm_control_endpoint_absence_verdict's shared proof - the
#              launch owner creates one fresh endpoint in the recorded session
#              and worktree and rebinds the record to it. See
#              docs/agent-control.md's reclaim contract for backend limits.
#              An explicit `default` model or effort clears that
#              axis for the replacement. With no explicit axis, a secondmate
#              re-resolves its durable config/secondmate-harness pin (harness
#              plus its optional model and effort tokens) exactly as any other
#              respawn does, while a ship or scout keeps the exact adapter
#              already recorded for it.
#              A prefixed raw-command basename cannot reconstruct its launch
#              command, so relaunch requires an explicit --harness for it.
#              --note is required for a ship or scout, whose replacement
#              inherits the local copy but none of the conversation; a
#              secondmate reconciles its own home's records at startup, so its
#              standing charter is never rewritten.
#              --require-idle rechecks semantic busy state at the stop boundary
#              after checkpointing. Any verdict other than idle refuses with
#              exit status 4 and `idle-required: <verdict>`, without stopping
#              the agent; the refused transaction is rolled back and removed.
#              Callers without this flag retain the ordinary exit behavior.
#              Records a durable checkpoint and that note, exits the old agent,
#              then delegates the launch to its single owner,
#              bin/fm-spawn.sh --relaunch. A failure before publication keeps
#              the prior durable record in place and reports the concrete
#              state; it never leaves a half-transitioned task claiming to be
#              running.
#   compact    Compact a second mate's conversation in place with its
#              harness's own compaction command, only behind these guards, each
#              of which refuses (exit status 4, `compact-refused <id>: <why>`)
#              when it fails or cannot be established, before /compact is typed:
#                1. its context, read from the session's own transcript by
#                   bin/fm-context-size.sh, is over 400000 tokens;
#                2. bin/fm-secondmate-health.sh idle - the restart pass's own
#                   idle owner - reads it idle;
#                3. its steering inbox holds no unhandled instruction, its
#                   status log in this home no open keyed decision, this home no
#                   open reply expectation it owes and no pending backlog
#                   handoff to it, its own home no queued notification, and
#                   every direct report of its home reads done, paused, or
#                   failed to bin/fm-crew-state.sh, with independent semantic
#                   idle evidence or positive proof that its agent is gone;
#                4. it answers the restart pass's durable open-work checkpoint
#                   request (bin/fm-secondmate-restart-lib.sh) within that
#                   pass's bound, affirming checkpoint=complete, then settles
#                   idle within that pass's settle window;
#                5. the before-size transcript read, agent-alive and empty
#                   composer checks, and all direct-report reads run first;
#                   idle and the remaining checks in 3 run last, immediately
#                   before the keystroke.
#              Only then is the command typed, through the same keystroke path
#              `exit` uses. Completion is the transcript's new compact_boundary.
#              The recovery check then requires a smaller context, a live agent,
#              and a read-only probe answered through its parent channel that
#              names role=secondmate, its own id=, and records=readable; the
#              context re-read after that answer must still be below the size
#              before compaction. Every attempt is recorded in its status log
#              here: `note: context-compact refused|compacted|recovery-ok` with
#              before/after sizes and the checkpoint reference, or a failed
#              recovery as `blocked [key=context-compact]`, which stops there
#              (exit status 1) and keeps later compactions refused until it is
#              resolved. Nothing is ever resumed, restarted, or re-dispatched.
#              Claude is the one verified adapter (fm_control_compact_supported);
#              a crew, a scout, and the primary are never targets. This is a
#              guarded action firstmate invokes deliberately, not a generic
#              way to type a slash command, and nothing schedules it.
#
# Teardown and discard are NOT verbs here and never will be. `exit` stops an
# agent and preserves everything else; `stand-down` additionally closes the
# endpoint of a finished, fully pushed ship and preserves everything else;
# removing a worktree, removing a task's records, or discarding work stays with
# bin/fm-teardown.sh, which owns the landed-work test.
#
# `resume` is not a verb: it is not deterministic across the verified adapters
# (bin/fm-control-lib.sh's header owns that reasoning). `relaunch` covers the
# same need for every adapter because the brief on disk, not a harness-private
# session, is the durable instruction.
#
# Targeting is EXACT: only a bare task id with a state/<id>.meta record in
# THIS home is accepted, and the record must pass the shared endpoint-identity
# validation (bin/fm-backend.sh's fm_backend_validate_task_endpoint). A legacy
# fm-<id> label, an explicit session:window endpoint, and a bare window name
# are all refused - a lifecycle command delivered to the wrong endpoint is far
# worse than a loud refusal.
#
# A remotely placed secondmate is refused by name: its agent runs on another
# host, so no postcondition this plane verifies could be read for it here.
#
# Fail-closed boundaries:
#   - An unverified harness, or a harness whose control mechanics are unknown,
#     is refused rather than guessed at.
#   - A backend that cannot deliver the harness's interrupt key is refused
#     (Orca's terminal API has no Escape).
#   - `exit` and `relaunch` require a backend with a recovery-grade agent-state
#     classifier (tmux, herdr), because without one the "the agent stopped"
#     postcondition cannot be proven. zellij, orca, and cmux are refused rather
#     than reported as successful blind.
#   - An ambiguous or unreadable endpoint state refuses; only a positively
#     classified state acts.
#   - A composer that visibly holds pending text refuses before an exit command
#     is typed, so existing text is preserved instead of being concatenated.
#
# Environment knobs (all bounded waits, seconds):
#   FM_CONTROL_POLL              poll interval for postcondition waits (0.5)
#   FM_CONTROL_SETTLE_WAIT       adapter acknowledgement wait after interrupt (5)
#   FM_CONTROL_EXIT_WAIT         alive->dead wait after the exit command (30)
#   FM_CONTROL_LAUNCH_WAIT       dead->alive wait after a relaunch (90)
#   FM_CONTROL_EXIT_RETRIES      Enter retries for the exit and compact commands (3)
#   FM_CONTROL_COMPACT_WAIT      wait for the compaction to be recorded (600)
#   FM_CONTROL_COMPACT_POLL      transcript re-read interval during that wait (5)
#   FM_CONTROL_COMPACT_PROBE_WAIT  wait for the recovery probe's answer (300)
#   The checkpoint shares FM_SECONDMATE_PERSIST_WAIT, FM_SECONDMATE_PERSIST_POLL,
#   and FM_SECONDMATE_IDLE_SETTLE with bin/fm-secondmate-restart.sh.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  # The whole leading comment block, ending at the first non-comment line.
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never
# drive a crewmate's lifecycle (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-control refuses to resolve a task without an explicit firstmate home" >&2
  exit 1
fi
[ -d "$FM_HOME" ] || {
  echo "error: FM_HOME '$FM_HOME' is not a directory" >&2
  exit 1
}
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
[ -d "$STATE" ] || {
  echo "error: state dir '$STATE' is missing; fm-control cannot resolve tasks for FM_HOME '$FM_HOME'" >&2
  exit 1
}

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-secondmate-restart-lib.sh
. "$SCRIPT_DIR/fm-secondmate-restart-lib.sh"

POLL=${FM_CONTROL_POLL:-0.5}
SETTLE_WAIT=${FM_CONTROL_SETTLE_WAIT:-5}
EXIT_WAIT=${FM_CONTROL_EXIT_WAIT:-30}
LAUNCH_WAIT=${FM_CONTROL_LAUNCH_WAIT:-90}
EXIT_RETRIES=${FM_CONTROL_EXIT_RETRIES:-3}

die() {  # <message>
  echo "error: $1" >&2
  exit 1
}

CONTROL_LOCK=
CONTROL_LOCK_HELD=0
RELAUNCH_ACTIVE=0
RELAUNCH_PHASE=start

control_cleanup() {
  local status=$?
  if [ "$RELAUNCH_ACTIVE" = 1 ] \
     && declare -F relaunch_rollback >/dev/null 2>&1; then
    relaunch_rollback || true
  fi
  if [ "$CONTROL_LOCK_HELD" = 1 ]; then
    CONTROL_LOCK_HELD=0
    fm_lock_release "$CONTROL_LOCK" || true
  fi
  if declare -F fm_lease_guard_release >/dev/null 2>&1; then
    fm_lease_guard_release || true
  fi
  return "$status"
}

# --- argument parsing -------------------------------------------------------

RAW_ID=${1:-}
VERB=${2:-}
[ -n "$RAW_ID" ] && [ -n "$VERB" ] || { usage >&2; exit 2; }
shift 2

if ! fm_control_verb_allowed "$VERB"; then
  {
    if [ "$VERB" = resume ]; then
      echo "error: 'resume' is not a control verb: resuming an exited agent is not deterministic across the verified adapters (codex and grok need a session id printed at exit, opencode continues the most recent session for the cwd, and claude, pi, pi-signed, and kimi have no verified pane-resume contract). Use 'relaunch', which carries the brief plus a progress note into a fresh agent on any adapter."
    else
      echo "error: '$VERB' is not a control verb"
    fi
    echo "allowed verbs:"
    fm_control_verbs | sed 's/^/  /'
  } >&2
  exit 2
fi

NEW_HARNESS=
NEW_MODEL=
NEW_EFFORT=
HARNESS_SET=0
MODEL_SET=0
EFFORT_SET=0
NOTE=
NOTE_SET=0
REQUIRE_IDLE=0
control_want_value=
for control_arg in "$@"; do
  if [ -n "$control_want_value" ]; then
    case "$control_arg" in
      --*) die "--$control_want_value requires a value" ;;
    esac
    case "$control_want_value" in
      harness) NEW_HARNESS=$control_arg; HARNESS_SET=1 ;;
      model) NEW_MODEL=$control_arg; MODEL_SET=1 ;;
      effort) NEW_EFFORT=$control_arg; EFFORT_SET=1 ;;
      note) NOTE=$control_arg; NOTE_SET=1 ;;
      note_file)
        [ -f "$control_arg" ] || die "--note-file '$control_arg' is not a readable file"
        NOTE=$(cat "$control_arg")
        NOTE_SET=1
        ;;
    esac
    control_want_value=
    continue
  fi
  case "$control_arg" in
    --require-idle) REQUIRE_IDLE=1 ;;
    --harness) control_want_value=harness ;;
    --harness=*) NEW_HARNESS=${control_arg#--harness=}; HARNESS_SET=1 ;;
    --model) control_want_value=model ;;
    --model=*) NEW_MODEL=${control_arg#--model=}; MODEL_SET=1 ;;
    --effort) control_want_value=effort ;;
    --effort=*) NEW_EFFORT=${control_arg#--effort=}; EFFORT_SET=1 ;;
    --note) control_want_value=note ;;
    --note=*) NOTE=${control_arg#--note=}; NOTE_SET=1 ;;
    --note-file) control_want_value=note_file ;;
    --note-file=*)
      [ -f "${control_arg#--note-file=}" ] || die "--note-file '${control_arg#--note-file=}' is not a readable file"
      NOTE=$(cat "${control_arg#--note-file=}")
      NOTE_SET=1
      ;;
    *) die "unexpected argument '$control_arg'" ;;
  esac
done
if [ -n "$control_want_value" ]; then
  [ "$control_want_value" = note_file ] && die "--note-file requires a value"
  die "--$control_want_value requires a value"
fi

if [ "$VERB" != relaunch ]; then
  [ "$HARNESS_SET" = 0 ] && [ "$MODEL_SET" = 0 ] && [ "$EFFORT_SET" = 0 ] && [ "$NOTE_SET" = 0 ] && [ "$REQUIRE_IDLE" = 0 ] \
    || die "--harness, --model, --effort, --note, and --require-idle apply to 'relaunch' only"
fi
[ "$HARNESS_SET" = 0 ] || [ -n "$NEW_HARNESS" ] || die "--harness requires a non-empty value"
[ "$MODEL_SET" = 0 ] || [ -n "$NEW_MODEL" ] || die "--model requires a non-empty value"
[ "$EFFORT_SET" = 0 ] || [ -n "$NEW_EFFORT" ] || die "--effort requires a non-empty value"
case "$NEW_EFFORT" in
  ''|default|low|medium|high|xhigh|max|ultra) ;;
  *) die "--effort must be one of default, low, medium, high, xhigh, max, ultra" ;;
esac

# --- exact task-id resolution ----------------------------------------------

case "$RAW_ID" in
  *:*) die "'$RAW_ID' is an explicit backend endpoint; fm-control accepts an exact task id only, so a lifecycle command can never land on an endpoint this home does not own" ;;
esac
if ! fm_task_id_creation_valid "$RAW_ID"; then
  die "'$RAW_ID' is not a valid task id"
fi
ID=$RAW_ID
# Supervision lease guard: lifecycle control is overlap territory between the
# two Pi supervision actors; refuse while the OTHER actor holds this task's
# live lease (contract: bin/fm-lease-lib.sh; no-op in homes without leases).
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_guard "$ID" "lifecycle control (fm-control)"
CONTROL_LOCK="$STATE/.control-$ID.lock"
trap control_cleanup EXIT
fm_lock_try_acquire "$CONTROL_LOCK" \
  || die "another lifecycle action is already running for task $ID"
CONTROL_LOCK_HELD=1
META="$STATE/$ID.meta"
if [ ! -f "$META" ]; then
  case "$RAW_ID" in
    fm-*)
      if [ -f "$STATE/${RAW_ID#fm-}.meta" ]; then
        die "'$RAW_ID' is a window label, not a task id; pass the exact task id '${RAW_ID#fm-}'"
      fi
      ;;
  esac
  die "no task '$ID' in $STATE (fm-control resolves an exact task id only)"
fi

# A remotely placed secondmate records its endpoint on ANOTHER host, so every
# postcondition this plane verifies - the agent-state classification, the busy
# verdict, the endpoint's existence - would be read here for an endpoint that
# does not live here. Endpoint validation already refuses such a record, since
# `window=remote:<id>` can never match a local backend's required shape, so
# nothing can be delivered to a wrong endpoint either way. What that refusal
# cannot say is WHY, and "malformed metadata" is the wrong thing to tell an
# operator about a correctly configured remote route. Name the placement
# instead, using the same `remote_host` signal bin/fm-send.sh routes on.
if [ -n "$(fm_meta_get "$META" remote_host)" ]; then
  die "task $ID is a remotely placed secondmate on $(fm_meta_get "$META" remote_host); its agent runs outside this home, so no lifecycle action here could verify that it interrupted, stopped, or came back. Drive its lifecycle on that host, and reconcile it through the secondmate recovery path rather than this plane"
fi

fm_backend_validate_task_endpoint "$META" "$ID" || exit 1
BACKEND=$FM_BACKEND_VALIDATED_BACKEND
T=$FM_BACKEND_VALIDATED_TARGET
LABEL="fm-$ID"
RECORDED_HARNESS=$(fm_meta_get "$META" harness)
KIND=$(fm_meta_get "$META" kind)
WT=$(fm_meta_get "$META" worktree)
[ -n "$KIND" ] || KIND=ship

HARNESS=$(fm_control_harness_family "$RECORDED_HARNESS") \
  || die "task $ID records harness '${RECORDED_HARNESS:-none}', which has no verified control mechanics; fm-control refuses to guess an interrupt key or exit command"
fm_control_harness_supported "$HARNESS" \
  || die "task $ID records harness '${RECORDED_HARNESS:-none}', which has no verified control mechanics; fm-control refuses to guess an interrupt key or exit command"

fm_backend_validate "$BACKEND" || exit 1

# --- shared helpers ---------------------------------------------------------

agent_state() {
  fm_backend_agent_state "$BACKEND" "$T"
}

busy_verdict() {
  fm_busy_classify_meta "$META" "$ID" "$STATE"
}

# wait_agent_state <wanted...> <timeout>: poll until agent_state prints one of
# the wanted values. Prints the final observed state; returns 0 on a match.
wait_agent_state() {  # <timeout> <wanted>...
  local timeout=$1 state want elapsed=0
  shift
  while :; do
    state=$(agent_state)
    for want in "$@"; do
      if [ "$state" = "$want" ]; then
        printf '%s' "$state"
        return 0
      fi
    done
    awk -v e="$elapsed" -v t="$timeout" 'BEGIN{exit !(e < t)}' || break
    sleep "$POLL"
    elapsed=$(awk -v e="$elapsed" -v p="$POLL" 'BEGIN{printf "%.3f", e + p}')
  done
  printf '%s' "$state"
  return 1
}

require_state_verified_backend() {  # <verb>
  fm_control_backend_state_verified "$BACKEND" && return 0
  die "task $ID runs on the $BACKEND backend, which has no recovery-grade agent-state classifier, so '$1' cannot prove the agent actually stopped; refusing rather than reporting an unproven transition as done"
}

# send_interrupt_keys: deliver the harness's interrupt key the verified number
# of times, then the composer-clear key when the adapter needs one. Refuses
# before sending anything when the backend cannot deliver either key, because
# an interrupt that cancels the turn but leaves the restored prompt in the
# composer would make the next submitted line concatenate onto it.
send_interrupt_keys() {
  local key repeat clear i=0
  key=$(fm_control_interrupt_key "$HARNESS")
  repeat=$(fm_control_interrupt_repeat "$HARNESS")
  clear=$(fm_control_interrupt_clear_key "$HARNESS")
  fm_control_backend_supports_key "$BACKEND" "$key" \
    || die "harness $HARNESS interrupts with $key, which the $BACKEND backend cannot deliver; refusing to send a different key"
  [ -z "$clear" ] || fm_control_backend_supports_key "$BACKEND" "$clear" \
    || die "harness $HARNESS needs $clear to clear its composer after an interrupt, which the $BACKEND backend cannot deliver; refusing to leave the cancelled prompt where the next submitted line would concatenate onto it"
  while [ "$i" -lt "$repeat" ]; do
    fm_backend_send_key "$BACKEND" "$T" "$key" "$LABEL" \
      || die "interrupt key $key was not delivered to task $ID on $BACKEND"
    i=$((i + 1))
    [ "$i" -ge "$repeat" ] || sleep 0.2
  done
  [ -z "$clear" ] || fm_backend_send_key "$BACKEND" "$T" "$clear" "$LABEL" \
    || die "interrupt key $key reached task $ID, but $clear did not, so its composer still holds the cancelled prompt; clear it before the next lifecycle action"
}

prepare_interrupt_ack() {
  INTERRUPT_ACK_SOURCE=$(fm_control_interrupt_ack_source "$HARNESS")
  INTERRUPT_ACK_LOG=
  INTERRUPT_ACK_RUN=
  case "$INTERRUPT_ACK_SOURCE" in
    muse-session-terminal)
      INTERRUPT_ACK_LOG=$(fm_busy_muse_session_log "$STATE" "$ID" 2>/dev/null || true)
      [ -n "$INTERRUPT_ACK_LOG" ] || return 0
      INTERRUPT_ACK_RUN=$(fm_busy_muse_active_run_id "$INTERRUPT_ACK_LOG" 2>/dev/null || true)
      ;;
  esac
}

interrupt_cancel_claim() {
  local elapsed=0 terminal=
  case "$INTERRUPT_ACK_SOURCE:$INTERRUPT_ACK_RUN" in
    muse-session-terminal:?*) ;;
    *) printf 'unconfirmed'; return 0 ;;
  esac
  while :; do
    terminal=$(fm_busy_muse_run_terminal "$INTERRUPT_ACK_LOG" "$INTERRUPT_ACK_RUN" 2>/dev/null || true)
    case "$terminal" in
      cancelled) printf 'confirmed'; return 0 ;;
      ?*) printf 'unconfirmed'; return 0 ;;
    esac
    awk -v e="$elapsed" -v t="$SETTLE_WAIT" 'BEGIN{exit !(e < t)}' || break
    sleep "$POLL"
    elapsed=$(awk -v e="$elapsed" -v p="$POLL" 'BEGIN{printf "%.3f", e + p}')
  done
  printf 'unconfirmed'
}

# deliver_interrupt: deliver and observe the strongest adapter-owned
# cancellation claim available after delivery.
deliver_interrupt() {
  local cancel
  prepare_interrupt_ack
  send_interrupt_keys
  cancel=$(interrupt_cancel_claim)
  printf '%s' "$cancel"
}

verify_interrupt_running() {
  local proof after
  fm_backend_target_exists "$BACKEND" "$T" "$LABEL" \
    || die "task $ID's endpoint disappeared while interrupting it; no further control action is safe"
  proof=endpoint
  if fm_control_backend_state_verified "$BACKEND"; then
    # An interrupt cancels a turn; it must never have stopped the agent. This
    # is the postcondition that separates a landed interrupt from an accident.
    after=$(agent_state)
    [ "$after" = alive ] \
      || die "task $ID's agent is '$after' after its interrupt key; an interrupt must leave the agent running"
    proof='agent-alive'
  fi
  printf '%s' "$proof"
}

do_interrupt() {
  local proof cancel
  cancel=$(deliver_interrupt) || return $?
  proof=$(verify_interrupt_running) || return $?
  printf '%s cancel=%s' "$proof" "$cancel"
}

retire_busy_incarnation() {
  if [ -f "$STATE/$ID.busy-gen" ]; then
    "$SCRIPT_DIR/fm-busy-event.sh" retire "$STATE" "$ID" --current-gen >/dev/null 2>&1 || true
  fi
}

# do_exit: stop the running agent, preserving endpoint and worktree. Prints
# `already-stopped`, `endpoint-gone`, or `stopped`.
do_exit() {
  local state cmd verdict composer_state cancel absence interrupt_result=not-needed
  require_state_verified_backend exit
  state=$(agent_state)
  if [ "$REQUIRE_IDLE" = 1 ]; then
    verdict=$(busy_verdict) || verdict="unknown unreadable"
    if [ "${verdict%% *}" != idle ]; then
      printf 'idle-required: %s\n' "$verdict" >&2
      return 4
    fi
  fi
  case "$state" in
    dead)
      printf 'already-stopped'
      return 0
      ;;
    alive) ;;
    missing)
      # `missing` on its own is not a finding about the endpoint: it conflates
      # "destroyed" with "unreachable from this seat". Route it through the
      # control plane's one absence proof - the same one the relaunch gate uses
      # - and report what that proof actually established, never more.
      absence=$(fm_control_endpoint_absence_verdict "$BACKEND" "$T" "$META")
      case "${absence%%$'\t'*}" in
        gone)
          # Proven gone, so the agent that lived in it went with it: exit's
          # postcondition already holds and there is nothing to send. Its own
          # outcome rather than `already-stopped`, because the endpoint this
          # verb normally preserves did not survive. The worktree and every
          # uncommitted change are untouched, and `relaunch` re-creates the
          # endpoint from here.
          printf 'endpoint-gone'
          return 0
          ;;
        dead)
          # The endpoint was only unreachable and is there after all, holding
          # no agent - a herdr pane whose session server was merely stopped is
          # the common case. Nothing is gone, so this is the ordinary
          # already-stopped outcome.
          printf 'already-stopped'
          return 0
          ;;
        alive)
          # The agent came back with its endpoint. Fall through to the ordinary
          # alive path: interrupt if busy, then the harness's exit command.
          ;;
        *)
          die "task $ID's endpoint $T reads 'missing', but ${absence#*$'\t'}; exit will not claim an agent stopped at an address it cannot trust, nor send lifecycle input to one"
          ;;
      esac
      ;;
    *) die "task $ID's endpoint reads '$state' rather than a positively classified state; refusing to send a lifecycle command into an unattributed endpoint" ;;
  esac
  # A busy agent is interrupted first before the exit command is submitted.
  if [ "$REQUIRE_IDLE" = 0 ]; then
    verdict=$(busy_verdict) || verdict="unknown unreadable"
  fi
  case "$verdict" in
    busy*)
      cancel=$(deliver_interrupt) || return $?
      state=$(agent_state)
      case "$state" in
        dead)
          retire_busy_incarnation
          printf 'stopped'
          return 0
          ;;
        alive) interrupt_result="delivered verified=agent-alive cancel=$cancel" ;;
        missing) die "task $ID's recorded endpoint disappeared after interrupt delivery, so exit cannot prove whether the agent stopped" ;;
        *) die "task $ID's endpoint reads '$state' after interrupt delivery rather than a positively classified state; exit cannot prove whether the agent stopped" ;;
      esac
      ;;
  esac
  cmd=$(fm_control_exit_command "$HARNESS")
  composer_state=$(fm_backend_composer_state "$BACKEND" "$T" "$LABEL" 2>/dev/null) \
    || composer_state=unknown
  case "$composer_state" in
    empty) ;;
    pending)
      die "task $ID's composer visibly holds pending text; refusing to type the $cmd exit command because it would concatenate onto that text. Clear or submit the pending text, then retry '$VERB'"
      ;;
    *)
      die "task $ID's composer state is '$composer_state', not proven empty; refusing to type the $cmd exit command because it could concatenate onto existing text. Clear the composer, then retry '$VERB'"
      ;;
  esac
  # The submit verdict is NOT the postcondition here: a successful exit command
  # destroys the composer the verdict is read from, so a post-exit read can
  # legitimately report anything. Only a hard transport failure aborts; the
  # authoritative proof is the agent-state wait below. The retried Enter still
  # matters, because a slash command opens a completion popup on some TUIs that
  # swallows the first Enter.
  verdict=$(fm_backend_send_text_submit "$BACKEND" "$T" "$cmd" "$EXIT_RETRIES" "$POLL" 1.2 "$LABEL") \
    || die "the exit command could not be sent to task $ID on $BACKEND"
  [ "$verdict" != send-failed ] \
    || die "the exit command could not be sent to task $ID on $BACKEND"
  state=$(wait_agent_state "$EXIT_WAIT" dead) || {
    die "exit-delivered $ID interrupt=$interrupt_result exit-command=delivered agent-state=$state exit=unconfirmed; the agent did not stop within ${EXIT_WAIT}s"
  }
  # The incarnation is over: retire its busy wiring so no stale record or
  # orphaned generation survives the agent that produced it.
  retire_busy_incarnation
  printf 'stopped'
}

# --- stand-down -------------------------------------------------------------

# standdown_worktree_landed_on_remote: refuse unless the recorded worktree holds
# no uncommitted or untracked change and its HEAD is already pushed - reachable
# from a remote-tracking branch, or exactly the recorded pr_head. Closing the
# endpoint of a worker that still holds unpushed work is what stand-down must
# never do, whatever its status log claims.
standdown_worktree_landed_on_remote() {  # <phase>
  local phase=$1 status_output head pr_head remotes
  [ -n "$WT" ] && [ -d "$WT" ] \
    || die "task $ID's recorded worktree '${WT:-none}' is missing; stand-down refuses to close the endpoint without accounting for its work"
  status_output=$(git -C "$WT" status --porcelain 2>/dev/null) \
    || die "task $ID's worktree status cannot be inspected $phase; stand-down refuses to close the endpoint without accounting for local changes"
  [ -z "$status_output" ] \
    || die "task $ID's worktree holds uncommitted or untracked changes $phase; stand-down refuses to close the endpoint of a worker with unlanded work"
  head=$(git -C "$WT" rev-parse --verify -q HEAD 2>/dev/null) \
    || die "task $ID's worktree HEAD cannot be resolved $phase; stand-down refuses to close the endpoint without accounting for its commits"
  pr_head=$(fm_meta_get "$META" pr_head)
  [ -n "$pr_head" ] && [ "$pr_head" = "$head" ] && return 0
  remotes=$(git -C "$WT" for-each-ref --contains "$head" --format='%(refname)' refs/remotes 2>/dev/null) \
    || die "task $ID's remote-tracking branches cannot be inspected $phase; stand-down refuses to close the endpoint without proving its commits are pushed"
  [ -n "$remotes" ] \
    || die "task $ID's worktree HEAD $head is not on any remote-tracking branch and is not the recorded PR head $phase; stand-down refuses to close the endpoint of a worker with unpushed commits"
}

# standdown_gate: every precondition that must hold before stand-down touches
# the agent. Refuses by name; nothing has changed when it does.
standdown_gate() {
  local mode pr current crew crew_state endpoint_state
  [ "$KIND" = ship ] \
    || die "task $ID is a $KIND task; stand-down closes only a finished ship worker's endpoint (use 'exit' to stop this agent and keep its endpoint)"
  mode=$(fm_meta_get "$META" mode)
  [ -n "$mode" ] || mode=no-mistakes
  case "$mode" in
    no-mistakes|direct-PR) ;;
    *) die "task $ID ships through '$mode', which has no recorded PR to wait on; stand-down applies to no-mistakes and direct-PR work only" ;;
  esac
  pr=$(fm_meta_get "$META" pr)
  [ -n "$pr" ] \
    || die "task $ID has no recorded PR; stand-down is allowed only from the done state with the PR recorded (bin/fm-pr-check.sh records it)"
  current=$(status_current_line "$STATE/$ID.status" "$KIND")
  case "$current" in
    done|done\ *|done:*) ;;
    *) die "task $ID's current status is '${current:-none}', not done; stand-down is allowed only from the done state" ;;
  esac
  crew=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_CREW_STATE_NO_FORGE=1 \
    "$SCRIPT_DIR/fm-crew-state.sh" "$ID" 2>/dev/null) || crew=
  crew_state=${crew#state: }
  crew_state=${crew_state%% *}
  case "$crew_state" in
    done) ;;
    unknown)
      # A direct-PR task has no validation run to attribute, so once its agent
      # is already stopped its current state has nothing left to read from. Only
      # that exact case - no pipeline, and an agent positively gone - may pass.
      endpoint_state=$(agent_state)
      if [ "$mode" != direct-PR ] || { [ "$endpoint_state" != dead ] && [ "$endpoint_state" != missing ]; }; then
        die "task $ID's current state reads '${crew:-unreadable}'; stand-down cannot prove no validation run is active, so it refuses"
      fi
      ;;
    *) die "task $ID's current state reads '${crew:-unreadable}', not done; stand-down never closes the endpoint of a worker that is validating, parked, or otherwise not finished" ;;
  esac
  standdown_worktree_landed_on_remote "before stand-down"
}

# standdown_record_marker <endpoint|->: add (or, with -, drop) the record's
# endpoint_closed= marker under the task's meta lock, preserving every other
# line byte-for-byte, honoring fm_pr_meta_trailer_keys in bin/fm-pr-lib.sh.
standdown_record_marker() {  # <endpoint|->
  local value=$1 lock tmp line key rc=0 inserted=0
  lock=$(fm_meta_lock_path "$META") || return 1
  fm_lock_acquire_wait "$lock" || return 1
  tmp="$STATE/.$ID.meta.standdown.${BASHPID:-$$}"
  # Copy first so the replacement keeps the record's own mode, then rewrite its
  # bytes in place.
  cp -p "$META" "$tmp" || rc=1
  if [ "$rc" = 0 ]; then
    {
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          endpoint_closed=*) continue ;;
        esac
        key=${line%%=*}
        if [ "$inserted" -eq 0 ] && fm_pr_meta_trailer_key "$key"; then
          [ "$value" = - ] || printf 'endpoint_closed=%s\n' "$value"
          inserted=1
        fi
        printf '%s\n' "$line"
      done < "$META"
      if [ "$inserted" -eq 0 ] && [ "$value" != - ]; then
        printf 'endpoint_closed=%s\n' "$value"
      fi
    } > "$tmp" || rc=1
  fi
  [ "$rc" != 0 ] || mv -f "$tmp" "$META" || rc=1
  rm -f "$tmp"
  fm_lock_release "$lock" || true
  return "$rc"
}

# do_stand_down: prints the stand-down outcome line, whose endpoint= is
# `closed` or `already-closed`. Called directly rather than through a command
# substitution so errexit still stops it at the first refusal of a nested one.
do_stand_down() {
  local exit_result state close_rc
  require_state_verified_backend stand-down
  case "$BACKEND" in
    tmux|herdr) ;;
    *) die "task $ID runs on the $BACKEND backend, which has no stand-down endpoint close; use 'exit', which keeps the endpoint" ;;
  esac
  standdown_gate
  exit_result=$(do_exit)
  # The agent is gone now. Re-prove that nothing unlanded appeared while it was
  # stopping, because the close below is the point of no return for the shell.
  standdown_worktree_landed_on_remote "after the agent stopped"
  if [ "$exit_result" = endpoint-gone ] \
     && fm_control_endpoint_closed_at_standdown "$META" "$T"; then
    standdown_report already-closed
    return 0
  fi
  standdown_record_marker "$T" \
    || die "task $ID's agent is stopped, but its record could not be marked before closing the endpoint; the endpoint was left in place"
  close_rc=0
  fm_backend_close_task_endpoint "$BACKEND" "$T" "$STATE" "$ID" "$META" || close_rc=$?
  state=$(agent_state)
  case "$state" in
    missing) ;;
    alive|dead)
      standdown_record_marker - || true
      die "task $ID's endpoint $T reads '$state' after its close (close status $close_rc); it was left in place and the record still names it"
      ;;
    *)
      if [ "$close_rc" -ne 0 ]; then
        standdown_record_marker - || true
      fi
      die "task $ID's endpoint $T reads '$state' after its close (close status $close_rc); whether it survived is unknown"
      ;;
  esac
  standdown_report closed
}

standdown_report() {  # <closed|already-closed>
  echo "stood-down $ID endpoint=$1 backend=$BACKEND closed=$T worktree=$WT"
}

# --- transactional relaunch -------------------------------------------------
#
# The transaction's durable record is state/<id>.control-relaunch, with the
# prior metadata and brief preserved beside it. Every failure path runs through
# relaunch_rollback (an EXIT trap, so a refusal raised deep inside a shared
# helper is covered too) and leaves either the pre-relaunch durable record or a
# concrete, named partial state - never a task whose record claims an agent
# that is not running.

JOURNAL="$STATE/$ID.control-relaunch"
META_PRIOR="$JOURNAL.meta-prior"
BRIEF_PRIOR="$JOURNAL.brief-prior"
NOTE_FILE="$JOURNAL.note"
RELAUNCH_META_PUBLISHED=0
RELAUNCH_AGENT_CONFIRMED=0
RELAUNCH_TX=
RELAUNCH_BRIEF=
PRIOR_HARNESS=$HARNESS
PRIOR_RECORDED_HARNESS=$RECORDED_HARNESS
CONFIG_HARNESS=
CONFIG_MODEL=
CONFIG_EFFORT=
PRIOR_MODEL=
PRIOR_EFFORT=
TARGET_HARNESS=$HARNESS
TARGET_MODEL=
TARGET_EFFORT=

journal_write() {  # <phase> [extra-line]...
  local phase=$1
  shift
  if {
    echo "v1"
    echo "task=$ID"
    echo "phase=$phase"
    echo "ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "backend=$BACKEND"
    echo "endpoint=$T"
    echo "worktree=$WT"
    echo "kind=$KIND"
    echo "from_harness=$PRIOR_RECORDED_HARNESS"
    echo "from_model=$PRIOR_MODEL"
    echo "from_effort=$PRIOR_EFFORT"
    echo "to_harness=$TARGET_HARNESS"
    echo "to_model=$TARGET_MODEL"
    echo "to_effort=$TARGET_EFFORT"
    local line
    for line in "$@"; do
      echo "$line"
    done
  } > "$JOURNAL.tmp" && mv -f "$JOURNAL.tmp" "$JOURNAL"; then
    RELAUNCH_PHASE=$phase
    return 0
  fi
  return 1
}

relaunch_rollback() {
  local state
  [ "$RELAUNCH_ACTIVE" = 1 ] || return 0
  [ "$RELAUNCH_PHASE" != complete ] || return 0
  RELAUNCH_ACTIVE=0
  case "$RELAUNCH_PHASE" in
    checkpoint|noted)
      # The old agent was never touched. Restore the instructions byte-exact so
      # a refused relaunch leaves nothing behind.
      if [ -n "$RELAUNCH_BRIEF" ] && [ -f "$BRIEF_PRIOR" ]; then
        cp -p "$BRIEF_PRIOR" "$RELAUNCH_BRIEF" 2>/dev/null || true
      fi
      journal_write "failed:$RELAUNCH_PHASE" "rollback=instructions-restored" || true
      echo "error: relaunch of $ID was refused before its agent was touched; nothing changed" >&2
      ;;
    stopping)
      state=$(agent_state 2>/dev/null || printf unknown)
      case "$state" in
        alive)
          if [ -n "$RELAUNCH_BRIEF" ] && [ -f "$BRIEF_PRIOR" ]; then
            cp -p "$BRIEF_PRIOR" "$RELAUNCH_BRIEF" 2>/dev/null || true
          fi
          journal_write "failed:$RELAUNCH_PHASE" "rollback=instructions-restored-agent-alive" || true
          echo "error: relaunch of $ID failed while stopping the old agent, which is still running; its original instructions were restored" >&2
          ;;
        dead)
          journal_write "failed:$RELAUNCH_PHASE" "rollback=prior-record-kept-agent-dead" || true
          echo "error: $ID's agent stopped but relaunch did not reach replacement launch; no agent is running, and its work plus progress note are preserved at $WT" >&2
          ;;
        *)
          # The old agent was NOT proven stopped, so no replacement is coming
          # and the agent that may still be reading these instructions is the
          # original one. The note exists to brief a replacement; leaving it in
          # a possibly-live agent's brief would be an unrequested edit to a
          # running task. Restore byte-exact, exactly as the alive case does.
          if [ -n "$RELAUNCH_BRIEF" ] && [ -f "$BRIEF_PRIOR" ]; then
            cp -p "$BRIEF_PRIOR" "$RELAUNCH_BRIEF" 2>/dev/null || true
          fi
          journal_write "failed:$RELAUNCH_PHASE" "rollback=instructions-restored-agent-state-$state" || true
          echo "error: relaunch of $ID failed while stopping the old agent and its state is '$state', so it was not proven stopped; its original instructions were restored and the durable record was retained for recovery" >&2
          ;;
      esac
      ;;
    exited|launching)
      if [ "$RELAUNCH_AGENT_CONFIRMED" = 1 ]; then
        journal_write "failed:$RELAUNCH_PHASE" "rollback=none-new-agent-confirmed" || true
        echo "error: $ID's replacement is running on $TARGET_HARNESS, but transaction completion could not be persisted; its published record was retained for reconciliation" >&2
      elif [ "$RELAUNCH_META_PUBLISHED" = 1 ] \
         || { [ -n "$RELAUNCH_TX" ] \
              && [ "$(fm_meta_get "$META" control_relaunch_tx)" = "$RELAUNCH_TX" ]; }; then
        # The launch owner published the new incarnation's record. Leaving it
        # in place is the honest state: the task is now recorded on the new
        # harness with no agent confirmed, which is exactly what recovery
        # reconciles. Rewriting it back to the old harness would be a second,
        # worse inaccuracy.
        journal_write "failed:$RELAUNCH_PHASE" "rollback=none-new-record-kept" || true
        echo "error: $ID was relaunched on $TARGET_HARNESS but no running agent could be confirmed; its work is preserved at $WT" >&2
      else
        journal_write "failed:$RELAUNCH_PHASE" "rollback=prior-record-kept" || true
        echo "error: $ID's agent was stopped but the replacement did not launch; no agent is running, and its work plus the recorded progress note are preserved at $WT" >&2
      fi
      ;;
  esac
  return 0
}

resolve_relaunch_profile() {
  PRIOR_HARNESS=$HARNESS
  PRIOR_RECORDED_HARNESS=$RECORDED_HARNESS
  PRIOR_MODEL=$(fm_meta_get "$META" model)
  PRIOR_EFFORT=$(fm_meta_get "$META" effort)
  [ -n "$PRIOR_MODEL" ] || PRIOR_MODEL=default
  [ -n "$PRIOR_EFFORT" ] || PRIOR_EFFORT=default
  if [ "$HARNESS_SET" = 0 ] \
     && [ "$PRIOR_RECORDED_HARNESS" != "$PRIOR_HARNESS" ]; then
    die "task $ID records harness '$PRIOR_RECORDED_HARNESS', whose original launch command cannot be reconstructed from its recorded basename; relaunching without --harness would substitute the canonical adapter '$PRIOR_HARNESS' for the command actually running. Pass an explicit --harness to choose the replacement runtime deliberately"
  fi
  CONFIG_HARNESS=
  CONFIG_MODEL=
  CONFIG_EFFORT=
  if [ "$KIND" = secondmate ]; then
    # A secondmate's harness, model, and effort are a durable configured pin
    # that every respawn re-resolves (the secondmate-provisioning contract), so
    # a relaunch with no explicit harness picks up a newly configured one
    # instead of freezing whatever this incarnation happens to run. Crewmates
    # and scouts deliberately do NOT resolve config here: their harness comes
    # from firstmate's own dispatch-profile judgment at intake, and silently
    # re-resolving it would bypass that consultation.
    CONFIG_HARNESS=$("$SCRIPT_DIR/fm-harness.sh" secondmate 2>/dev/null || true)
    CONFIG_MODEL=$("$SCRIPT_DIR/fm-harness.sh" secondmate-model 2>/dev/null || true)
    CONFIG_EFFORT=$("$SCRIPT_DIR/fm-harness.sh" secondmate-effort 2>/dev/null || true)
    case "$CONFIG_EFFORT" in
      ''|low|medium|high|xhigh|max|ultra) ;;
      *)
        echo "warning: config/secondmate-harness effort token '$CONFIG_EFFORT' is not one of low, medium, high, xhigh, max, ultra; ignoring" >&2
        CONFIG_EFFORT=
        ;;
    esac
  fi
  if [ "$HARNESS_SET" = 1 ]; then
    fm_control_harness_supported "$NEW_HARNESS" \
      || die "'$NEW_HARNESS' is not a verified harness; fm-control refuses to relaunch onto an adapter with no verified control or launch mechanics"
    TARGET_HARNESS=$NEW_HARNESS
  elif [ "$HARNESS_SET" = 0 ] && [ -n "$CONFIG_HARNESS" ]; then
    fm_control_harness_supported "$CONFIG_HARNESS" \
      || die "the configured secondmate harness '$CONFIG_HARNESS' is not verified; fm-control refuses to relaunch onto an adapter with no verified control or launch mechanics"
    TARGET_HARNESS=$CONFIG_HARNESS
  else
    TARGET_HARNESS=$PRIOR_HARNESS
  fi
  # The launch owner refuses an adapter that cannot run this task's kind, but it
  # is only reached after the old agent has been stopped. Asking the same
  # capability table here keeps that refusal on the pre-stop side of the
  # transaction, where nothing has changed yet.
  fm_control_harness_supports_kind "$TARGET_HARNESS" "$KIND" \
    || die "'$TARGET_HARNESS' is not verified to run a $KIND task, so relaunching $ID onto it would stop the running agent for a launch that must be refused; choose an adapter verified for this kind"
  # A model or effort chosen for the previous harness does not transfer to a
  # different one, so an explicit harness change resets both axes unless the
  # caller names them too.
  if [ "$MODEL_SET" = 1 ]; then
    TARGET_MODEL=$NEW_MODEL
  elif [ "$HARNESS_SET" = 0 ] && [ -n "$CONFIG_HARNESS" ]; then
    TARGET_MODEL=${CONFIG_MODEL:-default}
  elif [ "$TARGET_HARNESS" = "$PRIOR_HARNESS" ]; then
    TARGET_MODEL=$PRIOR_MODEL
  else
    TARGET_MODEL=default
  fi
  if [ "$EFFORT_SET" = 1 ]; then
    TARGET_EFFORT=$NEW_EFFORT
  elif [ "$HARNESS_SET" = 0 ] && [ -n "$CONFIG_HARNESS" ]; then
    TARGET_EFFORT=${CONFIG_EFFORT:-default}
  elif [ "$TARGET_HARNESS" = "$PRIOR_HARNESS" ]; then
    TARGET_EFFORT=$PRIOR_EFFORT
  else
    TARGET_EFFORT=default
  fi
  if [ "$TARGET_EFFORT" = ultra ]; then
    "$SCRIPT_DIR/fm-harness.sh" validate-native-effort "$TARGET_HARNESS" "$TARGET_MODEL" "$TARGET_EFFORT" || return 1
  fi
}

# safe_checkpoint: prove, before anything is stopped, that the work a relaunch
# must preserve is actually there and recoverable afterwards. Fills
# CHECKPOINT_LINES with the journal lines describing what it proved, and
# refuses outright when any of it cannot be established.
CHECKPOINT_LINES=()
safe_checkpoint() {
  local wt_real wt_top wt_top_real head head_ref head_ref_status status_output dirty children marker child_meta
  CHECKPOINT_LINES=()
  [ -n "$WT" ] || die "task $ID has no recorded worktree; refusing to relaunch without a recorded local copy to preserve"
  [ -d "$WT" ] || die "task $ID's recorded worktree $WT is missing; refusing to relaunch and lose track of its work"
  wt_real=$(cd "$WT" 2>/dev/null && pwd -P) || die "task $ID's recorded worktree $WT cannot be resolved"
  wt_top=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null) \
    || die "task $ID's recorded worktree $WT is not a git worktree; refusing to relaunch without a checkout whose unlanded work can be accounted for"
  wt_top_real=$(cd "$wt_top" 2>/dev/null && pwd -P) || wt_top_real=$wt_top
  [ "$wt_real" = "$wt_top_real" ] \
    || die "task $ID's recorded worktree $WT is not a worktree root (root is $wt_top); refusing to relaunch against an ambiguous checkout"
  if head=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null); then
    :
  elif head_ref=$(git -C "$WT" symbolic-ref -q HEAD 2>/dev/null); then
    if git -C "$WT" show-ref --verify --quiet "$head_ref" 2>/dev/null; then
      die "task $ID's worktree HEAD exists but cannot be resolved; refusing to relaunch from an unreadable checkout"
    else
      head_ref_status=$?
      [ "$head_ref_status" -eq 1 ] \
        || die "task $ID's worktree HEAD cannot be inspected; refusing to relaunch from an unreadable checkout"
      head=unborn
    fi
  else
    die "task $ID's worktree HEAD cannot be inspected; refusing to relaunch from an unreadable checkout"
  fi
  status_output=$(git -C "$WT" status --porcelain 2>/dev/null) \
    || die "task $ID's worktree status cannot be inspected; refusing to relaunch without accounting for local changes"
  if [ -n "$status_output" ]; then
    dirty=yes
  else
    dirty=no
  fi
  CHECKPOINT_LINES+=("worktree_head=$head" "worktree_dirty=$dirty")
  if [ "$KIND" = secondmate ]; then
    # A secondmate's own crewmates outlive its relaunch: they run in their own
    # endpoints, and the relaunched secondmate reconciles them from its home's
    # durable records at startup. The checkpoint proves those records are
    # readable BEFORE the agent stops, so a relaunch can never strand child
    # work behind an unreadable home.
    marker=$(cat "$WT/.fm-secondmate-home" 2>/dev/null || true)
    [ "$marker" = "$ID" ] \
      || die "task $ID's home $WT is not marked as its own seeded secondmate home (marker: ${marker:-none}); refusing to relaunch"
    [ -d "$WT/state" ] \
      || die "secondmate $ID's home has no readable state directory, so its child work cannot be accounted for; refusing to relaunch"
    find "$WT/state" -mindepth 1 -maxdepth 1 -print >/dev/null 2>&1 \
      || die "secondmate $ID's child records cannot be traversed; refusing to relaunch"
    children=0
    for child_meta in "$WT/state"/*.meta; do
      if [ ! -e "$child_meta" ] && [ ! -L "$child_meta" ]; then
        continue
      fi
      if [ ! -f "$child_meta" ] || [ -L "$child_meta" ] \
         || ! cat "$child_meta" >/dev/null 2>&1; then
        die "secondmate $ID's child record $child_meta is not a readable regular file; refusing to relaunch"
      fi
      children=$((children + 1))
    done
    CHECKPOINT_LINES+=("children=$children")
  fi
}

# record_note: put the required progress note somewhere durable, and - for a
# ship or scout, whose only record of the interrupted reasoning is the
# conversation about to be discarded - into the instructions the replacement
# actually reads. A secondmate's charter is a durable standing document and is
# never rewritten: a secondmate reconciles its own home's records at startup,
# so the note stays parent-side audit evidence.
record_note() {
  local stamp
  [ -n "$NOTE" ] || return 0
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '%s\n' "$NOTE" > "$NOTE_FILE"
  case "$KIND" in
    ship|scout)
      cp -p "$RELAUNCH_BRIEF" "$BRIEF_PRIOR" \
        || die "could not preserve task $ID's instructions before recording the progress note"
      {
        echo
        echo "## Progress note ($stamp)"
        echo
        echo "This task was relaunched. Continue from here; the local copy and every"
        echo "uncommitted change are exactly as the previous worker left them."
        echo
        echo "First, check your instruction inbox: list $STATE/$ID.inbox/*.msg, act on"
        echo "each message in numeric order, then mv each handled file into"
        echo "$STATE/$ID.inbox/handled/. A steer sent before the relaunch survives there."
        echo
        printf '%s\n' "$NOTE"
      } >> "$RELAUNCH_BRIEF" \
        || die "could not append the progress note to task $ID's instructions"
      ;;
  esac
}

do_relaunch() {
  local exit_result exit_rc state note_line
  local -a spawn_args

  require_state_verified_backend relaunch
  resolve_relaunch_profile

  case "$KIND" in
    ship|scout)
      RELAUNCH_BRIEF="$DATA/$ID/brief.md"
      [ -f "$RELAUNCH_BRIEF" ] \
        || die "task $ID has no instructions at $RELAUNCH_BRIEF; refusing to relaunch a worker with nothing to work from"
      [ "$NOTE_SET" = 1 ] && [ -n "$NOTE" ] \
        || die "relaunch of a $KIND task requires --note (or --note-file): the replacement worker inherits the local copy but none of the conversation, so it must be told what happened"
      ;;
    secondmate)
      # The charter in the secondmate's own home is its instruction source and
      # stays untouched.
      RELAUNCH_BRIEF=
      ;;
    *)
      die "task $ID records kind '$KIND', which has no defined relaunch shape"
      ;;
  esac

  if [ -n "$NOTE" ]; then
    note_line="note_file=$NOTE_FILE"
  else
    note_line="note=none"
  fi
  safe_checkpoint
  cp -p "$META" "$META_PRIOR" || die "could not preserve task $ID's durable record before relaunching"
  RELAUNCH_ACTIVE=1
  journal_write checkpoint "${CHECKPOINT_LINES[@]}" "$note_line"

  record_note
  journal_write noted "${CHECKPOINT_LINES[@]}" "$note_line"

  journal_write stopping "${CHECKPOINT_LINES[@]}" "$note_line"
  exit_result=$(do_exit) || {
    exit_rc=$?
    if [ "$exit_rc" -eq 4 ]; then
      RELAUNCH_PHASE=noted
      relaunch_rollback
      rm -f "$JOURNAL" "$META_PRIOR" "$BRIEF_PRIOR" "$NOTE_FILE"
    fi
    return "$exit_rc"
  }
  journal_write exited "${CHECKPOINT_LINES[@]}" "$note_line" "exit_result=$exit_result"

  # The launch owner (fm-spawn --relaunch) clears the previous incarnation's
  # per-task harness wiring before arming the new one, so nothing to do here.
  RELAUNCH_TX="${BASHPID:-$$}.$(date -u +%Y%m%dT%H%M%SZ).$RANDOM"
  journal_write launching "${CHECKPOINT_LINES[@]}" "$note_line" "relaunch_tx=$RELAUNCH_TX"
  spawn_args=("$ID" --relaunch --harness "$TARGET_HARNESS")
  [ "$TARGET_MODEL" = default ] || spawn_args+=(--model "$TARGET_MODEL")
  [ "$TARGET_EFFORT" = default ] || spawn_args+=(--effort "$TARGET_EFFORT")
  if FM_CONTROL_RELAUNCH_TX="$RELAUNCH_TX" \
      "$SCRIPT_DIR/fm-spawn.sh" "${spawn_args[@]}" >/dev/null; then
    RELAUNCH_META_PUBLISHED=1
    # $T was resolved from the record before the launch. When the recorded
    # endpoint was gone, the launch owner created a fresh one and republished
    # the record pointing at it, so every postcondition below must be read from
    # the endpoint the task now HAS, not the one it had. Re-resolving through
    # the same shared validation is what makes that safe: a record that no
    # longer passes it refuses here rather than leaving this transaction
    # polling an address nothing owns.
    # stdout is dropped (it is only the resolved target), but the refusal on
    # stderr names the exact row that failed - and in this one branch the record
    # was just rewritten by the launch owner, so that row is the whole
    # diagnostic. Let it through rather than dying with nothing to act on.
    if fm_backend_validate_task_endpoint "$META" "$ID" >/dev/null \
       && [ -n "$FM_BACKEND_VALIDATED_TARGET" ]; then
      T=$FM_BACKEND_VALIDATED_TARGET
    else
      die "the replacement agent for $ID was launched, but task $ID's republished record no longer passes endpoint validation (the refusal above names the row), so this transaction cannot say which endpoint to confirm it on; reconcile $META before any further control action"
    fi
  else
    [ "$(fm_meta_get "$META" control_relaunch_tx)" != "$RELAUNCH_TX" ] \
      || RELAUNCH_META_PUBLISHED=1
    die "the replacement agent for $ID could not be launched on $TARGET_HARNESS"
  fi

  state=$(wait_agent_state "$LAUNCH_WAIT" alive) || {
    die "the replacement agent for $ID did not come up within ${LAUNCH_WAIT}s (endpoint reads '$state')"
  }
  RELAUNCH_AGENT_CONFIRMED=1

  journal_write complete "${CHECKPOINT_LINES[@]}" "$note_line" "exit_result=$exit_result"
  RELAUNCH_ACTIVE=0
  echo "relaunched $ID harness=$TARGET_HARNESS from=$PRIOR_RECORDED_HARNESS model=$TARGET_MODEL effort=$TARGET_EFFORT backend=$BACKEND endpoint=$T worktree=$WT"
}

# --- guarded compact --------------------------------------------------------
#
# Every attempt leaves one durable line in the mate's status log in this home
# (compact_record): a refusal with its reason, the compaction itself, and the
# recovery verdict, each with the context sizes and checkpoint reference known
# at that point. A reply correlation token is never written into those lines,
# because a corr= token in this log is what resolves a reply expectation.

COMPACT_STATUS="$STATE/$ID.status"
COMPACT_BEFORE=unread
COMPACT_AFTER=none
COMPACT_CHECKPOINT=none
COMPACT_MATE_HOME=
CTX_TOKENS=
CTX_BOUNDARIES=
CTX_POST=
CTX_REASON=

compact_record() {  # <status-head> <text>
  local text
  text=$(printf '%s' "$2" | tr '\n' ' ' | sed 's/corr=/corr:/g')
  printf '%s: context-compact %s\n' "$1" "$text" >> "$COMPACT_STATUS" \
    || echo "warning: the context-compact record could not be appended to $COMPACT_STATUS" >&2
}

compact_sizes() {
  printf 'before=%s after=%s checkpoint=%s' "$COMPACT_BEFORE" "$COMPACT_AFTER" "$COMPACT_CHECKPOINT"
}

# compact_refuse: /compact was not typed; a checkpoint request may already
# have been delivered through the data plane. Exit status 4.
compact_refuse() {  # <reason>
  compact_record "note [at=$(date +%s)]" "refused: $1; $(compact_sizes)"
  echo "compact-refused $ID: $1" >&2
  exit 4
}

# compact_fail: /compact was delivered, and what followed could not be proven.
# The failure is recorded as a keyed blocker - which also keeps every later
# compact refused until it is resolved - and nothing is resumed, restarted, or
# re-dispatched.
compact_fail() {  # <reason>
  compact_record "blocked [at=$(date +%s)] [key=context-compact]" "recovery-failed: $1; $(compact_sizes)"
  die "compaction of $ID was not proven recovered: $1; nothing was resumed or restarted, and the failure is recorded as an open blocker in its status log"
}

# compact_read_context: the mate's current context size from its session's own
# transcript (bin/fm-context-size.sh). Sets CTX_TOKENS, CTX_BOUNDARIES, and
# CTX_POST, or CTX_REASON and returns 1.
compact_read_context() {
  local out rc=0
  CTX_TOKENS=
  CTX_BOUNDARIES=
  CTX_POST=
  CTX_REASON=
  out=$("$SCRIPT_DIR/fm-context-size.sh" --home "$COMPACT_MATE_HOME" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    CTX_REASON=$(printf '%s\n' "$out" | sed -n '/./{s/^error: //;p;q;}')
    [ -n "$CTX_REASON" ] || CTX_REASON="the context-size read failed without a reason"
    return 1
  fi
  CTX_TOKENS=$(printf '%s\n' "$out" | sed -n 's/^tokens=//p')
  CTX_BOUNDARIES=$(printf '%s\n' "$out" | sed -n 's/^boundaries=//p')
  CTX_POST=$(printf '%s\n' "$out" | sed -n 's/^last_boundary_post=//p')
  case "$CTX_TOKENS:$CTX_BOUNDARIES" in
    *[!0-9:]*|:*|*:) CTX_REASON="the context-size read returned no usable size"; return 1 ;;
  esac
}

# compact_idle_verdict: the restart-grade idle read, from the same owner the
# restart pass uses (bin/fm-secondmate-health.sh idle).
compact_idle_verdict() {
  local verdict
  verdict=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-secondmate-health.sh" idle "$ID" 2>/dev/null | head -1) || verdict=
  printf '%s' "${verdict:-unknown unreadable}"
}

compact_guards() {  # <full|final>
  local phase=$1 verdict msg open keys crew_meta crew_id crew_out crew_state
  local crew_backend crew_target crew_agent crew_busy
  for crew_meta in "$COMPACT_MATE_HOME/state"/*.meta; do
    [ -e "$crew_meta" ] || [ -L "$crew_meta" ] || continue
    crew_id=${crew_meta##*/}
    crew_id=${crew_id%.meta}
    crew_out=$(FM_HOME="$COMPACT_MATE_HOME" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
      FM_ROOT_OVERRIDE='' FM_CREW_STATE_NO_FORGE=1 \
      "$SCRIPT_DIR/fm-crew-state.sh" "$crew_id" 2>/dev/null | head -1) || crew_out=
    case "$crew_out" in
      'state: '*) ;;
      *) compact_refuse "the current state of its direct report $crew_id cannot be read" ;;
    esac
    crew_state=${crew_out#state: }
    crew_state=${crew_state%% *}
    case "$crew_state" in
      done|paused|failed) ;;
      working) compact_refuse "its direct report $crew_id is in a running step (${crew_out})" ;;
      parked|blocked) compact_refuse "its direct report $crew_id is waiting on a decision (${crew_out})" ;;
      *) compact_refuse "its direct report $crew_id is not provably inactive (${crew_out})" ;;
    esac
    [ -z "$(fm_meta_get "$crew_meta" remote_host)" ] \
      || compact_refuse "its direct report $crew_id has no locally provable activity state"
    crew_backend=$(fm_backend_of_meta "$crew_meta")
    crew_target=$(fm_backend_target_of_meta "$crew_meta")
    [ -n "$crew_target" ] || compact_refuse "its direct report $crew_id has no recorded endpoint"
    crew_agent=$(fm_backend_agent_state "$crew_backend" "$crew_target" 2>/dev/null) || crew_agent=unknown
    if [ "$crew_agent" = missing ]; then
      crew_agent=$(fm_control_endpoint_absence_verdict "$crew_backend" "$crew_target" "$crew_meta")
      crew_agent=${crew_agent%%$'\t'*}
    fi
    case "$crew_agent" in
      dead|gone) ;;
      alive|unverified)
        crew_busy=$(fm_busy_classify_meta "$crew_meta" "$crew_id" "$COMPACT_MATE_HOME/state") || crew_busy=unknown
        [ "${crew_busy%% *}" = idle ] \
          || compact_refuse "its direct report $crew_id is not provably idle (${crew_busy}) at the $phase check"
        ;;
      *) compact_refuse "its direct report $crew_id activity cannot be established (${crew_agent}) at the $phase check" ;;
    esac
  done
  verdict=$(compact_idle_verdict)
  [ "${verdict%% *}" = idle ] \
    || compact_refuse "it is not provably idle (${verdict})${phase:+ at the $phase check}"
  for msg in "$STATE/$ID.inbox"/*.msg; do
    if [ -e "$msg" ] || [ -L "$msg" ]; then
      compact_refuse "its steering inbox holds an unhandled instruction (${msg##*/}) at the $phase check"
    fi
  done
  open=$(status_open_decisions "$COMPACT_STATUS" "$KIND" 2>/dev/null) \
    || compact_refuse "its open decisions could not be read at the $phase check"
  if [ -n "$open" ]; then
    keys=$(printf '%s\n' "$open" | cut -f1 | paste -sd, -)
    compact_refuse "it has an open decision awaiting acknowledgement (${keys}) at the $phase check"
  fi
  ! fm_pending_reply_task_has_open "$STATE" "$ID" \
    || compact_refuse "an answer it owes to a correlated request is still pending at the $phase check"
  if [ -e "$DATA/handoff/$ID.outbox.md" ] || [ -e "$STATE/.backlog-handoff-$ID.wake-pending" ]; then
    compact_refuse "a backlog handoff to it is still pending at the $phase check"
  fi
  if [ -e "$COMPACT_MATE_HOME/state/.wake-queue" ]; then
    grep -q '[^[:space:]]' "$COMPACT_MATE_HOME/state/.wake-queue" 2>/dev/null \
      && compact_refuse "its own home holds queued notifications it has not handled at the $phase check"
    [ -r "$COMPACT_MATE_HOME/state/.wake-queue" ] \
      || compact_refuse "its own home's notification queue cannot be read at the $phase check"
  fi
}

# compact_checkpoint: the persist request the restart pass sends
# (bin/fm-secondmate-restart-lib.sh), framed for compaction. Refuses unless the
# mate's correlated answer arrives within the shared bound AND affirms
# completeness with checkpoint=complete.
compact_checkpoint() {
  local wait poll answer
  wait=${FM_SECONDMATE_PERSIST_WAIT:-$FM_SECONDMATE_PERSIST_WAIT_DEFAULT}
  poll=${FM_SECONDMATE_PERSIST_POLL:-$FM_SECONDMATE_PERSIST_POLL_DEFAULT}
  case "$wait" in ''|*[!0-9]*) die "FM_SECONDMATE_PERSIST_WAIT must be a non-negative integer: $wait" ;; esac
  case "$poll" in ''|*[!0-9]*|0) die "FM_SECONDMATE_PERSIST_POLL must be a positive integer: $poll" ;; esac
  fm_secondmate_request_send "$FM_HOME" "$STATE" "$ID" "$FM_SECONDMATE_COMPACT_CHECKPOINT_REQUEST" \
    || compact_refuse "the checkpoint request failed: $FM_SECONDMATE_REQUEST_REASON"
  COMPACT_CHECKPOINT="pending-reply:$FM_SECONDMATE_REQUEST_CORR"
  fm_secondmate_request_wait "$STATE" "$FM_SECONDMATE_REQUEST_CORR" "$wait" "$poll" \
    || compact_refuse "it did not answer the checkpoint request within ${wait}s, so its outstanding work is not proven written down"
  answer=$(fm_secondmate_request_answer "$STATE" "$FM_SECONDMATE_REQUEST_CORR")
  if printf '%s\n' "$answer" | grep -Eq '(^|[^A-Za-z0-9_])checkpoint=incomplete([^A-Za-z0-9_-]|$)'; then
    compact_refuse "it reported its checkpoint incomplete, so something is still held only in its conversation"
  fi
  printf '%s\n' "$answer" | grep -Eq '(^|[^A-Za-z0-9_])checkpoint=complete([^A-Za-z0-9_-]|$)' \
    || compact_refuse "its checkpoint answer did not affirm completeness with checkpoint=complete"
}

# compact_settle_idle: the checkpoint answer is written during a turn, so a
# mate still finishing that turn reads busy at first. Re-read it for the shared
# settle window, exactly as the restart pass does; only idle continues.
compact_settle_idle() {
  local settle poll deadline verdict
  settle=${FM_SECONDMATE_IDLE_SETTLE:-$FM_SECONDMATE_IDLE_SETTLE_DEFAULT}
  poll=${FM_SECONDMATE_PERSIST_POLL:-$FM_SECONDMATE_PERSIST_POLL_DEFAULT}
  case "$settle" in ''|*[!0-9]*) die "FM_SECONDMATE_IDLE_SETTLE must be a non-negative integer: $settle" ;; esac
  deadline=$(($(date +%s) + settle))
  while :; do
    verdict=$(compact_idle_verdict)
    case "${verdict%% *}" in
      idle) return 0 ;;
      busy) [ "$(date +%s)" -lt "$deadline" ] \
              || compact_refuse "it was still busy (${verdict}) ${settle}s after answering the checkpoint" ;;
      *) compact_refuse "it is not provably idle after answering the checkpoint (${verdict})" ;;
    esac
    sleep "$poll"
  done
}

# compact_recover: the lightweight recovery check. Nothing here resumes,
# restarts, or re-dispatches anything; a failure stops at compact_fail.
compact_recover() {
  local probe_wait answer state
  probe_wait=${FM_CONTROL_COMPACT_PROBE_WAIT:-300}
  case "$probe_wait" in ''|*[!0-9]*) compact_fail "FM_CONTROL_COMPACT_PROBE_WAIT is not a non-negative integer" ;; esac
  state=$(agent_state)
  [ "$state" = alive ] || compact_fail "its agent reads '$state' after compaction rather than running"
  fm_secondmate_request_send "$FM_HOME" "$STATE" "$ID" "$FM_SECONDMATE_COMPACT_PROBE_REQUEST" \
    || compact_fail "the recovery probe failed: $FM_SECONDMATE_REQUEST_REASON"
  fm_secondmate_request_wait "$STATE" "$FM_SECONDMATE_REQUEST_CORR" "$probe_wait" \
    "${FM_SECONDMATE_PERSIST_POLL:-$FM_SECONDMATE_PERSIST_POLL_DEFAULT}" \
    || compact_fail "it did not answer the read-only recovery probe within ${probe_wait}s"
  answer=$(fm_secondmate_request_answer "$STATE" "$FM_SECONDMATE_REQUEST_CORR")
  printf '%s\n' "$answer" | grep -Eq '(^|[^A-Za-z0-9_])records=unreadable([^A-Za-z0-9_-]|$)' \
    && compact_fail "it reported that its outstanding work cannot be read back from its durable records"
  printf '%s\n' "$answer" | grep -Eq '(^|[^A-Za-z0-9_])role=secondmate([^A-Za-z0-9_-]|$)' \
    || compact_fail "its probe answer does not show its second mate role"
  printf '%s\n' "$answer" | grep -Eq "(^|[^A-Za-z0-9_])id=${ID//./\\.}([^A-Za-z0-9._-]|\$)" \
    || compact_fail "its probe answer does not name its own charter id $ID"
  printf '%s\n' "$answer" | grep -Eq '(^|[^A-Za-z0-9_])records=readable([^A-Za-z0-9_-]|$)' \
    || compact_fail "its probe answer does not confirm its outstanding work reads back from its durable records"
  compact_read_context || compact_fail "its context size could not be re-read after the probe: $CTX_REASON"
  [ "$CTX_TOKENS" -lt "$COMPACT_BEFORE" ] \
    || compact_fail "its context reads $CTX_TOKENS tokens after the probe, not below the $COMPACT_BEFORE it held before"
}

do_compact() {
  local marker cmd verdict wait poll deadline boundaries_before composer_state
  [ "$KIND" = secondmate ] \
    || die "task $ID is a $KIND task; compact applies to a second mate only, and never to a crew, a scout, or the primary itself"
  fm_control_compact_supported "$HARNESS" \
    || compact_refuse "its worker runtime '${RECORDED_HARNESS:-none}' has no verified context-size read, idle proof, and in-place compaction; only claude has all three"
  fm_control_backend_state_verified "$BACKEND" \
    || compact_refuse "it runs on the $BACKEND backend, which cannot prove its agent is still running after compaction"
  COMPACT_MATE_HOME=$(fm_meta_get "$META" home)
  [ -n "$COMPACT_MATE_HOME" ] || COMPACT_MATE_HOME=$WT
  marker=$(cat "$COMPACT_MATE_HOME/.fm-secondmate-home" 2>/dev/null || true)
  [ "$marker" = "$ID" ] \
    || compact_refuse "its home '${COMPACT_MATE_HOME:-none}' is not marked as its own seeded second mate home"

  # 1. Eligibility: over the threshold, from a structured read only.
  compact_read_context || compact_refuse "its context size cannot be read: $CTX_REASON"
  COMPACT_BEFORE=$CTX_TOKENS
  [ "$CTX_TOKENS" -gt 400000 ] \
    || compact_refuse "its context is $CTX_TOKENS tokens, not over the 400000 eligibility threshold"

  # 2-4. Restart-grade idle, and nothing in flight toward or under it.
  compact_guards full

  # 5-6. Checkpoint whatever lives only in conversation, or do not compact.
  compact_checkpoint
  compact_settle_idle

  # 3. Re-check immediately before the keystroke; never rely on an earlier read.
  [ "$(agent_state)" = alive ] || compact_refuse "its agent is not running at the final check"
  composer_state=$(fm_backend_composer_state "$BACKEND" "$T" "$LABEL" 2>/dev/null) || composer_state=unknown
  [ "$composer_state" = empty ] \
    || compact_refuse "its composer is '$composer_state', not proven empty, so /compact could concatenate onto existing text"
  compact_read_context || compact_refuse "its context size cannot be re-read at the final check: $CTX_REASON"
  COMPACT_BEFORE=$CTX_TOKENS
  boundaries_before=$CTX_BOUNDARIES

  # Deliver through the control plane's verified keystroke path, never fm-send.
  cmd=$(fm_control_compact_command "$HARNESS")
  compact_guards final
  verdict=$(fm_backend_send_text_submit "$BACKEND" "$T" "$cmd" "$EXIT_RETRIES" "$POLL" 1.2 "$LABEL") \
    || compact_fail "the $cmd command could not be sent on $BACKEND"
  [ "$verdict" != send-failed ] || compact_fail "the $cmd command could not be sent on $BACKEND"

  # The session's own transcript records completion as a new compact_boundary.
  wait=${FM_CONTROL_COMPACT_WAIT:-600}
  poll=${FM_CONTROL_COMPACT_POLL:-5}
  case "$wait" in ''|*[!0-9]*) compact_fail "FM_CONTROL_COMPACT_WAIT is not a non-negative integer" ;; esac
  deadline=$(($(date +%s) + wait))
  while :; do
    if compact_read_context && [ "$CTX_BOUNDARIES" -gt "$boundaries_before" ]; then
      break
    fi
    [ "$(date +%s)" -lt "$deadline" ] \
      || compact_fail "no completed compaction was recorded in its session transcript within ${wait}s${CTX_REASON:+ ($CTX_REASON)}"
    sleep "$poll"
  done
  COMPACT_AFTER=${CTX_POST:-$CTX_TOKENS}
  [ "$COMPACT_AFTER" -lt "$COMPACT_BEFORE" ] \
    || compact_fail "its context reads $COMPACT_AFTER tokens after compaction, not below the $COMPACT_BEFORE it held before"
  compact_record "note [at=$(date +%s)]" "compacted: $(compact_sizes)"

  compact_recover
  compact_record "note [at=$(date +%s)]" "recovery-ok: $(compact_sizes)"
  echo "compacted $ID before=$COMPACT_BEFORE after=$COMPACT_AFTER checkpoint=$COMPACT_CHECKPOINT recovery=ok harness=$HARNESS backend=$BACKEND"
}

# --- verbs ------------------------------------------------------------------

case "$VERB" in
  interrupt)
    state=$(agent_state)
    case "$state" in
      alive) ;;
      unverified)
        # No recovery-grade classifier on this backend. Interrupt is
        # non-destructive and its endpoint-existence postcondition is still
        # real, so it proceeds - the printed proof names exactly what was
        # verified rather than implying more.
        ;;
      dead|missing) die "no agent is running at task $ID's recorded endpoint (state: $state); there is nothing to interrupt" ;;
      *) die "task $ID's endpoint reads '$state' rather than a positively classified state; refusing to send a lifecycle key into an unattributed endpoint" ;;
    esac
    proof=$(do_interrupt)
    echo "interrupt-delivered $ID harness=$HARNESS backend=$BACKEND verified=$proof"
    ;;
  exit)
    result=$(do_exit)
    echo "$result $ID harness=$HARNESS backend=$BACKEND endpoint=$T worktree=$WT"
    ;;
  stand-down)
    do_stand_down
    ;;
  relaunch)
    do_relaunch
    ;;
  compact)
    do_compact
    ;;
esac
