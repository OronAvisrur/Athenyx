---
eip: TBD
title: Modular Escrow Standard
description: A minimal, composable framework for escrow contracts on EVM-compatible chains
author: Athenyx Team (@athenyx)
discussions-to: TBD
status: Draft
type: Standards Track
category: ERC
created: 2025-01-15
requires: 165
---

## Abstract

This EIP proposes a minimal, modular standard for escrow contracts that enables developers to compose escrow functionality from reusable components. The standard defines a core interface for basic escrow operations and optional extensions for advanced features like milestone-based payments and social collateral systems.

## Motivation

Current escrow implementations suffer from several limitations:

1. **Monolithic Design**: Most escrow contracts are all-or-nothing, forcing developers to include unused features
2. **High Gas Costs**: Unnecessary features increase deployment and execution costs
3. **Poor Composability**: Difficult to mix features from different implementations
4. **No Standard Interface**: Each implementation has unique APIs, hindering interoperability

This standard addresses these issues by providing:

- **Minimal Core**: ~200 lines for basic escrow functionality
- **Optional Extensions**: Add only the features you need
- **Composability**: Mix and match extensions freely
- **Standard Interface**: Consistent API across implementations

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174.

### Core Interface

Every compliant contract MUST implement the `IEscrowCore` interface:
```solidity
// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.0;

interface IEscrowCore {
    enum EscrowState {
        PENDING,
        ACTIVE,
        CANCELLED,
        COMPLETED,
        DISPUTED
    }

    struct EscrowBasicInfo {
        address creator;
        address beneficiary;
        address arbiter;
        uint256 amount;
        uint256 deadline;
        EscrowState state;
        uint256 createdAt;
    }

    /// @notice Creates a new escrow
    /// @param beneficiary Address that will receive funds on release
    /// @param arbiter Address authorized to mediate disputes
    /// @param amount Total amount required for escrow
    /// @param deadline Timestamp after which certain actions are allowed (0 = no deadline)
    /// @return escrowId Unique identifier for the created escrow
    function createEscrow(
        address beneficiary,
        address arbiter,
        uint256 amount,
        uint256 deadline
    ) external payable returns (uint256 escrowId);

    /// @notice Adds funds to a pending escrow
    /// @param escrowId The escrow to fund
    function fundEscrow(uint256 escrowId) external payable;

    /// @notice Releases escrowed funds to beneficiary
    /// @param escrowId The escrow to release
    function releaseEscrow(uint256 escrowId) external;

    /// @notice Cancels escrow and refunds creator
    /// @param escrowId The escrow to cancel
    function cancelEscrow(uint256 escrowId) external;

    /// @notice Returns escrow information
    /// @param escrowId The escrow to query
    /// @return info Escrow details
    function getEscrowInfo(uint256 escrowId) 
        external view returns (EscrowBasicInfo memory info);

    /// @notice Returns current escrow state
    /// @param escrowId The escrow to query
    /// @return Current state
    function getEscrowState(uint256 escrowId) 
        external view returns (EscrowState);

    /// @notice Returns the next escrow ID to be created
    /// @return Next escrow ID
    function nextEscrowId() external view returns (uint256);

    /// @dev Emitted when an escrow is created
    event EscrowCreated(
        uint256 indexed escrowId,
        address indexed creator,
        address indexed beneficiary,
        uint256 amount
    );

    /// @dev Emitted when an escrow receives funding
    event EscrowFunded(
        uint256 indexed escrowId,
        address indexed funder,
        uint256 amount
    );

    /// @dev Emitted when funds are released to beneficiary
    event EscrowReleased(
        uint256 indexed escrowId,
        address indexed beneficiary,
        uint256 amount
    );

    /// @dev Emitted when an escrow is cancelled
    event EscrowCancelled(
        uint256 indexed escrowId,
        uint256 refundAmount
    );

    /// @dev Emitted when an escrow is completed
    event EscrowCompleted(uint256 indexed escrowId);

    error ZeroAddress();
    error InvalidAmount();
    error InvalidDeadline();
    error EscrowNotFound();
    error InvalidState();
    error Unauthorized();
    error InsufficientFunds();
    error TransferFailed();
}
```

### State Transitions

