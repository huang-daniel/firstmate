#!/usr/bin/env bash
# Behavior tests for bin/fm-validation-slot.sh: per-repository occupancy read
# from a temporary pipeline state database, the admit grant, hold, lapse,
# cross-home mutex, wait, and dead-daemon refusal paths, and the shared run
# library's terminal classification of ci_monitor_interrupted.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

command -v python3 >/dev/null 2>&1 || fail "python3 is required for the state database fixture"

TMP_ROOT=$(fm_test_tmproot fm-validation-slot)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "$1 $2" = "daemon status" ]; then
  if [ -e "$FAKE_NM_DAEMON_UP" ]; then
    echo "  ● daemon running (pid 4242)"
    exit 0
  fi
  echo "  ○ daemon not running"
  exit 1
fi
exit 1
SH
chmod +x "$FAKEBIN/no-mistakes"
export PATH="$FAKEBIN:$PATH"
export FAKE_NM_DAEMON_UP="$TMP_ROOT/daemon-up"
export NM_HOME="$TMP_ROOT/nm"
export FM_HOME="$TMP_ROOT/home"
mkdir -p "$NM_HOME" "$FM_HOME/state"
STATE="$FM_HOME/state"
SLOT="$ROOT/bin/fm-validation-slot.sh"
OAS=https://github.com/example-org/example-repo

# db <sql...>: run statements against the fixture database, creating the
# schema subset the helper reads on first use.
db() {
  python3 - "$NM_HOME/state.sqlite" "$@" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.executescript("""
CREATE TABLE IF NOT EXISTS repos(id TEXT PRIMARY KEY, working_path TEXT UNIQUE, upstream_url TEXT,
  fork_url TEXT, default_branch TEXT, created_at INTEGER);
CREATE TABLE IF NOT EXISTS runs(id TEXT PRIMARY KEY, repo_id TEXT, branch TEXT, head_sha TEXT,
  base_sha TEXT, status TEXT, pr_url TEXT, worktree_dir TEXT, awaiting_agent_since INTEGER,
  parked_ms INTEGER, error TEXT, created_at INTEGER, updated_at INTEGER);
CREATE TABLE IF NOT EXISTS step_results(id TEXT PRIMARY KEY, run_id TEXT, step_name TEXT,
  step_order INTEGER, status TEXT, started_at INTEGER, completed_at INTEGER,
  last_activity_at INTEGER, last_activity TEXT);
""")
for stmt in sys.argv[2:]:
    con.execute(stmt)
con.commit()
PY
}

# run_row <id> <repo> <branch> <status> [awaiting_agent_since]
run_row() {
  local now
  now=$(date +%s)
  db "INSERT INTO runs(id, repo_id, branch, head_sha, status, awaiting_agent_since, created_at, updated_at)
      VALUES ('$1', '$2', '$3', 'abc1234', '$4', ${5:-NULL}, $now, $now)"
}

# meta <task> [home]: record the task in a home so admit accepts it there.
meta() {
  printf 'window=fm:%s\n' "$1" > "${2:-$FM_HOME}/state/$1.meta"
}

reset_db() {
  rm -f "$NM_HOME/state.sqlite"
  db "INSERT INTO repos(id, working_path, upstream_url) VALUES
      ('clone1', '/c/one', 'https://github.com/example-org/example-repo.git'),
      ('clone2', '/c/two', 'git@github.com:Example-Org/example-repo'),
      ('clone3', '/c/three', 'ssh://git@github.com/example-org/example-repo/'),
      ('other', '/c/other', 'https://github.com/example-org/other-repo')"
}

