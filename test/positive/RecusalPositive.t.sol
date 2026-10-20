// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {QuorumLocalSystem} from "../../src/QuorumLocalSystem.sol";
import {QuorumMembership, IERC20Local} from "../../src/QuorumMembership.sol";
import {QuorumTreasury} from "../../src/QuorumTreasury.sol";
import {QuorumWork} from "../../src/QuorumWork.sol";
import {LocalToken} from "../../src/LocalFixtures.sol";
import {OperatingPlan,OperatingApproval,OperatingCall} from "../../src/QuorumOperatingAccount.sol";
import {QuorumCodeCatalog} from "../../src/QuorumCodeCatalog.sol";
interface RecusalVm {
    function prank(address) external;
    function warp(uint256) external;
    function roll(uint256) external;
    function setBlockhash(uint256, bytes32) external;
    function readFile(string calldata) external view returns (string memory);
}
abstract contract TenSeatFixture {
    RecusalVm constant vm = RecusalVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    QuorumLocalSystem system;
    QuorumMembership members;
    QuorumTreasury funds;
    QuorumWork work;
    LocalToken stake;
    LocalToken income;
    uint256 initialWeek;
    address[10] owners;
    address[10] agents;
    event log_named_uint(string key, uint256 val);

    function setUp() public {
        vm.warp(4 days + 100 weeks + 1 days); vm.roll(10);
        stake = new LocalToken(); income = new LocalToken();
        system = new QuorumLocalSystem(IERC20Local(address(stake)),
            IERC20Local(address(income)), 750 ether, bytes(vm.readFile("constitution.en.md")),new QuorumCodeCatalog());
        members = system.membership(); funds = system.treasury(); work = system.work();
        initialWeek = members.currentWeek();
        for (uint256 i; i < 10; ++i) {
            owners[i] = address(uint160(0x1000 + i)); agents[i] = address(uint160(0x2000 + i));
            stake.mint(owners[i], 2000 ether);
            uint256 amount = members.stakeAmount(); vm.prank(owners[i]); stake.approve(address(members), amount);
            vm.prank(owners[i]); members.authorize(agents[i], block.timestamp + 365 days);
            bytes32 digest = members.constitutionHash(); vm.prank(agents[i]); require(members.accept(owners[i], 1, digest) == i);
        }
        income.mint(address(this), 2100 ether);
        income.approve(address(funds), 2100 ether);
        funds.depositRevenue(700 ether);
    }
    function tick() internal {
        vm.roll(block.number + 1);
        bytes32 anchor = keccak256(abi.encode(block.number - 1));
        vm.setBlockhash(block.number - 1, anchor);
        uint256 week = members.currentWeek();
        uint256 hour = (block.timestamp - members.weekStart(week)) / 1 hours;
        for (uint256 i; i < 10; ++i) {
            if (members.live(i) && members.hourBitmap(i, week) & (uint256(1) << hour) == 0) {
                uint256 revision = system.agendaRevisionAt(block.number - 1); vm.prank(agents[i]);
                members.respond(i, block.number - 1, anchor, revision,
                    "Local rehearsal: observed current agenda. Participation record, not proof of opinion quality.");
                if (hour == 125) {
                    vm.prank(agents[i]); members.report(i, "Local rehearsal report: checked agenda and performed assigned review steps.");
                }
            }
        }
    }
    function maintainUntil(uint256 target) internal {
        uint256 next = (block.timestamp / 1 hours + 1) * 1 hours;
        while (next <= target) {
            vm.warp(next); uint256 week = members.currentWeek();
            if (week > initialWeek && !funds.settled(week - 1)) {
                funds.settleWeek(week - 1, 3);
                while (!funds.settled(week - 1)) funds.settleWeek(week - 1, 3);
            }
            tick(); next += 1 hours;
        }
        vm.warp(target);
    }
    function twoWeeks() internal {
        maintainUntil(members.weekStart(initialWeek + 2));
        require(funds.qualifiedCount(initialWeek + 1) == 10);
        funds.depositRevenue(1400 ether); // Goes to week +3, not a retroactive week +2 promise.
        maintainUntil(members.weekStart(initialWeek + 3));
        require(funds.qualifiedCount(initialWeek + 2) == 10);
    }
    function propose(uint256 budget) internal returns (uint256 id) {
        vm.prank(agents[0]);
        id = work.propose(0, 0, owners[0], budget, block.timestamp + 30 days,
            "Goal: reduce agent onboarding effort; deliver versioned guide and CLI examples; acceptance: independent operator follows guide and supplies a transcript.");
        while (!work.ballot(work.work(id).ballot).ready) work.prepareBallot(id, 2);
    }
    function votes(uint256 id) internal {
        for (uint256 i = 1; i <= 5; ++i) { vm.prank(agents[i]); work.vote(id, i, true); }
    }
    function finishWork(uint256 id) internal {
        votes(id);
        maintainUntil(work.ballot(work.work(id).ballot).started + 120 hours);
        work.fund(id);
        require(funds.reservedWork() == work.work(id).budget);
        vm.prank(agents[0]); work.submit(id, "Local fixture delivery: guide revision and review checklist. This test does not claim independent real-world labor.");
        while (!work.ballot(work.work(id).ballot).ready) work.prepareBallot(id, 2);
        require(work.ballot(work.work(id).ballot).week == members.currentWeek() - 1);
        votes(id);
        maintainUntil(work.ballot(work.work(id).ballot).started + 120 hours);
        work.accept(id);
        require(funds.earnedWork() == work.work(id).budget);
        work.claim(id);
        require(work.work(id).stage == QuorumWork.Stage.Paid);
    }
}

