#!/usr/bin/env bash
# fm-send strict target resolution and key delivery reporting.
#
# A send that cannot be tied to a recorded task/lane or to an explicit
# well-formed backend target must fail loudly. These tests pin the historical
# silent-fallback failures: missing FM_HOME, unresolved selectors, prefixless
# herdr pane ids, dead explicit endpoints, and the healthy exact/fm-id paths.
# They also verify that a key send reports whether delivery actually succeeded,
# and that the typed plane accounts for both of its submit verdicts out loud:
# the confirmed one it once reported with silence, and the unconfirmed one whose
# existing text and exit 3 must survive that addition. They also verify that the
# typed plane refuses, rather than types, when the composer already holds
# pending text, and when bytes that will execute as a command are aimed at a
# worker whose agent is mid-turn - on tmux and on a non-tmux backend alike, and
# whatever the backend's native agent-state claims - while text that merely
# queues goes through: plain prose to a mid-turn worker, "$"-prefixed prose to a
# mid-turn codex worker, a marked secondmate request whose marker makes it chat,
# and anything at all to a target this home records no harness for.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-strict)

make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
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
    printf 'send-keys target=%s literal=%s arg=%s\n' "$target" "$literal" "${1:-}" >> "$FM_TMUX_LOG"
    # FM_FAKE_TMUX_SEND_KEY_FAIL names one key whose delivery fails, so the
    # --key exit contract can be driven both ways from the same stub.
    if [ "$literal" = 0 ] && [ -n "${FM_FAKE_TMUX_SEND_KEY_FAIL:-}" ] \
      && [ "${1:-}" = "$FM_FAKE_TMUX_SEND_KEY_FAIL" ]; then
      exit 1
    fi
    exit 0 ;;
  display-message)
    target=
    cursor=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        *cursor_y*) cursor=1; shift ;;
        *) shift ;;
      esac
    done
    if [ -n "${FM_FAKE_TMUX_DEAD_TARGET:-}" ] && [ "$target" = "$FM_FAKE_TMUX_DEAD_TARGET" ]; then
      exit 1
    fi
    [ "$cursor" = 1 ] && { printf '1\n'; exit 0; }
    printf '%%1\n'
    exit 0 ;;
  capture-pane)
    # Two independent ways to put draft text in the composer box, because the
    # typed plane now reads that box at two different moments and they mean
    # opposite things. FM_FAKE_TMUX_COMPOSER_TEXT appears only AFTER the message
    # has been typed (a literal send-keys is in the log), modelling a harness
    # that keeps rendering the steer: the pre-typing read is empty, so the send
    # proceeds and the read-back classifies as "pending" (delivered, submission
    # unconfirmed). FM_FAKE_TMUX_COMPOSER_PREFILL is there from the start,
    # modelling a composer that already holds someone's content before this
    # send ever ran. With neither set the box is always empty, so a submit
    # classifies as "empty" (confirmed).
    # The box's inner width must match its borders, or the classifier reads the
    # geometry as ambiguous and downgrades the verdict to pending-unproven.
    composer_text=${FM_FAKE_TMUX_COMPOSER_PREFILL:-}
    if [ -z "$composer_text" ] && [ -n "${FM_FAKE_TMUX_COMPOSER_TEXT:-}" ] \
      && grep -q 'literal=1' "$FM_TMUX_LOG" 2>/dev/null; then
      composer_text=$FM_FAKE_TMUX_COMPOSER_TEXT
    fi
    if [ -n "$composer_text" ]; then
      printf '╭─────────────╮\n│ %-11.11s │\n╰─────────────╯\n' "$composer_text"
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    # FM_FAKE_TMUX_BUSY renders a harness's mid-turn footer on the row below
    # the composer box - the row the pane-tail busy detector reads. It is
    # independent of the box's contents on purpose, so the pane can be busy
    # with an EMPTY composer, which is the state a worker already driving its
    # own run is actually in.
    if [ -n "${FM_FAKE_TMUX_BUSY:-}" ]; then
      printf '%s\n' '✻ Baking… (esc to interrupt)'
    fi
    exit 0 ;;
  list-windows)
    printf 'foreign:%s\nfm-mpf-lane-m8\nfm-lane-ok\n' "${FM_FAKE_TMUX_WINDOW:-fm-lost}"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_HERDR_LOG"
