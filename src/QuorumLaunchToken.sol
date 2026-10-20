// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {ERC20} from "../lib/openzeppelin-token-v5.4.0/contracts/token/ERC20/ERC20.sol";
import {QuorumCoreCode} from "./QuorumCoreCode.sol";
import {ConstitutionPrototype} from "./ConstitutionPrototype.sol";
contract QuorumLaunchToken is ERC20 {
 uint256 public constant SUPPLY=1_000_000_000 ether;
 ConstitutionPrototype public immutable constitution;
 QuorumCoreCode public immutable coreCode;
 address public immutable revenueToken;
 uint256 public immutable stakeAmount;
 constructor(string memory name_,string memory symbol_,address imd,uint256 stake,address catalog,address approvedText) ERC20(name_,symbol_){
  require(catalog.code.length>0 && approvedText.code.length>0,"predeployed immutable code");
  require(imd!=address(0) && stake>0 && stake<=SUPPLY,"configuration");
  coreCode=QuorumCoreCode(catalog);constitution=ConstitutionPrototype(approvedText);
  revenueToken=imd;stakeAmount=stake;_mint(msg.sender,SUPPLY);
 }
}
