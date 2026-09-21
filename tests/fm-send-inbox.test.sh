#!/usr/bin/env bash
# tests/fm-send-inbox.test.sh - fm-send's inbox data plane.
#
# An ordinary text steer to a task recorded in this home no longer types its
# payload: fm-send appends a durable sequenced record to state/<id>.inbox/ and
# rings one constant self-describing doorbell line, best-effort. These tests
# drive the real fm-send executable over a stubbed tmux and pin:
#   1. The payload is durably recorded and never typed; only the doorbell
#      crosses the terminal, and the send exits 0 at enqueue.
#   2. Multi-line steers are legal and round-trip byte-exact.
#   3. A re-send never retypes a payload, so the terminal can never truncate or
#      garble a steer, and it cannot duplicate a queued instruction either: an
#      identical instruction still pending for that target collapses onto the
#      existing record and says so, while --again, a different instruction,
#      another target, and an already-acknowledged instruction each still queue.
#      No inbox-plane send is silent, which is what stops a quiet success from
#      being read as a dead transport and resent.
#   4. The composer pre-check is advisory: visibly pending text skips the ring
#      with a notice, and the steer is still durably sent (exit 0).
#   5. A failed doorbell is still a sent steer (exit 0, record durable): the
#      watcher's re-ring ladder owns delivery from the record on.
#   6. Carve-outs keep the typed plane: a leading "/" (any harness), a leading
#      "$" to codex, an explicit backend target, and the --key path.
#   7. A marked secondmate steer carries its marker + corr token in the record
#      body, and the pending-reply expectation is marked delivered at enqueue.
#   8. Pending-reply bookkeeping failure after enqueue never reports a
#      retryable send failure that could duplicate the durable instruction.
#   9. An unwritable inbox is a real local failure: nonzero exit, nothing
#      typed, and a just-created pending-reply expectation is discarded.
#  10. An empty or whitespace-only text steer is refused before anything is
#      marked, recorded, or typed - on the marked secondmate path that means
#      no marker-only record and no pending-reply expectation.
# Every case below that passes a literal `$...` message quotes it on purpose
# (the point is sending an unexpanded `$` line), so SC2016 is disabled.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-marker-lib.sh"

SEND="$ROOT/bin/fm-send.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-inbox)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# Stub tmux: logs literal typed text to FM_SEND_LOG and lets the submit and
# composer paths reach clean verdicts. FM_FAKE_TMUX_COMPOSER=pending renders a
# composer visibly holding text; FM_FAKE_TMUX_SEND_FAIL=1 fails send-keys.
make_stubs() { # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat >"$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    [ "${FM_FAKE_TMUX_SEND_FAIL:-0}" = 1 ] && exit 1
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s\n' "${1:-}" >> "$FM_SEND_LOG"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    if [ "${FM_FAKE_TMUX_COMPOSER:-}" = pending ]; then
      printf '╭──────────────╮\n│ leftover txt │\n╰──────────────╯\n'
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0 ;;
  list-windows) printf 'fm-t1\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat >"$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

setup_case() { # <name> [harness] -> echoes case dir with home/state + t1 meta
  local name=$1 harness=${2:-claude} dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state"
  make_stubs "$dir" >/dev/null
  fm_write_meta "$dir/home/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=$harness"
  printf '%s\n' "$dir"
}

run_send() { # <case-dir> <err-file> [env...] -- <fm-send args...>
  local dir=$1 err=$2
  shift 2
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    envs+=("$1")
    shift
  done
  shift
  : >"$dir/send.log"
  env PATH="$dir/fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$dir/home" FM_HOME="$dir/home" FM_SEND_LOG="$dir/send.log" \
    FM_SEND_SETTLE=0 ${envs[@]+"${envs[@]}"} \
    "$SEND" "$@" >/dev/null 2>"$err"
}

record_body() { # <record>
  bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$2"
}