case "${1:-} ${2:-}" in
  "status --json") printf '{"client":{"version":"0.7.5","protocol":16},"server":{"running":true}}\n' ;;
  "pane get") printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}" ;;
  "pane send-keys") : ;;
  "pane read")
    # An empty composer box, plus the harness's mid-turn footer below it when
    # FM_FAKE_HERDR_BUSY is set. The two knobs are independent because herdr's
    # native agent-state and its rendered tail genuinely disagree in the field.
    printf '╭────╮\n│    │\n╰────╯\n'
    if [ -n "${FM_FAKE_HERDR_BUSY:-}" ]; then
      printf '%s\n' '✻ Baking… (esc to interrupt)'
    fi
    ;;
  "agent get")
    # Unset leaves agent_status unparseable, so the native verdict is unknown.
    # FM_FAKE_HERDR_AGENT_STATUS=idle is the live shape herdr's own adapter
    # documents: Claude keeps agent_status idle through a whole landed turn,
    # so an idle native reading is not evidence the pane is free.
    if [ -n "${FM_FAKE_HERDR_AGENT_STATUS:-}" ]; then
      printf '{"result":{"agent":{"agent":"claude","agent_status":"%s"}}}\n' \
        "$FM_FAKE_HERDR_AGENT_STATUS"
    fi
    ;;
esac
SH
  chmod +x "$fb/herdr"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

setup_home() {  # <name> -> echoes home dir
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

test_exact_lane_id_send_still_works() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/exact"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home exact); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/mpf-lane-m8.meta" "window=sess:fm-mpf-lane-m8" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" mpf-lane-m8 "lost dispatch" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "exact task id send should succeed when metadata exists"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:fm-mpf-lane-m8 literal=1 arg=: Firstmate instruction waiting" \
    "exact id should ring the doorbell at the meta target"
  assert_contains "$got" "target=sess:fm-mpf-lane-m8 literal=0 arg=Enter" "exact id should submit the doorbell with Enter"
  grep -qF 'lost dispatch' "$home/state/mpf-lane-m8.inbox/001.msg" \
    || fail "exact id should record the steer in the task inbox"
  pass "fm-send strict: exact task/lane ids resolve through home metadata"
}

test_unset_fm_home_fails() {
  local dir fb err log rc
  dir="$TMP_ROOT/nohome"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  env -u FM_HOME PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" sess:win "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unset FM_HOME should fail"
  assert_contains "$(cat "$err")" "FM_HOME is not set" "unset FM_HOME diagnostic should be explicit"
  [ ! -s "$log" ] || fail "unset FM_HOME still attempted a send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unset FM_HOME fails before target resolution"
}

test_unresolvable_target_does_not_tmux_fallback() {
  local dir fb home err log rc
  dir="$TMP_ROOT/unresolved"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home unresolved); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_FAKE_TMUX_WINDOW=lost-target FM_SEND_SETTLE=0 \
    "$SEND" lost-target "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unresolvable target should fail"
  assert_contains "$(cat "$err")" "not resolvable" "unresolvable diagnostic should be loud"
  assert_contains "$(cat "$err")" "metadata window/terminal lookup" "unresolvable diagnostic should name the attempted lookup"
  assert_contains "$(cat "$err")" "backend=none" "unresolvable diagnostic should name that no backend was assumed"
  [ ! -s "$log" ] || fail "unresolvable target fell through to tmux send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unresolvable selectors do not fall back to tmux"
}

test_prefixless_herdr_pane_id_fails() {
  local dir fb home err log rc
  dir="$TMP_ROOT/herdr-pane"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home herdr); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/nudge.meta" \
    "window=default:wB:p2" "backend=herdr" "herdr_session=default" "herdr_pane_id=wB:p2" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" wB:p2 "nudge" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "prefixless herdr pane id should fail"
  assert_contains "$(cat "$err")" "matches herdr_pane_id" "herdr pane diagnostic should name the meta match"
  assert_contains "$(cat "$err")" "expected <herdr-session>:<pane-id>" "herdr pane diagnostic should show expected shape"
  assert_contains "$(cat "$err")" "default:wB:p2" "herdr pane diagnostic should show the canonical target"
  [ ! -s "$log" ] || fail "prefixless herdr pane id fell through to tmux send"$'\n'"$(cat "$log")"
  pass "fm-send strict: prefixless herdr pane ids are rejected before tmux fallback"
}

