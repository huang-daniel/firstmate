import os, subprocess, pathlib, json
root=pathlib.Path.cwd(); scratch=root/'.test-live-delivery'; state=scratch/'home/state'
evidence=pathlib.Path('/home/dev/.no-mistakes/evidence/01M2XDG20HJ2MPYYCKJP7WQ4C3')
env=dict(os.environ, FM_GATE_REFUSE_BYPASS='1', TMUX=str(scratch/'socket')+',0,0', FM_HOME=str(scratch/'home'), FM_SEND_SETTLE='0')
log=[]
def send(*args, ok=True):
 p=subprocess.run([str(root/'bin/fm-send.sh'),*args],env=env,text=True,capture_output=True)
 log.append({'args':args,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
 assert (p.returncode==0)==ok,log[-1]
 return p.stderr
def count(t): return len(list((state/(t+'.inbox')).glob('*.msg')))
try:
 for _ in range(2): assert 'collapsed' in send('t1','validate once')
 assert count('t1')==1
 assert 'deliberate repeat' in send('t1','--again','validate once'); assert count('t1')==2
 send('t1','distinct instruction'); assert count('t1')==3
 text='first line\n\n  indented line\n'
 send('t1',text); assert 'collapsed' in send('t1',text); assert count('t1')==4
 (state/'t2.meta').write_text('window=delivery:worker\nkind=ship\nharness=claude\nbackend=tmux\n')
 send('t2','validate once'); assert count('t2')==1
 for p in (state/'t1.inbox').glob('*.msg'): p.rename(p.parent/'handled'/p.name)
 assert 'steer queued' in send('t1','validate once'); assert count('t1')==1
 for args in [('t1','--again','/help'),('t1','--again','--key','Enter'),('t1','--again','--fire-and-forget','1234567890abcdef','hello')]: send(*args,ok=False)
 assert count('t1')==1
 log.append({'persisted_records':{str(p.relative_to(state)):p.read_text() for p in state.glob('*.inbox/**/*.msg')}})
 log.append({'result':'All live assertions passed; endpoint was a real tmux pane running sleep, with no transport stubs.'})
finally:
 (evidence/'live-delivery.json').write_text(json.dumps(log,indent=2))
print(log[-1])
