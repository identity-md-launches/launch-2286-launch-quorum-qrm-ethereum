// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {QuotaPrototype} from "./QuotaPrototype.sol";

import {QuorumBoundCore} from "./QuorumBoundCore.sol";
import {QuorumTreasury} from "./QuorumTreasury.sol";
import {IERC20Local, QuorumMembership} from "./QuorumMembership.sol";
import {QuorumLaunchToken} from "./QuorumLaunchToken.sol";
import {ImdLaunchProof} from "./ImdLaunchProof.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IFactoryFeeSource {
    function claimFees(uint64 launchNumber) external returns(uint256,uint256);
    function positionOf(uint64 launchNumber) external view returns(PoolKey memory,int24,int24,address);
}

/// Issuance composition candidate: factory -> hook -> immutable core/router/quota.
/// NOT release ready: final platform admission and the complete candidate remain unverified.
/// Fixed stake is pinned by the token; original allocations use the later factory Merkle root.
/// Only plain ERC20 pairs, exact input and self-recipient settlement are supported.
contract QuorumIssuanceHook {
    using SafeERC20 for IERC20;
    IPoolManager public immutable manager;
    address public immutable project;
    address public immutable paired;
    address public immutable seeder;
    QuorumSwapRouter public immutable router;
    QuotaPrototype public immutable quota;
    bool public initialized;
    QuorumBoundCore public immutable core;

    constructor(IPoolManager m,address token) {
        QuorumLaunchToken config=QuorumLaunchToken(token);
        address imd=config.revenueToken();
        require(address(m)!=address(0) && token!=imd,"configuration");
        manager=m; project=token; paired=imd; seeder=msg.sender;
        Hooks.validateHookPermissions(IHooks(address(this)),getHookPermissions());
        core=config.coreCode().create(token,imd,config.stakeAmount(),config.constitution());
        require(core.treasury().rewardReporter()==address(this),"fixed hook");
        router=new QuorumSwapRouter(m,address(this),token,imd,core.treasury());
        quota=new QuotaPrototype(address(this),address(this));
        IERC20(token).forceApprove(address(core.treasury()),type(uint256).max);
        IERC20(imd).forceApprove(address(core.treasury()),type(uint256).max);
    }
    /// Public protocol declaration shares the constructor's exact permission definition.
    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize=true;p.beforeAddLiquidity=true;p.beforeSwap=true;p.afterSwap=true;
    }
    /// Stores only the original wallet's factory-authenticated allocation. Does not unlock it.
    function registerOriginal(uint64 launchNumber,uint256 amount,bytes32[] calldata proof) external {
        bytes32 root=ImdLaunchProof.original(seeder,launchNumber,project,address(this),msg.sender,amount,proof);
        bytes32 entitlement=keccak256(abi.encode(seeder,project,launchNumber,root,msg.sender));
        quota.register(msg.sender,entitlement,amount);
    }
    /// Anyone may relay a settled qualified week; no relayer can choose a different beneficiary.
    /// The quota ledger counts each wallet/week once, even across key changes and re-enrollment.
    function countQualifiedWeek(uint256 enrollmentId,uint256 week) external {
        QuorumTreasury funds=core.treasury();
        require(funds.settled(week) && funds.isQualified(week,enrollmentId),"settled qualified week");
        QuorumMembership.Enrollment memory e=core.membership().enrollment(enrollmentId);
        quota.qualify(e.owner,week);
    }
    /// Only the constructor-bound treasury can attest a payment; transfers alone grant nothing.
    function rewardPaid(address recipient,uint256 amount) external {
        require(msg.sender==address(core.treasury()),"treasury only");
        quota.retireOrganizationBought(address(core.treasury().operatingAccount()),amount);
        quota.recordEarned(recipient,amount);
    }
    function openOperatingQuota(uint256 projectBudget) external {
        require(msg.sender==address(core.treasury()),"treasury only");
        quota.openOrganizationBudget(address(core.treasury().operatingAccount()),projectBudget);
    }
    function closeOperatingQuota(uint256 returnedProject) external {
        require(msg.sender==address(core.treasury()),"treasury only");
        quota.closeOrganizationBudget(address(core.treasury().operatingAccount()),returnedProject);
    }
    /// Fixed fee recipient with no requester-transfer or arbitrary-call facility.
    /// A caller pays gas only; it cannot select a treasury or payment destination.
    function collectPlatformFees(uint64 launchNumber) external {
        ImdLaunchProof.resolve(seeder,launchNumber,project,address(this));
        (,,,address recipient)=IFactoryFeeSource(seeder).positionOf(launchNumber);
        require(recipient==address(this),"fee destination not bound");
        IFactoryFeeSource(seeder).claimFees(launchNumber);
        flushRevenue();
    }
    /// Also accounts fees collected directly at the factory and plain donations.
    function flushRevenue() public {
        QuorumTreasury funds=core.treasury();
        uint256 imdAmount=IERC20(paired).balanceOf(address(this));
        uint256 projectAmount=IERC20(project).balanceOf(address(this));
        if(imdAmount>0)funds.depositRevenue(imdAmount);
        if(projectAmount>0)funds.depositAssetRevenue(project,projectAmount);
    }
    function _check(PoolKey calldata key) internal view {
        require(msg.sender==address(manager),"manager only");
        require(address(key.hooks)==address(this) && key.fee==12500 && key.tickSpacing==60,"pool policy");
        require(Currency.unwrap(key.currency0)==(project<paired?project:paired)
            && Currency.unwrap(key.currency1)==(project<paired?paired:project),"pair");
    }
    function beforeInitialize(address sender,PoolKey calldata key,uint160) external returns(bytes4) {
        _check(key);
        require(sender==seeder && !initialized,"initialization");
        initialized=true;
        return IHooks.beforeInitialize.selector;
    }
    function _liquidityAllowed(address sender) internal view virtual returns(bool) {
        return sender==seeder;
    }
    function beforeAddLiquidity(address sender,PoolKey calldata key,ModifyLiquidityParams calldata,bytes calldata)
        external view returns(bytes4) {
        _check(key);
        require(_liquidityAllowed(sender),"new LP restricted");
        return IHooks.beforeAddLiquidity.selector;
    }
    function beforeSwap(address sender,PoolKey calldata key,SwapParams calldata params,bytes calldata)
        external view returns(bytes4,BeforeSwapDelta,uint24) {
        _check(key);
        require(sender==address(router) && router.activeTrader()!=address(0),"authenticated router only");
        require(params.amountSpecified<0,"exact input only");
        return (IHooks.beforeSwap.selector,BeforeSwapDelta.wrap(0),0);
    }
    function afterSwap(address sender,PoolKey calldata key,SwapParams calldata,BalanceDelta delta,bytes calldata)
        external returns(bytes4,int128) {
        _check(key);
        require(sender==address(router),"router only");
        address trader=router.activeTrader();
        require(trader!=address(0),"no active trader");
        int128 tokenDelta=project<paired?delta.amount0():delta.amount1();
        if(tokenDelta>0) quota.recordBuy(trader,uint128(tokenDelta));
        else if(tokenDelta<0) quota.consume(trader,uint256(-int256(tokenDelta)));
        return (IHooks.afterSwap.selector,0);
    }
}

