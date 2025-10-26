// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IReputationSystem {
    struct ReputationConfig {
        uint256 successBonus;
        uint256 failurePenalty;
        uint256 collusionPenalty;
        uint256 whistleblowerBonus;
        uint256 minReputationForPrimary;
        uint256 minReputationForSecondary;
        uint256 reputationDecayRate;
        uint256 recoveryPeriod;
    }

    event ReputationScoreChanged(
        address indexed account,
        int256 change,
        uint256 newScore,
        string reason
    );

    function getReputationScore(address account) external view returns (uint256);
    
    function increaseReputation(
        address account,
        uint256 amount,
        string calldata reason
    ) external;
    
    function decreaseReputation(
        address account,
        uint256 amount,
        string calldata reason
    ) external;
    
    function meetsMinimumReputation(
        address account,
        uint256 minimumRequired
    ) external view returns (bool);
    
    function getReputationConfig() external view returns (ReputationConfig memory);
}