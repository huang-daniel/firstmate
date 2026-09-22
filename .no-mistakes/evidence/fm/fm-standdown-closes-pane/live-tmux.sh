#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
D=$ROOT/.test-standdown/live
mkdir -p "$D/bin" "$D/home/state" "$D/home/data/sd" "$D/proj"
export SD_SOCKET="$D/tmux.sock" SD_D="$D"
cat > "$D/bin/tmux" <<'SH'
#!/bin/bash
if [[ $1 == list-windows && -e "$SD_D/unreadable" ]]; then echo 'probe temporarily unavailable' >&2; exit 1; fi
/usr/bin/tmux -S "$SD_SOCKET" "$@"
rc=$?
if [[ $1 == kill-window && -e "$SD_D/inject" && $rc == 0 ]]; then touch "$SD_D/unreadable"; fi
exit "$rc"
SH
chmod +x "$D/bin/tmux"
export PATH="$D/bin:$PATH" FM_HOME="$D/home" FM_GATE_REFUSE_BYPASS=1 FM_CREW_STATE_NO_FORGE=1
unset TMUX HERDR_SESSION HERDR_ENV FM_TASK_ID || true
trap '/usr/bin/tmux -S "$SD_SOCKET" kill-server 2>/dev/null || true' EXIT
git -C "$D/proj" init -q
git -C "$D/proj" -c user.name=test -c user.email=test@example.invalid commit --allow-empty -qm initial
git -C "$D/proj" worktree add -q -b task-sd "$D/wt"
head=$(git -C "$D/wt" rev-parse HEAD)
tmux -f /dev/null new-session -d -s fmlab -n control -x 120 -y 40 'bash --noprofile --norc'
tmux new-window -t fmlab -n fm-sd -c "$D/wt" 'bash --noprofile --norc'
cat > "$D/home/state/sd.meta" <<META
window=fmlab:fm-sd
backend=tmux
kind=ship
mode=direct-PR
harness=claude
worktree=$D/wt
project=$D/proj
pr=https://github.com/example/repo/pull/7
pr_head=$head
META
printf 'done: PR ready\n' > "$D/home/state/sd.status"
cp "$D/home/state/sd.status" "$D/status-before"
touch "$D/home/state/.last-watcher-beat"
run() { echo "+ $*"; "$@"; }
run tmux list-windows -t fmlab -F '#{window_name}'
echo dirty > "$D/wt/untracked"
if run bin/fm-control.sh sd stand-down; then exit 1; fi
tmux list-windows -t fmlab -F '#{window_name}' | grep -x fm-sd
rm "$D/wt/untracked"
run bin/fm-control.sh sd stand-down
run tmux list-windows -t fmlab -F '#{window_name}'
run tmux display-message -p -t fmlab:fm-sd '#{pane_id} #{window_name}'
out=$(run bin/fm-crew-state.sh sd); echo "$out"
[[ $out == *'state: done'* && $out == *'endpoint closed at stand-down'* ]]
run bin/fm-control.sh sd stand-down
run bin/fm-control.sh sd exit
cmp "$D/status-before" "$D/home/state/sd.status"
[[ -f "$D/wt/.git" && -f "$D/home/state/sd.meta" ]]
echo 'PASS: close, sibling survival, finished-state reporting, repeat, exit, and record preservation'
# A mismatched marker must not classify a missing endpoint as intentionally closed.
sed -i 's/endpoint_closed=fmlab:fm-sd/endpoint_closed=fmlab:other/' "$D/home/state/sd.meta"
out=$(run bin/fm-crew-state.sh sd); echo "$out"; [[ $out != *'endpoint closed at stand-down'* ]]
sed -i '/endpoint_closed=/d' "$D/home/state/sd.meta"
tmux new-window -t fmlab -n fm-sd -c "$D/wt" 'bash --noprofile --norc'
touch "$D/inject"
if run bin/fm-control.sh sd stand-down; then exit 1; fi
grep '^endpoint_closed=fmlab:fm-sd$' "$D/home/state/sd.meta"
rm "$D/inject" "$D/unreadable"
run bin/fm-control.sh sd exit
run bin/fm-control.sh sd stand-down
echo 'PASS: successful close proof survives temporarily unreadable inventory'

cat > "$D/home/data/sd/brief.md" <<'BRIEF'
# Task
## Captain's intent
Verify isolated terminal lifecycle.
## Firstmate spec
Use the disposable test terminal only.
BRIEF
cat > "$D/bin/codex" <<'SH'
#!/bin/bash
printf 'launched\n' >> "$SD_D/launched"
SH
cat > "$D/bin/lab-shell" <<SH
#!/bin/bash
export PATH="$D/bin:\$PATH"
exec bash --noprofile --norc -i
SH
chmod +x "$D/bin/codex" "$D/bin/lab-shell"
export SHELL="$D/bin/lab-shell" FM_SPAWN_NO_GUARD=1
tmux set-option -g default-shell "$D/bin/lab-shell"
run bin/fm-spawn.sh sd --relaunch --harness codex
sleep 2
run tmux list-windows -t fmlab -F '#{window_name}'
[[ $(tmux list-windows -t fmlab -F '#{window_name}' | wc -l) == 2 ]]
[[ -s "$D/launched" ]]
! grep -q '^endpoint_closed=' "$D/home/state/sd.meta"
echo 'PASS: existing-session relaunch adds exactly one task window and clears closure proof (inert harness)'
printf 'done: PR ready\n' > "$D/home/state/sd.status"
run bin/fm-control.sh sd stand-down
tmux kill-window -t '=fmlab:=control'
rm "$D/launched"
run bin/fm-spawn.sh sd --relaunch --harness codex
sleep 2
run tmux list-windows -t fmlab -F '#{window_name}'
[[ $(tmux list-windows -t fmlab -F '#{window_name}' | wc -l) == 1 ]]
[[ -s "$D/launched" ]]
! grep -q '^endpoint_closed=' "$D/home/state/sd.meta"
echo 'PASS: missing-session relaunch creates only the task window (inert harness)'
