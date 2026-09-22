#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
D=$ROOT/.test-tmp/live
mkdir -p "$D/home/state" "$D/home/data/task" "$D/repo" "$D/bin"
export TMUX_TMPDIR="$D"
unset TMUX
trap 'tmux kill-server 2>/dev/null || true' EXIT
export FM_HOME="$D/home" FM_GATE_REFUSE_BYPASS=1
# Separate actual tmux server selected through its dedicated socket directory.
git -C "$D/repo" init -q
git -C "$D/repo" -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -qm initial
head=$(git -C "$D/repo" rev-parse HEAD)
tmux -f /dev/null new-session -d -s validation -n sentinel -x 120 -y 40 'bash --noprofile --norc'
tmux new-window -t validation -n fm-task -c "$D/repo" 'bash --noprofile --norc'
cat > "$FM_HOME/state/task.meta" <<META
window=validation:fm-task
worktree=$D/repo
project=$D/repo
harness=claude
kind=ship
mode=direct-PR
backend=tmux
pr=https://github.com/example/repo/pull/7
pr_head=$head
META
printf 'done: PR ready\n' > "$FM_HOME/state/task.status"
cp "$FM_HOME/state/task.status" "$D/status-before"
echo 'BEFORE: actual tmux windows'
tmux list-windows -t validation -F '#{window_name} #{pane_width}x#{pane_height}'
echo 'GUARD: dirty work must keep terminal'
touch "$D/repo/uncommitted"
if bin/fm-control.sh task stand-down; then exit 10; fi
tmux list-windows -t validation -F '#{window_name}' | grep -x fm-task
rm "$D/repo/uncommitted"
echo 'GUARD: unfinished work must keep terminal'
printf 'working: continuing\n' > "$FM_HOME/state/task.status"
if bin/fm-control.sh task stand-down; then exit 11; fi
tmux list-windows -t validation -F '#{window_name}' | grep -x fm-task
cp "$D/status-before" "$FM_HOME/state/task.status"
echo 'STAND DOWN: finished clean task'
bin/fm-control.sh task stand-down
echo 'AFTER: actual tmux windows'
tmux list-windows -t validation -F '#{window_name}'
! tmux list-windows -t validation -F '#{window_name}' | grep -qx fm-task
cmp "$FM_HOME/state/task.status" "$D/status-before"
test "$(git -C "$D/repo" rev-parse HEAD)" = "$head"
cat "$FM_HOME/state/task.meta"
echo 'REPEAT:'
bin/fm-control.sh task stand-down
echo 'EXIT AFTER STAND DOWN:'
bin/fm-control.sh task exit
