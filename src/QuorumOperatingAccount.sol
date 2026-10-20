// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {IERC20Local} from "./QuorumMembership.sol";
interface IApproveAsset { function approve(address spender,uint256 amount) external returns(bool); }
struct OperatingCall { address target; uint256 value; bytes data; bytes32 returnHash; }
struct OperatingApproval { address asset; address spender; uint256 amount; }
struct OperatingPlan {
    uint256 primaryBudget; uint256 projectBudget; uint256 nativeBudget;
    OperatingApproval[] approvals; OperatingCall[] calls;
}
/// Persistent organizational identity, funded only for a single approved execution.
/// Supported fungible balances and temporary approvals are cleared after every successful batch.
contract QuorumOperatingAccount {
    address public immutable treasury;
    address public immutable primary;
    address public immutable project;
    constructor(address primary_,address project_){treasury=msg.sender;primary=primary_;project=project_;}
    receive() external payable {}
    function sweepBeforeOperation() external {
        require(msg.sender==treasury,"treasury");
        _returnAsset(primary);_returnAsset(project);
        // Native currency remains operating property, never a salary asset.
        if(address(this).balance>0){(bool ok,)=treasury.call{value:address(this).balance}("");require(ok,"native return");}
    }
    function execute(OperatingPlan calldata plan) external returns(uint256 returnedPrimary,uint256 returnedProject) {
        require(msg.sender==treasury,"treasury");
        for(uint256 i;i<plan.approvals.length;++i){
            OperatingApproval calldata a=plan.approvals[i];
            require((a.asset==primary || a.asset==project) && a.spender!=address(0),"approval asset");
            require(a.amount<=IERC20Local(a.asset).balanceOf(address(this)),"approval balance");
            require(IApproveAsset(a.asset).approve(a.spender,0) && IApproveAsset(a.asset).approve(a.spender,a.amount),"approve");
        }
        for(uint256 i;i<plan.calls.length;++i){
            OperatingCall calldata c=plan.calls[i];
            bool tokenCall=c.target==primary || c.target==project;
            if(tokenCall)require(c.data.length>=4 && bytes4(c.data[:4])==IERC20Local.transfer.selector,"token transfer only");
            (bool ok,bytes memory result)=c.target.call{value:c.value}(c.data);require(ok,"operating call failed");
            if(tokenCall)require(result.length==32 && abi.decode(result,(bool)),"token transfer failed");
            if(c.returnHash!=bytes32(0))require(keccak256(result)==c.returnHash,"return commitment");
        }
        for(uint256 i;i<plan.approvals.length;++i){
            OperatingApproval calldata a=plan.approvals[i];require(IApproveAsset(a.asset).approve(a.spender,0),"clear approval");
        }
        returnedPrimary=_returnAsset(primary);returnedProject=_returnAsset(project);
        if(address(this).balance>0){(bool ok,)=treasury.call{value:address(this).balance}("");require(ok,"native return");}
    }
    function _returnAsset(address asset) private returns(uint256 amount) {
        amount=IERC20Local(asset).balanceOf(address(this));
        if(amount>0)require(IERC20Local(asset).transfer(treasury,amount),"return funds");
    }
}
