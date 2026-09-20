#!/usr/bin/env bash
# Live driver for the fm-promote hand-off line.
#
# Stands up an isolated firstmate home with a real tmux server, two live agent
# panes, and a real scout task, then runs the REAL bin/fm-promote.sh and pastes
# its printed hand-off command verbatim into a shell, exactly as an operator
# would. Nothing here stubs fm-send: the durable inbox record and the doorbell
# that lands in the worker's pane are produced by the real scripts.
set -u
ROOT=/home/dev/.no-mistakes/worktrees/222d8f0053d8/01M2YGDZ11J9MF1ZDS1H6J6A0B
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-promote-live.XXXXXX"); LAB=$(cd "$LAB" && pwd)
SOCKET="fm-promote-live-$$"
SESSION="promolive"
cleanup() { tmux -L "$SOCKET" kill-server 2>/dev/null || true; rm -rf "$LAB"; }
trap cleanup EXIT

mkdir -p "$LAB/shim"
REAL_TMUX=$(command -v tmux)
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
# A stand-in harness process so the pane is a LIVE agent endpoint rather than a
# bare shell: it draws claude's empty composer glyph and stays in the
# foreground, which is what fm-send's liveness and composer reads look at.
cat > "$LAB/shim/agent-harness" <<'SH'
#!/usr/bin/env bash
printf 'claude (stand-in harness pane for %s)\n' "${FM_PANE_LABEL:-worker}"
printf '\n\xe2\x9d\xaf '
while IFS= read -r line; do
  [ -z "$line" ] || printf '[pane received] %s\n' "$line"
  printf '\n\xe2\x9d\xaf '
done
SH
chmod +x "$LAB/shim/agent-harness"
export PATH="$LAB/shim:$PATH"
export FM_GATE_REFUSE_BYPASS=1
unset FM_TASK_ID NO_MISTAKES_GATE 2>/dev/null || true

HOME_DIR="$LAB/fmhome"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"
ID="rudder-trim"
DECOY="fm-$ID"   # an unrelated task whose id equals the old branch-shaped label

tmux -L "$SOCKET" new-session -d -s "$SESSION" -n "fm-$ID" -x 190 -y 45 -c "$LAB" \
  "FM_PANE_LABEL=$ID exec -a claude bash $LAB/shim/agent-harness"
tmux -L "$SOCKET" new-window -d -t "$SESSION" -n "fm-$DECOY" -c "$LAB" \
  "FM_PANE_LABEL=$DECOY exec -a claude bash $LAB/shim/agent-harness"
sleep 1

printf 'window=%s:fm-%s\nkind=scout\nharness=claude\nworktree=%s\n' "$SESSION" "$ID" "$LAB" > "$HOME_DIR/state/$ID.meta"
printf 'window=%s:fm-%s\nkind=ship\nharness=claude\nworktree=%s\n' "$SESSION" "$DECOY" "$LAB" > "$HOME_DIR/state/$DECOY.meta"

echo "### this firstmate home holds two tasks: the scout '$ID' and an unrelated task '$DECOY'"
ls "$HOME_DIR/state"
echo "### both have a live agent pane:"
tmux -L "$SOCKET" list-windows -t "$SESSION" -F '    #{window_name}' | while read -r w; do
  printf '    %s  agent-state=%s\n' "$w" "$(cd "$ROOT" && . ./bin/fm-backend.sh >/dev/null 2>&1; fm_backend_agent_state tmux "$SESSION:$w" 2>/dev/null)"
done

FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" "$ID" fixture-project --scout >/dev/null 2>&1 \
  || { echo "FATAL: scout brief generation failed"; exit 1; }
python3 - "$HOME_DIR/data/$ID/brief.md" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace('{TASK}','Trim the rudder: the promote hand-off must be runnable as printed.')
s=s.replace('{FIRSTMATE_SPEC}','Investigate why the printed hand-off needed hand repair.')
open(p,'w').write(s)
PY

echo
echo "=== 1. operator promotes the scout ==============================================="
echo "\$ bin/fm-promote.sh $ID --mode direct-PR --yolo off"
OUT=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-promote.sh" "$ID" --mode direct-PR --yolo off 2>&1)
STATUS=$?
printf '%s\n' "$OUT" | grep -v '^●'
[ "$STATUS" -eq 0 ] || { echo "FATAL: promotion exited $STATUS"; exit 1; }

NEXT=$(printf '%s\n' "$OUT" | sed -n 's/^next: //p' | grep 'fm-send\.sh' | head -1)
echo
echo "the hand-off command the operator copies:"
echo "  $NEXT"
case "$NEXT" in
  *"fm-send.sh $ID "*) echo "  -> names the task id '$ID'" ;;
  *) echo "  -> FAIL: does not name the task id '$ID'" ;;
esac

echo
echo "=== 2. operator pastes it verbatim and runs it ==================================="
( cd "$ROOT" && eval "$NEXT" ) 2>&1 | sed 's/^/  /'
echo "  (exit status: ${PIPESTATUS[0]})"

echo
echo "=== 3. where the ship instructions landed ========================================"
echo "durable steering inbox of the promoted task '$ID':"
find "$HOME_DIR/state/$ID.inbox" -maxdepth 1 -type f 2>/dev/null | sort | sed "s|$HOME_DIR|<FM_HOME>|;s/^/  /"
REC=$(find "$HOME_DIR/state/$ID.inbox" -maxdepth 1 -type f 2>/dev/null | sort | head -1)
[ -n "$REC" ] && { echo "  --- recorded steer (head) ---"; head -10 "$REC" | sed 's/^/  /'; }
echo "inbox of the unrelated task '$DECOY':"
if [ -d "$HOME_DIR/state/$DECOY.inbox" ]; then
  find "$HOME_DIR/state/$DECOY.inbox" -type f | sed "s|$HOME_DIR|<FM_HOME>|;s/^/  /"
else
  echo "  (no inbox exists - nothing was delivered here)"
fi

echo
echo "=== 4. what the promoted worker sees in its own pane ============================="
echo "pane $SESSION:fm-$ID:"
tmux -L "$SOCKET" capture-pane -p -t "$SESSION:fm-$ID" | grep -v '^[[:space:]]*$' | sed 's/^/  /'
echo "pane $SESSION:fm-$DECOY (the unrelated task):"
tmux -L "$SOCKET" capture-pane -p -t "$SESSION:fm-$DECOY" | grep -v '^[[:space:]]*$' | sed 's/^/  /'

echo
echo "=== 5. adversarial: the pre-fix label 'fm-$ID' in the same home =================="
echo "\$ bin/fm-send.sh fm-$ID \"...ship instructions...\""
( cd "$ROOT" && FM_HOME="$HOME_DIR" ./bin/fm-send.sh "fm-$ID" "pre-fix hand-off: ship instructions" ) 2>&1 \
  | grep -v '^WARNING: watcher' | sed 's/^/  /'
echo "inbox of the unrelated task '$DECOY' afterwards:"
find "$HOME_DIR/state/$DECOY.inbox" -maxdepth 1 -type f 2>/dev/null | sed "s|$HOME_DIR|<FM_HOME>|;s/^/  /"
echo "pane $SESSION:fm-$DECOY afterwards:"
tmux -L "$SOCKET" capture-pane -p -t "$SESSION:fm-$DECOY" | grep -v '^[[:space:]]*$' | tail -4 | sed 's/^/  /'
echo
echo "(the pre-fix label delivered the promoted task's contract to the WRONG task;"
echo " the shipped hand-off line names the task id and cannot do that.)"
