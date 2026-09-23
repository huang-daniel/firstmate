#!/usr/bin/env bash
# bin/fm-secondmate-restart.sh: persist-then-restart, and the honest fallback.
#
# What these pin, all through the real commands (real fm-send, real durable
# steering inbox, real parent-owned reply expectation, real fm-control
# transaction) against a lifecycle-modelling session-provider stub:
#
#   1. The persist request is a GATE. Nothing is stopped until that mate's own
#      correlated answer lands on the parent channel, and a mate that never
#      answers keeps its agent and gets the re-read message instead.
#   2. The order is persist THEN restart, observable in what reaches the pane.
#   3. The persist request is the task-subset of /stow: it asks for open records
#      and task status, and explicitly not for the memory, learnings, or
#      captain-preference sweeps.
#   4. Every unsafe case says what is known: pre-restart capability and persist
#      failures use the nudge path, while a failed relaunch is reported as an
#      unknown outcome; none is reported as a clean reload.
#   5. A remote mate whose idle state is unknown defers and receives the
#      re-read nudge through the fm-on transport.
#   6. End to end with bin/fm-update.sh: a live mate whose home needed no
#      fast-forward is still named for restart and genuinely restarted, and one
#      whose runtime cannot prove a restart keeps the honest re-read path with
#      its agent left running.
#   7. Staleness comes first: a mate whose running session recorded its home's
#      current instruction surface is reported current and never asked to
#      persist or stopped, while a stale one is restarted.
#   8. A provably busy mate is deferred after persisting and never restarted; a
#      provably idle one is reported restarted while idle, and one with no busy
#      record defers with idle not provable. A mate still finishing the turn
#      that carried its answer is re-read for the settle window and restarted on
#      the first proven idle; one busy for the whole window defers as before.
#   9. `restarted` requires the replacement to be verified: alive, holding the
#      home lock as a new session, and reporting the intended surface. A
#      replacement refused the lock by a surviving session is an unknown
#      outcome naming the lock collision.
#
# The stub also models each session start in a mate home: a live process whose
# argv[0] names a verified harness takes the home lock (unless a live holder
# refuses it) and records its revision through the real record command.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RESTART="$ROOT/bin/fm-secondmate-restart.sh"

fm_git_identity fmtest fmtest@example.com
TMP_ROOT=$(fm_test_tmproot fm-secondmate-restart)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 'kill_fake_sessions; rm -rf -- "$TMP_ROOT"' EXIT

# A session-provider stub that models the two things this pass depends on: the
# harness exit command stops the agent, a launch brief starts the replacement,
# and - when armed - the live mate ANSWERS a doorbell by doing what the persist
# request asks and reporting it on the parent channel with the correlation token
# the request carried. That answer is a real status append read by the real
# pending-reply machinery, not a stubbed verdict.
make_stub() {  # <case-dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
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
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'")
          staged=${payload#". '"}
          staged=${staged%"'"}
          [ ! -f "$staged" ] || payload=$(cat "$staged")
          ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit)
          if [ -e "$D/slow-relaunch" ]; then
            case "$target" in *fm-sm1) : > "$D/remote-relaunch-start" ;; esac
          fi
          if [ -e "$D/remote-relaunch-start" ] && [ ! -e "$D/remote-relaunch-end" ]; then
            : > "$D/local-relaunch-during-remote"
          fi
          printf 'zsh' > "$D/command.$target"
          # The old agent's process exits with it, unless the case models a
          # session that outlives its endpoint's agent.
          win=${target##*:}; win=${win#=}
          if [ -f "$D/session.$win" ] && [ ! -e "$D/old-session-survives" ]; then
            kill "$(cat "$D/session.$win")" 2>/dev/null || true
          fi
          ;;
        *'encode launch-brief'*)
          if [ -e "$D/slow-relaunch" ] && [[ "$target" = *fm-sm1 ]]; then
            : > "$D/remote-relaunch-start"
            /bin/sleep 2
            : > "$D/remote-relaunch-end"
          fi
          cat "$D/becomes" > "$D/command.$target"
          # Model the replacement's own session start: a live harness process
          # takes the home lock (unless an old live holder refuses it) and
          # records the revision it started on.
          win=${target##*:}; win=${win#=}
          if [ -f "$D/home.$win" ] && [ ! -e "$D/no-session-start" ]; then
            FM_FAKE_DIR="$D" "$D/start-session" "$(cat "$D/home.$win")" "$win"
          fi
          ;;
        ': Firstmate instruction waiting: list '*)
          printf 'doorbell\n' >> "$D/rings"
          if [ -x "$D/on-doorbell" ]; then
            "$D/on-doorbell" "$payload"
          fi
          win=${target##*:}; win=${win#=}; mate=${win#fm-}
          if [ -f "$D/answer.$mate" ]; then
            # Model the mate: read the newest instruction it was handed and
            # report back on the parent channel, carrying the correlation token
            # the request itself embedded.
            inbox="$FM_HOME/state/$mate.inbox"
            corr=$(cat "$inbox"/*.msg 2>/dev/null \
              | grep -oE 'corr=[0-9a-f]{16}' | head -1)
            if [ -n "$corr" ]; then
              printf 'done [%s]: open records written down\n' "$corr" \
                >> "$FM_HOME/state/$mate.status"
            fi
          fi
          ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    target=
    prev=
    for a in "$@"; do
      if [ "$prev" = -t ]; then target=$a; fi
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*)
          if [ -f "$D/command.$target" ]; then cat "$D/command.$target"; else cat "$D/command"; fi
          printf '\n'; exit 0 ;;
        *pane_current_path*)
          win=${target##*:}; win=${win#=}
          if [ -f "$D/home.$win" ]; then cat "$D/home.$win"; else cat "$D/cwd"; fi
          printf '\n'; exit 0 ;;

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
case "${1:-}" in
  ''|*[!0-9]*) ;;
  *) /bin/sleep 0.01 ;;
esac
exit 0
SH
  chmod +x "$fb/sleep"
  cat > "$1/fake/start-session" <<'SH'
#!/usr/bin/env bash
# start-session <home> <window>: model a session start in <home>.
set -u
D=$FM_FAKE_DIR home=$1 win=$2
old=$(sed -n 1p "$home/state/.lock" 2>/dev/null || true)
if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
  exit 0  # the lock is refused; the new session runs read-only
fi
# argv[0] names a verified harness, which is what the lock's liveness test reads.
bash -c 'exec -a claude "$0" 600' "$(cat "$D/sleep-bin")" </dev/null >/dev/null 2>&1 &
pid=$!
printf '%s\n' "$pid" >> "$D/pids"
printf '%s\n' "$pid" > "$D/session.$win"
printf '%s\n' "$pid" > "$home/state/.lock"
FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE= "$FM_FAKE_ROOT/bin/fm-secondmate-health.sh" record
SH
  chmod +x "$1/fake/start-session"
  command -v sleep > "$1/fake/sleep-bin"
}

# start_old_session <case-dir> <id>: a live session already running in the
# mate's home, holding its lock and recording the revision it started on.
start_old_session() {
  local dir=$1 id=$2
  FM_FAKE_DIR="$dir/fake" FM_FAKE_ROOT="$ROOT" \
    "$dir/fake/start-session" "$(cat "$dir/fake/home.fm-$id")" "fm-$id"
}

kill_fake_sessions() {
  local f pid
  for f in "$TMP_ROOT"/*/fake/pids; do
    [ -f "$f" ] || continue
    while IFS= read -r pid; do kill "$pid" 2>/dev/null || true; done < "$f"
  done
}

# new_case <name> -> a parent home with a stub session provider.
new_case() {
  local dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/fake"
  printf 'claude\n' > "$dir/home/config/secondmate-harness"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  : > "$dir/fake/rings"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  make_stub "$dir"
  printf '%s\n' "$dir"
}

# add_local_mate <case-dir> <id> [harness] [backend-line]
# A live LOCAL second mate: a real git worktree for its home, plus the durable
# record this home keeps for it.
add_local_mate() {
  local dir=$1 id=$2 harness=${3:-claude} backend=${4:-}
  local home="$dir/home" smhome="$dir/$id-home"
  fm_git_worktree "$dir/$id-repo" "$smhome" "sm-$id"
  mkdir -p "$smhome/state" "$smhome/data" "$smhome/bin" "$home/data/$id"
  printf '%s\n' "$id" > "$smhome/.fm-secondmate-home"
  printf '# agents\n' > "$smhome/AGENTS.md"
  printf '# charter\n' > "$home/data/$id/brief.md"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$smhome"
    echo "project=$smhome"
    echo "harness=$harness"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$smhome"
    [ -z "$backend" ] || echo "backend=$backend"
  } > "$home/state/$id.meta"
  printf '%s\n' "fm-$id" >> "$dir/fake/windows"
  printf '%s' "$smhome" > "$dir/fake/cwd"
  printf '%s' "$smhome" > "$dir/fake/home.fm-$id"
  arm_busy "$dir" "$id" idle
}

