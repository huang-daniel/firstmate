#!/usr/bin/env bash
# Continuation: nested stages on programme #33 / campaign #34 from the same scratch home.
set -u
WT=/home/dev/.no-mistakes/worktrees/222d8f0053d8/01M31N45EVPPNT9H86YPTFKQZ9
S=/tmp/nmlive/run.YZzN; export FM_HOME=$S/home FM_BOARD_GH=$S/bin/gh
NEW="$WT/bin/fm-board.sh"; BASE="$S/base/bin/fm-board.sh"
REPO=huang-daniel/oas-board-lab; R=https://github.com/$REPO/issues
P=$R/33 C=$R/34 TAG="nm-live-r2 20260921T100523Z"
say(){ printf '\n### %s\n' "$*"; }
run(){ printf '$ %s\n' "${*#$WT/bin/}"; "$@" 2>&1; }
col(){ for u in "$@"; do n=${u##*/}; gh api graphql -f query='query($n:Int!){repository(owner:"huang-daniel",name:"oas-board-lab"){issue(number:$n){state title projectItems(first:10){nodes{project{number} fieldValueByName(name:"Status"){... on ProjectV2ItemFieldSingleSelectValue{name}}}}}}}' -F n=$n --jq '.data.repository.issue | "#'$n' [\(.state)] \(.title) -> \([.projectItems.nodes[]|select(.project.number==3)|.fieldValueByName.name // "(no status)"] | if length==0 then "(not on board)" else join(",") end)"'; done; }
poll(){ printf '$ %s poll lab   (lines about #33/#34/tasks only)\n' "$1"; local s=$NEW; [ "$1" = BASE ] && s=$BASE; "$s" poll lab 2>&1 | grep -F -e "/33" -e "/34" -e "/${T1##*/}" -e "/${T2##*/}" -e error || echo "(no lines about these cards)"; }
T1=x T2=x
say "campaign tasks via child-add (fresh task ids)"
T1=$(run $NEW child-add lab $C "Campaign task one ($TAG)" "Disposable." fm-r2n-one | tee /dev/stderr | awk '/^child /{print $4}')
T2=$(run $NEW child-add lab $C "Campaign task two ($TAG)" "Disposable." fm-r2n-two | tee /dev/stderr | awk '/^child /{print $4}')
echo "T1=$T1 T2=$T2"; [ -n "$T1" ] && [ -n "$T2" ] || exit 1
say "columns from issue nodes: BEFORE (tasks carded, nothing started)"; poll NEW; col $P $C $T1 $T2
say "campaign task one starts"; run $NEW mark fm-r2n-one in-progress
say "BEFORE (base 32b24f5) poll"; poll BASE; col $P $C
say "AFTER (target f88a81b) poll"; poll NEW; col $P $C $T1 $T2
say "every campaign task done; campaign issue #34 left open"; run $NEW mark fm-r2n-one done; run $NEW mark fm-r2n-two done
say "BEFORE (base 32b24f5) poll"; poll BASE; col $P $C
say "AFTER (target f88a81b) poll"; poll NEW; col $P $C $T1 $T2
say "settled: next NEW poll"; poll NEW
say "decomposition records"; "$NEW" decompositions lab | grep -e /33 -e /34
