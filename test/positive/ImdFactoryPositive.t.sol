// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {IPoolManager as PoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {ConstitutionPrototype} from "../../src/ConstitutionPrototype.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {QuorumIssuanceHook,QuorumSwapRouter} from "../../src/QuorumIssuanceHook.sol";
import {LocalToken} from "../../src/LocalFixtures.sol";
import {QuorumBoundCore} from "../../src/QuorumBoundCore.sol";
import {QuorumMembership} from "../../src/QuorumMembership.sol";
import {QuorumTreasury} from "../../src/QuorumTreasury.sol";
import {QuorumWork} from "../../src/QuorumWork.sol";
import {IERC20Local} from "../../src/QuorumMembership.sol";
import {QuorumCoreCode} from "../../src/QuorumCoreCode.sol";
import {QuorumLaunchToken} from "../../src/QuorumLaunchToken.sol";
import {ImdLaunchProof} from "../../src/ImdLaunchProof.sol";
import {LaunchFactory,MerkleDistributor} from "./ExternalInterfaces.sol";
interface FactoryPositiveVm { function getNonce(address) external view returns(uint64); function getCode(string calldata) external view returns(bytes memory); function parseBytes(string calldata) external pure returns(bytes memory); function warp(uint256) external; function prank(address) external; function readFile(string calldata) external view returns(string memory); function roll(uint256) external; function setBlockhash(uint256,bytes32) external; }
/// Only positive normal factory/proof/seed/claim/trade/fee-collection paths. No bypass scenarios.
/// Uses unchanged real external bytecode with a predeployed immutable core; token/pool factory launch stays atomic.
contract ImdFactoryPositiveTest {
    FactoryPositiveVm constant vm=FactoryPositiveVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address constant AIRDROP=address(0xA11CE);
    uint64 constant NUMBER=3000;
    uint160 constant FLAGS=(1<<13)|(1<<11)|(1<<7)|(1<<6);
    PoolManager manager;
    LaunchFactory factory;
    LocalToken imd;
    QuorumLaunchToken token;
    QuorumIssuanceHook hook;
    MerkleDistributor distributor;
    PoolKey key;
    QuorumBoundCore core;
    uint256 deploymentGas;
    uint256 hookInitcodeBytes;
    event log_named_uint(string key,uint256 value);
    address[7] owners;
    address[7] agents;
    uint256 firstWeek;
    function deployExternal(string memory name,bytes memory args) internal returns(address created) {
        bytes memory code=abi.encodePacked(vm.getCode(string.concat("fixtures/external-build/out/",name,".sol/",name,".json")),args);
        assembly ("memory-safe") { created:=create(0,add(code,32),mload(code)) }
        require(created!=address(0),"external fixture deploy");
    }
    function nextCreate() internal view returns(address) {
        uint64 nonce=vm.getNonce(address(this));require(nonce>0 && nonce<128,"fixture nonce");
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"d694",address(this),bytes1(uint8(nonce)))))));
    }
    function setUp() public {
        vm.warp(4 days+200*7 days);
        manager=PoolManager(deployExternal("PoolManager",abi.encode(address(this))));
        address fees=deployExternal("LaunchFees",abi.encode(address(this),address(0xBEEF),address(0xCAFE),uint24(12500)));
        factory=LaunchFactory(deployExternal("LaunchFactory",abi.encode(manager,address(this),fees)));
        imd=new LocalToken();
        ConstitutionPrototype constitution=new ConstitutionPrototype(bytes(vm.readFile("constitution.en.md")));
        bytes memory coreCreation=vm.getCode("QuorumBoundCore.sol:QuorumBoundCore");
        bytes memory first=new bytes(24000);bytes memory second=new bytes(coreCreation.length-24000);
        for(uint256 i;i<coreCreation.length;++i){if(i<24000)first[i]=coreCreation[i];else second[i-24000]=coreCreation[i];}
        QuorumCoreCode catalog=new QuorumCoreCode(first,second,keccak256(coreCreation));
        bytes memory tokenCode=abi.encodePacked(type(QuorumLaunchToken).creationCode,
            abi.encode("QUORUM Local Candidate","LOCAL",address(imd),uint256(62_500 ether),address(catalog),address(constitution)));
        require(tokenCode.length<=49152,"token initcode size");
        address predictedToken=factory.predictToken(NUMBER,tokenCode);
        bytes memory hookCode=abi.encodePacked(type(QuorumIssuanceHook).creationCode,
            abi.encode(manager,predictedToken));
        hookInitcodeBytes=hookCode.length;require(hookCode.length<=49152,"EIP3860 initcode size");
        bytes32 hash=keccak256(hookCode); bytes32 salt;
        for(uint256 n;;++n){
            address a=address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff),address(factory),bytes32(n),hash)))));
            if(uint160(a)&((1<<14)-1)==FLAGS){salt=bytes32(n);break;}
        }
        LaunchFactory.LaunchParams memory p;
        p.launchNumber=NUMBER;p.kind=bytes32("univ4_hook");p.tokenCreationCode=tokenCode;p.hookCreationCode=hookCode;
        p.hookSalt=salt;p.hookFlags=FLAGS;p.totalSupply=1_000_000_000 ether;p.poolBps=9000;p.remainderTo=address(this);
        p.merkleRoot=ImdLaunchProof.leaf(AIRDROP,100_000_000 ether);p.contributorLockSeconds=3600;p.sweepDelaySeconds=365 days;
        p.pairedCurrency=Currency.wrap(address(imd));p.fee=12500;p.tickSpacing=60;p.sqrtPriceX96=uint160(1<<96);
        bool project0=predictedToken<address(imd);
        p.tickLower=project0?int24(0):int24(-887220);p.tickUpper=project0?int24(887220):int24(0);
        p.liquidity=700_000_000 ether;p.record.sourceRepoUrl="local-positive-fixture";p.requester=factory.predictHook(hookCode,salt);
        uint256 gasBefore=gasleft();
        (address t,address h,address d)=factory.launch(p);
        deploymentGas=gasBefore-gasleft();
        token=QuorumLaunchToken(t);hook=QuorumIssuanceHook(h);distributor=MerkleDistributor(d);core=hook.core();
        (key,,,)=factory.positionOf(NUMBER);
        require(t==predictedToken && h==factory.predictHook(hookCode,salt));
    }
    function testNormalAtomicFactorySeedRecordProofAndClaim() public {
        emit log_named_uint("factory_launch_execution_gas",deploymentGas);
        require(deploymentGas<16_000_000,"factory execution headroom");
        require(core.treasury().rewardReporter()==address(hook),"constructor binds actual hook");
        emit log_named_uint("hook_initcode_with_arguments_bytes",hookInitcodeBytes);
        require(factory.registry().isRecorded(NUMBER) && hook.initialized());
        require(hook.seeder()==address(factory) && address(core.membership().token())==address(token));
        require(address(core.treasury().asset())==address(imd) && address(hook.router().treasury())==address(core.treasury()));
        require(core.constitution().constitutionHash()==sha256(bytes(vm.readFile("constitution.en.md"))));
        require(address(hook).code.length<=24576 && address(core).code.length<=24576 && address(core.membership()).code.length<=24576
            && address(core.treasury()).code.length<=24576 && address(core.work()).code.length<=24576 && address(hook.router()).code.length<=24576);

        require(token.balanceOf(address(distributor))==100_000_000 ether);
        require(imd.balanceOf(address(factory))==0 && imd.balanceOf(address(manager))==0);
        require(token.balanceOf(address(manager))>0 && token.balanceOf(address(manager))<=900_000_000 ether);
        require(address(ImdLaunchProof.resolve(address(factory),NUMBER,address(token),address(hook)))==address(distributor));
        bytes32 root=ImdLaunchProof.original(address(factory),NUMBER,address(token),address(hook),AIRDROP,100_000_000 ether,new bytes32[](0));
        require(root==distributor.roundOf(0).root);
        vm.warp(block.timestamp+3600);distributor.claim(0,AIRDROP,100_000_000 ether,new bytes32[](0));
        require(token.balanceOf(AIRDROP)==100_000_000 ether && distributor.claimed(0,AIRDROP));
        vm.prank(AIRDROP);hook.registerOriginal(NUMBER,100_000_000 ether,new bytes32[](0));
        (,uint256 grant,,,bool registered)=hook.quota().accounts(AIRDROP);
        require(registered && grant==100_000_000 ether); // Registration is not qualification or an unlock.

    }
    function testNormalBuySellAndFactoryFeeCollection() public {
        QuorumSwapRouter r=hook.router();
        imd.mint(address(this),10_000 ether);imd.approve(address(r),type(uint256).max);token.approve(address(r),type(uint256).max);
        bool project0=address(token)<address(imd);
        uint256 beforeBalance=token.balanceOf(address(this));
        r.swap(key,!project0,1000 ether,1030 ether,1,project0?TickMath.MAX_SQRT_PRICE-1:TickMath.MIN_SQRT_PRICE+1,block.timestamp);
        uint256 received=token.balanceOf(address(this))-beforeBalance;
        (uint256 bought,)=hook.quota().available(address(this));
        require(bought==received && received>0 && imd.balanceOf(address(core.treasury()))==30 ether);
        uint256 sold=received/2;
        r.swap(key,project0,uint128(sold),sold,1,project0?TickMath.MIN_SQRT_PRICE+1:TickMath.MAX_SQRT_PRICE-1,block.timestamp);
        (bought,)=hook.quota().available(address(this));require(bought==received-sold);
        uint256 tax=imd.balanceOf(address(core.treasury()));
        require(tax>30 ether && imd.balanceOf(address(r))==0);
        require(core.treasury().allowancePool()==tax/2 && core.treasury().operatingFunds()==tax-tax/2);
        require(core.treasury().scheduled(core.membership().currentWeek()+1)==tax/2);
        require(core.treasury().accountedBalance()==tax);
        (uint256 fee0,uint256 fee1)=factory.claimFees(NUMBER);
        require(fee0>0 || fee1>0); // Normal collection remains compatible with restricted new liquidity.
    }
    function testNormalLaunchTaxFundsQualifiedMembersAndAcceptedWork() public {
        QuorumMembership m=core.membership();QuorumTreasury f=core.treasury();QuorumWork w=core.work();
        vm.warp(block.timestamp+3600);
        distributor.claim(0,AIRDROP,100_000_000 ether,new bytes32[](0));
        vm.prank(AIRDROP);hook.registerOriginal(NUMBER,100_000_000 ether,new bytes32[](0));
        firstWeek=m.currentWeek();
        for(uint256 i;i<7;++i){
            owners[i]=i==0?AIRDROP:address(uint160(0x1000+i));agents[i]=address(uint160(0x2000+i));
            token.transfer(owners[i],m.stakeAmount());
            uint256 amount=m.stakeAmount();vm.prank(owners[i]);token.approve(address(m),amount);
            vm.prank(owners[i]);m.authorize(agents[i],block.timestamp+365 days);
            bytes32 digest=m.constitutionHash();vm.prank(agents[i]);require(m.accept(owners[i],1,digest)==i);
        }
        QuorumSwapRouter r=hook.router();imd.mint(address(this),1030 ether);imd.approve(address(r),1030 ether);
        bool project0=address(token)<address(imd);
        r.swap(key,!project0,1000 ether,1030 ether,1,project0?TickMath.MAX_SQRT_PRICE-1:TickMath.MIN_SQRT_PRICE+1,block.timestamp);
        require(f.operatingFunds()==15 ether && f.allowancePool()==15 ether);
        maintainUntil(m.weekStart(firstWeek+3));
        require(f.qualifiedCount(firstWeek+1)==7 && f.qualifiedCount(firstWeek+2)==7);
        hook.countQualifiedWeek(0,firstWeek+1);
        require(hook.quota().unlocked(AIRDROP)==0);
        hook.countQualifiedWeek(0,firstWeek+2);
        require(hook.quota().unlocked(AIRDROP)==25_000_000 ether);
        uint256 expectedWage=uint256(15 ether)/7;f.claimAllowance(firstWeek+1,0);
        require(imd.balanceOf(owners[0])==expectedWage);
        vm.prank(agents[0]);uint256 id=w.propose(0,0,owners[0],1 ether,block.timestamp+30 days,
            "Local integration fixture: deliver the fixed deployment manifest and receipt checks; acceptance requires their committed digest. No actual model labor is claimed.");
        w.prepareBallot(id,32);for(uint256 i=1;i<=5;++i){vm.prank(agents[i]);w.vote(id,i,true);}
        maintainUntil(w.ballot(w.work(id).ballot).started+120 hours);w.fund(id);
        require(f.reservedWork()==1 ether && f.operatingFunds()==14 ether);
        vm.prank(agents[0]);w.submit(id,"Local integration fixture delivered; production admission and autonomous labor remain unproven.");
        w.prepareBallot(id,32);for(uint256 i=1;i<=5;++i){vm.prank(agents[i]);w.vote(id,i,true);}
        maintainUntil(w.ballot(w.work(id).ballot).started+120 hours);w.accept(id);w.claim(id);
        require(w.work(id).stage==QuorumWork.Stage.Paid && imd.balanceOf(owners[0])==expectedWage+1 ether);
        require(f.reservedWork()==0 && f.earnedWork()==0 && imd.balanceOf(address(f))==f.accountedBalance());
        require(token.balanceOf(address(m))==7*m.stakeAmount());
    }
    function testNormalPlatformFeesReachTwoAssetTreasury() public {
        testNormalBuySellAndFactoryFeeCollection();
        uint256 pairedFees=imd.balanceOf(address(hook));uint256 projectFees=token.balanceOf(address(hook));
        require(pairedFees>0 && projectFees>0);
        QuorumTreasury f=core.treasury();uint256 beforePrimary=f.accountedBalance();
        uint256 primaryAllowances=f.allowancePool();uint256 primaryOperations=f.operatingFunds();
        hook.collectPlatformFees(NUMBER);
        require(imd.balanceOf(address(hook))==0 && token.balanceOf(address(hook))==0);
        require(f.accountedBalance()==beforePrimary+pairedFees);
        require(f.allowancePool()==primaryAllowances+pairedFees/2);
        require(f.operatingFunds()==primaryOperations+pairedFees-pairedFees/2);
        QuorumTreasury.Ledger memory l=f.ledger(address(token));
        require(l.allowancePool==projectFees/2 && l.operatingFunds==projectFees-projectFees/2);
        require(f.accountedAssetBalance(address(token))==projectFees);
        require(token.balanceOf(address(f))==projectFees);
    }
    function testNormalTwoAssetAllowanceWorkRewardAndSale() public {
        testNormalLaunchTaxFundsQualifiedMembersAndAcceptedWork();
        QuorumMembership m=core.membership();QuorumTreasury f=core.treasury();QuorumWork w=core.work();
        uint256 incomeWeek=m.currentWeek();uint256 primaryBefore=f.accountedBalance();
        token.approve(address(f),140 ether+1);f.depositAssetRevenue(address(token),140 ether+1);
        require(f.accountedBalance()==primaryBefore && f.accountedAssetBalance(address(token))==140 ether+1);
        QuorumTreasury.Ledger memory l=f.ledger(address(token));
        require(l.operatingFunds==70 ether+1 && l.allowancePool==70 ether);
        maintainUntil(m.weekStart(incomeWeek+2));
        uint256 balanceBefore=token.balanceOf(owners[1]);f.claimAllowance(incomeWeek+1,1);
        require(token.balanceOf(owners[1])-balanceBefore==10 ether);
        require(hook.quota().earnedRewards(owners[1])==10 ether);
        vm.prank(agents[0]);uint256 id=w.proposeAsset(0,0,owners[0],address(token),3 ether,block.timestamp+30 days,
            "Normal fixture: deliver and accept a project-token-funded operating guide.");
        w.prepareBallot(id,32);for(uint256 i=1;i<=5;++i){vm.prank(agents[i]);w.vote(id,i,true);}
        maintainUntil(w.ballot(w.work(id).ballot).started+120 hours);w.fund(id);
        l=f.ledger(address(token));require(l.reservedWork==3 ether && l.operatingFunds==67 ether+1);
        vm.prank(agents[0]);w.submit(id,"Normal fixture delivery: versioned guide and test receipt digest.");
        w.prepareBallot(id,32);for(uint256 i=1;i<=5;++i){vm.prank(agents[i]);w.vote(id,i,true);}
        maintainUntil(w.ballot(w.work(id).ballot).started+120 hours);w.accept(id);
        require(hook.quota().earnedRewards(owners[0])==0); // Acceptance alone is not payment.
        balanceBefore=token.balanceOf(owners[0]);w.claim(id);
        require(token.balanceOf(owners[0])-balanceBefore==3 ether && hook.quota().earnedRewards(owners[0])==3 ether);
        QuorumSwapRouter router=hook.router();vm.prank(owners[1]);token.approve(address(router),1 ether);
        bool project0=address(token)<address(imd);uint256 beforeImd=imd.balanceOf(owners[1]);
        vm.prank(owners[1]);router.swap(key,project0,1 ether,1 ether,1,
            project0?TickMath.MIN_SQRT_PRICE+1:TickMath.MAX_SQRT_PRICE-1,block.timestamp);
        require(imd.balanceOf(owners[1])>beforeImd && hook.quota().earnedRewards(owners[1])==9 ether);
        require(token.balanceOf(address(f))==f.accountedAssetBalance(address(token)));
        require(imd.balanceOf(address(f))==f.accountedBalance());
        require(token.balanceOf(address(m))==7*m.stakeAmount());
    }
    function maintainUntil(uint256 target) private {
        QuorumMembership m=core.membership();QuorumTreasury f=core.treasury();
        uint256 next=(block.timestamp/1 hours+1)*1 hours;
        while(next<=target){
            vm.warp(next);vm.roll(block.number+1);uint256 week=m.currentWeek();
            if(week>firstWeek && !f.settled(week-1)) f.settleWeek(week-1,32);
            uint256 hour=(block.timestamp-m.weekStart(week))/1 hours;
            bytes32 anchor=keccak256(abi.encode(block.number-1));vm.setBlockhash(block.number-1,anchor);
            for(uint256 i;i<7;++i){
                uint256 revision=core.agendaRevisionAt(block.number - 1);vm.prank(agents[i]);
                m.respond(i,block.number-1,anchor,revision,"Local positive integration: checked agenda; simulated clock, not real continuous operation.");
                if(hour==125){vm.prank(agents[i]);m.report(i,"Local positive integration weekly report, no real-work quality claim.");}
            }
            next+=1 hours;
        }
        vm.warp(target);
    }

}