An escrow MUST follow these state transitions:
```
PENDING ──fund──> ACTIVE ──release──> COMPLETED
   │                 │
   └──cancel────────┘
   │                 │
   └──cancel─────────> CANCELLED
```

### Authorization Rules

1. **createEscrow**: Anyone MAY create an escrow
2. **fundEscrow**: Anyone MAY fund a PENDING escrow
3. **releaseEscrow**: 
   - Creator MAY release at any time
   - Arbiter MAY release at any time
   - Beneficiary MAY release after deadline (if deadline > 0)
4. **cancelEscrow**:
   - Creator MAY cancel at any time
   - Arbiter MAY cancel at any time

### Extension: Milestone-Based Payments

Contracts implementing milestone functionality MUST implement `IEscrowMilestones`:
```solidity
interface IEscrowMilestones {
    struct Milestone {
        uint256 amount;
        uint256 deadline;
        bool approved;
        bool released;
        string description;
    }

    /// @notice Creates escrow with predefined milestones
    function createEscrowWithMilestones(
        address beneficiary,
        address arbiter,
        uint256[] calldata milestoneAmounts,
        uint256[] calldata milestoneDeadlines,
        string[] calldata milestoneDescriptions
    ) external payable returns (uint256 escrowId);

    /// @notice Approves a milestone for release
    function approveMilestone(uint256 escrowId, uint256 milestoneIndex) external;

    /// @notice Releases an approved milestone
    function releaseMilestone(uint256 escrowId, uint256 milestoneIndex) external;

    /// @notice Returns milestone details
    function getMilestone(uint256 escrowId, uint256 milestoneIndex)
        external view returns (Milestone memory);

    /// @notice Returns total number of milestones
    function getMilestoneCount(uint256 escrowId)
        external view returns (uint256);

    event MilestoneCreated(
        uint256 indexed escrowId,
        uint256 indexed milestoneIndex,
        uint256 amount,
        uint256 deadline
    );

    event MilestoneApproved(
        uint256 indexed escrowId,
        uint256 indexed milestoneIndex,
        address indexed approver
    );

    event MilestoneReleased(
        uint256 indexed escrowId,
        uint256 indexed milestoneIndex,
        uint256 amount
    );

    error InvalidMilestoneCount();
    error MilestoneNotFound();
    error MilestoneNotApproved();
    error MilestoneAlreadyApproved();
    error MilestoneAlreadyReleased();
}
```

### Extension: Social Collateral (Guarantors)

Contracts implementing guarantor functionality MUST implement `IEscrowGuarantors`:
```solidity
interface IEscrowGuarantors {
    enum GuarantorTier {
        NONE,
        PRIMARY,
        SECONDARY
    }

    struct GuarantorCommitment {
        address guarantor;
        GuarantorTier tier;
        uint256 stakeAmount;
        bytes32 commitmentHash;
        bool revealed;
        uint256 commitedAt;
    }

    /// @notice Creates escrow requiring guarantor verification
    function createEscrowWithGuarantors(
        address beneficiary,
        address arbiter,
        uint256 amount,
        uint256 deadline,
        uint256 minGuarantors
    ) external payable returns (uint256 escrowId);

    /// @notice Commits to guarantee an escrow (commit phase)
    function commitAsGuarantor(
        uint256 escrowId,
        GuarantorTier tier,
        bytes32 commitmentHash
    ) external payable;

    /// @notice Reveals commitment (reveal phase)
    function revealCommitment(uint256 escrowId, bytes32 secret) external;

    /// @notice Returns all guarantors for an escrow
    function getGuarantors(uint256 escrowId)
        external view returns (address[] memory);

    /// @notice Checks if guarantor is verified
    function isGuarantorVerified(uint256 escrowId, address guarantor)
        external view returns (bool);

    event GuarantorCommitted(
        uint256 indexed escrowId,
        address indexed guarantor,
        GuarantorTier tier,
        uint256 stakeAmount
    );

    event GuarantorRevealed(
        uint256 indexed escrowId,
        address indexed guarantor
    );

    event GuarantorSlashed(
        uint256 indexed escrowId,
        address indexed guarantor,
        uint256 slashAmount
    );

    error CommitmentWindowClosed();
    error RevealWindowNotOpen();
    error GuarantorNotCommitted();
    error GuarantorAlreadyCommitted();
    error InvalidCommitmentHash();
    error InsufficientStake();
    error InvalidTier();
}
```