test_read_unions_clones_and_counts_only_active() {
  local out parked_since
  reset_db
  parked_since=$(( $(date +%s) - 300 ))
  run_row run-a clone1 fm/a running
  run_row run-b clone2 fm/b running "$parked_since"
  run_row run-c clone3 fm/c pending
  run_row run-d clone1 fm/d completed
  run_row run-e clone2 fm/e failed
  run_row run-f clone3 fm/f cancelled
  run_row run-g clone1 fm/g ci_monitor_interrupted
  run_row run-h other fm/h running
  out=$("$SLOT" read "$OAS.git") || fail "read exited nonzero"
  assert_contains "$out" "occupied 3" "read unions every clone record of one repository"
  assert_contains "$out" "run-a clone1 fm/a running" "https .git clone row is counted"
  assert_contains "$out" "run-b clone2 fm/b running" "git@ spelling normalises with the rest"
  assert_contains "$out" "run-c clone3 fm/c pending" "ssh:// spelling with trailing slash normalises"
  case "$out" in *"run-b clone2 fm/b running parked_s=3"[0-9][0-9]*) ;; *) fail "parked row reports its parked seconds: $out" ;; esac
  for id in run-d run-e run-f run-g run-h; do
    assert_not_contains "$out" "$id" "terminal or other-repository row $id is not counted"
  done
  out=$("$SLOT" read "git@github.com:example-org/example-repo") || fail "ssh-form read exited nonzero"
  assert_contains "$out" "occupied 3" "an ssh-form argument selects the same repository"
  pass "read unions clones, normalises spellings, counts parked rows, ignores terminal rows"
}

test_admit_grants_below_ceiling() {
  local out rc line
  reset_db
  run_row run-a clone1 fm/a running
  touch "$FAKE_NM_DAEMON_UP"
  rm -f "$STATE/t1.status"
  meta t1
  out=$("$SLOT" admit t1 "$OAS" --branch fm/t1 --wait-secs 0 2>&1); rc=$?
  expect_code 0 "$rc" "admit at 1 occupied"
  assert_contains "$out" "granted t1 (1 of 2 occupied)" "grant is reported"
  line=$(last_status_line "$STATE/t1.status")
  assert_equals "working" "$(status_line_verb "$line")" "grant line parses as working"
  status_line_at_epoch "$line" >/dev/null || fail "grant line carries a parseable at= stamp: $line"
  assert_contains "$line" "validation slot granted (1 of 2 occupied)" "grant line text"
  assert_absent "$NM_HOME/.validation-slot.lock" "mutex released when no hold is requested"
  pass "admit grants at 1 occupied and records a parseable working event"
}

test_admit_hold_releases_when_row_appears() {
  local rc i
  reset_db
  touch "$FAKE_NM_DAEMON_UP"
  printf 'branch=fm/t2\n' > "$STATE/t2.meta"
  "$SLOT" admit t2 "$OAS" --wait-secs 30 >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "admit at 0 occupied"
  [ -L "$NM_HOME/.validation-slot.lock" ] || [ -d "$NM_HOME/.validation-slot.lock" ] \
    || fail "grant keeps the mutex held until the admitted run is visible"
  meta t3
  "$SLOT" admit t3 "$OAS" --branch fm/t3 --wait-secs 0 >/dev/null 2>&1 &
  local waiter=$!
  sleep 1
  kill -0 "$waiter" 2>/dev/null || fail "a concurrent admission waits for the held mutex"
  run_row run-t2 clone2 fm/t2 pending
  for i in $(seq 1 20); do
    [ -e "$NM_HOME/.validation-slot.lock" ] || [ -L "$NM_HOME/.validation-slot.lock" ] || break
    sleep 0.5
  done
  wait "$waiter"; rc=$?
  expect_code 0 "$rc" "queued admission proceeds after the hold is released"
  assert_contains "$(last_status_line "$STATE/t3.status")" "(1 of 2 occupied)" \
    "queued admission sees the admitted run"
  [ "$i" -lt 20 ] || fail "hold released after the admitted run's row appeared"
  pass "grant hold keeps the mutex until the admitted run's row is visible"
}