test_text_steer_rides_inbox() {
  local dir err rc rec body typed
  dir=$(setup_case rides)
  err="$dir/send.err"
  run_send "$dir" "$err" -- t1 "please rebase onto main"
  rc=$?
  expect_code 0 "$rc" "an inbox-plane steer should exit 0 at enqueue"
  rec="$dir/home/state/t1.inbox/001.msg"
  [ -f "$rec" ] || fail "the steer was not durably recorded at $rec"
  body=$(record_body _ "$rec")
  [ "$body" = "please rebase onto main" ] || fail "the recorded body differs: $body"
  typed=$(cat "$dir/send.log")
  assert_contains "$typed" "Firstmate instruction waiting: list '$dir/home/state/t1.inbox'/*.msg" \
    "the doorbell should direct the worker to drain the inbox"
  case "$typed" in
  *"please rebase onto main"*) fail "the payload must never be typed:"$'\n'"$typed" ;;
  esac
  pass "fm-send inbox: the payload is recorded durably and only the doorbell is typed"
}

test_multiline_steer_is_legal() {
  local dir err rc body
  dir=$(setup_case multiline)
  err="$dir/send.err"
  run_send "$dir" "$err" -- t1 $'first line\nsecond line\nthird: with punctuation'
  rc=$?
  expect_code 0 "$rc" "a multi-line steer should succeed"
  body=$(record_body _ "$dir/home/state/t1.inbox/001.msg")
  [ "$body" = $'first line\nsecond line\nthird: with punctuation' ] ||
    fail "the multi-line body did not round-trip:"$'\n'"$body"
  case "$(cat "$dir/send.log")" in
  *"second line"*) fail "a payload line leaked onto the typed channel" ;;
  esac
  pass "fm-send inbox: newlines are legal and the terminal can no longer truncate a steer"
}

pending_count() {  # <case-dir> <task>
  find "$1/home/state/$2.inbox" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l | tr -d ' '
}

test_resend_of_pending_instruction_collapses() {
  local dir err doorbells typed count
  dir=$(setup_case resend); err="$dir/send.err"
  run_send "$dir" "$err" -- t1 "check the CI result" || fail "first send failed"
  # The whole defect in one line: exit 0 with no output reads as a dead
  # transport, so the operator resends. It must stay one instruction.
  assert_contains "$(cat "$err")" "steer queued for t1 at $dir/home/state/t1.inbox/001.msg" \
    "the first send must name what it queued rather than succeeding silently"
  run_send "$dir" "$err" -- t1 "check the CI result" || fail "second send failed"
  count=$(pending_count "$dir" t1)
  [ "$count" = 1 ] \
    || fail "an identical resend must not queue a second instruction, found $count:"$'\n'"$(ls "$dir/home/state/t1.inbox")"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "the collapse lost the pending record"
  assert_contains "$(cat "$err")" "already queued and unhandled for t1" \
    "the collapsed resend must say plainly that it did not queue a second copy"
  assert_contains "$(cat "$err")" "--again" \
    "the collapse notice should name the deliberate-repeat escape hatch"
  # A collapse still rings: the worker may not have seen the first doorbell,
  # and a duplicate doorbell is a no-op by construction.
  doorbells=$(grep -cF 'Firstmate instruction waiting' "$dir/send.log" || true)
  [ "$doorbells" = 1 ] || fail "a collapsed resend should still ring once, got $doorbells"
  typed=$(cat "$dir/send.log")
  case "$typed" in
  *"check the CI result"*) fail "a re-send typed the payload" ;;
  esac
  pass "fm-send inbox: resending a still-pending instruction collapses onto it and reports it"
}

test_multiline_resend_collapses_byte_for_byte() {
  local dir err count
  dir=$(setup_case resendmultiline); err="$dir/send.err"
  local text=$'run the pipeline\n\n  - keep the indent\n  - and the blank line above'
  run_send "$dir" "$err" -- t1 "$text" || fail "first multi-line send failed"
  run_send "$dir" "$err" -- t1 "$text" || fail "second multi-line send failed"
  count=$(pending_count "$dir" t1)
  [ "$count" = 1 ] || fail "an identical multi-line resend must collapse, found $count records"
  pass "fm-send inbox: collapse identity survives a multi-line body byte-for-byte"
}

test_deliberate_repeat_queues_twice() {
  local dir err count
  dir=$(setup_case again); err="$dir/send.err"
  run_send "$dir" "$err" -- t1 "check the CI result" || fail "first send failed"
  run_send "$dir" "$err" -- t1 --again "check the CI result" || fail "--again send failed"
  count=$(pending_count "$dir" t1)
  [ "$count" = 2 ] \
    || fail "--again must queue a deliberate repeat, found $count:"$'\n'"$(ls "$dir/home/state/t1.inbox")"
  [ -f "$dir/home/state/t1.inbox/002.msg" ] || fail "the repeat did not take a new sequence"
  assert_contains "$(cat "$err")" "deliberate repeat" \
    "an explicit repeat should report itself as one"
  pass "fm-send inbox: --again still queues a deliberate repeat of the same words"
}

