// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
interface LaunchRegistry { struct Artifact { bytes32 role; bytes32 name; address addr; } function writer() external view returns(address); function isRecorded(uint64 number) external view returns(bool); function artifactsOf(uint64 number) external view returns(Artifact[] memory); }
interface IImdFactoryRecord { function registry() external view returns (LaunchRegistry); }
interface IImdDistributor {
    struct Round { bytes32 root; uint256 funded; uint256 claimed; uint64 unlocksAt; }
    function token() external view returns (address);
    function opener() external view returns (address);
    function roundOf(uint256 round) external view returns (Round memory);
}
/// Verifies original wallet allocations against the actual factory record and round zero.
/// Does not infer tokenIds, online count N, owner consent, or weekly qualification from a wallet proof.
library ImdLaunchProof {
    function resolve(address factory, uint64 number, address token, address hook) internal view returns (IImdDistributor distributor) {
        LaunchRegistry registry = IImdFactoryRecord(factory).registry();
        require(registry.writer() == factory && registry.isRecorded(number), "factory record");
        LaunchRegistry.Artifact[] memory artifacts = registry.artifactsOf(number);
        bool foundToken; bool foundHook;
        for (uint256 i; i < artifacts.length; ++i) {
            if (artifacts[i].role == bytes32("token")) foundToken = artifacts[i].addr == token;
            if (artifacts[i].role == bytes32("hook")) foundHook = artifacts[i].addr == hook;
            if (artifacts[i].role == bytes32("distributor")) distributor = IImdDistributor(artifacts[i].addr);
        }
        require(foundToken && foundHook && address(distributor) != address(0), "launch binding");
        require(distributor.token() == token && distributor.opener() == factory, "distributor binding");
    }
    function original(address factory, uint64 number, address token, address hook, address wallet, uint256 amount, bytes32[] memory proof) internal view returns (bytes32 root) {
        IImdDistributor distributor = resolve(factory, number, token, hook);
        root = distributor.roundOf(0).root;
        require(amount > 0 && MerkleProof.verify(proof, root, leaf(wallet, amount)), "original allocation");
    }
    function leaf(address wallet, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(wallet, amount))));
    }
}
