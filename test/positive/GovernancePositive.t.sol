// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {NormalIntegratedTest} from "./NormalIntegrated.t.sol";
import {QuorumWork} from "../../src/QuorumWork.sol";
import {OperatingPlan,OperatingApproval,OperatingCall} from "../../src/QuorumOperatingAccount.sol";
import {IERC20Local} from "../../src/QuorumMembership.sol";
interface FundVm { function deal(address,uint256) external; }
contract NormalExchangeFixture {
    IERC20Local public token;
    constructor(IERC20Local t){token=t;}
    function exchange(uint256 amount) external {
        require(token.transferFrom(msg.sender,address(this),amount));
        (bool ok,)=msg.sender.call{value:amount/10}("");require(ok);
    }
}
contract NormalNameFixture {
    address public registrant;uint256 public updates;bool public available;
    function setAvailable(bool v) external {available=v;}
    function register(bytes32 name) external payable returns(bytes32) {
        require(available && msg.value==0.2 ether);registrant=msg.sender;return name;
    }
    function update() external payable {require(msg.sender==registrant && msg.value==0.1 ether);++updates;}
}
contract GovernancePositiveTest is NormalIntegratedTest {
    function fundedDelivery() internal returns(uint256 id) {
        twoWeeks(); id=propose(100 ether); votes(id);
        maintainUntil(work.ballot(work.work(id).ballot).started+120 hours);work.fund(id);
        vm.prank(agents[0]);work.submit(id,"First delivery, reviewers require a clearer operator transcript.");
        work.prepareBallot(id,32);
    }
    function firstRepair(uint256 id) internal {
        maintainUntil(work.ballot(work.work(id).ballot).started+72 hours);
        work.resolveAcceptance(id);
        require(work.work(id).stage==QuorumWork.Stage.Repair && work.work(id).repairs==1);
        require(funds.reservedWork()==100 ether && funds.operatingFunds()==950 ether);
    }
    function testNormalOneRepairFreshVoteThenPayment() public {
        uint256 id=fundedDelivery();uint256 originalBallot=work.work(id).ballot;
        firstRepair(id);
        vm.prank(agents[0]);work.explain(id,"Added missing transcript and reproduced the guide.");
        vm.prank(agents[0]);work.submit(id,"Revised delivery with complete transcript and acceptance checklist.");
        require(work.work(id).ballot!=originalBallot);
        require(work.ballot(work.work(id).ballot).week==members.currentWeek()-1);
        work.prepareBallot(id,32);votes(id);
        maintainUntil(work.ballot(work.work(id).ballot).started+120 hours);
        work.accept(id);work.claim(id);
        require(work.work(id).stage==QuorumWork.Stage.Paid && income.balanceOf(owners[0])==100 ether);
        require(funds.reservedWork()==0 && income.balanceOf(address(funds))==funds.accountedBalance());
    }
    function testNormalSecondUnapprovedDeliveryReturnsBudget() public {
        uint256 id=fundedDelivery();firstRepair(id);
        vm.prank(agents[0]);work.submit(id,"Second delivery; reviewers abstain because the agreed artifact is missing.");
        work.prepareBallot(id,32);
        maintainUntil(work.ballot(work.work(id).ballot).started+72 hours);
        work.resolveAcceptance(id);
        require(work.work(id).stage==QuorumWork.Stage.Expired && funds.reservedWork()==0);
        require(funds.operatingFunds()==1050 ether && income.balanceOf(owners[0])==0);
        require(income.balanceOf(address(funds))==funds.accountedBalance());
    }
    function testNormalMissedRepairReturnsBudget() public {
        uint256 id=fundedDelivery();firstRepair(id);
        vm.warp(work.work(id).repairDeadline+1);work.expire(id);
        require(work.work(id).stage==QuorumWork.Stage.Expired && funds.reservedWork()==0);
        require(funds.operatingFunds()==1050 ether);
    }
    function testNormalDelayedResolutionDoesNotExtendRepairClock() public {
        uint256 id=fundedDelivery();uint256 close=work.ballot(work.work(id).ballot).started+72 hours;
        vm.warp(close+7 days+1);work.resolveAcceptance(id);
        require(work.work(id).stage==QuorumWork.Stage.Expired && funds.reservedWork()==0);
    }
    function testNormalSuspensionPreservesOldBallotAndRecoversAfterFourWeeks() public {
        twoWeeks();uint256 decisionWeek=members.currentWeek();
        vm.prank(agents[0]);uint256 suspension=work.proposeSuspension(0,owners[6],"Repeated missing deliverables; request four full weeks suspension.");
        work.prepareBallot(suspension,32);
        require(work.ballot(work.work(suspension).ballot).voters==5);
        for(uint256 i=1;i<=5;++i){vm.prank(agents[i]);work.vote(suspension,i,true);}
        vm.prank(owners[6]);work.defend(suspension,"Published explanation and recovery plan.");
        maintainUntil(work.ballot(work.work(suspension).ballot).started+120 hours);
        work.executeSuspension(suspension);
        require(!work.isSuspended(owners[6],decisionWeek));
        for(uint256 w=decisionWeek+1;w<decisionWeek+5;++w)require(work.isSuspended(owners[6],w));
        maintainUntil(members.weekStart(decisionWeek+1)-1 hours);
        uint256 old=propose(10 ether);require(work.eligible(work.work(old).ballot,6));
        require(work.ballot(work.work(old).ballot).denominator==7 && work.threshold(work.work(old).ballot)==5,"old denominator");
        maintainUntil(members.weekStart(decisionWeek+1));
        vm.prank(agents[6]);work.vote(old,6,true); // Immutable old electorate survives suspension.
        require(work.voted(work.work(old).ballot,6));
        uint256 fresh=propose(10 ether);
        require(!work.eligible(work.work(fresh).ballot,6));
        require(work.ballot(work.work(fresh).ballot).voters==5);
        require(work.ballot(work.work(fresh).ballot).denominator==6 && work.threshold(work.work(fresh).ballot)==4,"creation-week suspension excluded");
        require(work.threshold(work.work(old).ballot)==5,"old threshold unchanged by later suspension");
        funds.claimAllowance(initialWeek+1,6);require(income.balanceOf(owners[6])==50 ether);
        maintainUntil(members.weekStart(decisionWeek+5));
        for(uint256 w=decisionWeek+1;w<decisionWeek+5;++w){
            require(!members.qualified(6,w) && !funds.isQualified(w,6));
        }
        require(!work.isSuspended(owners[6],members.currentWeek()));
        uint256 beforeFreshWeek=propose(10 ether);require(!work.eligible(work.work(beforeFreshWeek).ballot,6));
        maintainUntil(members.weekStart(decisionWeek+6));
        uint256 recovered=propose(10 ether);require(work.eligible(work.work(recovered).ballot,6));
        require(members.totalStaked()==5250 ether && income.balanceOf(address(funds))==funds.accountedBalance());
    }
    function testNormalSuspendedMemberCanExitAndReceiveOriginalStake() public {
        twoWeeks();vm.prank(agents[0]);uint256 id=work.proposeSuspension(0,owners[6],"Documented recurring omission.");
        work.prepareBallot(id,32);votes(id);
        maintainUntil(work.ballot(work.work(id).ballot).started+120 hours);work.executeSuspension(id);
        maintainUntil(members.weekStart(members.currentWeek()+1));
        uint256 before=stake.balanceOf(owners[6]);vm.prank(owners[6]);members.requestExit(6);
        maintainUntil(members.enrollment(6).exitAt);members.withdraw(6);
        require(stake.balanceOf(owners[6])==before+750 ether && members.totalStaked()==4500 ether);
    }
    function operationPlan(NormalExchangeFixture exchange,NormalNameFixture names) internal view returns(OperatingPlan memory p) {
        p.primaryBudget=20 ether;p.approvals=new OperatingApproval[](1);
        p.approvals[0]=OperatingApproval(address(income),address(exchange),10 ether);
        p.calls=new OperatingCall[](2);
        p.calls[0]=OperatingCall(address(exchange),0,abi.encodeCall(exchange.exchange,(10 ether)),bytes32(0));
        bytes32 name=keccak256("local ENS fixture");
        p.calls[1]=OperatingCall(address(names),0.2 ether,abi.encodeCall(names.register,(name)),keccak256(abi.encode(name)));
    }
    function approvedOperation(OperatingPlan memory p) internal returns(uint256 id) {
        address[] memory beneficiaries=new address[](0);
        vm.prank(agents[0]);id=work.proposeOperation(0,p,beneficiaries,"Acquire and maintain an organizational name under the fixed operating budget.");
        work.prepareBallot(id,32);votes(id);
        maintainUntil(work.ballot(work.work(id).ballot).started+120 hours);
    }
    function testNormalOperatingConversionNameAndLaterUpdate() public {
        twoWeeks();NormalExchangeFixture exchange=new NormalExchangeFixture(IERC20Local(address(income)));
        FundVm(address(vm)).deal(address(exchange),2 ether);NormalNameFixture names=new NormalNameFixture();names.setAvailable(true);
        OperatingPlan memory p=operationPlan(exchange,names);uint256 id=approvedOperation(p);
        work.executeOperation(id,p);
        require(work.work(id).stage==QuorumWork.Stage.Paid && names.registrant()==address(funds.operatingAccount()));
        require(funds.operatingFunds()==1040 ether && funds.operatingNative()==0.8 ether);
        require(income.allowance(address(funds.operatingAccount()),address(exchange))==0);
        require(income.balanceOf(address(funds.operatingAccount()))==0 && address(funds.operatingAccount()).balance==0);
        require(income.balanceOf(address(funds))==funds.accountedBalance() && members.totalStaked()==5250 ether);
        OperatingPlan memory update;update.nativeBudget=0.1 ether;update.approvals=new OperatingApproval[](0);update.calls=new OperatingCall[](1);
        update.calls[0]=OperatingCall(address(names),0.1 ether,abi.encodeCall(names.update,()),bytes32(0));
        uint256 second=approvedOperation(update);work.executeOperation(second,update);
        require(names.updates()==1 && funds.operatingNative()==0.7 ether);
        require(address(funds).balance==funds.operatingNative());
    }
    function testNormalUnavailableServiceLeavesBudgetAndAllowsRetry() public {
        twoWeeks();NormalExchangeFixture exchange=new NormalExchangeFixture(IERC20Local(address(income)));
        FundVm(address(vm)).deal(address(exchange),2 ether);NormalNameFixture names=new NormalNameFixture();
        OperatingPlan memory p=operationPlan(exchange,names);uint256 id=approvedOperation(p);
        (bool ok,)=address(work).call(abi.encodeCall(work.executeOperation,(id,p)));
        require(!ok && work.work(id).stage==QuorumWork.Stage.BudgetVoting);
        require(funds.operatingFunds()==1050 ether && funds.operatingNative()==0 && income.balanceOf(address(exchange))==0);
        names.setAvailable(true);work.executeOperation(id,p);
        require(work.work(id).stage==QuorumWork.Stage.Paid && funds.operatingFunds()==1040 ether);
    }
    function testNormalSnapshotTimeoutAndRepairClock() public {
        twoWeeks();vm.prank(agents[0]);uint256 unfunded=work.propose(0,0,owners[0],100 ether,block.timestamp+30 days,"Normal proposal awaiting voter list preparation.");
        maintainUntil(work.snapshotDeadline(work.work(unfunded).ballot)+1);work.expire(unfunded);
        require(work.work(unfunded).stage==QuorumWork.Stage.Expired && funds.operatingFunds()==1050 ether);
        uint256 id=propose(100 ether);votes(id);maintainUntil(work.ballot(work.work(id).ballot).started+120 hours);work.fund(id);
        vm.prank(agents[0]);work.submit(id,"Delivery awaiting acceptance list.");
        uint256 close=work.snapshotDeadline(work.work(id).ballot);maintainUntil(close+1);work.resolveAcceptance(id);
        require(work.work(id).repairDeadline==close+7 days && work.work(id).stage==QuorumWork.Stage.Repair);
        vm.prank(agents[0]);work.submit(id,"Repaired delivery awaiting second acceptance list.");
        maintainUntil(work.snapshotDeadline(work.work(id).ballot)+1);work.resolveAcceptance(id);
        require(work.work(id).stage==QuorumWork.Stage.Expired && funds.reservedWork()==0 && funds.operatingFunds()==1050 ether);
    }
}
