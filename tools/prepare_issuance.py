from constitution_pack import encoded_text
"""Offline LOCAL candidate packet builder. No RPC, key access, signing or broadcast.
Not an IMD admission manifest. Real release configuration remains gated.
"""
import argparse
import hashlib
import json
from pathlib import Path
from eth_abi import encode, decode
from Crypto.Hash import keccak
from seed_parameters import policy34,verify_public_example

ROOT = Path(__file__).resolve().parents[1]
FLAGS = 0x28c0
SUPPLY = 10**27
ZERO = bytes(32)

def kh(data): return keccak.new(digest_bits=256, data=data).digest()
def hx(data): return '0x'+data.hex()
def raw(value): return bytes.fromhex(value.removeprefix('0x'))
def artifact(source, name):
    base=ROOT/'fixtures/external-build/out' if name in ('PoolManager','LaunchFactory','LaunchRegistry','LaunchFees','MerkleDistributor') else ROOT/'out'
    return json.loads((base/source/(name+'.json')).read_text(encoding='utf-8-sig'))
def canonical(item):
    if item['type'].startswith('tuple'):
        return '('+','.join(canonical(c) for c in item['components'])+')'+item['type'][5:]
    return item['type']
def fn(art, name): return next(x for x in art['abi'] if x.get('name')==name and x['type']=='function')
def calldata(art, name, args):
    f=fn(art,name); types=[canonical(x) for x in f['inputs']]
    return kh((name+'('+','.join(types)+')').encode())[:4]+encode(types,args)
def output(art, name, data):
    return decode([canonical(x) for x in fn(art,name)['outputs']],raw(data))
def creation(art, args=()):
    constructor=next((x for x in art['abi'] if x['type']=='constructor'),{'inputs':[]})
    return raw(art['bytecode']['object'])+encode([canonical(x) for x in constructor['inputs']],args)
def create2(factory, salt, code): return hx(kh(b'\xff'+raw(factory)+salt+kh(code))[-20:])
def create_child(parent, nonce):
    # All current composition children use nonces 1..3; do not generalize RLP silently.
    if not 1<=nonce<128: raise ValueError('small positive child nonce required')
    return hx(kh(b'\xd6\x94'+raw(parent)+bytes([nonce]))[-20:])
def source_hashes():
    files=[ROOT/'foundry.toml',ROOT/'constitution.en.md',ROOT/'constitution.packed.hex']
    for directory in ('src','lib/imd-launch-verified','lib/openzeppelin-token-v5.4.0','lib/v4-core/src','lib/v4-core/lib/solmate/src'):
        files.extend((ROOT/directory).rglob('*.sol'))
    return {p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(set(files))}
