#!/usr/bin/env bash
# Drive a real `fm-teardown.sh` over a task whose busy-state writer lock was
# abandoned by a dead writer. Usage: drive.sh <firstmate-root> <case-name> <lock-mode>
#   lock-mode: abandoned  -> lock dir exists with a very old mtime (dead writer)
#              none       -> no lock at all (control)
set -u
ROOT=$1; CASE=$2; LOCK_MODE=$3
BASE=/tmp/fm-busy-drive/$CASE
rm -rf "$BASE"; mkdir -p "$BASE/state" "$BASE/config" "$BASE/fakebin"

cat > "$BASE/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf 'treehouse %s\n' "\$*" >> "$BASE/treehouse.log"
exit 0
SH
cat > "$BASE/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$BASE/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
cat > "$BASE/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
cat > "$BASE/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$BASE/fakebin/"*

git init -q --bare "$BASE/origin.git"
git -C "$BASE/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$BASE/origin.git" "$BASE/_seed" 2>/dev/null
git -C "$BASE/_seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "origin baseline"
git -C "$BASE/_seed" push -q origin main
rm -rf "$BASE/_seed"
git clone -q "$BASE/origin.git" "$BASE/project"
git -C "$BASE/project" remote set-head origin main 2>/dev/null || true
git -C "$BASE/project" worktree add -q -b fm/task-x1 "$BASE/wt" main
touch "$BASE/state/.last-watcher-beat"

# The task's work is landed (HEAD == origin/main), so teardown is allowed.
GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$BASE/state" task-x1)
cat > "$BASE/state/task-x1.meta" <<META
window=firstmate:fm-task-x1
endpoint_task_id=task-x1
worktree=$BASE/wt
project=$BASE/project
kind=ship
mode=local-only
busy_gen=$GEN
META

LOCK="$BASE/state/task-x1.busy-state.lock"
case "$LOCK_MODE" in
  abandoned) mkdir "$LOCK"; touch -t 200001010000 "$LOCK" ;;
  live) mkdir "$LOCK" ;;   # a writer that is alive right now: mtime is seconds old
  abandoned-darwin-uname)
    mkdir "$LOCK"; touch -t 200001010000 "$LOCK"
    # Simulate a host that reports itself as macOS while carrying a Linux stat:
    # the BSD form then emits filesystem prose instead of an epoch.
    cat > "$BASE/fakebin/uname" <<'SH'
#!/usr/bin/env bash
[ $# -eq 0 ] && { echo Darwin; exit 0; }
exec /usr/bin/uname "$@"
SH
    chmod +x "$BASE/fakebin/uname" ;;
  abandoned-bsd)
    mkdir "$LOCK"; touch -t 200001010000 "$LOCK"
    # Stand in for a macOS host: uname says Darwin and stat speaks the BSD dialect.
    cat > "$BASE/fakebin/uname" <<'SH'
#!/usr/bin/env bash
[ $# -eq 0 ] && { echo Darwin; exit 0; }
exec /usr/bin/uname "$@"
SH
    cat > "$BASE/fakebin/stat" <<'SH'
#!/usr/bin/env bash
# BSD stat: `-f <fmt> <file>` prints the formatted value; `-c` is not a BSD flag.
if [ "${1:-}" = -f ]; then
  fmt=$2; shift 2
  case "$fmt" in %m) exec /usr/bin/stat -c %Y "$@" ;; esac
  echo "stat: bad format" >&2; exit 1
fi
if [ "${1:-}" = -c ]; then echo "stat: illegal option -- c" >&2; exit 1; fi
exec /usr/bin/stat "$@"
SH
    chmod +x "$BASE/fakebin/uname" "$BASE/fakebin/stat" ;;
esac

echo "--- before teardown ---"
ls "$BASE/state" | sed 's/^/  state: /'
echo "  busy record: $(cat "$BASE/state/task-x1.busy-state" 2>/dev/null)"

set +e
FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$BASE/state" FM_CONFIG_OVERRIDE="$BASE/config" \
  PATH="$BASE/fakebin:$PATH" FM_GATE_REFUSE_BYPASS=1 "$ROOT/bin/fm-teardown.sh" task-x1 > "$BASE/stdout" 2> "$BASE/stderr"
RC=$?
set -e
echo "--- teardown exit rc=$RC ---"
echo "--- stdout ---"; cat "$BASE/stdout"
echo "--- stderr ---"; cat "$BASE/stderr"
echo "--- worktree return calls ---"; cat "$BASE/treehouse.log" 2>/dev/null || echo "  (none)"
echo "--- state dir after teardown ---"
leftovers=$(ls -A "$BASE/state" | grep -v '^\.last-watcher-beat$' || true)
if [ -n "$leftovers" ]; then printf '  ORPHANED: %s\n' $leftovers; else echo "  (no task records left)"; fi
exit $RC