# add_repo_backed_mate <case-dir> <id> [harness] [backend-line]
# Like add_local_mate, but the world is the one /updatefirstmate actually runs
# against: a bare origin, a firstmate repo clone on its default branch, and the
# mate's home as a DETACHED worktree of that repo already sitting on origin's tip.
# That "already current" home is the shape the old classifier skipped entirely.
add_repo_backed_mate() {  # <case-dir> <id> [harness] [backend]
  local dir=$1 id=$2 harness=${3:-claude} backend=${4:-}
  local home="$dir/home" repo="$dir/fmrepo" smhome="$dir/$id-home"
  if [ ! -d "$repo" ]; then
    git init -q --bare "$dir/origin.git"
    git -C "$dir/origin.git" symbolic-ref HEAD refs/heads/main
    git clone -q "$dir/origin.git" "$dir/seed" 2>/dev/null
    mkdir -p "$dir/seed/bin" "$dir/seed/.agents/skills"
    printf '# agents\n' > "$dir/seed/AGENTS.md"
    printf 'echo a\n' > "$dir/seed/bin/tool.sh"
    printf 's1\n' > "$dir/seed/.agents/skills/note.md"
    # The operational dirs a live home carries are gitignored in a real firstmate
    # checkout; without that the home would read as dirty and be skipped.
    printf '/data/\n/state/\n/config/\n/projects/\n/.no-mistakes/\n.fm-secondmate-home\n' \
      > "$dir/seed/.gitignore"
    git -C "$dir/seed" add -A
    git -C "$dir/seed" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm c1
    git -C "$dir/seed" push -q origin main
    git clone -q "$dir/origin.git" "$repo"
    git -C "$repo" remote set-head origin main >/dev/null 2>&1 || true
    touch "$home/state/.last-watcher-beat"
  fi
  git -C "$repo" worktree add -q --detach "$smhome" main
  mkdir -p "$smhome/state" "$smhome/data" "$home/data/$id"
  printf '%s\n' "$id" > "$smhome/.fm-secondmate-home"
  printf '# charter\n' > "$home/data/$id/brief.md"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$smhome"
    echo "project=$smhome"
    echo "harness=$harness"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$smhome"
    [ -z "$backend" ] || echo "backend=$backend"
  } > "$home/state/$id.meta"
  printf '%s\n' "fm-$id" >> "$dir/fake/windows"
  printf '%s' "$smhome" > "$dir/fake/cwd"
  printf '%s' "$smhome" > "$dir/fake/home.fm-$id"
  arm_busy "$dir" "$id" idle
}

# run_update_in_case <case-dir>: the real /updatefirstmate mechanics over that world.
run_update_in_case() {
  local dir=$1
  env PATH="$dir/fakebin:$PATH" FM_FAKE_DIR="$dir/fake" FM_FAKE_ROOT="$ROOT" \
    FM_SECONDMATE_VERIFY_WAIT="${FM_TEST_VERIFY_WAIT:-5}" FM_SECONDMATE_VERIFY_POLL=1 \
    FM_ROOT_OVERRIDE="$dir/fmrepo" FM_HOME="$dir/home" \
    FM_SSH_BIN="${FM_TEST_SSH_BIN:-ssh}" \
    "$ROOT/bin/fm-update.sh" 2>/dev/null
}

# arm_answer <case-dir> <id>: make the modelled mate answer the persist request.
arm_answer() {
  local dir=$1 id=$2
  : > "$dir/fake/answer.$id"
}

run_restart() {  # <case-dir> <args...>
  local dir=$1; shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_FAKE_ROOT="$ROOT" FM_SPAWN_NO_GUARD=1 FM_SECONDMATE_PERSIST_POLL=1 \
    FM_SECONDMATE_VERIFY_WAIT="${FM_TEST_VERIFY_WAIT:-5}" FM_SECONDMATE_VERIFY_POLL=1 \
    FM_SECONDMATE_PERSIST_WAIT="${FM_TEST_PERSIST_WAIT:-30}" \
    FM_SECONDMATE_IDLE_SETTLE="${FM_TEST_IDLE_SETTLE:-0}" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    FM_SSH_BIN="${FM_TEST_SSH_BIN:-ssh}" \
    "$RESTART" "$@" 2>&1
}