test_unmatched_single_colon_target_must_exist() {
  local dir fb home err log rc
  dir="$TMP_ROOT/dead-explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home deadexplicit); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_FAKE_TMUX_DEAD_TARGET=sess:missing FM_SEND_SETTLE=0 \
    "$SEND" sess:missing "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "dead explicit tmux-shaped target should fail"
  assert_contains "$(cat "$err")" "not a live tmux endpoint" "dead explicit target diagnostic should name the assumed backend"
  assert_contains "$(cat "$err")" "backend=tmux" "dead explicit target diagnostic should name the tried backend"
  [ ! -s "$log" ] || fail "dead explicit target still attempted a send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unmatched single-colon explicit targets must verify live before sending"
}

test_fm_prefixed_herdr_session_is_an_explicit_target() {
  local dir fb home err log herdr_log rc
  dir="$TMP_ROOT/fm-remote-explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home fmremote); err="$dir/send.err"; log="$dir/tmux.log"; herdr_log="$dir/herdr.log"
  : > "$log"
  : > "$herdr_log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_HERDR_LOG="$herdr_log" FM_SEND_SETTLE=0 \
    "$SEND" fm-remote:w1:p2 --key Enter >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "an fm-prefixed Herdr session target should be accepted as explicit"
  assert_grep 'pane get w1:p2 --session fm-remote' "$herdr_log" "fm-prefixed Herdr target was not verified in its session"
  assert_grep 'pane send-keys w1:p2 enter --session fm-remote' "$herdr_log" "fm-prefixed Herdr target was not sent its key in its session"
  assert_no_grep '--session default' "$herdr_log" "fm-prefixed Herdr target fell back to the default session"
  pass "fm-send strict: fm-prefixed Herdr sessions remain explicit backend targets"
}

test_healthy_fm_id_send_still_works() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/healthy"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home healthy); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/lane-ok.meta" "window=sess:fm-lane-ok" "kind=ship" "harness=codex"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" fm-lane-ok "hello captain" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "healthy fm-id send should succeed"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:fm-lane-ok literal=1 arg=: Firstmate instruction waiting" \
    "healthy send should ring the doorbell at the meta target"
  assert_contains "$got" "target=sess:fm-lane-ok literal=0 arg=Enter" "healthy send should submit the doorbell with Enter"
  grep -qF 'hello captain' "$home/state/lane-ok.inbox/001.msg" \
    || fail "healthy send should record the steer in the task inbox"
  assert_contains "$(cat "$err")" "requested message WILL still be sent" "fm-send guard banner should keep send-specific continuation wording"
  pass "fm-send strict: healthy fm-<id> sends record the steer and ring once"
}

# A --key send is how firstmate interrupts a worker, so its exit status is the
# only signal that the interrupt actually landed.
# Reporting success for a key that was never delivered would leave supervision
# believing a runaway worker had been stopped, so the failing case must exit
# nonzero and name the key.
# Both directions are asserted from one stub so the failing case cannot go
# quietly vacuous if the key ever stops being delivered at all.
test_key_send_exit_status_follows_delivery() {
  local dir fb home err log rc
  dir="$TMP_ROOT/key-exit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home keyexit); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/lane-key.meta" "window=sess:fm-lane-key" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" lane-key --key Escape >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "a delivered --key interrupt should report success"
  assert_contains "$(cat "$log")" "target=sess:fm-lane-key literal=0 arg=Escape" "the delivered case should send the named key"

  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    FM_FAKE_TMUX_SEND_KEY_FAIL=Escape \
    "$SEND" lane-key --key Escape >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an undelivered --key interrupt reported success"
  assert_contains "$(cat "$err")" "key 'Escape' not sent" "the undelivered case should name the key that failed"
  assert_contains "$(cat "$log")" "target=sess:fm-lane-key literal=0 arg=Escape" "the undelivered case should still have attempted the send"
  pass "fm-send --key: exit status follows delivery, and an undelivered key never reports success"
}

