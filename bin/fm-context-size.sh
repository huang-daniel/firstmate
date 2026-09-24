#!/usr/bin/env bash
# fm-context-size.sh - read-only: how large is the conversation context of the
# Claude session that holds a firstmate home's session lock?
#
# Usage: fm-context-size.sh [--home <firstmate-home>]
#
# <firstmate-home> defaults to FM_HOME. Run with no argument from a primary to
# read that primary's own session; bin/fm-control.sh's `compact` verb passes a
# second mate's home to read that mate's session. Nothing here writes, types,
# or schedules anything: there is no reminder loop and no timer.
#
# The source is structured, never a rendered pane:
#   1. The session. Line 1 of <home>/state/.lock names the lock-holding
#      session's anchor pid (bin/fm-lock.sh), which must be a live Claude
#      process. Its conversation id comes from <home>/state/.lock-session (the
#      trusted id bin/fm-lock.sh records beside the lock) and from Claude's own
#      per-process record <claude-dir>/sessions/<pid>.json. Either one names
#      it; when both exist they must agree.
#   2. The transcript. Exactly one <claude-dir>/projects/*/<session-id>.jsonl.
#      <claude-dir> is CLAUDE_CONFIG_DIR when set, else ~/.claude.
#   3. The size. The latest main-chain assistant turn's reported usage
#      (input + cache creation + cache read + output tokens), taken after the
#      transcript's last `compact_boundary` entry. When no assistant turn has
#      followed that boundary yet, the boundary's own recorded postTokens is the
#      size. API-error and synthetic turns carry no real usage and are skipped;
#      a partially written last line is ignored rather than failing the read.
#
# Output on success, one key=value per line, exit 0:
#   tokens=<n>                  current context size
#   source=usage|compact-boundary
#   boundaries=<n>              compact_boundary entries in the transcript
#   last_boundary_trigger=<manual|auto|>
#   last_boundary_pre=<n|>      that boundary's recorded preTokens
#   last_boundary_post=<n|>     that boundary's recorded postTokens
#   session=<session-id>
#   lock_pid=<pid>
#   transcript=<path>
#
# Anything that cannot be established - no live Claude lock holder, no session
# id, disagreeing ids, zero or several transcripts, no usable usage record, or
# jq missing - prints `error: <reason>` on stderr, nothing on stdout, and exits
# 1. Callers treat that as "size unknown" and never as small.
# Exit 2 is invalid use.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

HOME_DIR=${FM_HOME:-}
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --home)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "error: --home requires a value" >&2; exit 2; }
      HOME_DIR=$2
      shift 2
      ;;
    *) echo "error: unexpected argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

fail() {
  echo "error: $1" >&2
  exit 1
}

[ -n "$HOME_DIR" ] || fail "no firstmate home: set FM_HOME or pass --home"
[ -d "$HOME_DIR/state" ] || fail "'$HOME_DIR' has no state directory"
command -v jq >/dev/null 2>&1 || fail "jq is not installed, so the session transcript cannot be read"

# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

STATE_DIR="$HOME_DIR/state"
lock_pid=$(sed -n '1p' "$STATE_DIR/.lock" 2>/dev/null || true)
case "$lock_pid" in
  ''|*[!0-9]*) fail "no session holds the home lock in '$HOME_DIR'" ;;
esac
comm=$(ps -o comm= -p "$lock_pid" 2>/dev/null) || fail "the lock-holding session (pid $lock_pid) is not running"
args=$(ps -o args= -p "$lock_pid" 2>/dev/null || true)
fm_harness_process_matches "$comm" "$args" \
  || fail "the lock-holding process (pid $lock_pid) is not a verified harness session"
[ "${FM_HARNESS_IS_CLAUDE:-0}" -eq 1 ] \
  || fail "the lock-holding session (pid $lock_pid) is not Claude, whose transcript is the only verified context-size source"

CLAUDE_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
lock_sid=$(fm_session_lock_recorded_session_id "$STATE_DIR" 2>/dev/null || true)
proc_sid=
proc_record="$CLAUDE_DIR/sessions/$lock_pid.json"
if [ -f "$proc_record" ] && [ ! -L "$proc_record" ]; then
  proc_sid=$(jq -r '.sessionId // empty' "$proc_record" 2>/dev/null || true)
fi
if [ -n "$lock_sid" ] && [ -n "$proc_sid" ] && [ "$lock_sid" != "$proc_sid" ]; then
  fail "the home lock records session $lock_sid but Claude records $proc_sid for pid $lock_pid"
fi
sid=${lock_sid:-$proc_sid}
[ -n "$sid" ] || fail "the lock-holding session (pid $lock_pid) has no recorded conversation id"
case "$sid" in
  *[!A-Za-z0-9-]*) fail "the recorded conversation id '$sid' is not a session id" ;;
esac

transcript=
count=0
for candidate in "$CLAUDE_DIR"/projects/*/"$sid.jsonl"; do
  [ -f "$candidate" ] && [ ! -L "$candidate" ] || continue
  transcript=$candidate
  count=$((count + 1))
done
[ "$count" -eq 1 ] || fail "expected one transcript for session $sid under $CLAUDE_DIR/projects, found $count"

# One tolerant pass: fromjson? skips a line still being written.
read_out=$(jq -nrR '
  reduce (inputs | fromjson? | select(type == "object")) as $e
    ({tokens: null, source: "", boundaries: 0, trigger: "", pre: null, post: null};
     if $e.type == "system" and $e.subtype == "compact_boundary" then
       .boundaries += 1
       | .trigger = ($e.compactMetadata.trigger // "")
       | .pre = ($e.compactMetadata.preTokens // null)
       | .post = ($e.compactMetadata.postTokens // null)
       | .tokens = .post
       | .source = (if .post == null then "" else "compact-boundary" end)
     elif $e.type == "assistant"
          and ($e.isSidechain != true)
          and ($e.isApiErrorMessage != true)
          and ($e.message.model != "<synthetic>")
          and (($e.message.usage | type) == "object") then
       .tokens = (($e.message.usage.input_tokens // 0)
                  + ($e.message.usage.cache_creation_input_tokens // 0)
                  + ($e.message.usage.cache_read_input_tokens // 0)
                  + ($e.message.usage.output_tokens // 0))
       | .source = "usage"
     else . end)
  | [(.tokens // "" | tostring), .source, (.boundaries | tostring), .trigger,
     (.pre // "" | tostring), (.post // "" | tostring)]
  | join("\t")' < "$transcript" 2>/dev/null) || fail "the transcript $transcript could not be read"

IFS=$'\t' read -r tokens source boundaries trigger pre post <<EOF
$read_out
EOF
case "$tokens" in
  ''|*[!0-9]*) fail "the transcript $transcript holds no usable context-size record yet" ;;
esac

printf 'tokens=%s\n' "$tokens"
printf 'source=%s\n' "$source"
printf 'boundaries=%s\n' "$boundaries"
printf 'last_boundary_trigger=%s\n' "$trigger"
printf 'last_boundary_pre=%s\n' "$pre"
printf 'last_boundary_post=%s\n' "$post"
printf 'session=%s\n' "$sid"
printf 'lock_pid=%s\n' "$lock_pid"
printf 'transcript=%s\n' "$transcript"
