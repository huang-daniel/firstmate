import os, pathlib, subprocess, json, shutil
root=pathlib.Path.cwd(); ev=pathlib.Path('/home/dev/.no-mistakes/evidence/01M36X498DH839GV7MR09971ND'); home=root/'.snapshot-live-test'; base=root/'bin/.snapshot-base-test.sh'
home.mkdir(); [(home/x).mkdir() for x in ['data','state','config','projects','tmp']]
env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') or k.startswith('TASKS_AXI_'): del env[k]
env.update(FM_HOME=str(home),FM_ROOT_OVERRIDE=str(root),TMPDIR=str(home/'tmp'))
log=[]
def run(name,script='bin/fm-fleet-snapshot.sh',mode='--contribution-input'):
 p=subprocess.run(['bash',str(root/script),mode],env=env,capture_output=True)
 (ev/(name+'.json')).write_bytes(p.stdout); (ev/(name+'.stderr')).write_bytes(p.stderr)
 log.append({'scenario':name,'command':f'FM_HOME=<isolated home> bash {script} {mode}','exit':p.returncode,'bytes':len(p.stdout),'stderr':p.stderr.decode()})
 return p
try:
 (home/'data/backlog.md').write_text('# Backlog\n\n## Queued\n')
 p=run('empty'); assert p.returncode==0; d=json.loads(p.stdout); assert d['backlog']['records']==[] and d['tasks']==[]
 filler='filler-text-block-'*30
 (home/'data/backlog.md').write_text('# Backlog\n\n## Queued\n'+''.join(f'- [ ] oversized-{i:05d} - Padding task {i:05d} {filler} https://github.com/o/r/pull/{i} (repo: sample) (kind: ship)\n' for i in range(1,3001)))
 base.write_bytes(subprocess.check_output(['git','show','327bb93a:bin/fm-fleet-snapshot.sh']))
 p=run('oversized-before','bin/.snapshot-base-test.sh'); assert not p.stdout and b'Argument list too long' in p.stderr
 p=run('oversized-after'); assert p.returncode==0; d=json.loads(p.stdout); assert len(d['backlog']['records'])==3000 and len(p.stdout)>2097152
 log[-1]['records']=len(d['backlog']['records'])
 p=run('full-snapshot',mode='--json'); assert p.returncode==0; d=json.loads(p.stdout); assert len(d['backlog']['records'])==3000
 (home/'data/backlog.md').write_text('# Backlog\n\n## Queued\n')
 for i in range(100): (home/f'state/task-{i:03d}.meta').write_text('kind=ship\npr=https://example.invalid/'+('x'*1600)+f'/{i}\npr_head=abc123\n')
 p=run('oversized-tasks'); assert p.returncode==0; d=json.loads(p.stdout); assert len(d['tasks'])==100 and len(json.dumps(d['tasks']))>131072
 assert d['tasks'][99]['pr']['url'].endswith('/99')
 log[-1]['tasks']=len(d['tasks'])
 assert not list((home/'tmp').iterdir()), list((home/'tmp').iterdir())
 log.append({'cleanup':'no temporary transport files remain'})
finally:
 (ev/'transcript.json').write_text(json.dumps(log,indent=2)); base.unlink(missing_ok=True); shutil.rmtree(home)
print(json.dumps(log,indent=2))
