#!/usr/bin/env bash
# Live drift guard for gemini's delivery-footer row (bin/fm-test-run.sh's
# live-harness-optin family). The typed-plane mid-turn refusal in
# bin/fm-send.sh classifies a gemini pane busy from its `(esc to cancel, <n>s)`
# status row alone, so this proves against the real installed gemini that the
# row renders in the pane tail during a blocking shell tool call, and that
# the settled pane no longer matches.
# Opt-in because it submits a real prompt; the credential comes from the
# operator's own GEMINI_API_KEY or stored gemini login, never from this guard.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GEMINI_BIN=$(command -v gemini 2>/dev/null || true)
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
LAB=
SOCKET="fm-gemini-signals-$$"
SESSION=gemini-signals
TARGET="$SESSION:gemini"

cleanup() {
  [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -z "$LAB" ] || rm -rf -- "$LAB"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  cleanup
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

fm_live_gate opt-in FM_GEMINI_SIGNALS_LIVE gemini tmux
[ -n "$GEMINI_BIN" ] || fail "gemini is not installed"
GEMINI_VERSION=$("$GEMINI_BIN" --version 2>/dev/null | head -1)

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-gemini-signals.XXXXXX") || fail "could not create the isolated gemini lab"
trap cleanup EXIT
mkdir -p "$LAB/workspace"
git -C "$LAB/workspace" init -q || fail "could not initialize the isolated gemini workspace"
WORKSPACE=$(cd "$LAB/workspace" && pwd -P) || fail "could not resolve the isolated gemini workspace"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -c "$WORKSPACE" \
  || fail "could not start the isolated tmux server"
"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n gemini -c "$WORKSPACE" \
  || fail "could not open the isolated gemini window"

capture() {
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" -S -40 2>/dev/null || true
}

# The same visible tail the typed-plane refusal reads.
tail_is_busy() {
  capture | grep -v '^[[:space:]]*$' | tail -12 | fm_busy_lines_match gemini
}

# The prompt runs a blocking shell tool call, the shape of a worker driving its
# own validation run, then asks for a computed answer (12345+67890=80235) so
# the awaited token never appears in the echoed launch line itself.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  "GEMINI_CLI_TRUST_WORKSPACE=true $GEMINI_BIN -y \"Run the shell command echo \\\$((40000+1111)); sleep 20; echo \\\$((40000+2222)), then add 12345 and 67890 and reply with exactly the sum and nothing else\"" \
  || fail "could not type the gemini launch line"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
  || fail "could not submit the gemini launch line"

busy_seen=0
tool_started=
tool_ended=
for _ in $(seq 1 240); do
  pane=$(capture)
  case "$pane" in *41111*) tool_started=1 ;; esac
  case "$pane" in *42222*) tool_ended=1 ;; esac
  case "$pane" in
    *41111*)
      if [ -z "$tool_ended" ] && printf '%s\n' "$pane" | grep -v '^[[:space:]]*$' | tail -12 | fm_busy_lines_match gemini; then
        busy_seen=$((busy_seen + 1))
      fi
      ;;
  esac
  case "$pane" in *80235*|*80,235*) break ;; esac
  sleep 1
done
[ -n "$tool_started" ] \
  || fail "gemini $GEMINI_VERSION: the shell tool start marker never appeared"
[ -n "$tool_ended" ] \
  || fail "gemini $GEMINI_VERSION: the shell tool end marker never appeared"
[ "$busy_seen" -ge 10 ] \
  || fail "gemini $GEMINI_VERSION: its busy row matched on only $busy_seen one-second samples between the shell tool markers"
pass "gemini $GEMINI_VERSION: the busy row matched on $busy_seen samples during the blocking shell tool call"

case "$(capture)" in
  *80235*|*80,235*) ;;
  *) fail "gemini $GEMINI_VERSION: the worker never answered its launch prompt" ;;
esac
settled=
for _ in $(seq 1 60); do
  tail_is_busy || { settled=1; break; }
  sleep 1
done
[ -n "$settled" ] || fail "gemini $GEMINI_VERSION: the settled pane still matches the busy row"
pass "gemini $GEMINI_VERSION: the settled pane no longer matches the busy row"

"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l "/quit" \
  || fail "could not type the gemini exit command"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
  || fail "could not submit the gemini exit command"

cleanup
trap - EXIT
