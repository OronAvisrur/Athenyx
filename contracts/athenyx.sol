// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

contract Athenyx is ReentrancyGuard, ERC721, EIP712 {
    using ECDSA for bytes32;

    string public constant DOMAIN = "athenyx.brave";
    uint256 public nextEscrowId;

    constructor() ERC721("Athenyx Escrow", "ATHX") EIP712("Athenyx", "1") {}
}