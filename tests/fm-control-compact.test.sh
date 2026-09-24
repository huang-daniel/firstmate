#!/usr/bin/env bash
# bin/fm-control.sh <id> compact: the guarded, in-place context compaction of a
# second mate, and bin/fm-context-size.sh, the read it is built on.
#
# What these pin, through the real commands (real fm-control, real fm-send,
# real durable steering inbox, real parent-owned reply expectation, real busy
# record, real crew-state read) against a session-provider stub that models a
# live Claude mate: it answers the checkpoint request and the recovery probe on
# its parent channel with the correlation each request carried, acknowledges
# its inbox, and - when /compact is typed - appends the compact_boundary entry
# Claude writes into the session transcript.
#
#   1. The context read is structured: the lock holder's recorded session id
#      names exactly one transcript, the size is the latest main-chain usage
#      after the last compaction boundary, and anything unprovable refuses.
#   2. A guarded compaction of an idle mate over the threshold checkpoints
#      first, types /compact through the control plane (never the steering
#      inbox), proves the compaction from the transcript, runs the read-only
#      recovery probe, and records every step with sizes and the checkpoint.
#   3. Every guard refuses with nothing typed and a recorded reason: below the
#      threshold, unreadable size, not idle, unhandled instruction, open
#      decision, owed reply, pending handoff, queued notification, a direct
#      report in a running step or waiting on a decision, an unverified
#      harness, and a crew target.
#   4. The checkpoint is a gate: no answer, an incomplete answer, or an answer
#      that does not affirm completeness refuses.
#   5. Re-check before send: a mate that stays busy after the checkpoint, or
#      that receives an instruction or opens a decision during it, is refused
#      at the final check with /compact never typed.
#   6. Recovery failure stops there: no compaction recorded, a probe that is
#      not answered or does not show role, id, and readable records, or a
#      context that did not drop is recorded as an open blocker, nothing is
#      resumed, and that blocker keeps a later compaction refused.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONTROL="$ROOT/bin/fm-control.sh"
CONTEXT="$ROOT/bin/fm-context-size.sh"
SID=11111111-2222-3333-4444-555555555555

