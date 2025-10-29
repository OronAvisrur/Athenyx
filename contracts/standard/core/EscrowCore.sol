// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IEscrowCore.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract EscrowCore is IEscrowCore, ReentrancyGuard {
    uint256 private _nextEscrowId;

    struct Escrow {
        address creator;
        address beneficiary;
        address arbiter;
        uint256 amount;
        uint256 funded;
        uint256 deadline;
        EscrowState state;
        uint256 createdAt;
    }

    mapping(uint256 => Escrow) internal escrows;
    mapping(uint256 => mapping(address => bool)) public hasContributed;

    modifier onlyCreator(uint256 escrowId) {
        if (escrows[escrowId].creator != msg.sender) revert Unauthorized();
        _;
    }

    modifier onlyBeneficiary(uint256 escrowId) {
        if (escrows[escrowId].beneficiary != msg.sender) revert Unauthorized();
        _;
    }

    modifier onlyArbiter(uint256 escrowId) {
        if (escrows[escrowId].arbiter != msg.sender) revert Unauthorized();
        _;
    }

    modifier escrowExists(uint256 escrowId) {
        if (escrows[escrowId].createdAt == 0) revert EscrowNotFound();
        _;
    }

    modifier inState(uint256 escrowId, EscrowState requiredState) {
        if (escrows[escrowId].state != requiredState) revert InvalidState();
        _;
    }

    function createEscrow(
        address beneficiary,
        address arbiter,
        uint256 amount,
        uint256 deadline
    ) public payable virtual returns (uint256 escrowId) {
        if (beneficiary == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        if (deadline != 0 && deadline <= block.timestamp) revert InvalidDeadline();

        escrowId = _createEscrowInternal(
            msg.sender,
            beneficiary,
            arbiter,
            amount,
            msg.value,
            deadline
        );

        return escrowId;
    }

    function _createEscrowInternal(
        address creator,
        address beneficiary,
        address arbiter,
        uint256 amount,
        uint256 initialFunding,
        uint256 deadline
    ) internal virtual returns (uint256 escrowId) {
        escrowId = _nextEscrowId++;

        escrows[escrowId] = Escrow({
            creator: creator,
            beneficiary: beneficiary,
            arbiter: arbiter,
            amount: amount,
            funded: initialFunding,
            deadline: deadline,
            state: initialFunding >= amount ? EscrowState.ACTIVE : EscrowState.PENDING,
            createdAt: block.timestamp
        });

        if (initialFunding > 0) {
            hasContributed[escrowId][creator] = true;
        }

        emit EscrowCreated(escrowId, creator, beneficiary, amount);
        
        if (initialFunding > 0) {
            emit EscrowFunded(escrowId, creator, initialFunding);
        }

        if (escrows[escrowId].state == EscrowState.ACTIVE) {
            _onEscrowActivated(escrowId);
        }

        return escrowId;
    }

    function fundEscrow(uint256 escrowId) 
        external 
        payable 
        virtual
        escrowExists(escrowId)
        inState(escrowId, EscrowState.PENDING)
    {
        if (msg.value == 0) revert InvalidAmount();

        Escrow storage escrow = escrows[escrowId];
        escrow.funded += msg.value;

        hasContributed[escrowId][msg.sender] = true;

        emit EscrowFunded(escrowId, msg.sender, msg.value);

        if (escrow.funded >= escrow.amount) {
            escrow.state = EscrowState.ACTIVE;
            _onEscrowActivated(escrowId);
        }
    }

    function releaseEscrow(uint256 escrowId)
        external
        virtual
        nonReentrant
        escrowExists(escrowId)
        inState(escrowId, EscrowState.ACTIVE)
    {
        Escrow storage escrow = escrows[escrowId];

        bool canRelease = msg.sender == escrow.creator ||
                         msg.sender == escrow.arbiter ||
                         (escrow.deadline != 0 && 
                          block.timestamp > escrow.deadline && 
                          msg.sender == escrow.beneficiary);

        if (!canRelease) revert Unauthorized();

        uint256 releaseAmount = escrow.funded;
        escrow.state = EscrowState.COMPLETED;

        (bool success, ) = escrow.beneficiary.call{value: releaseAmount}("");
        if (!success) revert TransferFailed();

        emit EscrowReleased(escrowId, escrow.beneficiary, releaseAmount);
        emit EscrowCompleted(escrowId);

        _onEscrowCompleted(escrowId);
    }

    function cancelEscrow(uint256 escrowId)
        external
        virtual
        nonReentrant
        escrowExists(escrowId)
    {
        Escrow storage escrow = escrows[escrowId];

        if (escrow.state != EscrowState.PENDING && escrow.state != EscrowState.ACTIVE) {
            revert InvalidState();
        }

        bool canCancel = msg.sender == escrow.creator ||
                        msg.sender == escrow.arbiter ||
                        (escrow.deadline != 0 && 
                         block.timestamp > escrow.deadline && 
                         msg.sender == escrow.creator);

        if (!canCancel) revert Unauthorized();

        uint256 refundAmount = escrow.funded;
        escrow.state = EscrowState.CANCELLED;

        if (refundAmount > 0) {
            (bool success, ) = escrow.creator.call{value: refundAmount}("");
            if (!success) revert TransferFailed();
        }

        emit EscrowCancelled(escrowId, refundAmount);

        _onEscrowCancelled(escrowId);
    }

    function getEscrowInfo(uint256 escrowId)
        external
        view
        virtual
        escrowExists(escrowId)
        returns (EscrowBasicInfo memory)
    {
        Escrow storage escrow = escrows[escrowId];
        return EscrowBasicInfo({
            creator: escrow.creator,
            beneficiary: escrow.beneficiary,
            arbiter: escrow.arbiter,
            amount: escrow.amount,
            deadline: escrow.deadline,
            state: escrow.state,
            createdAt: escrow.createdAt
        });
    }

    function getEscrowState(uint256 escrowId)
        external
        view
        virtual
        escrowExists(escrowId)
        returns (EscrowState)
    {
        return escrows[escrowId].state;
    }

    function nextEscrowId() external view virtual returns (uint256) {
        return _nextEscrowId;
    }

    function _getEscrowAmount(uint256 escrowId) internal view returns (uint256) {
        return escrows[escrowId].amount;
    }

    function _onEscrowActivated(uint256 escrowId) internal virtual {}

    function _onEscrowCompleted(uint256 escrowId) internal virtual {}

    function _onEscrowCancelled(uint256 escrowId) internal virtual {}
}