# The key plane's failure is loud, so a silent success was the one key-send
# outcome a caller could not tell apart from a command that did nothing. It
# writes no durable record either, so what it prints is its only account of the
# delivery, and the confirmation is asserted beside the untouched failure text
# so a later change cannot trade one report for the other.
test_key_send_reports_confirmed_delivery() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/key-report"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home keyreport); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/lane-key.meta" "window=sess:fm-lane-key" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" lane-key --key Enter >"$dir/send.out" 2>"$err"; rc=$?
  expect_code 0 "$rc" "a delivered --key send should still exit 0"
  got=$(cat "$err")
  assert_contains "$got" "key 'Enter' sent to" "the delivered key must be named in its own report"
  assert_contains "$got" "sess:fm-lane-key" "the delivered key must name the target it reached"
  assert_no_grep "not sent" "$err" "a delivered key must never print the failure text"
  [ ! -s "$dir/send.out" ] || fail "the key confirmation belongs on stderr, not stdout"$'\n'"$(cat "$dir/send.out")"
  pass "fm-send --key: a confirmed key send reports the key and the target it reached"
}

# The typed plane writes no durable record, so its only account of what
# happened is what it prints. A confirmed submit was once the single silent
# outcome of the typed plane, and silence there is indistinguishable from a
# command that did nothing - which invites a duplicate send onto exactly the
# plane that must never carry one. Both verdicts are driven from the same stub
# so a later change cannot trade the confirmation for the already-loud
# unconfirmed report, or the other way round.
test_typed_submit_reports_confirmed_and_unconfirmed() {
  local dir fb home err rc log got
  dir="$TMP_ROOT/typed-report"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home typedreport); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" sess:win "hello captain" >"$dir/send.out" 2>"$err"; rc=$?
  expect_code 0 "$rc" "a confirmed typed submit should still exit 0"
  got=$(cat "$err")
  assert_contains "$got" "sess:win" "the confirmed submit must name the target it reached"
  assert_contains "$got" "verdict=empty" "the confirmed submit must report the verdict that proved it"
  assert_contains "$got" "do not resend" "the confirmed submit must close the resend question"
  assert_contains "$got" "rather than into a durable record" \
    "the confirmed submit must not read as the inbox plane's queued receipt"
  assert_no_grep "queued" "$err" "a typed submit must never claim the text was queued"
  [ ! -s "$dir/send.out" ] || fail "the confirmation belongs on stderr, not stdout"$'\n'"$(cat "$dir/send.out")"

  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    FM_FAKE_TMUX_COMPOSER_TEXT="hello" \
    "$SEND" sess:win "hello captain" >/dev/null 2>"$err"; rc=$?
  expect_code 3 "$rc" "an unconfirmed typed submit must keep its documented exit 3"
  got=$(cat "$err")
  assert_contains "$got" "text delivered to sess:win but submission is unconfirmed" \
    "the unconfirmed submit must keep its existing report"
  assert_contains "$got" "verdict=pending" "the unconfirmed submit must keep naming its verdict"
  assert_contains "$got" "do not retype or blindly resend" \
    "the unconfirmed submit must keep its retype refusal"
  pass "fm-send typed plane: a confirmed submit is reported, and the unconfirmed path keeps its text and exit 3"
}