test_different_instruction_queues_separately() {
  local dir err count
  dir=$(setup_case distinct); err="$dir/send.err"
  run_send "$dir" "$err" -- t1 "check the CI result" || fail "first send failed"
  run_send "$dir" "$err" -- t1 "check the CI result again tomorrow" || fail "second send failed"
  count=$(pending_count "$dir" t1)
  [ "$count" = 2 ] \
    || fail "a different instruction must queue separately, found $count:"$'\n'"$(ls "$dir/home/state/t1.inbox")"
  assert_contains "$(cat "$err")" "steer queued for t1 at $dir/home/state/t1.inbox/002.msg" \
    "a genuinely new instruction should report its own new record"
  pass "fm-send inbox: a different instruction to the same target still queues separately"
}

test_same_instruction_to_two_targets_queues_once_each() {
  local dir err
  dir=$(setup_case twotargets); err="$dir/send.err"
  fm_write_meta "$dir/home/state/t2.meta" "window=sess:fm-t2" "kind=ship" "harness=claude"
  run_send "$dir" "$err" -- t1 "check the CI result" || fail "send to t1 failed"
  run_send "$dir" "$err" -- t2 "check the CI result" || fail "send to t2 failed"
  [ "$(pending_count "$dir" t1)" = 1 ] || fail "t1 should hold exactly one instruction"
  [ "$(pending_count "$dir" t2)" = 1 ] || fail "t2 should hold exactly one instruction"
  pass "fm-send inbox: collapse is per target - the same instruction reaches each of two workers"
}

test_handled_instruction_queues_again() {
  local dir err count
  dir=$(setup_case handled); err="$dir/send.err"
  run_send "$dir" "$err" -- t1 "check the CI result" || fail "first send failed"
  # The worker's acknowledgement move: it read that instruction and acted on
  # it, so sending the same words later is a NEW instruction, not a duplicate.
  mv "$dir/home/state/t1.inbox/001.msg" "$dir/home/state/t1.inbox/handled/" \
    || fail "could not stage the acknowledgement"
  run_send "$dir" "$err" -- t1 "check the CI result" || fail "post-ack send failed"
  count=$(pending_count "$dir" t1)
  [ "$count" = 1 ] || fail "an acknowledged instruction must queue again, found $count pending"
  [ -f "$dir/home/state/t1.inbox/002.msg" ] \
    || fail "the re-queued instruction should take a new sequence:"$'\n'"$(ls "$dir/home/state/t1.inbox")"
  assert_contains "$(cat "$err")" "steer queued for t1 at $dir/home/state/t1.inbox/002.msg" \
    "a post-acknowledgement send should report a new record, not a collapse"
  pass "fm-send inbox: handled is not pending - an acknowledged instruction queues again"
}

test_again_is_refused_where_nothing_collapses() {
  local dir err rc
  dir=$(setup_case againrefused); err="$dir/send.err"
  # The typed plane queues nothing, so --again would silently do nothing.
  run_send "$dir" "$err" -- t1 --again "/no-mistakes"; rc=$?
  [ "$rc" -ne 0 ] || fail "--again on the typed plane should be refused"
  assert_contains "$(cat "$err")" "rides the durable inbox" \
    "the typed-plane refusal should name why nothing can collapse"
  [ ! -s "$dir/send.log" ] || fail "a refused --again typed something:"$'\n'"$(cat "$dir/send.log")"
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "a refused --again enqueued a record"
  run_send "$dir" "$err" -- t1 --again --key Enter; rc=$?
  [ "$rc" -ne 0 ] || fail "--again with --key should be refused"
  assert_contains "$(cat "$err")" "cannot accompany --key" \
    "the --key refusal should be explicit"
  pass "fm-send inbox: --again is refused on every plane where nothing collapses"
}

