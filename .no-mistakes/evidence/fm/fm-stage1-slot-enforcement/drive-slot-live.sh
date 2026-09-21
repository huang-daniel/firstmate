#!/usr/bin/env bash
# Live driver for bin/fm-validation-slot.sh. Uses the real no-mistakes CLI and a
# consistent snapshot of the real shared pipeline database (~/.no-mistakes/state.sqlite,
# opened read-only); injected OAS rows go only into the snapshot copy.
set -u
WT=/home/dev/.no-mistakes/worktrees/222d8f0053d8/01M31NR1WE926823DTCX3DYX05
SLOT=$WT/bin/fm-validation-slot.sh
REALNM=$(command -v no-mistakes)
T=$(mktemp -d /tmp/fm-slot-live.XXXX)
trap 'pkill -f "fm-validation-slot.sh _hold" 2>/dev/null; rm -rf "$T"' EXIT
OAS=https://github.com/overheadautomationsolutions/overhead-automation-solutions.git
OAS_SSH=git@github.com:OverheadAutomationSolutions/overhead-automation-solutions
FM=https://github.com/huang-daniel/firstmate.git
hr(){ printf '\n===== %s =====\n' "$*"; }
st(){ echo "--- $1/state/$2.status:"; cat "$1/state/$2.status" 2>/dev/null || echo "(absent)"; }

hr "S1 read against the REAL shared database (read-only, default NM_HOME)"
echo '$ fm-validation-slot.sh read' "$OAS"; env -u NM_HOME bash $SLOT read "$OAS"
echo '$ fm-validation-slot.sh read' "$OAS_SSH"; env -u NM_HOME bash $SLOT read "$OAS_SSH"
echo '$ fm-validation-slot.sh read' "$FM"; env -u NM_HOME bash $SLOT read "$FM"

# Snapshot the real DB (sqlite backup API, source read-only)
mkdir -p $T/nm
python3 - $T/nm/state.sqlite <<'PY'
import sqlite3,pathlib,sys
src=sqlite3.connect((pathlib.Path.home()/'.no-mistakes/state.sqlite').as_uri()+'?mode=ro',uri=True)
dst=sqlite3.connect(sys.argv[1]); src.backup(dst); dst.close()
PY
export NM_HOME=$T/nm
ins(){ python3 - "$NM_HOME/state.sqlite" "$@" <<'PY'
import sqlite3,sys,time
db=sqlite3.connect(sys.argv[1]); now=int(time.time())
rid,repo,branch,status=sys.argv[2:6]
db.execute("INSERT INTO runs(id,repo_id,branch,head_sha,base_sha,status,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?)",(rid,repo,branch,'h','b',status,now,now)); db.commit()
PY
}
mkhome(){ mkdir -p $T/$1/state; printf 'branch=%s\n' "$3" > $T/$1/state/$2.meta; }

hr "S2 admit refuses without writing when the real daemon reports not running (NM_HOME snapshot has no daemon)"
mkhome primary t-down fm/down
FM_HOME=$T/primary bash $SLOT admit t-down "$OAS"; echo "rc=$?"; st $T/primary t-down

# From here: `no-mistakes daemon status` is forwarded to the REAL CLI against the live default daemon
mkdir -p $T/bin; cat > $T/bin/no-mistakes <<SH
#!/usr/bin/env bash
if [ "\$1 \$2" = "daemon status" ]; then exec env -u NM_HOME "$REALNM" daemon status; fi
echo "unexpected no-mistakes \$*" >&2; exit 1
SH
chmod +x $T/bin/no-mistakes; export PATH=$T/bin:$PATH
echo "real daemon: $(no-mistakes daemon status)"

