const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("MilestoneEscrow - Milestone-Based Payments", function () {
  let milestoneEscrow;
  let creator, beneficiary, arbiter;

  beforeEach(async function () {
    [creator, beneficiary, arbiter] = await ethers.getSigners();

    const MilestoneEscrow = await ethers.getContractFactory("MilestoneEscrow");
    milestoneEscrow = await MilestoneEscrow.deploy();
    await milestoneEscrow.waitForDeployment();
  });

  describe("Create Escrow With Milestones", function () {
    it("Should create escrow with multiple milestones", async function () {
      const milestoneAmounts = [
        ethers.parseEther("1"),
        ethers.parseEther("2"),
        ethers.parseEther("3")
      ];

      const currentTime = Math.floor(Date.now() / 1000);
      const milestoneDeadlines = [
        currentTime + 86400 * 30,
        currentTime + 86400 * 60,
        currentTime + 86400 * 90
      ];

      const descriptions = ["Phase 1", "Phase 2", "Phase 3"];

      const totalAmount = ethers.parseEther("6");

      await expect(
        milestoneEscrow.connect(creator).createEscrowWithMilestones(
          beneficiary.address,
          arbiter.address,
          milestoneAmounts,
          milestoneDeadlines,
          descriptions,
          { value: totalAmount }
        )
      ).to.emit(milestoneEscrow, "EscrowCreated");

      const milestoneCount = await milestoneEscrow.getMilestoneCount(0);
      expect(milestoneCount).to.equal(3);
    });

    it("Should reject empty milestones", async function () {
      await expect(
        milestoneEscrow.connect(creator).createEscrowWithMilestones(
          beneficiary.address,
          arbiter.address,
          [],
          [],
          [],
          { value: ethers.parseEther("1") }
        )
      ).to.be.revertedWithCustomError(milestoneEscrow, "InvalidMilestoneCount");
    });

    it("Should reject mismatched arrays", async function () {
      const milestoneAmounts = [ethers.parseEther("1"), ethers.parseEther("2")];
      const milestoneDeadlines = [Math.floor(Date.now() / 1000) + 86400];

      await expect(
        milestoneEscrow.connect(creator).createEscrowWithMilestones(
          beneficiary.address,
          arbiter.address,
          milestoneAmounts,
          milestoneDeadlines,
          [],
          { value: ethers.parseEther("3") }
        )
      ).to.be.revertedWithCustomError(milestoneEscrow, "InvalidMilestoneCount");
    });
  });

  describe("Milestone Approval and Release", function () {
    let escrowId;

    beforeEach(async function () {
      const milestoneAmounts = [ethers.parseEther("1"), ethers.parseEther("2")];
      const currentTime = Math.floor(Date.now() / 1000);
      const milestoneDeadlines = [currentTime + 86400 * 30, currentTime + 86400 * 60];
      const totalAmount = ethers.parseEther("3");

      const tx = await milestoneEscrow.connect(creator).createEscrowWithMilestones(
        beneficiary.address,
        arbiter.address,
        milestoneAmounts,
        milestoneDeadlines,
        [],
        { value: totalAmount }
      );

      const receipt = await tx.wait();
      const event = receipt.logs.find(log => log.fragment && log.fragment.name === "EscrowCreated");
      escrowId = event.args[0];
    });

    it("Should allow creator to approve milestone", async function () {
      await expect(milestoneEscrow.connect(creator).approveMilestone(escrowId, 0))
        .to.emit(milestoneEscrow, "MilestoneApproved")
        .withArgs(escrowId, 0, creator.address);

      const milestone = await milestoneEscrow.getMilestone(escrowId, 0);
      expect(milestone.approved).to.be.true;
    });

    it("Should not allow non-contributor to approve", async function () {
      const [, , , nonContributor] = await ethers.getSigners();

      await expect(
        milestoneEscrow.connect(nonContributor).approveMilestone(escrowId, 0)
      ).to.be.revertedWithCustomError(milestoneEscrow, "Unauthorized");
    });

    it("Should release milestone after approval", async function () {
      await milestoneEscrow.connect(creator).approveMilestone(escrowId, 0);

      const beneficiaryBalanceBefore = await ethers.provider.getBalance(beneficiary.address);

      await expect(milestoneEscrow.connect(beneficiary).releaseMilestone(escrowId, 0))
        .to.emit(milestoneEscrow, "MilestoneReleased")
        .withArgs(escrowId, 0, ethers.parseEther("1"));

      const beneficiaryBalanceAfter = await ethers.provider.getBalance(beneficiary.address);
      expect(beneficiaryBalanceAfter).to.be.gt(beneficiaryBalanceBefore);

      const milestone = await milestoneEscrow.getMilestone(escrowId, 0);
      expect(milestone.released).to.be.true;
    });

    it("Should complete escrow after all milestones released", async function () {
      await milestoneEscrow.connect(creator).approveMilestone(escrowId, 0);
      await milestoneEscrow.connect(beneficiary).releaseMilestone(escrowId, 0);

      await milestoneEscrow.connect(creator).approveMilestone(escrowId, 1);

      await expect(milestoneEscrow.connect(beneficiary).releaseMilestone(escrowId, 1))
        .to.emit(milestoneEscrow, "EscrowCompleted");

      const state = await milestoneEscrow.getEscrowState(escrowId);
      expect(state).to.equal(3); // COMPLETED
    });

    it("Should get all milestones", async function () {
      const milestones = await milestoneEscrow.getAllMilestones(escrowId);
      expect(milestones.length).to.equal(2);
      expect(milestones[0].amount).to.equal(ethers.parseEther("1"));
      expect(milestones[1].amount).to.equal(ethers.parseEther("2"));
    });
  });
});