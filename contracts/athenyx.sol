// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

contract Athenyx is ReentrancyGuard, ERC721, EIP712 {
    using ECDSA for bytes32;

    string public constant DOMAIN = "athenyx.brave";
    uint256 public nextEscrowId;

    enum EscrowState {
        ACTIVE,
        CANCELLED,
        COMPLETED,
        DISPUTED
    }

    struct Milestone {
        uint256 amount;
        uint256 deadline;
        bool approved;
        bool released;
        bytes32 approvalHash;
    }

    struct Escrow {
        address[] payers;
        mapping(address => uint256) contributions;
        address seller;
        address arbiter;
        uint256 totalFunded;
        uint256 totalReleased;
        uint256 arbiterFee;
        EscrowState state;
        Milestone[] milestones;
        uint256 createdAt;
    }

    mapping(uint256 => Escrow) private escrows;
    mapping(uint256 => mapping(address => bool)) public hasContributed;

    bytes32 private constant APPROVAL_TYPEHASH = keccak256(
        "MilestoneApproval(uint256 escrowId,uint256 milestoneIndex,uint256 nonce,uint256 deadline)"
    );

    mapping(address => uint256) public nonces;

    event EscrowCreated(
        uint256 indexed escrowId,
        address indexed seller,
        address indexed arbiter,
        uint256 totalAmount,
        uint256 arbiterFee
    );
    event ContributionAdded(uint256 indexed escrowId, address indexed payer, uint256 amount);
    event MilestoneApproved(uint256 indexed escrowId, uint256 indexed milestoneIndex, address approver);
    event MilestoneReleased(uint256 indexed escrowId, uint256 indexed milestoneIndex, uint256 amount);
    event EscrowCancelled(uint256 indexed escrowId, uint256 refundAmount);
    event EscrowCompleted(uint256 indexed escrowId);
    event DisputeRaised(uint256 indexed escrowId, address indexed initiator);
    event DisputeResolved(uint256 indexed escrowId, uint256[] releasedMilestones);

    error Unauthorized();
    error InvalidState();
    error InvalidAmount();
    error InvalidDeadline();
    error DeadlineNotPassed();
    error AlreadyApproved();
    error AlreadyReleased();
    error NotApproved();
    error InsufficientFunds();
    error TransferFailed();
    error InvalidSignature();
    error SignatureExpired();
    error ZeroAddress();
    error EmptyMilestones();

    modifier onlyPayer(uint256 escrowId) {
        if (!hasContributed[escrowId][msg.sender]) revert Unauthorized();
        _;
    }

    modifier onlySeller(uint256 escrowId) {
        if (escrows[escrowId].seller != msg.sender) revert Unauthorized();
        _;
    }

    modifier onlyArbiter(uint256 escrowId) {
        if (escrows[escrowId].arbiter != msg.sender) revert Unauthorized();
        _;
    }

    modifier onlyActive(uint256 escrowId) {
        if (escrows[escrowId].state != EscrowState.ACTIVE) revert InvalidState();
        _;
    }

    constructor() ERC721("Athenyx Escrow", "ATHX") EIP712("Athenyx", "1") {}

    function createEscrow(
        address seller,
        address arbiter,
        uint256 arbiterFee,
        uint256[] calldata milestoneAmounts,
        uint256[] calldata milestoneDeadlines
    ) external payable returns (uint256) {
        if (seller == address(0)) revert ZeroAddress();
        if (milestoneAmounts.length == 0) revert EmptyMilestones();
        if (milestoneAmounts.length != milestoneDeadlines.length) revert InvalidAmount();

        uint256 totalMilestonesAmount = 0;
        for (uint256 i = 0; i < milestoneAmounts.length; i++) {
            if (milestoneAmounts[i] == 0) revert InvalidAmount();
            if (milestoneDeadlines[i] != 0 && milestoneDeadlines[i] <= block.timestamp) {
                revert InvalidDeadline();
            }
            totalMilestonesAmount += milestoneAmounts[i];
        }

        if (msg.value < arbiterFee) revert InvalidAmount();

        uint256 escrowId = nextEscrowId++;
        Escrow storage currentEscrow = escrows[escrowId];
        
        currentEscrow.seller = seller;
        currentEscrow.arbiter = arbiter;
        currentEscrow.arbiterFee = arbiterFee;
        currentEscrow.totalFunded = msg.value;
        currentEscrow.totalReleased = 0;
        currentEscrow.state = EscrowState.ACTIVE;
        currentEscrow.createdAt = block.timestamp;

        currentEscrow.payers.push(msg.sender);
        currentEscrow.contributions[msg.sender] = msg.value;
        hasContributed[escrowId][msg.sender] = true;

        for (uint256 i = 0; i < milestoneAmounts.length; i++) {
            currentEscrow.milestones.push(Milestone({
                amount: milestoneAmounts[i],
                deadline: milestoneDeadlines[i],
                approved: false,
                released: false,
                approvalHash: bytes32(0)
            }));
        }

        _safeMint(seller, escrowId);

        emit EscrowCreated(escrowId, seller, arbiter, totalMilestonesAmount, arbiterFee);
        emit ContributionAdded(escrowId, msg.sender, msg.value);

        return escrowId;
    }

    function contributeToEscrow(uint256 escrowId) external payable onlyActive(escrowId) {
        if (msg.value == 0) revert InvalidAmount();

        Escrow storage currentEscrow = escrows[escrowId];
        
        if (!hasContributed[escrowId][msg.sender]) {
            currentEscrow.payers.push(msg.sender);
            hasContributed[escrowId][msg.sender] = true;
        }

        currentEscrow.contributions[msg.sender] += msg.value;
        currentEscrow.totalFunded += msg.value;

        emit ContributionAdded(escrowId, msg.sender, msg.value);
    }

    function approveMilestone(uint256 escrowId, uint256 milestoneIndex) 
        external 
        onlyPayer(escrowId) 
        onlyActive(escrowId) 
    {
        Escrow storage currentEscrow = escrows[escrowId];
        if (milestoneIndex >= currentEscrow.milestones.length) revert InvalidAmount();

        Milestone storage currentMilestone = currentEscrow.milestones[milestoneIndex];
        if (currentMilestone.approved) revert AlreadyApproved();
        if (currentMilestone.released) revert AlreadyReleased();

        currentMilestone.approved = true;
        emit MilestoneApproved(escrowId, milestoneIndex, msg.sender);
    }

    function approveMilestoneWithSignature(
        uint256 escrowId,
        uint256 milestoneIndex,
        uint256 signatureDeadline,
        bytes calldata signature
    ) external onlyActive(escrowId) {
        if (block.timestamp > signatureDeadline) revert SignatureExpired();

        Escrow storage currentEscrow = escrows[escrowId];
        if (milestoneIndex >= currentEscrow.milestones.length) revert InvalidAmount();

        Milestone storage currentMilestone = currentEscrow.milestones[milestoneIndex];
        if (currentMilestone.approved) revert AlreadyApproved();
        if (currentMilestone.released) revert AlreadyReleased();

        address signer = _recoverApprovalSigner(escrowId, milestoneIndex, signatureDeadline, signature);
        if (!hasContributed[escrowId][signer]) revert Unauthorized();

        uint256 currentNonce = nonces[signer];
        nonces[signer]++;

        currentMilestone.approved = true;
        currentMilestone.approvalHash = keccak256(abi.encodePacked(signer, currentNonce));

        emit MilestoneApproved(escrowId, milestoneIndex, signer);
    }

    function releaseMilestone(uint256 escrowId, uint256 milestoneIndex) 
        external 
        nonReentrant 
        onlyActive(escrowId) 
    {
        Escrow storage currentEscrow = escrows[escrowId];
        if (milestoneIndex >= currentEscrow.milestones.length) revert InvalidAmount();

        Milestone storage currentMilestone = currentEscrow.milestones[milestoneIndex];
        if (!currentMilestone.approved) revert NotApproved();
        if (currentMilestone.released) revert AlreadyReleased();
        if (currentEscrow.totalFunded < currentEscrow.totalReleased + currentMilestone.amount) {
            revert InsufficientFunds();
        }

        currentMilestone.released = true;
        currentEscrow.totalReleased += currentMilestone.amount;

        (bool success, ) = currentEscrow.seller.call{value: currentMilestone.amount}("");
        if (!success) revert TransferFailed();

        emit MilestoneReleased(escrowId, milestoneIndex, currentMilestone.amount);

        uint256 totalExpectedAmount = currentEscrow.arbiterFee;
        for (uint256 i = 0; i < currentEscrow.milestones.length; i++) {
            totalExpectedAmount += currentEscrow.milestones[i].amount;
        }

        if (currentEscrow.totalReleased == totalExpectedAmount) {
            currentEscrow.state = EscrowState.COMPLETED;
            
            if (currentEscrow.arbiterFee > 0 && currentEscrow.arbiter != address(0)) {
                (bool arbiterSuccess, ) = currentEscrow.arbiter.call{value: currentEscrow.arbiterFee}("");
                if (!arbiterSuccess) revert TransferFailed();
            }
            
            emit EscrowCompleted(escrowId);
        }
    }

    function claimExpiredMilestone(uint256 escrowId, uint256 milestoneIndex) 
        external 
        onlySeller(escrowId) 
        onlyActive(escrowId) 
        nonReentrant 
    {
        Escrow storage currentEscrow = escrows[escrowId];
        if (milestoneIndex >= currentEscrow.milestones.length) revert InvalidAmount();

        Milestone storage currentMilestone = currentEscrow.milestones[milestoneIndex];
        if (currentMilestone.released) revert AlreadyReleased();
        if (currentMilestone.deadline == 0) revert InvalidDeadline();
        if (block.timestamp <= currentMilestone.deadline) revert DeadlineNotPassed();

        currentMilestone.approved = true;
        currentMilestone.released = true;
        currentEscrow.totalReleased += currentMilestone.amount;

        (bool success, ) = currentEscrow.seller.call{value: currentMilestone.amount}("");
        if (!success) revert TransferFailed();

        emit MilestoneApproved(escrowId, milestoneIndex, address(this));
        emit MilestoneReleased(escrowId, milestoneIndex, currentMilestone.amount);
    }

    function refundExpiredMilestone(uint256 escrowId, uint256 milestoneIndex) 
        external 
        onlyPayer(escrowId) 
        onlyActive(escrowId) 
        nonReentrant 
    {
        Escrow storage currentEscrow = escrows[escrowId];
        if (milestoneIndex >= currentEscrow.milestones.length) revert InvalidAmount();

        Milestone storage currentMilestone = currentEscrow.milestones[milestoneIndex];
        if (currentMilestone.released) revert AlreadyReleased();
        if (currentMilestone.approved) revert AlreadyApproved();
        if (currentMilestone.deadline == 0) revert InvalidDeadline();
        if (block.timestamp <= currentMilestone.deadline) revert DeadlineNotPassed();

        currentMilestone.released = true;
        uint256 refundAmount = _calculateRefund(escrowId, currentMilestone.amount);

        if (refundAmount > 0) {
            (bool success, ) = msg.sender.call{value: refundAmount}("");
            if (!success) revert TransferFailed();
        }
    }

    function _calculateRefund(uint256 escrowId, uint256 amount) internal view returns (uint256) {
        Escrow storage currentEscrow = escrows[escrowId];
        uint256 payerContribution = currentEscrow.contributions[msg.sender];
        
        if (payerContribution == 0 || currentEscrow.totalFunded == 0) return 0;
        
        return (amount * payerContribution) / currentEscrow.totalFunded;
    }

    function _recoverApprovalSigner(
        uint256 escrowId,
        uint256 milestoneIndex,
        uint256 signatureDeadline,
        bytes calldata signature
    ) internal view returns (address) {
        bytes32 structHash = keccak256(
            abi.encode(
                APPROVAL_TYPEHASH,
                escrowId,
                milestoneIndex,
                nonces[msg.sender],
                signatureDeadline
            )
        );

        bytes32 hash = _hashTypedDataV4(structHash);
        address signer = hash.recover(signature);

        if (signer == address(0)) revert InvalidSignature();
        return signer;
    }
}