"""Finite positive issuance rehearsal against actual mainnet factory state, on local fork only."""
import json,socket,subprocess,time,os,requests,hashlib,rlp,sys
from pathlib import Path
from prepare_issuance import ROOT,artifact,creation,calldata,output,build,raw,hx,kh,encode,decode,SUPPLY
REMOTE='https://ethereum-rpc.publicnode.com'
FACTORY='0x12c63b581d07093f6126bc02263c58f7eadaa96f'
IMD='0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7'
def remote(method,params):
    v=requests.post(REMOTE,json={'jsonrpc':'2.0','id':1,'method':method,'params':params},timeout=30).json()
    if 'error' in v:raise RuntimeError(str(v['error']))
    return v['result']
def main():
    d=ROOT/('evidence/mainnet-fork-'+str(time.time_ns()));d.mkdir(exist_ok=False,parents=True)
    result={'complete':False,'forkOnly':True,'realMainnetTransaction':False,'checks':{},'receipts':[]}
    tag='latest'
    if '--fork-block' in sys.argv:tag=hex(int(sys.argv[sys.argv.index('--fork-block')+1],0))
    elif '--fixed-token' in sys.argv:
        saved=json.loads((ROOT/'evidence/fixed-mainnet-fork-summary.json').read_text())
        tag=saved['upstreamBlock']['number']
    block=remote('eth_getBlockByNumber',[tag,False]);assert int(remote('eth_chainId',[]),16)==1
    result['upstreamBlock']={k:block[k] for k in ['number','hash','timestamp']}
    with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
    url='http://127.0.0.1:'+str(port);log=(d/'anvil.log').open('w',encoding='utf-8')
    cmd=['anvil','--host','127.0.0.1','--port',str(port),'--chain-id','31337','--hardfork','osaka','--enable-tx-gas-limit','--gas-limit','30000000','--fork-url',REMOTE,'--fork-block-number',str(int(block['number'],16)),'--silent']
    proc=subprocess.Popen(cmd,stdout=log,stderr=log,creationflags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0)
    def rpc(m,p=()):
        v=requests.post(url,json={'jsonrpc':'2.0','id':1,'method':m,'params':list(p)},timeout=45).json()
        if 'error' in v:raise RuntimeError(str(v['error']))
        return v['result']
    def check(label,v):
        result['checks'][label]=bool(v)
        if not v:raise AssertionError(label)
    def read(a,art,name,args=()):return output(art,name,rpc('eth_call',[{'to':a,'data':hx(calldata(art,name,args))},'latest']))
    def send(label,who,to,data):
        check('local_chain_before_transaction',int(rpc('eth_chainId'),16)==31337)
        base=int(rpc('eth_getBlockByNumber',['latest',False])['baseFeePerGas'],16)
        tx={'from':who,'data':hx(data),'value':'0x0','maxFeePerGas':hex(2*base+1000000),'maxPriorityFeePerGas':hex(1000000)}
        if to:tx['to']=to
        estimate=int(rpc('eth_estimateGas',[tx]),16);check(label+'_gas_estimate',estimate<=16777216)
        tx['gas']=hex(min(16777216,estimate+300000));h=rpc('eth_sendTransaction',[tx]);r=None
        for _ in range(100):
            r=rpc('eth_getTransactionReceipt',[h])
            if r:break
            time.sleep(.2)
        result['receipts'].append({'label':label,'estimateGas':estimate,'gasLimit':int(tx['gas'],16),'receipt':r})
        if r and r['status']!='0x1':
            try:result['failedTrace']=rpc('debug_traceTransaction',[h,{'tracer':'callTracer'}])
            except Exception as e:result['traceError']=str(e)
        check(label+'_success',r and r['status']=='0x1');return r
    def predict(a,nonce):return hx(kh(rlp.encode([raw(a),nonce]))[-20:])
    try:
        for _ in range(100):
            try:accounts=rpc('eth_accounts');break
            except Exception:
                if proc.poll() is not None:raise RuntimeError('Fork process failed; see anvil.log')
                time.sleep(.2)
        else:raise RuntimeError('Fork startup unavailable')
        check('fork_chain',int(rpc('eth_chainId'),16)==31337)
        f=artifact('LaunchFactory.sol','LaunchFactory');h=artifact('QuorumIssuanceHook.sol','QuorumIssuanceHook')
        live_code=rpc('eth_getCode',[FACTORY,'latest']);check('actual_factory_present',len(live_code)>2)
        result['factoryRuntimeKeccak256']=hx(kh(raw(live_code)))
        manager=read(FACTORY,f,'poolManager')[0];deployer=read(FACTORY,f,'deployer')[0];registry=read(FACTORY,f,'registry')[0]
        result['dependencies']={'factory':FACTORY,'manager':manager,'deployer':deployer,'registry':registry,'imd':IMD}
        caller=('0x2F29e170c709B6F3cE8D10BFebc8d8b0a73de7C1' if '--fixed-token' in sys.argv else accounts[0]);rpc('anvil_impersonateAccount',[caller]);nonce=int(rpc('eth_getTransactionCount',[caller,'latest']),16)
        constitution=predict(caller,nonce);package=predict(caller,nonce+1)
        r=send('constitution',caller,None,creation(artifact('ConstitutionPrototype.sol','ConstitutionPrototype'),[(ROOT/'constitution.en.md').read_bytes()]));check('constitution_address',r['contractAddress'].lower()==constitution.lower())
        code=raw(artifact('QuorumBoundCore.sol','QuorumBoundCore')['bytecode']['object'])
        r=send('core_package',caller,None,creation(artifact('QuorumCoreCode.sol','QuorumCoreCode'),[code[:24000],code[24000:],kh(code)]));check('package_address',r['contractAddress'].lower()==package.lower())
        # Impersonation is confined to this fork to reproduce the documented deployer role.
        rpc('anvil_impersonateAccount',[deployer]);rpc('anvil_setBalance',[deployer,hex(10**20)])
        for order in ('token0','token1'):
            config={'chainId':31337,'localOnly':True,'factory':FACTORY,'manager':manager,'imd':IMD,'requester':caller,'name':'QUORUM Fork','symbol':'FORK','stakeAmount':str(62500*10**18),'coreCode':package,'predeployedConstitution':constitution,'launchNumber':9000000000000000000+(0 if order=='token0' else 1),'merkleRoot':hx(kh(kh(encode(['address','uint256'],[caller,SUPPLY//10])))),'seedMode':'imd-policy-34','payerHandover':True}
            if '--fixed-token' in sys.argv:config['fixedToken']={'artifactSource':'QuorumToken.sol','contract':'QuorumToken'}
            for variant in range(100):
                config['name']='QUORUM Fork '+str(variant)
                config['launchNumber']=9000000000000000000+2*variant+(0 if order=='token0' else 1)
                packet=build(config)
                if (int(packet['predicted']['token'],16)<int(IMD,16))==(order=='token0'):break
            else:raise RuntimeError('No address-order candidate')
            # Include 64 contributor IDs in the same canonical launch tuple for a normal metadata envelope.
            fn=next(x for x in f['abi'] if x.get('name')=='launch');from prepare_issuance import canonical
            types=[canonical(x) for x in fn['inputs']];args=list(decode(types,raw(packet['transaction']['data'])[4:]));params=list(args[0]);params[20]=list(range(1,65))
            data=calldata(f,'launch',[params])
            a=packet['predicted'];a['core']=predict(package,int(rpc('eth_getTransactionCount',[package,'latest']),16))
            a['membership']=predict(a['core'],1);a['treasury']=predict(a['core'],2)
            a['work']=predict(a['treasury'],1);a['operatingAccount']=predict(a['treasury'],2)
            r=send(order+'_launch_64_ids',deployer,FACTORY,data)
            result.setdefault('launchGas',{})[order]=int(r['gasUsed'],16)
            a=packet['predicted'];actual_core=read(a['hook'],h,'core')[0];check(order+'_core_binding',actual_core.lower()==a['core'].lower())
            for key in ['token','hook','core','membership','treasury','work','operatingAccount']:check(order+'_'+key+'_code',len(rpc('eth_getCode',[a[key],'latest']))>2)
            reg=artifact('LaunchRegistry.sol','LaunchRegistry');check(order+'_registry',read(registry,reg,'isRecorded',[config['launchNumber']])[0])
            token_art=artifact('QuorumLaunchToken.sol','QuorumLaunchToken')
            core_art=artifact('QuorumBoundCore.sol','QuorumBoundCore')
            treasury_art=artifact('QuorumTreasury.sol','QuorumTreasury')
            membership_art=artifact('QuorumMembership.sol','QuorumMembership')
            constitution_art=artifact('ConstitutionPrototype.sol','ConstitutionPrototype')
            code_art=artifact('QuorumCoreCode.sol','QuorumCoreCode')
            check(order+'_exact_constitution_text',read(constitution,constitution_art,'text')[0]==(ROOT/'constitution.en.md').read_bytes())
            check(order+'_constitution_hash',read(constitution,constitution_art,'constitutionHash')[0]==hashlib.sha256((ROOT/'constitution.en.md').read_bytes()).digest())
            check(order+'_creation_package_hash',read(package,code_art,'creationHash')[0]==kh(code))
            check(order+'_token_code_binding',read(a['token'],token_art,'coreCode')[0].lower()==package.lower())
            check(order+'_token_constitution_binding',read(a['token'],token_art,'constitution')[0].lower()==constitution.lower())
            check(order+'_core_constitution_binding',read(a['core'],core_art,'constitution')[0].lower()==constitution.lower())
            check(order+'_membership_token',read(a['membership'],membership_art,'token')[0].lower()==a['token'].lower())
            check(order+'_treasury_imd',read(a['treasury'],treasury_art,'asset')[0].lower()==IMD.lower())
            check(order+'_treasury_reporter',read(a['treasury'],treasury_art,'rewardReporter')[0].lower()==a['hook'].lower())
            artifacts=read(registry,reg,'artifactsOf',[config['launchNumber']])[0]
            entries={entry[0].rstrip(b'\0').decode():entry[2] for entry in artifacts}
            check(order+'_registered_token',entries['token'].lower()==a['token'].lower())
            check(order+'_registered_hook',entries['hook'].lower()==a['hook'].lower())
            distributor=entries['distributor'];dist_art=artifact('MerkleDistributor.sol','MerkleDistributor')
            check(order+'_distributor_token',read(distributor,dist_art,'token')[0].lower()==a['token'].lower())
            check(order+'_distributor_opener',read(distributor,dist_art,'opener')[0].lower()==FACTORY.lower())
            check(order+'_root_matches_requested',read(distributor,dist_art,'roundOf',[0])[0][0]==raw(config['merkleRoot']))
            dist_balance=read(a['token'],token_art,'balanceOf',[distributor])[0]
            pool_balance=read(a['token'],token_art,'balanceOf',[manager])[0]
            remainder=read(a['token'],token_art,'balanceOf',[caller])[0]
            check(order+'_swarm_tenth',dist_balance==SUPPLY//10)
            check(order+'_no_factory_residue',read(a['token'],token_art,'balanceOf',[FACTORY])[0]==0)
            check(order+'_supply_accounted',dist_balance+pool_balance+remainder==SUPPLY)
            check(order+'_pool_ninety_with_rounding_only',params[7]==9000 and remainder<=10**9 and pool_balance<=SUPPLY*9//10)
            result.setdefault('distribution',{})[order]={'pool':str(pool_balance),'swarm':str(dist_balance),'roundingRemainder':str(remainder),'remainderRecipient':caller,'configuredFounderAllocation':0}
            check(order+'_initial_payer',read(FACTORY,f,'positionOf',[config['launchNumber']])[3].lower()==caller.lower())
            send(order+'_handover',caller,FACTORY,calldata(f,'setRequester',[config['launchNumber'],a['hook']]))
            check(order+'_fee_recipient',read(FACTORY,f,'positionOf',[config['launchNumber']])[3].lower()==a['hook'].lower())
            (d/(order+'-packet.json')).write_text(json.dumps(packet,indent=2),encoding='utf-8')
        result['complete']=True
    except Exception as e:
        result['error']=type(e).__name__+': '+str(e)[:800]
    finally:
        proc.terminate()
        try:proc.wait(timeout=5)
        except subprocess.TimeoutExpired:proc.kill();proc.wait(timeout=5)
        log.close();result['processExited']=proc.poll() is not None
        with socket.socket() as s:result['portClosed']=s.connect_ex(('127.0.0.1',port))!=0
        (d/'summary.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
        print(json.dumps({k:result.get(k) for k in ['complete','error','launchGas','processExited','portClosed']}),flush=True)
    if not result['complete']:raise SystemExit(1)
if __name__=='__main__':main()
