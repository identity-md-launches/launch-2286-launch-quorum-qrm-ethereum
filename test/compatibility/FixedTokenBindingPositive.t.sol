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
import {LaunchFactory,MerkleDistributor} from "../positive/ExternalInterfaces.sol";
import {QuorumToken} from "../../src/QuorumToken.sol";
interface FixedBindingVm { function etch(address,bytes calldata) external; function getNonce(address) external view returns(uint64); function getCode(string calldata) external view returns(bytes memory); function parseBytes(string calldata) external pure returns(bytes memory); function warp(uint256) external; function prank(address) external; function readFile(string calldata) external view returns(string memory); function roll(uint256) external; function setBlockhash(uint256,bytes32) external; }
/// Local-only zero-argument candidate rehearsal: dependency code is staged at configured addresses.
/// This proves composition wiring, not live prerequisite deployment or platform acceptance.
/// Uses unchanged real external bytecode with a predeployed immutable core; token/pool factory launch stays atomic.
contract FixedTokenBindingPositiveTest {
    FixedBindingVm constant vm=FixedBindingVm(address(uint160(uint256(keccak256("hevm cheat code")))));
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
        LocalToken imdFixture=new LocalToken();
        address imdAddress=address(bytes20(hex"d34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7"));
        vm.etch(imdAddress,address(imdFixture).code);imd=LocalToken(imdAddress);
        ConstitutionPrototype constitution=new ConstitutionPrototype(bytes(vm.readFile("constitution.en.md")));
        address constitutionAddress=address(bytes20(hex"48a78afb5397abeab5be23473973c5c62497cf55"));
        vm.etch(constitutionAddress,address(constitution).code);constitution=ConstitutionPrototype(constitutionAddress);
        bytes memory coreCreation=vm.getCode("QuorumBoundCore.sol:QuorumBoundCore");
        bytes memory first=new bytes(24000);bytes memory second=new bytes(coreCreation.length-24000);
        for(uint256 i;i<coreCreation.length;++i){if(i<24000)first[i]=coreCreation[i];else second[i-24000]=coreCreation[i];}
        QuorumCoreCode catalog=new QuorumCoreCode(first,second,keccak256(coreCreation));
        address pendingCode=address(bytes20(hex"5f8c721d44d5815ae9e6d54ff20e717d56ec0d91"));
        vm.etch(pendingCode,address(catalog).code);
        require(QuorumCoreCode(pendingCode).creationHash()==keccak256(coreCreation),"new code package pinned");
        bytes memory tokenCode=type(QuorumToken).creationCode;
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
    function testNormalZeroArgumentCandidateBinding() public view {
        require(address(token.coreCode())==address(bytes20(hex"5f8c721d44d5815ae9e6d54ff20e717d56ec0d91")),"fixed planned production dependency binding");
        require(keccak256(bytes(token.name()))==keccak256("QUORUM"));
        require(keccak256(bytes(token.symbol()))==keccak256("QRM"));
        require(token.stakeAmount()==62_500 ether);
        require(address(core.treasury().asset())==token.revenueToken());
        require(address(core.constitution())==address(token.constitution()));
    }
}
