// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IEscrowInsurance {
    struct InsurancePolicy {
        uint256 escrowId;
        uint256 premiumPaid;
        uint256 coverageAmount;
        bool claimed;
        uint256 claimAmount;
        uint256 activatedAt;
    }

    event InsuranceActivated(
        uint256 indexed escrowId,
        uint256 premium,
        uint256 coverageAmount
    );

    event InsuranceClaimed(
        uint256 indexed escrowId,
        address indexed claimant,
        uint256 claimAmount
    );

    event InsurancePremiumPaid(
        uint256 indexed escrowId,
        uint256 premium
    );

    error InsuranceNotActive();
    error InsuranceAlreadyClaimed();
    error InvalidCoverageAmount();
    error InsufficientPoolBalance();

    function activateInsurance(
        uint256 escrowId,
        uint256 coverageAmount
    ) external payable;

    function claimInsurance(uint256 escrowId) external;

    function calculatePremium(
        uint256 escrowId,
        uint256 coverageAmount
    ) external view returns (uint256 premium);

    function getInsurancePolicy(uint256 escrowId)
        external
        view
        returns (InsurancePolicy memory);

    function isInsured(uint256 escrowId) external view returns (bool);
}