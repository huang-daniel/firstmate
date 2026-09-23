#!/usr/bin/env bash
# tests/fm-secondmate-health.test.sh - bin/fm-secondmate-health.sh, the reads a
# parent uses to tell whether a second mate's running agent is stale, whether it
# can be restarted right now, and whether a replacement came up healthy.
#
# What these pin, through the real command against real git homes and real
# processes:
#   - record binds the lock-holding session to the commit and instruction
#     surface it started on, and self reports it beside the home's current HEAD.
#   - stale reads current when that surface is unchanged, stale naming the
#     changed paths when it moved, and unknown when no live lock holder has
#     recorded its revision (including a record left by a different session).
#   - idle comes from the mate's semantic busy record: provable busy and idle
#     are reported with their source, and a mate with no record reads unknown.
#   - verify accepts only a new live lock holder reporting the intended surface,
#     names a lock collision with the previous session, and reports anything it
#     cannot prove as unknown.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HEALTH="$ROOT/bin/fm-secondmate-health.sh"
fm_git_identity fmtest fmtest@example.com
TMP_ROOT=$(fm_test_tmproot fm-secondmate-health)

PIDS_FILE="$TMP_ROOT/fake-harness.pids"
kill_fake_harnesses() {
  local pid
  [ -f "$PIDS_FILE" ] || return 0
  while IFS= read -r pid; do kill "$pid" 2>/dev/null || true; done < "$PIDS_FILE"
}
trap 'kill_fake_harnesses; fm_test_cleanup' EXIT

# A live process whose argv[0] names a verified harness. Prints its pid.
start_fake_harness() {
  local pid
  bash -c 'exec -a claude "$0" 600' "$(command -v sleep)" </dev/null >/dev/null 2>&1 &
  pid=$!
  printf '%s\n' "$pid" >> "$PIDS_FILE"
  printf '%s\n' "$pid"
}

# new_world <name>: a parent home plus one local mate home that is a real git
# checkout carrying the instruction surface. Prints the world dir.
new_world() {
  local w="$TMP_ROOT/$1" smhome
  smhome="$w/sm1-home"
  mkdir -p "$w/home/state" "$smhome/bin" "$smhome/.agents/skills"
  git -C "$smhome" init -q
  printf '# agents\n' > "$smhome/AGENTS.md"
  printf 'echo a\n' > "$smhome/bin/tool.sh"
  printf 's\n' > "$smhome/.agents/skills/s.md"
  printf 'state/\n' > "$smhome/.gitignore"
  git -C "$smhome" add -A
  git -C "$smhome" commit -qm c1
  mkdir -p "$smhome/state"
  fm_write_meta "$w/home/state/sm1.meta" window=fmses:fm-sm1 endpoint_task_id=sm1 \
    "worktree=$smhome" "project=$smhome" harness=claude kind=secondmate "home=$smhome"
  printf '%s\n' "$w"
}

# session_start <world>: model a mate session start - take the lock, record.
session_start() {
  local w=$1 pid
  pid=$(start_fake_harness)
  printf '%s\n' "$pid" > "$w/sm1-home/state/.lock"
  FM_HOME="$w/sm1-home" FM_ROOT_OVERRIDE="$w/sm1-home" FM_STATE_OVERRIDE='' "$HEALTH" record \
    || fail "record failed"
  printf '%s\n' "$pid"
}

health() {  # <world> <args...>
  local w=$1
  shift
  FM_HOME="$w/home" "$HEALTH" "$@"
}

test_record_and_self_report_the_running_session() {
  local w pid report head
  w=$(new_world self)
  pid=$(session_start "$w")
  head=$(git -C "$w/sm1-home" rev-parse HEAD)

  report=$(FM_HOME="$w/sm1-home" "$HEALTH" self)

  assert_contains "$report" "lock_pid=$pid" "self must report the lock holder"
  assert_contains "$report" "lock_live=yes" "a live harness lock holder must read live"
  assert_contains "$report" "session_pid=$pid" "the record must be bound to the lock holder"
  assert_contains "$report" "session_commit=$head" "the record must carry the commit it started on"
  assert_contains "$report" "head_commit=$head" "self must report the home's current commit"
  assert_contains "$report" "session_instr=AGENTS.md:" "the record must carry the instruction surface"
  pass "record/self: the lock-holding session reports the revision it started on"
}

