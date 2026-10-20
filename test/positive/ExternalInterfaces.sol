// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
// ABI facade only. Tests deploy untouched verified implementations built with Solc 0.8.26.
interface FactoryRegistry {
    struct Launch {
        bytes32 kind;
        /// @dev Position in the network's launch history, carried over from the job that produced it.
        uint64 launchNumber;
        uint64 recordedAt;
        /// @dev Git commit of the delivered tree, and the hash of the document that attested it.
        bytes32 sourceCommit;
        bytes32 manifestHash;
        bytes32 attestationHash;
        /// @dev Ed25519 public key of the verifier that signed the attestation.
        bytes32 verifierKey;
        string sourceRepoUrl;
    }
 function isRecorded(uint64 number) external view returns(bool);
}
interface LaunchFactory {
    struct LaunchParams {
        uint64 launchNumber;
        bytes32 kind;
        /// @dev Creation code with constructor arguments already appended. The verifier attested the
        /// code without arguments; the deployer appends them and this recomputes what it deploys.
        bytes tokenCreationCode;
        bytes hookCreationCode;
        /// @dev Mined off chain until the resulting address carries exactly `hookFlags`.
        bytes32 hookSalt;
        uint160 hookFlags;
        /// @dev The whole supply, which the token must mint to this factory in its constructor.
        uint256 totalSupply;
        /// @dev Share of the whole supply the pool may take, the requester's choice within its 90%.
        /// The seed is rolled back if it takes more.
        uint16 poolBps;
        /// @dev Receives what the swarm and the pool leave: the requester's wallet, or zero for the
        /// chain's treasury (`LaunchFees.treasury()`), as for a launch nobody paid for.
        address remainderTo;
        bytes32 merkleRoot;
        uint64 contributorLockSeconds;
        uint64 sweepDelaySeconds;
        /// @dev The other side of the pair. Must sort below or above the launched token; the factory
        /// orders the key itself rather than trusting the caller to.
        Currency pairedCurrency;
        uint24 fee;
        int24 tickSpacing;
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        FactoryRegistry.Launch record;
        uint256[] agentIds;
        /// @dev Who shares the pool's LP fees with the network: the wallet that paid for the launch, or zero.
        address requester;
    }
 function predictToken(uint64 number,bytes calldata code) external view returns(address);
 function predictHook(bytes calldata code,bytes32 salt) external view returns(address);
 function launch(LaunchParams calldata params) external returns(address,address,address);
 function registry() external view returns(FactoryRegistry);
 function positionOf(uint64 number) external view returns(PoolKey memory,int24,int24,address);
 function claimFees(uint64 number) external returns(uint256,uint256);
}
interface MerkleDistributor {
 struct Round { bytes32 root; uint256 funded; uint256 claimed; uint64 unlocksAt; }
 function roundOf(uint256 round) external view returns(Round memory);
 function claim(uint256 round,address wallet,uint256 amount,bytes32[] calldata proof) external;
 function claimed(uint256 round,address wallet) external view returns(bool);
}
