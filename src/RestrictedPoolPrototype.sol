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

interface PlainToken {
    function transferFrom(address,address,uint256) external returns(bool);
}

/// Local integration prototype. Only plain ERC20 pairs, exact input, self recipient.
/// Not a mainnet release; factory seeding and the eligibility engine remain integration gates.
contract RestrictedPoolPrototype {
    IPoolManager public immutable manager;
    address public immutable project;
    address public immutable paired;
    address public immutable seeder;
    AuthenticatedRouterPrototype public immutable router;
    QuotaPrototype public immutable quota;
    bool public initialized;

    constructor(IPoolManager m,address token,address imd,address seed,address treasury,address eligibility) {
        require(address(m)!=address(0) && token!=address(0) && imd!=address(0) && token!=imd
            && seed!=address(0) && treasury!=address(0),"configuration");
        manager=m; project=token; paired=imd; seeder=seed;
        Hooks.Permissions memory p;
        p.beforeInitialize=true; p.beforeAddLiquidity=true; p.beforeSwap=true; p.afterSwap=true;
        Hooks.validateHookPermissions(IHooks(address(this)),p);
        router=new AuthenticatedRouterPrototype(m,address(this),token,imd,treasury);
        quota=new QuotaPrototype(address(this),eligibility);
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

contract AuthenticatedRouterPrototype {
    IPoolManager public immutable manager;
    address public immutable hook;
    address public immutable project;
    address public immutable paired;
    address public immutable treasury;
    address public activeTrader;
    struct Request {
        PoolKey key;
        SwapParams params;
        uint256 maxPayment;
        uint256 minReceive;
    }
    event Traded(address indexed trader,uint256 paid,uint256 received,uint256 projectTax);
    constructor(IPoolManager m,address h,address p,address i,address t) {
        manager=m; hook=h; project=p; paired=i; treasury=t;
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
        if(buy) require(PlainToken(paired).transferFrom(activeTrader,treasury,tax),"tax payment");
        emit Traded(activeTrader,paid,received,tax);
        return abi.encode(delta);
    }
    function _settle(Currency currency,int128 delta,bool buy,uint256 tax) private {
        if(delta<0) {
            manager.sync(currency);
            require(PlainToken(Currency.unwrap(currency)).transferFrom(activeTrader,address(manager),
                uint256(-int256(delta))),"payment");
            manager.settle();
        } else if(delta>0) {
            uint256 amount=uint128(delta);
            if(!buy && Currency.unwrap(currency)==paired) {
                manager.take(currency,treasury,tax);
                amount-=tax;
            }
            manager.take(currency,activeTrader,amount);
        }
    }
}

