# Integration Guide - Athenyx Standard

Step-by-step guide for integrating Athenyx Standard into your project.

---

## Table of Contents

1. [Installation](#installation)
2. [Basic Integration](#basic-integration)
3. [Use Cases](#use-cases)
4. [Advanced Patterns](#advanced-patterns)
5. [Testing](#testing)
6. [Deployment](#deployment)
7. [Troubleshooting](#troubleshooting)

---

## Installation

### Prerequisites

- Node.js >= 16
- Hardhat or Foundry
- Basic Solidity knowledge

### Install Package
```bash
npm install --save-dev @athenyx/contracts
# or
yarn add -D @athenyx/contracts
```

### Install Dependencies
```bash
npm install --save-dev @openzeppelin/contracts hardhat
```

---

## Basic Integration

### Step 1: Choose Your Components

Decide which features you need:

| Component | Use When |
|-----------|----------|
| `EscrowCore` | Simple payment holding |
| `EscrowMilestones` | Staged payments |
| `EscrowGuarantors` | Social collateral |

### Step 2: Create Your Contract

**Example: Simple Escrow**
```solidity
// contracts/MyEscrow.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@athenyx/contracts/standard/core/EscrowCore.sol";

contract MyEscrow is EscrowCore {
    constructor() {}
}
```

### Step 3: Deploy
```javascript
// scripts/deploy.js
const { ethers } = require("hardhat");

async function main() {
    const MyEscrow = await ethers.getContractFactory("MyEscrow");
    const escrow = await MyEscrow.deploy();
    await escrow.waitForDeployment();
    
    console.log("Escrow deployed to:", await escrow.getAddress());
}

main();
```
```bash
npx hardhat run scripts/deploy.js --network sepolia
```

### Step 4: Interact
```javascript
// scripts/create-escrow.js
const escrow = await ethers.getContractAt("MyEscrow", escrowAddress);

const tx = await escrow.createEscrow(
    beneficiaryAddress,
    arbiterAddress,
    ethers.parseEther("10"),
    Math.floor(Date.now() / 1000) + 86400 * 30, // 30 days
    { value: ethers.parseEther("10") }
);

await tx.wait();
console.log("Escrow created!");
```

---

## Use Cases

### Use Case 1: Freelance Payment

**Scenario**: Pay freelancer after work completion
```solidity
// contracts/FreelanceEscrow.sol
pragma solidity ^0.8.20;

import "@athenyx/contracts/standard/extensions/EscrowMilestones.sol";

contract FreelanceEscrow is EscrowMilestones {
    mapping(uint256 => string) public projectDescriptions;
    
    function createProject(
        address freelancer,
        address arbiter,
        uint256[] calldata milestoneAmounts,
        uint256[] calldata deadlines,
        string[] calldata descriptions,
        string calldata projectDescription
    ) external payable returns (uint256 escrowId) {
        escrowId = createEscrowWithMilestones(
            freelancer,
            arbiter,
            milestoneAmounts,
            deadlines,
            descriptions
        );
        
        projectDescriptions[escrowId] = projectDescription;
    }
}
```

**Frontend Integration**:
```javascript
// Create project with 3 milestones
const milestones = [
    { amount: ethers.parseEther("2"), deadline: now + 7 * 86400, desc: "Mockups" },
    { amount: ethers.parseEther("5"), deadline: now + 21 * 86400, desc: "Development" },
    { amount: ethers.parseEther("3"), deadline: now + 30 * 86400, desc: "Testing" }
];

const tx = await freelanceEscrow.createProject(
    freelancerAddress,
    arbiterAddress,
    milestones.map(m => m.amount),
    milestones.map(m => m.deadline),
    milestones.map(m => m.desc),
    "E-commerce Website Development",
    { value: ethers.parseEther("10") }
);

// Approve milestone
await freelanceEscrow.approveMilestone(escrowId, 0);

// Freelancer releases
await freelanceEscrow.connect(freelancer).releaseMilestone(escrowId, 0);
```

---

### Use Case 2: P2P Lending with Guarantors

**Scenario**: Loan with social collateral
```solidity
// contracts/P2PLending.sol
pragma solidity ^0.8.20;

import "@athenyx/contracts/standard/extensions/EscrowGuarantors.sol";

contract P2PLending is EscrowGuarantors {
    struct LoanTerms {
        uint256 principal;
        uint256 interestRate; // basis points (100 = 1%)
        uint256 duration;
        uint256 minGuarantors;
    }
    
    mapping(uint256 => LoanTerms) public loanTerms;
    
    function createLoan(
        address borrower,
        address arbiter,
        uint256 principal,
        uint256 interestRate,
        uint256 duration,
        uint256 minGuarantors
    ) external payable returns (uint256 loanId) {
        uint256 deadline = block.timestamp + duration;
        
        loanId = createEscrowWithGuarantors(
            borrower,
            arbiter,
            principal,
            deadline,
            minGuarantors
        );
        
        loanTerms[loanId] = LoanTerms({
            principal: principal,
            interestRate: interestRate,
            duration: duration,
            minGuarantors: minGuarantors
        });
    }
    
    function repayLoan(uint256 loanId) external payable {
        LoanTerms memory terms = loanTerms[loanId];
        uint256 interest = (terms.principal * terms.interestRate) / 10000;
        uint256 totalDue = terms.principal + interest;
        
        require(msg.value >= totalDue, "Insufficient repayment");
        
        // Release to lender
        releaseEscrow(loanId);
        
        // Refund guarantors
        _refundGuarantors(loanId);
    }
    
    function _refundGuarantors(uint256 loanId) internal {
        address[] memory guarantors = this.getGuarantors(loanId);
        
        for (uint256 i = 0; i < guarantors.length; i++) {
            GuarantorCommitment memory commitment = this.getGuarantorCommitment(
                loanId,
                guarantors[i]
            );
            
            if (commitment.stakeAmount > 0) {
                rewardGuarantor(loanId, guarantors[i], 0);
            }
        }
    }
}
```

**Usage Flow**:
```javascript
// 1. Lender creates loan
const loanId = await lending.createLoan(
    borrowerAddress,
    arbiterAddress,
    ethers.parseEther("10"),  // principal
    500,                       // 5% interest
    86400 * 90,               // 90 days
    3,                         // min 3 guarantors
    { value: ethers.parseEther("10") }
);

// 2. Guarantors commit (within 48h)
const secret = ethers.randomBytes(32);
const hash = ethers.keccak256(
    ethers.solidityPacked(
        ["address", "bytes32", "uint256"],
        [guarantorAddress, secret, loanId]
    )
);

await lending.connect(guarantor1).commitAsGuarantor(
    loanId,
    1, // PRIMARY tier
    hash,
    { value: ethers.parseEther("2") } // 20% stake
);

// 3. Reveal (after 48h)
await ethers.provider.send("evm_increaseTime", [48 * 3600]);
await lending.connect(guarantor1).revealCommitment(loanId, secret);

// 4. Borrower repays
await lending.connect(borrower).repayLoan(loanId, {
    value: ethers.parseEther("10.5") // principal + 5%
});
```

---

### Use Case 3: Escrow Marketplace

**Scenario**: Marketplace with escrow for each order
```solidity
// contracts/EscrowMarketplace.sol
pragma solidity ^0.8.20;

import "@athenyx/contracts/standard/core/EscrowCore.sol";

contract EscrowMarketplace is EscrowCore {
    struct Listing {
        address seller;
        uint256 price;
        string itemId;
        bool active;
    }
    
    mapping(uint256 => Listing) public listings;
    mapping(uint256 => uint256) public orderToEscrow; // orderId => escrowId
    uint256 public nextListingId;
    
    event ListingCreated(uint256 indexed listingId, address seller, uint256 price);
    event OrderPlaced(uint256 indexed orderId, uint256 escrowId, address buyer);
    
    function createListing(
        uint256 price,
        string calldata itemId
    ) external returns (uint256 listingId) {
        listingId = nextListingId++;
        
        listings[listingId] = Listing({
            seller: msg.sender,
            price: price,
            itemId: itemId,
            active: true
        });
        
        emit ListingCreated(listingId, msg.sender, price);
    }
    
    function purchase(
        uint256 listingId,
        address arbiter
    ) external payable returns (uint256 orderId) {
        Listing storage listing = listings[listingId];
        require(listing.active, "Listing not active");
        require(msg.value >= listing.price, "Insufficient payment");
        
        // Create escrow
        uint256 escrowId = createEscrow(
            listing.seller,
            arbiter,
            listing.price,
            block.timestamp + 86400 * 14 // 14 day deadline
        );
        
        orderId = escrowId; // Simple: use escrowId as orderId
        orderToEscrow[orderId] = escrowId;
        
        listing.active = false;
        
        emit OrderPlaced(orderId, escrowId, msg.sender);
    }
    
    function confirmDelivery(uint256 orderId) external {
        uint256 escrowId = orderToEscrow[orderId];
        releaseEscrow(escrowId);
    }
}
```

---

## Advanced Patterns

### Pattern 1: Access Control
```solidity
import "@openzeppelin/contracts/access/AccessControl.sol";

contract AdminEscrow is EscrowCore, AccessControl {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }
    
    function emergencyCancel(uint256 escrowId) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        cancelEscrow(escrowId);
    }
}
```

### Pattern 2: Fee Collection
```solidity
contract FeeEscrow is EscrowCore {
    address public feeCollector;
    uint256 public feePercentage = 250; // 2.5%
    
    constructor(address _feeCollector) {
        feeCollector = _feeCollector;
    }
    
    function releaseEscrow(uint256 escrowId) 
        public 
        virtual 
        override 
    {
        Escrow storage escrow = escrows[escrowId];
        uint256 fee = (escrow.funded * feePercentage) / 10000;
        uint256 netAmount = escrow.funded - fee;
        
        // Transfer fee
        (bool feeSuccess, ) = feeCollector.call{value: fee}("");
        require(feeSuccess, "Fee transfer failed");
        
        // Transfer to beneficiary
        escrow.funded = netAmount;
        super.releaseEscrow(escrowId);
    }
}
```

### Pattern 3: Multi-Signature Arbiter
```solidity
contract MultiSigArbiterEscrow is EscrowCore {
    mapping(uint256 => mapping(address => bool)) public arbiterApprovals;
    mapping(uint256 => address[]) public escrowArbiters;
    mapping(uint256 => uint256) public requiredApprovals;
    
    function createEscrowWithMultiSig(
        address beneficiary,
        address[] calldata arbiters,
        uint256 required,
        uint256 amount,
        uint256 deadline
    ) external payable returns (uint256 escrowId) {
        escrowId = createEscrow(beneficiary, address(this), amount, deadline);
        escrowArbiters[escrowId] = arbiters;
        requiredApprovals[escrowId] = required;
    }
    
    function approveRelease(uint256 escrowId) external {
        require(_isArbiter(escrowId, msg.sender), "Not arbiter");
        arbiterApprovals[escrowId][msg.sender] = true;
        
        if (_getApprovalCount(escrowId) >= requiredApprovals[escrowId]) {
            releaseEscrow(escrowId);
        }
    }
    
    function _isArbiter(uint256 escrowId, address account) 
        internal 
        view 
        returns (bool) 
    {
        address[] memory arbiters = escrowArbiters[escrowId];
        for (uint256 i = 0; i < arbiters.length; i++) {
            if (arbiters[i] == account) return true;
        }
        return false;
    }
    
    function _getApprovalCount(uint256 escrowId) 
        internal 
        view 
        returns (uint256 count) 
    {
        address[] memory arbiters = escrowArbiters[escrowId];
        for (uint256 i = 0; i < arbiters.length; i++) {
            if (arbiterApprovals[escrowId][arbiters[i]]) count++;
        }
    }
}
```

---

## Testing

### Basic Test Setup
```javascript
// test/MyEscrow.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("MyEscrow", function () {
    let escrow, creator, beneficiary, arbiter;
    
    beforeEach(async function () {
        [creator, beneficiary, arbiter] = await ethers.getSigners();
        
        const MyEscrow = await ethers.getContractFactory("MyEscrow");
        escrow = await MyEscrow.deploy();
    });
    
    it("Should create and release escrow", async function () {
        const amount = ethers.parseEther("1");
        const deadline = (await time.latest()) + 86400;
        
        // Create
        await escrow.connect(creator).createEscrow(
            beneficiary.address,
            arbiter.address,
            amount,
            deadline,
            { value: amount }
        );
        
        // Release
        await expect(escrow.connect(creator).releaseEscrow(0))
            .to.emit(escrow, "EscrowReleased");
    });
});
```

---

## Deployment

### Hardhat Deployment Script
```javascript
// scripts/deploy-production.js
const { ethers } = require("hardhat");

async function main() {
    // Validate network
    const network = await ethers.provider.getNetwork();
    console.log(`Deploying to ${network.name} (chainId: ${network.chainId})`);
    
    if (network.chainId === 1) {
        console.log("⚠️  MAINNET DEPLOYMENT - Double check everything!");
        // Add confirmation prompt here
    }
    
    // Deploy
    const MyEscrow = await ethers.getContractFactory("MyEscrow");
    console.log("Deploying MyEscrow...");
    
    const escrow = await MyEscrow.deploy();
    await escrow.waitForDeployment();
    
    const address = await escrow.getAddress();
    console.log("✅ MyEscrow deployed to:", address);
    
    // Verify on Etherscan
    if (network.chainId !== 31337) { // not local
        console.log("Waiting for block confirmations...");
        await escrow.deploymentTransaction().wait(5);
        
        console.log("Verifying contract...");
        await hre.run("verify:verify", {
            address: address,
            constructorArguments: [],
        });
    }
    
    // Save deployment info
    const fs = require("fs");
    const deployments = {
        network: network.name,
        chainId: network.chainId,
        address: address,
        deployer: (await ethers.provider.getSigner()).address,
        timestamp: new Date().toISOString(),
    };
    
    fs.writeFileSync(
        `deployments/${network.name}.json`,
        JSON.stringify(deployments, null, 2)
    );
    
    console.log("✅ Deployment info saved");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
```

### Deployment Checklist

- [ ] Contracts audited
- [ ] Tests passing (100% coverage)
- [ ] Constructor parameters validated
- [ ] Gas costs estimated
- [ ] Etherscan verification ready
- [ ] Emergency pause mechanism (if needed)
- [ ] Multi-sig ownership (for production)
- [ ] Monitoring/alerts configured

---

## Troubleshooting

### Common Issues

**Issue**: `InvalidDeadline` error
```
Solution: Use blockchain time, not JavaScript time
❌ Bad:  deadline: Date.now() / 1000
✅ Good: deadline: (await time.latest()) + 86400
```

**Issue**: `InsufficientStake` not reverting
```
Solution: Ensure escrow is created with correct amount
await escrow.createEscrowWithGuarantors(..., {
    value: amount  // Must match `amount` parameter
});
```

**Issue**: `CommitmentWindowClosed` error
```
Solution: Commit within 48 hours of escrow creation
Check: block.timestamp < commitmentDeadline
```

**Issue**: Gas estimation fails
```
Solution: Increase gas limit manually
await tx.send({ gasLimit: 500000 })
```

---

## Support

- 📖 [Full Documentation](../contracts/standard/README.md)
- 💬 [Discord Community](https://discord.gg/athenyx)
- 🐛 [GitHub Issues](https://github.com/athenyx/contracts/issues)
- 📧 Email: support@athenyx.io

---

## What's Next?

1. ✅ Integrate Athenyx Standard
2. ⬜ Add custom business logic
3. ⬜ Write comprehensive tests
4. ⬜ Deploy to testnet
5. ⬜ Audit (for production)
6. ⬜ Deploy to mainnet

**Happy Building!** 🚀