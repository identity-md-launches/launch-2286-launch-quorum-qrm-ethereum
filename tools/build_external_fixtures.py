"""Reproduce unchanged external factory/PoolManager fixtures with their pinned Solidity version."""
from pathlib import Path
import hashlib,json,subprocess
NAMES=('PoolManager','LaunchFactory','LaunchRegistry','LaunchFees','MerkleDistributor')
def build_external(root):
    d=root/'fixtures/external-build'; sources={}
    for directory in ('lib/v4-core','lib/imd-launch-verified'):
        for p in (root/directory).rglob('*.sol'):
            if any(x in ('out','cache','.git','node_modules') for x in p.parts):continue
            sources[p.relative_to(root).as_posix()]=hashlib.sha256(p.read_bytes()).hexdigest()
    config='[profile.default]\nsrc="lib/imd-launch-verified/src"\nout="out"\nsolc_version="0.8.26"\nevm_version="cancun"\noptimizer=true\noptimizer_runs=200\nvia_ir=true\nbytecode_hash="none"\nremappings=["v4-core/=lib/v4-core/","solmate/=lib/v4-core/lib/solmate/","@openzeppelin/contracts/=lib/imd-launch-verified/lib/openzeppelin-contracts/contracts/"]\n'
    digest=hashlib.sha256(json.dumps({'sources':sources,'config':config},sort_keys=True).encode()).hexdigest()
    reportpath=d/'build-summary.json'
    if reportpath.exists():
        old=json.loads(reportpath.read_text(encoding='utf-8'))
        if old.get('inputDigest')==digest and all((d/n).exists() and hashlib.sha256((d/n).read_bytes()).hexdigest()==h for n,h in old.get('artifactSha256',{}).items()) and len(old.get('artifactSha256',{}))==len(NAMES):return old
    d.mkdir(parents=True,exist_ok=True)
    for rel in sources:
        q=d/rel;q.parent.mkdir(parents=True,exist_ok=True);q.write_bytes((root/rel).read_bytes())
    (d/'foundry.toml').write_text(config,encoding='utf-8')
    command=['forge','build','lib/v4-core/src/PoolManager.sol','lib/imd-launch-verified/src/LaunchFactory.sol']
    run=subprocess.run(command,cwd=d,capture_output=True,text=True,encoding='utf-8',timeout=180)
    (d/'build.log').write_text(run.stdout+run.stderr,encoding='utf-8')
    if run.returncode:raise RuntimeError('External fixture build failed; see fixtures/external-build/build.log')
    artifacts={};sizes={}
    for n in NAMES:
        p=d/'out'/f'{n}.sol'/f'{n}.json';a=json.loads(p.read_text(encoding='utf-8'))
        artifacts[p.relative_to(d).as_posix()]=hashlib.sha256(p.read_bytes()).hexdigest()
        sizes[n]=len(bytes.fromhex(a['deployedBytecode']['object'].removeprefix('0x')))
        if sizes[n]>24576:raise RuntimeError('External fixture EIP-170 limit: '+n)
    result={'inputDigest':digest,'sourceSha256':sources,'artifactSha256':artifacts,'runtimeBytes':sizes,'compiler':'0.8.26','command':command,'originalSourceUnchanged':True}
    reportpath.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8');return result
if __name__=='__main__':
    report=build_external(Path(__file__).resolve().parents[1]);print(json.dumps({'runtimeBytes':report['runtimeBytes'],'compiler':report['compiler']}))
