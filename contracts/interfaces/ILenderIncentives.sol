// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ILenderIncentives {
    struct LenderProfile {
        address lenderAddress;
        uint256 totalLent;
        uint256 totalRepaid;
        uint256 activeLoanCount;
        uint256 successfulLoanCount;
        uint256 defaultedLoanCount;
        uint256 rewardsEarned;
        uint256 joinedAt;
    }

    struct LoanOffer {
        uint256 escrowId;
        address lender;
        uint256 offeredAmount;
        uint256 interestRateBasisPoints;
        uint256 offerTimestamp;
        bool isAccepted;
        bool isActive;
    }

    struct InterestCalculation {
        uint256 baseRate;
        uint256 riskPremium;
        uint256 earlyBirdBonus;
        uint256 reputationDiscount;
        uint256 finalRate;
    }

    event LenderRegistered(address indexed lender, uint256 timestamp);
    event LoanOfferPlaced(
        uint256 indexed escrowId,
        address indexed lender,
        uint256 amount,
        uint256 interestRate
    );
    event LoanOfferAccepted(uint256 indexed escrowId, address indexed lender, uint256 amount);
    event InterestPaid(uint256 indexed escrowId, address indexed lender, uint256 amount);
    event LenderRewarded(address indexed lender, uint256 rewardAmount, string reason);
    event EarlyBirdBonusAwarded(address indexed lender, uint256 bonusAmount);

    error LenderNotRegistered();
    error OfferAlreadyExists();
    error OfferNotFound();
    error InvalidInterestRate();
    error InvalidAmount();
    error InsufficientFunds();

    function registerLender() external;
    
    function placeLoanOffer(
        uint256 escrowId,
        uint256 interestRateBasisPoints
    ) external payable;
    
    function acceptLoanOffer(
        uint256 escrowId,
        address lender
    ) external;
    
    function calculateInterestRate(
        uint256 escrowId,
        uint256 borrowerReputation,
        uint256 guarantorCount,
        uint256 guarantorQuality
    ) external view returns (InterestCalculation memory);
    
    function payInterest(
        uint256 escrowId,
        address lender,
        uint256 amount
    ) external;
    
    function rewardLender(
        address lender,
        uint256 amount,
        string calldata reason
    ) external;
    
    function getLenderProfile(address lender) external view returns (LenderProfile memory);
    
    function getLoanOffer(uint256 escrowId, address lender) external view returns (LoanOffer memory);
    
    function getEscrowOffers(uint256 escrowId) external view returns (address[] memory);
}