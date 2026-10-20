// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {NormalIntegratedTest} from "./NormalIntegrated.t.sol";
import {QuorumTreasury} from "../../src/QuorumTreasury.sol";
import {OperatingPlan,OperatingApproval,OperatingCall} from "../../src/QuorumOperatingAccount.sol";
contract RevenueAndScalePositiveTest is NormalIntegratedTest {
    function checkedCounts(uint256 from,uint256 to) internal view {
        for(uint256 w=from;w<=to;++w){
            uint256 expected;
            for(uint256 i;i<members.enrollmentCount();++i)if(members.registeredAtStart(i,w))++expected;
            require(members.registrationCount(w)==expected,"indexed count matches membership rules");
        }
    }
    function rotate(uint256 i,uint256 expiry) internal {
        vm.prank(owners[i]);members.authorize(agents[i],expiry);
        (,,,uint256 nonce)=members.authorizations(owners[i]);bytes32 hash=members.constitutionHash();
        vm.prank(agents[i]);members.accept(owners[i],nonce,hash);
    }
    function testNormalDirectSupportedDonationsRecognizedExactlyOnce() public {
        income.mint(address(funds),101);stake.mint(address(funds),51);
        funds.syncAssetRevenue(address(income));funds.syncAssetRevenue(address(stake));
        require(funds.allowancePool()==350 ether+50 && funds.operatingFunds()==350 ether+51);
        QuorumTreasury.Ledger memory q=funds.ledger(address(stake));require(q.allowancePool==25 && q.operatingFunds==26);
        require(funds.scheduled(initialWeek+1)==350 ether+50);
        funds.syncAssetRevenue(address(income));funds.syncAssetRevenue(address(stake));
        require(funds.allowancePool()==350 ether+50 && funds.operatingFunds()==350 ether+51);
        require(income.balanceOf(address(funds))==funds.accountedBalance());
        require(stake.balanceOf(address(funds))==funds.accountedAssetBalance(address(stake)));
        require(members.totalStaked()==5250 ether);
    }
    function testNormalLateDonationRecognitionDoesNotRewriteClosedBudget() public {
        income.mint(address(funds),100 ether);
        maintainUntil(members.weekStart(initialWeek+2));
        require(funds.weekInfo(initialWeek+1).perSeat==50 ether);
        funds.syncAssetRevenue(address(income));
        require(funds.weekInfo(initialWeek+1).perSeat==50 ether && funds.scheduled(initialWeek+3)==50 ether);
        funds.claimAllowance(initialWeek+1,0);require(income.balanceOf(owners[0])==50 ether);
    }
    function testNormalOperatingDonationsAreIncomeBeforeBudgetAndRefund() public {
        twoWeeks();uint256 allowanceBefore=funds.allowancePool();
        income.mint(address(funds.operatingAccount()),20 ether);income.mint(address(funds),10 ether);
        stake.mint(address(funds.operatingAccount()),10 ether);
        OperatingPlan memory p;p.primaryBudget=20 ether;p.approvals=new OperatingApproval[](0);p.calls=new OperatingCall[](1);
        p.calls[0]=OperatingCall(address(income),0,abi.encodeCall(income.transfer,(address(0x9000),10 ether)),bytes32(0));
        address[] memory beneficiaries=new address[](1);beneficiaries[0]=address(0x9000);
        vm.prank(agents[0]);uint256 id=work.proposeOperation(0,p,beneficiaries,"Pay approved service; recognize pre-existing donations separately.");
        work.prepareBallot(id,32);votes(id);maintainUntil(work.ballot(work.work(id).ballot).started+120 hours);
        work.executeOperation(id,p);
        require(funds.operatingFunds()==1055 ether && funds.allowancePool()==allowanceBefore+15 ether);
        QuorumTreasury.Ledger memory q=funds.ledger(address(stake));require(q.allowancePool==5 ether && q.operatingFunds==5 ether);
        require(income.balanceOf(address(0x9000))==10 ether);
        require(income.balanceOf(address(funds.operatingAccount()))==0 && stake.balanceOf(address(funds.operatingAccount()))==0);
        require(income.balanceOf(address(funds))==funds.accountedBalance());
    }
    function testNormalAnyoneMayRecognizeOperatingDonationsWithoutProposal() public {
        income.mint(address(funds.operatingAccount()),99);stake.mint(address(funds.operatingAccount()),101);
        vm.prank(address(0x9001));funds.syncOperatingRevenue();
        require(funds.operatingFunds()==350 ether+50 && funds.allowancePool()==350 ether+49);
        QuorumTreasury.Ledger memory q=funds.ledger(address(stake));require(q.allowancePool==50 && q.operatingFunds==51);
        funds.syncOperatingRevenue();require(funds.allowancePool()==350 ether+49);
    }
    function testNormalRegistrationIndexMatchesRotationExpiryAndExit() public {
        checkedCounts(initialWeek,initialWeek+60);
        rotate(0,members.weekStart(initialWeek+4)); // Exact expiry excludes that start.
        rotate(1,members.weekStart(initialWeek+4)+1); // One second later includes it.
        rotate(2,block.timestamp+1 hours); // Never valid at next week's start.
        vm.prank(owners[3]);members.revoke();
        checkedCounts(initialWeek,initialWeek+60);
        vm.warp(members.weekStart(initialWeek+1)+1 days);
        vm.prank(owners[4]);members.requestExit(4);
        rotate(5,members.weekStart(initialWeek+7));
        checkedCounts(initialWeek,initialWeek+60);
        require(members.registrationCount(initialWeek+1)==5);
        vm.warp(members.weekStart(initialWeek+9));
        rotate(0,block.timestamp+365 days);
        checkedCounts(initialWeek,initialWeek+65); // Historical counts do not change.
    }
    function testNormalHistoricalRegistrationsDoNotIncreaseEmptyWeekScan() public {
        for(uint256 i;i<1000;++i)rotate(0,block.timestamp+365 days);
        require(members.enrollmentCount()==1007 && members.registrationCount(initialWeek+1)==7);
        vm.warp(members.weekStart(initialWeek+2));
        uint256 before=gasleft();funds.settleWeek(initialWeek+1,32);uint256 used=before-gasleft();
        emit log_named_uint("settlement gas with 1000 historical rotations and no responses",used);
        require(used<350000,"bounded empty-week settlement");
        require(funds.settled(initialWeek+1) && funds.weekInfo(initialWeek+1).rosterLimit==0);
        require(funds.weekInfo(initialWeek+1).registrations==7 && funds.qualifiedCount(initialWeek+1)==0);
        require(funds.scheduled(initialWeek+3)==350 ether && funds.allowancePool()==350 ether);
    }
    function testNormalResponderBatchesPreserveAllRegisteredDenominator() public {
        vm.warp(members.weekStart(initialWeek+1));tick();
        vm.prank(owners[0]);members.revoke(); // Start count retained, qualification lost.
        maintainUntil(members.weekStart(initialWeek+2)-1);
        uint256 w=initialWeek+1;require(members.responderCount(w)==7 && members.registrationCount(w)==7);
        vm.warp(members.weekStart(initialWeek+2));funds.settleWeek(w,2);
        require(!funds.settled(w) && funds.weekInfo(w).cursor==2 && funds.weekInfo(w).registrations==7);
        while(!funds.settled(w))funds.settleWeek(w,2);
        require(funds.qualifiedCount(w)==6 && funds.weekInfo(w).perSeat==50 ether);
        require(funds.scheduled(initialWeek+3)==50 ether && funds.earnedAllowances()==300 ether);
    }
}
