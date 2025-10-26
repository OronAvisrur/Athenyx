// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IGuarantorRegistry.sol";
import "./interfaces/IReputationSystem.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract GuarantorRegistry is IGuarantorRegistry, ReentrancyGuard, Ownable {
    uint256 public constant INITIAL_REPUTATION = 100;
    uint256 public constant MIN_REPUTATION_PRIMARY = 200;
    uint256 public constant MIN_REPUTATION_SECONDARY = 100;
    uint256 public constant REPUTATION_SUCCESS_BONUS = 10;
    uint256 public constant REPUTATION_FAILURE_PENALTY = 50;
    uint256 public constant REPUTATION_COLLUSION_PENALTY = 100;
    uint256 public constant WHISTLEBLOWER_BONUS = 20;
    uint256 public constant BAN_DURATION_FAILURE = 30 days;
    uint256 public constant BAN_DURATION_COLLUSION = 365 days;
    
    uint256 public constant COMMITMENT_WINDOW = 2 days;
    uint256 public constant REVEAL_WINDOW = 1 days;
    
    uint256 public constant MIN_STAKE_PERCENTAGE = 10;
    uint256 public constant MAX_STAKE_PERCENTAGE = 30;

    mapping(address => GuarantorProfile) private guarantorProfiles;
    mapping(uint256 => mapping(address => GuarantorCommitment)) private escrowCommitments;
    mapping(uint256 => address[]) private escrowGuarantorsList;
    mapping(uint256 => mapping(bytes32 => bool)) private usedSecrets;
    mapping(uint256 => uint256) private escrowCommitmentDeadlines;
    
    address public athenyxCore;
    
    modifier onlyCore() {
        if (msg.sender != athenyxCore) revert Unauthorized();
        _;
    }
    
    modifier notBanned(address guarantor) {
        GuarantorProfile storage profile = guarantorProfiles[guarantor];
        if (profile.isBanned && block.timestamp < profile.bannedUntil) {
            revert GuarantorIsBanned();
        }
        _;
    }

    error Unauthorized();
    error AlreadyRegistered();
    error InvalidStakeAmount();
    error InvalidTier();
    error InvalidAddress();

    constructor() Ownable(msg.sender) {}
    
    function setAthenyxCore(address coreAddress) external onlyOwner {
        if (coreAddress == address(0)) revert InvalidAddress();
        athenyxCore = coreAddress;
    }

    function registerGuarantor() external {
        GuarantorProfile storage profile = guarantorProfiles[msg.sender];
        
        if (profile.registeredAt != 0) revert AlreadyRegistered();
        
        profile.guarantorAddress = msg.sender;
        profile.reputationScore = INITIAL_REPUTATION;
        profile.totalStaked = 0;
        profile.availableStake = 0;
        profile.successfulGuarantees = 0;
        profile.failedGuarantees = 0;
        profile.activeGuarantees = 0;
        profile.isBanned = false;
        profile.bannedUntil = 0;
        profile.registeredAt = block.timestamp;
        
        emit GuarantorRegistered(msg.sender, block.timestamp);
    }

    function commitAsGuarantor(
        uint256 escrowId,
        GuarantorTier tier,
        uint256 stakeAmount,
        bytes32 commitmentHash
    ) external notBanned(msg.sender) {
        GuarantorProfile storage profile = guarantorProfiles[msg.sender];
        
        if (profile.registeredAt == 0) revert GuarantorNotRegistered();
        if (escrowCommitments[escrowId][msg.sender].commitmentTimestamp != 0) {
            revert CommitmentAlreadyExists();
        }
        if (stakeAmount == 0) revert InvalidStakeAmount();
        if (tier == GuarantorTier.NONE) revert InvalidTier();
        
        if (tier == GuarantorTier.PRIMARY && profile.reputationScore < MIN_REPUTATION_PRIMARY) {
            revert InsufficientReputation(MIN_REPUTATION_PRIMARY, profile.reputationScore);
        }
        if (tier == GuarantorTier.SECONDARY && profile.reputationScore < MIN_REPUTATION_SECONDARY) {
            revert InsufficientReputation(MIN_REPUTATION_SECONDARY, profile.reputationScore);
        }
        
        GuarantorCommitment storage commitment = escrowCommitments[escrowId][msg.sender];
        commitment.guarantorAddress = msg.sender;
        commitment.escrowId = escrowId;
        commitment.tier = tier;
        commitment.stakedAmount = stakeAmount;
        commitment.commitmentHash = commitmentHash;
        commitment.commitmentTimestamp = block.timestamp;
        commitment.isRevealed = false;
        commitment.isActive = true;
        
        escrowGuarantorsList[escrowId].push(msg.sender);
        profile.activeGuarantees++;
        profile.totalStaked += stakeAmount;
        
        if (escrowCommitmentDeadlines[escrowId] == 0) {
            escrowCommitmentDeadlines[escrowId] = block.timestamp + COMMITMENT_WINDOW;
        }
        
        emit GuarantorCommitted(msg.sender, escrowId, tier, stakeAmount);
    }

    function revealCommitment(
        uint256 escrowId,
        bytes32 secret
    ) external {
        GuarantorCommitment storage commitment = escrowCommitments[escrowId][msg.sender];
        
        if (commitment.commitmentTimestamp == 0) revert CommitmentNotFound();
        if (commitment.isRevealed) revert CommitmentAlreadyExists();
        
        uint256 commitDeadline = escrowCommitmentDeadlines[escrowId];
        if (block.timestamp < commitDeadline || block.timestamp > commitDeadline + REVEAL_WINDOW) {
            revert RevealWindowClosed();
        }
        
        bytes32 expectedHash = keccak256(abi.encodePacked(msg.sender, secret, escrowId));
        if (expectedHash != commitment.commitmentHash) revert InvalidSecret();
        
        if (usedSecrets[escrowId][secret]) revert CollusionDetected();
        
        usedSecrets[escrowId][secret] = true;
        commitment.isRevealed = true;
        
        emit GuarantorRevealed(msg.sender, escrowId, secret);
    }

    function slashGuarantor(
        address guarantor,
        uint256 escrowId,
        uint256 amount
    ) external onlyCore nonReentrant {
        GuarantorProfile storage profile = guarantorProfiles[guarantor];
        GuarantorCommitment storage commitment = escrowCommitments[escrowId][guarantor];
        
        if (commitment.stakedAmount < amount) {
            amount = commitment.stakedAmount;
        }
        
        commitment.stakedAmount -= amount;
        profile.totalStaked -= amount;
        profile.failedGuarantees++;
        profile.activeGuarantees--;
        
        emit GuarantorSlashed(guarantor, escrowId, amount);
    }

    function rewardGuarantor(
        address guarantor,
        uint256 escrowId,
        uint256 amount
    ) external onlyCore nonReentrant {
        GuarantorProfile storage profile = guarantorProfiles[guarantor];
        GuarantorCommitment storage commitment = escrowCommitments[escrowId][guarantor];
        
        profile.successfulGuarantees++;
        profile.activeGuarantees--;
        
        uint256 totalReturn = commitment.stakedAmount + amount;
        commitment.stakedAmount = 0;
        profile.totalStaked -= commitment.stakedAmount;
        
        (bool success, ) = guarantor.call{value: totalReturn}("");
        if (!success) revert TransferFailed();
        
        emit GuarantorRewarded(guarantor, escrowId, amount);
    }

    function updateReputation(
        address guarantor,
        int256 change
    ) external onlyCore {
        GuarantorProfile storage profile = guarantorProfiles[guarantor];
        
        if (change > 0) {
            profile.reputationScore += uint256(change);
        } else {
            uint256 decrease = uint256(-change);
            if (profile.reputationScore > decrease) {
                profile.reputationScore -= decrease;
            } else {
                profile.reputationScore = 0;
            }
        }
        
        emit ReputationUpdated(guarantor, change, profile.reputationScore);
    }

    function banGuarantor(
        address guarantor,
        uint256 duration,
        string calldata reason
    ) external onlyCore {
        GuarantorProfile storage profile = guarantorProfiles[guarantor];
        
        profile.isBanned = true;
        profile.bannedUntil = block.timestamp + duration;
        
        emit GuarantorBannedEvent(guarantor, profile.bannedUntil, reason);
    }

    function getGuarantorProfile(address guarantor) external view returns (GuarantorProfile memory) {
        return guarantorProfiles[guarantor];
    }

    function getCommitment(
        uint256 escrowId,
        address guarantor
    ) external view returns (GuarantorCommitment memory) {
        return escrowCommitments[escrowId][guarantor];
    }

    function isEligibleGuarantor(
        address guarantor,
        GuarantorTier tier,
        uint256 requiredStake
    ) external view returns (bool) {
        GuarantorProfile storage profile = guarantorProfiles[guarantor];
        
        if (profile.registeredAt == 0) return false;
        if (profile.isBanned && block.timestamp < profile.bannedUntil) return false;
        if (profile.availableStake < requiredStake) return false;
        
        if (tier == GuarantorTier.PRIMARY) {
            return profile.reputationScore >= MIN_REPUTATION_PRIMARY;
        } else if (tier == GuarantorTier.SECONDARY) {
            return profile.reputationScore >= MIN_REPUTATION_SECONDARY;
        }
        
        return false;
    }

    function getEscrowGuarantors(uint256 escrowId) external view returns (address[] memory) {
        return escrowGuarantorsList[escrowId];
    }

    error TransferFailed();

    receive() external payable {}
}