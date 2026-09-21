#!/usr/bin/env bash
# fm-validation-slot.sh - admit a no-mistakes validation run under a
# per-repository ceiling of concurrently active runs.
#
# Usage:
#   fm-validation-slot.sh read <upstream-url>
#   fm-validation-slot.sh admit <task-id> <upstream-url> [--ceiling N]
#       [--wait-secs N] [--poll-secs N] [--branch NAME]
#
# The SUPERVISING firstmate runs `admit` immediately before it sends a worker
# the pipeline trigger; a worker never runs it.
#
# Occupancy is derived, never stored. The pipeline daemon keys runs to a clone
# path, not to a repository, so one repository can own several `repos` rows
# (one per registered clone, including one per secondmate home's clone), and
# the per-clone `no-mistakes runs` listing cannot see the others. `read` opens
# NM_HOME/state.sqlite (default ~/.no-mistakes/state.sqlite) read-only the
# same way bin/fm-nm-run-lib.sh does, selects every `repos` row whose
# upstream_url normalises to <upstream-url> (lowercased, `.git` and trailing
# slash stripped, git@github.com: and ssh://git@github.com/ mapped to
# https://github.com/), and counts runs with status pending or running across
# all of them. A run parked at a gate (awaiting_agent_since set) keeps
# status running and still occupies its slot; completed, failed, cancelled
# and ci_monitor_interrupted are terminal. Runs on any other repository are
# never counted. It prints `occupied <n>` and then one line per active run:
#   <run-id> <repo-id> <branch> <status> parked_s=<secs> quiet_s=<secs>
# where quiet_s is measured from the run's newest step activity, or its
# updated_at when no step has reported.
#
# `admit` first requires `no-mistakes daemon status` to report the daemon
# running: with the daemon down every active row is unowned until the next
# daemon start reconciles it, so the helper refuses and writes nothing. It
# then takes this home's admission mutex ($FM_HOME/state/.validation-slot.lock,
# the portable lock from bin/fm-wake-lib.sh, since flock is absent on macOS)
# so two simultaneous requests cannot both read one free slot, and runs the
# read. Below the ceiling (default 2) it appends to state/<task-id>.status
#   working [at=<epoch>]: validation slot granted (<n> of <ceiling> occupied)
# and exits 0. At or above it, it appends
#   paused [at=<epoch>]: waiting for a validation slot (<n> of <ceiling> occupied)
# releases the mutex, and exits 3 so the caller retries later. The wait line
# is not repeated while it is already the task's latest status event, so the
# first wait and the grant bound the measured wait. --poll-secs N (default 0)
# re-reads every 5 seconds for up to N seconds before giving up with exit 3.
#
# A granted run's row appears only after the worker pushes through the gate,
# which happens after this command returns and the caller sends the trigger.
# So a grant hands the mutex to a detached holder process that keeps it until
# a pending or running row created at or after the grant is visible for the
# task's branch under one of the matched repo ids, or --wait-secs (default
# 60; 0 releases at once) elapses. The branch comes from --branch or the
# task's state/<task-id>.meta `branch=` line. A holder that dies leaves a
# lock the next admission reclaims through the lock's dead-owner recovery.
#
# Exit codes: 0 read printed or slot granted; 1 refused (daemon not running,
# database unreadable, no branch, mutex unavailable); 2 usage; 3 no slot
# free, retry later. Nothing here writes slot state, touches the daemon, or
# changes any database row.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
export STATE

# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

SLOT_LOCK="$STATE/.validation-slot.lock"
SLOT_WAIT_RC=3
SLOT_POLL_INTERVAL=${FM_VALIDATION_SLOT_POLL_INTERVAL:-5}

header() {
  awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"
}

usage() {
  header | sed -n '4,7p' >&2
  exit 2
}

die() {
  echo "fm-validation-slot: $*" >&2
  exit 1
}

nonneg_int() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
}