test_admit_waits_at_ceiling() {
  local out rc line
  reset_db
  run_row run-a clone1 fm/a running
  run_row run-b clone2 fm/b running "$(date +%s)"
  touch "$FAKE_NM_DAEMON_UP"
  rm -f "$STATE/t4.status"
  meta t4
  out=$("$SLOT" admit t4 "$OAS" --branch fm/t4 2>&1); rc=$?
  expect_code 3 "$rc" "admit at 2 occupied"
  assert_contains "$out" "waiting t4 (2 of 2 occupied)" "wait is reported"
  line=$(last_status_line "$STATE/t4.status")
  status_is_paused "$line" || fail "wait line parses as paused: $line"
  status_line_at_epoch "$line" >/dev/null || fail "wait line carries a parseable at= stamp: $line"
  assert_contains "$line" "waiting for a validation slot (2 of 2 occupied)" "wait line text"
  "$SLOT" admit t4 "$OAS" --branch fm/t4 >/dev/null 2>&1; rc=$?
  expect_code 3 "$rc" "repeat admit at 2 occupied"
  assert_equals 1 "$(grep -c 'waiting for a validation slot' "$STATE/t4.status")" \
    "a repeated wait does not append a second wait event"
  assert_absent "$NM_HOME/.validation-slot.lock" "mutex released after a wait"
  pass "admit waits at 2 occupied with a parseable paused event"
}

test_admit_refuses_when_daemon_down() {
  local out rc
  reset_db
  rm -f "$FAKE_NM_DAEMON_UP" "$STATE/t5.status"
  meta t5
  out=$("$SLOT" admit t5 "$OAS" --branch fm/t5 2>&1); rc=$?
  expect_code 1 "$rc" "admit with the daemon down"
  assert_contains "$out" "daemon is not running" "refusal names the daemon"
  assert_absent "$STATE/t5.status" "refusal writes no status event"
  assert_absent "$NM_HOME/.validation-slot.lock" "refusal takes no mutex"
  pass "admit refuses without writing when the daemon is down"
}

wait_lock_gone() {  # <tries>
  local i
  for i in $(seq 1 "$1"); do
    [ -e "$NM_HOME/.validation-slot.lock" ] || [ -L "$NM_HOME/.validation-slot.lock" ] || return 0
    sleep 0.5
  done
  return 1
}

test_admit_mutex_is_shared_across_homes() {
  local rc other=$TMP_ROOT/other-home waiter
  reset_db
  run_row run-a clone1 fm/a running
  touch "$FAKE_NM_DAEMON_UP"
  mkdir -p "$other/state"
  meta t6
  "$SLOT" admit t6 "$OAS" --branch fm/t6 --wait-secs 30 >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "primary-home admit at 1 occupied"
  meta t7 "$other"
  FM_HOME=$other "$SLOT" admit t7 "$OAS" --branch fm/t7 --wait-secs 0 >/dev/null 2>&1 &
  waiter=$!
  sleep 1
  kill -0 "$waiter" 2>/dev/null || fail "another home's admission waits for the shared mutex"
  run_row run-t6 clone2 fm/t6 pending
  wait_lock_gone 20 || fail "hold released after the admitted run's row appeared"
  wait "$waiter"; rc=$?
  expect_code 3 "$rc" "the other home's admission sees 2 occupied"
  assert_contains "$(last_status_line "$other/state/t7.status")" "waiting for a validation slot (2 of 2 occupied)" \
    "the other home's request waits instead of starting a third run"
  pass "every home admits under one shared mutex beside the state database"
}

test_admit_hold_ends_when_task_leaves_granted_state() {
  local rc
  reset_db
  touch "$FAKE_NM_DAEMON_UP"
  rm -f "$STATE/t8.status"
  meta t8
  "$SLOT" admit t8 "$OAS" --branch fm/t8 --wait-secs 30 >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "admit at 0 occupied"
  [ -L "$NM_HOME/.validation-slot.lock" ] || [ -d "$NM_HOME/.validation-slot.lock" ] \
    || fail "grant keeps the mutex held"
  printf '%s\n' "$(status_stamp_line "failed: worker lost")" >> "$STATE/t8.status"
  wait_lock_gone 20 || fail "hold released once the task left its granted state"
  assert_not_contains "$(cat "$STATE/t8.status")" "lapsed" "a left grant is not reported as lapsed"
  pass "grant hold ends when the task's latest event is no longer the grant"
}

