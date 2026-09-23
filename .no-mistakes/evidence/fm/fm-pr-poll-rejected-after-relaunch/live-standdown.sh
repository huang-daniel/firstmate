#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
D=$ROOT/.live-pr-watch
mkdir -p "$D/home/state" "$D/home/data/livewatch" "$D/user" "$D/project"
SOCKET=$D/tmux.sock
cleanup() { /usr/bin/tmux -S "$SOCKET" kill-server 2>/dev/null || true; rm -rf "$D"; }
trap cleanup EXIT
export HOME=$D/user FM_HOME=$D/home FM_GATE_REFUSE_BYPASS=1
unset HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID
export PATH=/usr/bin:/bin
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
 git -C "$D/project" init -q
 git -C "$D/project" -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -qm initial
 git -C "$D/project" worktree add -qb livewatch "$D/wt"
 git init --bare -q "$D/origin.git"
 git -C "$D/project" remote add origin "$D/origin.git"
 git -C "$D/wt" push -q origin livewatch
/usr/bin/tmux -S "$SOCKET" -f /dev/null new-session -d -s lab -n keeper -x 120 -y 40 'bash --noprofile --norc'
/usr/bin/tmux -S "$SOCKET" new-window -t lab -n fm-livewatch -c "$D/wt" 'bash --noprofile --norc'
export TMUX="$SOCKET,$(/usr/bin/tmux -S "$SOCKET" display-message -p '#{pid}'),0"
cat > "$FM_HOME/state/livewatch.meta" <<EOF
window=lab:fm-livewatch
endpoint_task_id=livewatch
worktree=$D/wt
project=$D/project
harness=claude
kind=ship
mode=direct-PR
yolo=off
backend=tmux
model=default
effort=default
EOF
printf 'done [at=%s]: awaiting PR merge\n' "$(date +%s)" > "$FM_HOME/state/livewatch.status"
printf '# Task\n\nLive merge-watch validation.\n' > "$FM_HOME/data/livewatch/brief.md"
"$ROOT/bin/fm-pr-check.sh" livewatch https://github.com/huang-daniel/firstmate/pull/1
. "$ROOT/bin/fm-pr-lib.sh"
check_watch() {
 fm_pr_poll_artifacts_valid "$FM_HOME/state" livewatch "$ROOT/bin/fm-pr-poll.sh"
 fm_pr_metadata_identity_parse "$FM_HOME/state/livewatch.meta"
 printf 'Authenticated merge watch: %s\n' "$FM_PR_META_URL"
}
check_watch
"$ROOT/bin/fm-control.sh" livewatch stand-down
check_watch
"$ROOT/bin/fm-control.sh" livewatch stand-down
check_watch
cat "$FM_HOME/state/livewatch.meta"
printf 'injected=unexpected\n' >> "$FM_HOME/state/livewatch.meta"
if fm_pr_metadata_identity_parse "$FM_HOME/state/livewatch.meta"; then
 echo 'ERROR: malformed trailer accepted'; exit 1
fi
printf 'Malformed trailing metadata rejected.\n'
