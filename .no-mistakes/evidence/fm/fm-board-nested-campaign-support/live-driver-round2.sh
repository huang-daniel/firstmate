#!/usr/bin/env bash
# Live driver: nested programme -> campaign -> tasks on huang-daniel/oas-board-lab project 3.
# NEW = fm-board.sh at the target commit (worktree); BASE = fm-board.sh at 32b24f5.
set -u
WT=/home/dev/.no-mistakes/worktrees/222d8f0053d8/01M31N45EVPPNT9H86YPTFKQZ9
S=$(mktemp -d /tmp/nmlive/run.XXXX)
export FM_HOME=$S/home
mkdir -p "$FM_HOME/config" "$FM_HOME/data" "$S/base/bin" "$S/bin"
git -C "$WT" show 32b24f5:bin/fm-board.sh > "$S/base/bin/fm-board.sh"; chmod +x "$S/base/bin/fm-board.sh"
NEW="$WT/bin/fm-board.sh"; BASE="$S/base/bin/fm-board.sh"
REPO=huang-daniel/oas-board-lab; R=https://github.com/$REPO/issues
# gh wrapper that logs every call, so sub-issue reads can be counted
cat > "$S/bin/gh" <<W
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$S/gh.log"
exec /home/dev/.local/bin/gh "\$@"
W
chmod +x "$S/bin/gh"; export FM_BOARD_GH=$S/bin/gh
cat > "$FM_HOME/config/boards" <<C
project = lab
owner = huang-daniel
number = 3
repo = $REPO
processed = Processed
queued = Queued
big-picture-todo = Umbrella Programme
big-picture-in-progress = Umbrella Programme In Progress
big-picture-done = Umbrella Programme Done

project = labalias
owner = huang-daniel
number = 3
repo = $REPO
processed = Processed
queued = Queued
big-picture-todo = Umbrella Programme
big-picture-in-progress = Umbrella Programme In Progress
big-picture-done = Umbrella Programme Done
C
# Pre-existing lab containers are recorded under a third project so this scratch
# home reports them foreign and never moves them.
for n in 1 2 11 15 16 17 20; do printf 'other\t%s/%s\topen\t-\t-\t-\n' "$R" "$n"; done > "$FM_HOME/data/board-decompositions.tsv"
TAG="nm-live-r2 $(date -u +%Y%m%dT%H%M%SZ)"
say(){ printf '\n### %s\n' "$*"; }
run(){ printf '$ %s\n' "$*"; "$@" 2>&1; }
mk(){ gh issue create -R $REPO -t "$1 ($TAG)" -b "Disposable live-validation issue." | tail -1; }
sub(){ local id; id=$(gh api repos/$REPO/issues/${2##*/} --jq .id); gh api -X POST repos/$REPO/issues/${1##*/}/sub_issues -F sub_issue_id=$id >/dev/null && echo "sub-issue ${2##*/} -> ${1##*/}"; }
col(){ for u in "$@"; do n=${u##*/}; gh api graphql -f query='query($n:Int!){repository(owner:"huang-daniel",name:"oas-board-lab"){issue(number:$n){state title projectItems(first:10){nodes{project{number} fieldValueByName(name:"Status"){... on ProjectV2ItemFieldSingleSelectValue{name}}}}}}}' -F n=$n --jq '.data.repository.issue | "#'$n' [\(.state)] \(.title) -> \([.projectItems.nodes[]|select(.project.number==3)|.fieldValueByName.name // "(no status)"] | if length==0 then "(not on board)" else join(",") end)"'; done; }
reads(){ local c; c=$(grep -c 'sub_issues' "$S/gh.log" 2>/dev/null); : > "$S/gh.log"; echo "sub-issue reads this command: ${c:-0}"; }
poll(){ printf '$ %s poll lab\n' "$1"; local s=$NEW; [ "$1" = BASE ] && s=$BASE; "$s" poll lab 2>&1 | grep -F -e "/${P##*/}" -e "/${C##*/}" -e "/${F##*/}" -e "/${U##*/}" -e "/${T1##*/}" -e "/${T2##*/}" -e error || echo "(no lines about this run's cards)"; }

say "setup ($TAG)"
P=$(mk "Programme: nested"); C=$(mk "Campaign: nested"); F=$(mk "Flat programme guard"); F1=$(mk "Flat child one"); F2=$(mk "Flat child two"); U=$(mk "Programme with underived child"); U1=$(mk "Ordinary child once marked decomposed")
echo "P=$P C=$C F=$F F1=$F1 F2=$F2 U=$U U1=$U1"
sub $P $C; sub $F $F1; sub $F $F2; sub $U $U1
for x in $P $C $F $U; do gh project item-add 3 --owner huang-daniel --url $x >/dev/null && echo "added #${x##*/} to project 3"; run $NEW promote lab $x; done
T1=$(run $NEW child-add lab $C "Campaign task one ($TAG)" "Disposable." fm-r2-one | tee /dev/stderr | awk '/^child /{print $4}')
T2=$(run $NEW child-add lab $C "Campaign task two ($TAG)" "Disposable." fm-r2-two | tee /dev/stderr | awk '/^child /{print $4}')
echo "T1=$T1 T2=$T2"
for x in $C $P $F $U1 $U; do run $NEW decomposed lab $x; done
gh issue close -R $REPO ${F1##*/} >/dev/null && echo "closed #${F1##*/}"
gh issue close -R $REPO ${U1##*/} >/dev/null && echo "closed #${U1##*/} (record: done - - -)"
ALL="$P $C $T1 $T2 $F $F1 $F2 $U $U1"
say "columns from issue nodes: BEFORE first poll"; col $ALL
: > "$S/gh.log"
say "poll 1 (nothing started) with NEW"; poll NEW; reads; col $ALL

say "campaign task one starts"; run $NEW mark fm-r2-one in-progress
say "BEFORE (base 32b24f5) poll"; poll BASE; col $P $C
say "AFTER (target f88a81b) poll"; poll NEW; col $P $C

say "every campaign task done; campaign issue left open"; run $NEW mark fm-r2-one done; run $NEW mark fm-r2-two done
say "BEFORE (base 32b24f5) poll"; poll BASE; col $P $C
say "AFTER (target f88a81b) poll"; poll NEW; col $ALL
say "settled: next NEW poll"; poll NEW
say "flat guard: close remaining flat child"; gh issue close -R $REPO ${F2##*/} >/dev/null && echo "closed #${F2##*/}"; poll NEW; col $F
say "foreign: poll labalias over the same board"; : > "$S/gh.log"
"$NEW" poll labalias 2>&1 | grep -F -e "/${P##*/}" -e "/${C##*/}" -e "/${F##*/}" -e "/${U##*/}"; reads
say "decomposition records"; "$NEW" decompositions lab
say "full board status after run (all cards)"; gh project item-list 3 --owner huang-daniel --format json -L 200 | jq -r '.items[] | "#\(.content.number) \(.status // "(no status)")"' | sort -t'#' -k2 -n
echo "scratch: $S"