test_admit_hold_lapses_unconsumed() {
  local rc line
  reset_db
  touch "$FAKE_NM_DAEMON_UP"
  rm -f "$STATE/t9.status"
  meta t9
  "$SLOT" admit t9 "$OAS" --branch fm/t9 --wait-secs 2 >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "admit at 0 occupied"
  wait_lock_gone 20 || fail "hold released at its bound"
  line=$(last_status_line "$STATE/t9.status")
  assert_equals "note" "$(status_line_verb "$line")" "lapse line parses as a note"
  status_line_at_epoch "$line" >/dev/null || fail "lapse line carries a parseable at= stamp: $line"
  assert_contains "$line" "validation slot grant lapsed unconsumed after 2s" "lapse line text"
  pass "an unconsumed grant lapses at its bound with a note event"
}

test_admit_refuses_without_task_meta_in_home() {
  local out rc other=$TMP_ROOT/owner-home
  reset_db
  touch "$FAKE_NM_DAEMON_UP"
  mkdir -p "$other/state"
  meta t10 "$other"
  rm -f "$STATE/t10.status" "$STATE/t10.meta"
  out=$("$SLOT" admit t10 "$OAS" --branch fm/t10 --wait-secs 0 2>&1); rc=$?
  expect_code 1 "$rc" "admit from a home that does not own the task"
  assert_contains "$out" "FM_HOME" "refusal names the owning-home requirement"
  assert_absent "$STATE/t10.status" "a wrong-home admit writes no status event"
  assert_absent "$NM_HOME/.validation-slot.lock" "a wrong-home admit takes no mutex"
  FM_HOME=$other "$SLOT" admit t10 "$OAS" --branch fm/t10 --wait-secs 0 >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "admit with FM_HOME set to the owning home"
  assert_contains "$(last_status_line "$other/state/t10.status")" "validation slot granted" \
    "the grant lands in the owning home's status log"
  pass "admit refuses without writing unless run in the task's owning home"
}

test_admit_hold_releases_on_fast_terminal_row() {
  local rc
  reset_db
  touch "$FAKE_NM_DAEMON_UP"
  meta t11
  rm -f "$STATE/t11.status"
  "$SLOT" admit t11 "$OAS" --branch fm/t11 --wait-secs 30 >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "admit at 0 occupied"
  run_row run-t11 clone3 fm/t11 failed
  wait_lock_gone 20 || fail "hold released once the admitted run's row exists, whatever its status"
  assert_not_contains "$(cat "$STATE/t11.status")" "lapsed" "a consumed grant is not reported as lapsed"
  pass "grant hold ends when the admitted run already reached a terminal status"
}

test_ci_monitor_interrupted_is_terminal() {
  local overview out
  out=$(. "$ROOT/bin/fm-nm-run-lib.sh"; fm_nm_run_status_class ci_monitor_interrupted)
  assert_equals "terminal" "$out" "ci_monitor_interrupted classifies as terminal"
  overview='count: 2 of 2 total
runs[2]{id,branch,status,head,pr}:
  01NEW,fm/x,ci_monitor_interrupted,abc1234,""
  01OLD,fm/x,failed,abc1234,""'
  out=$(. "$ROOT/bin/fm-nm-run-lib.sh"; fm_nm_select_run fm/x "$overview" "$TMP_ROOT")
  assert_equals "selected|01NEW|ci_monitor_interrupted|01NEW, 01OLD" "$out" \
    "an overview row in ci_monitor_interrupted is selected, not flagged unknown"
  out=$(. "$ROOT/bin/fm-nm-run-lib.sh"; fm_nm_select_run fm/x "${overview/ci_monitor_interrupted/mystery}" "$TMP_ROOT")
  assert_contains "$out" "unknown|unrecognized run status" "an unlisted status is still flagged unknown"
  pass "ci_monitor_interrupted is a terminal run status in the shared run library"
}

test_read_unions_clones_and_counts_only_active
test_admit_grants_below_ceiling
test_admit_hold_releases_when_row_appears
test_admit_waits_at_ceiling
test_admit_refuses_when_daemon_down
test_admit_mutex_is_shared_across_homes
test_admit_hold_ends_when_task_leaves_granted_state
test_admit_hold_lapses_unconsumed
test_admit_refuses_without_task_meta_in_home
test_admit_hold_releases_on_fast_terminal_row
test_ci_monitor_interrupted_is_terminal
