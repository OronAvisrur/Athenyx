// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IEscrowGuarantors {
    enum GuarantorTier {
        NONE,
        SECONDARY,
        PRIMARY
    }

    struct GuarantorCommitment {
        address guarantor;
        GuarantorTier tier;
        uint256 stakeAmount;
        bytes32 commitmentHash;
        bool revealed;
        uint256 commitedAt;
    }

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
        uint256 slashedAmount
    );

    event GuarantorRewarded(
        uint256 indexed escrowId,
        address indexed guarantor,
        uint256 rewardAmount
    );

    error GuarantorAlreadyCommitted();
    error GuarantorNotCommitted();
    error InvalidCommitmentHash();
    error CommitmentWindowClosed();
    error RevealWindowNotOpen();
    error InsufficientStake();
    error InvalidTier();

    function commitAsGuarantor(
        uint256 escrowId,
        GuarantorTier tier,
        bytes32 commitmentHash
    ) external payable;

    function revealCommitment(
        uint256 escrowId,
        bytes32 secret
    ) external;

    function getGuarantors(uint256 escrowId) 
        external 
        view 
        returns (address[] memory);

    function getGuarantorCommitment(uint256 escrowId, address guarantor)
        external
        view
        returns (GuarantorCommitment memory);

    function isGuarantorVerified(uint256 escrowId, address guarantor)
        external
        view
        returns (bool);
}