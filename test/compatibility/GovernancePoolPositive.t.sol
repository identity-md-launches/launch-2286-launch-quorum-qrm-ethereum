// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {ImdFactoryPositiveTest} from "../positive/ImdFactoryPositive.t.sol";
import {QuorumMembership} from "../../src/QuorumMembership.sol";
import {QuorumTreasury} from "../../src/QuorumTreasury.sol";
import {QuorumWork} from "../../src/QuorumWork.sol";
import {QuorumIssuanceHook,QuorumSwapRouter} from "../../src/QuorumIssuanceHook.sol";
import {OperatingPlan,OperatingApproval,OperatingCall} from "../../src/QuorumOperatingAccount.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20Local} from "../../src/QuorumMembership.sol";
contract BudgetedTaskService {
    IERC20Local public immutable payment;
    uint256 public price;
    bool public completed;
    constructor(IERC20Local token){payment=token;}
    function setPrice(uint256 amount) external {price=amount;}
    function completeTask() external {
        require(payment.transferFrom(msg.sender,address(this),price),"task payment");
        completed=true;
    }
}
interface OperationLogsVm {
    struct Log { bytes32[] topics; bytes data; address emitter; }
    function recordLogs() external;
    function getRecordedLogs() external returns(Log[] memory);
}
contract NormalOperationService {
    bool public available;
    function setAvailable(bool value) external { available=value; }
    function confirm() external view { require(available,"service temporarily unavailable"); }
}
/// Real factory/pool plus actual member authorization, qualification, budget vote and execution.
/// Local positive workflows and ordinary unavailable-service recovery only.
contract GovernancePoolPositiveTest is ImdFactoryPositiveTest {
    function testNormalManifestPermissionsMatchConstructor() public view {
        Hooks.Permissions memory p=hook.getHookPermissions();
        require(p.beforeInitialize && p.beforeAddLiquidity && p.beforeSwap && p.afterSwap,"required flags");
        require(!p.afterInitialize && !p.afterAddLiquidity && !p.beforeRemoveLiquidity && !p.afterRemoveLiquidity
            && !p.beforeDonate && !p.afterDonate && !p.beforeSwapReturnDelta && !p.afterSwapReturnDelta
            && !p.afterAddLiquidityReturnDelta && !p.afterRemoveLiquidityReturnDelta,"only declared flags");
        require(uint160(address(hook))&((1<<14)-1)==FLAGS,"address flag match");
    }
    function _membersAndBudget() internal {
        QuorumMembership m=core.membership();firstWeek=m.currentWeek();
        for(uint256 i;i<7;++i){
            owners[i]=address(uint160(0x4100+i));agents[i]=address(uint160(0x5100+i));
            token.transfer(owners[i],m.stakeAmount());
            uint256 amount=m.stakeAmount();vm.prank(owners[i]);token.approve(address(m),amount);
            vm.prank(owners[i]);m.authorize(agents[i],block.timestamp+365 days);
            bytes32 digest=m.constitutionHash();vm.prank(agents[i]);require(m.accept(owners[i],1,digest)==i);
        }
        _maintain(m.weekStart(firstWeek+2));require(core.treasury().qualifiedCount(firstWeek+1)==7,"qualified voters");
        imd.mint(address(this),10_000 ether);imd.approve(address(core.treasury()),10_000 ether);
        core.treasury().depositRevenue(10_000 ether);
    }
    function _maintain(uint256 target) internal {
        QuorumMembership m=core.membership();QuorumTreasury f=core.treasury();
        uint256 next=(block.timestamp/1 hours+1)*1 hours;
        while(next<=target){
            vm.warp(next);vm.roll(block.number+1);uint256 week=m.currentWeek();
            if(week>firstWeek && !f.settled(week-1))f.settleWeek(week-1,32);
            uint256 hour=(block.timestamp-m.weekStart(week))/1 hours;
            bytes32 anchor=keccak256(abi.encode(block.number-1));vm.setBlockhash(block.number-1,anchor);
            for(uint256 i;i<7;++i){
                uint256 revision=core.agendaRevisionAt(block.number - 1);vm.prank(agents[i]);
                m.respond(i,block.number-1,anchor,revision,"Local positive operation rehearsal: checked the current agenda.");
                if(hour==125){vm.prank(agents[i]);m.report(i,"Local governance operation review and receipt reconciliation.");}
            }
            next+=1 hours;
        }
        vm.warp(target);
    }
    function _approve(OperatingPlan memory p) internal returns(uint256 id) {
        QuorumWork w=core.work();vm.prank(agents[0]);
        id=w.proposeOperation(0,p,new address[](0),"Execute the committed treasury conversion and retain unused budget; collect tax under the unchanged constitution.");
        w.prepareBallot(id,32);require(w.ballot(w.work(id).ballot).voters==6,"proposer excluded");
        for(uint256 i=1;i<=5;++i){vm.prank(agents[i]);w.vote(id,i,true);}
        _maintain(w.ballot(w.work(id).ballot).started+120 hours);
    }
    function _tradePlan(bool buy,uint256 input,uint256 budget) internal view returns(OperatingPlan memory p) {
        if(buy)p.primaryBudget=budget;else p.projectBudget=budget;
        p.approvals=new OperatingApproval[](1);
        p.approvals[0]=OperatingApproval(buy?address(imd):address(token),address(hook.router()),budget);
        p.calls=new OperatingCall[](1);bool project0=address(token)<address(imd);
        uint160 limit=(buy==project0)?TickMath.MAX_SQRT_PRICE-1:TickMath.MIN_SQRT_PRICE+1;
        p.calls[0]=OperatingCall(address(hook.router()),0,abi.encodeCall(QuorumSwapRouter.swap,
            (key,buy?!project0:project0,uint128(input),budget,input*9/10,limit,block.timestamp+30 days)),bytes32(0));
    }
    function _executeTrade(uint256 id,OperatingPlan memory p) internal returns(uint256 paid,uint256 received,uint256 tax){
        OperationLogsVm logVm=OperationLogsVm(address(vm));logVm.recordLogs();core.work().executeOperation(id,p);
        OperationLogsVm.Log[] memory logs=logVm.getRecordedLogs();uint256 count;
        for(uint256 i;i<logs.length;++i){
            if(logs[i].emitter==address(hook.router()) && logs[i].topics[0]==keccak256("Traded(address,uint256,uint256,uint256)")){
                require(address(uint160(uint256(logs[i].topics[1])))==address(core.treasury().operatingAccount()),"organization traded");
                (paid,received,tax)=abi.decode(logs[i].data,(uint256,uint256,uint256));++count;
            }
        }
        require(count==1 && core.work().work(id).stage==QuorumWork.Stage.Paid,"one completed trade");
    }
    function _cleanAndAccounted() internal view {
        QuorumTreasury f=core.treasury();address account=address(f.operatingAccount());
        require(imd.balanceOf(address(f))==f.accountedBalance(),"IMD exact liabilities");
        require(token.balanceOf(address(f))==f.accountedAssetBalance(address(token)),"project exact liabilities");
        require(imd.balanceOf(account)==0 && token.balanceOf(account)==0,"unused funds returned");
        require(imd.allowance(account,address(hook.router()))==0 && token.allowance(account,address(hook.router()))==0,"approvals cleared");
        require(imd.balanceOf(address(hook.router()))==0,"no tax left in router");
        require(token.balanceOf(address(core.membership()))==7*core.membership().stakeAmount(),"stake isolated");
    }
    function _buy() internal returns(uint256 received) {
        OperatingPlan memory p=_tradePlan(true,100 ether,120 ether);uint256 id=_approve(p);
        QuorumTreasury f=core.treasury();uint256 ops=f.operatingFunds();uint256 allowance=f.allowancePool();
        uint256 scheduled=f.scheduled(core.membership().currentWeek()+1);
        uint256 paid;uint256 tax;(paid,received,tax)=_executeTrade(id,p);
        require(paid==103 ether && tax==3 ether && received>0,"buy economics");
        require(f.operatingFunds()==ops-paid+tax-tax/2,"refund not counted as tax twice");
        require(f.allowancePool()==allowance+tax/2 && f.scheduled(core.membership().currentWeek()+1)==scheduled+tax/2,"tax qualification budget");
        QuorumTreasury.Ledger memory q=f.ledger(address(token));
        require(q.operatingFunds==received && q.allowancePool==0,"conversion proceeds are operations");
        (uint256 credit,)=hook.quota().available(address(f.operatingAccount()));require(credit==received,"own purchased credit");
        _cleanAndAccounted();
    }
    function testNormalVotedBuyThenSellTaxAndRefunds() public {
        _membersAndBudget();uint256 bought=_buy();
        OperatingPlan memory p=_tradePlan(false,bought/2,bought/2);uint256 id=_approve(p);
        QuorumTreasury f=core.treasury();uint256 ops=f.operatingFunds();uint256 allowance=f.allowancePool();
        uint256 schedule=f.scheduled(core.membership().currentWeek()+1);
        (uint256 paid,uint256 received,uint256 tax)=_executeTrade(id,p);
        require(paid==bought/2 && tax==((received+tax)*3+99)/100,"sell economics");
        require(f.operatingFunds()==ops+received+tax-tax/2 && f.allowancePool()==allowance+tax/2,"sale and tax accounted once");
        require(f.scheduled(core.membership().currentWeek()+1)==schedule+tax/2,"next week tax");
        QuorumTreasury.Ledger memory q=f.ledger(address(token));require(q.operatingFunds==bought-paid,"sold project budget");
        (uint256 credit,)=hook.quota().available(address(f.operatingAccount()));require(credit==bought-paid,"only purchased quota consumed");
        _cleanAndAccounted();
    }
    function testNormalVotedFeeCollectionSplitsIncomeOnlyOnce() public {
        _membersAndBudget();_buy();factory.claimFees(NUMBER);
        uint256 imdFees=imd.balanceOf(address(hook));uint256 tokenFees=token.balanceOf(address(hook));require(imdFees>0 || tokenFees>0);
        OperatingPlan memory p;p.calls=new OperatingCall[](1);p.approvals=new OperatingApproval[](0);
        p.calls[0]=OperatingCall(address(hook),0,abi.encodeCall(QuorumIssuanceHook.collectPlatformFees,(NUMBER)),bytes32(0));
        uint256 id=_approve(p);QuorumTreasury f=core.treasury();
        uint256 ops=f.operatingFunds();uint256 allowance=f.allowancePool();QuorumTreasury.Ledger memory q=f.ledger(address(token));
        core.work().executeOperation(id,p);
        require(f.operatingFunds()==ops+imdFees-imdFees/2 && f.allowancePool()==allowance+imdFees/2,"IMD fee split");
        QuorumTreasury.Ledger memory afterQ=f.ledger(address(token));
        require(afterQ.operatingFunds==q.operatingFunds+tokenFees-tokenFees/2 && afterQ.allowancePool==q.allowancePool+tokenFees/2,"project fee split");
        require(imd.balanceOf(address(hook))==0 && token.balanceOf(address(hook))==0,"fee income flushed");
        _cleanAndAccounted();
    }
    function testNormalUnavailableServiceRollsBackTradeAndCanRetry() public {
        _membersAndBudget();OperatingPlan memory p=_tradePlan(true,100 ether,120 ether);
        NormalOperationService service=new NormalOperationService();OperatingCall memory swapCall=p.calls[0];
        p.calls=new OperatingCall[](2);p.calls[0]=swapCall;
        p.calls[1]=OperatingCall(address(service),0,abi.encodeCall(service.confirm,()),bytes32(0));
        uint256 id=_approve(p);QuorumTreasury f=core.treasury();
        uint256 ops=f.operatingFunds();uint256 allowance=f.allowancePool();uint256 balance=imd.balanceOf(address(f));
        uint256 schedule=f.scheduled(core.membership().currentWeek()+1);
        (bool ok,)=address(core.work()).call(abi.encodeCall(QuorumWork.executeOperation,(id,p)));
        require(!ok && core.work().work(id).stage==QuorumWork.Stage.BudgetVoting,"unavailable work not completed");
        require(f.operatingFunds()==ops && f.allowancePool()==allowance && imd.balanceOf(address(f))==balance,"funds and income rolled back");
        require(f.scheduled(core.membership().currentWeek()+1)==schedule,"no stale tax schedule");
        (uint256 credit,)=hook.quota().available(address(f.operatingAccount()));require(credit==0,"trade rolled back");
        _cleanAndAccounted();service.setAvailable(true);_executeTrade(id,p);_cleanAndAccounted();
    }
    function testNormalApprovedTaskExceedsBudgetThenRetriesWithinBudget() public {
        _membersAndBudget();QuorumTreasury f=core.treasury();
        BudgetedTaskService service=new BudgetedTaskService(IERC20Local(address(imd)));
        service.setPrice(80 ether);
        OperatingPlan memory p;p.primaryBudget=100 ether;
        p.approvals=new OperatingApproval[](1);
        p.approvals[0]=OperatingApproval(address(imd),address(service),100 ether);
        p.calls=new OperatingCall[](1);
        p.calls[0]=OperatingCall(address(service),0,abi.encodeCall(service.completeTask,()),bytes32(0));
        uint256 id=_approve(p);uint256 initial=f.operatingFunds();
        service.setPrice(120 ether);
        (bool ok,)=address(core.work()).call(abi.encodeCall(QuorumWork.executeOperation,(id,p)));
        require(!ok && !service.completed(),"over-budget task not completed");
        require(f.operatingFunds()==initial && imd.balanceOf(address(service))==0,"entire budget retained");
        require(core.work().work(id).stage==QuorumWork.Stage.BudgetVoting,"proposal retryable");
        service.setPrice(80 ether);core.work().executeOperation(id,p);
        require(service.completed() && f.operatingFunds()==initial-80 ether,"same task within budget");
        require(imd.balanceOf(address(service))==80 ether,"only actual cost paid");
        require(imd.allowance(address(f.operatingAccount()),address(service))==0,"service approval cleared");
        _cleanAndAccounted();
    }
    function testNormalProcurementRetiresOnlySpentOrganizationQuota() public {
        _membersAndBudget();uint256 bought=_buy();QuorumTreasury f=core.treasury();
        address recipient=address(0xCE11);uint256 spent=bought/4;
        OperatingPlan memory p;p.projectBudget=bought/2;
        p.approvals=new OperatingApproval[](0);p.calls=new OperatingCall[](1);
        p.calls[0]=OperatingCall(address(token),0,abi.encodeWithSignature("transfer(address,uint256)",recipient,spent),bytes32(0));
        uint256 id=_approve(p);core.work().executeOperation(id,p);
        (uint256 credit,)=hook.quota().available(address(f.operatingAccount()));
        require(credit==bought-spent,"refund preserves, procurement retires");
        require(token.balanceOf(recipient)==spent && hook.quota().earnedRewards(recipient)==0,"procurement has no reward quota");
        _cleanAndAccounted();
    }
    function testNormalAcceptedWorkRetiresOrganizationQuotaAndPaysReward() public {
        _membersAndBudget();uint256 bought=_buy();QuorumWork w=core.work();
        uint256 amount=bought/3;vm.prank(agents[0]);
        uint256 id=w.proposeAsset(0,0,owners[0],address(token),amount,block.timestamp+30 days,
            "Build agent onboarding guide; acceptance: complete documented steps and publish an operation transcript.");
        w.prepareBallot(id,32);
        for(uint256 i=1;i<=5;++i){vm.prank(agents[i]);w.vote(id,i,true);}
        _maintain(w.ballot(w.work(id).ballot).started+120 hours);w.fund(id);
        vm.prank(agents[0]);w.submit(id,"Local positive fixture: completed guide with onboarding transcript and acceptance checklist.");
        w.prepareBallot(id,32);
        for(uint256 i=1;i<=5;++i){vm.prank(agents[i]);w.vote(id,i,true);}
        _maintain(w.ballot(w.work(id).ballot).started+120 hours);w.accept(id);w.claim(id);
        (uint256 credit,)=hook.quota().available(address(core.treasury().operatingAccount()));
        require(credit==bought-amount && hook.quota().earnedRewards(owners[0])==amount,"no duplicated organization credit");
        require(w.work(id).stage==QuorumWork.Stage.Paid && token.balanceOf(owners[0])==amount,"earned reward paid");
        _cleanAndAccounted();
    }

}
