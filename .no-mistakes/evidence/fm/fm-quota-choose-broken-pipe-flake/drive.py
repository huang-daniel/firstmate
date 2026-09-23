import subprocess, pathlib, json
root=pathlib.Path.cwd()
evidence=pathlib.Path(__file__).parent
snapshot=evidence/'quota-live.json'
log=[]
def run(args, expected):
    r=subprocess.run(args,text=True,capture_output=True)
    actual=(r.returncode,r.stdout,r.stderr)
    assert actual==expected, (args,actual,expected)
    return actual
cli=['bash','bin/fm-quota-choose.sh','--snapshot',str(snapshot)]
cases=[(['claude:default','codex:default'],(0,'codex default\n','')),(['claude:default'],(1,'none\n','')),(['claude:default','bogus:default'],(2,'','error: unknown harness: bogus\n')),(['codex:default','rovo:default'],(2,'','error: unknown harness: rovo\n'))]
for args,expected in cases:
    for i in range(50): run(cli+args,expected)
    log.append(f"CLI {args}: 50 repetitions; exit={expected[0]}, stdout={expected[1]!r}, stderr={expected[2]!r}")
script=r'''set -euo pipefail
source bin/fm-control-lib.sh
for ((i=0;i<1000;i++)); do
  for h in claude codex opencode pi pi-signed grok kimi cursor gemini muse rovo omp agy; do
    fm_control_harness_supported "$h"
  done
  for h in '' bogus Claude claude-extra 'pi signed'; do
    if fm_control_harness_supported "$h"; then exit 90; fi
  done
  if fm_control_harness_supported; then exit 91; fi
done
printf 'All 13 registered names accepted; empty, omitted, unknown, case and prefix variants rejected across 1000 iterations.\n'
'''
r=subprocess.run(['bash','-c',script],text=True,capture_output=True)
assert r.returncode==0 and not r.stderr,(r.returncode,r.stderr)
log.append(r.stdout.strip())
(evidence/'live-transcript.txt').write_text('Real quota snapshot: quota-axi --json\n'+ '\n'.join(log)+'\n')
print('\n'.join(log))