### ERC-165 Support

Compliant contracts MUST implement ERC-165 and return `true` for the appropriate interface IDs:
```solidity
interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}
```

Interface IDs:
- `IEscrowCore`: `0x????????` (TBD)
- `IEscrowMilestones`: `0x????????` (TBD)
- `IEscrowGuarantors`: `0x????????` (TBD)

## Rationale

### Why Modular Design?

1. **Gas Efficiency**: Deploy only what you need. A simple escrow costs ~200 lines vs 1000+ in monolithic designs.
2. **Flexibility**: Compose features like LEGO blocks
3. **Upgradability**: Add extensions without modifying core
4. **Specialization**: Different use cases need different features

### Why Separate Milestones Extension?

Not all escrows need milestone functionality. Simple escrows (e.g., "pay on delivery") should not pay the gas overhead for complex milestone logic.

### Why Commit-Reveal for Guarantors?

Prevents front-running and collusion. Guarantors commit blindly, then reveal after commitment window closes.

### Why Custom Errors?

Custom errors (EIP-838) reduce gas costs by ~70% compared to revert strings while maintaining debuggability.

## Backwards Compatibility

This EIP introduces new interfaces and does not conflict with existing standards.

Contracts implementing this standard MAY also implement:
- ERC-721 for NFT-based escrow ownership
- ERC-20 for token-based escrows
- Other EIPs as needed

## Reference Implementation

See: [https://github.com/athenyx/contracts](https://github.com/athenyx/contracts)
```solidity
// Minimal implementation (200 lines)
contract SimpleEscrow is IEscrowCore, ReentrancyGuard {
    // See contracts/standard/core/EscrowCore.sol
}

// With milestones
contract MilestoneEscrow is SimpleEscrow, IEscrowMilestones {
    // See contracts/standard/extensions/EscrowMilestones.sol
}

// Full-featured
contract FullEscrow is MilestoneEscrow, IEscrowGuarantors {
    // See contracts/standard/examples/FullFeaturedEscrow.sol
}
```

## Security Considerations

### Reentrancy

All state changes MUST occur before external calls (Checks-Effects-Interactions pattern). Implementations SHOULD use ReentrancyGuard or equivalent.

### Integer Overflow

Use Solidity >= 0.8.0 for automatic overflow protection, or SafeMath for older versions.

### Authorization

Implementations MUST validate:
- Beneficiary is not zero address
- Amount is greater than zero
- Caller has permission for restricted functions

### Front-running

The guarantor commit-reveal mechanism mitigates front-running attacks. Implementations SHOULD enforce:
- Minimum 24-hour commitment window
- Separate reveal window

### Griefing

Implementations SHOULD consider:
- Deadline enforcement to prevent indefinite locking
- Arbiter role for dispute resolution
- Minimum stake requirements for guarantors

## Copyright

Copyright and related rights waived via [CC0](../LICENSE).

---

## Appendix A: Gas Benchmarks

| Operation | SimpleEscrow | MilestoneEscrow | FullEscrow |
|-----------|--------------|-----------------|------------|
| Deploy | ~500k | ~800k | ~1.2M |
| Create | ~100k | ~150k | ~180k |
| Fund | ~50k | ~50k | ~50k |
| Release | ~40k | ~60k | ~80k |

## Appendix B: Comparison with Existing Solutions

| Feature | This EIP | OpenZeppelin | Custom Solutions |
|---------|----------|--------------|------------------|
| Modularity | ✅ | ❌ | ⚠️ |
| Gas Optimization | ✅ | ⚠️ | ⚠️ |
| Standard Interface | ✅ | ❌ | ❌ |
| Milestones | ✅ | ❌ | ⚠️ |
| Guarantors | ✅ | ❌ | ❌ |

## Appendix C: Future Extensions

Potential future extensions include:
- Multi-token support (ERC-20, ERC-721, ERC-1155)
- Automated insurance integration
- Oracle-based release conditions
- Multi-signature arbiter systems