contract RecusalPositiveTest is TenSeatFixture {
    function planFor(uint256 recipients) internal view returns(OperatingPlan memory p,address[] memory beneficiaries) {
        p.primaryBudget=recipients*1 ether;
        p.approvals=new OperatingApproval[](0);
        p.calls=new OperatingCall[](recipients);
        beneficiaries=new address[](recipients);
        for(uint256 i;i<recipients;++i){
            address recipient=owners[9-i];beneficiaries[i]=recipient;
            p.calls[i]=OperatingCall(address(income),0,abi.encodeCall(IERC20Local.transfer,(recipient,1 ether)),bytes32(0));
        }
    }
    function operation(OperatingPlan memory p,address[] memory beneficiaries) internal returns(uint256 id) {
        vm.prank(agents[0]);id=work.proposeOperation(0,p,beneficiaries,"Pay the declared member contractors for the approved operating service.");
    }
    function testNormalTenQualifiedSeatsRequireSevenWithDeclaredRecipients() public {
        twoWeeks();(OperatingPlan memory p,address[] memory recipients)=planFor(2);
        uint256 id=operation(p,recipients);uint256 ballot=work.work(id).ballot;
        work.prepareBallot(id,3);
        require(!work.ballot(ballot).ready && work.ballot(ballot).denominator==3,"partial assembly");
        (bool available,)=address(work).staticcall(abi.encodeCall(work.threshold,(ballot)));
        require(!available,"incomplete threshold not published");
        while(!work.ballot(ballot).ready)work.prepareBallot(id,3);
        require(work.ballot(ballot).denominator==10 && work.ballot(ballot).voters==7,"denominator includes proposer and recipients");
        require(work.threshold(ballot)==7,"ten seats require seven");
        require(!work.eligible(ballot,0) && !work.eligible(ballot,8) && !work.eligible(ballot,9),"interested seats recuse");
        for(uint256 i=1;i<=7;++i){vm.prank(agents[i]);work.vote(id,i,true);}
        uint256 before=funds.operatingFunds();
        maintainUntil(work.ballot(ballot).started+120 hours);work.executeOperation(id,p);
        require(income.balanceOf(owners[8])==1 ether && income.balanceOf(owners[9])==1 ether,"fixed service payments");
        require(funds.operatingFunds()==before-2 ether,"budget accounted");
        require(income.balanceOf(address(funds))==funds.accountedBalance(),"ledger preserved");
    }
    function testNormalManyInterestedMembersLeaveThresholdFixedAndProposalExpires() public {
        twoWeeks();(OperatingPlan memory p,address[] memory recipients)=planFor(3);
        uint256 id=operation(p,recipients);work.prepareBallot(id,32);
        uint256 ballot=work.work(id).ballot;
        require(work.ballot(ballot).denominator==10 && work.ballot(ballot).voters==6,"six available voters");
        require(work.threshold(ballot)==7,"recusal does not lower seven required");
        for(uint256 i=1;i<=6;++i){vm.prank(agents[i]);work.vote(id,i,true);}
        require(work.ballot(ballot).yes==6 && work.ballot(ballot).yes<work.threshold(ballot),"all available votes still insufficient");
        uint256 before=funds.operatingFunds();
        maintainUntil(work.ballot(ballot).started+120 hours+7 days+1);work.expire(id);
        require(work.work(id).stage==QuorumWork.Stage.Expired && funds.operatingFunds()==before,"normal expiry preserves budget");
    }
    function testNormalSeparateWorkerAndRecipientRemainInBudgetAndAcceptanceDenominator() public {
        twoWeeks();vm.prank(agents[0]);uint256 id=work.propose(0,1,owners[2],10 ether,block.timestamp+30 days,"Independent member builds a documented integration; fixed third member receives payment.");
        work.prepareBallot(id,32);uint256 first=work.work(id).ballot;
        require(work.ballot(first).denominator==10 && work.ballot(first).voters==7 && work.threshold(first)==7,"budget denominator");
        for(uint256 i=3;i<10;++i){vm.prank(agents[i]);work.vote(id,i,true);}
        maintainUntil(work.ballot(first).started+120 hours);work.fund(id);
        vm.prank(agents[1]);work.submit(id,"Delivered integration and reproducible operation transcript.");
        work.prepareBallot(id,32);uint256 second=work.work(id).ballot;
        require(second!=first && work.ballot(second).denominator==10 && work.threshold(second)==7,"fresh acceptance retains full denominator");
        for(uint256 i=3;i<10;++i){vm.prank(agents[i]);work.vote(id,i,true);}
        maintainUntil(work.ballot(second).started+120 hours);work.accept(id);work.claim(id);
        require(income.balanceOf(owners[2])==10 ether && funds.reservedWork()==0,"accepted work paid");
    }
}
