// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {QuorumTreasury} from "./QuorumTreasury.sol";
/// Immutable adapter for protocols paying plain token transfers rather than calling depositRevenue.
/// Anyone can account received revenue; destinations and the accounting asset cannot be changed.
/// Only the configured asset is handled; this is not a multiasset treasury or a converter.
contract QuorumRevenueSink {
    using SafeERC20 for IERC20;
    QuorumTreasury public immutable treasury;
    IERC20 public immutable asset;
    constructor(QuorumTreasury target) {
        require(address(target)!=address(0), "treasury");
        treasury=target; asset=IERC20(address(target.asset()));
        asset.forceApprove(address(target),type(uint256).max);
    }
    function flush() external returns(uint256 amount) {
        amount=asset.balanceOf(address(this));
        if(amount>0) treasury.depositRevenue(amount);
    }
}
