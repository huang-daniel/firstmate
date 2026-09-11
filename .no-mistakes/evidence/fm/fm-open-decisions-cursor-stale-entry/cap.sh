set -eu
lab="$PWD/.test-live-phase/home"
printf 'needs-decision [key=api-shape]: choose REST or RPC for the release implementation after the infrastructure freeze lifts, with enough context to decide which option the worker should implement next\n' >> "$lab/state/zz.status"
printf '$ bin/fm-wake-drain.sh (appended long closable row omitted by cap)\n'
FM_HOME="$lab" FM_ROOT_OVERRIDE="$lab" FM_STATE_OVERRIDE="$lab/state" bin/fm-wake-drain.sh
