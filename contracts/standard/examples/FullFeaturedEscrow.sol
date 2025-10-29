// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../extensions/EscrowMilestones.sol";
import "../extensions/EscrowGuarantors.sol";

contract FullFeaturedEscrow is EscrowMilestones, EscrowGuarantors {
    constructor() {}

    function _onEscrowCompleted(uint256 escrowId) 
        internal 
        virtual 
        override(EscrowCore, EscrowGuarantors) 
    {
        EscrowGuarantors._onEscrowCompleted(escrowId);
    }
}