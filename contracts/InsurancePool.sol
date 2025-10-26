// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IInsurancePool.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract InsurancePool is IInsurancePool, ReentrancyGuard, Ownable {
    uint256 public constant PREMIUM_RATE_BASE = 1000;
    uint256 public constant PREMIUM_PERCENTAGE = 10;
    uint256 public constant MIN_RESERVE_RATIO = 20;
    uint256 public constant FULL_COLLATERAL_PAYOUT = 100;
    uint256 public constant PARTIAL_COLLATERAL_PAYOUT = 50;
    
    struct Claim {
        uint256 escrowId;
        address claimant;
        uint256 requestedAmount;
        uint256 approvedAmount;
        bool processed;
        bool approved;
        uint256 filedAt;
        bytes evidence;
    }
    
    PoolStats private poolStats;
    
    mapping(uint256 => uint256) private escrowPremiums;
    mapping(uint256 => Claim) private claims;
    mapping(uint256 => bool) private claimExists;
    
    address public athenyxCore;
    address public treasuryAddress;
    
    modifier onlyCore() {
        if (msg.sender != athenyxCore) revert Unauthorized();
        _;
    }
    
    error Unauthorized();
    error InvalidTreasuryAddress();

    constructor(address treasury) Ownable(msg.sender) {
        if (treasury == address(0)) revert InvalidTreasuryAddress();
        treasuryAddress = treasury;
        
        poolStats.totalCollected = 0;
        poolStats.totalPaidOut = 0;
        poolStats.currentBalance = 0;
        poolStats.reserveRatio = 100;
        poolStats.activeClaims = 0;
    }
    
    function setAthenyxCore(address coreAddress) external onlyOwner {
        if (coreAddress == address(0)) revert Unauthorized();
        athenyxCore = coreAddress;
    }
    
    function setTreasuryAddress(address treasury) external onlyOwner {
        if (treasury == address(0)) revert InvalidTreasuryAddress();
        treasuryAddress = treasury;
    }

    function collectPremium(uint256 escrowId) external payable onlyCore {
        if (msg.value == 0) revert InvalidClaimAmount();
        
        escrowPremiums[escrowId] += msg.value;
        poolStats.totalCollected += msg.value;
        poolStats.currentBalance += msg.value;
        
        _updateReserveRatio();
        
        emit PremiumCollected(escrowId, msg.value, msg.sender);
    }

    function fileClaim(
        uint256 escrowId,
        uint256 requestedAmount,
        bytes calldata evidence
    ) external {
        if (claimExists[escrowId]) revert ClaimAlreadyExists();
        if (requestedAmount == 0) revert InvalidClaimAmount();
        if (requestedAmount > poolStats.currentBalance) {
            revert InsufficientPoolBalance(requestedAmount, poolStats.currentBalance);
        }
        
        claims[escrowId] = Claim({
            escrowId: escrowId,
            claimant: msg.sender,
            requestedAmount: requestedAmount,
            approvedAmount: 0,
            processed: false,
            approved: false,
            filedAt: block.timestamp,
            evidence: evidence
        });
        
        claimExists[escrowId] = true;
        poolStats.activeClaims++;
        
        emit ClaimFiled(escrowId, msg.sender, requestedAmount);
    }

    function processClaim(
        uint256 escrowId,
        bool approved,
        uint256 payoutAmount
    ) external onlyCore nonReentrant {
        if (!claimExists[escrowId]) revert ClaimNotFound();
        
        Claim storage claim = claims[escrowId];
        
        if (claim.processed) revert ClaimAlreadyExists();
        
        claim.processed = true;
        claim.approved = approved;
        
        if (approved) {
            if (payoutAmount > poolStats.currentBalance) {
                revert InsufficientPoolBalance(payoutAmount, poolStats.currentBalance);
            }
            
            claim.approvedAmount = payoutAmount;
            poolStats.currentBalance -= payoutAmount;
            poolStats.totalPaidOut += payoutAmount;
            poolStats.activeClaims--;
            
            (bool success, ) = claim.claimant.call{value: payoutAmount}("");
            if (!success) revert TransferFailed();
            
            _updateReserveRatio();
            
            emit ClaimApproved(escrowId, claim.claimant, payoutAmount);
            emit PayoutProcessed(escrowId, claim.claimant, payoutAmount);
        } else {
            poolStats.activeClaims--;
            emit ClaimRejected(escrowId, claim.claimant, "Claim rejected by core");
        }
    }

    function getPoolStats() external view returns (PoolStats memory) {
        return poolStats;
    }

    function calculatePremium(
        uint256 loanAmount,
        uint256 duration,
        uint256 riskScore
    ) external pure returns (uint256) {
        uint256 basePremium = (loanAmount * PREMIUM_PERCENTAGE) / 100;
        
        uint256 durationMultiplier = duration / 30 days;
        if (durationMultiplier == 0) durationMultiplier = 1;
        
        uint256 riskMultiplier = 100 + riskScore;
        
        uint256 totalPremium = (basePremium * durationMultiplier * riskMultiplier) / (100 * PREMIUM_RATE_BASE);
        
        return totalPremium;
    }

    function getAvailableLiquidity() external view returns (uint256) {
        return poolStats.currentBalance;
    }
    
    function getClaim(uint256 escrowId) external view returns (Claim memory) {
        return claims[escrowId];
    }
    
    function getEscrowPremium(uint256 escrowId) external view returns (uint256) {
        return escrowPremiums[escrowId];
    }

    function withdrawExcessReserves() external onlyOwner nonReentrant {
        uint256 requiredReserve = (poolStats.totalCollected * MIN_RESERVE_RATIO) / 100;
        
        if (poolStats.currentBalance <= requiredReserve) revert InsufficientPoolBalance(0, 0);
        
        uint256 excessAmount = poolStats.currentBalance - requiredReserve;
        
        poolStats.currentBalance -= excessAmount;
        
        (bool success, ) = treasuryAddress.call{value: excessAmount}("");
        if (!success) revert TransferFailed();
    }

    function _updateReserveRatio() private {
        if (poolStats.totalCollected == 0) {
            poolStats.reserveRatio = 100;
        } else {
            poolStats.reserveRatio = (poolStats.currentBalance * 100) / poolStats.totalCollected;
        }
    }

    error TransferFailed();

    receive() external payable {
        poolStats.totalCollected += msg.value;
        poolStats.currentBalance += msg.value;
        _updateReserveRatio();
    }
}