# --- T1: the persist request is the task subset of /stow, and it gates --------
test_persist_gates_and_asks_only_for_open_records() {
  local dir out rc request
  dir=$(new_case gate)
  add_local_mate "$dir" sm1
  # No answer armed: the mate never confirms its open work is written down.
  out=$(FM_TEST_PERSIST_WAIT=0 run_restart "$dir" fm-sm1); rc=$?

  expect_code 3 "$rc" "an unconfirmed persist is a fallback, not a success"$'\n'"$out"
  assert_contains "$out" "nudged: sm1:" "an unconfirmed persist must fall back to the re-read message"
  assert_contains "$out" "its open work is written down" "the fallback must name the missing confirmation"
  assert_not_contains "$out" "restarted: sm1" "a mate that never confirmed must not be restarted"
  assert_contains "$out" "summary: 0 of 1 restarted" "the summary must not claim a reload"
  # The agent is untouched: nothing exited, nothing relaunched.
  assert_no_grep '^/exit$' "$dir/fake/literal" "the agent was stopped without a confirmed persist"
  assert_absent "$dir/home/state/sm1.control-relaunch" \
    "a restart transaction was opened without a confirmed persist"
  grep -h '^phase=' "$dir/home/state/pending-replies"/* | grep -q '^phase=awaiting_report$' \
    || fail "the timed-out persist expectation was closed instead of left to recovery"

  # The request the mate actually received is the open-record half of /stow only.
  request=$(cat "$dir/home/state/sm1.inbox"/*.msg)
  assert_contains "$request" "Open-record persistence" "the request must reuse stow's open-record contract"
  assert_contains "$request" "file a task for each open record" "the request must ask for the unfiled open records"
  assert_contains "$request" "correct any task whose status" "the request must ask for stale task status"
  assert_contains "$request" "captain call you had formed but never registered" \
    "the request must flush an unregistered captain call"
  assert_contains "$request" "Do NOT run the memory, learnings, or captain-preference sweeps" \
    "the request must exclude the memory curation half of stow"
  pass "T1 persist is a gate, and asks for open records and task status only"
}

# --- T2: persist THEN restart, in that order --------------------------------
test_persist_precedes_restart() {
  local dir out rc doorbell_line exit_line
  dir=$(new_case order)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 0 "$rc" "a confirmed persist should restart the mate"$'\n'"$out"
  assert_contains "$out" "restarted: sm1 (claude)" "the mate should be restarted on its pinned runtime"
  assert_contains "$out" "summary: 1 of 1 restarted while idle, 0 already current, 0 deferred, 0 nudged, 0 unreached" "the summary should report the reload"
  # The pane transcript orders the two phases: the instruction doorbell first,
  # the harness exit command only after it.
  doorbell_line=$(grep -n '^: Firstmate instruction waiting: ' "$dir/fake/literal" | head -1 | cut -d: -f1)
  exit_line=$(grep -n '^/exit$' "$dir/fake/literal" | head -1 | cut -d: -f1)
  [ -n "$doorbell_line" ] || fail "the persist request never reached the mate"
  [ -n "$exit_line" ] || fail "the mate was never stopped, so it was not restarted"
  [ "$doorbell_line" -lt "$exit_line" ] \
    || fail "the agent was stopped before it was asked to persist (persist line $doorbell_line, exit line $exit_line)"
  # The reply expectation is settled rather than left open behind the restart.
  grep -h '^phase=' "$dir/home/state/pending-replies"/* | grep -q '^phase=resolved$' \
    || fail "the persist answer did not settle its durable expectation"
  pass "T2 the mate persists before anything is stopped"
}

# --- T2b: an answer delivered at a zero-second bound still releases the gate -
test_arrived_answer_precedes_deadline_check() {
  local dir out rc
  dir=$(new_case arrived-at-bound)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1

  out=$(FM_TEST_PERSIST_WAIT=0 run_restart "$dir" sm1); rc=$?

  expect_code 0 "$rc" "an answer delivered with the request must beat the deadline check"$'\n'"$out"
  assert_contains "$out" "restarted: sm1" "the arrived persist answer was ignored at the deadline"
  pass "T2b an arrived persist answer is resolved before timeout"
}

# --- T2c: an answer arriving between resolution and timeout wins -------------
test_answer_between_resolution_and_timeout_wins() {
  local dir out rc
  dir=$(new_case answer-at-timeout-decision)
  add_local_mate "$dir" sm1

  # Delay the modelled answer until the first resolution attempt has completed
  # its unsuccessful status scan. The real pending-reply machinery publishes
  # that scan signature with mv; this wrapper appends the correlated answer only
  # after that publication, reproducing the boundary race deterministically.
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
/bin/mv "$@" || exit $?
target=${!#}
case "$target" in
  "${FM_FAKE_DIR%/fake}"/home/state/pending-replies/*)
    if [ ! -e "$FM_FAKE_DIR/answer-after-scan" ] \
      && grep -q '^parent_status_scan_signature=.' "$target"; then
      : > "$FM_FAKE_DIR/answer-after-scan"
      corr=${target##*/}
      status=$(sed -n 's/^parent_status=//p' "$target")
      printf 'done [corr=%s]: open records written down\n' "$corr" >> "$status"
    fi
    ;;
esac
SH
  chmod +x "$dir/fakebin/mv"

  out=$(FM_TEST_PERSIST_WAIT=0 run_restart "$dir" sm1); rc=$?

  expect_code 0 "$rc" "an answer already on disk at the timeout decision must release the gate"$'\n'"$out"
  assert_contains "$out" "restarted: sm1" "the reply that raced the timeout was ignored"
  assert_not_contains "$out" "nudged: sm1" "a confirmed mate must not take the timeout fallback"
  pass "T2c a reply between the preliminary scan and timeout decision wins"
}

# --- T3: a runtime that cannot prove a restart never gets one ----------------
test_unprovable_runtime_falls_back() {
  local dir out rc
  dir=$(new_case unprovable)
  # zellij has no recovery-grade agent-state classifier, so "the old agent
  # stopped and the replacement came up" can never be established there.
  add_local_mate "$dir" sm1 claude zellij

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 3 "$rc" "an unprovable runtime must not report a reload"$'\n'"$out"
  assert_contains "$out" "nudged: sm1:" "an unprovable runtime must fall back to the re-read message"
  assert_contains "$out" "cannot prove an agent stopped" "the fallback must name the runtime limit"
  assert_not_contains "$out" "restarted: sm1" "an unprovable runtime must not be reported as restarted"
  # It is never even asked to spend a turn persisting, because it could not be
  # restarted afterwards either way; the only thing it was handed is the nudge.
  assert_no_grep 'Open-record persistence' "$dir/home/state/sm1.inbox/001.msg" \
    "a mate that cannot be restarted should not be asked to persist first"
  assert_grep 're-read your AGENTS.md' "$dir/home/state/sm1.inbox/001.msg" \
    "the fallback should hand the mate the ordinary re-read message"
  pass "T3 a runtime that cannot prove a restart falls back to the re-read message"
}

# --- T4: a mate with no durable record in this home --------------------------
test_unknown_mate_is_accounted_for() {
  local dir out rc
  dir=$(new_case unknown)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1

  out=$(run_restart "$dir" sm1 ghost); rc=$?

  expect_code 3 "$rc" "an unknown mate must not pass silently"$'\n'"$out"
  assert_contains "$out" "restarted: sm1" "the known mate should still be restarted"
  assert_contains "$out" "ghost:" "the unknown mate must be accounted for by name"
  assert_contains "$out" "no durable record" "the unknown mate's reason must be concrete"
  assert_contains "$out" "summary: 1 of 2 restarted while idle, 0 already current, 0 deferred, 0 nudged, 1 unreached" "the summary must count both mates"
  pass "T4 every named mate is accounted for, including one this home does not know"
}

