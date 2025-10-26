// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/ILenderIncentives.sol";
import "./interfaces/IGuarantorRegistry.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract LenderIncentives is ILenderIncentives, ReentrancyGuard, Ownable {
    uint256 public constant BASE_RATE_BPS = 500;
    uint256 public constant MAX_RISK_PREMIUM_BPS = 1500;
    uint256 public constant EARLY_BIRD_BONUS_BPS = 50;
    uint256 public constant MAX_REPUTATION_DISCOUNT_BPS = 300;
    uint256 public constant BASIS_POINTS = 10000;
    
    uint256 public constant EARLY_BIRD_THRESHOLD = 5;
    uint256 public constant MIN_GUARANTOR_COUNT = 3;
    uint256 public constant OPTIMAL_GUARANTOR_COUNT = 5;
    
    mapping(address => LenderProfile) private lenderProfiles;
    mapping(uint256 => mapping(address => LoanOffer)) private loanOffers;
    mapping(uint256 => address[]) private escrowLendersList;
    
    address public athenyxCore;
    address public guarantorRegistry;
    
    uint256 public totalLendersCount;
    
    modifier onlyCore() {
        if (msg.sender != athenyxCore) revert Unauthorized();
        _;
    }
    
    error Unauthorized();
    error AlreadyRegistered();
    error InvalidAddress();

    constructor() Ownable(msg.sender) {}
    
    function setAthenyxCore(address coreAddress) external onlyOwner {
        if (coreAddress == address(0)) revert InvalidAddress();
        athenyxCore = coreAddress;
    }
    
    function setGuarantorRegistry(address registryAddress) external onlyOwner {
        if (registryAddress == address(0)) revert InvalidAddress();
        guarantorRegistry = registryAddress;
    }

    function registerLender() external {
        LenderProfile storage profile = lenderProfiles[msg.sender];
        
        if (profile.joinedAt != 0) revert AlreadyRegistered();
        
        profile.lenderAddress = msg.sender;
        profile.totalLent = 0;
        profile.totalRepaid = 0;
        profile.activeLoanCount = 0;
        profile.successfulLoanCount = 0;
        profile.defaultedLoanCount = 0;
        profile.rewardsEarned = 0;
        profile.joinedAt = block.timestamp;
        
        totalLendersCount++;
        
        emit LenderRegistered(msg.sender, block.timestamp);
    }

    function placeLoanOffer(
        uint256 escrowId,
        uint256 interestRateBasisPoints
    ) external payable {
        LenderProfile storage profile = lenderProfiles[msg.sender];
        
        if (profile.joinedAt == 0) revert LenderNotRegistered();
        if (msg.value == 0) revert InvalidAmount();
        if (interestRateBasisPoints == 0 || interestRateBasisPoints > 5000) {
            revert InvalidInterestRate();
        }
        if (loanOffers[escrowId][msg.sender].offerTimestamp != 0) {
            revert OfferAlreadyExists();
        }
        
        LoanOffer storage offer = loanOffers[escrowId][msg.sender];
        offer.escrowId = escrowId;
        offer.lender = msg.sender;
        offer.offeredAmount = msg.value;
        offer.interestRateBasisPoints = interestRateBasisPoints;
        offer.offerTimestamp = block.timestamp;
        offer.isAccepted = false;
        offer.isActive = true;
        
        escrowLendersList[escrowId].push(msg.sender);
        
        uint256 offerCount = escrowLendersList[escrowId].length;
        if (offerCount <= EARLY_BIRD_THRESHOLD) {
            uint256 bonus = (msg.value * EARLY_BIRD_BONUS_BPS) / BASIS_POINTS;
            profile.rewardsEarned += bonus;
            emit EarlyBirdBonusAwarded(msg.sender, bonus);
        }
        
        emit LoanOfferPlaced(escrowId, msg.sender, msg.value, interestRateBasisPoints);
    }

    function acceptLoanOffer(
        uint256 escrowId,
        address lender
    ) external onlyCore nonReentrant {
        LoanOffer storage offer = loanOffers[escrowId][lender];
        
        if (offer.offerTimestamp == 0) revert OfferNotFound();
        if (!offer.isActive) revert OfferNotFound();
        
        offer.isAccepted = true;
        offer.isActive = false;
        
        LenderProfile storage profile = lenderProfiles[lender];
        profile.totalLent += offer.offeredAmount;
        profile.activeLoanCount++;
        
        (bool success, ) = athenyxCore.call{value: offer.offeredAmount}("");
        if (!success) revert TransferFailed();
        
        emit LoanOfferAccepted(escrowId, lender, offer.offeredAmount);
    }

    function calculateInterestRate(
        uint256 escrowId,
        uint256 borrowerReputation,
        uint256 guarantorCount,
        uint256 guarantorQuality
    ) external view returns (InterestCalculation memory) {
        InterestCalculation memory calc;
        
        calc.baseRate = BASE_RATE_BPS;
        
        uint256 riskScore = 100;
        
        if (borrowerReputation < 100) {
            riskScore += 50;
        } else if (borrowerReputation < 200) {
            riskScore += 25;
        } else if (borrowerReputation >= 300) {
            riskScore -= 20;
        }
        
        if (guarantorCount < MIN_GUARANTOR_COUNT) {
            riskScore += 30;
        } else if (guarantorCount >= OPTIMAL_GUARANTOR_COUNT) {
            riskScore -= 15;
        }
        
        if (guarantorQuality < 150) {
            riskScore += 20;
        } else if (guarantorQuality >= 250) {
            riskScore -= 10;
        }
        
        calc.riskPremium = (MAX_RISK_PREMIUM_BPS * riskScore) / 100;
        if (calc.riskPremium > MAX_RISK_PREMIUM_BPS) {
            calc.riskPremium = MAX_RISK_PREMIUM_BPS;
        }
        
        uint256 offerCount = escrowLendersList[escrowId].length;
        if (offerCount < EARLY_BIRD_THRESHOLD) {
            calc.earlyBirdBonus = EARLY_BIRD_BONUS_BPS;
        }
        
        if (borrowerReputation >= 300) {
            calc.reputationDiscount = MAX_REPUTATION_DISCOUNT_BPS;
        } else if (borrowerReputation >= 200) {
            calc.reputationDiscount = MAX_REPUTATION_DISCOUNT_BPS / 2;
        }
        
        calc.finalRate = calc.baseRate + calc.riskPremium + calc.earlyBirdBonus;
        if (calc.finalRate > calc.reputationDiscount) {
            calc.finalRate -= calc.reputationDiscount;
        }
        
        return calc;
    }

    function payInterest(
        uint256 escrowId,
        address lender,
        uint256 amount
    ) external onlyCore nonReentrant {
        if (amount == 0) revert InvalidAmount();
        
        LenderProfile storage profile = lenderProfiles[lender];
        profile.totalRepaid += amount;
        
        (bool success, ) = lender.call{value: amount}("");
        if (!success) revert TransferFailed();
        
        emit InterestPaid(escrowId, lender, amount);
    }

    function rewardLender(
        address lender,
        uint256 amount,
        string calldata reason
    ) external onlyCore nonReentrant {
        if (amount == 0) revert InvalidAmount();
        
        LenderProfile storage profile = lenderProfiles[lender];
        profile.rewardsEarned += amount;
        
        (bool success, ) = lender.call{value: amount}("");
        if (!success) revert TransferFailed();
        
        emit LenderRewarded(lender, amount, reason);
    }

    function markLoanComplete(address lender, bool successful) external onlyCore {
        LenderProfile storage profile = lenderProfiles[lender];
        
        profile.activeLoanCount--;
        
        if (successful) {
            profile.successfulLoanCount++;
        } else {
            profile.defaultedLoanCount++;
        }
    }

    function getLenderProfile(address lender) external view returns (LenderProfile memory) {
        return lenderProfiles[lender];
    }

    function getLoanOffer(uint256 escrowId, address lender) external view returns (LoanOffer memory) {
        return loanOffers[escrowId][lender];
    }

    function getEscrowOffers(uint256 escrowId) external view returns (address[] memory) {
        return escrowLendersList[escrowId];
    }
    
    function getBestOffer(uint256 escrowId) external view returns (address bestLender, uint256 lowestRate) {
        address[] memory lenders = escrowLendersList[escrowId];
        
        if (lenders.length == 0) return (address(0), 0);
        
        bestLender = lenders[0];
        lowestRate = loanOffers[escrowId][lenders[0]].interestRateBasisPoints;
        
        for (uint256 i = 1; i < lenders.length; i++) {
            uint256 rate = loanOffers[escrowId][lenders[i]].interestRateBasisPoints;
            if (rate < lowestRate && loanOffers[escrowId][lenders[i]].isActive) {
                lowestRate = rate;
                bestLender = lenders[i];
            }
        }
    }

    error TransferFailed();

    receive() external payable {}
}