hr "S3 one OAS run active (oas-ops clone row) + 2 firstmate runs active: OAS admit grants 1 of 2"
ins run-oas-1 2fd9ba8e857e oas/feature-1 running
bash $SLOT read "$OAS"
bash $SLOT read "$FM" | head -1
hr "S4 simultaneous admits from two different homes (primary crew vs oas-ops crew): exactly one may grant"
mkhome primary t-prim oas/prim; mkhome oas-ops t-ops oas/ops
(FM_HOME=$T/primary bash $SLOT admit t-prim "$OAS" > $T/a.out 2>&1; echo "rc=$?" >> $T/a.out) &
(FM_HOME=$T/oas-ops bash $SLOT admit t-ops "$OAS_SSH" > $T/b.out 2>&1; echo "rc=$?" >> $T/b.out) &
wait
echo "[primary t-prim]"; cat $T/a.out; echo "[oas-ops t-ops]"; cat $T/b.out
st $T/primary t-prim; st $T/oas-ops t-ops
echo "shared lock present while grant unconsumed: $(ls -d $NM_HOME/.validation-slot.lock 2>/dev/null || echo none)"
GRANTED=$(grep -l '^granted' $T/a.out $T/b.out)
case $GRANTED in *a.out) GH=primary GT=t-prim GB=oas/prim;; *) GH=oas-ops GT=t-ops GB=oas/ops;; esac
echo "granted: $GH/$GT"

hr "S5 while the grant is unconsumed, a third home (oas-web) cannot be admitted"
mkhome oas-web t-web oas/web
FM_HOME=$T/oas-web bash $SLOT admit t-web "$OAS"; echo "rc=$?"; st $T/oas-web t-web

hr "S6 granted run's row appears (fails fast -> already terminal): hold releases; OAS now 2 active? count, third still blocked"
ins run-oas-2 70bbba7d8a04 $GB running
for i in $(seq 1 10); do [ -e $NM_HOME/.validation-slot.lock ] || break; sleep 1; done
echo "lock after row appeared: $(ls -d $NM_HOME/.validation-slot.lock 2>/dev/null || echo released)"
bash $SLOT read "$OAS"
FM_HOME=$T/oas-web bash $SLOT admit t-web "$OAS"; echo "rc=$?  (wait line not duplicated:)"; st $T/oas-web t-web

hr "S7 firstmate-repository run coexists: firstmate admit is independent of the OAS ceiling"
mkhome primary t-fm fm/x
FM_HOME=$T/primary bash $SLOT admit t-fm "$FM" --ceiling 3 --wait-secs 0; echo "rc=$?"

hr "S8 one OAS run ends as ci_monitor_interrupted: slot frees and oas-web is granted; fast-terminal consumption releases hold"
python3 -c "import sqlite3;d=sqlite3.connect('$NM_HOME/state.sqlite');d.execute(\"update runs set status='ci_monitor_interrupted' where id='run-oas-1'\");d.commit()"
FM_HOME=$T/oas-web bash $SLOT admit t-web "$OAS"; echo "rc=$?"; st $T/oas-web t-web
ins run-oas-3 2fd9ba8e857e oas/web failed
for i in $(seq 1 10); do [ -e $NM_HOME/.validation-slot.lock ] || break; sleep 1; done
echo "lock after fast-failed row: $(ls -d $NM_HOME/.validation-slot.lock 2>/dev/null || echo released)"
. $WT/bin/fm-nm-run-lib.sh; for s in ci_monitor_interrupted running failed bogus; do echo "fm_nm_run_status_class $s -> $(fm_nm_run_status_class $s)"; done

hr "S9 primary runs admit for a secondmate task without FM_HOME of the owning home: refused, nothing written"
FM_HOME=$T/primary bash $SLOT admit t-ops "$OAS" --branch oas/ops; echo "rc=$?"; st $T/primary t-ops

hr "S10 lapse: grant never consumed within --wait-secs 3 -> note line, lock released"
mkhome oas-web t-lapse oas/lapse
python3 -c "import sqlite3;d=sqlite3.connect('$NM_HOME/state.sqlite');d.execute(\"update runs set status='completed' where id='run-oas-2'\");d.commit()"
FM_HOME=$T/oas-web bash $SLOT admit t-lapse "$OAS" --wait-secs 3; echo "rc=$?"; sleep 6
st $T/oas-web t-lapse; echo "lock: $(ls -d $NM_HOME/.validation-slot.lock 2>/dev/null || echo released)"
hr "real DB untouched check"; env -u NM_HOME bash $SLOT read "$OAS" | head -1