# --- T5: a refused restart leaves the mate running and says so ---------------
test_refused_restart_falls_back_without_claiming_a_reload() {
  local dir out rc before
  dir=$(new_case refused)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  # muse is a crewmate-only adapter, so the control plane refuses a secondmate
  # relaunch onto it BEFORE stopping anything.
  printf 'muse\n' > "$dir/home/config/secondmate-harness"
  before=$(cat "$dir/fake/command")

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 3 "$rc" "a refused restart must not be reported as a reload"$'\n'"$out"
  assert_contains "$out" "unreached: sm1:" "a failed restart must be reported as unknown"
  assert_contains "$out" "restart outcome is unknown" "the report must not attribute an ambiguous failure"
  assert_not_contains "$out" "nudged: sm1" "a failed restart must not claim the old agent was nudged"
  assert_not_contains "$out" "restarted: sm1" "a refused restart must not be reported as restarted"
  [ "$(cat "$dir/fake/command")" = "$before" ] \
    || fail "a refusal before the stop should leave the running agent exactly as it was"
  assert_no_grep '^/exit$' "$dir/fake/literal" "a pre-stop refusal must not have stopped the agent"
  pass "T5 a refused restart leaves the mate running and reports an unknown outcome"
}

# --- T6: a remote mate restarts over the fm-on hop, on the parent's pin -------
# The seam decodes what fm-on.sh actually put on the wire, so this pins the
# host-local command and the profile the PARENT resolved, not a local shortcut.
# The far side also models the live mate: it answers the persist request that
# crossed the same hop, on the parent channel, with that request's own token.
setup_remote_case() {  # <case-dir> <id> <ssh-mode>
  local dir=$1 id=$2 mode=$3
  local fb="$dir/fakebin"
  mkdir -p "$dir/$id-home"
  {
    echo "window=remote:$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$dir/$id-home"
    echo "project=$dir/$id-home"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/$id-home"
    echo "remote_host=remote-mac"
    echo "remote_backend=herdr"
    echo "remote_target=fm-remote:2ndmate-$id"
  } > "$dir/home/state/$id.meta"
  printf -- '- %s - remote domain (host: remote-mac; root: /srv/fm; home: /srv/%s; scope: things; projects: p; added 2026-09-03)\n' \
    "$id" "$id" > "$dir/home/data/secondmates.md"
  cat > "$fb/fake-ssh" <<'SH'
#!/usr/bin/env bash
set -u
cat > /dev/null
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
shift 2  # host, fm-remote-entrypoint.sh
argv_b64=$4
decode() { printf '%s' "$1" | base64 --decode 2>/dev/null || printf '%s' "$1" | base64 -D; }
rargs=()
while IFS= read -r -d '' a; do rargs+=("$a"); done < <(decode "$argv_b64")
printf '%s\n' "${rargs[*]}" >> "$FM_FAKE_SSH_LOG"
case "${FM_FAKE_SSH_MODE:-ok}" in
  unreachable) exit 255 ;;
esac
case "${rargs[1]:-}" in
  send)
    # Model the live remote mate: act on the instruction and report back on the
    # parent channel, carrying the correlation token the request embedded.
    if [ -n "${FM_FAKE_ANSWER_STATUS:-}" ]; then
      corr=$(printf '%s' "${rargs[3]:-}" | grep -oE 'corr=[0-9a-f]{16}' | head -1)
      [ -z "$corr" ] || printf 'done [%s]: open records written down\n' "$corr" \
        >> "$FM_FAKE_ANSWER_STATUS"
    fi
    ;;
  state) printf 'alive\n' ;;
  self)
    [ "${FM_FAKE_SSH_MODE:-ok}" != missing-identity ] || exit 1
    printf 'lock_pid=111\nlock_live=yes\nsession_pid=111\nsession_commit=c1\nsession_instr=AGENTS.md:a1,bin:b1,.agents/skills:s2\n'
    printf 'head_commit=c2\nhead_instr=AGENTS.md:a2,bin:b2,.agents/skills:s2\n'
    ;;
esac
exit 0
SH
  chmod +x "$fb/fake-ssh"
  : > "$dir/ssh.log"
  export FM_FAKE_SSH_LOG="$dir/ssh.log"
  export FM_FAKE_SSH_MODE="$mode"
  export FM_TEST_SSH_BIN="$fb/fake-ssh"
}

test_remote_mate_restarts_over_the_transport_hop() {
  local dir out rc
  dir=$(new_case remote)
  setup_remote_case "$dir" sm2 ok
  export FM_FAKE_ANSWER_STATUS="$dir/home/state/sm2.status"
  # The parent's own pin is what the replacement must run on; the remote home's
  # copy of config/secondmate-harness is a different home's file.
  printf 'codex big-model high\n' > "$dir/home/config/secondmate-harness"

  out=$(run_restart "$dir" fm-sm2); rc=$?
  unset FM_FAKE_ANSWER_STATUS

  expect_code 3 "$rc" "remote idle cannot be proven: $out"
  assert_contains "$out" "deferred: sm2: idle not provable (remote-idle-not-provable)" "remote must defer"
  assert_contains "$out" "nudged: sm2:" "remote must receive the re-read nudge"
  assert_no_grep '^fm-remote-secondmate-control.sh relaunch' "$dir/ssh.log" "remote must not restart"
  pass "T6 a remote mate defers and receives the re-read nudge"

}

# --- T7: an unreachable host is unknown, never a claimed reload --------------
test_unreachable_host_is_reported_unknown() {
  local dir out rc
  dir=$(new_case unreachable)
  setup_remote_case "$dir" sm3 unreachable

  out=$(run_restart "$dir" sm3); rc=$?

  expect_code 3 "$rc" "an unreachable host must not be reported as a reload"$'\n'"$out"
  assert_not_contains "$out" "restarted: sm3" "an unreachable host must not be claimed as restarted"
  assert_contains "$out" "sm3:" "the unreachable mate must still be named"
  assert_contains "$out" "could not be delivered" "an unreachable host must be reported as undelivered, not as reloaded"
  pass "T7 an unreachable host is reported honestly instead of claimed as reloaded"
}

# --- T8: a local restart lands on this home's durable pin, and says which -----
test_local_restart_uses_the_home_pin_and_reports_what_ran() {
  local dir out rc
  dir=$(new_case pin)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  printf 'codex\n' > "$dir/home/config/secondmate-harness"
  printf 'codex' > "$dir/fake/becomes"

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 0 "$rc" "a pinned local restart should succeed"$'\n'"$out"
  assert_contains "$out" "restarted: sm1 (codex)" \
    "the restart should land on this home's pin and report the runtime that actually came up"
  [ "$(grep '^harness=' "$dir/home/state/sm1.meta" | tail -1)" = "harness=codex" ] \
    || fail "the durable record did not follow the replacement onto the pinned runtime"
  pass "T8 a local restart re-resolves this home's pin and reports the runtime that came up"
}

test_native_ultra_restart_keeps_local_and_remote_profiles() {
  local dir out rc
  dir=$(new_case native-local)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  printf 'pi codex-native/gpt-6-astra ultra\n' > "$dir/home/config/secondmate-harness"
  printf 'pi' > "$dir/fake/becomes"
  printf '#!/usr/bin/env bash\nprintf "Options: --tui-mode\\n"\n' > "$dir/fakebin/pi"
  chmod +x "$dir/fakebin/pi"
  out=$(run_restart "$dir" sm1); rc=$?
  expect_code 0 "$rc" "native local restart failed: $out"
  assert_contains "$out" "restarted: sm1 (pi)" "native local restart did not complete"
  assert_contains "$(cat "$dir/home/state/sm1.meta")" "effort=ultra" "local restart dropped native effort"
  assert_contains "$(cat "$dir/fake/literal")" "--codex-effort 'ultra'" "local restart dropped native launch flag"

  dir=$(new_case native-remote)
  setup_remote_case "$dir" sm2 ok
  export FM_FAKE_ANSWER_STATUS="$dir/home/state/sm2.status"
  printf 'pi-signed codex-native/gpt-6-astra ultra\n' > "$dir/home/config/secondmate-harness"
  out=$(run_restart "$dir" sm2); rc=$?
  unset FM_FAKE_ANSWER_STATUS
  expect_code 3 "$rc" "native remote idle cannot be proven: $out"
  assert_contains "$out" "deferred: sm2: idle not provable" "native remote must defer"
  assert_no_grep '^fm-remote-secondmate-control.sh relaunch' "$dir/ssh.log" "native remote must not restart"
  pass "native Ultra survives local restart and remote unknown defers"

}

