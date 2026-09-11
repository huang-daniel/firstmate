set -eu
lab="$PWD/.test-live-phase/baseline"
chmod +x "$lab"/bin/*.sh
mkdir -p "$lab/state"
export FM_STATE_OVERRIDE="$lab/state" FM_ROOT_OVERRIDE="$lab" FM_HOME="$lab"
printf 'needs-decision [key=api-shape]: choose REST\n' > "$lab/state/task.status"
printf '$ base drain: open\n'
"$lab/bin/fm-wake-drain.sh"
printf 'resol' >> "$lab/state/task.status"
printf '\n$ base drain: partial resolution\n'
"$lab/bin/fm-wake-drain.sh"
printf 'ved [key=api-shape]: REST\n' >> "$lab/state/task.status"
printf '\n$ base drain: completed resolution still incorrectly listed\n'
"$lab/bin/fm-wake-drain.sh"
. "$lab/bin/fm-classify-lib.sh"
printf '\n$ authoritative open set (empty)\n'
status_open_decisions "$lab/state/task.status"