def build(c):
    if c.get('chainId')!=31337 or c.get('localOnly') is not True:
        raise ValueError('Only explicit local rehearsal configuration is supported; release gates unresolved')
    text=(ROOT/'constitution.en.md').read_bytes()
    token_source,token_name='QuorumLaunchToken.sol','QuorumLaunchToken'
    if c.get('fixedToken'):
        token_source=c['fixedToken']['artifactSource'];token_name=c['fixedToken']['contract']
        if Path(token_source).name!=token_source or Path(token_name).name!=token_name:raise ValueError('Artifact basename required')
        fixed=artifact(token_source,token_name)
        constructor=next((x for x in fixed['abi'] if x['type']=='constructor'),{'inputs':[]})
        if constructor['inputs']:raise ValueError('Fixed token must have a zero-argument constructor')
        token_code=creation(fixed)
    else:
        token_code=creation(artifact(token_source,token_name),[
            c['name'],c['symbol'],c['imd'],int(c['stakeAmount']),c['coreCode'],c['predeployedConstitution']])
    token=create2(c['factory'],int(c['launchNumber']).to_bytes(32,'big'),token_code)
    hook_code=creation(artifact('QuorumIssuanceHook.sol','QuorumIssuanceHook'),[c['manager'],token])
    if max(len(token_code),len(hook_code))>49152: raise ValueError('EIP-3860 initcode limit')
    for n in range(2_000_000):
        salt=n.to_bytes(32,'big'); hook=create2(c['factory'],salt,hook_code)
        if int(hook,16)&0x3fff==FLAGS: break
    else: raise ValueError('Hook salt search exhausted')
    p0=int(token,16)<int(c['imd'],16)
    seed_mode=c.get('seedMode','local-1-to-1')
    if seed_mode not in ('local-1-to-1','imd-policy-34'):raise ValueError('Unknown seed mode')
    if seed_mode=='imd-policy-34':
        verify_public_example();seed=policy34(p0)
    else:seed={'sqrtPriceX96':2**96,'tickLower':0 if p0 else -887220,
        'tickUpper':887220 if p0 else 0,'liquidity':700_000_000*10**18}
    # Real policy math can be rehearsed with local fixture currencies; no mainnet packet is emitted.
    params=[c['launchNumber'],b'univ4_hook'.ljust(32,b'\0'),token_code,hook_code,salt,FLAGS,
        SUPPLY,9000,c['requester'],raw(c['merkleRoot']),3600,365*86400,c['imd'],12500,60,seed['sqrtPriceX96'],
        seed['tickLower'],seed['tickUpper'],seed['liquidity'],
        [ZERO,0,0,ZERO,ZERO,ZERO,ZERO,'local-positive-fixture'],[],c['requester'] if c.get('payerHandover') else hook]
    data=calldata(artifact('LaunchFactory.sol','LaunchFactory'),'launch',[params])
    core=create_child(c['coreCode'],3); treasury=create_child(core,2)
    addresses={'token':token,'hook':hook,'core':core,'constitution':c['predeployedConstitution'],
        'membership':create_child(core,1),'treasury':treasury,'work':create_child(treasury,1),'operatingAccount':create_child(treasury,2),
        'router':create_child(hook,1),'quota':create_child(hook,2)}
    return {'schema':1,'localOnly':True,'chainId':31337,'status':'local-candidate-not-release',
        'config':c,'constitutionSha256':hashlib.sha256(text).hexdigest(),'predicted':addresses,
        'tokenInitcodeBytes':len(token_code),'hookInitcodeBytes':len(hook_code),
        'tokenInitcodeKeccak256':hx(kh(token_code)),'hookInitcodeKeccak256':hx(kh(hook_code)),
        'hookSalt':hx(salt),'hookFlags':FLAGS,'poolFixture':{'mode':seed_mode,'parameters':seed,'price':'policy 34 cap, local rehearsal' if seed_mode=='imd-policy-34' else '1 IMD per token, local only',
        'tickLower':params[16],'tickUpper':params[17],'liquidity':str(params[18])},
        'transaction':{'from':c['requester'],'to':c['factory'],'value':'0x0','data':hx(data)},
        'calldataBytes':len(data),'sourceSha256':source_hashes(),
        'artifactSha256':{p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest()
            for source,name in [(token_source,token_name),('QuorumIssuanceHook.sol','QuorumIssuanceHook'),('LaunchFactory.sol','LaunchFactory')]
            for p in [(ROOT/'fixtures/external-build/out' if name=='LaunchFactory' else ROOT/'out')/source/(name+'.json')]},
        'unresolved':['Final fixed stake amount approval (independent of launch snapshot)',
        'Final policy selection, manifest/admission and exact platform parameter acceptance',
        'Platform must assign requester fee rights to the immutable hook, or original requester must hand them over before acceptance',
        'IMD issuance compatibility and mandatory platform checks; supplied constitution is not an invitation to redesign governance',
        'Final production binding and issuance authorization pending; immutable package is predeployed and Hook creates Core with actual addresses',
        'IMD verification of immutable creation package, constitution and eventual constructor-bound core']}

def save(path,obj): Path(path).write_text(json.dumps(obj,indent=2)+'\n',encoding='utf-8')
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('config');p.add_argument('output');a=p.parse_args()
    target=Path(a.output).resolve()
    if not target.is_relative_to(ROOT/'evidence') or target.exists(): raise ValueError('New evidence path required')
    packet=build(json.loads(Path(a.config).read_text(encoding='utf-8-sig')));save(target,packet)
    print(json.dumps({'packet':str(target),'predicted':packet['predicted'],'calldataBytes':packet['calldataBytes']}))
if __name__=='__main__': main()