fm_git_identity fmtest fmtest@example.com
TMP_ROOT=$(fm_test_tmproot fm-control-compact)
kill_fake_sessions() {
  local f pid
  for f in "$TMP_ROOT"/*/fake/pids; do
    [ -f "$f" ] || continue
    while IFS= read -r pid; do kill "$pid" 2>/dev/null || true; done < "$f"
  done
}
trap 'kill_fake_sessions; fm_test_cleanup' EXIT

# The stub session provider. It models the live mate in window fm-<id>.
make_stub() {  # <case-dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
usage_line() {  # <tokens>
  printf '{"type":"assistant","isSidechain":false,"message":{"model":"claude-test","usage":{"input_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}\n' "$1"
}
answer() {  # <mate> <template-file> <default-template> <corr>
  local tpl
  if [ -f "$2" ]; then tpl=$(cat "$2"); else tpl=$3; fi
  # shellcheck disable=SC2059
  printf "$tpl\n" "$4" >> "$FM_HOME/state/$1.status"
}
case "${1:-}" in
  send-keys)
    shift
    literal=0
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" != 1 ]; then
      printf '%s\n' "$payload" >> "$D/keys"
      exit 0
    fi
    printf '%s\n' "$payload" >> "$D/literal"
    win=${target##*:}; win=${win#=}; mate=${win#fm-}
    case "$payload" in
      /compact)
        [ -e "$D/no-compact" ] && exit 0
        printf '{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"manual","preTokens":%s,"postTokens":%s}}\n' \
          "$(cat "$D/tokens")" "$(cat "$D/post-tokens")" >> "$D/transcript"
        ;;
      ': Firstmate instruction waiting: list '*)
        inbox="$FM_HOME/state/$mate.inbox"
        for msg in "$inbox"/*.msg; do
          [ -f "$msg" ] || continue
          corr=$(grep -oE 'corr=[0-9a-f]{16}' "$msg" | head -1)
          if grep -q 'Open-record persistence' "$msg"; then
            printf 'checkpoint\n' >> "$D/requests"
            [ -e "$D/no-checkpoint-answer" ] \
              || answer "$mate" "$D/checkpoint-answer" 'done [%s]: open work written down; checkpoint=complete' "$corr"
            [ ! -x "$D/after-checkpoint" ] || "$D/after-checkpoint"
          elif grep -q 'Context check after your conversation was compacted' "$msg"; then
            printf 'probe\n' >> "$D/requests"
            usage_line "$(cat "$D/probe-tokens")" >> "$D/transcript"
            [ -e "$D/no-probe-answer" ] \
              || answer "$mate" "$D/probe-answer" "done [%s]: role=secondmate id=$mate records=readable outstanding=2" "$corr"
          fi
          [ -e "$D/no-ack" ] || { mkdir -p "$inbox/handled"; mv "$msg" "$inbox/handled/"; }
        done
        ;;
    esac
    exit 0 ;;
  display-message)
    target=
    prev=
    for a in "$@"; do
      if [ "$prev" = -t ]; then target=$a; fi
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) printf 'claude\n'; exit 0 ;;
        *pane_current_path*)
          win=${target##*:}; win=${win#=}
          if [ -f "$D/home.$win" ]; then cat "$D/home.$win"; else printf '/\n'; fi
          exit 0 ;;
      esac
      prev=$a
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
/bin/sleep 0.01
SH
  chmod +x "$fb/sleep"
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = axi ] && [ -f "$FM_FAKE_DIR/completed-run" ]; then
  cat "$FM_FAKE_DIR/completed-run"
  exit 0
fi
exit 1
SH
  chmod +x "$fb/no-mistakes"
}

# new_case <name> [harness] [kind] [tokens]: a parent home holding one live
# local second mate sm1 whose Claude session's transcript reads <tokens>.
new_case() {
  local name=$1 harness=${2:-claude} kind=${3:-secondmate} tokens=${4:-450000}
  local dir="$TMP_ROOT/$name-$RANDOM" home smhome pid
  home="$dir/home"
  smhome="$dir/sm1-home"
  mkdir -p "$home/state" "$home/data/sm1" "$home/config" "$dir/fake"
  printf 'claude\n' > "$home/config/secondmate-harness"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  : > "$dir/fake/requests"
  printf '%s' "$tokens" > "$dir/fake/tokens"
  printf '20000' > "$dir/fake/post-tokens"
  printf '30000' > "$dir/fake/probe-tokens"
  make_stub "$dir"
  fm_git_worktree "$dir/sm1-repo" "$smhome" sm-sm1
  mkdir -p "$smhome/state" "$smhome/data"
  printf 'sm1\n' > "$smhome/.fm-secondmate-home"
  printf '# charter\n' > "$home/data/sm1/brief.md"
  {
    echo "window=fmses:fm-sm1"
    echo "endpoint_task_id=sm1"
    echo "worktree=$smhome"
    echo "project=$smhome"
    echo "harness=$harness"
    echo "kind=$kind"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$smhome"
  } > "$home/state/sm1.meta"
  printf 'fm-sm1\n' > "$dir/fake/windows"
  printf '%s' "$smhome" > "$dir/fake/home.fm-sm1"
  "$ROOT/bin/fm-busy-event.sh" arm "$home/state" sm1 --state idle \
    --source claude-hook --event test >/dev/null
  # The mate's live Claude session: a process whose argv[0] is claude holds
  # its home lock beside the recorded conversation id, and that id names the
  # one transcript under the Claude config dir.
  bash -c 'exec -a claude "$0" 600' "$(command -v sleep)" </dev/null >/dev/null 2>&1 &
  pid=$!
  printf '%s\n' "$pid" >> "$dir/fake/pids"
  printf '%s\n' "$pid" > "$smhome/state/.lock"
  printf '%s\n' "$SID" > "$smhome/state/.lock-session"
  mkdir -p "$dir/claude/projects/-sm1-home"
  ln -s "$dir/claude/projects/-sm1-home/$SID.jsonl" "$dir/fake/transcript"
  {
    printf '{"type":"user","message":{"content":"hello"}}\n'
    printf '{"type":"assistant","isSidechain":false,"message":{"model":"claude-test","usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":%s,"output_tokens":0}}}\n' "$((tokens - 10))"
  } > "$dir/claude/projects/-sm1-home/$SID.jsonl"
  printf '%s\n' "$dir"
}

run_compact() {  # <case-dir>
  local dir=$1
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    CLAUDE_CONFIG_DIR="$dir/claude" FM_SPAWN_NO_GUARD=1 \
    FM_SECONDMATE_PERSIST_POLL=1 FM_SECONDMATE_PERSIST_WAIT="${FM_TEST_PERSIST_WAIT:-30}" \
    FM_SECONDMATE_IDLE_SETTLE=0 FM_CONTROL_POLL=0.01 \
    FM_CONTROL_COMPACT_POLL=1 FM_CONTROL_COMPACT_WAIT="${FM_TEST_COMPACT_WAIT:-30}" \
    FM_CONTROL_COMPACT_PROBE_WAIT="${FM_TEST_PROBE_WAIT:-30}" \
    "$CONTROL" sm1 compact 2>&1
}

status_of() { cat "$1/home/state/sm1.status" 2>/dev/null; }

assert_not_typed() {  # <case-dir> <why>
  ! grep -qx '/compact' "$1/fake/literal" || fail "$2"
}

assert_refused() {  # <case-dir> <out> <rc> <reason-fragment> <label>
  local dir=$1 out=$2 rc=$3 reason=$4 label=$5
  expect_code 4 "$rc" "$label: a refusal must exit 4"$'\n'"$out"
  assert_contains "$out" "compact-refused sm1:" "$label: the refusal must be named"
  assert_contains "$out" "$reason" "$label: the refusal must say why"
  assert_not_typed "$dir" "$label: /compact was typed into a session that failed a guard"
  grep '^note \[at=[0-9]*\]: context-compact refused: ' "$dir/home/state/sm1.status" 2>/dev/null \
    | grep -qF -- "$reason" || fail "$label: the refusal must be recorded in the mate's status log"
}

# --- C1: the structured context read ----------------------------------------
test_context_size_read() {
  local dir out rc
  dir=$(new_case ctx)
  out=$(CLAUDE_CONFIG_DIR="$dir/claude" "$CONTEXT" --home "$dir/sm1-home" 2>&1); rc=$?
  expect_code 0 "$rc" "a live Claude lock holder's transcript must be readable"$'\n'"$out"
  assert_contains "$out" "tokens=450000" "the size must be the latest usage"
  assert_contains "$out" "source=usage" "the size must name its source"
  assert_contains "$out" "session=$SID" "the read must name the session it read"

  # A sidechain turn, an API-error turn, and a torn last line do not count.
  {
    printf '{"type":"assistant","isSidechain":true,"message":{"model":"claude-test","usage":{"input_tokens":5}}}\n'
    printf '{"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","usage":{"input_tokens":0}}}\n'
    printf '{"type":"assistant","isSidechain":false,"mess'
  } >> "$dir/fake/transcript"
  out=$(CLAUDE_CONFIG_DIR="$dir/claude" "$CONTEXT" --home "$dir/sm1-home" 2>&1)
  assert_contains "$out" "tokens=450000" "sidechain, synthetic, and torn lines must not change the size"

  # After a boundary with no later turn, the boundary's own post size answers.
  printf '\n{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"manual","preTokens":450000,"postTokens":21000}}\n' \
    >> "$dir/fake/transcript"
  out=$(CLAUDE_CONFIG_DIR="$dir/claude" "$CONTEXT" --home "$dir/sm1-home" 2>&1)
  assert_contains "$out" "tokens=21000" "a boundary with no later turn must report its post size"
  assert_contains "$out" "boundaries=1" "the boundary must be counted"
  assert_contains "$out" "source=compact-boundary" "the boundary must be named as the source"

  # Disagreeing session ids refuse rather than pick one.
  mkdir -p "$dir/claude/sessions"
  printf '{"sessionId":"99999999-2222-3333-4444-555555555555"}\n' \
    > "$dir/claude/sessions/$(cat "$dir/sm1-home/state/.lock").json"
  out=$(CLAUDE_CONFIG_DIR="$dir/claude" "$CONTEXT" --home "$dir/sm1-home" 2>&1); rc=$?
  expect_code 1 "$rc" "disagreeing session ids must refuse"$'\n'"$out"
  assert_not_contains "$out" "tokens=" "a refused read must print no size"
  rm -f "$dir/claude/sessions"/*.json

  # A dead lock holder is no session at all.
  printf '999999\n' > "$dir/sm1-home/state/.lock"
  out=$(CLAUDE_CONFIG_DIR="$dir/claude" "$CONTEXT" --home "$dir/sm1-home" 2>&1); rc=$?
  expect_code 1 "$rc" "a dead lock holder must refuse"$'\n'"$out"
  pass "C1 the context size is read from the session transcript, and unprovable reads refuse"
}

# --- C2: the guarded happy path ----------------------------------------------
test_compaction_happy_path() {
  local dir out rc status checkpoint_line compact_line probe_line
  dir=$(new_case happy)
  out=$(run_compact "$dir"); rc=$?
  expect_code 0 "$rc" "an idle mate over the threshold should compact"$'\n'"$out"
  assert_contains "$out" "compacted sm1 before=450000 after=20000 checkpoint=pending-reply:" \
    "the outcome must carry the sizes and the checkpoint reference"
  assert_contains "$out" "recovery=ok" "the outcome must report the recovery check"
  [ "$(grep -c '^/compact$' "$dir/fake/literal")" -eq 1 ] \
    || fail "/compact must be typed exactly once"
  # /compact goes through the control plane, never the steering inbox.
  if grep -rqx '/compact' "$dir/home/state/sm1.inbox"; then
    fail "/compact was delivered through the steering inbox"
  fi
  # Checkpoint first, then /compact, then the probe.
  assert_equals $'checkpoint\nprobe' "$(cat "$dir/fake/requests")" "the mate must get the checkpoint, then the probe"
  checkpoint_line=$(grep -n '^: Firstmate instruction waiting: ' "$dir/fake/literal" | head -1 | cut -d: -f1)
  compact_line=$(grep -n '^/compact$' "$dir/fake/literal" | cut -d: -f1)
  probe_line=$(grep -n '^: Firstmate instruction waiting: ' "$dir/fake/literal" | tail -1 | cut -d: -f1)
  [ "$checkpoint_line" -lt "$compact_line" ] && [ "$compact_line" -lt "$probe_line" ] \
    || fail "the order must be checkpoint ($checkpoint_line), /compact ($compact_line), probe ($probe_line)"
  status=$(status_of "$dir")
  assert_contains "$status" "context-compact compacted: before=450000 after=20000 checkpoint=pending-reply:" \
    "the compaction must be recorded with its sizes and checkpoint"
  assert_contains "$status" "context-compact recovery-ok: before=450000 after=20000" \
    "the recovery verdict must be recorded"
  assert_not_contains "$(grep 'context-compact' "$dir/home/state/sm1.status")" "corr=" \
    "a record line must never carry a reply correlation token"
  pass "C2 an idle mate over the threshold is checkpointed, compacted, probed, and recorded"
}

# --- C3: every guard refuses with nothing typed ------------------------------
test_below_threshold_refuses() {
  local dir out rc
  dir=$(new_case below claude secondmate 400000)
  out=$(run_compact "$dir"); rc=$?
  assert_refused "$dir" "$out" "$rc" "not over the 400000 eligibility threshold" below
  [ ! -s "$dir/fake/requests" ] || fail "a mate below the threshold must not be asked to checkpoint"
  pass "C3a a session at or below 400k is not eligible"
}

test_unreadable_size_refuses() {
  local dir out rc
  dir=$(new_case unreadable)
  rm -f "$dir/claude/projects/-sm1-home/$SID.jsonl"
  out=$(run_compact "$dir"); rc=$?
  assert_refused "$dir" "$out" "$rc" "context size cannot be read" unreadable
  pass "C3b an unreadable context size refuses"
}

test_busy_refuses() {
  local dir out rc
  dir=$(new_case busy)
  "$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" sm1 --state busy \
    --source claude-hook --event test >/dev/null
  out=$(run_compact "$dir"); rc=$?
  assert_refused "$dir" "$out" "$rc" "not provably idle (busy claude-hook)" busy
  [ ! -s "$dir/fake/requests" ] || fail "a busy mate must not be asked to checkpoint"
  pass "C3c a mate that is not provably idle refuses"
}

test_unhandled_instruction_refuses() {
  local dir out rc
  dir=$(new_case inbox)
  mkdir -p "$dir/home/state/sm1.inbox/handled"
  printf 'schema=fm-task-inbox.v1\n--\npending steer\n' > "$dir/home/state/sm1.inbox/001.msg"
  out=$(run_compact "$dir"); rc=$?
  assert_refused "$dir" "$out" "$rc" "unhandled instruction (001.msg)" inbox
  pass "C3d an unhandled steering instruction refuses"
}

test_open_decision_refuses() {
  local dir out rc
  dir=$(new_case decision)
  printf 'needs-decision [at=1] [key=pick-one]: which way\n' > "$dir/home/state/sm1.status"
  out=$(run_compact "$dir"); rc=$?
  assert_refused "$dir" "$out" "$rc" "open decision awaiting acknowledgement (pick-one)" decision
  pass "C3e an open keyed decision refuses"
}

test_owed_reply_refuses() {
  local dir out rc
  dir=$(new_case owed)
  # shellcheck disable=SC2016  # expanded by the inner shell
  bash -c '. "$1/bin/fm-pending-reply-lib.sh" && fm_pending_reply_create "$2" "$2/state" sm1 "an earlier request"' \
    _ "$ROOT" "$dir/home" >/dev/null || fail "could not arm the owed reply"
  out=$(run_compact "$dir"); rc=$?
  assert_refused "$dir" "$out" "$rc" "answer it owes to a correlated request is still pending" owed
  pass "C3f an answer the mate still owes refuses"
}

test_pending_handoff_refuses() {
  local dir out rc
  dir=$(new_case handoff)
  mkdir -p "$dir/home/data/handoff"
  printf -- '- [ ] item\n' > "$dir/home/data/handoff/sm1.outbox.md"
  out=$(run_compact "$dir"); rc=$?
  assert_refused "$dir" "$out" "$rc" "backlog handoff to it is still pending" handoff
  pass "C3g a pending backlog handoff refuses"
}

test_queued_notification_refuses() {
  local dir out rc
  dir=$(new_case wakeq)
  printf '1\t1\tsignal\tc1\tpayload\n' > "$dir/sm1-home/state/.wake-queue"
  out=$(run_compact "$dir"); rc=$?
  assert_refused "$dir" "$out" "$rc" "queued notifications it has not handled" wakeq
  pass "C3h a notification queued in the mate's own home refuses"
}

# add_crew <case-dir> <crew-id> <busy|idle> [status-line]: a direct report of
# the mate, recorded in the mate's own home.
add_crew() {
  local dir=$1 cid=$2 busy=$3 line=${4:-} wt
  wt="$dir/$cid-wt"
  mkdir -p "$wt"
  {
    echo "window=fmses:fm-$cid"
    echo "endpoint_task_id=$cid"
    echo "worktree=$wt"
    echo "project=$wt"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=direct-PR"
  } > "$dir/sm1-home/state/$cid.meta"
  printf 'fm-%s\n' "$cid" >> "$dir/fake/windows"
  printf '%s' "$wt" > "$dir/fake/home.fm-$cid"
  "$ROOT/bin/fm-busy-event.sh" arm "$dir/sm1-home/state" "$cid" --state "$busy" \
    --source claude-hook --event test >/dev/null
  [ -z "$line" ] || printf '%s\n' "$line" > "$dir/sm1-home/state/$cid.status"
}

test_running_direct_report_refuses() {
  local dir out rc
  dir=$(new_case crew-working)
  add_crew "$dir" c1 busy
  out=$(run_compact "$dir"); rc=$?
  assert_refused "$dir" "$out" "$rc" "direct report c1 is in a running step" crew-working
  pass "C3i a direct report in a running step refuses"
}

test_waiting_direct_report_refuses() {
  local dir out rc
  dir=$(new_case crew-blocked)
  add_crew "$dir" c1 idle 'blocked [at=1]: need a credential'
  out=$(run_compact "$dir"); rc=$?
  assert_refused "$dir" "$out" "$rc" "direct report c1 is waiting on a decision" crew-blocked
  pass "C3j a direct report waiting on a decision refuses"
}

test_idle_direct_report_passes() {
  local dir out rc
  dir=$(new_case crew-done)
  add_crew "$dir" c1 idle 'done [at=1]: PR https://example.invalid/pr/1'
  out=$(run_compact "$dir"); rc=$?
  expect_code 0 "$rc" "a finished direct report must not block compaction"$'\n'"$out"
  pass "C3k a direct report that is not running or waiting does not block"
}

test_unknown_direct_report_refuses() {
  local dir out rc
  dir=$(new_case crew-unknown)
  add_crew "$dir" c1 idle
  rm "$dir/sm1-home/state/c1.busy-state"
  out=$(run_compact "$dir"); rc=$?
  assert_refused "$dir" "$out" "$rc" "direct report c1 is not provably inactive" crew-unknown
  pass "C3n an unverified direct report refuses"
}

test_completed_run_activity_guard() {
  local dir out rc activity
  for activity in busy unknown idle checkpoint missing gone; do
    dir=$(new_case "completed-$activity")
    add_crew "$dir" c1 idle 'done [at=1]: finished'
    git -C "$dir/c1-wt" init -q
    git -C "$dir/c1-wt" checkout -q -b completed-worker
    git -C "$dir/c1-wt" commit -q --allow-empty -m initial
    cat > "$dir/fake/completed-run" <<RUN
run:
  id: "01RUN"
  branch: completed-worker
  status: completed
  head: "$(git -C "$dir/c1-wt" rev-parse HEAD)"
  pr: "https://example.invalid/pr/1"
  findings: none
outcome: passed
RUN
    case "$activity" in
      busy) "$ROOT/bin/fm-busy-event.sh" arm "$dir/sm1-home/state" c1 --state busy --source claude-hook --event test >/dev/null ;;
      unknown) rm "$dir/sm1-home/state/c1.busy-state" ;;
      missing|gone)
        printf 'fm-sm1\n' > "$dir/fake/windows"
        if [ "$activity" = gone ]; then
          printf 'endpoint_closed=fmses:fm-c1\n' >> "$dir/sm1-home/state/c1.meta"
        fi
        ;;
      checkpoint)
        cat > "$dir/fake/after-checkpoint" <<SH
#!/usr/bin/env bash
"$ROOT/bin/fm-busy-event.sh" arm "$dir/sm1-home/state" c1 --state busy --source claude-hook --event test >/dev/null
SH
        chmod +x "$dir/fake/after-checkpoint"
        ;;
    esac
    out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/sm1-home" FM_FAKE_DIR="$dir/fake" FM_CREW_STATE_NO_FORGE=1 "$ROOT/bin/fm-crew-state.sh" c1)
    assert_contains "$out" "state: done" "completed run must mask the worker activity in the run-state view"
    assert_contains "$out" "source: run-step" "the completed run must be attributed to HEAD"
    out=$(run_compact "$dir"); rc=$?
    if [ "$activity" = idle ] || [ "$activity" = gone ]; then
      expect_code 0 "$rc" "a completed run with independent idle evidence may compact"$'\n'"$out"
    elif [ "$activity" = missing ]; then
      assert_refused "$dir" "$out" "$rc" "direct report c1 activity cannot be established" completed-missing
    else
      assert_refused "$dir" "$out" "$rc" "direct report c1 is not provably idle" "completed-$activity"
      if [ "$activity" = checkpoint ]; then
        assert_contains "$out" "at the final check" "follow-up activity must be caught at the send boundary"
        assert_equals checkpoint "$(cat "$dir/fake/requests")" "the checkpoint must precede the refusal"
      else
        [ ! -s "$dir/fake/requests" ] || fail "active or unverified reports must refuse before checkpointing"
      fi
    fi
  done
  pass "C3o completed validation requires independent worker inactivity at both guards"
}

test_unverified_harness_refuses() {
  local dir out rc
  dir=$(new_case codex codex)
  out=$(run_compact "$dir"); rc=$?
  assert_refused "$dir" "$out" "$rc" "no verified context-size read, idle proof, and in-place compaction" codex
  pass "C3l a harness without all three verified legs refuses by name"
}

test_crew_target_refuses() {
  local dir out rc
  dir=$(new_case ship claude ship)
  out=$(run_compact "$dir"); rc=$?
  expect_code 1 "$rc" "a crew target must be refused"$'\n'"$out"
  assert_contains "$out" "compact applies to a second mate only" "a crew target must be named as out of scope"
  assert_not_typed "$dir" "a crew was compacted"
  pass "C3m a crew is never a compaction target"
}

# --- C4: the checkpoint is a gate ---------------------------------------------
test_checkpoint_unanswered_refuses() {
  local dir out rc
  dir=$(new_case ckpt-silent)
  : > "$dir/fake/no-checkpoint-answer"
  out=$(FM_TEST_PERSIST_WAIT=0 run_compact "$dir"); rc=$?
  assert_refused "$dir" "$out" "$rc" "did not answer the checkpoint request" ckpt-silent
  pass "C4a an unanswered checkpoint refuses"
}

test_checkpoint_incomplete_refuses() {
  local dir out rc
  dir=$(new_case ckpt-incomplete)
  printf 'done [%%s]: checkpoint=incomplete - the design call lives only here\n' > "$dir/fake/checkpoint-answer"
  out=$(run_compact "$dir"); rc=$?
  assert_refused "$dir" "$out" "$rc" "reported its checkpoint incomplete" ckpt-incomplete
  pass "C4b a checkpoint reported incomplete refuses"
}

test_checkpoint_unaffirmed_refuses() {
  local dir out rc
  dir=$(new_case ckpt-vague)
  printf 'done [%%s]: done\n' > "$dir/fake/checkpoint-answer"
  out=$(run_compact "$dir"); rc=$?
  assert_refused "$dir" "$out" "$rc" "did not affirm completeness" ckpt-vague
  pass "C4c a checkpoint answer that does not affirm completeness refuses"
}

# --- C5: re-check immediately before the keystroke ----------------------------
test_busy_after_checkpoint_refuses() {
  local dir out rc
  dir=$(new_case recheck-busy)
  cat > "$dir/fake/after-checkpoint" <<SH
#!/usr/bin/env bash
"$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" sm1 --state busy --source claude-hook --event test >/dev/null
SH
  chmod +x "$dir/fake/after-checkpoint"
  out=$(run_compact "$dir"); rc=$?
  assert_refused "$dir" "$out" "$rc" "still busy" recheck-busy
  pass "C5a a mate busy again after its checkpoint is re-read and refused"
}

test_direct_report_active_during_checkpoint_refuses() {
  local dir out rc
  dir=$(new_case recheck-crew)
  add_crew "$dir" c1 idle 'done [at=1]: finished'
  cat > "$dir/fake/after-checkpoint" <<SH
#!/usr/bin/env bash
"$ROOT/bin/fm-busy-event.sh" arm "$dir/sm1-home/state" c1 --state busy --source claude-hook --event test >/dev/null
SH
  chmod +x "$dir/fake/after-checkpoint"
  out=$(run_compact "$dir"); rc=$?
  assert_refused "$dir" "$out" "$rc" "direct report c1 is in a running step" recheck-crew
  assert_equals checkpoint "$(cat "$dir/fake/requests")" "the report must become active during the checkpoint"
  pass "C5e a direct report becoming active during the checkpoint refuses"
}

test_instruction_during_checkpoint_refuses() {
  local dir out rc
  dir=$(new_case recheck-inbox)
  cat > "$dir/fake/after-checkpoint" <<SH
#!/usr/bin/env bash
printf 'schema=fm-task-inbox.v1\n--\nnew steer\n' > "$dir/home/state/sm1.inbox/900.msg"
SH
  chmod +x "$dir/fake/after-checkpoint"
  out=$(run_compact "$dir"); rc=$?
  assert_refused "$dir" "$out" "$rc" "unhandled instruction (900.msg) at the final check" recheck-inbox
  pass "C5b an instruction that arrives during the checkpoint is caught at the final check"
}

test_unacknowledged_checkpoint_refuses() {
  local dir out rc
  dir=$(new_case recheck-noack)
  : > "$dir/fake/no-ack"
  out=$(run_compact "$dir"); rc=$?
  assert_refused "$dir" "$out" "$rc" "at the final check" recheck-noack
  pass "C5c a checkpoint request the mate never acknowledged is caught at the final check"
}

test_decision_during_checkpoint_refuses() {
  local dir out rc
  dir=$(new_case recheck-decision)
  cat > "$dir/fake/after-checkpoint" <<SH
#!/usr/bin/env bash
printf 'needs-decision [at=2] [key=late]: a new question\n' >> "$dir/home/state/sm1.status"
SH
  chmod +x "$dir/fake/after-checkpoint"
  out=$(run_compact "$dir"); rc=$?
  assert_refused "$dir" "$out" "$rc" "open decision awaiting acknowledgement (late) at the final check" recheck-decision
  pass "C5d a decision opened during the checkpoint is caught at the final check"
}

# --- C6: recovery failure stops there -----------------------------------------
assert_recovery_failed() {  # <case-dir> <out> <rc> <reason-fragment> <label>
  local dir=$1 out=$2 rc=$3 reason=$4 label=$5
  expect_code 1 "$rc" "$label: a failed recovery must exit 1"$'\n'"$out"
  assert_contains "$out" "$reason" "$label: the failure must say why"
  assert_contains "$out" "nothing was resumed or restarted" "$label: the failure must say it stopped"
  grep '^blocked \[at=[0-9]*\] \[key=context-compact\]: context-compact recovery-failed: ' \
    "$dir/home/state/sm1.status" 2>/dev/null | grep -qF -- "$reason" \
    || fail "$label: the failure must be recorded as an open blocker"
  ! grep -qx '/exit' "$dir/fake/literal" || fail "$label: a failed recovery must not stop or restart the mate"
  assert_absent "$dir/home/state/sm1.control-relaunch" "$label: a failed recovery must not relaunch the mate"
}

test_compaction_not_recorded_fails() {
  local dir out rc
  dir=$(new_case no-boundary)
  : > "$dir/fake/no-compact"
  out=$(FM_TEST_COMPACT_WAIT=0 run_compact "$dir"); rc=$?
  assert_recovery_failed "$dir" "$out" "$rc" "no completed compaction was recorded" no-boundary
  pass "C6a a compaction the transcript never records is a recorded failure"
}

test_context_not_dropped_fails() {
  local dir out rc
  dir=$(new_case no-drop)
  printf '460000' > "$dir/fake/post-tokens"
  out=$(run_compact "$dir"); rc=$?
  assert_recovery_failed "$dir" "$out" "$rc" "not below the 450000 it held before" no-drop
  pass "C6b a context that did not drop is a recorded failure"
}

test_probe_unanswered_fails() {
  local dir out rc
  dir=$(new_case probe-silent)
  : > "$dir/fake/no-probe-answer"
  out=$(FM_TEST_PROBE_WAIT=0 run_compact "$dir"); rc=$?
  assert_recovery_failed "$dir" "$out" "$rc" "did not answer the read-only recovery probe" probe-silent
  assert_contains "$(status_of "$dir")" "context-compact compacted:" "the compaction itself must still be recorded"
  pass "C6c an unanswered recovery probe is a recorded failure"
}

test_probe_wrong_identity_fails() {
  local dir out rc
  dir=$(new_case probe-identity)
  printf 'done [%%s]: role=secondmate id=someone-else records=readable\n' > "$dir/fake/probe-answer"
  out=$(run_compact "$dir"); rc=$?
  assert_recovery_failed "$dir" "$out" "$rc" "does not name its own charter id sm1" probe-identity
  pass "C6d a probe answer without the mate's own id is a recorded failure"
}

test_probe_unreadable_records_fails() {
  local dir out rc
  dir=$(new_case probe-records)
  printf 'done [%%s]: role=secondmate id=sm1 records=unreadable backlog missing\n' > "$dir/fake/probe-answer"
  out=$(run_compact "$dir"); rc=$?
  assert_recovery_failed "$dir" "$out" "$rc" "cannot be read back from its durable records" probe-records
  pass "C6e a probe answer reporting unreadable records is a recorded failure"
}

test_failed_recovery_blocks_next_attempt() {
  local dir out rc
  dir=$(new_case after-failure)
  printf 'done [%%s]: role=secondmate id=sm1\n' > "$dir/fake/probe-answer"
  out=$(run_compact "$dir"); rc=$?
  assert_recovery_failed "$dir" "$out" "$rc" "does not confirm its outstanding work reads back" after-failure
  # The mate is back over the threshold; the open blocker still refuses.
  printf '{"type":"assistant","isSidechain":false,"message":{"model":"claude-test","usage":{"input_tokens":480000}}}\n' \
    >> "$dir/fake/transcript"
  : > "$dir/fake/literal"
  out=$(run_compact "$dir"); rc=$?
  assert_refused "$dir" "$out" "$rc" "open decision awaiting acknowledgement (context-compact)" after-failure-retry
  pass "C6f a recorded recovery failure keeps the next compaction refused until resolved"
}

test_context_size_read
test_compaction_happy_path
test_below_threshold_refuses
test_unreadable_size_refuses
test_busy_refuses
test_unhandled_instruction_refuses
test_open_decision_refuses
test_owed_reply_refuses
test_pending_handoff_refuses
test_queued_notification_refuses
test_running_direct_report_refuses
test_waiting_direct_report_refuses
test_idle_direct_report_passes
test_unknown_direct_report_refuses
test_completed_run_activity_guard
test_unverified_harness_refuses
test_crew_target_refuses
test_checkpoint_unanswered_refuses
test_checkpoint_incomplete_refuses
test_checkpoint_unaffirmed_refuses
test_busy_after_checkpoint_refuses
test_direct_report_active_during_checkpoint_refuses
test_instruction_during_checkpoint_refuses
test_unacknowledged_checkpoint_refuses
test_decision_during_checkpoint_refuses
test_compaction_not_recorded_fails
test_context_not_dropped_fails
test_probe_unanswered_fails
test_probe_wrong_identity_fails
test_probe_unreadable_records_fails
test_failed_recovery_blocks_next_attempt
