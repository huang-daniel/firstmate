#!/usr/bin/env bash
set -euo pipefail
repo=$PWD
lab=$repo/.test-live-phase/home
mkdir -p "$lab/state"
export FM_HOME="$lab" FM_ROOT_OVERRIDE="$lab" FM_STATE_OVERRIDE="$lab/state"
state=$lab/state
. "$repo/bin/fm-classify-lib.sh"
drain() { printf '\n$ bin/fm-wake-drain.sh (%s)\n' "$1"; "$repo/bin/fm-wake-drain.sh"; }
printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task.status"
drain 'open decision'
printf 'resol' >> "$state/task.status"
drain 'closing line split inside verb'
printf 'ved [key=api-shape]: REST selected\n' >> "$state/task.status"
drain 'closing line complete'
[ -z "$(status_open_decisions "$state/task.status")" ]
[ -z "$(status_open_decisions_incremental "$state/task.status")" ]
printf 'needs-decision: ask-user findings=F1,F2 [key=nm-run-review]\n' >> "$state/task.status"
drain 'trailing token exposes default row key'
printf 'resolved [key=default]: accepted fix\n' >> "$state/task.status"
drain 'default key resolved through status protocol'
printf 'note: the captain says use p' >> "$state/task.status"
. "$repo/bin/fm-wake-lib.sh"
fm_wake_append signal task.status 'signal: task.status'
drain 'queued signal during partial note'
printf '\n$ fm_wake_latest_event (partial retained by existing interface)\n'
fm_wake_latest_event "$state/task.status" 0
printf 'lan B\n' >> "$state/task.status"
fm_wake_append signal task.status 'signal: task.status'
drain 'queued signal after complete note'
drain 'repeat drain must not repeat note'
printf 'blocked [key=pending-reply-abcdef]: pending-reply-missed: waiting for answer\n' > "$state/a.status"
drain 'reserved namespace only'
for i in $(seq -w 1 24); do
 printf 'blocked [key=pending-reply-abcdef%s]: pending-reply-missed: waiting for the worker to reply to the release question with sufficient information to decide which approach to use and proceed safely\n' "$i" > "$state/a$i.status"
done
printf 'needs-decision [key=api-shape]: choose REST or RPC\n' > "$state/zz.status"
drain 'closable row omitted by byte cap must retain hint'
printf 'needs-decision [key=api-shape]: choose REST or RPC for the release implementation after the infrastructure freeze lifts, with enough context to decide which option the worker should implement next\n' > "$state/zz.status"
drain 'long closable row exceeds remaining budget'
printf '\n$ fm_wake_latest_event on an unterminated note (returned event state)\n'
printf 'note: unfinished current event' > "$state/latest.status"
fm_wake_latest_event "$state/latest.status" 0
printf '%s\n' "$FM_WAKE_EVENT_LINE"
[ "$FM_WAKE_EVENT_LINE" = 'note: unfinished current event' ]
