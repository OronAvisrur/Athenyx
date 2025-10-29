const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("SimpleEscrow - Basic Escrow Tests", function () {
  let simpleEscrow;
  let creator, beneficiary, arbiter, funder;

  beforeEach(async function () {
    [creator, beneficiary, arbiter, funder] = await ethers.getSigners();

    const SimpleEscrow = await ethers.getContractFactory("SimpleEscrow");
    simpleEscrow = await SimpleEscrow.deploy();
    await simpleEscrow.waitForDeployment();
  });

  describe("Deployment", function () {
    it("Should deploy successfully", async function () {
      expect(await simpleEscrow.getAddress()).to.be.properAddress;
    });

    it("Should start with nextEscrowId = 0", async function () {
      expect(await simpleEscrow.nextEscrowId()).to.equal(0);
    });
  });

  describe("Create Escrow", function () {
    it("Should create escrow with full funding", async function () {
      const amount = ethers.parseEther("1");
      const deadline = (await time.latest()) + 86400;

      await expect(
        simpleEscrow.connect(creator).createEscrow(
          beneficiary.address,
          arbiter.address,
          amount,
          deadline,
          { value: amount }
        )
      )
        .to.emit(simpleEscrow, "EscrowCreated")
        .withArgs(0, creator.address, beneficiary.address, amount);

      const info = await simpleEscrow.getEscrowInfo(0);
      expect(info.creator).to.equal(creator.address);
      expect(info.beneficiary).to.equal(beneficiary.address);
      expect(info.state).to.equal(1); 
    });

    it("Should create escrow with partial funding (PENDING)", async function () {
      const amount = ethers.parseEther("2");
      const partialFunding = ethers.parseEther("1");
      const deadline = (await time.latest()) + 86400; 

      await simpleEscrow.connect(creator).createEscrow(
        beneficiary.address,
        arbiter.address,
        amount,
        deadline,
        { value: partialFunding }
      );

      const state = await simpleEscrow.getEscrowState(0);
      expect(state).to.equal(0); 
    });

    it("Should reject zero beneficiary address", async function () {
      const amount = ethers.parseEther("1");
      const deadline = (await time.latest()) + 86400;

      await expect(
        simpleEscrow.connect(creator).createEscrow(
          ethers.ZeroAddress,
          arbiter.address,
          amount,
          deadline,
          { value: amount }
        )
      ).to.be.revertedWithCustomError(simpleEscrow, "ZeroAddress");
    });

    it("Should reject zero amount", async function () {
      const deadline = (await time.latest()) + 86400; 

      await expect(
        simpleEscrow.connect(creator).createEscrow(
          beneficiary.address,
          arbiter.address,
          0,
          deadline,
          { value: ethers.parseEther("1") }
        )
      ).to.be.revertedWithCustomError(simpleEscrow, "InvalidAmount");
    });
  });

  describe("Fund Escrow", function () {
    let escrowId;

    beforeEach(async function () {
      const amount = ethers.parseEther("2");
      const partialFunding = ethers.parseEther("1");
      const deadline = (await time.latest()) + 86400;

      const tx = await simpleEscrow.connect(creator).createEscrow(
        beneficiary.address,
        arbiter.address,
        amount,
        deadline,
        { value: partialFunding }
      );

      const receipt = await tx.wait();
      const event = receipt.logs.find(log => log.fragment && log.fragment.name === "EscrowCreated");
      escrowId = event.args[0];
    });

    it("Should allow additional funding", async function () {
      const additionalFunding = ethers.parseEther("0.5");

      await expect(
        simpleEscrow.connect(funder).fundEscrow(escrowId, { value: additionalFunding })
      )
        .to.emit(simpleEscrow, "EscrowFunded")
        .withArgs(escrowId, funder.address, additionalFunding);
    });

    it("Should activate escrow when fully funded", async function () {
      const remainingFunding = ethers.parseEther("1");

      await simpleEscrow.connect(funder).fundEscrow(escrowId, { value: remainingFunding });

      const state = await simpleEscrow.getEscrowState(escrowId);
      expect(state).to.equal(1);
    });

    it("Should reject funding active escrow", async function () {
      await simpleEscrow.connect(funder).fundEscrow(escrowId, { value: ethers.parseEther("1") });

      await expect(
        simpleEscrow.connect(funder).fundEscrow(escrowId, { value: ethers.parseEther("0.1") })
      ).to.be.revertedWithCustomError(simpleEscrow, "InvalidState");
    });
  });

  describe("Release Escrow", function () {
    let escrowId;

    beforeEach(async function () {
      const amount = ethers.parseEther("1");
      const deadline = (await time.latest()) + 86400;

      const tx = await simpleEscrow.connect(creator).createEscrow(
        beneficiary.address,
        arbiter.address,
        amount,
        deadline,
        { value: amount }
      );

      const receipt = await tx.wait();
      const event = receipt.logs.find(log => log.fragment && log.fragment.name === "EscrowCreated");
      escrowId = event.args[0];
    });

    it("Should allow creator to release", async function () {
      const beneficiaryBalanceBefore = await ethers.provider.getBalance(beneficiary.address);

      await expect(simpleEscrow.connect(creator).releaseEscrow(escrowId))
        .to.emit(simpleEscrow, "EscrowReleased")
        .to.emit(simpleEscrow, "EscrowCompleted");

      const beneficiaryBalanceAfter = await ethers.provider.getBalance(beneficiary.address);
      expect(beneficiaryBalanceAfter).to.be.gt(beneficiaryBalanceBefore);

      const state = await simpleEscrow.getEscrowState(escrowId);
      expect(state).to.equal(3);
    });

    it("Should allow arbiter to release", async function () {
      await expect(simpleEscrow.connect(arbiter).releaseEscrow(escrowId))
        .to.emit(simpleEscrow, "EscrowReleased");
    });

    it("Should not allow unauthorized release", async function () {
      await expect(
        simpleEscrow.connect(funder).releaseEscrow(escrowId)
      ).to.be.revertedWithCustomError(simpleEscrow, "Unauthorized");
    });
  });

  describe("Cancel Escrow", function () {
    let escrowId;

    beforeEach(async function () {
      const amount = ethers.parseEther("1");
      const deadline = (await time.latest()) + 86400;

      const tx = await simpleEscrow.connect(creator).createEscrow(
        beneficiary.address,
        arbiter.address,
        amount,
        deadline,
        { value: amount }
      );

      const receipt = await tx.wait();
      const event = receipt.logs.find(log => log.fragment && log.fragment.name === "EscrowCreated");
      escrowId = event.args[0];
    });

    it("Should allow creator to cancel", async function () {
      const creatorBalanceBefore = await ethers.provider.getBalance(creator.address);

      await expect(simpleEscrow.connect(creator).cancelEscrow(escrowId))
        .to.emit(simpleEscrow, "EscrowCancelled");

      const state = await simpleEscrow.getEscrowState(escrowId);
      expect(state).to.equal(2);

      const creatorBalanceAfter = await ethers.provider.getBalance(creator.address);
      expect(creatorBalanceAfter).to.be.gt(creatorBalanceBefore);
    });

    it("Should allow arbiter to cancel", async function () {
      await expect(simpleEscrow.connect(arbiter).cancelEscrow(escrowId))
        .to.emit(simpleEscrow, "EscrowCancelled");
    });

    it("Should not allow unauthorized cancellation", async function () {
      await expect(
        simpleEscrow.connect(beneficiary).cancelEscrow(escrowId)
      ).to.be.revertedWithCustomError(simpleEscrow, "Unauthorized");
    });
  });
});