# slot_db <mode> <upstream-url> [branch since-epoch]
#   mode read: prints the occupancy report described in the header.
#   mode seen: exits 0 when an active row for <branch> created at or after
#   <since-epoch> exists under the matched repo ids, 1 when none does.
# Exits 2 when the database cannot be read.
slot_db() {
  python3 - "$@" <<'PY'
import os
import re
import sqlite3
import sys
import time
from contextlib import closing
from pathlib import Path


def norm(url):
    url = (url or "").strip().lower()
    url = re.sub(r"^git@github\.com:", "https://github.com/", url)
    url = re.sub(r"^ssh://git@github\.com/", "https://github.com/", url)
    url = url.rstrip("/")
    if url.endswith(".git"):
        url = url[:-4]
    return url.rstrip("/")


mode, target = sys.argv[1], norm(sys.argv[2])
try:
    root = Path(os.environ.get("NM_HOME") or Path.home() / ".no-mistakes")
    if not root.is_absolute():
        root = Path.cwd() / root
    with closing(sqlite3.connect((root / "state.sqlite").as_uri() + "?mode=ro", uri=True, timeout=1)) as db:
        db.execute("BEGIN")
        ids = [rid for rid, url in db.execute("SELECT id, upstream_url FROM repos") if norm(url) == target]
        marks = ",".join("?" * len(ids))
        if mode == "seen":
            branch, since = sys.argv[3], int(sys.argv[4])
            if not ids:
                sys.exit(1)
            row = db.execute(
                f"SELECT 1 FROM runs WHERE repo_id IN ({marks}) AND branch = ? "
                "AND status IN ('pending','running') AND created_at >= ? LIMIT 1",
                (*ids, branch, since)).fetchone()
            sys.exit(0 if row else 1)
        rows = []
        if ids:
            rows = db.execute(
                "SELECT r.id, r.repo_id, r.branch, r.status, r.awaiting_agent_since, r.updated_at, "
                "(SELECT MAX(s.last_activity_at) FROM step_results s WHERE s.run_id = r.id) "
                f"FROM runs r WHERE r.repo_id IN ({marks}) AND r.status IN ('pending','running') "
                "ORDER BY r.created_at, r.id", ids).fetchall()
except (OSError, ValueError, sqlite3.Error) as err:
    print(f"state database unreadable: {err}", file=sys.stderr)
    sys.exit(2)
now = int(time.time())
print("occupied", len(rows))
for rid, repo, branch, status, parked_since, updated, last_act in rows:
    parked = now - int(parked_since) if parked_since else 0
    quiet = now - int(last_act or updated or now)
    print(rid, repo, branch, status, f"parked_s={parked}", f"quiet_s={quiet}")
PY
}

slot_read() {  # <upstream-url>
  command -v python3 >/dev/null 2>&1 || die "python3 is required to read the pipeline state database"
  slot_db read "$1" || die "cannot read the pipeline state database"
}

daemon_running() {
  local out
  out=$(fm_nm_run_checked "$STATE" 10 daemon status) || return 1
  printf '%s\n' "$out" | grep -q 'daemon running'
}

append_status() {  # <task-id> <line>
  printf '%s\n' "$(status_stamp_line "$2")" >> "$STATE/$1.status"
}

# Hand the held mutex to a detached holder process, which releases it once
# the admitted run's row is visible or the hold bound passes.
hand_off_hold() {  # <upstream-url> <branch> <since-epoch> <hold-secs>
  local ownerdir holder
  if [ -L "$SLOT_LOCK" ]; then
    ownerdir=$(fm_lock_link_owner "$SLOT_LOCK") || return 1
  else
    ownerdir=$SLOT_LOCK
  fi
  bash "$SCRIPT_DIR/fm-validation-slot.sh" _hold "$1" "$2" "$3" "$(( $(date +%s) + $4 ))" \
    </dev/null >/dev/null 2>&1 &
  holder=$!
  if ! printf '%s\n' "$holder" > "$ownerdir/pid" \
    || [ "$(cat "$ownerdir/pid" 2>/dev/null)" != "$holder" ]; then
    kill "$holder" 2>/dev/null
    return 1
  fi
}

