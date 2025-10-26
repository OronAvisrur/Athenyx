// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IGuarantorRegistry {
    enum GuarantorTier {
        NONE,
        SECONDARY,
        PRIMARY
    }

    struct GuarantorProfile {
        address guarantorAddress;
        uint256 reputationScore;
        uint256 totalStaked;
        uint256 availableStake;
        uint256 successfulGuarantees;
        uint256 failedGuarantees;
        uint256 activeGuarantees;
        bool isBanned;
        uint256 bannedUntil;
        uint256 registeredAt;
    }

    struct GuarantorCommitment {
        address guarantorAddress;
        uint256 escrowId;
        GuarantorTier tier;
        uint256 stakedAmount;
        bytes32 commitmentHash;
        uint256 commitmentTimestamp;
        bool isRevealed;
        bool isActive;
    }

    event GuarantorRegistered(address indexed guarantor, uint256 timestamp);
    event GuarantorCommitted(address indexed guarantor, uint256 indexed escrowId, GuarantorTier tier, uint256 stake);
    event GuarantorRevealed(address indexed guarantor, uint256 indexed escrowId, bytes32 secret);
    event GuarantorSlashed(address indexed guarantor, uint256 indexed escrowId, uint256 slashedAmount);
    event GuarantorRewarded(address indexed guarantor, uint256 indexed escrowId, uint256 rewardAmount);
    event ReputationUpdated(address indexed guarantor, int256 change, uint256 newScore);
    event GuarantorBannedEvent(address indexed guarantor, uint256 bannedUntil, string reason);

    error GuarantorNotRegistered();
    error GuarantorIsBanned();
    error InsufficientReputation(uint256 required, uint256 current);
    error InsufficientStake(uint256 required, uint256 available);
    error CommitmentAlreadyExists();
    error CommitmentNotFound();
    error RevealWindowClosed();
    error InvalidSecret();
    error CollusionDetected();

    function registerGuarantor() external;
    
    function commitAsGuarantor(
        uint256 escrowId,
        GuarantorTier tier,
        uint256 stakeAmount,
        bytes32 commitmentHash
    ) external;
    
    function revealCommitment(
        uint256 escrowId,
        bytes32 secret
    ) external;
    
    function slashGuarantor(
        address guarantor,
        uint256 escrowId,
        uint256 amount
    ) external;
    
    function rewardGuarantor(
        address guarantor,
        uint256 escrowId,
        uint256 amount
    ) external;
    
    function updateReputation(
        address guarantor,
        int256 change
    ) external;
    
    function banGuarantor(
        address guarantor,
        uint256 duration,
        string calldata reason
    ) external;
    
    function getGuarantorProfile(address guarantor) external view returns (GuarantorProfile memory);
    
    function getCommitment(
        uint256 escrowId,
        address guarantor
    ) external view returns (GuarantorCommitment memory);
    
    function isEligibleGuarantor(
        address guarantor,
        GuarantorTier tier,
        uint256 requiredStake
    ) external view returns (bool);
    
    function getEscrowGuarantors(uint256 escrowId) external view returns (address[] memory);
}