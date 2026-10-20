"""Local source/ABI acceptance gate. --submission additionally requires finalized live prerequisites.
This is our explicit check list, not a claim to reproduce IMD's private verifier.
No network, keys, signing or broadcasting.
"""
import argparse,hashlib,json,re,sys
from pathlib import Path
from Crypto.Hash import keccak
ROOT=Path(__file__).resolve().parents[1]
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--submission',action='store_true');args=p.parse_args()
 checks={};blockers=[]
 def check(name,value):
  checks[name]=bool(value)
  if not value:blockers.append(name)
 a=json.loads((ROOT/'ACCEPTANCE.json').read_text());manifest=json.loads((ROOT/'launch.json').read_text());pr=json.loads((ROOT/'PREREQUISITES.json').read_text())
 config=(ROOT/'foundry.toml').read_text()
 check('default_test_root_includes_all_suites',bool(re.search(r'(?m)^test\s*=\s*"test"\s*$',config)))
 check('declared_flags_exact',set(manifest['hook']['permissions'])=={'beforeInitialize','beforeAddLiquidity','beforeSwap','afterSwap'} and len(manifest['hook']['permissions'])==4)
 for file,rule in a['requiredSuites'].items():
  data=(ROOT/file).read_bytes();check('pin:'+file,hashlib.sha256(data).hexdigest()==rule['sha256'])
  # Some required methods are inherited; compiler test discovery is checked separately.
 check('constitution_hash',hashlib.sha256((ROOT/'constitution.en.md').read_bytes()).hexdigest()==pr['constitution']['sha256'])
 names=['QuorumBoundCore','QuorumIssuanceHook','QuorumMembership','QuorumTreasury','QuorumWork','QuorumOperatingAccount','QuorumToken','QuorumSwapRouter']
 sizes={}
 for name in names:
  source='QuorumIssuanceHook' if name=='QuorumSwapRouter' else name
  art=json.loads((ROOT/'out'/(source+'.sol')/(name+'.json')).read_text())
  creation=bytes.fromhex(art['bytecode']['object'].removeprefix('0x'));runtime=bytes.fromhex(art['deployedBytecode']['object'].removeprefix('0x'))
  sizes[name]={'creationBytes':len(creation),'runtimeBytes':len(runtime)};check('runtime:'+name,len(runtime)<=24576)
  if name=='QuorumBoundCore':check('core_creation_hash',('0x'+keccak.new(digest_bits=256,data=creation).hexdigest())==pr['coreCode']['creationKeccak256']);check('core_init_with_arguments',len(creation)+160<=49152)
  if name=='QuorumIssuanceHook':
   fn=next((x for x in art['abi'] if x.get('name')=='getHookPermissions' and x['type']=='function'),None)
   check('public_hook_permissions_query',fn is not None and fn['inputs']==[] and fn['stateMutability']=='pure' and len(fn['outputs'])==1 and len(fn['outputs'][0].get('components',[]))==14 and all(x['type']=='bool' for x in fn['outputs'][0]['components']))
   check('hook_constructor_arguments',manifest['hook']['constructorArgs']==['$poolManager','$token']);check('hook_init_with_arguments',len(creation)+64<=49152)
  if name=='QuorumToken':check('zero_argument_token',next((x for x in art['abi'] if x['type']=='constructor'),{'inputs':[]})['inputs']==[])
 if args.submission:
  check('prerequisites_verified_on_chain',pr.get('status')=='VERIFIED_DEPLOYED' and pr.get('submissionAllowed') is True)
  address=pr['coreCode'].get('address');check('code_package_final_address',bool(address) and address!=pr['coreCode'].get('candidatePlaceholder'))
  if address:check('token_binds_final_code_package',address[2:].lower() in (ROOT/'src/QuorumToken.sol').read_text().lower())
  check('live_receipts_and_runtime_verification',bool(pr.get('runtimeAndReceiptsVerified')))
 result={'ok':not blockers,'mode':'submission' if args.submission else 'local','checks':checks,'blockers':blockers,'sizes':sizes,'limitations':['Not IMD private deployment-verifier execution','Compiled creation hash and receipt checks must be rerun after final address binding','No bypass/adversarial testing performed']}
 print(json.dumps(result,indent=2));return 0 if result['ok'] else 1
if __name__=='__main__':sys.exit(main())