# A typed "/no-mistakes" reaches the harness's own parser, so it is an
# instruction to START something rather than queueable work, and landing it on a
# target that is already occupied is how a second pipeline run gets started
# against a branch the first already owns. Two states occupy a target and both
# must refuse: a composer that already holds content, and a pane whose agent is
# mid-turn with NOTHING typed - the reported incident, which the composer read
# alone cannot see because an empty composer is exactly what it classifies. The
# inbox plane reads the composer condition before its doorbell and defers to its
# durable record; the typed plane has no record to defer to, so it must refuse
# and type nothing at all.
# The refusals are asserted beside three sends that must NOT be refused, so no
# later change can buy the guard by blocking the plane: an idle worker still
# takes an invocation; a mid-turn one still takes plain prose, because queueing
# "when you finish this, do X" behind a running turn is the normal way to steer
# a busy pane and refusing it would leave no way to do so at all; and a target
# this home records no harness for still takes an invocation whatever its tail
# happens to render, because a busy token we cannot attribute to that target's
# own harness is not evidence about that target.
test_typed_send_refuses_an_occupied_target() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/typed-busy"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home typedbusy); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/busy-lane.meta" \
    "window=sess:fm-busy-lane" "kind=ship" "harness=claude"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    FM_FAKE_TMUX_COMPOSER_PREFILL="half typed" \
    "$SEND" sess:win "/no-mistakes" >"$dir/send.out" 2>"$err"; rc=$?
  expect_code 1 "$rc" "a typed send onto a busy composer must fail, not report a submit"
  got=$(cat "$err")
  assert_contains "$got" "sess:win" "the refusal must name the target it declined to type into"
  assert_contains "$got" "composer visibly holds pending text" \
    "the refusal must name the condition that caused it"
  assert_contains "$got" "Nothing was sent" "the refusal must say nothing was sent"
  assert_no_grep 'literal=1' "$log" "a refused typed send must type nothing at all"
  assert_no_grep 'literal=0 arg=Enter' "$log" "a refused typed send must not submit"
  [ ! -s "$dir/send.out" ] || fail "the refusal belongs on stderr, not stdout"$'\n'"$(cat "$dir/send.out")"

  # The reported incident: the worker is mid-turn driving its own validation
  # run and has typed nothing, so the composer reads empty and only the pane's
  # busy footer can tell. Typing here queues the invocation behind the running
  # turn and starts the second run.
  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    FM_FAKE_TMUX_BUSY=1 \
    "$SEND" busy-lane "/no-mistakes" >"$dir/send.out" 2>"$err"; rc=$?
  expect_code 1 "$rc" "a typed send onto a mid-turn worker must fail, not report a submit"
  got=$(cat "$err")
  assert_contains "$got" "sess:fm-busy-lane" "the mid-turn refusal must name the target it declined to type into"
  assert_contains "$got" "reads busy" \
    "the mid-turn refusal must name its own condition, not the pending-text one"
  assert_contains "$got" "Nothing was sent" "the mid-turn refusal must say nothing was sent"
  assert_no_grep 'literal=1' "$log" "a refused mid-turn send must type nothing at all"
  assert_no_grep 'literal=0 arg=Enter' "$log" "a refused mid-turn send must not submit"
  [ ! -s "$dir/send.out" ] || fail "the refusal belongs on stderr, not stdout"$'\n'"$(cat "$dir/send.out")"

  # Same mid-turn worker, plain prose instead of an invocation: this starts
  # nothing, so it must still be typed and queued behind the running turn.
  # Addressed by endpoint rather than by task id so it stays typed instead of
  # riding the inbox, but at the endpoint busy-lane.meta records - so the
  # recorded harness IS read and the busy tail IS matched, and this leg fails
  # if the guard ever stops distinguishing prose from an invocation.
  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    FM_FAKE_TMUX_BUSY=1 \
    "$SEND" sess:fm-busy-lane "when you finish this, rerun the linter" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "plain prose to a mid-turn worker must still be delivered"
  assert_contains "$(cat "$log")" "literal=1 arg=when you finish this, rerun the linter" \
    "plain prose to a mid-turn worker must still be typed"

  # Same busy footer, same invocation, but an explicit address this home holds
  # no task record for, so no harness is recorded for it. A busy token we
  # cannot attribute to the target's own harness proves nothing about the
  # target, and there is no override flag to get past a refusal, so this must
  # still be typed.
  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    FM_FAKE_TMUX_BUSY=1 \
    "$SEND" sess:win "/no-mistakes" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "an invocation to a target with no recorded harness must still be delivered"
  assert_contains "$(cat "$log")" "literal=1 arg=/no-mistakes" \
    "an unattributable busy tail must not withhold the typed text"

  # Same worker, same command, empty composer and no busy footer: the guard
  # must not have made the ordinary typed send conditional on anything else.
  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" busy-lane "/no-mistakes" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "an idle worker must still take the typed send"
  assert_contains "$(cat "$log")" "literal=1 arg=/no-mistakes" \
    "an idle worker must still receive the typed text"
  pass "fm-send typed plane: a prefilled composer and a mid-turn invocation are each refused untyped, while plain prose, an unattributable tail and an idle worker still send"
}

