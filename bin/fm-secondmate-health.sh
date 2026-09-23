#!/usr/bin/env bash
# fm-secondmate-health.sh - read what a second mate's running agent is actually
# on, whether it can be restarted right now, and whether a replacement is healthy.
#
# Usage: fm-secondmate-health.sh record
#        fm-secondmate-health.sh self
#        fm-secondmate-health.sh stale <secondmate-id>
#        fm-secondmate-health.sh idle <secondmate-id>
#        fm-secondmate-health.sh verify <secondmate-id> [--prior-pid <pid>]
#                                       --expect-instr <identity> [--wait <seconds>]
#
# A running agent keeps the instruction surface it launched on (AGENTS.md,
# CLAUDE.md, bin/, .agents/skills/, .claude/, .codex/, .cursor/, .grok/, .omp/,
# .opencode/, .pi/) no matter what later lands in its home, so "the home
# is current" says nothing about the agent. This command is the one owner of the
# record that closes that gap and of every read built on it:
#
#   record  Run by bin/fm-session-start.sh in every home, right after a locked
#           (non-re-emit) start that acquired a different lock pid. Same-pid
#           reruns without evidence stay unknown. Writes state/.session-revision: the lock-holding
#           session pid, the code root it runs from, that root's HEAD commit, and
#           the instruction-surface identity at that commit. The session that
#           holds the home lock is thereby the one that reports its revision.
#           A record for the same pid is preserved on subsequent starts, even
#           after instruction reloads; a different pid writes a fresh record.
#   self    Print this home's (FM_HOME's) running-session report as key=value
#           lines: lock_pid, lock_live (yes|no, the lock-holding pid is a live
#           verified harness), session_pid, session_commit, session_instr (from
#           the record), and head_commit and head_instr (the recorded root's
#           current HEAD; FM_HOME itself when there is no record). The parent
#           calls it with FM_HOME set to a local mate's home, or on a remote
#           mate's host through bin/fm-on.sh; nothing here writes.
#
#   The next three run in the PARENT home and need an explicit FM_HOME there.
#   stale   One line: `current <id> commit=<c> ...`, `stale <id> launched=<c>
#           head=<c> changed=<paths> ...`, or `unknown <id>: <reason> ...`. Every
#           line ends with `lock_pid=<pid>` and `head_instr=<identity>` so a
#           restart pass can capture the prior lock holder and the intended
#           revision in the same read. `unknown` means the running agent's
#           launch revision is not provable (no live lock holder, no record from
#           it, an unreadable or remote host without this command); callers treat
#           it like stale, because a restart is still persist-gated and idle-gated.
#   idle    `<busy|idle|unknown|dead> <source>` from the mate's semantic
#           busy-state record, classified by bin/fm-busy-lib.sh. bin/fm-spawn.sh
#           arms that record for a local claude mate, so it reads `idle
#           claude-hook` once its turn has ended at the home's own turn-end
#           guard. Every other secondmate harness keeps no record and reads
#           `unknown missing` (Herdr can still prove busy, never idle), except
#           grok, which bin/fm-busy-lib.sh classifies from its rendered tail.
#           A remote mate's record would live on its host, so it always reads
#           `unknown remote-idle-not-provable` here.
#   verify  After a relaunch, poll up to --wait seconds (FM_SECONDMATE_VERIFY_WAIT,
#           default 180; poll FM_SECONDMATE_VERIFY_POLL, default 5) until the
#           replacement is proven healthy: its endpoint's agent is alive, the
#           home lock is held by a live harness pid other than --prior-pid, that
#           pid's own record reports the revision, and its instruction identity
#           equals the required nonempty --expect-instr. Prints `verified <id> pid=<p>
#           commit=<c>` and exits 0, or `unknown <id>: <last reason>` and exits 3.
#           A live --prior-pid still holding the lock is named as a lock
#           collision: the replacement cannot take the lock and would run
#           read-only, leaving the home without a working mate.
#           Each probe and sleep is bounded by the remaining wait budget.
#           A zero budget returns unknown without probing.
#
# Exit status: 0 on a completed read (and a verified replacement); 3 an
# unverified replacement; 1 an unusable input or home; 2 invalid use.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

FM_HEALTH_INSTR_PATHS="AGENTS.md bin .agents/skills CLAUDE.md .claude .codex .cursor .grok .omp .opencode .pi"

