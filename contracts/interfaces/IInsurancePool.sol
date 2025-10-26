// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IInsurancePool {
    struct PoolStats {
        uint256 totalCollected;
        uint256 totalPaidOut;
        uint256 currentBalance;
        uint256 reserveRatio;
        uint256 activeClaims;
    }

    event PremiumCollected(uint256 indexed escrowId, uint256 amount, address indexed payer);
    event ClaimFiled(uint256 indexed escrowId, address indexed claimant, uint256 requestedAmount);
    event ClaimApproved(uint256 indexed escrowId, address indexed claimant, uint256 approvedAmount);
    event ClaimRejected(uint256 indexed escrowId, address indexed claimant, string reason);
    event PayoutProcessed(uint256 indexed escrowId, address indexed recipient, uint256 amount);

    error InsufficientPoolBalance(uint256 requested, uint256 available);
    error ClaimAlreadyExists();
    error ClaimNotFound();
    error UnauthorizedClaim();
    error InvalidClaimAmount();

    function collectPremium(uint256 escrowId) external payable;
    
    function fileClaim(
        uint256 escrowId,
        uint256 requestedAmount,
        bytes calldata evidence
    ) external;
    
    function processClaim(
        uint256 escrowId,
        bool approved,
        uint256 payoutAmount
    ) external;
    
    function getPoolStats() external view returns (PoolStats memory);
    
    function calculatePremium(
        uint256 loanAmount,
        uint256 duration,
        uint256 riskScore
    ) external view returns (uint256);
    
    function getAvailableLiquidity() external view returns (uint256);
}