import os, subprocess, pathlib, json
root=pathlib.Path.cwd(); home=root/'.test-phase/live'; ev=pathlib.Path('/home/dev/.no-mistakes/evidence/01M2XDQ5YVXGQMDE3XP6VCERN5/live-cli.txt')
env=dict(os.environ,FM_HOME=str(home),FM_GATE_REFUSE_BYPASS='1')
merged=json.loads(subprocess.check_output(['gh','pr','view','15','--repo','huang-daniel/firstmate','--json','state,headRefOid,url']))
opened=json.loads(subprocess.check_output(['gh','pr','view','16','--repo','huang-daniel/firstmate','--json','state,headRefOid,url']))
base=f'kind=ship\nmode=no-mistakes\nspawn_gen=live-test\nbackend=tmux\nwindow=phase-test-nonexistent:fm-phase-live\nworktree={root}/.test-phase/absent-tree\nproject={root}/.test-phase/absent-project\n'
cases=[('missing-github-head',merged['url'],'',True,1),('missing-gitlab-head','https://gitlab.com/example/repo/-/merge_requests/7','',True,1),('open-pr',opened['url'],opened['headRefOid'],False,1),('forced-open-pr',opened['url'],opened['headRefOid'],True,1),('mismatched-head',merged['url'],'a'*40,True,1),('unreadable-pr','https://github.com/huang-daniel/firstmate/pull/999999',merged['headRefOid'],True,1),('verified-merge',merged['url'],merged['headRefOid'],True,0)]
with ev.open('w') as log:
 log.write('Live read-only GitHub preconditions: '+json.dumps([merged,opened])+'\n')
 for name,url,head,force,expected in cases:
  meta=home/'state/phase-live.meta'; meta.write_text(base+f'pr={url}\n'+(f'pr_head={head}\n' if head else '')); before=meta.read_bytes(); (home/'state/.last-watcher-beat').touch()
  cmd=['bin/fm-teardown.sh','phase-live']+(['--force'] if force else [])
  p=subprocess.run(cmd,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
  retained=meta.exists(); unchanged=retained and meta.read_bytes()==before
  log.write(f'\n{name}: {" ".join(cmd)}\n{p.stdout}\nexit={p.returncode}; record_exists={retained}; record_unchanged={unchanged}\n'); log.flush()
  print(name,p.returncode,retained,unchanged,flush=True)
  assert p.returncode==expected and (unchanged if expected else not retained),p.stdout