# Print <root>'s instruction-surface identity at <rev> as
# comma-separated `<path>:<id>` entries (`none` for an absent path).
instr_identity() {  # <root> [<rev>]
  local root=$1 rev=${2:-HEAD} p id out=""
  git -C "$root" rev-parse --verify -q "$rev^{commit}" >/dev/null 2>&1 || return 1
  for p in $FM_HEALTH_INSTR_PATHS; do
    id=$(git -C "$root" rev-parse -q --verify "$rev:$p" 2>/dev/null) || id=none
    out="$out${out:+,}$p:$id"
  done
  printf '%s' "$out"
}

# Comma list of the paths whose identity differs between two identities.
instr_changed() {  # <identity-a> <identity-b>
  local a=$1 b=$2 p ida idb out=""
  for p in $FM_HEALTH_INSTR_PATHS; do
    ida=$(printf '%s\n' "$a" | tr ',' '\n' | sed -n "s|^$p:||p")
    idb=$(printf '%s\n' "$b" | tr ',' '\n' | sed -n "s|^$p:||p")
    [ "$ida" = "$idb" ] || out="$out${out:+,}$p"
  done
  printf '%s' "${out:-none}"
}

record_field() {  # <file> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1
}

own_state() {
  FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
  STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
}

cmd_record() {
  local pid root commit instr tmp
  own_state
  [ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing" >&2; return 1; }
  pid=$(sed -n '1p' "$STATE/.lock" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) echo "error: this home's session lock names no pid; nothing to record" >&2; return 1 ;; esac
  if [ -f "$STATE/.session-revision" ] && [ ! -L "$STATE/.session-revision" ] \
    && [ "$(record_field "$STATE/.session-revision" pid)" = "$pid" ]; then
    return 0
  fi
  root=$(cd "$FM_ROOT" 2>/dev/null && pwd -P) || return 1
  commit=$(git -C "$root" rev-parse --verify -q HEAD 2>/dev/null) || commit=""
  instr=$(instr_identity "$root" 2>/dev/null) || instr=""
  tmp=$(mktemp "$STATE/.session-revision.XXXXXX") || return 1
  if {
    echo v1
    echo "pid=$pid"
    echo "root=$root"
    echo "commit=$commit"
    echo "instr=$instr"
    echo "at=$(date +%s)"
  } > "$tmp" && mv -f "$tmp" "$STATE/.session-revision"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

cmd_self() {
  local rec lock_pid lock_live=no session_pid="" session_commit="" session_instr="" root
  own_state
  [ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing" >&2; return 1; }
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$SCRIPT_DIR/fm-session-lock-lib.sh"
  lock_pid=""
  if [ -e "$STATE/.lock" ] || [ -L "$STATE/.lock" ]; then
    lock_pid=$(sed -n '1p' "$STATE/.lock" 2>/dev/null) || return 1
    case "$lock_pid" in ''|*[!0-9]*) return 1 ;; esac
  fi
  if [ -n "$lock_pid" ] && fm_harness_pid_alive "$lock_pid"; then
    lock_live=yes
  fi
  rec="$STATE/.session-revision"
  root=$FM_HOME
  if [ -f "$rec" ] && [ ! -L "$rec" ]; then
    session_pid=$(record_field "$rec" pid)
    session_commit=$(record_field "$rec" commit)
    session_instr=$(record_field "$rec" instr)
    [ -z "$(record_field "$rec" root)" ] || root=$(record_field "$rec" root)
  fi
  echo "lock_pid=$lock_pid"
  echo "lock_live=$lock_live"
  echo "session_pid=$session_pid"
  echo "session_commit=$session_commit"
  echo "session_instr=$session_instr"
  echo "head_commit=$(git -C "$root" rev-parse --verify -q HEAD 2>/dev/null || true)"
  echo "head_instr=$(instr_identity "$root" 2>/dev/null || true)"
}

# --- parent-side reads -------------------------------------------------------

parent_state() {
  if [ -z "${FM_HOME:-}" ]; then
    echo "error: FM_HOME is not set; fm-secondmate-health refuses to resolve second mates without an explicit firstmate home" >&2
    exit 1
  fi
  STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
  [ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing" >&2; exit 1; }
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh"
}

mate_meta() {  # <id> -> sets META, MATE_HOME, MATE_REMOTE
  local id=$1
  META="$STATE/$id.meta"
  if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_meta_get "$META" kind)" != secondmate ]; then
    echo "error: no second mate record for '$id' in this home" >&2
    exit 1
  fi
  MATE_HOME=$(fm_meta_get "$META" home)
  MATE_REMOTE=$(fm_meta_get "$META" remote_host)
}

# The mate's own self report, from its home here or over its host transport.
mate_self() {  # <id>
  if [ -n "$MATE_REMOTE" ]; then
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-on.sh" "$1" fm-secondmate-health.sh self < /dev/null 2>/dev/null
  else
    [ -n "$MATE_HOME" ] && [ -d "$MATE_HOME" ] || return 1
    FM_HOME="$MATE_HOME" FM_STATE_OVERRIDE='' FM_ROOT_OVERRIDE='' \
      "$SCRIPT_DIR/fm-secondmate-health.sh" self 2>/dev/null
  fi
}

self_field() {  # <report> <key>
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | tail -1
}

cmd_stale() {
  local id=$1 report lock_pid lock_live session_pid session_commit session_instr head_commit head_instr tail
  parent_state
  mate_meta "$id"
  if ! report=$(mate_self "$id") || [ -z "$report" ]; then
    echo "unknown $id: its home's running-session report could not be read${MATE_REMOTE:+ from $MATE_REMOTE} lock_pid= head_instr="
    return 0
  fi
  lock_pid=$(self_field "$report" lock_pid)
  lock_live=$(self_field "$report" lock_live)
  session_pid=$(self_field "$report" session_pid)
  session_commit=$(self_field "$report" session_commit)
  session_instr=$(self_field "$report" session_instr)
  head_commit=$(self_field "$report" head_commit)
  head_instr=$(self_field "$report" head_instr)
  tail="lock_pid=$lock_pid head_instr=$head_instr"
  if [ "$lock_live" != yes ]; then
    echo "unknown $id: no live session holds its home lock, so the running agent's revision is not recorded $tail"
  elif [ "$session_pid" != "$lock_pid" ] || [ -z "$session_instr" ]; then
    echo "unknown $id: the live session (pid $lock_pid) has not recorded the revision it started on $tail"
  elif [ -z "$head_instr" ]; then
    echo "unknown $id: its home's current commit could not be read $tail"
  elif [ "$session_instr" = "$head_instr" ]; then
    echo "current $id commit=${session_commit:-unknown} head=$head_commit $tail"
  else
    echo "stale $id launched=${session_commit:-unknown} head=$head_commit changed=$(instr_changed "$session_instr" "$head_instr") $tail"
  fi
}

cmd_idle() {
  local id=$1 backend target harness
  parent_state
  mate_meta "$id"
  if [ -n "$MATE_REMOTE" ]; then
    echo "unknown remote-idle-not-provable"
    return 0
  fi
  # shellcheck source=bin/fm-busy-lib.sh
  . "$SCRIPT_DIR/fm-busy-lib.sh"
  backend=$(fm_backend_of_meta "$META")
  target=$(fm_backend_target_of_meta "$META")
  harness=$(fm_meta_get "$META" harness)
  fm_busy_classify_live "$backend" "$target" "$harness" "$id" "$STATE"
  echo
}

agent_state_of() {  # <id>
  local out
  if [ -n "$MATE_REMOTE" ]; then
    out=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-on.sh" "$1" fm-remote-secondmate-control.sh state "$1" < /dev/null 2>/dev/null) \
      || { printf unreadable; return 0; }
    printf '%s' "$(printf '%s\n' "$out" | tail -1)"
    return 0
  fi
  fm_backend_validate_task_endpoint "$META" "$1" >/dev/null 2>&1 || { printf unreadable; return 0; }
  fm_backend_agent_state "$FM_BACKEND_VALIDATED_BACKEND" "$FM_BACKEND_VALIDATED_TARGET" 2>/dev/null || printf unreadable
}

verify_probe() {
  local remaining
  remaining=$((deadline - $(date +%s)))
  [ "$remaining" -gt 0 ] || return 124
  fm_run_timed "$remaining" "$SCRIPT_DIR/fm-secondmate-health.sh" _verify-probe "$1" "$2"
}

cmd_verify() {
  local id=$1 prior="" expect="" wait=${FM_SECONDMATE_VERIFY_WAIT:-180} poll=${FM_SECONDMATE_VERIFY_POLL:-5}
  local deadline reason state report lock_pid lock_live session_pid session_commit session_instr remaining probe_rc
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --prior-pid) prior=${2-}; shift 2 ;;
      --expect-instr) expect=${2-}; shift 2 ;;
      --wait) wait=${2-}; shift 2 ;;
      *) echo "error: unexpected argument '$1'" >&2; exit 2 ;;
    esac
  done
  case "$wait" in ''|*[!0-9]*) echo "error: --wait must be a non-negative integer" >&2; exit 2 ;; esac
  case "$poll" in ''|*[!0-9.]*) poll=5 ;; esac
  if [ -z "$expect" ]; then
    echo "unknown $id: the intended instruction identity is missing"
    return 3
  fi
  parent_state
  mate_meta "$id"
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$SCRIPT_DIR/fm-timeout-lib.sh"
  deadline=$(($(date +%s) + wait))
  reason=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    state=$(verify_probe agent "$id")
    probe_rc=$?
    if [ "$probe_rc" -eq 124 ]; then
      reason="${reason:+last observation: $reason; }agent-state probe timed out"
      break
    elif [ "$probe_rc" -ne 0 ] || [ "$state" != alive ]; then
      reason="its endpoint reads '$state' rather than a running agent"
    else
      report=$(verify_probe self "$id")
      probe_rc=$?
      if [ "$probe_rc" -eq 124 ]; then
        reason="${reason:+last observation: $reason; }self-report probe timed out"
        break
      elif [ "$probe_rc" -ne 0 ] || [ -z "$report" ]; then
        reason="its home's running-session report could not be read${MATE_REMOTE:+ from $MATE_REMOTE (that host may predate this check)}"
      else
        lock_pid=$(self_field "$report" lock_pid)
        lock_live=$(self_field "$report" lock_live)
        session_pid=$(self_field "$report" session_pid)
        session_commit=$(self_field "$report" session_commit)
        session_instr=$(self_field "$report" session_instr)
        if [ "$lock_live" != yes ]; then
          reason="no live session has taken its home lock"
        elif [ -n "$prior" ] && [ "$lock_pid" = "$prior" ]; then
          reason="lock collision: its home lock is still held by the previous session (pid $prior), so the replacement cannot take it and would run read-only"
        elif [ "$session_pid" != "$lock_pid" ] || [ -z "$session_instr" ]; then
          reason="the session holding its home lock (pid $lock_pid) has not reported its revision"
        elif [ "$session_instr" != "$expect" ]; then
          reason="the replacement reports revision ${session_commit:-unknown}, whose instruction surface differs from the intended one ($(instr_changed "$session_instr" "$expect"))"
        else
          echo "verified $id pid=$lock_pid commit=${session_commit:-unknown}"
          return 0
        fi
      fi
    fi
    remaining=$((deadline - $(date +%s)))
    [ "$remaining" -gt 0 ] || break
    sleep "$(awk -v poll="$poll" -v remaining="$remaining" 'BEGIN { print poll < remaining ? poll : remaining }')"
  done
  echo "unknown $id: ${reason:-verification budget exhausted}"
  return 3
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  _verify-probe)
    [ "$#" -eq 3 ] || exit 2
    case "$2" in agent|self) ;; *) exit 2 ;; esac
    case "$3" in ''|*[!A-Za-z0-9._-]*) exit 2 ;; esac
    parent_state
    mate_meta "$3"
    case "$2" in
      agent) agent_state_of "$3" ;;
      self) mate_self "$3" ;;
    esac
    ;;
  record) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; cmd_record ;;
  self) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; cmd_self ;;
  stale|idle|verify)
    verb=$1
    [ "$#" -ge 2 ] || { usage >&2; exit 2; }
    id=${2#fm-}
    case "$id" in ''|*[!A-Za-z0-9._-]*) echo "error: invalid second mate id: $2" >&2; exit 2 ;; esac
    shift 2
    case "$verb" in
      stale) [ "$#" -eq 0 ] || { usage >&2; exit 2; }; cmd_stale "$id" ;;
      idle) [ "$#" -eq 0 ] || { usage >&2; exit 2; }; cmd_idle "$id" ;;
      verify) cmd_verify "$id" "$@" ;;
    esac
    ;;
  *) usage >&2; exit 2 ;;
esac
