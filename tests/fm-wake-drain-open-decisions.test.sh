#!/usr/bin/env bash
# tests/fm-wake-drain-open-decisions.test.sh - behavior tests for the OPEN
# DECISIONS section bin/fm-wake-drain.sh prints on every drain (including the
# empty-queue fast path). The section is pure wiring around
# fm-classify-lib.sh's status_open_decisions fold (the ONE authoritative
# open/resolved statement); these tests exercise the real drain script over
# crafted status logs and assert on its printed output, not on the fold's own
# source text.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-open-decisions-tests)

test_trailing_token_lists_answerable_default_key() {
  local dir state out row key padding
  dir=$(make_bordered_case trailing-token)
  state="$dir/state"
  out="$dir/drain.out"
  fm_write_meta "$state/task-default.meta" "window=sess:fm-default" "kind=ship"
  printf 'needs-decision: ask-user findings=F1,F2 file=data/task/nm-run-findings.txt [key=nm-run-review]\n' > "$state/task-default.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "trailing-token drain failed"
  row=$(grep '^task-default ' "$out")
  case "$row" in
    'task-default [key=default] needs-decision: '*'[key=nm-run-review]') : ;;
    *) fail "the folded row key is missing or confused with the note token: $row" ;;
  esac
  key=$(printf '%s\n' "$row" | sed -n 's/^task-default \[key=\([^]]*\)\] needs-decision:.*/\1/p')
  [ "$key" = default ] || fail "the printed row key is not default"
  grep -F "bin/fm-send.sh <task> --resolve-key <key> '<answer>'" "$out" >/dev/null \
    || fail "the advertised close command is missing"

  padding=$(awk 'BEGIN { while (i++ < 200) printf " extra" }')
  printf 'needs-decision: ask-user findings=F1,F2 file=data/task/nm-run-findings.txt %s [key=nm-run-review]\n' "$padding" >> "$state/task-default.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "long trailing-token drain failed"
  row=$(grep '^task-default ' "$out")
  case "$row" in
    'task-default [key=default] needs-decision: '*' [truncated]') : ;;
    *) fail "the row key did not survive the note cap: $row" ;;
  esac
  [ "${#row}" -le 219 ] || fail "the row exceeded its byte cap"

  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" \
    FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$dir/sent" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" task-default --resolve-key "$key" 'use the reviewed fix' \
    > "$dir/send.out" 2> "$dir/send.err" || fail "the printed key was refused: $(cat "$dir/send.err")"
  grep -F 'use the reviewed fix' "$dir/sent" >/dev/null || fail "the answer was not delivered"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "post-resolution drain failed"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "resolving the printed key left the decision listed: $(cat "$out")"
  fi
  pass "the trailing note token keeps an answerable default row key through truncation"
}

# Section 8 requires every listed entry to be closable by the command the
# listing advertises. A reserved-namespace key is closed only by the flow that
# raised it, so the row must say whose it is and the generic close command must
# not be advertised for it.
test_reserved_key_row_is_marked_owned_not_advertised_as_closable() {
  local dir state out
  dir=$(make_case reserved-key-listing)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'blocked [key=pending-reply-abcdef0123456789]: pending-reply-missed: task=ios pending-reply-id=abcdef0123456789 request=ship it\n' > "$state/task10.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a reserved-key row"

  grep -F 'task10' "$out" | grep -F '[key=pending-reply-abcdef0123456789]' \
    | grep -F '[owned-by=pending-reply]' >/dev/null \
    || fail "the reserved-namespace row is not marked as owned elsewhere: $(cat "$out")"
  if grep -F 'close one by answering it' "$out" >/dev/null; then
    fail "the listing advertises a close command that refuses this row: $(cat "$out")"
  fi

  # A row the reader can close themselves keeps the hint and carries no owner
  # marker, so the two kinds are distinguishable at a glance.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task11.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a mixed listing"
  grep -F "close one by answering it: bin/fm-send.sh <task> --resolve-key <key>" "$out" >/dev/null \
    || fail "a closable row lost the answerer-closes hint: $(cat "$out")"
  grep -F 'task11 [key=api-shape] needs-decision: pick REST or RPC' "$out" >/dev/null \
    || fail "the closable row was not printed without an owner marker: $(cat "$out")"
  pass "a reserved-namespace row is marked owned and never advertised as --resolve-key closable"
}