# A leading "$" to a codex target is read as a skill invocation when a plane is
# being chosen, and that reading is a documented over-match: "$200 is the budget
# cap" and "$HOME" are ordinary text codex never executes. Choosing the wrong
# plane over it costs nothing because both planes deliver, but refusing over it
# would block a legitimate steer outright, since the mid-turn refusal has no
# override flag. So the refusal must ask the narrower, provable question, and
# prose like this must still reach a worker that is mid-turn.
test_dollar_prose_to_a_mid_turn_codex_worker_still_sends() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/typed-busy-codex"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home typedbusycodex); err="$dir/send.err"
  log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/cdx-lane.meta" \
    "window=sess:fm-cdx-lane" "kind=ship" "harness=codex"

  # shellcheck disable=SC2016 # The leading $ is literal message bytes, not an expansion.
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    FM_FAKE_TMUX_BUSY=1 \
    "$SEND" cdx-lane '$200 is the budget cap, stay under it' >/dev/null 2>"$err"; rc=$?
  [ "$rc" != 1 ] \
    || fail "\$-prefixed prose to a mid-turn codex worker must not be refused"$'\n'"$(cat "$err")"
  got=$(cat "$log")
  # shellcheck disable=SC2016 # The leading $ is literal message bytes, not an expansion.
  assert_contains "$got" 'literal=1 arg=$200 is the budget cap, stay under it' \
    "\$-prefixed prose must still be typed into a mid-turn codex worker"
  assert_contains "$got" "target=sess:fm-cdx-lane literal=0 arg=Enter" \
    "\$-prefixed prose to a mid-turn codex worker must still be submitted"
  pass "fm-send typed plane: \$-prefixed prose executes nothing, so a mid-turn codex worker still takes it"
}

# A secondmate request is typed with the from-firstmate marker ahead of it, so
# what the harness receives is chat, not a parser command - the Stage-1
# compatibility boundary fm-send.sh documents and deliberately keeps. The
# operator's text still begins with "/", so classification calls it
# harness-native and it stays typed rather than enqueued; but nothing is
# started by it, so the mid-turn refusal must not fire. Refusing here would
# block a legitimate steer outright, since there is no override flag and the
# refusal also discards the request's pending-reply expectation.
test_marked_secondmate_invocation_still_sends_into_a_mid_turn_pane() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/typed-busy-marked"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home typedbusymarked); err="$dir/send.err"
  log="$dir/tmux.log"; : > "$log"
  mkdir -p "$home/sm"
  fm_write_meta "$home/state/lsm.meta" \
    "window=sess:fm-lsm" "harness=claude" "kind=secondmate" "mode=secondmate" "home=$home/sm"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    FM_FAKE_TMUX_BUSY=1 \
    "$SEND" lsm "/audit the ledger" >/dev/null 2>"$err"; rc=$?
  [ "$rc" != 1 ] \
    || fail "a marked secondmate request must not be refused as mid-turn"$'\n'"$(cat "$err")"
  got=$(cat "$log")
  assert_contains "$got" "literal=1" "a marked secondmate request must still be typed"
  assert_contains "$got" "/audit the ledger" "the operator's text must still reach the pane"
  assert_contains "$got" "target=sess:fm-lsm literal=0 arg=Enter" \
    "a marked secondmate request must still be submitted"
  pass "fm-send typed plane: a marked secondmate request starts nothing, so a mid-turn pane still takes it"
}

