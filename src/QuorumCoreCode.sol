// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {QuorumBoundCore} from "./QuorumBoundCore.sol";
import {IERC20Local} from "./QuorumMembership.sol";
import {ConstitutionPrototype} from "./ConstitutionPrototype.sol";
contract CoreCodePart {
 constructor(bytes memory code) {
  require(code.length>0 && code.length<=24575,"part length");
  bytes memory data=bytes.concat(hex"00",code);
  assembly("memory-safe"){return(add(data,32),mload(data))}
 }
}
/// EXPERIMENT: immutable creation bytes; no owner, setters, proxy or delegatecall.
/// Each caller receives a fresh core whose reward reporter is exactly that caller.
contract QuorumCoreCode {
 address public immutable part0;
 address public immutable part1;
 bytes32 public immutable creationHash;
 constructor(bytes memory first,bytes memory second,bytes32 expectedHash) {
  require(keccak256(bytes.concat(first,second))==expectedHash,"creation hash");
  part0=address(new CoreCodePart(first));part1=address(new CoreCodePart(second));creationHash=expectedHash;
 }
 function create(address token,address asset,uint256 stake,ConstitutionPrototype constitution) external returns(QuorumBoundCore core){
  address a=part0;address b=part1;
  uint256 n=a.code.length-1;uint256 m=b.code.length-1;
  bytes memory code=new bytes(n+m);
  assembly("memory-safe") { extcodecopy(a,add(code,32),1,n) extcodecopy(b,add(add(code,32),n),1,m) }
  require(keccak256(code)==creationHash,"creation hash");
  code=bytes.concat(code,abi.encode(IERC20Local(token),IERC20Local(asset),stake,constitution,msg.sender));
  address created;
  assembly("memory-safe") {created:=create(0,add(code,32),mload(code))}
  require(created!=address(0),"core creation");return QuorumBoundCore(created);
 }
}