test_stale_reads_current_stale_and_unknown() {
  local w out
  w=$(new_world stale)

  out=$(health "$w" stale sm1)
  assert_contains "$out" "unknown sm1: no live session holds its home lock" \
    "with no live session the running revision is not provable"

  session_start "$w" >/dev/null
  out=$(health "$w" stale fm-sm1)
  assert_contains "$out" "current sm1 commit=" "an unchanged surface must read current"

  # A docs-only commit moves HEAD but not the instruction surface.
  printf 'doc\n' > "$w/sm1-home/README.md"
  git -C "$w/sm1-home" add README.md
  git -C "$w/sm1-home" commit -qm docs
  out=$(health "$w" stale sm1)
  assert_contains "$out" "current sm1" "a change outside the instruction surface must not read stale"

  printf 'echo b\n' > "$w/sm1-home/bin/tool.sh"
  git -C "$w/sm1-home" commit -qam tool
  out=$(health "$w" stale sm1)
  assert_contains "$out" "stale sm1 launched=" "a moved instruction surface must read stale"
  assert_contains "$out" "changed=bin " "stale must name exactly the changed paths"
  assert_contains "$out" "head_instr=AGENTS.md:" "stale must carry the intended surface for a restart"

  # A different live session now holds the lock without having recorded.
  start_fake_harness > "$w/sm1-home/state/.lock"
  out=$(health "$w" stale sm1)
  assert_contains "$out" "has not recorded the revision it started on" \
    "a record from another session must not vouch for the current lock holder"
  pass "stale: current, stale with changed paths, and unknown are distinguished"
}

test_idle_reads_the_busy_record() {
  local w out
  w=$(new_world idle)

  # The endpoint read needs a tmux that reports the window present.
  mkdir -p "$w/fakebin"
  cat > "$w/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf '%s\n' fm-sm1 ;;
  display-message) printf 'claude\n' ;;
esac
exit 0
SH
  chmod +x "$w/fakebin/tmux"
  out=$(PATH="$w/fakebin:$PATH" TMUX='' health "$w" idle sm1)
  assert_contains "$out" "unknown missing" "a mate with no busy record must read unknown, never idle"

  "$ROOT/bin/fm-busy-event.sh" arm "$w/home/state" sm1 --state busy --source claude-hook --event t >/dev/null
  out=$(PATH="$w/fakebin:$PATH" TMUX='' health "$w" idle sm1)
  assert_contains "$out" "busy claude-hook" "a busy record must read busy with its source"

  "$ROOT/bin/fm-busy-event.sh" apply "$w/home/state" sm1 idle --current-gen --source claude-hook --event stop >/dev/null
  out=$(PATH="$w/fakebin:$PATH" TMUX='' health "$w" idle sm1)
  assert_contains "$out" "idle claude-hook" "an idle record must read idle with its source"
  pass "idle: reads the semantic busy record and never promotes a missing one to idle"
}

test_verify_proves_or_reports_unknown() {
  local w old new out rc instr
  w=$(new_world verify)
  mkdir -p "$w/fakebin"
  cat > "$w/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf '%s\n' fm-sm1 ;;
  display-message) printf 'claude\n' ;;
esac
exit 0
SH
  chmod +x "$w/fakebin/tmux"
  old=$(session_start "$w")
  instr=$(FM_HOME="$w/sm1-home" "$HEALTH" self | sed -n 's/^head_instr=//p')

  out=$(PATH="$w/fakebin:$PATH" TMUX='' FM_SECONDMATE_VERIFY_POLL=1 \
    health "$w" verify sm1 --prior-pid "$old" --expect-instr "$instr" --wait 0); rc=$?
  expect_code 3 "$rc" "the old session still holding the lock is not a healthy replacement"
  assert_contains "$out" "lock collision: its home lock is still held by the previous session (pid $old)" \
    "verify must name a lock collision with the previous session"

  kill "$old" 2>/dev/null
  new=$(session_start "$w")
  out=$(PATH="$w/fakebin:$PATH" TMUX='' health "$w" verify sm1 --prior-pid "$old" --expect-instr "$instr" --wait 0); rc=$?
  expect_code 0 "$rc" "a new live lock holder on the intended surface is verified: $out"
  assert_contains "$out" "verified sm1 pid=$new" "verify must name the verified replacement"

  out=$(PATH="$w/fakebin:$PATH" TMUX='' health "$w" verify sm1 --prior-pid "$old" \
    --expect-instr "AGENTS.md:x,bin:y,.agents/skills:z" --wait 0); rc=$?
  expect_code 3 "$rc" "a replacement on another revision is not verified"
  assert_contains "$out" "whose instruction surface differs from the intended one" \
    "verify must report a revision mismatch as unknown"
  out=$(PATH="$w/fakebin:$PATH" TMUX='' health "$w" verify sm1 --wait 0); rc=$?
  expect_code 3 "$rc" "missing intended identity must not verify"
  assert_contains "$out" "intended instruction identity is missing" "missing identity must be explicit"
  sed '/^instr=/d' "$w/sm1-home/state/.session-revision" > "$w/revision"
  mv "$w/revision" "$w/sm1-home/state/.session-revision"
  out=$(PATH="$w/fakebin:$PATH" TMUX='' health "$w" verify sm1 --expect-instr "$instr" --wait 0); rc=$?
  expect_code 3 "$rc" "missing reported identity must not verify"
  assert_contains "$out" "has not reported its revision" "missing report must be explicit"
  pass "verify: accepts only a new live lock holder on the intended surface, names a collision"
}

test_record_and_self_report_the_running_session
test_stale_reads_current_stale_and_unknown
test_idle_reads_the_busy_record
test_verify_proves_or_reports_unknown

echo "# all fm-secondmate-health tests passed"
