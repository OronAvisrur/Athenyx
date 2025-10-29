// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../core/EscrowCore.sol";
import "../interfaces/IEscrowMilestones.sol";

abstract contract EscrowMilestones is EscrowCore, IEscrowMilestones {
    mapping(uint256 => Milestone[]) private escrowMilestones;

    function createEscrowWithMilestones(
        address beneficiary,
        address arbiter,
        uint256[] calldata milestoneAmounts,
        uint256[] calldata milestoneDeadlines,
        string[] calldata milestoneDescriptions
    ) external payable virtual returns (uint256 escrowId) {
        if (milestoneAmounts.length == 0) revert InvalidMilestoneCount();
        if (milestoneAmounts.length != milestoneDeadlines.length) revert InvalidMilestoneCount();
        if (milestoneDescriptions.length > 0 && milestoneDescriptions.length != milestoneAmounts.length) {
            revert InvalidMilestoneCount();
        }

        uint256 totalAmount = 0;
        for (uint256 i = 0; i < milestoneAmounts.length; i++) {
            if (milestoneAmounts[i] == 0) revert InvalidAmount();
            totalAmount += milestoneAmounts[i];

            if (milestoneDeadlines[i] != 0 && milestoneDeadlines[i] <= block.timestamp) {
                revert InvalidDeadline();
            }
        }

        escrowId = _createEscrowInternal(
            msg.sender,
            beneficiary,
            arbiter,
            totalAmount,
            msg.value,
            0
        );

        for (uint256 i = 0; i < milestoneAmounts.length; i++) {
            string memory description = milestoneDescriptions.length > 0 
                ? milestoneDescriptions[i] 
                : "";

            escrowMilestones[escrowId].push(Milestone({
                amount: milestoneAmounts[i],
                deadline: milestoneDeadlines[i],
                approved: false,
                released: false,
                description: description
            }));

            emit MilestoneCreated(escrowId, i, milestoneAmounts[i], milestoneDeadlines[i]);
        }

        return escrowId;
    }

    function approveMilestone(uint256 escrowId, uint256 milestoneIndex)
        external
        virtual
        escrowExists(escrowId)
        inState(escrowId, EscrowState.ACTIVE)
    {
        if (!hasContributed[escrowId][msg.sender]) revert Unauthorized();
        if (milestoneIndex >= escrowMilestones[escrowId].length) revert MilestoneNotFound();

        Milestone storage milestone = escrowMilestones[escrowId][milestoneIndex];

        if (milestone.approved) revert MilestoneAlreadyApproved();
        if (milestone.released) revert MilestoneAlreadyReleased();

        milestone.approved = true;

        emit MilestoneApproved(escrowId, milestoneIndex, msg.sender);
    }

    function releaseMilestone(uint256 escrowId, uint256 milestoneIndex)
        external
        virtual
        nonReentrant
        escrowExists(escrowId)
        inState(escrowId, EscrowState.ACTIVE)
    {
        if (milestoneIndex >= escrowMilestones[escrowId].length) revert MilestoneNotFound();

        Milestone storage milestone = escrowMilestones[escrowId][milestoneIndex];
        Escrow storage escrow = escrows[escrowId];

        bool canRelease = milestone.approved ||
                         (milestone.deadline != 0 && 
                          block.timestamp > milestone.deadline && 
                          msg.sender == escrow.beneficiary);

        if (!canRelease) revert MilestoneNotApproved();
        if (milestone.released) revert MilestoneAlreadyReleased();
        if (escrow.funded < milestone.amount) revert InsufficientFunds();

        milestone.released = true;
        escrow.funded -= milestone.amount;

        (bool success, ) = escrow.beneficiary.call{value: milestone.amount}("");
        if (!success) revert TransferFailed();

        emit MilestoneReleased(escrowId, milestoneIndex, milestone.amount);

        if (_allMilestonesReleased(escrowId)) {
            escrow.state = EscrowState.COMPLETED;
            emit EscrowCompleted(escrowId);
            _onEscrowCompleted(escrowId);
        }
    }

    function getMilestone(uint256 escrowId, uint256 milestoneIndex)
        external
        view
        virtual
        escrowExists(escrowId)
        returns (Milestone memory)
    {
        if (milestoneIndex >= escrowMilestones[escrowId].length) revert MilestoneNotFound();
        return escrowMilestones[escrowId][milestoneIndex];
    }

    function getMilestoneCount(uint256 escrowId)
        external
        view
        virtual
        escrowExists(escrowId)
        returns (uint256)
    {
        return escrowMilestones[escrowId].length;
    }

    function getAllMilestones(uint256 escrowId)
        external
        view
        virtual
        escrowExists(escrowId)
        returns (Milestone[] memory)
    {
        return escrowMilestones[escrowId];
    }

    function _allMilestonesReleased(uint256 escrowId) internal view returns (bool) {
        Milestone[] storage milestones = escrowMilestones[escrowId];
        for (uint256 i = 0; i < milestones.length; i++) {
            if (!milestones[i].released) {
                return false;
            }
        }
        return true;
    }
}