# --- T9: an unrelated concurrent reply cannot release the persist gate -------
test_concurrent_reply_cannot_release_persist_gate() {
  local dir out rc state corr rec
  dir=$(new_case correlation)
  add_local_mate "$dir" sm1
  state="$dir/home/state"
  corr=ffffffffffffffff
  rec="$state/pending-replies/$corr"
  cat > "$dir/fake/on-doorbell" <<SH
#!/usr/bin/env bash
[ ! -e "$dir/fake/concurrent-created" ] || exit 0
: > "$dir/fake/concurrent-created"
mkdir -p "$state/pending-replies"
cat > "$rec" <<EOF
phase=awaiting_report
task_id=sm1
parent_status=$state/sm1.status
parent_status_scan_signature=
delivered_epoch=1
resolved_epoch=
resolved_via=
EOF
printf 'done [corr=$corr]: unrelated request answered\n' >> "$state/sm1.status"
SH
  chmod +x "$dir/fake/on-doorbell"

  out=$(FM_TEST_PERSIST_WAIT=0 run_restart "$dir" sm1); rc=$?

  expect_code 3 "$rc" "an unrelated concurrent answer must not release the persist gate"$'\n'"$out"
  assert_not_contains "$out" "restarted: sm1" "the unrelated answer authorized a restart"
  assert_no_grep '^/exit$' "$dir/fake/literal" "the unrelated answer stopped the mate"
  pass "T9 the persist gate retains its explicitly allocated correlation"
}

# --- T10: one unanswered mate does not hold a confirmed mate behind it -------
test_persist_waits_are_polled_together() {
  local dir out rc exit_line nudge_line
  dir=$(new_case concurrent-waits)
  add_local_mate "$dir" sm1
  add_local_mate "$dir" sm2
  arm_answer "$dir" sm2

  out=$(FM_TEST_PERSIST_WAIT=3 run_restart "$dir" sm1 sm2); rc=$?

  expect_code 3 "$rc" "the unanswered mate should fall back after the confirmed mate restarts"$'\n'"$out"
  exit_line=$(grep -n '^/exit$' "$dir/fake/literal" | head -1 | cut -d: -f1)
  nudge_line=$(grep -n '^: Firstmate instruction waiting: ' "$dir/fake/literal" | tail -1 | cut -d: -f1)
  [ -n "$exit_line" ] && [ -n "$nudge_line" ] && [ "$exit_line" -lt "$nudge_line" ] \
    || fail "the first mate's timeout held the confirmed second mate behind it: $out"
  pass "T10 pending persist answers are polled as one fleet"
}

# --- T11: a failed post-stop relaunch is not described as a nudge ------------
test_post_stop_failure_is_reported_unreached() {
  local dir out rc
  dir=$(new_case post-stop)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  printf 'zsh' > "$dir/fake/becomes"

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 3 "$rc" "a post-stop relaunch failure must remain accounted for"$'\n'"$out"
  assert_contains "$out" "unreached: sm1:" "a stopped mate must be reported as unreached"
  assert_contains "$out" "restart outcome is unknown" "the report must not attribute the failed lifecycle operation"
  assert_not_contains "$out" "nudged: sm1" "a durable enqueue must not masquerade as a running mate's nudge"
  assert_contains "$out" "summary: 0 of 1 restarted while idle, 0 already current, 0 deferred, 0 nudged, 1 unreached" \
    "the summary must not claim that a stopped mate remains on older instructions with a message"
  pass "T11 post-stop restart failure is never misreported as a nudge"
}

# --- T12: relaunch work does not stop polling other persist answers ----------
test_relaunches_do_not_block_persist_polling() {
  local dir out rc
  dir=$(new_case relaunch-polling)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  : > "$dir/fake/slow-relaunch"
  add_local_mate "$dir" sm2
  export FM_FAKE_ANSWER_STATUS="$dir/home/state/sm1.status"
  arm_answer "$dir" sm2

  out=$(FM_TEST_PERSIST_WAIT=5 run_restart "$dir" sm1 sm2); rc=$?
  unset FM_FAKE_ANSWER_STATUS

  expect_code 0 "$rc" "both confirmed mates should restart independently"$'\n'"$out"
  assert_present "$dir/fake/local-relaunch-during-remote" \
    "the slow first relaunch blocked lifecycle progress for the second mate"
  assert_contains "$out" "summary: 2 of 2 restarted while idle, 0 already current, 0 deferred, 0 nudged, 0 unreached" \
    "parallel relaunches were not both accounted for"
  pass "T12 relaunch waits do not block fleet persistence polling"
}

# --- T13: a worker that cannot publish its result cannot hang the pass -------
test_unpublished_worker_result_is_accounted_for() {
  local dir out rc_file driver i result_dir
  dir=$(new_case worker-result)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  : > "$dir/fake/slow-relaunch"
  export FM_FAKE_ANSWER_STATUS="$dir/home/state/sm1.status"
  out="$dir/restart.out"
  rc_file="$dir/restart.rc"

  ( run_restart "$dir" sm1 > "$out" 2>&1; printf '%s\n' "$?" > "$rc_file" ) &
  driver=$!
  result_dir=
  i=0
  while [ "$i" -lt 200 ]; do
    result_dir=$(find "$dir/home/state" -maxdepth 1 -type d -name '.secondmate-restart.*' -print -quit)
    [ -e "$dir/fake/remote-relaunch-start" ] && [ -n "$result_dir" ] && break
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -n "$result_dir" ] || { kill "$driver" 2>/dev/null || true; fail "restart result directory never appeared"; }
  rm -rf -- "$result_dir"
  i=0
  while kill -0 "$driver" 2>/dev/null && [ "$i" -lt 400 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  if kill -0 "$driver" 2>/dev/null; then
    kill "$driver" 2>/dev/null || true
    wait "$driver" 2>/dev/null || true
    fail "a terminated restart worker left the parent hung"
  fi
  wait "$driver" 2>/dev/null || true
  unset FM_FAKE_ANSWER_STATUS

  [ "$(cat "$rc_file")" = 3 ] || fail "an unpublished worker result did not fail as accounted"
  assert_contains "$(cat "$out")" "restart worker exited before publishing an outcome" \
    "the missing worker result was not reported"
  assert_contains "$(cat "$out")" "summary: 0 of 1 restarted while idle, 0 already current, 0 deferred, 0 nudged, 1 unreached" \
    "the missing worker result was not included in the summary"
  pass "T13 a dead restart worker cannot hang the parent"
}

