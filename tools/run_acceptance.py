"""Run every discovered positive test and verify mandatory suite membership. Local only."""
import datetime,json,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
EVIDENCE=ROOT/'evidence';EVIDENCE.mkdir(exist_ok=True)
p=subprocess.run(['forge','test','--json'],cwd=ROOT,capture_output=True,text=True,encoding='utf-8')
(EVIDENCE/'forge-all.json').write_text(p.stdout,encoding='utf-8');(EVIDENCE/'forge-all.stderr.txt').write_text(p.stderr,encoding='utf-8')
if p.returncode and not p.stdout.strip():print(p.stderr);sys.exit(p.returncode)
d=json.loads(p.stdout);counts={};tests=[]
for suite,v in d.items():
 for name,t in v.get('test_results',{}).items():
  status=t.get('status','unknown');counts[status]=counts.get(status,0)+1;tests.append({'suite':suite,'name':name,'status':status,'reason':t.get('reason')})
a=json.loads((ROOT/'ACCEPTANCE.json').read_text());required={}
for path,rule in a['requiredSuites'].items():
 for name in rule['requiredCases']:required[path+':'+name]=any(t['suite'].split(':')[0]==path and t['name']==name and t['status']=='Success' for t in tests)
check=subprocess.run([sys.executable,'tools/verify_candidate.py'],cwd=ROOT,capture_output=True,text=True,encoding='utf-8')
(EVIDENCE/'local-preflight.json').write_text(check.stdout,encoding='utf-8')
ok=p.returncode==0 and check.returncode==0 and all(required.values()) and all(t['status']=='Success' for t in tests)
s={'checkedAtUtc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'ok':ok,'counts':counts,'requiredCases':required,'tests':tests,'note':'Test harness may replay weeks with a large per-test budget; local Anvil separately enforces the actual per-transaction gas cap.'}
(EVIDENCE/'acceptance-summary.json').write_text(json.dumps(s,indent=2),encoding='utf-8');print(json.dumps({'ok':ok,'counts':counts,'mandatory':len(required),'missing':[k for k,v in required.items() if not v]}));sys.exit(0 if ok else 1)
