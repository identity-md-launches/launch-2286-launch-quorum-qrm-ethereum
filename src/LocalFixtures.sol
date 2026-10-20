// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice TEST ASSET ONLY. Public minting; never use as a launch token.
contract LocalToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function approve(address to, uint256 amount) external returns (bool) { allowance[msg.sender][to] = amount; return true; }
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount; balanceOf[to] += amount; return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount; balanceOf[from] -= amount; balanceOf[to] += amount; return true;
    }
}
/// @notice Test ownerOf adapter, not the live IMD NFT.
contract LocalSeats {
    mapping(uint256 => address) public ownerOf;
    function mint(address to, uint256 id) external { require(ownerOf[id] == address(0), "exists"); ownerOf[id] = to; }
    function transferFrom(address from, address to, uint256 id) external {
        require(msg.sender == from && ownerOf[id] == from && to != address(0), "owner"); ownerOf[id] = to;
    }
}