# The mid-turn rail is not a tmux rail: every spawn-supported backend reaches
# this plane, and a worker mid-turn on any of them can queue a second run the
# same way. herdr stands in for the non-tmux half because it is the one backend
# with a NATIVE agent-state, which lets this pin both rungs of the ladder.
# The second leg is the reported incident as herdr actually renders it: herdr's
# own adapter records that live Claude keeps agent_status idle through a whole
# landed turn, so a native "idle" is not evidence the worker is free and must
# not settle the question before the rendered tail is read. Only a proven busy
# verdict may refuse, so the idle-and-quiet leg must still send.
test_typed_send_refuses_a_mid_turn_non_tmux_target() {
  local dir fb home err log herdr_log rc got
  dir="$TMP_ROOT/typed-busy-herdr"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home typedbusyherdr); err="$dir/send.err"
  log="$dir/tmux.log"; herdr_log="$dir/herdr.log"; : > "$log"; : > "$herdr_log"
  fm_write_meta "$home/state/hbusy.meta" \
    "window=default:wB:p2" "backend=herdr" "herdr_session=default" "herdr_pane_id=wB:p2" \
    "kind=ship" "harness=claude"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_HERDR_LOG="$herdr_log" FM_SEND_SETTLE=0 FM_FAKE_HERDR_BUSY=1 \
    "$SEND" hbusy "/no-mistakes" >"$dir/send.out" 2>"$err"; rc=$?
  expect_code 1 "$rc" "a typed invocation onto a mid-turn herdr pane must fail, not report a submit"
  got=$(cat "$err")
  assert_contains "$got" "default:wB:p2" "the refusal must name the herdr target it declined to type into"
  assert_contains "$got" "reads busy" "the herdr refusal must name the mid-turn condition"
  assert_contains "$got" "Nothing was sent" "the herdr refusal must say nothing was sent"
  assert_no_grep 'send-text' "$herdr_log" "a refused herdr send must type nothing at all"
  assert_no_grep 'send-keys' "$herdr_log" "a refused herdr send must not submit"

  # Native agent-state says idle while the pane's own tail shows the turn still
  # running. That disagreement is the documented live shape, and the rail must
  # resolve it against the tail: taking the native idle as settled would type
  # the invocation straight into the running turn.
  : > "$herdr_log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_HERDR_LOG="$herdr_log" FM_SEND_SETTLE=0 FM_FAKE_HERDR_BUSY=1 \
    FM_FAKE_HERDR_AGENT_STATUS=idle \
    "$SEND" hbusy "/no-mistakes" >/dev/null 2>"$err"; rc=$?
  expect_code 1 "$rc" "a native idle verdict must not settle a pane whose tail is still mid-turn"
  assert_contains "$(cat "$err")" "reads busy" "the natively-idle mid-turn pane must still be refused as busy"
  assert_no_grep 'send-text' "$herdr_log" "a natively-idle mid-turn pane must be typed nothing at all"
  assert_no_grep 'send-keys' "$herdr_log" "a natively-idle mid-turn pane must not be submitted to"

  # Natively idle AND quiet: nothing proves this pane busy, so it must send.
  # Without this the rail could pass the leg above by refusing everything.
  : > "$herdr_log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_HERDR_LOG="$herdr_log" FM_SEND_SETTLE=0 FM_FAKE_HERDR_AGENT_STATUS=idle \
    "$SEND" hbusy "/no-mistakes" >/dev/null 2>"$err"; rc=$?
  [ "$rc" != 1 ] || fail "an idle, quiet herdr pane must not be refused"$'\n'"$(cat "$err")"
  assert_grep 'send-text' "$herdr_log" "an idle, quiet herdr pane must still receive the typed text"
  pass "fm-send typed plane: the mid-turn refusal reaches non-tmux backends, and a native idle verdict never settles it"
}

test_exact_lane_id_send_still_works
test_key_send_exit_status_follows_delivery
test_typed_send_refuses_an_occupied_target
test_dollar_prose_to_a_mid_turn_codex_worker_still_sends
test_marked_secondmate_invocation_still_sends_into_a_mid_turn_pane
test_typed_send_refuses_a_mid_turn_non_tmux_target
test_key_send_reports_confirmed_delivery
test_typed_submit_reports_confirmed_and_unconfirmed
test_unset_fm_home_fails
test_unresolvable_target_does_not_tmux_fallback
test_prefixless_herdr_pane_id_fails
test_unmatched_single_colon_target_must_exist
test_fm_prefixed_herdr_session_is_an_explicit_target
test_healthy_fm_id_send_still_works
