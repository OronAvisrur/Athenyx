// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../core/EscrowCore.sol";
import "../interfaces/IEscrowGuarantors.sol";

abstract contract EscrowGuarantors is EscrowCore, IEscrowGuarantors {
    uint256 public constant COMMITMENT_WINDOW = 48 hours;
    uint256 public constant REVEAL_WINDOW = 24 hours;
    uint256 public constant MIN_PRIMARY_STAKE_PERCENTAGE = 20;
    uint256 public constant MIN_SECONDARY_STAKE_PERCENTAGE = 10;

    mapping(uint256 => mapping(address => GuarantorCommitment)) private guarantorCommitments;
    mapping(uint256 => address[]) private escrowGuarantors;
    mapping(uint256 => uint256) private escrowCommitmentDeadline;
    mapping(uint256 => uint256) private escrowMinGuarantors;

    error InsufficientGuarantors();

    function createEscrowWithGuarantors(
        address beneficiary,
        address arbiter,
        uint256 amount,
        uint256 deadline,
        uint256 minGuarantors
    ) external payable returns (uint256 escrowId) {
        escrowId = _createEscrowInternal(
            msg.sender,
            beneficiary,
            arbiter,
            amount,
            msg.value,
            deadline
        );

        escrowCommitmentDeadline[escrowId] = block.timestamp + COMMITMENT_WINDOW;
        escrowMinGuarantors[escrowId] = minGuarantors;

        return escrowId;
    }

    function commitAsGuarantor(
        uint256 escrowId,
        GuarantorTier tier,
        bytes32 commitmentHash
    ) external payable virtual escrowExists(escrowId) {
        if (block.timestamp > escrowCommitmentDeadline[escrowId]) {
            revert CommitmentWindowClosed();
        }
        if (guarantorCommitments[escrowId][msg.sender].commitedAt != 0) {
            revert GuarantorAlreadyCommitted();
        }
        if (tier == GuarantorTier.NONE) revert InvalidTier();

        Escrow storage escrow = _getEscrow(escrowId);
        uint256 minStake = (escrow.amount * 
            (tier == GuarantorTier.PRIMARY ? MIN_PRIMARY_STAKE_PERCENTAGE : MIN_SECONDARY_STAKE_PERCENTAGE)) 
            / 100;

        if (msg.value < minStake) revert InsufficientStake();

        guarantorCommitments[escrowId][msg.sender] = GuarantorCommitment({
            guarantor: msg.sender,
            tier: tier,
            stakeAmount: msg.value,
            commitmentHash: commitmentHash,
            revealed: false,
            commitedAt: block.timestamp
        });

        escrowGuarantors[escrowId].push(msg.sender);

        emit GuarantorCommitted(escrowId, msg.sender, tier, msg.value);
    }

    function revealCommitment(
        uint256 escrowId,
        bytes32 secret
    ) external virtual escrowExists(escrowId) {
        if (block.timestamp <= escrowCommitmentDeadline[escrowId]) {
            revert RevealWindowNotOpen();
        }
        if (block.timestamp > escrowCommitmentDeadline[escrowId] + REVEAL_WINDOW) {
            revert RevealWindowNotOpen();
        }

        GuarantorCommitment storage commitment = guarantorCommitments[escrowId][msg.sender];
        
        if (commitment.commitedAt == 0) revert GuarantorNotCommitted();
        if (commitment.revealed) revert GuarantorAlreadyCommitted();

        bytes32 expectedHash = keccak256(
            abi.encodePacked(msg.sender, secret, escrowId)
        );

        if (expectedHash != commitment.commitmentHash) {
            revert InvalidCommitmentHash();
        }

        commitment.revealed = true;

        emit GuarantorRevealed(escrowId, msg.sender);

        _checkMinGuarantorsRevealed(escrowId);
    }

    function slashGuarantor(
        uint256 escrowId,
        address guarantor,
        uint256 slashAmount
    ) external virtual escrowExists(escrowId) onlyArbiter(escrowId) {
        GuarantorCommitment storage commitment = guarantorCommitments[escrowId][guarantor];
        
        if (commitment.commitedAt == 0) revert GuarantorNotCommitted();
        if (slashAmount > commitment.stakeAmount) revert InsufficientStake();

        commitment.stakeAmount -= slashAmount;

        Escrow storage escrow = _getEscrow(escrowId);
        escrow.funded += slashAmount;

        emit GuarantorSlashed(escrowId, guarantor, slashAmount);
    }

    function rewardGuarantor(
        uint256 escrowId,
        address guarantor,
        uint256 rewardAmount
    ) external virtual escrowExists(escrowId) {
        GuarantorCommitment storage commitment = guarantorCommitments[escrowId][guarantor];
        
        if (commitment.commitedAt == 0) revert GuarantorNotCommitted();

        uint256 totalReturn = commitment.stakeAmount + rewardAmount;
        commitment.stakeAmount = 0;

        (bool success, ) = guarantor.call{value: totalReturn}("");
        if (!success) revert TransferFailed();

        emit GuarantorRewarded(escrowId, guarantor, rewardAmount);
    }

    function getGuarantors(uint256 escrowId)
        external
        view
        virtual
        escrowExists(escrowId)
        returns (address[] memory)
    {
        return escrowGuarantors[escrowId];
    }

    function getGuarantorCommitment(uint256 escrowId, address guarantor)
        external
        view
        virtual
        escrowExists(escrowId)
        returns (GuarantorCommitment memory)
    {
        return guarantorCommitments[escrowId][guarantor];
    }

    function isGuarantorVerified(uint256 escrowId, address guarantor)
        external
        view
        virtual
        escrowExists(escrowId)
        returns (bool)
    {
        GuarantorCommitment storage commitment = guarantorCommitments[escrowId][guarantor];
        return commitment.revealed && commitment.commitedAt != 0;
    }

    function _checkMinGuarantorsRevealed(uint256 escrowId) internal view {
        uint256 minRequired = escrowMinGuarantors[escrowId];
        if (minRequired == 0) return;

        uint256 revealedCount = 0;
        address[] storage guarantors = escrowGuarantors[escrowId];

        for (uint256 i = 0; i < guarantors.length; i++) {
            if (guarantorCommitments[escrowId][guarantors[i]].revealed) {
                revealedCount++;
            }
        }

        if (revealedCount < minRequired) {
            revert InsufficientGuarantors();
        }
    }

    function _onEscrowCompleted(uint256 escrowId) internal virtual override {
        address[] storage guarantors = escrowGuarantors[escrowId];
        
        for (uint256 i = 0; i < guarantors.length; i++) {
            GuarantorCommitment storage commitment = guarantorCommitments[escrowId][guarantors[i]];
            
            if (commitment.stakeAmount > 0) {
                (bool success, ) = guarantors[i].call{value: commitment.stakeAmount}("");
                require(success, "Guarantor refund failed");
                commitment.stakeAmount = 0;
            }
        }

        super._onEscrowCompleted(escrowId);
    }
}