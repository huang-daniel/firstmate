#!/usr/bin/env bash
set -euo pipefail
# Run from the assigned worktree. Copy live-launch-driver.sh to .test-pool/live-launch.sh first.
mkdir -p .test-pool/tmp .test-pool/home
bwrap --ro-bind / / --bind "$PWD" "$PWD" --bind "$PWD/.test-pool/tmp" /tmp --ro-bind /tmp/claude-1000/-home-dev--treehouse-firstmate-746777-1-firstmate/14efdcce-4fd7-43cc-9436-3795dab4c58a/scratchpad/th23 /tmp/claude-1000/-home-dev--treehouse-firstmate-746777-1-firstmate/14efdcce-4fd7-43cc-9436-3795dab4c58a/scratchpad/th23 --dev-bind /dev /dev --proc /proc --unshare-pid --die-with-parent env -i PATH="/tmp/claude-1000/-home-dev--treehouse-firstmate-746777-1-firstmate/14efdcce-4fd7-43cc-9436-3795dab4c58a/scratchpad/th23:$PATH" HOME="$PWD/.test-pool/home" TMPDIR="$PWD/.test-pool/tmp" bash .test-pool/live-launch.sh