# What the section owes the reader follows from what is open, not from what fit
# in the byte budget. A listing crowded with rows owned elsewhere is exactly when
# a reader most needs to be told how to close the one row that is theirs.
test_close_hint_survives_a_closable_row_pushed_past_the_byte_cap() {
  local dir state out i note
  dir=$(make_case hint-past-cap)
  state="$dir/state"
  out="$dir/drain.out"
  note='pending-reply-missed: task=ios pending-reply-id=abcdef0123456789 request=ship the release branch once the infra freeze lifts and the queue drains'
  for i in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22; do
    printf 'blocked [key=pending-reply-abcdef012345%s]: %s\n' "$i" "$note" \
      > "$state/a$i.status"
  done
  printf 'needs-decision [key=api-shape]: pick REST or RPC for the bearings ingest, and say which of the two the crew starts with once the infra freeze lifts\n' \
    > "$state/zz.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on an over-cap listing"

  grep -F 'OPEN DECISIONS: ' "$out" | grep -F 'more omitted (byte cap)' >/dev/null \
    || fail "precondition: the listing should have omitted rows for the byte cap: $(cat "$out")"
  if grep -F 'zz [key=api-shape]' "$out" >/dev/null; then
    fail "precondition: the closable row should have been pushed past the cap: $(cat "$out")"
  fi
  grep -F "close one by answering it: bin/fm-send.sh <task> --resolve-key <key>" "$out" >/dev/null \
    || fail "the close command vanished while a closable decision was open: $(cat "$out")"
  pass "the answerer-closes hint still prints when the closable row is omitted by the byte cap"
}

test_buried_decision_still_surfaces() {
  local dir state out
  dir=$(make_case buried)
  state="$dir/state"
  out="$dir/drain.out"
  # The needs-decision line sits under later routine and unrelated-key lines,
  # exactly the burial scenario the fix targets: last-line-only reads would
  # show "resolved [key=other]" and hide the still-open api-shape decision.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task1.status"
  printf 'working: continuing other work\n' >> "$state/task1.status"
  printf 'resolved [key=other]: unrelated decision closed\n' >> "$state/task1.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a buried decision"

  grep -F 'OPEN DECISIONS' "$out" >/dev/null || fail "buried decision produced no OPEN DECISIONS section"
  grep -F 'task1' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
    || fail "buried needs-decision was not surfaced with its task, key, and note"
  grep -F "close one by answering it: bin/fm-send.sh <task> --resolve-key <key>" "$out" >/dev/null \
    || fail "open section is missing the answerer-closes hint"
  pass "a needs-decision buried under later routine/other-key lines still reports as open"
}

test_explicit_resolution_closes_it() {
  local dir state out
  dir=$(make_case resolved)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task2.status"
  printf 'resolved [key=api-shape]: went with REST\n' >> "$state/task2.status"
  printf 'done: shipped\n' >> "$state/task2.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after an explicit resolution"

  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "an explicitly resolved decision still printed as open: $(cat "$out")"
  fi
  pass "an explicit resolved [key=X] closes the keyed decision"
}

test_reserved_key_namespace_is_owned_by_its_library() {
  local dir state out
  dir=$(make_case reserved-key)
  state="$dir/state"
  out="$dir/drain.out"
  # `pending-reply-<id>` names a decision bin/fm-pending-reply-lib.sh raises and
  # is the only writer that closes it. Every writer reaches this same stream - a
  # local mate appends into it directly, and a remote mate's lines are mirrored
  # into it verbatim - so another writer must not be able to take that key over
  # or clear it just by naming it.
  printf 'blocked [key=pending-reply-abcdef0123456789]: pending-reply-missed: task=ios pending-reply-id=abcdef0123456789 request=ship it\n' > "$state/task9.status"
  printf 'blocked [key=pending-reply-abcdef0123456789]: shipping is blocked on infra\n' >> "$state/task9.status"
  printf 'resolved [key=pending-reply-abcdef0123456789]: all good now\n' >> "$state/task9.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on reserved-key lines"

  grep -F 'pending-reply-id=abcdef0123456789' "$out" >/dev/null \
    || fail "a foreign resolution cleared a reserved decision it does not own: $(cat "$out")"
  if grep -F 'shipping is blocked on infra' "$out" >/dev/null; then
    fail "a foreign line took over a reserved decision key: $(cat "$out")"
  fi

  # The owner's own resolution, which speaks that namespace's vocabulary, closes it.
  printf 'resolved [key=pending-reply-abcdef0123456789]: pending-reply-resolved: task=ios pending-reply-id=abcdef0123456789 via=status\n' >> "$state/task9.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after the owner closed its decision"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the owner's own resolution did not close its reserved decision: $(cat "$out")"
  fi
  pass "a reserved decision key can only be opened or closed by its owning library"
}

test_later_unrelated_terminal_line_does_not_close_it() {
  local dir state out
  dir=$(make_case unrelated-terminal)
  state="$dir/state"
  out="$dir/drain.out"
  # A later done: with no matching [key=...] token opens/closes only the
  # "default" key; it must never clear the still-open api-shape decision.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task3.status"
  printf 'done: unrelated later milestone\n' >> "$state/task3.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after an unrelated terminal line"

  grep -F 'task3' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
    || fail "a later unrelated terminal line incorrectly cleared the open decision"
  pass "a later unrelated terminal line never clears an open decision"
}

test_no_open_decisions_prints_nothing() {
  local dir state out
  dir=$(make_case none-open)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'working: on it\n' > "$state/task4.status"
  printf 'resolved: shipped clean\n' > "$state/task5.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with no open decisions"

  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the empty case printed an OPEN DECISIONS section: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the empty case with no queued wakes was not silent: $(cat "$out")"
  pass "no open decisions across the fleet prints nothing"
}

