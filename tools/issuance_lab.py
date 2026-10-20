from constitution_pack import encoded_text
from build_external_fixtures import build_external
"""Finite loopback-only Anvil rehearsal of the actual factory transaction packet.
Uses local unlocked fixture accounts. No private keys, external RPC or persistent service.
"""
import argparse
import hashlib
import json
import os
import socket
import subprocess
import time
import urllib.request
from pathlib import Path
from prepare_issuance import ROOT,artifact,calldata,creation,output,build,save,hx,raw,kh,encode,decode,SUPPLY,create2,create_child
from seed_parameters import verify_public_example

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--directory',required=True);p.add_argument('--project-order',choices=['token0','token1']);p.add_argument('--fixed-token-config');p.add_argument('--payer-handover',action='store_true');p.add_argument('--diagnostic-pre-fusaka',action='store_true');a=p.parse_args()
    directory=Path(a.directory).resolve()
    if not directory.is_relative_to(ROOT/'evidence'): raise ValueError('Evidence directory required')
    directory.mkdir(parents=True,exist_ok=False)
    external_report={"mode":"committed original fixture bytecode; optional separate source rebuild","directory":"fixtures/external-build/out"}
    compiled=subprocess.run(['forge','build'],cwd=ROOT,capture_output=True,text=True,encoding='utf-8')
    (directory/'build.txt').write_text(compiled.stdout+compiled.stderr,encoding='utf-8')
    if compiled.returncode: raise RuntimeError('Build failed before starting local node')
    with socket.socket() as sock: sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
    url=f'http://127.0.0.1:{port}'
    hardfork='cancun' if a.diagnostic_pre_fusaka else 'osaka'
    command=['anvil','--host','127.0.0.1','--port',str(port),'--chain-id','31337','--hardfork',hardfork,
        '--timestamp',str(4*86400+200*7*86400),'--gas-limit',('100000000' if a.diagnostic_pre_fusaka else '30000000'),'--silent']
    if not a.diagnostic_pre_fusaka:command.append('--enable-tx-gas-limit')
    proc=subprocess.Popen(command,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,
        creationflags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0)
    counter=0;receipts=[];checks={};summary={'complete':False,'localOnly':True,'hardfork':hardfork,'diagnosticPreFusaka':a.diagnostic_pre_fusaka,'mainnetTransactionGasCap':16777216,'checks':checks}
    def rpc(method,params=()):
        nonlocal counter
        counter+=1
        req=urllib.request.Request(url,json.dumps({'jsonrpc':'2.0','id':counter,'method':method,'params':list(params)}).encode(),{'Content-Type':'application/json'})
        with urllib.request.urlopen(req,timeout=60) as response: result=json.load(response)
        if 'error' in result: raise RuntimeError(json.dumps(result['error']))
        return result['result']
    def check(label,value):
        checks[label]=bool(value)
        if not value: raise AssertionError(label)
    try:
        for _ in range(100):
            try: accounts=rpc('eth_accounts');break
            except Exception: time.sleep(.1)
        else: raise RuntimeError('Anvil startup failed')
        check('local_chain',int(rpc('eth_chainId'),16)==31337)
        caller=accounts[0];claimant=accounts[1]
        def transact(label,to,data,sender=caller):
            check('local_chain_before_mutation',int(rpc('eth_chainId'),16)==31337)
            tx={'from':sender,'data':hx(data),'value':'0x0'}
            if to:tx['to']=to
            estimate=int(rpc('eth_estimateGas',[tx]),16)
            summary.setdefault('estimates',{})[label]=estimate
            cap=90_000_000 if a.diagnostic_pre_fusaka else 16_777_216
            if estimate>cap:raise RuntimeError('Transaction estimate exceeds protocol gas cap')
            tx['gas']=hex(min(cap,estimate+500000))
            txid=rpc('eth_sendTransaction',[tx]);receipt=None
            for _ in range(100):
                receipt=rpc('eth_getTransactionReceipt',[txid])
                if receipt:break
                time.sleep(.05)
            if not receipt or int(receipt['status'],16)!=1:raise RuntimeError('Local transaction failed: '+label)
            receipts.append({'label':label,'estimateGas':estimate,'receipt':receipt})
            save(directory/'receipts.json',receipts)
            return receipt
        def deploy(label,source,name,args=()):
            return transact(label,None,creation(artifact(source,name),args))['contractAddress']
        def call(address,art,name,args=()):return output(art,name,rpc('eth_call',[{'to':address,'data':hx(calldata(art,name,args))},'latest']))
        def send(label,address,art,name,args=(),sender=caller):return transact(label,address,calldata(art,name,args),sender)
        manager_art=artifact('PoolManager.sol','PoolManager')
        summary['externalFixtureBuild']=external_report
        manager=transact('fixture-manager',None,creation(manager_art,[caller]))['contractAddress']
        fees=deploy('fixture-fees','LaunchFees.sol','LaunchFees',[caller,accounts[8],accounts[9],12500])
        factory=deploy('fixture-factory','LaunchFactory.sol','LaunchFactory',[manager,caller,fees])
        imd=deploy('fixture-imd','LocalFixtures.sol','LocalToken')
        root=kh(kh(encode(['address','uint256'],[claimant,SUPPLY//10])))
        config={'chainId':31337,'localOnly':True,'factory':factory,'manager':manager,'imd':imd,
            'requester':caller,'name':'QUORUM Local Candidate','symbol':'LOCAL','stakeAmount':str(62_500*10**18),
            'coreCode':create_child(caller,5),'predeployedConstitution':create_child(caller,4),'launchNumber':3000,'merkleRoot':hx(root),'seedMode':'imd-policy-34'}
        if a.payer_handover:config['payerHandover']=True
        if a.fixed_token_config:
            fixed=json.loads(Path(a.fixed_token_config).read_text(encoding='utf-8-sig'))
            if fixed.get('localOnly') is not True or fixed.get('chainId')!=31337:raise ValueError('Local fixed input only')
            if fixed['imd'].lower()!=imd.lower():raise ValueError('Fixed fixture IMD differs')
            for k in ['predeployedCore','predeployedConstitution']:
                if fixed[k].lower()!=config[k].lower():raise ValueError('Fixed predeployment fixture differs')
            for k in ['name','symbol','stakeAmount','fixedToken']:config[k]=fixed[k]
            code=creation(artifact(config['fixedToken']['artifactSource'],config['fixedToken']['contract']))
            predicted=create2(factory,(3000).to_bytes(32,'big'),code)
            actual_order='token0' if int(predicted,16)<int(imd,16) else 'token1'
            if a.project_order and a.project_order!=actual_order:raise ValueError('Fixed token has the other address order')
        else:
            desired=a.project_order or 'token0'
            # Different local labels select both address orderings without changing production rules.
            for variant in range(100):
                config['name']='QUORUM Local Candidate '+str(variant)
                code=creation(artifact('QuorumLaunchToken.sol','QuorumLaunchToken'),[config['name'],config['symbol'],imd,int(config['stakeAmount']),config['coreCode'],config['predeployedConstitution']])
                predicted=create2(factory,(3000).to_bytes(32,'big'),code)
                if (int(predicted,16)<int(imd,16))==(desired=='token0'):break
            else:raise RuntimeError('No local address-order fixture found')
            actual_order=desired
        summary['publicSeedComparison']=verify_public_example()
        summary['projectOrder']=actual_order;summary['fixedToken']=bool(a.fixed_token_config)
        save(directory/'config.json',config);packet=build(config);save(directory/'packet.json',packet)
        constitution=deploy('predeploy-constitution','ConstitutionPrototype.sol','ConstitutionPrototype',[(ROOT/'constitution.en.md').read_bytes()])
        check('predeployed_constitution_address',constitution.lower()==config['predeployedConstitution'].lower())
        core_code=raw(artifact('QuorumBoundCore.sol','QuorumBoundCore')['bytecode']['object'])
        catalog=deploy('predeploy-immutable-core-code','QuorumCoreCode.sol','QuorumCoreCode',[core_code[:24000],core_code[24000:],kh(core_code)])
        check('predeployed_catalog_address',catalog.lower()==config['coreCode'].lower())
        launch=transact('factory-launch-candidate',factory,raw(packet['transaction']['data']))
        summary['factoryLaunchReceiptGas']=int(launch['gasUsed'],16)
        summary['calldataBytes']=packet['calldataBytes'];summary['initcodeBytes']={k:packet[k] for k in ('tokenInitcodeBytes','hookInitcodeBytes')}
        addresses=packet['predicted'];f=artifact('LaunchFactory.sol','LaunchFactory');h=artifact('QuorumIssuanceHook.sol','QuorumIssuanceHook')
        permissions=call(addresses['hook'],h,'getHookPermissions')[0]
        expected=tuple(i in (0,2,6,7) for i in range(14))
        check('public_hook_permissions',tuple(permissions)==expected)
        check('hook_address_permission_bits',int(addresses['hook'],16)&((1<<14)-1)==0x28c0)
        core_art=artifact('QuorumBoundCore.sol','QuorumBoundCore');tr=artifact('QuorumTreasury.sol','QuorumTreasury')
        addresses['router']=create_child(addresses['hook'],1);addresses['quota']=create_child(addresses['hook'],2)
        for name in ('core','router','quota'):
            check('hook_binding_'+name,call(addresses['hook'],h,name)[0].lower()==addresses[name])
        for name in ('constitution','membership','treasury','work'):
            check('core_binding_'+name,call(addresses['core'],core_art,name)[0].lower()==addresses[name])
        registry=call(factory,f,'registry')[0];reg=artifact('LaunchRegistry.sol','LaunchRegistry')
        check('factory_registry_recorded',call(registry,reg,'isRecorded',[3000])[0])
        roles={role.rstrip(b'\0').decode():addr for role,name,addr in call(registry,reg,'artifactsOf',[3000])[0]}
        check('registry_token',roles['token'].lower()==addresses['token']);check('registry_hook',roles['hook'].lower()==addresses['hook'])
        addresses['distributor']=roles['distributor'];addresses['registry']=registry
        summary['addresses']=addresses
        summary['runtimeSha256']={}
        for name,address in addresses.items():
            code=raw(rpc('eth_getCode',[address,'latest']));check('runtime_'+name,0<len(code)<=24576)
            summary['runtimeSha256'][name]=hashlib.sha256(code).hexdigest()
        ca=artifact('ConstitutionPrototype.sol','ConstitutionPrototype')
        check('constitution_digest',call(addresses['constitution'],ca,'constitutionHash')[0].hex()==packet['constitutionSha256'])
        check('constitution_full_text',call(addresses['constitution'],ca,'text')[0]==(ROOT/'constitution.en.md').read_bytes())
        token_art=artifact('QuorumLaunchToken.sol','QuorumLaunchToken');mock=artifact('LocalFixtures.sol','LocalToken')
        check('full_supply',call(addresses['token'],token_art,'totalSupply')[0]==SUPPLY)
        check('fixed_name',call(addresses['token'],token_art,'name')[0]==config['name'])
        check('fixed_symbol',call(addresses['token'],token_art,'symbol')[0]==config['symbol'])
        check('fixed_imd',call(addresses['token'],token_art,'revenueToken')[0].lower()==imd.lower())
        check('fixed_stake_token',call(addresses['token'],token_art,'stakeAmount')[0]==int(config['stakeAmount']))
        membership_art=artifact('QuorumMembership.sol','QuorumMembership')
        check('fixed_stake_membership',call(addresses['membership'],membership_art,'stakeAmount')[0]==int(config['stakeAmount']))
        check('initial_distribution',call(addresses['token'],token_art,'balanceOf',[addresses['distributor']])[0]==SUPPLY//10)
        check('paired_seed_zero',call(imd,mock,'balanceOf',[manager])[0]==0)
        pool_tokens=call(addresses['token'],token_art,'balanceOf',[manager])[0]
        check('policy_seed_budget',0<pool_tokens<=SUPPLY*9//10)
        check('policy_seed_rounding',SUPPLY*9//10-pool_tokens<10**6)
        check('policy_tick_lower',call(factory,f,'positionOf',[3000])[1]==packet['poolFixture']['parameters']['tickLower'])
        check('policy_tick_upper',call(factory,f,'positionOf',[3000])[2]==packet['poolFixture']['parameters']['tickUpper'])
        summary['seededTokenMinorUnits']=str(pool_tokens)
        if a.payer_handover:
            check('initial_requester_is_payer',call(factory,f,'positionOf',[3000])[3].lower()==caller.lower())
            receipt=send('payer-hands-over-future-fees',factory,f,'setRequester',[3000,addresses['hook']])
            check('payer_handover_to_hook',call(factory,f,'positionOf',[3000])[3].lower()==addresses['hook'])
            summary['payerHandover']={'localOnly':True,'from':caller,'to':addresses['hook'],'transactionHash':receipt['transactionHash'],'beforeTrading':True}
        send('mint-local-imd',imd,mock,'mint',[caller,1030*10**18])
        send('approve-router-imd',imd,mock,'approve',[addresses['router'],1030*10**18])
        router_art=artifact('QuorumIssuanceHook.sol','QuorumSwapRouter')
        key=call(factory,f,'positionOf',[3000])[0];p0=int(addresses['token'],16)<int(imd,16)
        lo=4295128739+1;hi=1461446703485210103287273052203988822378723970342-1
        deadline=int(rpc('eth_getBlockByNumber',['latest',False])['timestamp'],16)+3600
        before=call(addresses['token'],token_art,'balanceOf',[caller])[0]
        buy=send('normal-buy',addresses['router'],router_art,'swap',[key,not p0,1000*10**18,1030*10**18,1,hi if p0 else lo,deadline])
        bought=call(addresses['token'],token_art,'balanceOf',[caller])[0]-before
        quota_art=artifact('QuotaPrototype.sol','QuotaPrototype')
        check('buy_credit_actual_received',call(addresses['quota'],quota_art,'available',[caller])[0]==bought and bought>0)
        check('buy_tax_atomic',call(imd,mock,'balanceOf',[addresses['treasury']])[0]==30*10**18)
        def traded(receipt):
            topic=hx(kh(b'Traded(address,uint256,uint256,uint256)'))
            logs=[log for log in receipt['logs'] if log['address'].lower()==addresses['router'] and log['topics'][0]==topic]
            check('one_trade_event_'+receipt['transactionHash'],len(logs)==1)
            check('trade_event_sender_'+receipt['transactionHash'],logs[0]['topics'][1][-40:]==caller[2:].lower())
            return decode(['uint256','uint256','uint256'],raw(logs[0]['data']))
        buy_paid,buy_received,buy_tax=traded(buy)
        check('buy_exact_tax',buy_tax==((buy_paid-buy_tax)*3+99)//100)
        check('buy_event_received',buy_received==bought)
        check('buy_total_payment',buy_paid==1030*10**18 and call(imd,mock,'balanceOf',[caller])[0]==0)
        check('buy_split_allowance',call(addresses['treasury'],tr,'allowancePool')[0]==15*10**18)
        check('buy_split_operating',call(addresses['treasury'],tr,'operatingFunds')[0]==15*10**18)
        sold=bought//2
        send('approve-router-token',addresses['token'],token_art,'approve',[addresses['router'],sold])
        sell=send('normal-sell',addresses['router'],router_art,'swap',[key,p0,sold,sold,1,lo if p0 else hi,deadline])
        check('sell_consumed_quota',call(addresses['quota'],quota_art,'available',[caller])[0]==bought-sold)
        sell_paid,sell_received,sell_tax=traded(sell)
        check('sell_exact_tax',sell_tax==((sell_received+sell_tax)*3+99)//100)
        check('sell_net_proceeds',call(imd,mock,'balanceOf',[caller])[0]==sell_received and sell_paid==sold)
        check('both_taxes_allowance',call(addresses['treasury'],tr,'allowancePool')[0]==buy_tax//2+sell_tax//2)
        check('both_taxes_operating',call(addresses['treasury'],tr,'operatingFunds')[0]==buy_tax-buy_tax//2+sell_tax-sell_tax//2)
        summary['trades']={'buy':{'paid':str(buy_paid),'received':str(buy_received),'projectTaxIMD':str(buy_tax)},
            'sell':{'paid':str(sell_paid),'received':str(sell_received),'projectTaxIMD':str(sell_tax)}}
        balance=call(imd,mock,'balanceOf',[addresses['treasury']])[0]
        check('sell_tax_accounted',call(addresses['treasury'],tr,'accountedBalance')[0]==balance and balance>30*10**18)
        check('router_no_tax_residue',call(imd,mock,'balanceOf',[addresses['router']])[0]==0)
        rpc('evm_increaseTime',[3601]);rpc('evm_mine')
        dist_art=artifact('MerkleDistributor.sol','MerkleDistributor')
        send('normal-original-claim',addresses['distributor'],dist_art,'claim',[0,claimant,SUPPLY//10,[]])
        send('normal-register-original',addresses['hook'],h,'registerOriginal',[3000,SUPPLY//10,[]],claimant)
        check('original_claim_balance',call(addresses['token'],token_art,'balanceOf',[claimant])[0]==SUPPLY//10)
        account=call(addresses['quota'],quota_art,'accounts',[claimant])
        check('original_registered',account[1]==SUPPLY//10 and account[-1])
        check('registration_is_not_unlock',call(addresses['quota'],quota_art,'available',[claimant])[1]==0)
        fee_recipient=call(fees,artifact('LaunchFees.sol','LaunchFees'),'feeRecipient')[0]
        currencies=[(addresses['token'],token_art),(imd,mock)]
        before_fees={asset:[call(asset,art,'balanceOf',[who])[0] for who in (addresses['treasury'],fee_recipient)] for asset,art in currencies}
        fee_receipt=send('normal-factory-fees-to-dao',addresses['hook'],h,'collectPlatformFees',[3000])
        claimed_topic=hx(kh(b'FeesClaimed(uint64,address,uint256,uint256)'))
        claimed=[log for log in fee_receipt['logs'] if log['address'].lower()==factory.lower() and log['topics'][0]==claimed_topic]
        check('one_factory_fee_event',len(claimed)==1)
        fee0,fee1=decode(['uint256','uint256'],raw(claimed[0]['data']))
        by_currency={key[0]:fee0,key[1]:fee1};fee_flows={}
        for asset,art in currencies:
            total=by_currency[asset.lower()];expected=total*8000//10000
            actual_requester=call(asset,art,'balanceOf',[addresses['treasury']])[0]-before_fees[asset][0]
            actual_network=call(asset,art,'balanceOf',[fee_recipient])[0]-before_fees[asset][1]
            check('lp_fee_requester_'+asset,actual_requester==expected and actual_requester>0)
            check('lp_fee_network_'+asset,actual_network==total-expected and actual_network>0)
            fee_flows[asset]={'total':str(total),'requester':str(actual_requester),'network':str(actual_network)}
        for asset,art in currencies:
            balance=call(asset,art,'balanceOf',[addresses['treasury']])[0]
            check('two_asset_ledger_'+asset,call(addresses['treasury'],tr,'accountedAssetBalance',[asset])[0]==balance)
            check('no_hook_fee_residue_'+asset,call(asset,art,'balanceOf',[addresses['hook']])[0]==0)
        check('immutable_fee_destination',call(factory,f,'positionOf',[3000])[3].lower()==addresses['hook'])
        summary['lpFees']=fee_flows
        summary['withinMainnetTransactionCap']=all(int(x['receipt']['gasUsed'],16)<=16777216 for x in receipts)
        summary.update({'complete':True,'transactionCount':len(receipts),'buyGas':int(buy['gasUsed'],16),'sellGas':int(sell['gasUsed'],16),
            'limitations':packet['unresolved']+['Mock IMD, local fixed stake/root and simulated claim time; cap math reconstructed from public policy/example, not private deployer source',
                'Local '+hardfork+' EVM; not a live-chain gas quote or admission approval'],
            'sourceSha256':packet['sourceSha256']})
    except Exception as error:
        summary['failure']=str(error)
        raise
    finally:
        proc.terminate()
        try:proc.wait(timeout=10)
        except subprocess.TimeoutExpired:proc.kill();proc.wait(timeout=5)
        with socket.socket() as sock:summary['portClosed']=sock.connect_ex(('127.0.0.1',port))!=0
        summary['processExited']=proc.poll() is not None
        save(directory/'summary.json',summary)
        print(json.dumps({k:summary.get(k) for k in ('complete','factoryLaunchReceiptGas','transactionCount','portClosed','processExited')}),flush=True)
if __name__=='__main__':main()