# --- T14: result publication after the first probe remains authoritative -----
test_result_published_while_reaping_is_honored() {
  local dir out rc
  dir=$(new_case result-race)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  : > "$dir/fake/slow-relaunch"
  export FM_FAKE_ANSWER_STATUS="$dir/home/state/sm1.status"
  cat > "$dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ -e "$FM_FAKE_DIR/remote-relaunch-start" ] && [ ! -e "$FM_FAKE_DIR/result-race-injected" ]; then
  result=$(find "$FM_HOME/state" -maxdepth 2 -name '0.result' -print -quit)
  if [ -z "$result" ]; then
    result_dir=$(find "$FM_HOME/state" -maxdepth 1 -type d -name '.secondmate-restart.*' -print -quit)
    if [ -n "$result_dir" ]; then
      printf 'restarted: sm1 (claude)\n' > "$result_dir/0.result"
      : > "$FM_FAKE_DIR/result-race-injected"
      printf 'Z\n'
      exit 0
    fi
  fi
fi
exec /bin/ps "$@"
SH
  chmod +x "$dir/fakebin/ps"

  out=$(run_restart "$dir" sm1); rc=$?
  unset FM_FAKE_ANSWER_STATUS

  expect_code 0 "$rc" "a result published while the worker is reaped must remain authoritative"$'\n'"$out"
  assert_contains "$out" "restarted: sm1 (claude)" \
    "the result published during the reap window was replaced with a worker failure"
  assert_not_contains "$out" "exited before publishing" \
    "the parent failed to recheck the worker result after wait"
  pass "T14 a result published during reaping is honored"
}

