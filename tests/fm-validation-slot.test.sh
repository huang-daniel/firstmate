#!/usr/bin/env bash
# Behavior tests for bin/fm-validation-slot.sh: per-repository occupancy read
# from a temporary pipeline state database, and the admit grant, wait, and
# dead-daemon refusal paths.
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
  out=$("$SLOT" admit t1 "$OAS" --branch fm/t1 --wait-secs 0 2>&1); rc=$?
  expect_code 0 "$rc" "admit at 1 occupied"
  assert_contains "$out" "granted t1 (1 of 2 occupied)" "grant is reported"
  line=$(last_status_line "$STATE/t1.status")
  assert_equals "working" "$(status_line_verb "$line")" "grant line parses as working"
  status_line_at_epoch "$line" >/dev/null || fail "grant line carries a parseable at= stamp: $line"
  assert_contains "$line" "validation slot granted (1 of 2 occupied)" "grant line text"
  assert_absent "$STATE/.validation-slot.lock" "mutex released when no hold is requested"
  pass "admit grants at 1 occupied and records a parseable working event"
}

test_admit_hold_releases_when_row_appears() {
  local rc i
  reset_db
  touch "$FAKE_NM_DAEMON_UP"
  printf 'branch=fm/t2\n' > "$STATE/t2.meta"
  "$SLOT" admit t2 "$OAS" --wait-secs 30 >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "admit at 0 occupied"
  [ -L "$STATE/.validation-slot.lock" ] || [ -d "$STATE/.validation-slot.lock" ] \
    || fail "grant keeps the mutex held until the admitted run is visible"
  "$SLOT" admit t3 "$OAS" --branch fm/t3 --wait-secs 0 >/dev/null 2>&1 &
  local waiter=$!
  sleep 1
  kill -0 "$waiter" 2>/dev/null || fail "a concurrent admission waits for the held mutex"
  run_row run-t2 clone2 fm/t2 pending
  for i in $(seq 1 20); do
    [ -e "$STATE/.validation-slot.lock" ] || [ -L "$STATE/.validation-slot.lock" ] || break
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
  assert_absent "$STATE/.validation-slot.lock" "mutex released after a wait"
  pass "admit waits at 2 occupied with a parseable paused event"
}

test_admit_refuses_when_daemon_down() {
  local out rc
  reset_db
  rm -f "$FAKE_NM_DAEMON_UP" "$STATE/t5.status"
  out=$("$SLOT" admit t5 "$OAS" --branch fm/t5 2>&1); rc=$?
  expect_code 1 "$rc" "admit with the daemon down"
  assert_contains "$out" "daemon is not running" "refusal names the daemon"
  assert_absent "$STATE/t5.status" "refusal writes no status event"
  assert_absent "$STATE/.validation-slot.lock" "refusal takes no mutex"
  pass "admit refuses without writing when the daemon is down"
}

test_read_unions_clones_and_counts_only_active
test_admit_grants_below_ceiling
test_admit_hold_releases_when_row_appears
test_admit_waits_at_ceiling
test_admit_refuses_when_daemon_down
