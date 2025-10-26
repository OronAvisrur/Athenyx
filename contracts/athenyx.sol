// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IGuarantorRegistry.sol";
import "./interfaces/IInsurancePool.sol";
import "./interfaces/ILenderIncentives.sol";

contract Athenyx is ReentrancyGuard, ERC721, EIP712, Ownable {
    using ECDSA for bytes32;

    string public constant DOMAIN = "athenyx.brave";
    uint256 public nextEscrowId;
    
    uint256 private constant REPUTATION_SUCCESS_BONUS = 10;
    uint256 private constant REPUTATION_FAILURE_PENALTY = 50;

    enum EscrowState {
        PENDING,
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
        address lender;
        uint256 totalFunded;
        uint256 totalReleased;
        uint256 arbiterFee;
        uint256 interestRate;
        uint256 insurancePremium;
        EscrowState state;
        Milestone[] milestones;
        uint256 createdAt;
        uint256 activatedAt;
        bool requiresGuarantors;
        uint256 minGuarantorCount;
    }

    IGuarantorRegistry public guarantorRegistry;
    IInsurancePool public insurancePool;
    ILenderIncentives public lenderIncentives;

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
        uint256 arbiterFee,
        bool requiresGuarantors
    );
    event EscrowActivated(uint256 indexed escrowId, address indexed lender, uint256 interestRate);
    event ContributionAdded(uint256 indexed escrowId, address indexed payer, uint256 amount);
    event MilestoneApproved(uint256 indexed escrowId, uint256 indexed milestoneIndex, address approver);
    event MilestoneReleased(uint256 indexed escrowId, uint256 indexed milestoneIndex, uint256 amount);
    event EscrowCancelled(uint256 indexed escrowId, uint256 refundAmount);
    event EscrowCompleted(uint256 indexed escrowId);
    event DisputeRaised(uint256 indexed escrowId, address indexed initiator);
    event DisputeResolved(uint256 indexed escrowId, uint256[] releasedMilestones);
    event GuarantorsVerified(uint256 indexed escrowId, uint256 guarantorCount);
    event InsurancePremiumPaid(uint256 indexed escrowId, uint256 premium);

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
    error InsufficientGuarantors();
    error GuarantorsNotVerified();

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

    constructor(
        address _guarantorRegistry,
        address _insurancePool,
        address _lenderIncentives
    ) ERC721("Athenyx Escrow", "ATHX") EIP712("Athenyx", "1") Ownable(msg.sender) {
        if (_guarantorRegistry == address(0) || _insurancePool == address(0) || _lenderIncentives == address(0)) {
            revert ZeroAddress();
        }
        
        guarantorRegistry = IGuarantorRegistry(_guarantorRegistry);
        insurancePool = IInsurancePool(_insurancePool);
        lenderIncentives = ILenderIncentives(_lenderIncentives);
    }

    function setGuarantorRegistry(address _guarantorRegistry) external onlyOwner {
        if (_guarantorRegistry == address(0)) revert ZeroAddress();
        guarantorRegistry = IGuarantorRegistry(_guarantorRegistry);
    }

    function setInsurancePool(address _insurancePool) external onlyOwner {
        if (_insurancePool == address(0)) revert ZeroAddress();
        insurancePool = IInsurancePool(_insurancePool);
    }

    function setLenderIncentives(address _lenderIncentives) external onlyOwner {
        if (_lenderIncentives == address(0)) revert ZeroAddress();
        lenderIncentives = ILenderIncentives(_lenderIncentives);
    }

    function createEscrow(
        address seller,
        address arbiter,
        uint256 arbiterFee,
        uint256[] calldata milestoneAmounts,
        uint256[] calldata milestoneDeadlines,
        bool requiresGuarantors,
        uint256 minGuarantorCount
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
        currentEscrow.state = requiresGuarantors ? EscrowState.PENDING : EscrowState.ACTIVE;
        currentEscrow.createdAt = block.timestamp;
        currentEscrow.requiresGuarantors = requiresGuarantors;
        currentEscrow.minGuarantorCount = minGuarantorCount;

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

        emit EscrowCreated(escrowId, seller, arbiter, totalMilestonesAmount, arbiterFee, requiresGuarantors);
        emit ContributionAdded(escrowId, msg.sender, msg.value);

        return escrowId;
    }

    function activateEscrowWithLender(
        uint256 escrowId,
        address lender
    ) external nonReentrant {
        Escrow storage currentEscrow = escrows[escrowId];
        
        if (currentEscrow.state != EscrowState.PENDING) revert InvalidState();
        if (msg.sender != currentEscrow.seller && msg.sender != owner()) revert Unauthorized();
        
        if (currentEscrow.requiresGuarantors) {
            address[] memory guarantors = guarantorRegistry.getEscrowGuarantors(escrowId);
            if (guarantors.length < currentEscrow.minGuarantorCount) {
                revert InsufficientGuarantors();
            }
            
            emit GuarantorsVerified(escrowId, guarantors.length);
        }
        
        ILenderIncentives.LoanOffer memory offer = lenderIncentives.getLoanOffer(escrowId, lender);
        if (offer.offerTimestamp == 0 || !offer.isActive) revert InvalidAmount();
        
        currentEscrow.lender = lender;
        currentEscrow.interestRate = offer.interestRateBasisPoints;
        currentEscrow.state = EscrowState.ACTIVE;
        currentEscrow.activatedAt = block.timestamp;
        
        lenderIncentives.acceptLoanOffer(escrowId, lender);
        
        uint256 premium = insurancePool.calculatePremium(
            currentEscrow.totalFunded,
            90 days,
            currentEscrow.interestRate
        );
        
        currentEscrow.insurancePremium = premium;
        
        if (premium > 0 && address(this).balance >= premium) {
            insurancePool.collectPremium{value: premium}(escrowId);
            emit InsurancePremiumPaid(escrowId, premium);
        }
        
        emit EscrowActivated(escrowId, lender, currentEscrow.interestRate);
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

        bool allMilestonesReleased = true;
        for (uint256 i = 0; i < currentEscrow.milestones.length; i++) {
            if (!currentEscrow.milestones[i].released) {
                allMilestonesReleased = false;
                break;
            }
        }

        if (allMilestonesReleased) {
            _completeEscrow(escrowId);
        }
    }

    function _completeEscrow(uint256 escrowId) private {
        Escrow storage currentEscrow = escrows[escrowId];
        
        currentEscrow.state = EscrowState.COMPLETED;
        
        if (currentEscrow.arbiterFee > 0 && currentEscrow.arbiter != address(0)) {
            (bool arbiterSuccess, ) = currentEscrow.arbiter.call{value: currentEscrow.arbiterFee}("");
            if (!arbiterSuccess) revert TransferFailed();
        }
        
        if (currentEscrow.lender != address(0) && currentEscrow.requiresGuarantors) {
            address[] memory guarantors = guarantorRegistry.getEscrowGuarantors(escrowId);
            for (uint256 i = 0; i < guarantors.length; i++) {
                guarantorRegistry.rewardGuarantor(guarantors[i], escrowId, 0);
                guarantorRegistry.updateReputation(guarantors[i], int256(REPUTATION_SUCCESS_BONUS));
            }
        }
        
        emit EscrowCompleted(escrowId);
    }

    function getEscrowDetails(uint256 escrowId) external view returns (
        address[] memory payers,
        address seller,
        address arbiter,
        address lender,
        uint256 totalFunded,
        uint256 totalReleased,
        uint256 arbiterFee,
        uint256 interestRate,
        EscrowState state,
        uint256 createdAt,
        bool requiresGuarantors
    ) {
        Escrow storage currentEscrow = escrows[escrowId];
        return (
            currentEscrow.payers,
            currentEscrow.seller,
            currentEscrow.arbiter,
            currentEscrow.lender,
            currentEscrow.totalFunded,
            currentEscrow.totalReleased,
            currentEscrow.arbiterFee,
            currentEscrow.interestRate,
            currentEscrow.state,
            currentEscrow.createdAt,
            currentEscrow.requiresGuarantors
        );
    }

    function getMilestone(uint256 escrowId, uint256 milestoneIndex) external view returns (
        uint256 amount,
        uint256 deadline,
        bool approved,
        bool released
    ) {
        Milestone storage currentMilestone = escrows[escrowId].milestones[milestoneIndex];
        return (
            currentMilestone.amount,
            currentMilestone.deadline,
            currentMilestone.approved,
            currentMilestone.released
        );
    }

    function getMilestoneCount(uint256 escrowId) external view returns (uint256) {
        return escrows[escrowId].milestones.length;
    }

    function getContribution(uint256 escrowId, address payer) external view returns (uint256) {
        return escrows[escrowId].contributions[payer];
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

    function _update(address to, uint256 tokenId, address auth) internal virtual override returns (address) {
        address from = _ownerOf(tokenId);
        address previousOwner = super._update(to, tokenId, auth);
        
        if (from != address(0) && to != address(0)) {
            escrows[tokenId].seller = to;
        }
        
        return previousOwner;
    }

    receive() external payable {}

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

    function raiseDispute(uint256 escrowId) external onlyActive(escrowId) {
        if (!hasContributed[escrowId][msg.sender] && escrows[escrowId].seller != msg.sender) {
            revert Unauthorized();
        }

        escrows[escrowId].state = EscrowState.DISPUTED;
        emit DisputeRaised(escrowId, msg.sender);
    }

    function resolveDispute(uint256 escrowId, uint256[] calldata milestoneIndicesToRelease) 
        external 
        onlyArbiter(escrowId) 
        nonReentrant 
    {
        Escrow storage currentEscrow = escrows[escrowId];
        if (currentEscrow.state != EscrowState.DISPUTED) revert InvalidState();

        for (uint256 i = 0; i < milestoneIndicesToRelease.length; i++) {
            uint256 milestoneIndex = milestoneIndicesToRelease[i];
            if (milestoneIndex >= currentEscrow.milestones.length) revert InvalidAmount();

            Milestone storage currentMilestone = currentEscrow.milestones[milestoneIndex];
            if (currentMilestone.released) continue;

            currentMilestone.approved = true;
            currentMilestone.released = true;
            currentEscrow.totalReleased += currentMilestone.amount;

            (bool success, ) = currentEscrow.seller.call{value: currentMilestone.amount}("");
            if (!success) revert TransferFailed();

            emit MilestoneReleased(escrowId, milestoneIndex, currentMilestone.amount);
        }

        currentEscrow.state = EscrowState.ACTIVE;

        if (currentEscrow.arbiterFee > 0) {
            (bool arbiterSuccess, ) = currentEscrow.arbiter.call{value: currentEscrow.arbiterFee}("");
            if (!arbiterSuccess) revert TransferFailed();
        }

        emit DisputeResolved(escrowId, milestoneIndicesToRelease);

        uint256 totalExpectedAmount = currentEscrow.arbiterFee;
        for (uint256 i = 0; i < currentEscrow.milestones.length; i++) {
            totalExpectedAmount += currentEscrow.milestones[i].amount;
        }

        if (currentEscrow.totalReleased == totalExpectedAmount) {
            _completeEscrow(escrowId);
        }
    }

    function cancelEscrow(uint256 escrowId) 
        external 
        onlyPayer(escrowId) 
        onlyActive(escrowId) 
        nonReentrant 
    {
        Escrow storage currentEscrow = escrows[escrowId];

        uint256 totalExpectedAmount = currentEscrow.arbiterFee;
        for (uint256 i = 0; i < currentEscrow.milestones.length; i++) {
            totalExpectedAmount += currentEscrow.milestones[i].amount;
        }

        uint256 remainingAmount = currentEscrow.totalFunded - currentEscrow.totalReleased;
        if (remainingAmount == 0) revert InsufficientFunds();

        currentEscrow.state = EscrowState.CANCELLED;

        for (uint256 i = 0; i < currentEscrow.milestones.length; i++) {
            if (!currentEscrow.milestones[i].released) {
                currentEscrow.milestones[i].released = true;
            }
        }
        
        if (currentEscrow.requiresGuarantors) {
            address[] memory guarantors = guarantorRegistry.getEscrowGuarantors(escrowId);
            for (uint256 i = 0; i < guarantors.length; i++) {
                guarantorRegistry.slashGuarantor(guarantors[i], escrowId, 0);
                guarantorRegistry.updateReputation(guarantors[i], -int256(REPUTATION_FAILURE_PENALTY));
            }
        }

        for (uint256 i = 0; i < currentEscrow.payers.length; i++) {
            address payerAddress = currentEscrow.payers[i];
            uint256 payerRefund = (remainingAmount * currentEscrow.contributions[payerAddress]) / currentEscrow.totalFunded;
            
            if (payerRefund > 0) {
                (bool success, ) = payerAddress.call{value: payerRefund}("");
                if (!success) revert TransferFailed();
            }
        }

        emit EscrowCancelled(escrowId, remainingAmount);
    }

    function _calculateRefund(uint256 escrowId, uint256 amount) internal view returns (uint256) {
        Escrow storage currentEscrow = escrows[escrowId];
        uint256 payerContribution = currentEscrow.contributions[msg.sender];
        
        if (payerContribution == 0 || currentEscrow.totalFunded == 0) return 0;
        
        return (amount * payerContribution) / currentEscrow.totalFunded;
    }
}