# --- T15: an already-current mate still restarts, end to end -----------------
# The SSHHIP regression, driven through BOTH real commands rather than either
# one's own idea of the other. The mate's home needs no fast-forward at all, so
# the old instruction-diff classifier left it out of every action set and its
# agent kept running the launch-time wiring it started with. The update pass must
# now name it, and the restart pass must then persist its open records and only
# afterwards replace the agent.
test_already_current_mate_restarts_end_to_end() {
  local dir out restart_line ids rc head_before head_after doorbell_line exit_line
  dir=$(new_case already-current)
  add_repo_backed_mate "$dir" sm1
  arm_answer "$dir" sm1
  head_before=$(git -C "$dir/sm1-home" rev-parse HEAD)

  out=$(run_update_in_case "$dir")

  assert_contains "$out" "secondmate sm1: already current" \
    "the fixture must model a home that needs no advance"
  restart_line=$(printf '%s\n' "$out" | grep '^restart-secondmates:')
  assert_contains "$restart_line" "fm-sm1" \
    "an already-current live second mate must still be named for restart"
  assert_contains "$out" "nudge-secondmates: none" \
    "a mate named for restart must not also be steered"

  ids=${restart_line#restart-secondmates: }
  # shellcheck disable=SC2086
  out=$(run_restart "$dir" $ids); rc=$?

  expect_code 0 "$rc" "the mate named by the update pass did not restart"$'\n'"$out"
  assert_contains "$out" "restarted: sm1" "an already-current mate must actually be replaced"
  assert_contains "$out" "summary: 1 of 1 restarted while idle, 0 already current, 0 deferred, 0 nudged, 0 unreached" \
    "the pass must report the reload it performed"
  # Persist strictly before replace, read off the pane transcript.
  doorbell_line=$(grep -n '^: Firstmate instruction waiting: ' "$dir/fake/literal" | head -1 | cut -d: -f1)
  exit_line=$(grep -n '^/exit$' "$dir/fake/literal" | head -1 | cut -d: -f1)
  [ -n "$doorbell_line" ] || fail "the persist request never reached the already-current mate"
  [ -n "$exit_line" ] || fail "the already-current mate was never stopped, so it was not restarted"
  [ "$doorbell_line" -lt "$exit_line" ] \
    || fail "the agent was stopped before it was asked to persist (persist line $doorbell_line, exit line $exit_line)"
  # Nothing about the home's git state was touched to buy that restart.
  head_after=$(git -C "$dir/sm1-home" rev-parse HEAD)
  [ "$head_after" = "$head_before" ] || fail "the already-current home's checkout moved"
  [ -z "$(git -C "$dir/sm1-home" status --porcelain)" ] \
    || fail "the restart left the mate's home dirty"
  pass "T15 an already-current live mate is named by the update pass and genuinely restarted"
}

# --- T16: an already-current mate that cannot prove a restart stays honest ----
# Same already-current home, a runtime with no recovery-grade state classifier.
# Unconditional restart must not become an unconditional CLAIM of one: the update
# pass routes it to the re-read steer, and the restart pass reports a nudge with
# the agent still running.
test_already_current_unprovable_mate_stays_on_the_nudge_path() {
  local dir out rc restart_line nudge_line before
  dir=$(new_case already-current-unprovable)
  # zellij can never establish "the old agent stopped and the replacement came up".
  add_repo_backed_mate "$dir" sm1 claude zellij
  arm_answer "$dir" sm1
  before=$(cat "$dir/fake/command")

  out=$(run_update_in_case "$dir")

  assert_contains "$out" "secondmate sm1: already current" \
    "the fixture must model a home that needs no advance"
  restart_line=$(printf '%s\n' "$out" | grep '^restart-secondmates:')
  nudge_line=$(printf '%s\n' "$out" | grep '^nudge-secondmates:')
  assert_not_contains "$restart_line" "sm1" \
    "a mate whose restart cannot be proven must stay out of the restart set"
  assert_contains "$nudge_line" "fm-sm1" \
    "a live mate that cannot be restarted must keep the honest re-read steer"

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 3 "$rc" "an unprovable restart must not report success"$'\n'"$out"
  assert_contains "$out" "nudged: sm1:" "the fallback must be reported as a nudge"
  assert_not_contains "$out" "restarted: sm1" "an unprovable mate must never be reported as reloaded"
  [ "$(cat "$dir/fake/command")" = "$before" ] \
    || fail "the unprovable mate's agent was stopped anyway"
  assert_no_grep '^/exit$' "$dir/fake/literal" "nothing may be stopped on the nudge path"
  pass "T16 an already-current mate with an unprovable runtime keeps the honest nudge path"
}

# --- T17: a mate already running its home's instructions is left alone -------
test_current_mate_is_not_restarted() {
  local dir out rc
  dir=$(new_case current)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  start_old_session "$dir" sm1

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 0 "$rc" "an already-current mate is a clean outcome"$'\n'"$out"
  assert_contains "$out" "current: sm1: already running its home's current instructions" \
    "a mate whose session recorded the home's current surface must be reported current"
  assert_contains "$out" "1 already current" "the summary must count the current mate"
  assert_absent "$dir/home/state/sm1.inbox" "a current mate must not be asked to spend its conversation"
  assert_no_grep '^/exit$' "$dir/fake/literal" "a current mate must never be stopped"
  pass "T17 a mate already on its home's instruction surface is reported current and untouched"
}

# advance_mate_bin <case-dir> <id>: land a bin/ change in the mate's home, so a
# session recorded before it is stale.
advance_mate_bin() {
  local home
  home=$(cat "$1/fake/home.fm-$2")
  mkdir -p "$home/bin"
  printf 'echo new\n' > "$home/bin/tool.sh"
  git -C "$home" add bin/tool.sh
  git -C "$home" -c user.name=t -c user.email=t@example.invalid commit -qm "new tool"
}

# --- T18: a stale mate restarts and the replacement is verified --------------
test_stale_unknown_mate_defers() {
  local dir out rc old_pid
  dir=$(new_case stale-unknown)
  add_local_mate "$dir" sm1
  rm -f "$dir/home/state/sm1.busy-state" "$dir/home/state/sm1.busy-gen"
  arm_answer "$dir" sm1
  start_old_session "$dir" sm1
  old_pid=$(cat "$dir/fake/session.fm-sm1")
  advance_mate_bin "$dir" sm1
  out=$(run_restart "$dir" sm1); rc=$?
  expect_code 3 "$rc" "an unknown idle state must defer: $out"
  assert_contains "$out" "deferred: sm1: idle not provable (missing)" "missing busy records must defer"
  assert_contains "$out" "nudged: sm1:" "unknown idle must receive the re-read nudge"
  [ "$(cat "$dir/fake/session.fm-sm1")" = "$old_pid" ] || fail "unknown mate restarted"
  assert_no_grep '^/exit$' "$dir/fake/literal" "unknown mate must not stop"
  pass "T18 stale mate with unknown idle state defers"
}

# arm_busy <case-dir> <id> <busy|idle>: a semantic busy record for the mate.
arm_busy() {
  "$ROOT/bin/fm-busy-event.sh" arm "$1/home/state" "$2" --state "$3" \
    --source claude-hook --event test >/dev/null
}

# --- T19: a provably busy mate is deferred, never restarted ------------------
test_busy_mate_is_deferred() {
  local dir out rc
  dir=$(new_case busy)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  start_old_session "$dir" sm1
  advance_mate_bin "$dir" sm1
  arm_busy "$dir" sm1 busy

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 3 "$rc" "a deferred mate is not a clean reload"$'\n'"$out"
  assert_contains "$out" "deferred: sm1: busy (claude-hook)" "a busy mate must be reported deferred with its source"
  assert_contains "$out" "all 1 mates deferred; 0 received re-read nudges" "the summary must report the busy deferral without claiming a nudge"
  assert_not_contains "$out" "restarted: sm1" "a busy mate must never be restarted"
  assert_no_grep '^/exit$' "$dir/fake/literal" "a busy mate's agent must not be stopped"
  assert_absent "$dir/home/state/sm1.control-relaunch" "no restart transaction may open for a busy mate"
  grep -h '^phase=' "$dir/home/state/pending-replies"/* | grep -q '^phase=resolved$' \
    || fail "the busy mate's persist answer should still be recorded"
  pass "T19 a provably busy mate is deferred after persisting, never restarted"
}

# --- T20: a provably idle mate restarts and is reported as idle --------------
test_mate_rewoken_during_checkpoint_defers() {
  local dir out rc verdict
  for verdict in busy unknown; do
    dir=$(new_case "checkpoint-$verdict")
    add_local_mate "$dir" sm1
    arm_answer "$dir" sm1
    command -v git > "$dir/fake/git-bin"
    printf '%s\n' "$verdict" > "$dir/fake/checkpoint-verdict"
    cat > "$dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "$*" = "-C $(cat "$FM_FAKE_DIR/home.fm-sm1") status --porcelain" ]; then
  if [ "$(cat "$FM_FAKE_DIR/checkpoint-verdict")" = busy ]; then
    "$FM_FAKE_ROOT/bin/fm-busy-event.sh" apply "$FM_HOME/state" sm1 busy \
      --current-gen --source claude-hook --event user-prompt-submit >/dev/null
  else
    rm -f "$FM_HOME/state/sm1.busy-state"
  fi
  : > "$FM_FAKE_DIR/checkpoint-reached"
fi
exec "$(cat "$FM_FAKE_DIR/git-bin")" "$@"
SH
    chmod +x "$dir/fakebin/git"

    out=$(run_restart "$dir" sm1); rc=$?

    expect_code 3 "$rc" "a mate no longer proven idle must defer: $out"
    [ -f "$dir/fake/checkpoint-reached" ] || fail "the initial idle verdict never reached relaunch"
    assert_contains "$out" "deferred: sm1: busy ($verdict " "the stop-boundary verdict must be reported"
    assert_contains "$out" "all 1 mates deferred; 0 received re-read nudges, 0 were unreached" "the refusal must count as deferred"
    assert_not_contains "$out" "restarted: sm1" "a refused relaunch must not claim a restart"
    assert_no_grep '^/exit$' "$dir/fake/literal" "the agent must not receive an exit command"
    assert_no_grep '^(C-c|Escape)$' "$dir/fake/keys" "the agent must not be interrupted"
    assert_absent "$dir/fake/command.fmses:=fm-sm1" "the agent must not be replaced"
    assert_absent "$dir/home/state/sm1.control-relaunch" "the refused transaction must be removed"
    assert_absent "$dir/home/state/sm1.control-relaunch.meta-prior" "the transaction backup must be removed"
  done
  pass "a mate losing its idle proof during checkpoint is deferred without stopping"
}

test_idle_mate_restarts_while_idle() {
  local dir out rc
  dir=$(new_case idle)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  arm_busy "$dir" sm1 idle

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 0 "$rc" "an idle mate should restart"$'\n'"$out"
  assert_contains "$out" "restarted: sm1 (claude) while idle;" "an idle restart must say it was made while idle"
  assert_contains "$out" "1 of 1 restarted while idle" "the summary must separate idle restarts"
  pass "T20 a provably idle mate restarts and is reported as restarted while idle"
}

# settle_idle_after_answer <case-dir> <id> <seconds>: model a mate that writes
# its persist answer mid-turn and ends that turn <seconds> later, the way a live
# claude mate's record goes idle when its own turn-end guard lets the turn end.
settle_idle_after_answer() {
  local dir=$1 id=$2 delay=$3
  cat > "$dir/fake/on-doorbell" <<SH
#!/usr/bin/env bash
[ ! -e "$dir/fake/settle-armed" ] || exit 0
: > "$dir/fake/settle-armed"
( /bin/sleep $delay
  "$ROOT/bin/fm-busy-event.sh" apply "$dir/home/state" $id idle --current-gen \
    --source claude-hook --event stop >/dev/null 2>&1 ) </dev/null >/dev/null 2>&1 &
SH
  chmod +x "$dir/fake/on-doorbell"
}

# --- T20b: a mate still finishing its answering turn restarts inside the window
test_mate_going_idle_inside_settle_window_restarts() {
  local dir out rc old_gen new_gen
  dir=$(new_case settle-idle)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  arm_busy "$dir" sm1 busy
  settle_idle_after_answer "$dir" sm1 3
  old_gen=$(cat "$dir/home/state/sm1.busy-gen")

  out=$(FM_TEST_IDLE_SETTLE=30 run_restart "$dir" sm1); rc=$?

  expect_code 0 "$rc" "a mate that ends its answering turn inside the settle window should restart"$'\n'"$out"
  assert_contains "$out" "restarted: sm1 (claude) while idle;" "the restart must be the proven-idle one"
  assert_not_contains "$out" "deferred: sm1" "a mate proven idle inside the window must not be deferred"
  new_gen=$(cat "$dir/home/state/sm1.busy-gen" 2>/dev/null || true)
  [ -n "$new_gen" ] && [ "$new_gen" != "$old_gen" ] \
    || fail "the replacement claude mate must be re-armed with a fresh busy generation (old=$old_gen new=$new_gen)"
  assert_grep 'source=fm-spawn event=launch-brief' "$dir/home/state/sm1.busy-state" \
    "the replacement's launch brief must seed its record busy"
  pass "T20b a mate still finishing its answering turn restarts once it is proven idle inside the settle window"
}

# The counterfactual for T20b: the same mate with no settle window is read only
# at the answer, while its turn is still running, so it defers. This is what
# proves the answer really did land before the mate went idle.
test_same_mate_without_settle_window_defers() {
  local dir out rc
  dir=$(new_case settle-zero)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  arm_busy "$dir" sm1 busy
  settle_idle_after_answer "$dir" sm1 3

  out=$(FM_TEST_IDLE_SETTLE=0 run_restart "$dir" sm1); rc=$?

  expect_code 3 "$rc" "with no settle window the answering turn is still running"$'\n'"$out"
  assert_contains "$out" "deferred: sm1: busy (claude-hook)" "a single read at the answer must see the turn still running"
  assert_no_grep '^/exit$' "$dir/fake/literal" "a busy mate's agent must not be stopped"
  pass "T20c without a settle window the same mate is read mid-turn and deferred"
}

# --- T20d: a mate busy for the whole window defers exactly as before ---------
test_mate_busy_through_settle_window_defers() {
  local dir out rc started elapsed
  dir=$(new_case settle-busy)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  arm_busy "$dir" sm1 busy
  started=$(date +%s)

  out=$(FM_TEST_IDLE_SETTLE=3 run_restart "$dir" sm1); rc=$?

  elapsed=$(($(date +%s) - started))
  expect_code 3 "$rc" "a mate busy for the whole window is not a clean reload"$'\n'"$out"
  assert_contains "$out" "deferred: sm1: busy (claude-hook), so it was not restarted" "the deferral wording must be unchanged"
  assert_contains "$out" "all 1 mates deferred; 0 received re-read nudges" "the summary must be unchanged"
  assert_no_grep '^/exit$' "$dir/fake/literal" "a busy mate's agent must not be stopped"
  [ "$elapsed" -ge 3 ] || fail "a busy mate must be re-read for the whole settle window before it is deferred (elapsed ${elapsed}s)"
  pass "T20d a mate busy for the whole settle window is deferred with the unchanged wording"
}

# --- T21: a lock collision after the relaunch is unknown, not restarted -------
test_lock_collision_after_relaunch_is_unknown() {
  local dir out rc old_pid
  dir=$(new_case collision)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  start_old_session "$dir" sm1
  old_pid=$(cat "$dir/fake/session.fm-sm1")
  advance_mate_bin "$dir" sm1
  # The old session outlives its endpoint's agent and keeps the home lock, so
  # the replacement's own session start is refused it.
  : > "$dir/fake/old-session-survives"

  out=$(FM_TEST_VERIFY_WAIT=3 run_restart "$dir" sm1); rc=$?

  expect_code 3 "$rc" "a replacement that cannot take the lock is not a reload"$'\n'"$out"
  assert_contains "$out" "unreached: sm1: the restart outcome is unknown" "a collision must be an unknown outcome"
  assert_contains "$out" "lock collision: its home lock is still held by the previous session (pid $old_pid)" \
    "the report must name the collision and the holding session"
  assert_not_contains "$out" "restarted: sm1" "a collided replacement must never be reported restarted"
  pass "T21 a replacement refused the home lock is reported as an unknown outcome naming the collision"
}

test_missing_intended_identity_does_not_restart() {
  local dir out rc
  dir=$(new_case missing-identity)
  setup_remote_case "$dir" sm1 missing-identity
  out=$(run_restart "$dir" sm1); rc=$?
  expect_code 3 "$rc" "unreadable intended identity must prevent restart: $out"
  assert_contains "$out" "intended instruction identity could not be read" "must report missing identity"
  assert_no_grep '^fm-remote-secondmate-control.sh relaunch' "$dir/ssh.log" "missing identity cannot restart"
  assert_contains "$out" "nudged: sm1:" "missing identity falls back to nudge"
  pass "missing intended identity prevents restart"
}

test_unarmed_mate_defers_with_a_nudge() {
  local dir out rc
  dir=$(new_case unarmed)
  add_local_mate "$dir" sm1
  rm "$dir/home/state/sm1.busy-state" "$dir/home/state/sm1.busy-gen"
  arm_answer "$dir" sm1
  out=$(run_restart "$dir" sm1); rc=$?
  expect_code 3 "$rc" "a mate with no busy record must defer: $out"
  assert_contains "$out" "deferred: sm1: idle not provable (missing)" "a missing record must never read idle"
  assert_contains "$out" "nudged: sm1:" "an unarmed mate must receive a re-read nudge"
  assert_contains "$out" "summary: all 1 mates deferred; 1 received re-read nudges, 0 were unreached, and none were reloaded." "the summary must say none were reloaded"
  assert_grep 're-read your AGENTS.md' "$dir/home/state/sm1.inbox/002.msg" "the nudge must actually be delivered"
  assert_no_grep '^/exit$' "$dir/fake/literal" "an unarmed mate must not stop"
  assert_absent "$dir/home/state/sm1.busy-state" "the pass must not arm busy records"
  pass "a mate without a busy record, as on every harness but claude, defers and receives a nudge"
}

test_unarmed_mate_defers_with_a_nudge

test_missing_intended_identity_does_not_restart
test_persist_gates_and_asks_only_for_open_records
test_persist_precedes_restart
test_arrived_answer_precedes_deadline_check
test_answer_between_resolution_and_timeout_wins
test_unprovable_runtime_falls_back
test_unknown_mate_is_accounted_for
test_refused_restart_falls_back_without_claiming_a_reload
test_local_restart_uses_the_home_pin_and_reports_what_ran
test_native_ultra_restart_keeps_local_and_remote_profiles
test_remote_mate_restarts_over_the_transport_hop
test_unreachable_host_is_reported_unknown
test_concurrent_reply_cannot_release_persist_gate
test_persist_waits_are_polled_together
test_post_stop_failure_is_reported_unreached
test_relaunches_do_not_block_persist_polling
test_unpublished_worker_result_is_accounted_for
test_result_published_while_reaping_is_honored
test_already_current_mate_restarts_end_to_end
test_already_current_unprovable_mate_stays_on_the_nudge_path
test_current_mate_is_not_restarted
test_stale_unknown_mate_defers
test_busy_mate_is_deferred
test_idle_mate_restarts_while_idle
test_mate_rewoken_during_checkpoint_defers
test_mate_going_idle_inside_settle_window_restarts
test_same_mate_without_settle_window_defers
test_mate_busy_through_settle_window_defers
test_lock_collision_after_relaunch_is_unknown

echo "# all fm-secondmate-restart tests passed"
