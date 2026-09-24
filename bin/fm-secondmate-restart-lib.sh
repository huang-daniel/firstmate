# shellcheck shell=bash disable=SC2034
# fm-secondmate-restart-lib.sh - the shared contract for restarting a second
# mate onto the current instruction surface and launch-time wiring. Source only.
#
# Two consumers, one owner:
#   - bin/fm-update.sh decides WHICH live mates belong in the restart set, so it
#     needs the capability test before it prints its action lines.
#   - bin/fm-secondmate-restart.sh performs the pass, so it needs the same test
#     again on its own argv rather than trusting a caller's list.
# The persist checkpoint below (the request, its correlated send, its wait
# bounds, and the answer read) is shared with a third consumer,
# bin/fm-control.sh's guarded `compact` verb, which spends a mate's
# conversation in place instead of replacing the agent.
#
# The capability test is the pre-stop half of the control plane's own refusals
# (bin/fm-control-lib.sh owns those tables): a mate whose recorded backend has
# no recovery-grade agent-state classifier, or whose harness has no verified
# control mechanics, can never have "the old agent stopped and the replacement
# came up" proven for it. Asking here keeps that verdict on the side of the
# transaction where nothing has been touched yet, so an incapable mate is routed
# to the ordinary re-read nudge instead of being stopped for a launch that must
# be refused.
#
# Placement is resolved from the same remote_host= signal bin/fm-send.sh routes
# on, and it changes only the transport: the restart itself is bin/fm-control.sh
# <id> relaunch either way, run here for a local mate and run on the host over
# bin/fm-on.sh for a remote one.

_FM_SECONDMATE_RESTART_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-backend.sh disable=SC1091
. "$_FM_SECONDMATE_RESTART_LIB_DIR/fm-backend.sh"
# shellcheck source=bin/fm-control-lib.sh disable=SC1091
. "$_FM_SECONDMATE_RESTART_LIB_DIR/fm-control-lib.sh"

# The persist request the primary sends before anything spends a mate's
# conversation. It is the open-record half of /stow and nothing more: the
# conversation's loss needs the state of work written down, not a memory
# curation pass, and bundling one would make every restart or compaction cost
# far more than the reload it is paying for. FM_SECONDMATE_PERSIST_CORE is that
# shared checkpoint ask; each caller frames it with why the conversation is
# about to be spent and what its answer must say.
# The mate answers through its parent channel, which is what resolves the
# parent-owned reply expectation fm-send arms for a marked request; that
# correlated answer, never the wall clock, is what releases the next step.
FM_SECONDMATE_PERSIST_CORE='persist the open work you are holding only in this conversation, following the /stow skill'"'"'s "Open-record persistence" section and nothing else from that skill: file a task for each open record that exists only in this conversation, including any captain call you had formed but never registered, and correct any task whose status no longer reflects what you now know. Do NOT run the memory, learnings, or captain-preference sweeps.'

# The restart pass (bin/fm-secondmate-restart.sh) sends this one.
FM_SECONDMATE_PERSIST_REQUEST="Firstmate was updated and I am about to restart your agent so it comes up on the current instructions and launch-time settings, which drops your conversation but keeps every durable record. Before that, $FM_SECONDMATE_PERSIST_CORE Then reply on your parent channel saying it is done, or saying what you deliberately left alone and why."

# The guarded compaction (bin/fm-control.sh <id> compact) sends this one. Its
# answer must AFFIRM completeness with the exact checkpoint=complete token:
# anything else, including checkpoint=incomplete, refuses the compaction.
FM_SECONDMATE_COMPACT_CHECKPOINT_REQUEST="I am about to compact your conversation with /compact to reduce its context size. Your session keeps running, but everything above is replaced by a summary, so nothing operationally important may exist only in this conversation. Before that, $FM_SECONDMATE_PERSIST_CORE Also make sure your normal durable records name the outstanding work, decisions, ownership, blockers, and next action for everything you hold. Then reply on your parent channel with one line containing checkpoint=complete when all of it is written down, or checkpoint=incomplete and what is still held only in conversation and why."

# The guarded compaction's read-only recovery probe, sent once the compaction
# is recorded. Its answer must carry role=secondmate, the mate's own id=, and
# records=readable; bin/fm-control.sh owns that check.
FM_SECONDMATE_COMPACT_PROBE_REQUEST="Context check after your conversation was compacted. This is read-only: change nothing and start no new work. From your durable records alone (your charter, backlog, status logs, open decisions, and steering inbox), reply on your parent channel with one line containing role=secondmate id=<your second mate id> records=readable and a short count of the outstanding work those records show, or records=unreadable and what you could not read."

# The bounds every persist wait shares. Callers read their environment knobs
# (FM_SECONDMATE_PERSIST_WAIT, FM_SECONDMATE_PERSIST_POLL,
# FM_SECONDMATE_IDLE_SETTLE; bin/fm-secondmate-restart.sh documents them) and
# fall back to these.
FM_SECONDMATE_PERSIST_WAIT_DEFAULT=900
FM_SECONDMATE_PERSIST_POLL_DEFAULT=5
FM_SECONDMATE_IDLE_SETTLE_DEFAULT=120

