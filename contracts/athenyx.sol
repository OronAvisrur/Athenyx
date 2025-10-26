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
}