// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {QuorumLaunchToken} from "./QuorumLaunchToken.sol";
/// QUORUM release preparation. Addresses are predicted and NOT yet deployed.
/// Dependency receipts and runtime verification: see PREREQUISITES.json.
contract QuorumToken is QuorumLaunchToken {
 constructor() QuorumLaunchToken("QUORUM","QRM",
  address(bytes20(hex"d34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7")),62500 ether,
  address(bytes20(hex"5f8c721d44d5815ae9e6d54ff20e717d56ec0d91")),address(bytes20(hex"48a78afb5397abeab5be23473973c5c62497cf55"))) {}
}
