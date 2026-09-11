#!/usr/bin/env bash
# Feed the literal status line the generated brief tells the worker to write
# into the real supervision classifier (bin/fm-classify-lib.sh) - the consumer
# that decides declared wait vs possible wedge.
set -u
ROOT=/home/dev/.no-mistakes/worktrees/222d8f0053d8/01M27HAWF6CY9TFRCFQW86P6T0
. "$ROOT/bin/fm-classify-lib.sh"
probe() {  # <line>
  local l=$1
  printf '  %-62s pause=%s terminal=%s captain-relevant=%s\n' "\"$l\"" \
    "$(status_is_paused "$l" && echo yes || echo no)" \
    "$(status_is_terminal_verb "$l" && echo yes || echo no)" \
    "$(status_is_captain_relevant "$l" && echo yes || echo no)"
}
echo "default verb (FM_CLASSIFY_PAUSED_VERB unset):"
probe 'paused: no-mistakes axi run, waiting for the pipeline to return'
probe 'paused: no-mistakes axi respond, resuming the run after the gate'
probe 'working: handed the change to no-mistakes'
probe 'blocked: the run paused on an ask-user gate I cannot answer'
echo
echo "configured verb FM_CLASSIFY_PAUSED_VERB=awaiting:"
export FM_CLASSIFY_PAUSED_VERB=awaiting
probe 'awaiting: no-mistakes axi run, waiting for the pipeline to return'
probe 'paused: no-mistakes axi run, waiting for the pipeline to return'
