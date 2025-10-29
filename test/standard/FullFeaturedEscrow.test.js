const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("FullFeaturedEscrow - Complete Integration", function () {
  let fullEscrow;
  let creator, beneficiary, arbiter, guarantor1, guarantor2, guarantor3;

  beforeEach(async function () {
    [creator, beneficiary, arbiter, guarantor1, guarantor2, guarantor3] = await ethers.getSigners();

    const FullFeaturedEscrow = await ethers.getContractFactory("FullFeaturedEscrow");
    fullEscrow = await FullFeaturedEscrow.deploy();
    await fullEscrow.waitForDeployment();
  });

  describe("Deployment", function () {
    it("Should deploy successfully", async function () {
      expect(await fullEscrow.getAddress()).to.be.properAddress;
    });

    it("Should have correct constants", async function () {
      expect(await fullEscrow.COMMITMENT_WINDOW()).to.equal(48 * 3600);
      expect(await fullEscrow.REVEAL_WINDOW()).to.equal(24 * 3600);
      expect(await fullEscrow.MIN_PRIMARY_STAKE_PERCENTAGE()).to.equal(20);
    });
  });

  describe("Create Escrow With Guarantors", function () {
    it("Should create escrow requiring guarantors", async function () {
      const amount = ethers.parseEther("10");
      const deadline = Math.floor(Date.now() / 1000) + 86400 * 90;
      const minGuarantors = 3;

      await expect(
        fullEscrow.connect(creator).createEscrowWithGuarantors(
          beneficiary.address,
          arbiter.address,
          amount,
          deadline,
          minGuarantors,
          { value: amount }
        )
      ).to.emit(fullEscrow, "EscrowCreated");

      const info = await fullEscrow.getEscrowInfo(0);
      expect(info.amount).to.equal(amount);
      expect(info.beneficiary).to.equal(beneficiary.address);
    });
  });

  describe("Guarantor Commit-Reveal Flow", function () {
    let escrowId;
    const escrowAmount = ethers.parseEther("10");
    const minStake = ethers.parseEther("2"); // 20% for PRIMARY

    beforeEach(async function () {
      const deadline = Math.floor(Date.now() / 1000) + 86400 * 90;
      
      const tx = await fullEscrow.connect(creator).createEscrowWithGuarantors(
        beneficiary.address,
        arbiter.address,
        escrowAmount,
        deadline,
        3, // minGuarantors
        { value: escrowAmount }
      );

      const receipt = await tx.wait();
      const event = receipt.logs.find(log => log.fragment && log.fragment.name === "EscrowCreated");
      escrowId = event.args[0];
    });

    it("Should allow guarantor to commit", async function () {
      const secret = ethers.randomBytes(32);
      const commitmentHash = ethers.keccak256(
        ethers.solidityPacked(
          ["address", "bytes32", "uint256"],
          [guarantor1.address, secret, escrowId]
        )
      );

      await expect(
        fullEscrow.connect(guarantor1).commitAsGuarantor(
          escrowId,
          1, // GuarantorTier.PRIMARY
          commitmentHash,
          { value: minStake }
        )
      )
        .to.emit(fullEscrow, "GuarantorCommitted")
        .withArgs(escrowId, guarantor1.address, 1, minStake);

      const guarantors = await fullEscrow.getGuarantors(escrowId);
      expect(guarantors.length).to.equal(1);
      expect(guarantors[0]).to.equal(guarantor1.address);
    });

    it("Should reject insufficient stake", async function () {
      // Get escrow info
      const info = await fullEscrow.getEscrowInfo(escrowId);
      
      const minStakeCalculated = (info.amount * 20n) / 100n;
      console.log("Calculated min stake (20%):", ethers.formatEther(minStakeCalculated), "ETH");
      
      const secret = ethers.randomBytes(32);
      const commitmentHash = ethers.keccak256(
        ethers.solidityPacked(
          ["address", "bytes32", "uint256"],
          [guarantor1.address, secret, escrowId]
        )
      );

      const insufficientStake = ethers.parseEther("1");

      await expect(
        fullEscrow.connect(guarantor1).commitAsGuarantor(
          escrowId,
          2,
          commitmentHash,
          { value: insufficientStake }
        )
      ).to.be.revertedWithCustomError(fullEscrow, "InsufficientStake");
    });


    it("Should allow reveal after commitment window", async function () {
      const guarantors = [guarantor1, guarantor2, guarantor3];
      const secrets = [];

      for (let i = 0; i < 3; i++) {
        const secret = ethers.randomBytes(32);
        secrets.push(secret);
        
        const commitmentHash = ethers.keccak256(
          ethers.solidityPacked(
            ["address", "bytes32", "uint256"],
            [guarantors[i].address, secret, escrowId]
          )
        );

        await fullEscrow.connect(guarantors[i]).commitAsGuarantor(
          escrowId,
          1,
          commitmentHash,
          { value: minStake }
        );
      }

      await time.increase(48 * 3600 + 1);

      for (let i = 0; i < 3; i++) {
        await expect(
          fullEscrow.connect(guarantors[i]).revealCommitment(escrowId, secrets[i])
        )
          .to.emit(fullEscrow, "GuarantorRevealed")
          .withArgs(escrowId, guarantors[i].address);
      }

      for (let i = 0; i < 3; i++) {
        const isVerified = await fullEscrow.isGuarantorVerified(escrowId, guarantors[i].address);
        expect(isVerified).to.be.true;
      }
      
      const canActivate = await fullEscrow.canActivateEscrow(escrowId);
      expect(canActivate).to.be.true;
    });

    it("Should reject reveal before commitment window closes", async function () {
      const secret = ethers.randomBytes(32);
      const commitmentHash = ethers.keccak256(
        ethers.solidityPacked(
          ["address", "bytes32", "uint256"],
          [guarantor1.address, secret, escrowId]
        )
      );

      await fullEscrow.connect(guarantor1).commitAsGuarantor(
        escrowId,
        1,
        commitmentHash,
        { value: minStake }
      );

      await expect(
        fullEscrow.connect(guarantor1).revealCommitment(escrowId, secret)
      ).to.be.revertedWithCustomError(fullEscrow, "RevealWindowNotOpen");
    });

    it("Should reject wrong secret on reveal", async function () {
      const secret = ethers.randomBytes(32);
      const wrongSecret = ethers.randomBytes(32);
      
      const commitmentHash = ethers.keccak256(
        ethers.solidityPacked(
          ["address", "bytes32", "uint256"],
          [guarantor1.address, secret, escrowId]
        )
      );

      await fullEscrow.connect(guarantor1).commitAsGuarantor(
        escrowId,
        1,
        commitmentHash,
        { value: minStake }
      );

      await time.increase(48 * 3600 + 1);

      await expect(
        fullEscrow.connect(guarantor1).revealCommitment(escrowId, wrongSecret)
      ).to.be.revertedWithCustomError(fullEscrow, "InvalidCommitmentHash");
    });
  });

  describe("Milestones + Guarantors Integration", function () {
    let escrowId;

    beforeEach(async function () {
      const totalAmount = ethers.parseEther("10");
      const currentTime = await time.latest();
      const deadline = currentTime + 86400 * 90;

      const tx = await fullEscrow.connect(creator).createEscrowWithGuarantors(
        beneficiary.address,
        arbiter.address,
        totalAmount,
        deadline,
        3, // minGuarantors
        { value: totalAmount }
      );

      const receipt = await tx.wait();
      const event = receipt.logs.find(log => log.fragment && log.fragment.name === "EscrowCreated");
      escrowId = event.args[0];

      const minStake = ethers.parseEther("2");
      const guarantors = [guarantor1, guarantor2, guarantor3];
      const secrets = [];
      
      for (let i = 0; i < 3; i++) {
        const secret = ethers.randomBytes(32);
        secrets.push(secret);
        
        const commitmentHash = ethers.keccak256(
          ethers.solidityPacked(
            ["address", "bytes32", "uint256"],
            [guarantors[i].address, secret, escrowId]
          )
        );

        await fullEscrow.connect(guarantors[i]).commitAsGuarantor(
          escrowId,
          1, // PRIMARY
          commitmentHash,
          { value: minStake }
        );
      }

      await time.increase(48 * 3600 + 1);

      for (let i = 0; i < 3; i++) {
        await fullEscrow.connect(guarantors[i]).revealCommitment(escrowId, secrets[i]);
      }
    });

    it("Should have guarantors after setup", async function () {
      const guarantors = await fullEscrow.getGuarantors(escrowId);
      expect(guarantors.length).to.equal(3);
    });

    it("Should allow creator to approve and release funds", async function () {
      const beneficiaryBalanceBefore = await ethers.provider.getBalance(beneficiary.address);

      await expect(fullEscrow.connect(creator).releaseEscrow(escrowId))
        .to.emit(fullEscrow, "EscrowReleased")
        .to.emit(fullEscrow, "EscrowCompleted");

      const beneficiaryBalanceAfter = await ethers.provider.getBalance(beneficiary.address);
      expect(beneficiaryBalanceAfter).to.be.gt(beneficiaryBalanceBefore);
    });

    it("Should refund guarantors on completion", async function () {
      const guarantor1BalanceBefore = await ethers.provider.getBalance(guarantor1.address);

      await fullEscrow.connect(creator).releaseEscrow(escrowId);

      const guarantor1BalanceAfter = await ethers.provider.getBalance(guarantor1.address);
      
      expect(guarantor1BalanceAfter).to.be.gt(guarantor1BalanceBefore);
    });
  });

  describe("Guarantor Slashing", function () {
    let escrowId;

    beforeEach(async function () {
      const amount = ethers.parseEther("10");
      const deadline = Math.floor(Date.now() / 1000) + 86400 * 90;

      const tx = await fullEscrow.connect(creator).createEscrowWithGuarantors(
        beneficiary.address,
        arbiter.address,
        amount,
        deadline,
        1,
        { value: amount }
      );

      const receipt = await tx.wait();
      const event = receipt.logs.find(log => log.fragment && log.fragment.name === "EscrowCreated");
      escrowId = event.args[0];

      const secret = ethers.randomBytes(32);
      const commitmentHash = ethers.keccak256(
        ethers.solidityPacked(
          ["address", "bytes32", "uint256"],
          [guarantor1.address, secret, escrowId]
        )
      );

      await fullEscrow.connect(guarantor1).commitAsGuarantor(
        escrowId,
        1,
        commitmentHash,
        { value: ethers.parseEther("2") }
      );

      await time.increase(48 * 3600 + 1);
      await fullEscrow.connect(guarantor1).revealCommitment(escrowId, secret);
    });

    it("Should allow arbiter to slash guarantor", async function () {
      const slashAmount = ethers.parseEther("1");

      await expect(
        fullEscrow.connect(arbiter).slashGuarantor(escrowId, guarantor1.address, slashAmount)
      )
        .to.emit(fullEscrow, "GuarantorSlashed")
        .withArgs(escrowId, guarantor1.address, slashAmount);
    });

    it("Should not allow non-arbiter to slash", async function () {
      const slashAmount = ethers.parseEther("1");

      await expect(
        fullEscrow.connect(creator).slashGuarantor(escrowId, guarantor1.address, slashAmount)
      ).to.be.revertedWithCustomError(fullEscrow, "Unauthorized");
    });
  });
});