# Athenyx Standard - Modular Escrow Framework

A composable, gas-efficient, and production-ready escrow standard for Ethereum and EVM-compatible chains.

<div align="center">

[![Solidity](https://img.shields.io/badge/Solidity-^0.8.20-363636?style=flat-square&logo=solidity)](https://soliditylang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](https://opensource.org/licenses/MIT)
[![Tests](https://img.shields.io/badge/Tests-52%20passing-success?style=flat-square)]()

</div>

---

## 🎯 Overview

Athenyx Standard provides a **minimal, modular, and extensible** escrow framework that allows developers to compose exactly the features they need - nothing more, nothing less.

### Design Philosophy

Like ERC-20 and ERC-721, Athenyx Standard follows these principles:

1. **Minimal Core** - Basic escrow with ~200 lines of code
2. **Optional Extensions** - Add features only when needed
3. **Composable** - Mix and match extensions freely
4. **Gas Efficient** - Pay only for what you use
5. **Battle-tested** - 50+ comprehensive tests

---

## 📦 Quick Start

### Installation
```bash
npm install @athenyx/contracts
```

### Simple Escrow (3 lines!)
```solidity
import "@athenyx/contracts/standard/core/EscrowCore.sol";

contract MyEscrow is EscrowCore {}
```

Deploy and use:
```javascript
const escrow = await MyEscrow.deploy();
await escrow.createEscrow(
  beneficiaryAddress,
  arbiterAddress,
  ethers.parseEther("10"),
  deadline,
  { value: ethers.parseEther("10") }
);
```

---

## 🏗️ Architecture
```
┌─────────────────────────────────────────────────────┐
│                  Your Contract                      │
├─────────────────────────────────────────────────────┤
│                                                     │
│  Choose what you need:                              │
│                                                     │
│  ┌──────────────┐  ┌─────────────────┐              │
│  │ EscrowCore   │  │ EscrowMilestones│              │
│  │ (required)   │  │ (optional)      │              │
│  └──────┬───────┘  └────────┬────────┘              │
│         │                    │                      │
│         └────────┬───────────┘                      │
│                  │                                  │
│         ┌────────▼─────────┐                        │
│         │ EscrowGuarantors │                        │
│         │   (optional)     │                        │
│         └──────────────────┘                        │
│                                                     │
└─────────────────────────────────────────────────────┘
```

---

## 🧩 Components

### Core

**EscrowCore** - The foundation
- Create escrows with beneficiary and arbiter
- Fund escrows (single or multi-party)
- Release funds to beneficiary
- Cancel and refund
- ~200 lines of battle-tested code

### Extensions

**EscrowMilestones** - Milestone-based payments
- Split payments into stages
- Approval-based releases
- Deadline enforcement
- Perfect for: freelance work, project funding

**EscrowGuarantors** - Social collateral system
- Commit-reveal mechanism (Byzantine-resistant)
- Multi-tier guarantors (PRIMARY/SECONDARY)
- Stake management with slashing
- Perfect for: P2P lending, trust networks

**EscrowInsurance** *(coming soon)*
- Automated insurance coverage
- Premium calculation
- Claims processing

---

## 💡 Usage Examples

### Example 1: Simple Escrow

**Use case**: Basic payment holding
```solidity
import "@athenyx/contracts/standard/core/EscrowCore.sol";

contract SimplePayment is EscrowCore {
    // That's it! You have a working escrow.
}
```

**Features**:
- ✅ Create escrow
- ✅ Fund from single/multiple parties
- ✅ Release to beneficiary
- ✅ Cancel and refund
- ✅ Arbiter mediation

---

### Example 2: Milestone-Based Escrow

**Use case**: Freelance project with deliverables
```solidity
import "@athenyx/contracts/standard/extensions/EscrowMilestones.sol";

contract FreelanceEscrow is EscrowMilestones {
    // Inherits all core + milestone features
}
```

**Usage**:
```javascript
// Create escrow with 3 milestones
await escrow.createEscrowWithMilestones(
  freelancerAddress,
  arbiterAddress,
  [
    ethers.parseEther("2"),  // Design phase
    ethers.parseEther("3"),  // Development
    ethers.parseEther("5")   // Deployment
  ],
  [
    deadline1,
    deadline2,
    deadline3
  ],
  ["Design", "Development", "Deployment"],
  { value: ethers.parseEther("10") }
);

// Approve and release milestones one by one
await escrow.approveMilestone(escrowId, 0);
await escrow.releaseMilestone(escrowId, 0);
```

---

### Example 3: Full-Featured (Milestones + Guarantors)

**Use case**: P2P lending with social collateral
```solidity
import "@athenyx/contracts/standard/extensions/EscrowMilestones.sol";
import "@athenyx/contracts/standard/extensions/EscrowGuarantors.sol";

contract P2PLending is EscrowMilestones, EscrowGuarantors {
    function _onEscrowCompleted(uint256 escrowId) 
        internal 
        virtual 
        override(EscrowCore, EscrowGuarantors) 
    {
        EscrowGuarantors._onEscrowCompleted(escrowId);
    }
}
```

**Features**:
- ✅ All milestone features
- ✅ Guarantor commit-reveal
- ✅ Stake management
- ✅ Automatic refunds on success
- ✅ Slashing on default

---

## 📚 API Reference

### IEscrowCore
```solidity
interface IEscrowCore {
    function createEscrow(
        address beneficiary,
        address arbiter,
        uint256 amount,
        uint256 deadline
    ) external payable returns (uint256 escrowId);

    function fundEscrow(uint256 escrowId) external payable;
    function releaseEscrow(uint256 escrowId) external;
    function cancelEscrow(uint256 escrowId) external;
    
    function getEscrowInfo(uint256 escrowId) 
        external view returns (EscrowBasicInfo memory);
}
```

### IEscrowMilestones
```solidity
interface IEscrowMilestones {
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
        external view returns (Milestone memory);
}
```

### IEscrowGuarantors
```solidity
interface IEscrowGuarantors {
    function commitAsGuarantor(
        uint256 escrowId,
        GuarantorTier tier,
        bytes32 commitmentHash
    ) external payable;

    function revealCommitment(uint256 escrowId, bytes32 secret) external;
    
    function getGuarantors(uint256 escrowId) 
        external view returns (address[] memory);
}
```

---

## 🔒 Security

### Audits

- ✅ Internal review complete
- 🔄 External audit: Q2 2025
- 🔄 Bug bounty: Coming soon

### Best Practices

All contracts implement:
- ✅ ReentrancyGuard
- ✅ Custom errors (gas efficient)
- ✅ Checks-Effects-Interactions
- ✅ No delegatecall
- ✅ Explicit state management

---

## 🧪 Testing
```bash
# Clone repository
git clone https://github.com/athenyx/contracts
cd contracts

# Install dependencies
npm install

# Run tests
npm test

# With coverage
npm run test:coverage
```

**Test Coverage**: 52+ tests, 100% line coverage on core contracts

---

## 🎓 Learn More

- [Integration Guide](./INTEGRATION-GUIDE.md) - Step-by-step examples
- [EIP Draft](./EIP-DRAFT.md) - Technical specification
- [Full Protocol](../README.md) - Complete Athenyx system

---

## 🤝 Contributing

We welcome contributions! See [CONTRIBUTING.md](../CONTRIBUTING.md)

---

## 📄 License

MIT License - see [LICENSE](../LICENSE)

---

## 🌟 Why Choose Athenyx Standard?

| Feature | Athenyx Standard | Traditional Escrow | Other Solutions |
|---------|------------------|-------------------|-----------------|
| **Modularity** | ✅ Pick what you need | ❌ All-or-nothing | ⚠️ Limited |
| **Gas Cost** | ✅ Pay only for features used | ❌ High overhead | ⚠️ Variable |
| **Composability** | ✅ Mix extensions freely | ❌ Monolithic | ⚠️ Fixed |
| **Battle-tested** | ✅ 50+ tests | ⚠️ Varies | ⚠️ Varies |
| **EIP Standard** | ✅ In progress | ❌ No | ❌ No |

---

<div align="center">

**Built with ❤️ for the Ethereum community**

[GitHub](https://github.com/athenyx) • [Discord](https://discord.gg/athenyx) • [Twitter](https://twitter.com/athenyx)

</div>