test_pending_composer_skips_ring_advisorily() {
  local dir err rc
  dir=$(setup_case pendingskip)
  err="$dir/send.err"
  run_send "$dir" "$err" FM_FAKE_TMUX_COMPOSER=pending -- t1 "steer past a stuck composer"
  rc=$?
  expect_code 0 "$rc" "a skipped ring is still a sent steer"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "the steer was not recorded"
  [ ! -s "$dir/send.log" ] || fail "a visibly pending composer should skip the ring:"$'\n'"$(cat "$dir/send.log")"
  assert_contains "$(cat "$err")" "watcher will re-ring" \
    "the skip notice should point at the re-ring"
  pass "fm-send inbox: a visibly pending composer skips the ring, and the steer stays durably sent"
}

test_failed_ring_is_still_sent() {
  local dir err rc
  dir=$(setup_case ringfail)
  err="$dir/send.err"
  run_send "$dir" "$err" FM_FAKE_TMUX_SEND_FAIL=1 -- t1 "steer into a dead pane"
  rc=$?
  expect_code 0 "$rc" "a failed doorbell must not fail the send"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "the steer was not recorded"
  assert_contains "$(cat "$err")" "watcher will re-ring" \
    "the failed-ring notice should point at the re-ring"
  pass "fm-send inbox: a failed doorbell is still a durably sent steer"
}

test_harness_invocations_stay_typed() {
  local dir err typed
  # A slash command must reach the harness's own parser, on any harness.
  dir=$(setup_case slash)
  err="$dir/send.err"
  run_send "$dir" "$err" -- t1 "/no-mistakes" || fail "a slash send should succeed"
  typed=$(cat "$dir/send.log")
  assert_contains "$typed" "/no-mistakes" "the slash command should be typed literally"
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "a slash command must not be routed to the inbox"
  # A codex `$<skill>` invocation likewise stays typed.
  dir=$(setup_case codexskill codex)
  err="$dir/send.err"
  run_send "$dir" "$err" -- t1 '$no-mistakes' || fail "a codex \$skill send should succeed"
  assert_contains "$(cat "$dir/send.log")" '$no-mistakes' "the codex \$skill should be typed literally"
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "a codex \$skill must not be routed to the inbox"
  # The same `$` message to a non-codex harness is plain text: inbox plane.
  dir=$(setup_case dollartext claude)
  err="$dir/send.err"
  run_send "$dir" "$err" -- t1 '$5/month is cheap' || fail "a claude \$-text send should succeed"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "a non-codex \$-message should ride the inbox"
  case "$(cat "$dir/send.log")" in
  *'$5/month'*) fail "a non-codex \$-message payload was typed" ;;
  esac
  pass "fm-send planes: slash and codex \$skill invocations stay typed; plain \$-text rides the inbox"
}

test_explicit_target_stays_typed() {
  local dir err
  dir=$(setup_case explicit)
  err="$dir/send.err"
  run_send "$dir" "$err" -- sess:win "hello there" || fail "an explicit-target send should succeed"
  assert_contains "$(cat "$dir/send.log")" "hello there" \
    "an explicit backend target should receive the literal text"
  [ -z "$(find "$dir/home/state" -maxdepth 1 -name '*.inbox' -print 2>/dev/null)" ] ||
    fail "an explicit target has no task record here and must not grow an inbox"
  pass "fm-send planes: an explicit backend target keeps the typed plane"
}

test_key_path_never_touches_inbox() {
  local dir err
  dir=$(setup_case keypath)
  err="$dir/send.err"
  run_send "$dir" "$err" -- t1 --key Enter || fail "a --key send should succeed"
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "the --key path must never write an inbox record"
  pass "fm-send planes: the --key lifecycle path never touches the inbox"
}

