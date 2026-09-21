#!/usr/bin/env bash
set -euo pipefail
set -x
. "$PWD/tests/fixtures.sh"
LAB="$PWD/.test-pool/live"
mkdir -p "$LAB/bin" "$LAB/user" "$LAB/claude"
export HOME="$LAB/user" CLAUDE_CONFIG_DIR="$LAB/claude"
export LAB_LOG="$LAB/launches.jsonl"
export PATH="${PATH%%:*}:$LAB/bin:${PATH#*:}"
export SHELL=/bin/bash TERM=xterm-256color TREEHOUSE_NO_UPDATE_CHECK=1
export FM_SPAWN_NO_GUARD=1
unset TMUX TMUX_PANE
cat > "$LAB/bin/claude" <<'STUB'
#!/usr/bin/env node
const fs = require('fs');
const cp = require('child_process');
const cwd = fs.realpathSync(process.cwd());
const common = cp.execFileSync('git', ['rev-parse', '--path-format=absolute', '--git-common-dir'], {encoding:'utf8'}).trim();
const project = require('path').dirname(common);
const store = JSON.parse(fs.readFileSync(process.env.CLAUDE_CONFIG_DIR+'/.claude.json'));
if (store.projects[cwd]?.hasTrustDialogAccepted !== true || store.projects[project]?.hasTrustDialogAccepted !== true) process.exit(42);
fs.appendFileSync(process.env.LAB_LOG, JSON.stringify({task:process.env.FM_TASK_ID,cwd,project,trust:true})+'\n');
console.log('HARMLESS_CLAUDE_STUB: trust verified; no agent started');
STUB
chmod +x "$LAB/bin/claude"
treehouse --version
git init -q -b main "$LAB/seed"
printf 'scratch upstream\n' > "$LAB/seed/README.md"
git -C "$LAB/seed" add README.md
git -C "$LAB/seed" -c user.name=Tests -c user.email=tests@example.invalid commit -qm initial
git clone -q --bare "$LAB/seed" "$LAB/upstream.git"
tmux -f /dev/null new-session -d -s firstmate
trap 'tmux kill-server || true' EXIT
tmux set-option -g default-shell /bin/bash
tmux set-option -g default-command '/bin/bash --noprofile --norc -i'
for name in primary oas-ops oas-web; do
  home="$LAB/homes/$name"
  fm_test_spawn_home "$home" claude
  printf 'manual\n' > "$home/config/backlog-backend"
  git clone -q "file://$LAB/upstream.git" "$home/projects/app"
  id="live-$name"
  fm_test_spawn_brief "$home" "$id"
  FM_HOME="$home" bash bin/fm-spawn.sh "$id" "$home/projects/app" --scout --harness claude --backend tmux
  for attempt in {1..30}; do
    if test -f "$LAB_LOG" && grep -q "\"task\":\"$id\"" "$LAB_LOG"; then break; fi
    sleep 0.2
  done
  node - "$LAB_LOG" "$id" "$home" <<'ASSERT'
const fs = require('fs');
const [log,id,home] = process.argv.slice(2);
const record = fs.readFileSync(log,'utf8').trim().split('\n').map(JSON.parse).find(x=>x.task===id);
if (!record || record.project !== home+'/projects/app' || !record.trust) throw Error('missing successful launch '+id);
const meta = Object.fromEntries(fs.readFileSync(home+'/state/'+id+'.meta','utf8').trim().split('\n').map(x=>{const i=x.indexOf('=');return [x.slice(0,i),x.slice(i+1)]}));
if (meta.worktree!==record.cwd || meta.harness!=='claude') throw Error('wrong task metadata');
const claim = fs.readFileSync(require('path').dirname(record.cwd)+'/.fm-slot-owner','utf8');
if (!claim.split('\n').includes('task='+id)) throw Error('missing slot claim');
console.log('PASS_OWN_LAUNCH '+JSON.stringify(record));
ASSERT
  tmux capture-pane -p -t "firstmate:fm-$id" -S -100
done

# Fault injection is restricted to allocation in the next real shell pane.
# The three successful acquisitions above used the supplied binary unmodified.
foreign=$(node -e "console.log(JSON.parse(require('fs').readFileSync(process.env.LAB_LOG,'utf8').split('\n')[0]).cwd)")
claim="$(dirname "$foreign")/.fm-slot-owner"
cp "$claim" "$LAB/claim-before"
cp "$CLAUDE_CONFIG_DIR/.claude.json" "$LAB/trust-before"
cp "$LAB_LOG" "$LAB/launches-before"
printf 'treehouse() { printf "INJECTED_FOREIGN_COPY\\n"; cd %q; }\n' "$foreign" > "$LAB/foreign.rc"
tmux set-option -g default-command "/bin/bash --noprofile --rcfile '$LAB/foreign.rc' -i"
home="$LAB/homes/oas-ops"
id=foreign-oas-ops-from-primary
fm_test_spawn_brief "$home" "$id"
set +e
FM_HOME="$home" bash bin/fm-spawn.sh "$id" "$home/projects/app" --scout --harness claude --backend tmux > "$LAB/foreign-output" 2>&1
status=$?
set -e
cat "$LAB/foreign-output"
test "$status" -ne 0
grep -F "not a copy of this home's clone" "$LAB/foreign-output"
test ! -e "$home/state/$id.meta"
cmp "$claim" "$LAB/claim-before"
cmp "$CLAUDE_CONFIG_DIR/.claude.json" "$LAB/trust-before"
cmp "$LAB_LOG" "$LAB/launches-before"
printf 'PASS_FOREIGN_REFUSAL status=%s no-task-record unchanged-slot-claim unchanged-trust no-launch\n' "$status"
cat "$LAB_LOG"
cat "$CLAUDE_CONFIG_DIR/.claude.json"
printf 'PASS: three real spawn launches and foreign-copy refusal; no real agent sessions\n'
