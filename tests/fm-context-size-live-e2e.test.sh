#!/usr/bin/env bash
# Opt-in credentialed Claude live guard for bin/fm-context-size.sh and the
# compaction evidence bin/fm-control.sh's `compact` verb relies on.
#
# The context read and the compaction proof are harness-dependent: both come
# from what Claude Code writes into its own session transcript. This guard
# proves them against the real installed Claude Code: a real turn's usage is
# found through the session id recorded beside a firstmate home lock and read
# as a positive size, and a real `/compact` in that same session appends a
# manual compact_boundary whose recorded post size is smaller than its pre size
# and becomes the reported size. It fails naming the Claude version.
#
# Isolation: the project directory and the firstmate home are throwaway; the
# lock holder is a placeholder process named claude, because only the lock's
# identity is firstmate's own - the transcript under test is Claude's real one.
# Claude keeps its existing authentication, and the transcript it writes for
# the throwaway project is removed on exit. No live fleet home or session is
# touched. Two short prompts are submitted, so the guard is opt-in.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CONTEXT_SIZE_LIVE_E2E claude jq

CONTEXT="$ROOT/bin/fm-context-size.sh"
MODEL=${FM_CONTEXT_SIZE_LIVE_MODEL:-haiku}
VERSION=$(claude --version 2>/dev/null | head -1)
LAB=$(fm_test_tmproot fm-context-size-live)
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
SID=$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]')
[ -n "$SID" ] || SID=$(cat /proc/sys/kernel/random/uuid)
HOLDER=

version_fail() {
  fail "claude $VERSION: $1"
}

cleanup() {
  local f d
  [ -z "$HOLDER" ] || kill "$HOLDER" 2>/dev/null || true
  for f in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/projects/*/"$SID.jsonl"; do
    [ -f "$f" ] || continue
    d=${f%/*}
    rm -f "$f"
    rm -rf "${d:?}/$SID"
    rmdir "$d/memory" "$d" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup EXIT

mkdir -p "$PROJECT" "$HOME_DIR/state"
bash -c 'exec -a claude "$0" 600' "$(command -v sleep)" </dev/null >/dev/null 2>&1 &
HOLDER=$!
printf '%s\n' "$HOLDER" > "$HOME_DIR/state/.lock"
printf '%s\n' "$SID" > "$HOME_DIR/state/.lock-session"

field() {  # <report> <key>
  printf '%s\n' "$1" | sed -n "s/^$2=//p"
}

run_claude() {  # <prompt> <session-flag>
  (cd "$PROJECT" && timeout 300 claude -p "$1" "$2" "$SID" --model "$MODEL" \
    --dangerously-skip-permissions --settings '{"feedbackDrafts":"off"}' </dev/null) >/dev/null 2>&1
}

run_claude 'Reply with the single word ok.' --session-id \
  || version_fail "the first turn could not run"
out=$("$CONTEXT" --home "$HOME_DIR" 2>&1) || version_fail "the context read failed after a real turn: $out"
before=$(field "$out" tokens)
[ "$(field "$out" source)" = usage ] || version_fail "the size did not come from a real turn's usage: $out"
[ "$(field "$out" boundaries)" = 0 ] || version_fail "a fresh session reported a compaction: $out"
[ "$before" -gt 0 ] || version_fail "a real turn reported no context: $out"
[ "$(field "$out" session)" = "$SID" ] || version_fail "the read did not resolve the recorded session: $out"
pass "claude $VERSION: a real turn's context size reads through the home lock ($before tokens)"

run_claude '/compact' --resume || version_fail "/compact could not run in the same session"
out=$("$CONTEXT" --home "$HOME_DIR" 2>&1) || version_fail "the context read failed after /compact: $out"
[ "$(field "$out" boundaries)" = 1 ] || version_fail "/compact wrote no compact_boundary: $out"
[ "$(field "$out" last_boundary_trigger)" = manual ] || version_fail "the boundary is not a manual compaction: $out"
pre=$(field "$out" last_boundary_pre)
post=$(field "$out" last_boundary_post)
case "$pre:$post" in
  *[!0-9:]*|:*|*:) version_fail "the boundary carries no pre and post sizes: $out" ;;
esac
[ "$post" -lt "$pre" ] || version_fail "the boundary's post size $post is not below its pre size $pre: $out"
[ "$(field "$out" tokens)" = "$post" ] || version_fail "the size after /compact is not the boundary's post size: $out"
pass "claude $VERSION: /compact records a manual boundary ($pre -> $post tokens) that becomes the reported size"
