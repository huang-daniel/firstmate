#!/usr/bin/env bash
# Isolated real-Herdr E2E coverage for the default-on disposable single-task
# presentation projection, its explicit opt-out, and its best-effort
# owning-parent ordering across primary and secondmate homes.
# The test drives the real spawn and teardown scripts, a real Treehouse pool,
# and the guarded named-session lab helper.
set -u

ROOT='/home/dev/.no-mistakes/worktrees/222d8f0053d8/01M35N3Y6M9S0M7259KYNFPXHV'
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found"; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

REAL_HERDR=$(command -v herdr)
REAL_TREEHOUSE=$(command -v treehouse)
HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-presentation.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
HERDR_CALL_LOG="$TMP_ROOT/herdr-calls.log"
TREEHOUSE_CALL_LOG="$TMP_ROOT/treehouse-calls.log"
TREEHOUSE_LOCK_DIR="$TMP_ROOT/treehouse-call.lock"
MOVE_CALL_LOG="$TMP_ROOT/workspace-move-calls.log"
FOCUS_AUDIT_LOG="$TMP_ROOT/focus-audit.log"
ACTIVE_SEEDED_CONTROL="$TMP_ROOT/active-seeded-control"
POST_CREATE_ABORT_CONTROL="$TMP_ROOT/post-create-abort-control"
LIVE_VIEWER_CONTROL="$TMP_ROOT/live-viewer-control"
mkdir -p "$FAKEBIN"
: > "$HERDR_CALL_LOG"
: > "$TREEHOUSE_CALL_LOG"
: > "$MOVE_CALL_LOG"
: > "$FOCUS_AUDIT_LOG"
REAL_MOVER="$ROOT/bin/backends/herdr-workspace-move.py"
export REAL_HERDR REAL_TREEHOUSE REAL_MOVER HERDR_CALL_LOG TREEHOUSE_CALL_LOG TREEHOUSE_LOCK_DIR MOVE_CALL_LOG FOCUS_AUDIT_LOG HERDR_ORIGINAL_PATH HERDR_LAB_HELPER
export ACTIVE_SEEDED_CONTROL POST_CREATE_ABORT_CONTROL LIVE_VIEWER_CONTROL TMP_ROOT