slot_hold() {  # <upstream-url> <branch> <since-epoch> <deadline-epoch>
  while [ "$(date +%s)" -lt "$4" ]; do
    slot_db seen "$1" "$2" "$3" 2>/dev/null && break
    sleep 1
  done
  fm_lock_release "$SLOT_LOCK"
}

slot_admit() {
  local task=${1:-} url=${2:-} ceiling=2 hold=60 poll=0 branch='' deadline report occupied waited=0 last
  [ -n "$task" ] && [ -n "$url" ] || usage
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ceiling) ceiling=${2:-}; shift 2 ;;
      --wait-secs) hold=${2:-}; shift 2 ;;
      --poll-secs) poll=${2:-}; shift 2 ;;
      --branch) branch=${2:-}; shift 2 ;;
      *) usage ;;
    esac
  done
  fm_pr_task_id_valid "$task" || die "invalid task id: $task"
  { nonneg_int "$hold" && nonneg_int "$poll"; } || usage
  { nonneg_int "$ceiling" && [ "$ceiling" -gt 0 ]; } || usage
  command -v python3 >/dev/null 2>&1 || die "python3 is required to read the pipeline state database"
  daemon_running || die "the no-mistakes daemon is not running; active runs are unowned until it restarts, so nothing was admitted"
  [ -n "$branch" ] || branch=$(sed -n 's/^branch=//p' "$STATE/$task.meta" 2>/dev/null | tail -n 1)
  [ -n "$branch" ] || die "no branch for $task: pass --branch or record branch= in its meta"

  deadline=$(( $(date +%s) + poll ))
  while :; do
    if ! fm_lock_acquire_wait_bounded "$SLOT_LOCK" "$(( hold + 10 ))"; then
      die "admission mutex $SLOT_LOCK is held${FM_LOCK_HELD_PID:+ by pid $FM_LOCK_HELD_PID}; retry later"
    fi
    if ! report=$(slot_db read "$url"); then
      fm_lock_release "$SLOT_LOCK"
      die "cannot read the pipeline state database"
    fi
    printf '%s\n' "$report"
    occupied=$(printf '%s\n' "$report" | sed -n 's/^occupied //p' | head -n 1)
    if [ "$occupied" -lt "$ceiling" ]; then
      append_status "$task" "working: validation slot granted ($occupied of $ceiling occupied)"
      if [ "$hold" -eq 0 ] || ! hand_off_hold "$url" "$branch" "$(date +%s)" "$hold"; then
        fm_lock_release "$SLOT_LOCK"
      fi
      echo "granted $task ($occupied of $ceiling occupied)"
      return 0
    fi
    if [ "$waited" -eq 0 ]; then
      last=$(last_status_line "$STATE/$task.status")
      case "$last" in
        paused*:*"waiting for a validation slot"*) ;;
        *) append_status "$task" "paused: waiting for a validation slot ($occupied of $ceiling occupied)" ;;
      esac
      waited=1
    fi
    fm_lock_release "$SLOT_LOCK"
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "waiting $task ($occupied of $ceiling occupied)"
      return "$SLOT_WAIT_RC"
    fi
    sleep "$SLOT_POLL_INTERVAL"
  done
}

[ "$#" -ge 1 ] || usage
verb=$1
shift
case "$verb" in
  read)
    [ "$#" -eq 1 ] || usage
    slot_read "$1"
    ;;
  admit|_hold)
    [ -d "$STATE" ] || die "state directory is unavailable: $STATE"
    # shellcheck source=bin/fm-pr-lib.sh
    . "$SCRIPT_DIR/fm-pr-lib.sh"
    # shellcheck source=bin/fm-classify-lib.sh
    . "$SCRIPT_DIR/fm-classify-lib.sh"
    # shellcheck source=bin/fm-wake-lib.sh
    FM_STATE_OVERRIDE="$STATE" . "$SCRIPT_DIR/fm-wake-lib.sh"
    if [ "$verb" = admit ]; then
      slot_admit "$@"
    else
      [ "$#" -eq 4 ] || usage
      slot_hold "$@"
    fi
    ;;
  -h|--help) header ;;
  *) usage ;;
esac
