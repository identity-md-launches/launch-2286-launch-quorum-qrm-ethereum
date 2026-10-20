// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {QuorumLocalSystem} from "../../src/QuorumLocalSystem.sol";
import {QuorumMembership, IERC20Local} from "../../src/QuorumMembership.sol";
import {QuorumTreasury} from "../../src/QuorumTreasury.sol";
import {QuorumWork} from "../../src/QuorumWork.sol";
import {LocalToken} from "../../src/LocalFixtures.sol";
import {QuorumCodeCatalog} from "../../src/QuorumCodeCatalog.sol";
interface IntegratedVm {
    function prank(address) external;
    function warp(uint256) external;
    function roll(uint256) external;
    function setBlockhash(uint256, bytes32) external;
    function readFile(string calldata) external view returns (string memory);
}
contract NormalIntegratedTest {
    IntegratedVm constant vm = IntegratedVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    QuorumLocalSystem system;
    QuorumMembership members;
    QuorumTreasury funds;
    QuorumWork work;
    LocalToken stake;
    LocalToken income;
    uint256 initialWeek;
    address[7] owners;
    address[7] agents;
    event log_named_uint(string key, uint256 val);

    function setUp() public {
        vm.warp(4 days + 100 weeks + 1 days); vm.roll(10);
        stake = new LocalToken(); income = new LocalToken();
        system = new QuorumLocalSystem(IERC20Local(address(stake)),
            IERC20Local(address(income)), 750 ether, bytes(vm.readFile("constitution.en.md")),new QuorumCodeCatalog());
        members = system.membership(); funds = system.treasury(); work = system.work();
        initialWeek = members.currentWeek();
        for (uint256 i; i < 7; ++i) {
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
        for (uint256 i; i < 7; ++i) {
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
        require(funds.qualifiedCount(initialWeek + 1) == 7);
        funds.depositRevenue(1400 ether); // Goes to week +3, not a retroactive week +2 promise.
        maintainUntil(members.weekStart(initialWeek + 3));
        require(funds.qualifiedCount(initialWeek + 2) == 7);
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
    function testNormalJoinAuthorizationAndSeparateStake() public view {
        require(members.stakeAmount() == 750 ether);
        require(members.totalStaked() == 5250 ether && stake.balanceOf(address(members)) == 5250 ether);
        require(funds.operatingFunds() == 350 ether && funds.allowancePool() == 350 ether);
        require(members.enrollment(0).firstWeek == initialWeek + 1 && members.live(0));
    }
    function testNormalTwoQualifiedPeriodsAndAllowanceClaim() public {
        twoWeeks();
        uint256 prior = income.balanceOf(owners[0]);
        funds.claimAllowance(initialWeek + 1, 0);
        funds.claimAllowance(initialWeek + 2, 0); // Zero income allocated to this week means zero new wage debt.
        require(income.balanceOf(owners[0]) - prior == 50 ether);
        require(funds.weekInfo(initialWeek + 1).perSeat == 50 ether);
        require(funds.weekInfo(initialWeek + 2).perSeat == 0);
        require(income.balanceOf(address(funds)) == funds.accountedBalance());
    }
    function testNormalTwoWorkRoundsAndExit() public {
        twoWeeks();
        uint256 first = propose(100 ether); finishWork(first);
        uint256 second = propose(80 ether); finishWork(second);
        require(income.balanceOf(owners[0]) == 180 ether);
        require(funds.operatingFunds() == 870 ether);
        for (uint256 week = initialWeek + 1; week < members.currentWeek(); ++week) {
            if (funds.settled(week)) {
                for (uint256 i; i < 7; ++i) if (funds.isQualified(week, i)) funds.claimAllowance(week, i);
            }
        }
        require(income.balanceOf(address(funds)) == funds.accountedBalance());
        uint256 beforeStake = stake.balanceOf(owners[0]);
        vm.prank(owners[0]); members.requestExit(0);
        uint256 available = members.enrollment(0).exitAt;
        maintainUntil(available); members.withdraw(0);
        require(stake.balanceOf(owners[0]) == beforeStake + 750 ether);
        require(members.totalStaked() == 4500 ether);
        require(!members.qualified(0, members.currentWeek() - 1));
        emit log_named_uint("operating", funds.operatingFunds());
        emit log_named_uint("remaining_stake", members.totalStaked());
        emit log_named_uint("treasury_accounted", funds.accountedBalance());
    }
    function testNormalKeyRotationCarriesStakeAndPreservesPastEarnings() public {
        twoWeeks(); uint256 past = initialWeek + 1; address replacement = address(0x3000);
        vm.prank(owners[0]); members.authorize(replacement, block.timestamp + 365 days);
        bytes32 digest = members.constitutionHash(); vm.prank(replacement); uint256 replacementId = members.accept(owners[0], 2, digest);
        require(replacementId == 7 && members.totalStaked() == 5250 ether);
        require(members.enrollment(0).stake == 0 && members.enrollment(7).stake == 750 ether);
        require(members.enrollment(7).firstWeek == members.currentWeek() + 1);
        funds.claimAllowance(past, 0);
        require(income.balanceOf(owners[0]) == 50 ether);
    }
    function testNormalFixedStakeHasNoSnapshotOrSeatCap() public {
        QuorumLocalSystem small = new QuorumLocalSystem(IERC20Local(address(stake)),
            IERC20Local(address(income)), 37_500 ether, bytes("address admission fixture"),new QuorumCodeCatalog());
        QuorumMembership m=small.membership();
        // Direct fixed stake; three addresses join without any launch/NFT snapshot.
        for(uint256 i;i<3;++i){
            address owner=address(uint160(0x9000+i));
            stake.mint(owner,m.stakeAmount());
            uint256 amount=m.stakeAmount();vm.prank(owner);stake.approve(address(m),amount);
            vm.prank(owner);m.authorize(owner,block.timestamp+365 days);
            bytes32 digest=m.constitutionHash();vm.prank(owner);uint256 id=m.accept(owner,1,digest);
            require(m.enrollment(id).seat==owner && m.currentEnrollmentPlusOne(owner)==id+1);
        }
        require(m.enrollmentCount()==3 && m.stakeAmount()==37_500 ether && m.totalStaked()==112_500 ether);
    }

}