test_secondmate_marker_and_enqueue_delivery() {
  local dir err body corr pr_rec delivered
  dir=$(setup_case secondmate)
  err="$dir/send.err"
  fm_write_secondmate_meta "$dir/home/state/domain.meta" "$dir/home" "sess:fm-domain"
  run_send "$dir" "$err" -- fm-domain "please summarize fleet health" ||
    fail "a secondmate steer should succeed"
  body=$(record_body _ "$dir/home/state/domain.inbox/001.msg")
  case "$body" in
  "$FM_FROMFIRST_MARK"corr=*) : ;;
  *) fail "the recorded body lost the from-firstmate marker/corr framing:"$'\n'"$body" ;;
  esac
  corr=$(printf '%s' "$body" | grep -oE 'corr=[a-f0-9]{16}' | head -1 | cut -d= -f2)
  [ -n "$corr" ] || fail "no corr token in the recorded body"
  pr_rec="$dir/home/state/pending-replies/$corr"
  [ -f "$pr_rec" ] || fail "no pending-reply expectation was recorded at $pr_rec"
  delivered=$(grep '^delivered_epoch=' "$pr_rec" | cut -d= -f2)
  [ -n "$delivered" ] || fail "enqueue IS delivery: delivered_epoch should be set at enqueue time:"$'\n'"$(cat "$pr_rec")"
  case "$(cat "$dir/send.log")" in
  *"summarize fleet health"*) fail "the marked payload was typed" ;;
  esac
  pass "fm-send inbox: a secondmate steer records marker+corr in the body and is delivered at enqueue"
}

test_post_enqueue_bookkeeping_failure_is_not_retryable() {
  local dir err rc rec body
  dir=$(setup_case bookkeeping-failure)
  err="$dir/send.err"
  fm_write_secondmate_meta "$dir/home/state/domain.meta" "$dir/home" "sess:fm-domain"
  cat >"$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
source_arg=${@: -2:1}
target_arg=${@: -1}
if [ "${FM_FAIL_DELIVERY_CONFIRM:-0}" = 1 ] \
  && grep -q '^confirmed=' "$source_arg" 2>/dev/null; then
  # Simulate losing both the delivery commit and its prepared recovery marker.
  rm -f "$target_arg"
  exit 1
fi
exec /bin/mv "$@"
SH
  chmod +x "$dir/fakebin/mv"

  run_send "$dir" "$err" FM_FAIL_DELIVERY_CONFIRM=1 -- domain "durable once"
  rc=$?
  # The durable record IS the delivery: even with the commit AND its recovery
  # marker both lost, the steer was delivered, so fm-send must not signal a
  # status that invites a resend (a nonzero would make automated callers
  # enqueue the same instruction again under a new sequence). The degradation
  # surfaces as its own distinct do-not-resend condition instead.
  expect_code 0 "$rc" "a delivered steer must not report a resend-inviting failure over lost bookkeeping"
  rec="$dir/home/state/domain.inbox/001.msg"
  [ -f "$rec" ] || fail "bookkeeping failure test did not durably enqueue the steer"
  [ "$(find "$dir/home/state/domain.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')" = 1 ] ||
    fail "the delivered steer was duplicated:"$'\n'"$(ls "$dir/home/state/domain.inbox")"
  body=$(record_body _ "$rec")
  case "$body" in
  "$FM_FROMFIRST_MARK"corr=*) : ;;
  *) fail "bookkeeping failure test lost the secondmate marker: $body" ;;
  esac
  assert_contains "$(cat "$err")" "reply-tracking-degraded" \
    "lost bookkeeping should surface as its own distinct degraded condition"
  assert_contains "$(cat "$err")" "do not resend" \
    "the degraded condition should give explicit do-not-resend guidance"
  assert_contains "$(cat "$err")" "durably recorded at" \
    "the degraded condition should name the already-delivered record"
  pass "fm-send inbox: lost reply bookkeeping never invites a resend, and the delivered steer is never duplicated"
}

test_meta_lock_contention_fails_bounded() {
  local dir err rc holder marker lock i
  dir=$(setup_case meta-lock)
  err="$dir/send.err"
  marker="$dir/meta-lock-held"
  lock="$dir/home/state/.meta-t1.lock"
  bash -c '
    . "$1"
    fm_lock_acquire_wait "$2"
    touch "$3"
    sleep 30
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$lock" "$marker" &
  holder=$!
  i=0
  while [ ! -e "$marker" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$marker" ] || {
    kill "$holder" 2>/dev/null
    fail "the metadata lock holder did not start"
  }
  run_send "$dir" "$err" FM_TASK_INBOX_LOCK_WAIT_SECS=0 -- t1 "must not hang"
  rc=$?
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null
  [ "$rc" -ne 0 ] || fail "metadata lock contention should fail after the bounded wait"
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "a lock refusal must not enqueue a record"
  assert_contains "$(cat "$err")" "metadata could not be locked" \
    "the bounded metadata lock refusal should be explicit"
  pass "fm-send inbox: metadata lock contention fails bounded without enqueue"
}

