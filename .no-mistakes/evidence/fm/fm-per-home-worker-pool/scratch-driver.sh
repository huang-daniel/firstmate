#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
LAB=$ROOT/.pool-live
EVID=/home/dev/.no-mistakes/evidence/01M331E76FPZNGEM33C3XNZGC7
TH=/tmp/claude-1000/-home-dev--treehouse-firstmate-746777-1-firstmate/14efdcce-4fd7-43cc-9436-3795dab4c58a/scratchpad/th23
export LAB
mkdir -p "$LAB/bin" "$LAB/user" "$LAB/tmp" "$LAB/claude"
cat > "$LAB/bin/tmux" <<'EOF'
#!/bin/bash
exec /usr/bin/tmux -L fm-pool-live-331 -f /dev/null "$@"
EOF
cat > "$LAB/bin/claude" <<'EOF'
#!/bin/bash
printf 'STUB_LAUNCH cwd=%s args=%s\n' "$PWD" "$*" >> "$LAB/launches"
EOF
chmod +x "$LAB/bin/"*
export PATH="$TH:$LAB/bin:$PATH" HOME="$LAB/user" CLAUDE_CONFIG_DIR="$LAB/claude" TMPDIR="$LAB/tmp" SHELL=/bin/bash TREEHOUSE_NO_UPDATE_CHECK=1
unset TMUX HERDR_ENV HERDR_SESSION FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE
export FM_ROOT_OVERRIDE='' FM_SPAWN_NO_GUARD=1
# A real detached 120x40 terminal; no human config or agent executable.
tmux new-session -d -s firstmate -x 120 -y 40
tmux set-option -g default-shell /bin/bash
tmux set-option -g default-command 'bash --noprofile --norc'
trap 'tmux kill-server' EXIT
git init -q -b main "$LAB/seed"
printf 'scratch\n' > "$LAB/seed/README.md"
git -C "$LAB/seed" add README.md
git -C "$LAB/seed" -c user.name=Test -c user.email=test@example.invalid commit -qm initial
git clone -q --bare "$LAB/seed" "$LAB/upstream.git"
for name in primary oas-ops oas-web; do
  export FM_HOME="$LAB/homes/$name"
  mkdir -p "$FM_HOME/"{data,projects,state,config}
  git clone -q "file://$LAB/upstream.git" "$FM_HOME/projects/app"
  id="live331-$name"
  mkdir -p "$FM_HOME/data/$id"
  printf '# Task\n## Captain\x27s intent\nScratch pool validation.\n## Firstmate spec\nNo real agent.\n' > "$FM_HOME/data/$id/brief.md"
  printf '\nCOMMAND: FM_HOME=%s bin/fm-spawn.sh %s %s --scout --harness claude --backend tmux\n' "$FM_HOME" "$id" "$FM_HOME/projects/app"
  "$ROOT/bin/fm-spawn.sh" "$id" "$FM_HOME/projects/app" --scout --harness claude --backend tmux
  cat "$FM_HOME/state/$id.meta"
done
sleep 1
cat "$LAB/launches"
cat "$CLAUDE_CONFIG_DIR/.claude.json"
