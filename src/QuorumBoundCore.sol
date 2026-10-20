// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {QuorumMembership,IERC20Local,IAgendaSource} from "./QuorumMembership.sol";
import {QuorumTreasury} from "./QuorumTreasury.sol";
import {QuorumWork} from "./QuorumWork.sol";
import {ConstitutionPrototype} from "./ConstitutionPrototype.sol";
/// Immutable staged-deployment candidate. Final bindings must be attested before any public deployment.
contract QuorumBoundCore is IAgendaSource {
 ConstitutionPrototype public immutable constitution;
 QuorumMembership public immutable membership;
 QuorumTreasury public immutable treasury;
 QuorumWork public immutable work;
 constructor(IERC20Local token,IERC20Local imd,uint256 stake,ConstitutionPrototype approvedText,address reporter){
  require(address(approvedText).code.length>0,"constitution deployed");constitution=approvedText;
  membership=new QuorumMembership(token,stake,constitution.constitutionHash(),IAgendaSource(address(this)));
  treasury=new QuorumTreasury(imd,membership,reporter,address(0));work=treasury.work();
 }
 function agendaRevision() external view returns(uint256){return work.agendaRevision();}
 function isSuspended(address owner,uint256 week) external view returns(bool){return work.isSuspended(owner,week);}
 function agendaRevisionAt(uint256 anchorNumber) external view returns(uint256) {return work.agendaRevisionAt(anchorNumber);}
}