contract QuorumSwapRouter {
    using SafeERC20 for IERC20;
    IPoolManager public immutable manager;
    address public immutable hook;
    address public immutable project;
    address public immutable paired;
    QuorumTreasury public immutable treasury;
    address public activeTrader;
    struct Request {
        PoolKey key;
        SwapParams params;
        uint256 maxPayment;
        uint256 minReceive;
    }
    event Traded(address indexed trader,uint256 paid,uint256 received,uint256 projectTax);
    constructor(IPoolManager m,address h,address p,address i,QuorumTreasury t) {
        manager=m; hook=h; project=p; paired=i; treasury=t;
        require(address(t.asset())==i,"revenue asset");
        IERC20(i).forceApprove(address(t),type(uint256).max);
    }
    // poolInput is the AMM input budget, NOT the user's total cost on a buy.
    // maxPayment bounds actual pool input plus project tax. No external recipient.
    function swap(PoolKey calldata key,bool zeroForOne,uint128 poolInput,uint256 maxPayment,
        uint256 minReceive,uint160 priceLimit,uint256 deadline) external returns(BalanceDelta delta) {
        require(block.timestamp<=deadline && poolInput>0,"deadline or amount");
        require(activeTrader==address(0),"reentrant");
        require(address(key.hooks)==hook,"wrong hook");
        activeTrader=msg.sender;
        Request memory r=Request(key,SwapParams(zeroForOne,-int256(uint256(poolInput)),priceLimit),maxPayment,minReceive);
        delta=abi.decode(manager.unlock(abi.encode(r)),(BalanceDelta));
        activeTrader=address(0);
    }
    function unlockCallback(bytes calldata raw) external returns(bytes memory) {
        require(msg.sender==address(manager) && activeTrader!=address(0),"callback");
        Request memory r=abi.decode(raw,(Request));
        BalanceDelta delta=manager.swap(r.key,r.params,bytes(""));
        int256 td=project<paired?int256(delta.amount0()):int256(delta.amount1());
        int256 id=project<paired?int256(delta.amount1()):int256(delta.amount0());
        require((td>0 && id<0)||(td<0 && id>0),"empty trade");
        bool buy=td>0;
        uint256 imdAmount=uint256(buy?-id:id);
        uint256 tax=(imdAmount*3+99)/100; // ceil 3% of actual AMM-side IMD delta.
        uint256 paid=buy?imdAmount+tax:uint256(-td);
        uint256 received=buy?uint256(td):imdAmount-tax;
        require(paid<=r.maxPayment && received>=r.minReceive,"price bounds");
        _settle(r.key.currency0,delta.amount0(),buy,tax);
        _settle(r.key.currency1,delta.amount1(),buy,tax);
        if(buy) IERC20(paired).safeTransferFrom(activeTrader,address(this),tax);
        treasury.depositRevenue(tax); // Tax receipt and 50/50 accounting are one atomic swap transaction.
        emit Traded(activeTrader,paid,received,tax);
        return abi.encode(delta);
    }
    function _settle(Currency currency,int128 delta,bool buy,uint256 tax) private {
        if(delta<0) {
            manager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransferFrom(activeTrader,address(manager),uint256(-int256(delta)));
            manager.settle();
        } else if(delta>0) {
            uint256 amount=uint128(delta);
            if(!buy && Currency.unwrap(currency)==paired) {
                manager.take(currency,address(this),tax);
                amount-=tax;
            }
            manager.take(currency,activeTrader,amount);
        }
    }
}