# Send one correlated, reply-bearing marked request to a LOCAL or remote mate
# through the ordinary data plane (bin/fm-send.sh), with the parent-owned reply
# expectation armed before delivery exactly as fm-send's own contract requires.
# Requires bin/fm-pending-reply-lib.sh to be sourced by the caller.
# Publishes FM_SECONDMATE_REQUEST_CORR on success; on failure publishes
# FM_SECONDMATE_REQUEST_REASON (one readable line) and discards the
# never-delivered expectation so nothing is left waiting on it.
FM_SECONDMATE_REQUEST_CORR=""
FM_SECONDMATE_REQUEST_REASON=""
fm_secondmate_request_send() {  # <parent-home> <state-dir> <id> <request-text>
  local home=$1 state=$2 id=$3 text=$4 corr send_out
  FM_SECONDMATE_REQUEST_CORR=""
  FM_SECONDMATE_REQUEST_REASON=""
  if ! corr=$(fm_pending_reply_create "$home" "$state" "$id" "$text"); then
    FM_SECONDMATE_REQUEST_REASON="its answer cannot be tracked"
    return 1
  fi
  if ! send_out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_PENDING_REPLY_EXISTING_CORR="$corr" \
    "$_FM_SECONDMATE_RESTART_LIB_DIR/fm-send.sh" "$id" "$text" 2>&1); then
    fm_pending_reply_discard_undelivered "$state" "$corr" >/dev/null 2>&1 || true
    FM_SECONDMATE_REQUEST_REASON="the request could not be delivered: $(printf '%s\n' "$send_out" \
      | sed -n '/./{s/^error: //;s/[[:space:]]\{1,\}/ /g;p;q;}')"
    return 1
  fi
  FM_SECONDMATE_REQUEST_CORR=$corr
  return 0
}

# Wait, polling, until the correlated answer to <corr> lands or <wait> seconds
# pass. 0 once the expectation resolved; 1 at the bound, leaving an unanswered
# expectation open for the ordinary pending-reply recovery ladder rather than
# closing it here. Requires bin/fm-pending-reply-lib.sh.
fm_secondmate_request_wait() {  # <state-dir> <corr> <wait-seconds> <poll-seconds>
  local state=$1 corr=$2 wait=$3 poll=$4 deadline
  deadline=$(($(date +%s) + wait))
  while :; do
    fm_pending_reply_try_resolve "$state" "$corr" && return 0
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep "$poll"
  done
  # A reply can land during the last sleep; it wins over the bound.
  fm_pending_reply_try_resolve "$state" "$corr"
}

# The parent status line that answered <corr>, or nothing. Requires
# bin/fm-pending-reply-lib.sh.
fm_secondmate_request_answer() {  # <state-dir> <corr>
  local state=$1 corr=$2 rec
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 0
  fm_pending_reply_find_resolve_line "$(fm_pending_reply_get "$rec" parent_status)" "$corr"
}

# Resolve one mate's restart capability from its durable record alone.
# Publishes, on success:
#   FM_SECONDMATE_RESTART_PLACEMENT  local|remote
#   FM_SECONDMATE_RESTART_BACKEND    the backend whose classifier must prove the stop
#   FM_SECONDMATE_RESTART_HARNESS    the verified control adapter it runs on
#   FM_SECONDMATE_RESTART_HOST       the configured host (remote placement only)
# and on failure sets FM_SECONDMATE_RESTART_REASON to one operator-readable line.
FM_SECONDMATE_RESTART_PLACEMENT=""
FM_SECONDMATE_RESTART_BACKEND=""
FM_SECONDMATE_RESTART_HARNESS=""
FM_SECONDMATE_RESTART_HOST=""
FM_SECONDMATE_RESTART_REASON=""
fm_secondmate_restart_capable() {  # <meta-file>
  local meta=$1 kind window remote_host backend harness family
  FM_SECONDMATE_RESTART_PLACEMENT=""
  FM_SECONDMATE_RESTART_BACKEND=""
  FM_SECONDMATE_RESTART_HARNESS=""
  FM_SECONDMATE_RESTART_HOST=""
  FM_SECONDMATE_RESTART_REASON=""

  if [ ! -f "$meta" ] || [ -L "$meta" ]; then
    FM_SECONDMATE_RESTART_REASON="no durable record for this second mate in this home"
    return 1
  fi
  kind=$(fm_meta_get "$meta" kind)
  if [ "$kind" != secondmate ]; then
    FM_SECONDMATE_RESTART_REASON="the durable record is not a second mate's"
    return 1
  fi
  window=$(fm_meta_get "$meta" window)
  if [ -z "$window" ]; then
    FM_SECONDMATE_RESTART_REASON="the durable record names no endpoint, so there is no agent to replace"
    return 1
  fi
  harness=$(fm_meta_get "$meta" harness)
  remote_host=$(fm_meta_get "$meta" remote_host)
  if [ -n "$remote_host" ]; then
    FM_SECONDMATE_RESTART_PLACEMENT=remote
    FM_SECONDMATE_RESTART_HOST=$remote_host
    # A remote mate's endpoint record lives on its host; the parent's own record
    # names the backend that launch established there, and the remote route
    # accepts nothing but herdr.
    backend=$(fm_meta_get "$meta" remote_backend)
    [ -n "$backend" ] || backend=herdr
  else
    FM_SECONDMATE_RESTART_PLACEMENT=local
    backend=$(fm_backend_of_meta "$meta")
  fi
  FM_SECONDMATE_RESTART_BACKEND=$backend
  if ! fm_control_backend_state_verified "$backend"; then
    FM_SECONDMATE_RESTART_REASON="its runtime cannot prove an agent stopped and came back (backend $backend)"
    return 1
  fi
  if ! family=$(fm_control_harness_family "$harness") \
    || ! fm_control_harness_supported "$family" \
    || ! fm_control_harness_supports_kind "$family" secondmate; then
    FM_SECONDMATE_RESTART_REASON="its worker runtime '${harness:-none}' has no verified restart mechanics for a second mate"
    return 1
  fi
  FM_SECONDMATE_RESTART_HARNESS=$family
  return 0
}
