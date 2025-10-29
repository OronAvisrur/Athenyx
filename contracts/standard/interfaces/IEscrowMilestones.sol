// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IEscrowMilestones {
    struct Milestone {
        uint256 amount;
        uint256 deadline;
        bool approved;
        bool released;
        string description;
    }

    event MilestoneCreated(
        uint256 indexed escrowId,
        uint256 indexed milestoneIndex,
        uint256 amount,
        uint256 deadline
    );

    event MilestoneApproved(
        uint256 indexed escrowId,
        uint256 indexed milestoneIndex,
        address indexed approver
    );

    event MilestoneReleased(
        uint256 indexed escrowId,
        uint256 indexed milestoneIndex,
        uint256 amount
    );

    error MilestoneNotFound();
    error MilestoneAlreadyApproved();
    error MilestoneAlreadyReleased();
    error MilestoneNotApproved();
    error InvalidMilestoneCount();

    function createEscrowWithMilestones(
        address beneficiary,
        address arbiter,
        uint256[] calldata milestoneAmounts,
        uint256[] calldata milestoneDeadlines,
        string[] calldata milestoneDescriptions
    ) external payable returns (uint256 escrowId);

    function approveMilestone(uint256 escrowId, uint256 milestoneIndex) external;

    function releaseMilestone(uint256 escrowId, uint256 milestoneIndex) external;

    function getMilestone(uint256 escrowId, uint256 milestoneIndex) 
        external 
        view 
        returns (Milestone memory);

    function getMilestoneCount(uint256 escrowId) external view returns (uint256);

    function getAllMilestones(uint256 escrowId) external view returns (Milestone[] memory);
}