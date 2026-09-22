#!/usr/bin/env bash
# tests/fm-control-herdr-standdown-smoke.test.sh - real-herdr smoke test for
# `bin/fm-control.sh <id> stand-down`, the close of a finished ship's endpoint.
#
# A worker held for a merge word is stood down. Stopping its agent alone leaves
# a blank shell in its pane until post-merge cleanup; stand-down closes that
# pane through the adapter's locked, focus-safe close, while the task record,
# status log, and worktree stay. This pins, against the REAL binary:
#   1. stand-down closes a done, pushed ship's pane and keeps its records;
#   2. a repeat is idempotent;
#   3. relaunch re-creates a pane for the task from its records alone, in the
#      recorded session, and the record drops the stand-down marker;
#   4. cleanup after stand-down meets the already-gone pane as ordinary and
#      still completes its landed-work test.
# The hermetic tmux counterparts live in tests/fm-control-relaunch.test.sh.
#
# No real harness is launched: the task pane holds a plain shell, which is the
# agent-free state a stopped worker leaves, and the replacement harness is an
# inert script. Always runs on a private, named, throwaway lab session, never
# the default one (tests/herdr-test-safety.sh). Skips cleanly when herdr or jq
# is missing.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION="fm-lab-standdown-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=
LAB_OWNED=0
cleanup_all() {
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  if [ "$LAB_OWNED" = 1 ]; then
    LAB_OWNED=0
    herdr_safe_stop_and_delete "$SESSION"
  fi
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"
LAB_OWNED=1

HERDR_VERSION=$(herdr --version 2>&1 | head -1)
HERDR_VERSION=${HERDR_VERSION#herdr }
version_fail() {  # <message>
  fail "$1 [herdr $HERDR_VERSION]"
}

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-control-herdr-standdown.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)
HOME_DIR="$SCRATCH/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/hsd"
touch "$HOME_DIR/state/.last-watcher-beat"
cat > "$HOME_DIR/data/hsd/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise Herdr stand-down safely.

## Firstmate spec
Close the finished worker's pane and keep its records.
EOF

# A real worktree whose branch is pushed, so nothing in it is unlanded.
PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b hsd "$WT"
git init -q --bare "$SCRATCH/origin.git"
git -C "$PROJ" remote add origin "$SCRATCH/origin.git"
git -C "$WT" push -q origin hsd
WT_REAL=$(cd "$WT" && pwd -P)
WT_HEAD=$(git -C "$WT" rev-parse HEAD)

# No validation pipeline in this lab: the current-state read must not reach a
# real one, the replacement harness is inert, and the later cleanup reads a
# merged PR at the pushed head.
FAKEBIN="$SCRATCH/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/codex" <<EOF
#!/usr/bin/env bash
: > "$SCRATCH/codex-launched"
EOF
cat > "$FAKEBIN/no-mistakes" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
# This lab worktree is not a pool slot, so cleanup's pool return is a no-op.
cat > "$FAKEBIN/treehouse" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$FAKEBIN/gh-axi" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 1 (showing first 1)" "pull_requests[1]{number,state}:" "  7,merged" ; exit 0 ;;
  "pr view") printf '%s\n' "pull_request:" "  number: 7" "  state: merged" '  merged: "2026-06-26T00:00:00Z"' ; exit 0 ;;
esac
exit 0
EOF
cat > "$FAKEBIN/gh" <<EOF
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *"state,headRefOid,url"*) printf '%s\t%s\t%s\n' MERGED '$WT_HEAD' 'https://github.com/example/repo/pull/7' ; exit 0 ;;
      *"state,headRefOid"*) printf '%s\t%s\n' MERGED '$WT_HEAD' ; exit 0 ;;
      *"headRefOid"*) printf '%s\n' '$WT_HEAD' ; exit 0 ;;
    esac ;;
esac
echo "error: pull request not found" >&2
exit 1
EOF
# Every pane the lab server opens - including the one a relaunch re-creates -
# runs this shell, which skips the user's startup files so none of them can
# put a real harness ahead of the inert one. The server starts below from this
# environment; a probe further down refuses to go on if a pane still resolves
# a real harness.
cat > "$FAKEBIN/fm-lab-shell" <<EOF
#!/usr/bin/env bash
export PATH="$FAKEBIN:\$PATH"
exec bash --norc --noprofile -i
EOF
chmod +x "$FAKEBIN/codex" "$FAKEBIN/no-mistakes" "$FAKEBIN/treehouse" "$FAKEBIN/gh-axi" "$FAKEBIN/gh" \
  "$FAKEBIN/fm-lab-shell"
