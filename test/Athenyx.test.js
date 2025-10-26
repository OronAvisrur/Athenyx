const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("Athenyx Protocol - Core Tests", function () {
  let athenyx;
  let guarantorRegistry;
  let insurancePool;
  let lenderIncentives;
  
  let deployer, seller, buyer, lender, guarantor1, guarantor2, arbiter;

  const INITIAL_REPUTATION = 100n;
  const MIN_REPUTATION_PRIMARY = 200n;

  beforeEach(async function () {
    [deployer, seller, buyer, lender, guarantor1, guarantor2, arbiter] = await ethers.getSigners();

    // Deploy GuarantorRegistry
    const GuarantorRegistry = await ethers.getContractFactory("GuarantorRegistry");
    guarantorRegistry = await GuarantorRegistry.deploy();
    await guarantorRegistry.waitForDeployment();

    // Deploy InsurancePool
    const InsurancePool = await ethers.getContractFactory("InsurancePool");
    insurancePool = await InsurancePool.deploy(deployer.address);
    await insurancePool.waitForDeployment();

    // Deploy LenderIncentives
    const LenderIncentives = await ethers.getContractFactory("LenderIncentives");
    lenderIncentives = await LenderIncentives.deploy();
    await lenderIncentives.waitForDeployment();

    // Deploy Athenyx
    const Athenyx = await ethers.getContractFactory("Athenyx");
    athenyx = await Athenyx.deploy(
      await guarantorRegistry.getAddress(),
      await insurancePool.getAddress(),
      await lenderIncentives.getAddress()
    );
    await athenyx.waitForDeployment();

    // Configure permissions
    await guarantorRegistry.setAthenyxCore(await athenyx.getAddress());
    await insurancePool.setAthenyxCore(await athenyx.getAddress());
    await lenderIncentives.setAthenyxCore(await athenyx.getAddress());
    await lenderIncentives.setGuarantorRegistry(await guarantorRegistry.getAddress());
  });

  describe("Deployment", function () {
    it("Should set the correct addresses", async function () {
      expect(await athenyx.guarantorRegistry()).to.equal(await guarantorRegistry.getAddress());
      expect(await athenyx.insurancePool()).to.equal(await insurancePool.getAddress());
      expect(await athenyx.lenderIncentives()).to.equal(await lenderIncentives.getAddress());
    });

    it("Should start with nextEscrowId = 0", async function () {
      expect(await athenyx.nextEscrowId()).to.equal(0);
    });
  });

  describe("Simple Escrow Creation", function () {
    it("Should create a basic escrow without guarantors", async function () {
      const milestoneAmounts = [
        ethers.parseEther("1"),
        ethers.parseEther("2")
      ];
      
      const futureTime = (await time.latest()) + 86400 * 30;
      const milestoneDeadlines = [futureTime, futureTime + 86400 * 30];
      
      const arbiterFee = ethers.parseEther("0.1");
      const totalValue = ethers.parseEther("3.1");

      const tx = await athenyx.connect(buyer).createEscrow(
        seller.address,
        arbiter.address,
        arbiterFee,
        milestoneAmounts,
        milestoneDeadlines,
        false, // no guarantors required
        0,
        { value: totalValue }
      );

      await expect(tx)
        .to.emit(athenyx, "EscrowCreated")
        .withArgs(0, seller.address, arbiter.address, ethers.parseEther("3"), arbiterFee, false);

      const details = await athenyx.getEscrowDetails(0);
      expect(details[1]).to.equal(seller.address); // seller
      expect(details[4]).to.equal(totalValue); // totalFunded
    });

    it("Should fail if seller is zero address", async function () {
      await expect(
        athenyx.connect(buyer).createEscrow(
          ethers.ZeroAddress,
          arbiter.address,
          ethers.parseEther("0.1"),
          [ethers.parseEther("1")],
          [(await time.latest()) + 86400],
          false,
          0,
          { value: ethers.parseEther("1.1") }
        )
      ).to.be.revertedWithCustomError(athenyx, "ZeroAddress");
    });

    it("Should fail if no milestones provided", async function () {
      await expect(
        athenyx.connect(buyer).createEscrow(
          seller.address,
          arbiter.address,
          ethers.parseEther("0.1"),
          [], // empty
          [],
          false,
          0,
          { value: ethers.parseEther("0.1") }
        )
      ).to.be.revertedWithCustomError(athenyx, "EmptyMilestones");
    });

    it("Should mint NFT to seller", async function () {
      const milestoneAmounts = [ethers.parseEther("1")];
      const milestoneDeadlines = [(await time.latest()) + 86400];
      
      await athenyx.connect(buyer).createEscrow(
        seller.address,
        arbiter.address,
        ethers.parseEther("0.1"),
        milestoneAmounts,
        milestoneDeadlines,
        false,
        0,
        { value: ethers.parseEther("1.1") }
      );

      expect(await athenyx.ownerOf(0)).to.equal(seller.address);
    });
  });

  describe("Milestone Approval and Release", function () {
    let escrowId;

    beforeEach(async function () {
      const milestoneAmounts = [ethers.parseEther("1"), ethers.parseEther("2")];
      const futureTime = (await time.latest()) + 86400 * 30;
      const milestoneDeadlines = [futureTime, futureTime + 86400 * 30];
      
      const tx = await athenyx.connect(buyer).createEscrow(
        seller.address,
        arbiter.address,
        ethers.parseEther("0.1"),
        milestoneAmounts,
        milestoneDeadlines,
        false,
        0,
        { value: ethers.parseEther("3.1") }
      );

      const receipt = await tx.wait();
      const event = receipt.logs.find(log => log.fragment && log.fragment.name === "EscrowCreated");
      escrowId = event.args[0];
    });

    it("Should allow payer to approve milestone", async function () {
      await expect(athenyx.connect(buyer).approveMilestone(escrowId, 0))
        .to.emit(athenyx, "MilestoneApproved")
        .withArgs(escrowId, 0, buyer.address);

      const milestone = await athenyx.getMilestone(escrowId, 0);
      expect(milestone[2]).to.be.true; // approved
    });

    it("Should not allow non-payer to approve", async function () {
      await expect(
        athenyx.connect(lender).approveMilestone(escrowId, 0)
      ).to.be.revertedWithCustomError(athenyx, "Unauthorized");
    });

    it("Should release milestone after approval", async function () {
      await athenyx.connect(buyer).approveMilestone(escrowId, 0);

      const sellerBalanceBefore = await ethers.provider.getBalance(seller.address);
      
      await expect(athenyx.connect(seller).releaseMilestone(escrowId, 0))
        .to.emit(athenyx, "MilestoneReleased")
        .withArgs(escrowId, 0, ethers.parseEther("1"));

      const sellerBalanceAfter = await ethers.provider.getBalance(seller.address);
      expect(sellerBalanceAfter).to.be.gt(sellerBalanceBefore);
    });

    it("Should not release unapproved milestone", async function () {
      await expect(
        athenyx.connect(seller).releaseMilestone(escrowId, 0)
      ).to.be.revertedWithCustomError(athenyx, "NotApproved");
    });

    it("Should complete escrow after all milestones released", async function () {
      await athenyx.connect(buyer).approveMilestone(escrowId, 0);
      await athenyx.connect(seller).releaseMilestone(escrowId, 0);

      await athenyx.connect(buyer).approveMilestone(escrowId, 1);
      
      await expect(athenyx.connect(seller).releaseMilestone(escrowId, 1))
        .to.emit(athenyx, "EscrowCompleted")
        .withArgs(escrowId);

      const details = await athenyx.getEscrowDetails(escrowId);
      expect(details[8]).to.equal(3); // EscrowState.COMPLETED
    });
  });

  describe("Contribution", function () {
    let escrowId;

    beforeEach(async function () {
      const milestoneAmounts = [ethers.parseEther("1")];
      const milestoneDeadlines = [(await time.latest()) + 86400 * 30];
      
      const tx = await athenyx.connect(buyer).createEscrow(
        seller.address,
        arbiter.address,
        ethers.parseEther("0.1"),
        milestoneAmounts,
        milestoneDeadlines,
        false,
        0,
        { value: ethers.parseEther("1.1") }
      );

      const receipt = await tx.wait();
      const event = receipt.logs.find(log => log.fragment && log.fragment.name === "EscrowCreated");
      escrowId = event.args[0];
    });

    it("Should allow additional contributions", async function () {
      await expect(
        athenyx.connect(lender).contributeToEscrow(escrowId, { value: ethers.parseEther("0.5") })
      )
        .to.emit(athenyx, "ContributionAdded")
        .withArgs(escrowId, lender.address, ethers.parseEther("0.5"));

      const details = await athenyx.getEscrowDetails(escrowId);
      expect(details[4]).to.equal(ethers.parseEther("1.6")); // totalFunded
    });

    it("Should track multiple contributors", async function () {
      await athenyx.connect(lender).contributeToEscrow(escrowId, { value: ethers.parseEther("0.5") });
      
      expect(await athenyx.hasContributed(escrowId, buyer.address)).to.be.true;
      expect(await athenyx.hasContributed(escrowId, lender.address)).to.be.true;
      expect(await athenyx.hasContributed(escrowId, seller.address)).to.be.false;
    });
  });

  describe("Dispute Resolution", function () {
    let escrowId;

    beforeEach(async function () {
      const milestoneAmounts = [ethers.parseEther("1"), ethers.parseEther("2")];
      const futureTime = (await time.latest()) + 86400 * 30;
      const milestoneDeadlines = [futureTime, futureTime + 86400 * 30];
      
      const tx = await athenyx.connect(buyer).createEscrow(
        seller.address,
        arbiter.address,
        ethers.parseEther("0.1"),
        milestoneAmounts,
        milestoneDeadlines,
        false,
        0,
        { value: ethers.parseEther("3.1") }
      );

      const receipt = await tx.wait();
      const event = receipt.logs.find(log => log.fragment && log.fragment.name === "EscrowCreated");
      escrowId = event.args[0];
    });

    it("Should allow payer to raise dispute", async function () {
      await expect(athenyx.connect(buyer).raiseDispute(escrowId))
        .to.emit(athenyx, "DisputeRaised")
        .withArgs(escrowId, buyer.address);

      const details = await athenyx.getEscrowDetails(escrowId);
      expect(details[8]).to.equal(4); // EscrowState.DISPUTED
    });

    it("Should allow seller to raise dispute", async function () {
      await expect(athenyx.connect(seller).raiseDispute(escrowId))
        .to.emit(athenyx, "DisputeRaised");
    });

    it("Should not allow non-participant to raise dispute", async function () {
      await expect(
        athenyx.connect(lender).raiseDispute(escrowId)
      ).to.be.revertedWithCustomError(athenyx, "Unauthorized");
    });

    it("Should allow arbiter to resolve dispute", async function () {
      await athenyx.connect(buyer).raiseDispute(escrowId);

      await expect(
        athenyx.connect(arbiter).resolveDispute(escrowId, [0])
      )
        .to.emit(athenyx, "DisputeResolved")
        .withArgs(escrowId, [0]);

      const details = await athenyx.getEscrowDetails(escrowId);
      expect(details[8]).to.equal(1); // EscrowState.ACTIVE
    });

    it("Should not allow non-arbiter to resolve", async function () {
      await athenyx.connect(buyer).raiseDispute(escrowId);

      await expect(
        athenyx.connect(seller).resolveDispute(escrowId, [0])
      ).to.be.revertedWithCustomError(athenyx, "Unauthorized");
    });
  });

  describe("GuarantorRegistry Integration", function () {
    it("Should register guarantor", async function () {
      await guarantorRegistry.connect(guarantor1).registerGuarantor();

      const profile = await guarantorRegistry.getGuarantorProfile(guarantor1.address);
      expect(profile.guarantorAddress).to.equal(guarantor1.address);
      expect(profile.reputationScore).to.equal(INITIAL_REPUTATION);
    });

    it("Should not allow double registration", async function () {
      await guarantorRegistry.connect(guarantor1).registerGuarantor();

      await expect(
        guarantorRegistry.connect(guarantor1).registerGuarantor()
      ).to.be.revertedWithCustomError(guarantorRegistry, "AlreadyRegistered");
    });
  });

  describe("LenderIncentives Integration", function () {
    it("Should register lender", async function () {
      await lenderIncentives.connect(lender).registerLender();

      const profile = await lenderIncentives.getLenderProfile(lender.address);
      expect(profile.lenderAddress).to.equal(lender.address);
      expect(profile.totalLent).to.equal(0);
    });

    it("Should allow lender to place loan offer", async function () {
      await lenderIncentives.connect(lender).registerLender();

      await expect(
        lenderIncentives.connect(lender).placeLoanOffer(0, 750, { value: ethers.parseEther("5") })
      )
        .to.emit(lenderIncentives, "LoanOfferPlaced")
        .withArgs(0, lender.address, ethers.parseEther("5"), 750);
    });
  });

  describe("InsurancePool Integration", function () {
    it("Should have correct initial state", async function () {
      const stats = await insurancePool.getPoolStats();
      expect(stats.totalCollected).to.equal(0);
      expect(stats.currentBalance).to.equal(0);
    });

    it("Should calculate premium correctly", async function () {
      const premium = await insurancePool.calculatePremium(
        ethers.parseEther("10"),
        86400 * 90, // 90 days
        100 // risk score
      );

      expect(premium).to.be.gt(0);
    });
  });

  describe("NFT Ownership Transfer", function () {
    let escrowId;

    beforeEach(async function () {
      const milestoneAmounts = [ethers.parseEther("1")];
      const milestoneDeadlines = [(await time.latest()) + 86400 * 30];
      
      const tx = await athenyx.connect(buyer).createEscrow(
        seller.address,
        arbiter.address,
        ethers.parseEther("0.1"),
        milestoneAmounts,
        milestoneDeadlines,
        false,
        0,
        { value: ethers.parseEther("1.1") }
      );

      const receipt = await tx.wait();
      const event = receipt.logs.find(log => log.fragment && log.fragment.name === "EscrowCreated");
      escrowId = event.args[0];
    });

    it("Should transfer seller rights with NFT", async function () {
      await athenyx.connect(seller).transferFrom(seller.address, lender.address, escrowId);

      expect(await athenyx.ownerOf(escrowId)).to.equal(lender.address);

      const details = await athenyx.getEscrowDetails(escrowId);
      expect(details[1]).to.equal(lender.address); // new seller
    });
  });
});