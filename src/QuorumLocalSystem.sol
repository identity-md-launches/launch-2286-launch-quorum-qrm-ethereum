// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {QuorumMembership, IERC20Local, IAgendaSource} from "./QuorumMembership.sol";
import {QuorumTreasury} from "./QuorumTreasury.sol";
import {QuorumWork} from "./QuorumWork.sol";
import {QuorumCreate} from "./QuorumCreate.sol";
import {QuorumCodeCatalog} from "./QuorumCodeCatalog.sol";
import {ConstitutionPrototype} from "./ConstitutionPrototype.sol";

/// @notice Local composition only. No launch provenance/admission or token distribution.
contract QuorumLocalSystem is IAgendaSource {
    ConstitutionPrototype public immutable constitution;
    QuorumMembership public immutable membership;
    QuorumTreasury public immutable treasury;
    QuorumWork public immutable work;
    constructor(IERC20Local stakeToken, IERC20Local revenueToken,
        uint256 fixedStake, bytes memory constitutionText,QuorumCodeCatalog catalog)
    {
        constitution = new ConstitutionPrototype(constitutionText);
        membership = QuorumMembership(QuorumCreate.deploy(catalog.membershipCreation(),abi.encode(stakeToken,fixedStake,sha256(constitutionText),IAgendaSource(address(this)))));
        treasury = new QuorumTreasury(revenueToken, membership, address(0),catalog.workCreation());
        work = treasury.work();
    }
    function agendaRevision() external view returns (uint256) { return work.agendaRevision(); }
    function isSuspended(address seat,uint256 week) external view returns(bool) {
        return work.isSuspended(seat,week);
    }
 function agendaRevisionAt(uint256 anchorNumber) external view returns(uint256) {return work.agendaRevisionAt(anchorNumber);}
}
