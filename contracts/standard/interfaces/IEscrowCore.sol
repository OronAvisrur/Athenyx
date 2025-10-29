// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IEscrowCore {
    enum EscrowState {
        PENDING,
        ACTIVE,
        CANCELLED,
        COMPLETED,
        DISPUTED
    }

    struct EscrowBasicInfo {
        address creator;
        address beneficiary;
        address arbiter;
        uint256 amount;
        uint256 deadline;
        EscrowState state;
        uint256 createdAt;
    }

    event EscrowCreated(
        uint256 indexed escrowId,
        address indexed creator,
        address indexed beneficiary,
        uint256 amount
    );

    event EscrowFunded(
        uint256 indexed escrowId,
        address indexed funder,
        uint256 amount
    );

    event EscrowReleased(
        uint256 indexed escrowId,
        address indexed beneficiary,
        uint256 amount
    );

    event EscrowCancelled(
        uint256 indexed escrowId,
        uint256 refundedAmount
    );

    event EscrowCompleted(uint256 indexed escrowId);

    error EscrowNotFound();
    error InvalidState();
    error InvalidAmount();
    error InvalidDeadline();
    error Unauthorized();
    error DeadlineNotPassed();
    error InsufficientFunds();
    error TransferFailed();
    error ZeroAddress();

    function createEscrow(
        address beneficiary,
        address arbiter,
        uint256 amount,
        uint256 deadline
    ) external payable returns (uint256 escrowId);

    function fundEscrow(uint256 escrowId) external payable;

    function releaseEscrow(uint256 escrowId) external;

    function cancelEscrow(uint256 escrowId) external;

    function getEscrowInfo(uint256 escrowId) external view returns (EscrowBasicInfo memory);

    function getEscrowState(uint256 escrowId) external view returns (EscrowState);

    function nextEscrowId() external view returns (uint256);
}