export PATH="$FAKEBIN:$PATH"
export SHELL="$FAKEBIN/fm-lab-shell"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-hsd" "$WT" "$SEEDED_TAB_ID") \
  || fail "create_task failed"
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
[ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || fail "create_task did not return tab/pane ids"

{
  echo "window=$SESSION:$PANE_ID"
  echo "endpoint_task_id=hsd"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=direct-PR"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
  echo "pr=https://github.com/example/repo/pull/7"
  echo "pr_head=$WT_HEAD"
} > "$HOME_DIR/state/hsd.meta"
printf 'done [at=%s]: PR https://github.com/example/repo/pull/7\n' "$(date +%s)" > "$HOME_DIR/state/hsd.status"
STATUS_BEFORE=$(cat "$HOME_DIR/state/hsd.status")

run_fm() {  # <script> <args...>
  local script=$1
  shift
  env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=2 \
    "$ROOT/bin/$script" "$@" 2>&1
}

meta() {  # <key>
  sed -n "s/^$1=//p" "$HOME_DIR/state/hsd.meta" | tail -1
}

[ "$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")" = dead ] \
  || version_fail "the agent-free task pane does not read dead, so this run cannot model a stopped worker"

# The relaunch below delivers a real launch command into a fresh lab pane, so
# prove first that a pane of this server resolves the harness to the inert
# script and never to an installed one.
printf -v WHICH_Q '%q' "$SCRATCH/which-codex"
fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" "command -v codex > $WHICH_Q" \
  || fail "could not probe which harness a lab pane resolves"
for _ in $(seq 1 50); do
  [ ! -s "$SCRATCH/which-codex" ] || break
  sleep 0.1
done
[ "$(cat "$SCRATCH/which-codex" 2>/dev/null)" = "$FAKEBIN/codex" ] \
  || version_fail "a lab pane resolves codex to '$(cat "$SCRATCH/which-codex" 2>/dev/null)' rather than the inert test harness; refusing to relaunch a real harness"

# --- 1. stand-down closes the pane and keeps the task -----------------------

OUT=$(run_fm fm-control.sh hsd stand-down) \
  || version_fail "stand-down of a done, pushed ship on a real herdr pane failed: $OUT"
case "$OUT" in
  "stood-down hsd endpoint=closed backend=herdr closed=$SESSION:$PANE_ID"*) : ;;
  *) fail "stand-down should report the closed herdr pane, got: $OUT" ;;
esac
[ "$(fm_backend_herdr_pane_presence_state "$SESSION" "$PANE_ID")" = dead ] \
  || version_fail "the stood-down herdr pane is still present"
[ "$(meta endpoint_closed)" = "$SESSION:$PANE_ID" ] \
  || fail "the record should say stand-down closed exactly this pane"
[ "$(meta window)" = "$SESSION:$PANE_ID" ] || fail "stand-down must keep the record naming its endpoint"
[ "$(meta pr)" = https://github.com/example/repo/pull/7 ] || fail "stand-down must keep the recorded PR"
[ "$(cat "$HOME_DIR/state/hsd.status")" = "$STATUS_BEFORE" ] || fail "stand-down must not rewrite the status log"
[ "$(git -C "$WT" rev-parse HEAD)" = "$WT_HEAD" ] || fail "stand-down must leave the worktree's commits alone"
pass "real herdr $HERDR_VERSION: stand-down closes a done ship's pane and keeps its record, status log, and worktree"

# --- 2. idempotent -----------------------------------------------------------

OUT=$(run_fm fm-control.sh hsd stand-down) || fail "a repeated stand-down should be idempotent: $OUT"
case "$OUT" in
  *"endpoint=already-closed"*) : ;;
  *) fail "a repeated stand-down should report the pane already closed, got: $OUT" ;;
esac
pass "real herdr: a repeated stand-down reports the pane already closed"

# --- 3. relaunch after stand-down --------------------------------------------

OUT=$(run_fm fm-spawn.sh hsd --relaunch --harness codex) \
  || version_fail "a stood-down herdr task should relaunch into a fresh pane: $OUT"
for _ in $(seq 1 50); do
  [ ! -e "$SCRATCH/codex-launched" ] || break
  sleep 0.1
done
[ -e "$SCRATCH/codex-launched" ] || fail "the replacement harness was not launched after stand-down"
NEW_PANE_ID=$(meta herdr_pane_id)
[ -n "$NEW_PANE_ID" ] && [ "$NEW_PANE_ID" != "$PANE_ID" ] \
  || fail "the relaunch after stand-down should rebind to a fresh pane, got '$NEW_PANE_ID'"
[ "$(meta herdr_session)" = "$SESSION" ] || fail "the rebound pane must stay in the recorded herdr session"
[ "$(meta window)" = "$SESSION:$NEW_PANE_ID" ] || fail "the rebound record should name the fresh pane"
[ -z "$(meta endpoint_closed)" ] || fail "the relaunched record must drop the stand-down marker"
[ "$(meta pr)" = https://github.com/example/repo/pull/7 ] || fail "the relaunch must keep the recorded PR"
[ "$(fm_backend_herdr_current_path "$SESSION:$NEW_PANE_ID" 2>/dev/null || true)" = "$WT_REAL" ] \
  || fail "the rebound pane did not open in the recorded worktree"
PANE_ID=$NEW_PANE_ID
pass "real herdr: a stood-down task relaunches from its records into a fresh pane in its recorded session"

# --- 4. cleanup after stand-down ---------------------------------------------

# The inert harness has already exited, so the fresh pane is agent-free again.
awk -F= '$1 == "harness" {$0="harness=claude"} {print}' "$HOME_DIR/state/hsd.meta" > "$HOME_DIR/state/hsd.meta.tmp"
mv "$HOME_DIR/state/hsd.meta.tmp" "$HOME_DIR/state/hsd.meta"
OUT=$(run_fm fm-control.sh hsd stand-down) || version_fail "standing the relaunched task down failed: $OUT"
[ "$(fm_backend_herdr_pane_presence_state "$SESSION" "$PANE_ID")" = dead ] \
  || version_fail "the second stood-down herdr pane is still present"
OUT=$(run_fm fm-teardown.sh hsd) || fail "cleanup after stand-down should treat the closed pane as ordinary: $OUT"
case "$OUT" in
  *"teardown hsd complete"*) : ;;
  *) fail "cleanup after stand-down did not complete: $OUT" ;;
esac
[ ! -e "$HOME_DIR/state/hsd.meta" ] || fail "cleanup after stand-down left the task record behind"
pass "real herdr: cleanup after stand-down meets the already-closed pane as ordinary and completes"
