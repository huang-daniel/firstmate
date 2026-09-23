#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
D=$ROOT/.test-phase-tmp/live
mkdir -p "$D"/{user,home/state,home/data,home/config,bin}
export HOME=$D/user FM_HOME=$D/home FM_ROOT_OVERRIDE=$ROOT FM_GATE_REFUSE_BYPASS=1 TREEHOUSE_NO_UPDATE_CHECK=1
export TMPDIR=$ROOT/.test-phase-tmp
unset TMUX TMUX_PANE TASKS_AXI_FILE TASKS_AXI_BACKEND FM_TASK_ID
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
printf manual > "$FM_HOME/config/backlog-backend"
REAL_TMUX=$(command -v tmux)
export LIVE_TMUX=$REAL_TMUX LIVE_SOCKET=$D/tmux.sock
cat > "$D/bin/tmux" <<'EOF'
#!/usr/bin/env bash
exec "$LIVE_TMUX" -S "$LIVE_SOCKET" "$@"
EOF
chmod +x "$D/bin/tmux"
export PATH=$D/bin:$PATH
tmux new-session -d -s slotlab -n control
trap 'tmux kill-server 2>/dev/null || true' EXIT
git init -q -b main "$D/project"
git -C "$D/project" commit -q --allow-empty -m initial
cd "$D/project"
slot=$(treehouse get --lease --root "$D/pool" --lease-holder current)
printf 'task=current\nhome=%s\n' "$FM_HOME" > "$(dirname "$slot")/.fm-slot-owner"
for id in stale current; do
cat > "$FM_HOME/state/$id.meta" <<EOF
window=slotlab:fm-$id
endpoint_task_id=$id
worktree=$slot
project=$D/project
kind=scout
backend=tmux
EOF
done
printf valuable > "$slot/sentinel"
tmux new-window -d -t slotlab -n fm-current -c "$slot" 'sleep 120'
printf '\n$ fm-teardown.sh stale --force\n'
set +e
"$ROOT/bin/fm-teardown.sh" stale --force
rc=$?
set -e
[ "$rc" != 0 ]
[ -f "$slot/sentinel" ]
tmux has-session -t slotlab:fm-current
printf 'Verified: stale cleanup refused; claimant endpoint and sentinel survived.\n'
for guard in absent foreign secondmate; do
cp "$(dirname "$slot")/.fm-slot-owner" "$D/claim"
case $guard in
 absent) rm "$(dirname "$slot")/.fm-slot-owner";;
 foreign) mkdir -p "$D/foreign"; printf 'task=current\nhome=%s\n' "$D/foreign" > "$(dirname "$slot")/.fm-slot-owner";;
 secondmate) printf 'home=%s\n' "$slot" >> "$FM_HOME/state/stale.meta";;
esac
printf '\n$ fm-teardown.sh current --force (guard=%s)\n' "$guard"
set +e
"$ROOT/bin/fm-teardown.sh" current --force
rc=$?
set -e
[ "$rc" != 0 ] && [ -f "$slot/sentinel" ]
tmux has-session -t slotlab:fm-current
mv "$D/claim" "$(dirname "$slot")/.fm-slot-owner"
if [ "$guard" = secondmate ]; then sed -i '/^home=/d' "$FM_HOME/state/stale.meta"; fi
printf 'Verified: ambiguous ownership refused without closing claimant or resetting slot.\n'
done
printf '\n$ fm-teardown.sh current --force\n'
"$ROOT/bin/fm-teardown.sh" current --force
[ ! -e "$FM_HOME/state/current.meta" ] && [ -e "$FM_HOME/state/stale.meta" ]
[ ! -e "$slot/sentinel" ]
if tmux has-session -t slotlab:fm-current 2>/dev/null; then exit 1; fi
printf 'Verified: claimant cleaned up; stale record retained; task endpoint closed; slot reset.\n'
treehouse status --json --root "$D/pool"