test_unwritable_inbox_fails_loudly() {
  local dir err rc
  dir=$(setup_case unwritable)
  err="$dir/send.err"
  fm_write_secondmate_meta "$dir/home/state/domain.meta" "$dir/home" "sess:fm-domain"
  : >"$dir/home/state/domain.inbox" # a FILE where the inbox dir must go
  run_send "$dir" "$err" -- fm-domain "this cannot be recorded"
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unwritable inbox must fail the send"
  assert_contains "$(cat "$err")" "inbox record could not be written" \
    "the failure should name the unwritable inbox"
  [ ! -s "$dir/send.log" ] || fail "a failed enqueue still typed something:"$'\n'"$(cat "$dir/send.log")"
  [ -z "$(find "$dir/home/state/pending-replies" -type f -not -name '.*' 2>/dev/null)" ] ||
    fail "a failed enqueue should discard the just-created pending-reply expectation"
  pass "fm-send inbox: an unwritable record is a loud local failure that leaves no false expectation"
}

test_empty_message_refused() {
  local dir err rc
  # The lived defect: an empty marked secondmate steer used to deliver a
  # marker+corr record with no body and mint a pending-reply expectation the
  # parent could never see resolved.
  dir=$(setup_case empty-marked)
  err="$dir/send.err"
  fm_write_secondmate_meta "$dir/home/state/domain.meta" "$dir/home" "sess:fm-domain"
  run_send "$dir" "$err" -- fm-domain
  rc=$?
  [ "$rc" -ne 0 ] || fail "an empty secondmate steer should refuse"
  assert_contains "$(cat "$err")" "nonempty message" \
    "the empty-message refusal should be explicit"
  [ ! -d "$dir/home/state/domain.inbox" ] || fail "an empty steer still wrote an inbox record"
  [ -z "$(find "$dir/home/state/pending-replies" -type f -not -name '.*' 2>/dev/null)" ] ||
    fail "an empty steer still minted a pending-reply expectation"
  [ ! -s "$dir/send.log" ] || fail "an empty steer still typed something:"$'\n'"$(cat "$dir/send.log")"

  # An explicit empty-string argument is the same refusal.
  dir=$(setup_case empty-string-arg)
  err="$dir/send.err"
  run_send "$dir" "$err" -- t1 ""
  rc=$?
  [ "$rc" -ne 0 ] || fail "an explicit empty-string message should refuse"
  assert_contains "$(cat "$err")" "nonempty message" \
    "the empty-string refusal should be explicit"
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "an empty-string steer still wrote an inbox record"

  # A whitespace-only message is equally contentless and refuses.
  dir=$(setup_case whitespace-only)
  err="$dir/send.err"
  run_send "$dir" "$err" -- t1 "   "
  rc=$?
  [ "$rc" -ne 0 ] || fail "a whitespace-only message should refuse"
  assert_contains "$(cat "$err")" "nonempty message" \
    "the whitespace-only refusal should be explicit"
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "a whitespace-only steer still wrote an inbox record"

  # The --key lifecycle path is unaffected: it takes no text at all.
  dir=$(setup_case keypath-after-refusal)
  err="$dir/send.err"
  run_send "$dir" "$err" -- t1 --key Enter || fail "a --key send should still succeed"
  pass "fm-send: an empty or whitespace-only text steer refuses before marking, recording, or typing"
}

test_text_steer_rides_inbox
test_multiline_steer_is_legal
test_resend_of_pending_instruction_collapses
test_multiline_resend_collapses_byte_for_byte
test_deliberate_repeat_queues_twice
test_different_instruction_queues_separately
test_same_instruction_to_two_targets_queues_once_each
test_handled_instruction_queues_again
test_again_is_refused_where_nothing_collapses
test_pending_composer_skips_ring_advisorily
test_failed_ring_is_still_sent
test_harness_invocations_stay_typed
test_explicit_target_stays_typed
test_key_path_never_touches_inbox
test_secondmate_marker_and_enqueue_delivery
test_post_enqueue_bookkeeping_failure_is_not_retryable
test_meta_lock_contention_fails_bounded
test_unwritable_inbox_fails_loudly
test_empty_message_refused
