// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {TenSeatFixture} from "./RecusalPositive.t.sol";

/// Ordinary concurrent activity: a response is bound to what was observable
/// at its confirmed anchor, not to messages posted while it was in flight.
interface AgendaClockVm { function getBlockNumber() external view returns(uint256); }
contract AgendaResponsePositiveTest is TenSeatFixture {
    AgendaClockVm constant clockVm=AgendaClockVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    function _readyWork() internal returns(uint256 id) {
        vm.warp(members.weekStart(initialWeek+1));
        funds.settleWeek(initialWeek,32);
        vm.prank(agents[0]);
        id=work.propose(0,0,owners[0],1 ether,block.timestamp+30 days,"Publish an agent onboarding guide");
    }
    function _anchor(uint256 number) internal returns(bytes32 h) {
        h=keccak256(abi.encode("confirmed block",number));vm.setBlockhash(number,h);
    }
    function testNormalResponseWithNoAgendaYet() public {
        uint256 number=clockVm.getBlockNumber();vm.roll(number+1);bytes32 h=_anchor(number);
        require(system.agendaRevisionAt(number)==0,"initial agenda");
        vm.prank(agents[1]);members.respond(1,number,h,0,"Checked: no proposals yet.");
        require(members.responseCount(1,members.currentWeek())==1,"response recorded");
    }
    function testNormalInFlightResponseSurvivesWorkerProgressMessage() public {
        uint256 id=_readyWork();uint256 number=clockVm.getBlockNumber();uint256 revision=system.agendaRevision();
        vm.roll(number+1);bytes32 h=_anchor(number);
        vm.prank(agents[0]);work.explain(id,"The guide outline is ready for review.");
        require(system.agendaRevision()>revision,"new message exists");
        vm.prank(agents[1]);members.respond(1,number,h,revision,"Reviewed the guide proposal at the referenced block.");
        require(members.responseCount(1,members.currentWeek())==1,"in-flight response recorded");
        require(system.agendaRevisionAt(number)==revision,"historical context preserved");
    }
    function testNormalSameBlockMessagesUseFinalConfirmedRevision() public {
        uint256 id=_readyWork();uint256 beforeNumber=clockVm.getBlockNumber();uint256 first=system.agendaRevision();
        vm.roll(beforeNumber+1);uint256 number=clockVm.getBlockNumber();
        vm.prank(agents[0]);work.explain(id,"Added installation steps.");
        vm.prank(agents[0]);work.explain(id,"Added expected outputs.");
        uint256 last=system.agendaRevision();vm.roll(number+1);bytes32 h=_anchor(number);
        require(system.agendaRevisionAt(beforeNumber)==first,"previous block unchanged");
        require(system.agendaRevisionAt(number)==last,"last update in block");
        vm.prank(agents[1]);members.respond(1,number,h,last,"Reviewed both additions in the confirmed block.");
        require(members.responseCount(1,members.currentWeek())==1,"response recorded");
    }
    function testNormalResponseAtExistingAnchorAgeLimit() public {
        uint256 id=_readyWork();uint256 number=clockVm.getBlockNumber();uint256 revision=system.agendaRevision();
        vm.roll(number+256);bytes32 h=_anchor(number);
        vm.prank(agents[0]);work.explain(id,"Progress update while another agent prepares its response.");
        vm.prank(agents[1]);members.respond(1,number,h,revision,"Response anchored within the existing 256-block limit.");
        require(members.responseCount(1,members.currentWeek())==1,"existing age limit preserved");
    }
}
