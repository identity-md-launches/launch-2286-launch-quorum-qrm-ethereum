// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {QuorumWork} from "./QuorumWork.sol";
import {QuorumMembership} from "./QuorumMembership.sol";
/// Immutable creation bytes. Runtime starts with STOP and has no callable mutation path.
contract QuorumCreationData {
    constructor(bytes memory code){
        require(code.length>0 && code.length<=24575,"creation data size");
        bytes memory data=bytes.concat(hex"00",code);
        assembly("memory-safe"){return(add(data,32),mload(data))}
    }
}
/// Created as part of the launch token constructor. No address setters or external deployment functions.
contract QuorumCodeCatalog {
    address public immutable workCreation;
    address public immutable membershipCreation;
    constructor(){
        workCreation=address(new QuorumCreationData(type(QuorumWork).creationCode));
        membershipCreation=address(new QuorumCreationData(type(QuorumMembership).creationCode));
    }
}