test_open_decision_surfaces_even_with_an_unrelated_queued_wake() {
  local dir state out
  dir=$(make_case fleet-wide)
  state="$dir/state"
  out="$dir/drain.out"
  # task6 has a buried, still-open decision but generates NO new queue record
  # this turn; task7 is what actually wakes the drain. The fleet-wide scan
  # must still catch task6's decision alongside task7's own raw row.
  printf 'needs-decision [key=migration]: pick the rollout plan\n' > "$state/task6.status"
  printf 'working: continuing\n' >> "$state/task6.status"
  printf 'blocked: waiting on credentials\n' > "$state/task7.status"
  append_wake "$state" signal task7.status "blocked: waiting on credentials" \
    || fail "queueing the unrelated wake failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with a mixed fleet"

  grep "$(printf '\tsignal\ttask7.status\t')" "$out" >/dev/null || fail "task7's own raw row is missing"
  grep -F 'task6' "$out" | grep -F '[key=migration]' >/dev/null \
    || fail "task6's buried decision was not surfaced even though only task7 queued a wake"
  pass "the open-decision section is fleet-wide, not scoped to this drain's own queued records"
}

test_buried_decision_surfaces_on_the_empty_queue_fast_path() {
  local dir state out
  dir=$(make_case empty-queue-fast-path)
  state="$dir/state"
  out="$dir/drain.out"
  # No wake is queued at all (the empty-queue exit), but the decision is still
  # open on disk - session-start relies on exactly this path.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task8.status"
  printf 'working: continuing\n' >> "$state/task8.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "empty-queue drain failed"

  grep -F 'task8' "$out" | grep -F '[key=api-shape]' >/dev/null \
    || fail "the empty-queue fast path did not surface a still-open decision"
  pass "a buried open decision surfaces even when the wake queue itself is empty"
}

test_status_symlink_is_not_followed() {
  local dir state out
  dir=$(make_case status-symlink)
  state="$dir/state"
  out="$dir/drain.out"
  mkdir -p "$dir/outside"
  printf 'needs-decision [key=local]: keep this visible\n' > "$state/local.status"
  printf 'needs-decision [key=foreign]: do not expose this\n' > "$dir/outside/foreign.status"
  ln -s ../outside/foreign.status "$state/linked.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with a symlinked status file"

  grep -F 'local [key=local] needs-decision: keep this visible' "$out" >/dev/null \
    || fail "the valid local decision did not surface alongside a rejected status symlink"
  if grep -F 'do not expose this' "$out" >/dev/null; then
    fail "the fleet scan followed a status symlink outside the state directory"
  fi
  pass "the fleet-wide decision scan does not follow status symlinks"
}

# The per-item cut now comes from bin/fm-line-cap-lib.sh, shared with the
# session-start digest's status tails so one truncation marker means the same
# thing wherever an agent meets it. This pins the drain's own end of that
# contract: the lede survives, the marker appears, and the item still fits the
# section's per-item budget including the newline it is charged for.
test_over_long_decision_note_is_capped_with_a_marker() {
  local dir state out line longest
  dir=$(make_case long-note)
  state="$dir/state"
  out="$dir/drain.out"
  {
    printf 'needs-decision [key=api-shape]: pick REST or RPC'
    awk 'BEGIN { while (i++ < 200) printf " and-then-some" }'
    printf '\n'
  } > "$state/task-long.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on an over-long decision note"

  line=$(grep -F 'task-long' "$out")
  case "$line" in
    'task-long [key=api-shape] needs-decision: pick REST or RPC'*' [truncated]') : ;;
    *) fail "an over-long decision note was not capped with its lede intact: $line" ;;
  esac
  longest=${#line}
  [ "$longest" -le 219 ] || fail "a capped decision item ran $longest characters past its per-item budget"

  printf 'needs-decision [key=short]: brief enough to keep whole\n' > "$state/task-short.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a short decision note"
  grep -F 'task-short [key=short] needs-decision: brief enough to keep whole' "$out" >/dev/null \
    || fail "a decision note already under the cap was altered"
  if grep -F 'brief enough to keep whole [truncated]' "$out" >/dev/null; then
    fail "a decision note already under the cap was marked truncated"
  fi

  pass "an over-long open decision is cut to its per-item budget with the shared truncation marker"
}

test_trailing_token_lists_answerable_default_key
test_reserved_key_row_is_marked_owned_not_advertised_as_closable
test_close_hint_survives_a_closable_row_pushed_past_the_byte_cap
test_buried_decision_still_surfaces
test_over_long_decision_note_is_capped_with_a_marker
test_explicit_resolution_closes_it
test_later_unrelated_terminal_line_does_not_close_it
test_reserved_key_namespace_is_owned_by_its_library
test_no_open_decisions_prints_nothing
test_open_decision_surfaces_even_with_an_unrelated_queued_wake
test_buried_decision_surfaces_on_the_empty_queue_fast_path
test_status_symlink_is_not_followed