# Log every production-adapter call, remove its already-validated trailing
# session flag, and send the operation through the lab helper so that helper
# remains the sole process which appends the real trailing session flag.
# The adapter's deliberately session-independent version read cannot pass the
# helper's leading-option guard, so the wrapper sends only that read straight
# to the absolute real binary with the same explicit trailing lab session.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
{
  first=1
  for arg in "$@"; do
    [ "$first" -eq 0 ] && printf '\t'
    printf '%s' "$arg"
    first=0
  done
  printf '\n'
} >> "$HERDR_CALL_LOG"
args=("$@")
last_index=$((${#args[@]} - 1))
flag_index=$((last_index - 1))
if [ "${#args[@]}" -ge 2 ] \
   && [ "${args[$flag_index]}" = --session ] \
   && [ "${args[$last_index]}" = "${HERDR_LAB_SESSION:?}" ]; then
  unset "args[$last_index]" "args[$flag_index]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in
    --session|--session=*)
      echo "test wrapper: unexpected caller-supplied session flag" >&2
      exit 1
      ;;
  esac
done
if [ "${1:-}" = --version ]; then
  exec env PATH="$HERDR_ORIGINAL_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"
fi

focus_snapshot() {
  local list row workspace tab tabs
  list=$(env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace list) || return 1
  row=$(printf '%s' "$list" | jq -r '
    [.result.workspaces[]? | select(.focused == true)]
    | select(length == 1)
    | .[0]
    | select((.workspace_id | type) == "string" and (.active_tab_id | type) == "string")
    | [.workspace_id, .active_tab_id]
    | @tsv
  ') || return 1
  [ -n "$row" ] || return 1
  workspace=${row%%$'\t'*}
  tab=${row#*$'\t'}
  tabs=$(env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" tab list --workspace "$workspace") || return 1
  printf '%s' "$tabs" | jq -e --arg tab "$tab" '
    ([.result.tabs[]? | select(.focused == true)] | length) == 1
    and ([.result.tabs[]? | select(.focused == true)][0].tab_id == $tab)
  ' >/dev/null 2>&1 || return 1
  printf '%s/%s' "$workspace" "$tab"
}

arg_value() {
  local want=$1 previous= arg
  shift
  for arg in "$@"; do
    if [ "$previous" = "$want" ]; then
      printf '%s' "$arg"
      return 0
    fi
    previous=$arg
  done
  return 1
}

label=$(arg_value --label "$@" || true)
seeded_task=$(cat "$ACTIVE_SEEDED_CONTROL/task" 2>/dev/null || printf active-seeded)
if [ "${1:-} ${2:-}" = "workspace list" ] && [ -d "$ACTIVE_SEEDED_CONTROL" ]; then
  stage=$(cat "$ACTIVE_SEEDED_CONTROL/stage" 2>/dev/null || true)
  if [ "$stage" = task-created ]; then
    printf '%s\n' post-task-snapshot > "$ACTIVE_SEEDED_CONTROL/stage"
  elif [ "$stage" = post-task-snapshot ]; then
    seeded_tab=$(cat "$ACTIVE_SEEDED_CONTROL/seeded-tab")
    inject_before=$(focus_snapshot || printf ambiguous/ambiguous)
    env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" tab focus "$seeded_tab" >/dev/null
    inject_after=$(focus_snapshot || printf ambiguous/ambiguous)
    printf 'active-seeded-inject\t%s\t%s\t%s\n' "$inject_before" "$inject_after" "$seeded_tab" >> "$FOCUS_AUDIT_LOG"
    printf '%s\n' injected > "$ACTIVE_SEEDED_CONTROL/stage"
  fi
fi

mutation=
mutation_target=${3:-}
case "${1:-} ${2:-}" in
  "workspace create") mutation=workspace-create; mutation_target=$label ;;
  "tab create") mutation=tab-create; mutation_target=$label ;;
  "pane close") mutation=pane-close ;;
  "tab focus") mutation=tab-focus ;;
esac
refusal_probe=0
if [ "${1:-} ${2:-}" = "pane get" ] && [ -d "$ACTIVE_SEEDED_CONTROL" ] \
   && [ "$(cat "$ACTIVE_SEEDED_CONTROL/stage" 2>/dev/null || true)" = injected ] \
   && [ "${3:-}" = "$(cat "$ACTIVE_SEEDED_CONTROL/seeded-pane" 2>/dev/null || true)" ]; then
  refusal_probe=1
  refusal_before=$(focus_snapshot || printf ambiguous/ambiguous)
fi
before=
[ -z "$mutation" ] || before=$(focus_snapshot || printf ambiguous/ambiguous)
if out=$(env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"); then
  status=0
else
  status=$?
fi
if [ "$status" -eq 0 ] && [ "$mutation" = workspace-create ]; then
  case "$label" in
    "└ $seeded_task · p:"*)
      mkdir -p "$ACTIVE_SEEDED_CONTROL"
      printf '%s\n' "$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id')" > "$ACTIVE_SEEDED_CONTROL/workspace"
      printf '%s\n' "$(printf '%s' "$out" | jq -r '.result.tab.tab_id')" > "$ACTIVE_SEEDED_CONTROL/seeded-tab"
      printf '%s\n' "$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id')" > "$ACTIVE_SEEDED_CONTROL/seeded-pane"
      ;;
    $'└ abort-a · p:'*|$'└ abort-b · p:'*)
      task=${label#$'└ '}; task=${task%% *}
      mkdir -p "$POST_CREATE_ABORT_CONTROL/$task"
      printf '%s\n' "$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id')" > "$POST_CREATE_ABORT_CONTROL/$task/workspace"
      ;;
  esac
fi
if [ "$status" -eq 0 ] && [ "$mutation" = tab-create ]; then
  case "$label" in
    "fm-$seeded_task")
      # A flat fallback creates a second fm-<id> tab; only the projected one is recorded.
      if [ ! -e "$ACTIVE_SEEDED_CONTROL/task-pane" ]; then
        printf '%s\n' "$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id')" > "$ACTIVE_SEEDED_CONTROL/task-pane"
        printf '%s\n' task-created > "$ACTIVE_SEEDED_CONTROL/stage"
      fi
      ;;
    fm-abort-a|fm-abort-b)
      task=${label#fm-}
      mkdir -p "$POST_CREATE_ABORT_CONTROL/$task"
      printf '%s\n' "$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id')" > "$POST_CREATE_ABORT_CONTROL/$task/task-pane"
      ;;
  esac
fi
if [ "$status" -eq 0 ] && [ "${1:-} ${2:-}" = "pane get" ] && [ -d "$POST_CREATE_ABORT_CONTROL" ]; then
  for task_dir in "$POST_CREATE_ABORT_CONTROL"/abort-*; do
    [ -d "$task_dir" ] || continue
    [ "${3:-}" = "$(cat "$task_dir/task-pane" 2>/dev/null || true)" ] || continue
    out=$(printf '%s' "$out" | jq --arg cwd "$POST_CREATE_ABORT_CONTROL/not-a-worktree" '.result.pane.foreground_cwd = $cwd')
    break
  done
fi
if [ -n "$mutation" ]; then
  after=$(focus_snapshot || printf ambiguous/ambiguous)
  printf '%s\t%s\t%s\t%s\n' "$mutation" "$before" "$after" "$mutation_target" >> "$FOCUS_AUDIT_LOG"
fi
if [ "$refusal_probe" -eq 1 ]; then
  refusal_after=$(focus_snapshot || printf ambiguous/ambiguous)
  printf 'seeded-prune-refusal\t%s\t%s\t%s\n' "$refusal_before" "$refusal_after" "${3:-}" >> "$FOCUS_AUDIT_LOG"
fi
[ -z "$out" ] || printf '%s\n' "$out"
exit "$status"
SH

cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
{
  first=1
  for arg in "$@"; do
    [ "$first" -eq 0 ] && printf '\t'
    printf '%s' "$arg"
    first=0
  done
  printf '\n'
} >> "$TREEHOUSE_CALL_LOG"
if [ -d "$POST_CREATE_ABORT_CONTROL" ] && [ "${1:-}" = get ]; then
  exit 0
fi
# Treehouse's pool allocator is outside the Herdr concurrency contract under
# test. Serialize its calls so simultaneous recovery spawns cannot race for
# one pool slot before reaching the Herdr session lock exercised below.
while ! mkdir "$TREEHOUSE_LOCK_DIR" 2>/dev/null; do
  sleep 0.01
done
release_treehouse_lock() { rmdir "$TREEHOUSE_LOCK_DIR" 2>/dev/null || true; }
trap release_treehouse_lock EXIT
trap 'exit 1' HUP INT TERM
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  if [ "${args[$i]}" = --root ]; then args[$((i+1))]="$TEST_POOL_ROOT/$(basename "${args[$((i+1))]}")"; fi
done
"$REAL_TREEHOUSE" "${args[@]}"
exit $?
SH

cat > "$FAKEBIN/herdr-workspace-mover" <<'SH'
#!/usr/bin/env bash
set -u
focus_snapshot() {
  local list row workspace tab tabs
  list=$(env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace list) || return 1
  row=$(printf '%s' "$list" | jq -r '
    [.result.workspaces[]? | select(.focused == true)]
    | select(length == 1)
    | .[0]
    | [.workspace_id, .active_tab_id]
    | @tsv
  ') || return 1
  [ -n "$row" ] || return 1
  workspace=${row%%$'\t'*}
  tab=${row#*$'\t'}
  tabs=$(env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" tab list --workspace "$workspace") || return 1
  printf '%s' "$tabs" | jq -e --arg tab "$tab" '
    ([.result.tabs[]? | select(.focused == true)] | length) == 1
    and ([.result.tabs[]? | select(.focused == true)][0].tab_id == $tab)
  ' >/dev/null 2>&1 || return 1
  printf '%s/%s' "$workspace" "$tab"
}
printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$MOVE_CALL_LOG"
before=$(focus_snapshot || printf ambiguous/ambiguous)
if out=$("$REAL_MOVER" "$@"); then
  status=0
else
  status=$?
fi
after=$(focus_snapshot || printf ambiguous/ambiguous)
printf 'workspace-move\t%s\t%s\t%s\n' "$before" "$after" "$2" >> "$FOCUS_AUDIT_LOG"
[ -z "$out" ] || printf '%s\n' "$out"
exit "$status"
SH
chmod +x "$FAKEBIN/herdr" "$FAKEBIN/treehouse"
chmod +x "$FAKEBIN/herdr-workspace-mover"
export PATH="$FAKEBIN:$PATH"
export FM_BACKEND_HERDR_WORKSPACE_MOVER="$FAKEBIN/herdr-workspace-mover"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
# This suite runs against its own isolated lab session, so a Herdr pane
# inherited from the terminal it was launched in must not follow spawn into it
# as a cross-session parent identity. Every projection below is anchored on the
# parent this suite sets up, not on the developer's own workspace.
herdr_forget_inherited_pane

HERDR_LAB_SESSION=$(PATH="$HERDR_ORIGINAL_PATH" \
  "$HERDR_LAB_HELPER" name fm-herdr-presentation-projection)
export HERDR_SESSION="$HERDR_LAB_SESSION" HERDR_LAB_SESSION
LAB_READY=0
RECORDED_WORKTREES=""
LOCK_CONTENTION_OWNER_PID=
cleanup_all() {
  local wt
  if [ -n "$LOCK_CONTENTION_OWNER_PID" ]; then
    kill "$LOCK_CONTENTION_OWNER_PID" 2>/dev/null || true
    wait "$LOCK_CONTENTION_OWNER_PID" 2>/dev/null || true
    LOCK_CONTENTION_OWNER_PID=
  fi
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    [ -d "$wt" ] || continue
    "$REAL_TREEHOUSE" return --force "$wt" >/dev/null 2>&1 || true
  done <<EOF
$RECORDED_WORKTREES
EOF
  if [ "$LAB_READY" -eq 1 ]; then
    PATH="$HERDR_ORIGINAL_PATH" \
      "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null 2>&1 || true
    LAB_READY=0
  fi
  mkdir -p "$TEST_EVIDENCE/product"
  cp "$TMP_ROOT"/*.out "$TMP_ROOT"/*.err "$TMP_ROOT"/*.log "$TEST_EVIDENCE/product/" 2>/dev/null || true
  rm -rf "$TMP_ROOT"
}
trap cleanup_all EXIT

PATH="$HERDR_ORIGINAL_PATH" \
  "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not provision the isolated Herdr lab"
LAB_READY=1

lab() {
  PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
}

focus_snapshot() {
  local list row workspace tab tabs
  list=$(lab workspace list) || fail "could not read the active workspace for focus instrumentation"
  row=$(printf '%s' "$list" | jq -r '
    [.result.workspaces[]? | select(.focused == true)]
    | select(length == 1)
    | .[0]
    | select((.workspace_id | type) == "string" and (.active_tab_id | type) == "string")
    | [.workspace_id, .active_tab_id]
    | @tsv
  ') || fail "could not parse the active workspace and tab"
  [ -n "$row" ] || fail "focus instrumentation found an ambiguous active workspace"
  workspace=${row%%$'\t'*}
  tab=${row#*$'\t'}
  tabs=$(lab tab list --workspace "$workspace") || fail "could not verify the active tab"
  printf '%s' "$tabs" | jq -e --arg tab "$tab" '
    ([.result.tabs[]? | select(.focused == true)] | length) == 1
    and ([.result.tabs[]? | select(.focused == true)][0].tab_id == $tab)
  ' >/dev/null 2>&1 || fail "workspace active_tab_id disagreed with the focused tab"
  printf '%s/%s' "$workspace" "$tab"
}

assert_focus_is() {  # <expected> <case-name>
  local expected=$1 case_name=$2 actual
  actual=$(focus_snapshot)
  [ "$actual" = "$expected" ] || fail "$case_name changed active workspace/tab from $expected to $actual"
}

focus_audit_line_count() { wc -l < "$FOCUS_AUDIT_LOG" | tr -d '[:space:]'; }

assert_raw_presentation_mutations_preserved_since() {  # <line-count> <case-name>
  local start=$1 case_name=$2 changed
  changed=$(sed -n "$((start + 1)),\$p" "$FOCUS_AUDIT_LOG" | awk -F '\t' '
    ($1 == "workspace-create" || $1 == "tab-create" || $1 == "workspace-move" || $1 == "pane-close") && $2 != $3 {
      print $0
    }
  ')
  [ -z "$changed" ] || fail "$case_name changed active workspace/tab inside a create, move, or seeded cleanup: $changed"
}

# The focus-safe emptying-close plan removes a last pane through Herdr's
# pane-death path with no pane.close mutation at all (the raw explicit-close
# defect is demonstrated by tests/fm-backend-herdr-focus-flash-e2e.test.sh);
# a fallback plain close must preserve or immediately restore exact focus.
assert_cleanup_focus_preserved() {  # <line-count> <pane-id> <expected-focus>
  local start=$1 pane_id=$2 expected=$3
  sed -n "$((start + 1)),\$p" "$FOCUS_AUDIT_LOG" | awk -F '\t' -v pane="$pane_id" -v expected="$expected" '
    $1 == "pane-close" && $4 == pane {
      saw_close = 1
      if ($2 != expected) { bad = 1 }
      else if ($3 == expected) { preserved = 1 }
      else { drift = $3 }
      next
    }
    saw_close && drift != "" && $1 == "tab-focus" && $2 == drift && $3 == expected {
      preserved = 1
    }
    END { exit(bad || (saw_close && !preserved) ? 1 : 0) }
  ' || fail "projected pane close did not preserve or restore the exact active workspace and tab"
  if lab pane get "$pane_id" >/dev/null 2>&1; then
    fail "projected cleanup left exact pane $pane_id alive"
  fi
}

remember_meta_worktree() {  # <meta>
  local wt
  wt=$(grep '^worktree=' "$1" | cut -d= -f2-)
  [ -n "$wt" ] || fail "metadata did not record a worktree"
  RECORDED_WORKTREES="${RECORDED_WORKTREES}${wt}"$'\n'
  printf '%s' "$wt"
}

make_project() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# Herdr projection E2E fixture\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$dir" "$dir.origin.git"
  git -C "$dir" remote add origin "file://$dir.origin.git"
}

write_ship_brief() {  # <home> <id> [description]
  local home=$1 id=$2 description=${3:-Herdr presentation fixture $2}
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
$description

## Firstmate spec
Verify projected workspace behavior for $id.
EOF
}

spawn_task() {  # <id> <home> <project>
  local id=$1 home=$2 project=$3
  FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$project" "sh -c 'while :; do sleep 60; done'" --mode no-mistakes --yolo off --backend herdr
}

finish_concurrent_spawn() {  # <id> <status> <stdout> <stderr>
  local id=$1 status=$2 out=$3 err=$4
  [ "$status" -ne 0 ] || return 0
  grep -F "task set is locked" "$err" >/dev/null 2>&1 \
    || fail "concurrent projected spawn $id failed unexpectedly: $(cat "$err")"
  spawn_task "$id" "$HOME_DIR" "$PROJECT_DIR" > "$out" 2> "$err" \
    || fail "projected spawn $id retry failed after task-set publication completed: $(cat "$err")"
}

finish_concurrent_expected_abort() {  # <id> <status> <stdout> <stderr>
  local id=$1 status=$2 out=$3 err=$4
  [ "$status" -ne 0 ] || fail "post-create abort fixture $id unexpectedly succeeded"
  if grep -F "task set is locked" "$err" >/dev/null 2>&1; then
    if spawn_task "$id" "$HOME_DIR" "$PROJECT_DIR" > "$out" 2> "$err"; then
      fail "post-create abort fixture $id unexpectedly succeeded after task-set publication completed"
    fi
  fi
}

spawn_secondmate_task() {
  local id=$1 home=$2
  FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$home" "sh -c 'while :; do sleep 60; done'" --secondmate --backend herdr
}

teardown_task() {  # <id> <home>
  local id=$1 home=$2
  FM_GATE_REFUSE_BYPASS=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-teardown.sh" "$id" --force
}

finish_concurrent_teardown() {  # <id> <status> <stdout> <stderr>
  local id=$1 status=$2 out=$3 err=$4
  [ "$status" -ne 0 ] || return 0
  if ! grep -F "session presentation lock is contended" "$err" >/dev/null 2>&1 \
     && ! grep -F "another Treehouse slot allocation or return is in progress" "$err" >/dev/null 2>&1; then
    fail "projected teardown $id failed unexpectedly: $(cat "$err")"
  fi
  teardown_task "$id" "$HOME_DIR" > "$out" 2> "$err" \
    || fail "projected teardown $id retry failed after presentation cleanup completed: $(cat "$err")"
}

normalize_meta() {  # <meta>
  sed -E \
    -e 's|^window=.*$|window=<herdr-container-id>|' \
    -e 's|^herdr_workspace_id=.*$|herdr_workspace_id=<herdr-container-id>|' \
    -e 's|^herdr_tab_id=.*$|herdr_tab_id=<herdr-container-id>|' \
    -e 's|^herdr_pane_id=.*$|herdr_pane_id=<herdr-container-id>|' \
    -e 's|^spawn_gen=.*$|spawn_gen=<spawn-incarnation>|' \
    "$1"
}

log_line_count() { wc -l < "$HERDR_CALL_LOG" | tr -d '[:space:]'; }

projection_labels_from_log() {  # <start-line>
  local start=$1
  sed -n "$((start + 1)),\$p" "$HERDR_CALL_LOG" | awk -F '\t' '
    $1 == "workspace" && $2 == "create" {
      for (i = 1; i < NF; i += 1) {
        if ($i == "--label" && $(i + 1) ~ /^└ /) {
          print $(i + 1)
        }
      }
    }
  '
}

session_presentation_lock_path() {
  PATH="$FAKEBIN:$PATH" HERDR_SESSION="$HERDR_LAB_SESSION" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_presentation_session_lock_path "$1"
  ' "$ROOT" "$HERDR_LAB_SESSION"
}

assert_no_ordering_lifecycle_calls_since() {  # <line-count> <case-name>
  local start=$1 name=$2 calls
  calls=$(sed -n "$((start + 1)),\$p" "$HERDR_CALL_LOG")
  if printf '%s\n' "$calls" | grep -E $'^(workspace\t(close|rename)|tab\tclose|session\t(stop|delete)|server)' >/dev/null 2>&1; then
    fail "$name introduced a workspace/tab/session lifecycle or label mutation call"
  fi
}

assert_no_projection_mutation_since() {  # <line-count> <case-name>
  local start=$1 name=$2 calls
  calls=$(sed -n "$((start + 1)),\$p" "$HERDR_CALL_LOG")
  if printf '%s\n' "$calls" | grep -E $'^(workspace\t(create|close|rename)|tab\t(create|close)|pane\tclose|session\t(stop|delete)|server)' >/dev/null 2>&1; then
    fail "$name performed a create, close, delete, rename, or lifecycle call during recovery inspection"
  fi
}

HOME_DIR="$TMP_ROOT/home"
PROJECT_DIR="$TMP_ROOT/project"
RECOVERY_PROJECT_DIR="$TMP_ROOT/recovery-project"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" \
  "$HOME_DIR/data/anchor" "$HOME_DIR/data/shape" \
  "$HOME_DIR/data/order-a" "$HOME_DIR/data/order-b" \
  "$HOME_DIR/data/order-fail" "$HOME_DIR/data/fm-hibit-resume-r1" \
  "$HOME_DIR/data/wheelhouse-healing-r1"
mkdir -p "$HOME_DIR/data/active-seeded" "$HOME_DIR/data/abort-a" "$HOME_DIR/data/abort-b" \
  "$HOME_DIR/data/lock-contended" "$HOME_DIR/data/default-on"
touch "$HOME_DIR/state/.last-watcher-beat"
# Presentation spaces are on by default, so the flat baseline below opts out
# explicitly; the projected cases each restate the setting they exercise.
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
write_ship_brief "$HOME_DIR" anchor 'Projection anchor fixture.'
write_ship_brief "$HOME_DIR" shape 'Projection E2E fixture.'
write_ship_brief "$HOME_DIR" order-a 'Projection ordering fixture A.'
write_ship_brief "$HOME_DIR" order-b 'Projection ordering fixture B.'
write_ship_brief "$HOME_DIR" order-fail 'Projection ordering failure fixture.'
write_ship_brief "$HOME_DIR" fm-hibit-resume-r1 'Hi Bit-style projection restart fixture.'
write_ship_brief "$HOME_DIR" wheelhouse-healing-r1 'Wheelhouse-style projection restart fixture.'
write_ship_brief "$HOME_DIR" active-seeded 'Projection active seeded fixture.'
write_ship_brief "$HOME_DIR" abort-a 'Projection abort fixture A.'
write_ship_brief "$HOME_DIR" abort-b 'Projection abort fixture B.'
write_ship_brief "$HOME_DIR" lock-contended 'Projection lock contention fixture.'
write_ship_brief "$HOME_DIR" lock-retry 'Projection lock released within the bounded wait fixture.'
write_ship_brief "$HOME_DIR" prune-clears 'Projection seeded prune focus clears within the bounded wait fixture.'
write_ship_brief "$HOME_DIR" prune-exhausted 'Projection seeded prune focus stays unsafe for the bounded wait fixture.'
write_ship_brief "$HOME_DIR" default-on 'Projection default-on fixture.'
make_project "$PROJECT_DIR"
make_project "$RECOVERY_PROJECT_DIR"

# Keep one ordinary primary task live so the durable firstmate workspace is
# first and remains present while disposable workers are projected around it.
spawn_task anchor "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/anchor.out" 2> "$TMP_ROOT/anchor.err" \
  || fail "opted-out anchor spawn failed: $(cat "$TMP_ROOT/anchor.err")"
ANCHOR_META="$HOME_DIR/state/anchor.meta"
remember_meta_worktree "$ANCHOR_META" >/dev/null
FIRSTMATE_WSID=$(grep '^herdr_workspace_id=' "$ANCHOR_META" | cut -d= -f2-)
[ -n "$FIRSTMATE_WSID" ] || fail "anchor metadata did not record the firstmate workspace"

# The same task id and project run once opted out and once projected, so
# Treehouse commands and metadata can be compared after normalizing endpoint
# IDs and the deliberately fresh per-spawn incarnation.
: > "$TREEHOUSE_CALL_LOG"
OFF_HERDR_START=$(log_line_count)
OFF_MOVE_START=$(wc -l < "$MOVE_CALL_LOG" | tr -d '[:space:]')
spawn_task shape "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/off.out" 2> "$TMP_ROOT/off.err" \
  || fail "opted-out spawn failed: $(cat "$TMP_ROOT/off.err")"
OFF_HERDR_END=$(log_line_count)
OFF_META="$TMP_ROOT/off.meta"
cp "$HOME_DIR/state/shape.meta" "$OFF_META"
OFF_WT=$(remember_meta_worktree "$OFF_META")
cp "$TREEHOUSE_CALL_LOG" "$TMP_ROOT/off-treehouse.log"
[ "$(wc -l < "$MOVE_CALL_LOG" | tr -d '[:space:]')" = "$OFF_MOVE_START" ] \
  || fail "opted-out spawn invoked the presentation-only workspace mover"
OFF_HERDR_CALLS=$(sed -n "$((OFF_HERDR_START + 1)),${OFF_HERDR_END}p" "$HERDR_CALL_LOG")
if printf '%s\n' "$OFF_HERDR_CALLS" | grep -E $'^(api\tschema|session\tlist)' >/dev/null 2>&1; then
  fail "opted-out spawn added presentation-ordering capability or socket calls"
fi
pass "real Herdr lab: an opted-out spawn retains the Stage 1 Herdr command sequence with zero ordering calls"
teardown_task shape "$HOME_DIR" > "$TMP_ROOT/off-teardown.out" 2> "$TMP_ROOT/off-teardown.err" \
  || fail "opted-out teardown failed: $(cat "$TMP_ROOT/off-teardown.err")"

# A home that configured nothing at all follows the version floor: it is
# projected on a release at or above it, and takes the ordinary flat layout with
# one naming warning below it. The only difference from the opted-out spawn
# above is the removed file, so this case is the floor's live end-user proof on
# whichever Herdr this lab is running.
rm -f "$HOME_DIR/config/herdr-presentation-spaces"
FLOOR_STATUS=$(lab status --json) || fail 'could not read the lab release for the presentation floor'
FLOOR_VERSION=$(printf '%s' "$FLOOR_STATUS" | jq -r 'if .server.running then .server.version else .client.version end')
FLOOR_PROTOCOL=$(printf '%s' "$FLOOR_STATUS" | jq -r 'if .server.running then .server.protocol else .client.protocol end')
FLOOR_VERDICT=$(bash -c '
  . "$0/bin/backends/herdr.sh"
  status=0
  fm_backend_herdr_release_floor_verdict "$1" "$2" || status=$?
  printf "%s\n" "$status"
' "$ROOT" "$FLOOR_PROTOCOL" "$FLOOR_VERSION")
[ "$FLOOR_VERDICT" = 0 ] || [ "$FLOOR_VERDICT" = 1 ] \
  || fail "herdr $FLOOR_VERSION protocol $FLOOR_PROTOCOL could not be classified against the presentation floor"
spawn_task default-on "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/default-on.out" 2> "$TMP_ROOT/default-on.err" \
  || fail "default-on spawn failed: $(cat "$TMP_ROOT/default-on.err")"
DEFAULT_ON_META="$HOME_DIR/state/default-on.meta"
remember_meta_worktree "$DEFAULT_ON_META" >/dev/null
DEFAULT_ON_JOURNAL="$HOME_DIR/state/default-on.herdr-presentation"
DEFAULT_ON_WSID=$(grep '^herdr_workspace_id=' "$DEFAULT_ON_META" | cut -d= -f2-)
if [ "$FLOOR_VERDICT" = 0 ]; then
  [ -f "$DEFAULT_ON_JOURNAL" ] \
    || fail "an unconfigured home did not publish a presentation journal on supported herdr $FLOOR_VERSION"
  DEFAULT_ON_TOKEN=$(grep '^projection_id=' "$DEFAULT_ON_JOURNAL" | cut -d= -f2-)
  [ -n "$DEFAULT_ON_WSID" ] && [ "$DEFAULT_ON_WSID" != "$FIRSTMATE_WSID" ] \
    || fail "an unconfigured home reused the flat firstmate workspace instead of projecting"
  DEFAULT_ON_LABEL=$(lab workspace get "$DEFAULT_ON_WSID" | jq -r '.result.workspace.label // empty')
  [ "$DEFAULT_ON_LABEL" = "└ default-on · p:$DEFAULT_ON_TOKEN" ] \
    || fail "default-on projection used an unexpected workspace label: $DEFAULT_ON_LABEL"
  pass "real Herdr lab: a home that configured nothing is projected by default on herdr $FLOOR_VERSION"
else
  [ ! -e "$DEFAULT_ON_JOURNAL" ] \
    || fail "an unconfigured home published a presentation journal on below-floor herdr $FLOOR_VERSION"
  [ "$DEFAULT_ON_WSID" = "$FIRSTMATE_WSID" ] \
    || fail "an unconfigured home did not land in the flat firstmate workspace on below-floor herdr $FLOOR_VERSION (got '${DEFAULT_ON_WSID:-<empty>}')"
  grep -q "$FLOOR_VERSION" "$TMP_ROOT/default-on.err" \
    || fail "the below-floor fallback did not name herdr $FLOOR_VERSION: $(cat "$TMP_ROOT/default-on.err")"
  pass "real Herdr lab: a home that configured nothing falls back flat on below-floor herdr $FLOOR_VERSION with one naming warning"
fi
teardown_task default-on "$HOME_DIR" > "$TMP_ROOT/default-on-teardown.out" 2> "$TMP_ROOT/default-on-teardown.err" \
  || fail "default-on teardown failed: $(cat "$TMP_ROOT/default-on-teardown.err")"
if [ "$FLOOR_VERDICT" = 0 ] && lab workspace get "$DEFAULT_ON_WSID" >/dev/null 2>&1; then
  fail "default-on teardown left its disposable workspace behind"
fi
# The ordering scenarios below read the whole move log cumulatively against the
# projected workspaces that are still live, so this retired one starts them clean.
: > "$MOVE_CALL_LOG"

SECOND_ONE_OUT=$(lab workspace create --cwd "$PROJECT_DIR" --label 2ndmate-alpha --no-focus) \
  || fail "could not create the first secondmate presentation fixture"
SECOND_TWO_OUT=$(lab workspace create --cwd "$PROJECT_DIR" --label 2ndmate-bravo --focus) \
  || fail "could not create the focused secondmate presentation fixture"
SECOND_ONE_WSID=$(printf '%s' "$SECOND_ONE_OUT" | jq -r '.result.workspace.workspace_id // empty')
SECOND_TWO_WSID=$(printf '%s' "$SECOND_TWO_OUT" | jq -r '.result.workspace.workspace_id // empty')
SECOND_TWO_TAB=$(printf '%s' "$SECOND_TWO_OUT" | jq -r '.result.tab.tab_id // empty')
SECOND_TWO_PANE=$(printf '%s' "$SECOND_TWO_OUT" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$SECOND_ONE_WSID" ] && [ -n "$SECOND_TWO_WSID" ] && [ -n "$SECOND_TWO_TAB" ] && [ -n "$SECOND_TWO_PANE" ] \
  || fail "secondmate presentation fixtures returned incomplete IDs"
SECOND_ORDER_BEFORE=$(printf '%s\n%s\n' "$SECOND_ONE_WSID" "$SECOND_TWO_WSID")
CAPTAIN_FOCUS="$SECOND_TWO_WSID/$SECOND_TWO_TAB"
assert_focus_is "$CAPTAIN_FOCUS" "focused secondmate fixture"

: > "$TREEHOUSE_CALL_LOG"
# The historical presence-based opt-in was an empty file; it must still project,
# so no home that had already enabled the projection is turned off by the default.
: > "$HOME_DIR/config/herdr-presentation-spaces"
SHAPE_FOCUS_AUDIT_START=$(focus_audit_line_count)
spawn_task shape "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/on.out" 2> "$TMP_ROOT/on.err" \
  || fail "projected spawn failed: $(cat "$TMP_ROOT/on.err")"
assert_focus_is "$CAPTAIN_FOCUS" "projected spawn"
assert_raw_presentation_mutations_preserved_since "$SHAPE_FOCUS_AUDIT_START" "projected spawn"
ON_META="$TMP_ROOT/on.meta"
cp "$HOME_DIR/state/shape.meta" "$ON_META"
ON_WT=$(remember_meta_worktree "$ON_META")
cmp -s "$TMP_ROOT/off-treehouse.log" "$TREEHOUSE_CALL_LOG" \
  || fail "Treehouse command sequence changed between opted-out and projected spawns"
JOURNAL="$HOME_DIR/state/shape.herdr-presentation"
[ -f "$JOURNAL" ] || fail "projected spawn did not publish its presentation journal"
TOKEN=$(grep '^projection_id=' "$JOURNAL" | cut -d= -f2-)
[ "${#TOKEN}" -eq 22 ] || fail "projection id is not the compact 22-character encoding of 128 bits"
# The uncontended projected path must stay byte-identical to the opted-out
# spawn's result line apart from the endpoint, with no bounded-wait output.
[ "$(sed -E 's/window=[^ ]*/window=<endpoint>/' "$TMP_ROOT/on.out")" = "$(sed -E 's/window=[^ ]*/window=<endpoint>/' "$TMP_ROOT/off.out")" ] \
  || fail "uncontended projected spawn stdout diverged from the flat result line: $(cat "$TMP_ROOT/on.out")"
[ "$(wc -l < "$TMP_ROOT/on.out" | tr -d '[:space:]')" = 1 ] \
  || fail "uncontended projected spawn printed more than its result line: $(cat "$TMP_ROOT/on.out")"
if grep -E 'retrying|HERDR_PRESENTATION_FALLBACK|stayed focus-unsafe' "$TMP_ROOT/on.err" >/dev/null 2>&1; then
  fail "uncontended projected spawn reported a bounded wait or fallback: $(cat "$TMP_ROOT/on.err")"
fi
if grep -q '^fallback=' "$JOURNAL"; then
  fail "uncontended projected spawn recorded a fallback in its journal"
fi
PROJECTED_WSID=$(grep '^herdr_workspace_id=' "$ON_META" | cut -d= -f2-)
PROJECTED_TAB=$(grep '^herdr_tab_id=' "$ON_META" | cut -d= -f2-)
PROJECTED_PANE=$(grep '^herdr_pane_id=' "$ON_META" | cut -d= -f2-)
PROJECTED_INFO=$(lab workspace get "$PROJECTED_WSID") || fail "could not inspect the projected workspace"
PROJECTED_LABEL=$(printf '%s' "$PROJECTED_INFO" | jq -r '.result.workspace.label // empty')
[ "$PROJECTED_LABEL" = "└ shape · p:$TOKEN" ] \
  || fail "projected workspace label did not use the corner format with full token: $PROJECTED_LABEL"
PROJECTED_TABS=$(lab tab list --workspace "$PROJECTED_WSID")
PROJECTED_PANES=$(lab pane list --workspace "$PROJECTED_WSID")
[ "$(printf '%s' "$PROJECTED_TABS" | jq -r '.result.tabs | length')" = 1 ] \
  || fail "projected workspace retained a seeded or placeholder tab"
[ "$(printf '%s' "$PROJECTED_PANES" | jq -r '.result.panes | length')" = 1 ] \
  || fail "projected workspace did not contain exactly one task pane"
printf '%s' "$PROJECTED_TABS" | jq -e --arg tab "$PROJECTED_TAB" \
  '.result.tabs[0].tab_id == $tab and .result.tabs[0].label == "fm-shape"' >/dev/null 2>&1 \
  || fail "projected workspace's only tab was not the normal fm-shape task tab"
printf '%s' "$PROJECTED_PANES" | jq -e --arg pane "$PROJECTED_PANE" \
  '.result.panes[0].pane_id == $pane' >/dev/null 2>&1 \
  || fail "projected workspace's only pane was not the exact recorded task pane"
SECOND_TWO_INFO=$(lab workspace get "$SECOND_TWO_WSID") || fail "focused secondmate disappeared during projected create"
[ "$(printf '%s' "$SECOND_TWO_INFO" | jq -r '.result.workspace.focused')" = true ] \
  || fail "projected create or workspace.move stole focus from the captain's current space"
pass "real Herdr lab: every projected create, task-tab create, seeded prune, and move preserves active workspace and tab"

mkdir -p "$ACTIVE_SEEDED_CONTROL"
printf '%s\n' requested > "$ACTIVE_SEEDED_CONTROL/stage"
ACTIVE_SEEDED_START=$(log_line_count)
cp "$MOVE_CALL_LOG" "$TMP_ROOT/move-log-before-active-seeded"
if ! spawn_task active-seeded "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/active-seeded.out" 2> "$TMP_ROOT/active-seeded.err"; then
  fail "detached persisted-focus seeded prune should succeed: $(cat "$TMP_ROOT/active-seeded.err")"
fi
if grep -F "target is the captain's active tab" "$TMP_ROOT/active-seeded.err" >/dev/null 2>&1; then
  fail "detached persisted-focus seeded prune still used the live-viewer refusal"
fi
ACTIVE_SEEDED_PANE=$(cat "$ACTIVE_SEEDED_CONTROL/seeded-pane")
ACTIVE_SEEDED_TASK_PANE=$(cat "$ACTIVE_SEEDED_CONTROL/task-pane")
if lab pane get "$ACTIVE_SEEDED_PANE" >/dev/null 2>&1; then
  fail "detached persisted-focus seeded prune left the seeded pane behind"
fi
lab pane get "$ACTIVE_SEEDED_TASK_PANE" >/dev/null 2>&1 \
  || fail "detached persisted-focus seeded prune lost the task pane"
sed -n "$((ACTIVE_SEEDED_START + 1)),\$p" "$HERDR_CALL_LOG" | grep -F $'pane\tclose\t'"$ACTIVE_SEEDED_PANE" >/dev/null 2>&1 \
  || fail "detached persisted-focus seeded prune did not close the seeded pane"
lab tab focus "$SECOND_TWO_TAB" >/dev/null || fail "could not restore the captured captain tab after the active seeded-tab fixture"
assert_focus_is "$CAPTAIN_FOCUS" "active seeded-tab fixture restoration"
rm -rf "$ACTIVE_SEEDED_CONTROL"
remember_meta_worktree "$HOME_DIR/state/active-seeded.meta" >/dev/null
teardown_task active-seeded "$HOME_DIR" > "$TMP_ROOT/active-seeded-teardown.out" 2> "$TMP_ROOT/active-seeded-teardown.err" \
  || fail "detached persisted-focus seeded prune leftover teardown failed: $(cat "$TMP_ROOT/active-seeded-teardown.err")"
cp "$TMP_ROOT/move-log-before-active-seeded" "$MOVE_CALL_LOG"
assert_focus_is "$CAPTAIN_FOCUS" "active seeded-tab fixture cleanup"
pass "real Herdr lab: persisted-focused seeded prune proceeds when no live client is attached"

# A live viewer on the fresh seeded tab refuses the prune; once the captain
# navigates back within the bounded wait, the retried prune completes the
# projection instead of demoting the worker to the flat layout.
mkdir -p "$ACTIVE_SEEDED_CONTROL"
printf '%s\n' prune-clears > "$ACTIVE_SEEDED_CONTROL/task"
printf '%s\n' requested > "$ACTIVE_SEEDED_CONTROL/stage"
PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" viewer start "$HERDR_LAB_SESSION" || fail "real viewer attach failed"
cp "$MOVE_CALL_LOG" "$TMP_ROOT/move-log-before-prune-clears"
FM_HERDR_PRESENTATION_RETRY_TRIES=3 FM_HERDR_PRESENTATION_RETRY_TRY_SECONDS=5 \
  spawn_task prune-clears "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/prune-clears.out" 2> "$TMP_ROOT/prune-clears.err" &
PRUNE_CLEARS_PID=$!
PRUNE_CLEARS_WAIT=0
while ! grep -F "target is the captain's active tab" "$TMP_ROOT/prune-clears.err" >/dev/null 2>&1; do
  kill -0 "$PRUNE_CLEARS_PID" 2>/dev/null || break
  PRUNE_CLEARS_WAIT=$((PRUNE_CLEARS_WAIT + 1))
  [ "$PRUNE_CLEARS_WAIT" -lt 600 ] || break
  sleep 0.05
done
grep -F "target is the captain's active tab" "$TMP_ROOT/prune-clears.err" >/dev/null 2>&1 \
  || { wait "$PRUNE_CLEARS_PID" 2>/dev/null; fail "a live viewer on the seeded tab did not refuse the first prune: $(cat "$TMP_ROOT/prune-clears.err")"; }
lab tab focus "$SECOND_TWO_TAB" >/dev/null || fail "could not model the captain navigating away from the seeded tab"
wait "$PRUNE_CLEARS_PID" || fail "a seeded prune whose focus cleared within the bound failed the spawn: $(cat "$TMP_ROOT/prune-clears.err")"
PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" viewer stop "$HERDR_LAB_SESSION" || fail "real viewer detach failed"
PRUNE_CLEARS_SEEDED_PANE=$(cat "$ACTIVE_SEEDED_CONTROL/seeded-pane")
rm -rf "$ACTIVE_SEEDED_CONTROL"
remember_meta_worktree "$HOME_DIR/state/prune-clears.meta" >/dev/null
if lab pane get "$PRUNE_CLEARS_SEEDED_PANE" >/dev/null 2>&1; then
  fail "the retried seeded prune left the seeded pane behind"
fi
[ "$(grep '^herdr_workspace_id=' "$HOME_DIR/state/prune-clears.meta" | cut -d= -f2-)" != "$FIRSTMATE_WSID" ] \
  || fail "a seeded prune whose focus cleared within the bound still fell back flat"
grep -q '^version=2$' "$HOME_DIR/state/prune-clears.herdr-presentation" \
  || fail "a seeded prune whose focus cleared within the bound did not bind its projection"
if grep -q '^fallback=' "$HOME_DIR/state/prune-clears.herdr-presentation"; then
  fail "a completed projection recorded a flat fallback"
fi
if grep -q 'HERDR_PRESENTATION_FALLBACK' "$TMP_ROOT/prune-clears.out"; then
  fail "a completed projection printed a flat-fallback diagnostic"
fi
[ "$(grep -c "target is the captain's active tab" "$TMP_ROOT/prune-clears.err")" = 1 ] \
  || fail "the repeated seeded-prune refusal was not reported exactly once: $(cat "$TMP_ROOT/prune-clears.err")"
assert_focus_is "$CAPTAIN_FOCUS" "retried seeded prune"
teardown_task prune-clears "$HOME_DIR" > "$TMP_ROOT/prune-clears-teardown.out" 2> "$TMP_ROOT/prune-clears-teardown.err" \
  || fail "retried seeded prune teardown failed: $(cat "$TMP_ROOT/prune-clears-teardown.err")"
cp "$TMP_ROOT/move-log-before-prune-clears" "$MOVE_CALL_LOG"
assert_focus_is "$CAPTAIN_FOCUS" "retried seeded prune cleanup"
pass "real Herdr lab: a focus-unsafe seeded prune retries and completes the projection once the viewer leaves the seeded tab"

# A live viewer that stays on the seeded tab exhausts the bound: the spawn
# still succeeds flat, but only with an actionable stdout diagnostic and a
# journal record that keeps the unremovable projection's token quarantined.
mkdir -p "$ACTIVE_SEEDED_CONTROL"
printf '%s\n' prune-exhausted > "$ACTIVE_SEEDED_CONTROL/task"
printf '%s\n' requested > "$ACTIVE_SEEDED_CONTROL/stage"
PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" viewer start "$HERDR_LAB_SESSION" || fail "real viewer attach failed"
PRUNE_EXHAUSTED_MOVE_START=$(wc -l < "$MOVE_CALL_LOG" | tr -d '[:space:]')
FM_HERDR_PRESENTATION_RETRY_TRIES=2 FM_HERDR_PRESENTATION_RETRY_TRY_SECONDS=1 \
  spawn_task prune-exhausted "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/prune-exhausted.out" 2> "$TMP_ROOT/prune-exhausted.err" \
  || fail "an exhausted seeded-prune bound did not fall back to a successful flat spawn: $(cat "$TMP_ROOT/prune-exhausted.err")"
PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" viewer stop "$HERDR_LAB_SESSION" || fail "real viewer detach failed"
PRUNE_EXHAUSTED_SEEDED_PANE=$(cat "$ACTIVE_SEEDED_CONTROL/seeded-pane")
PRUNE_EXHAUSTED_TASK_PANE=$(cat "$ACTIVE_SEEDED_CONTROL/task-pane")
PRUNE_EXHAUSTED_WSID=$(cat "$ACTIVE_SEEDED_CONTROL/workspace")
rm -rf "$ACTIVE_SEEDED_CONTROL"
remember_meta_worktree "$HOME_DIR/state/prune-exhausted.meta" >/dev/null
PRUNE_EXHAUSTED_JOURNAL="$HOME_DIR/state/prune-exhausted.herdr-presentation"
[ "$(sed -n '1p' "$TMP_ROOT/prune-exhausted.out")" = "$(sed -n '1p' "$TMP_ROOT/prune-exhausted.out" | grep -F "HERDR_PRESENTATION_FALLBACK: prune-exhausted reason=prune-refused bound=2x1s record=$PRUNE_EXHAUSTED_JOURNAL - ")" ] \
  && [ -n "$(sed -n '1p' "$TMP_ROOT/prune-exhausted.out")" ] \
  || fail "an exhausted seeded-prune bound did not print its actionable stdout diagnostic: $(cat "$TMP_ROOT/prune-exhausted.out")"
sed -n '2p' "$TMP_ROOT/prune-exhausted.out" | grep -q '^spawned prune-exhausted ' \
  || fail "the flat-fallback diagnostic did not precede the spawn result line: $(cat "$TMP_ROOT/prune-exhausted.out")"
grep -F "retrying (try 2 of 2, 1s each)" "$TMP_ROOT/prune-exhausted.err" >/dev/null 2>&1 \
  || fail "an exhausted seeded-prune bound did not retry: $(cat "$TMP_ROOT/prune-exhausted.err")"
[ "$(grep '^herdr_workspace_id=' "$HOME_DIR/state/prune-exhausted.meta" | cut -d= -f2-)" = "$FIRSTMATE_WSID" ] \
  || fail "an exhausted seeded-prune bound did not place the worker in the ordinary flat workspace"
if lab pane get "$PRUNE_EXHAUSTED_TASK_PANE" >/dev/null 2>&1; then
  fail "an exhausted seeded-prune bound left the unused projected task pane behind: $(cat "$TMP_ROOT/prune-exhausted.err") calls: $(grep -F "$PRUNE_EXHAUSTED_TASK_PANE" "$HERDR_CALL_LOG")"
fi
lab pane get "$PRUNE_EXHAUSTED_SEEDED_PANE" >/dev/null 2>&1 \
  || fail "an exhausted seeded-prune bound closed the pane a live viewer was watching"
PRUNE_EXHAUSTED_TOKEN=$(sed -n 's/^projection_id=//p' "$PRUNE_EXHAUSTED_JOURNAL")
[ "$(cat "$PRUNE_EXHAUSTED_JOURNAL")" = "$(printf 'version=1\ntask_id=prune-exhausted\nprojection_id=%s\nfallback=prune-refused' "$PRUNE_EXHAUSTED_TOKEN")" ] \
  || fail "an exhausted seeded-prune bound did not record its fallback beside the retained token: $(cat "$PRUNE_EXHAUSTED_JOURNAL")"
[ "$(lab workspace get "$PRUNE_EXHAUSTED_WSID" | jq -r '.result.workspace.label')" = "└ prune-exhausted · p:$PRUNE_EXHAUSTED_TOKEN" ] \
  || fail "the retained projection is not the one its fallback record names"
[ "$(wc -l < "$MOVE_CALL_LOG" | tr -d '[:space:]')" = "$PRUNE_EXHAUSTED_MOVE_START" ] \
  || fail "an exhausted seeded-prune bound ordered the abandoned projection"
lab tab focus "$SECOND_TWO_TAB" >/dev/null || fail "could not restore the captain tab after the exhausted seeded-prune fixture"
lab pane close "$PRUNE_EXHAUSTED_SEEDED_PANE" >/dev/null 2>&1 || true
assert_focus_is "$CAPTAIN_FOCUS" "exhausted seeded-prune fixture restoration"
teardown_task prune-exhausted "$HOME_DIR" > "$TMP_ROOT/prune-exhausted-teardown.out" 2> "$TMP_ROOT/prune-exhausted-teardown.err" \
  || fail "exhausted seeded-prune flat teardown failed: $(cat "$TMP_ROOT/prune-exhausted-teardown.err")"
grep -F "remains quarantined" "$TMP_ROOT/prune-exhausted-teardown.err" >/dev/null 2>&1 \
  || fail "a retained prune fallback journal was not kept quarantined at teardown"
rm -f "$PRUNE_EXHAUSTED_JOURNAL"
assert_focus_is "$CAPTAIN_FOCUS" "exhausted seeded-prune fixture cleanup"
pass "real Herdr lab: an exhausted seeded-prune bound falls back flat with a stdout diagnostic and a quarantined journal record"

LOCK_CONTENTION_READY="$TMP_ROOT/lock-contention-ready"
LOCK_CONTENTION_RELEASE="$TMP_ROOT/lock-contention-release"
LOCK_CONTENTION_PATH=$(session_presentation_lock_path) \
  || fail "could not resolve the session presentation lock for contention"
ROOT="$ROOT" READY="$LOCK_CONTENTION_READY" RELEASE="$LOCK_CONTENTION_RELEASE" \
  LOCK="$LOCK_CONTENTION_PATH" bash -c '
  . "$ROOT/bin/fm-wake-lib.sh"
  fm_lock_try_acquire "$LOCK" || exit 1
  : > "$READY"
  while [ ! -e "$RELEASE" ]; do sleep 0.05; done
  fm_lock_release "$LOCK"
' &
LOCK_CONTENTION_OWNER_PID=$!
while [ ! -e "$LOCK_CONTENTION_READY" ] && kill -0 "$LOCK_CONTENTION_OWNER_PID" 2>/dev/null; do sleep 0.01; done
[ -e "$LOCK_CONTENTION_READY" ] || fail "could not hold the guarded lab presentation lock"
LOCK_CONTENTION_START=$(log_line_count)
LOCK_CONTENTION_FOCUS_START=$(focus_audit_line_count)
LOCK_CONTENTION_MOVE_START=$(wc -l < "$MOVE_CALL_LOG" | tr -d '[:space:]')
if FM_HERDR_PRESENTATION_RETRY_TRIES=2 FM_HERDR_PRESENTATION_RETRY_TRY_SECONDS=1 \
  spawn_task lock-contended "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/lock-contended.out" 2> "$TMP_ROOT/lock-contended.err"; then
  LOCK_CONTENTION_STATUS=0
else
  LOCK_CONTENTION_STATUS=$?
fi
: > "$LOCK_CONTENTION_RELEASE"
wait "$LOCK_CONTENTION_OWNER_PID" || fail "guarded lab presentation lock owner failed"
LOCK_CONTENTION_OWNER_PID=
[ "$LOCK_CONTENTION_STATUS" -eq 0 ] \
  || fail "bounded presentation lock contention did not fall back to a successful flat spawn: $(cat "$TMP_ROOT/lock-contended.err")"
grep -F "presentation focus lock unavailable; using the ordinary flat layout without projection" "$TMP_ROOT/lock-contended.err" >/dev/null 2>&1 \
  || fail "bounded presentation lock contention did not warn about flat fallback"
grep -F "session lock is still held by another spawn; retrying (try 2 of 2, 1s each)" "$TMP_ROOT/lock-contended.err" >/dev/null 2>&1 \
  || fail "bounded presentation lock contention did not retry before falling back: $(cat "$TMP_ROOT/lock-contended.err")"
LOCK_CONTENTION_JOURNAL="$HOME_DIR/state/lock-contended.herdr-presentation"
sed -n '1p' "$TMP_ROOT/lock-contended.out" | grep -F "HERDR_PRESENTATION_FALLBACK: lock-contended reason=lock-contended bound=2x1s record=$LOCK_CONTENTION_JOURNAL - " >/dev/null 2>&1 \
  || fail "bounded presentation lock contention did not print its actionable stdout diagnostic: $(cat "$TMP_ROOT/lock-contended.out")"
sed -n '2p' "$TMP_ROOT/lock-contended.out" | grep -q '^spawned lock-contended ' \
  || fail "the lock flat-fallback diagnostic did not precede the spawn result line: $(cat "$TMP_ROOT/lock-contended.out")"
LOCK_CONTENTION_META="$HOME_DIR/state/lock-contended.meta"
remember_meta_worktree "$LOCK_CONTENTION_META" >/dev/null
LOCK_CONTENTION_WSID=$(grep '^herdr_workspace_id=' "$LOCK_CONTENTION_META" | cut -d= -f2-)
[ "$LOCK_CONTENTION_WSID" = "$FIRSTMATE_WSID" ] \
  || fail "bounded lock contention did not use the ordinary flat firstmate workspace"
[ "$(cat "$LOCK_CONTENTION_JOURNAL")" = "$(printf 'version=3\ntask_id=lock-contended\nfallback=lock-contended')" ] \
  || fail "bounded lock contention did not record a token-less fallback-only journal: $(cat "$LOCK_CONTENTION_JOURNAL" 2>&1)"
LOCK_CONTENTION_CALLS=$(sed -n "$((LOCK_CONTENTION_START + 1)),\$p" "$HERDR_CALL_LOG")
# session list is required to resolve the shared session lock path before the
# bounded acquire attempt; it must not unlock projection create or move.
if printf '%s\n' "$LOCK_CONTENTION_CALLS" | grep -E $'^(workspace\tcreate|pane\tclose|api\tschema)' >/dev/null 2>&1; then
  fail "bounded lock contention performed an unlocked projection mutation or ordering capability call"
fi
[ "$(wc -l < "$MOVE_CALL_LOG" | tr -d '[:space:]')" = "$LOCK_CONTENTION_MOVE_START" ] \
  || fail "bounded lock contention invoked workspace.move"
assert_focus_is "$CAPTAIN_FOCUS" "bounded presentation lock flat fallback"
assert_raw_presentation_mutations_preserved_since "$LOCK_CONTENTION_FOCUS_START" "bounded presentation lock flat fallback"
teardown_task lock-contended "$HOME_DIR" > "$TMP_ROOT/lock-contended-teardown.out" 2> "$TMP_ROOT/lock-contended-teardown.err" \
  || fail "flat lock-contention fixture teardown failed: $(cat "$TMP_ROOT/lock-contended-teardown.err")"
assert_focus_is "$CAPTAIN_FOCUS" "bounded presentation lock flat fallback teardown"
[ ! -e "$LOCK_CONTENTION_JOURNAL" ] || fail "the fallback-only record outlived its flat task's teardown"
if grep -F "remains quarantined" "$TMP_ROOT/lock-contended-teardown.err" >/dev/null 2>&1; then
  fail "a fallback-only record was reported as a quarantined projection at teardown"
fi
pass "real Herdr lab: bounded lock contention retries, then falls back flat with a stdout diagnostic and fallback-only record, without projection or focus drift"

# A lock released during the bounded wait is acquired on a later try, so the
# worker is projected rather than silently demoted to the flat layout.
LOCK_RETRY_READY="$TMP_ROOT/lock-retry-ready"
LOCK_RETRY_RELEASE="$TMP_ROOT/lock-retry-release"
ROOT="$ROOT" READY="$LOCK_RETRY_READY" RELEASE="$LOCK_RETRY_RELEASE" \
  LOCK="$LOCK_CONTENTION_PATH" bash -c '
  . "$ROOT/bin/fm-wake-lib.sh"
  fm_lock_try_acquire "$LOCK" || exit 1
  : > "$READY"
  while [ ! -e "$RELEASE" ]; do sleep 0.05; done
  fm_lock_release "$LOCK"
' &
LOCK_CONTENTION_OWNER_PID=$!
while [ ! -e "$LOCK_RETRY_READY" ] && kill -0 "$LOCK_CONTENTION_OWNER_PID" 2>/dev/null; do sleep 0.01; done
[ -e "$LOCK_RETRY_READY" ] || fail "could not hold the guarded lab presentation lock for the retry case"
cp "$MOVE_CALL_LOG" "$TMP_ROOT/move-log-before-lock-retry"
FM_HERDR_PRESENTATION_RETRY_TRIES=3 FM_HERDR_PRESENTATION_RETRY_TRY_SECONDS=1 \
  spawn_task lock-retry "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/lock-retry.out" 2> "$TMP_ROOT/lock-retry.err" &
LOCK_RETRY_PID=$!
LOCK_RETRY_WAIT=0
while ! grep -F "session lock is still held by another spawn; retrying" "$TMP_ROOT/lock-retry.err" >/dev/null 2>&1; do
  kill -0 "$LOCK_RETRY_PID" 2>/dev/null || break
  LOCK_RETRY_WAIT=$((LOCK_RETRY_WAIT + 1))
  [ "$LOCK_RETRY_WAIT" -lt 600 ] || break
  sleep 0.05
done
: > "$LOCK_RETRY_RELEASE"
wait "$LOCK_CONTENTION_OWNER_PID" || fail "guarded lab presentation lock owner failed in the retry case"
LOCK_CONTENTION_OWNER_PID=
wait "$LOCK_RETRY_PID" || fail "a lock released within the bounded wait failed the spawn: $(cat "$TMP_ROOT/lock-retry.err")"
remember_meta_worktree "$HOME_DIR/state/lock-retry.meta" >/dev/null
grep -F "session lock is still held by another spawn; retrying (try 2 of 3, 1s each)" "$TMP_ROOT/lock-retry.err" >/dev/null 2>&1 \
  || fail "the lock retry case did not exercise a retried try: $(cat "$TMP_ROOT/lock-retry.err")"
[ "$(grep '^herdr_workspace_id=' "$HOME_DIR/state/lock-retry.meta" | cut -d= -f2-)" != "$FIRSTMATE_WSID" ] \
  || fail "a lock released within the bounded wait still fell back flat"
grep -q '^version=2$' "$HOME_DIR/state/lock-retry.herdr-presentation" \
  || fail "a lock released within the bounded wait did not bind its projection"
if grep -q 'HERDR_PRESENTATION_FALLBACK' "$TMP_ROOT/lock-retry.out"; then
  fail "a lock released within the bounded wait printed a flat-fallback diagnostic"
fi
assert_focus_is "$CAPTAIN_FOCUS" "lock acquired on retry"
teardown_task lock-retry "$HOME_DIR" > "$TMP_ROOT/lock-retry-teardown.out" 2> "$TMP_ROOT/lock-retry-teardown.err" \
  || fail "lock retry fixture teardown failed: $(cat "$TMP_ROOT/lock-retry-teardown.err")"
cp "$TMP_ROOT/move-log-before-lock-retry" "$MOVE_CALL_LOG"
assert_focus_is "$CAPTAIN_FOCUS" "lock acquired on retry cleanup"
pass "real Herdr lab: a presentation lock released within the bounded wait is acquired on retry and the worker is projected"

cleanup_all
trap - EXIT
