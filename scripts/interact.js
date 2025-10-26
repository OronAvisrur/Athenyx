const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

async function loadDeployment() {
  const deploymentsDir = path.join(__dirname, "..", "deployments");
  const latestPath = path.join(deploymentsDir, `${hre.network.name}-latest.json`);
  
  if (!fs.existsSync(latestPath)) {
    throw new Error("No deployment found. Please run: npm run deploy:local");
  }
  
  return JSON.parse(fs.readFileSync(latestPath, "utf8"));
}

async function main() {
  console.log("🔗 Athenyx Protocol - Interaction Script\n");

  const [deployer, seller, buyer, lender, guarantor1, guarantor2, arbiter] = await hre.ethers.getSigners();
  
  console.log("👥 Accounts:");
  console.log("   Deployer:   ", deployer.address);
  console.log("   Seller:     ", seller.address);
  console.log("   Buyer:      ", buyer.address);
  console.log("   Lender:     ", lender.address);
  console.log("   Guarantor 1:", guarantor1.address);
  console.log("   Guarantor 2:", guarantor2.address);
  console.log("   Arbiter:    ", arbiter.address);
  console.log("");

  const deployment = await loadDeployment();
  console.log("📦 Loading deployed contracts...");
  console.log("   Network:", hre.network.name);
  console.log("");

  const GuarantorRegistry = await hre.ethers.getContractFactory("GuarantorRegistry");
  const guarantorRegistry = GuarantorRegistry.attach(deployment.contracts.GuarantorRegistry);

  const InsurancePool = await hre.ethers.getContractFactory("InsurancePool");
  const insurancePool = InsurancePool.attach(deployment.contracts.InsurancePool);

  const LenderIncentives = await hre.ethers.getContractFactory("LenderIncentives");
  const lenderIncentives = LenderIncentives.attach(deployment.contracts.LenderIncentives);

  const Athenyx = await hre.ethers.getContractFactory("Athenyx");
  const athenyx = Athenyx.attach(deployment.contracts.Athenyx);

  try {
    // ========================================
    // Step 1: Register Participants
    // ========================================
    console.log("📝 [1/6] Registering participants...\n");

    console.log("   Registering Guarantor 1...");
    let tx = await guarantorRegistry.connect(guarantor1).registerGuarantor();
    await tx.wait();
    console.log("   ✅ Guarantor 1 registered");

    console.log("   Registering Guarantor 2...");
    tx = await guarantorRegistry.connect(guarantor2).registerGuarantor();
    await tx.wait();
    console.log("   ✅ Guarantor 2 registered");

    console.log("   Registering Lender...");
    tx = await lenderIncentives.connect(lender).registerLender();
    await tx.wait();
    console.log("   ✅ Lender registered\n");

    // ========================================
    // Step 2: Create Escrow
    // ========================================
    console.log("📦 [2/6] Creating escrow...\n");

    const milestoneAmounts = [
      hre.ethers.parseEther("1"),
      hre.ethers.parseEther("2"),
      hre.ethers.parseEther("3")
    ];

    const futureTime = Math.floor(Date.now() / 1000) + 86400 * 30; // 30 days
    const milestoneDeadlines = [
      futureTime,
      futureTime + 86400 * 30,
      futureTime + 86400 * 60
    ];

    const arbiterFee = hre.ethers.parseEther("0.1");
    const totalAmount = hre.ethers.parseEther("6.1"); // milestones + arbiter fee

    tx = await athenyx.connect(buyer).createEscrow(
      seller.address,
      arbiter.address,
      arbiterFee,
      milestoneAmounts,
      milestoneDeadlines,
      false, // requiresGuarantors
      0,     // minGuarantorCount
      { value: totalAmount }
    );
    const receipt = await tx.wait();
    
    const escrowCreatedEvent = receipt.logs.find(
      log => log.fragment && log.fragment.name === "EscrowCreated"
    );
    const escrowId = escrowCreatedEvent.args[0];

    console.log("   ✅ Escrow created with ID:", escrowId.toString());
    console.log("   Total funded:", hre.ethers.formatEther(totalAmount), "ETH");
    console.log("   Milestones: 3");
    console.log("");

    // ========================================
    // Step 3: Check Escrow Details
    // ========================================
    console.log("🔍 [3/6] Checking escrow details...\n");

    const details = await athenyx.getEscrowDetails(escrowId);
    console.log("   Payers:", details[0].length);
    console.log("   Seller:", details[1]);
    console.log("   Arbiter:", details[2]);
    console.log("   Total Funded:", hre.ethers.formatEther(details[4]), "ETH");
    console.log("   State:", ["PENDING", "ACTIVE", "CANCELLED", "COMPLETED", "DISPUTED"][Number(details[8])]);
    console.log("");

    // ========================================
    // Step 4: Approve Milestone
    // ========================================
    console.log("✅ [4/6] Approving first milestone...\n");

    tx = await athenyx.connect(buyer).approveMilestone(escrowId, 0);
    await tx.wait();
    console.log("   ✅ Milestone 0 approved by buyer\n");

    // ========================================
    // Step 5: Release Milestone
    // ========================================
    console.log("💸 [5/6] Releasing first milestone...\n");

    const sellerBalanceBefore = await hre.ethers.provider.getBalance(seller.address);
    
    tx = await athenyx.connect(seller).releaseMilestone(escrowId, 0);
    await tx.wait();

    const sellerBalanceAfter = await hre.ethers.provider.getBalance(seller.address);
    const received = sellerBalanceAfter - sellerBalanceBefore;

    console.log("   ✅ Milestone 0 released");
    console.log("   Seller received:", hre.ethers.formatEther(received), "ETH\n");

    // ========================================
    // Step 6: Check Pool Stats
    // ========================================
    console.log("📊 [6/6] Checking system stats...\n");

    const poolStats = await insurancePool.getPoolStats();
    console.log("   Insurance Pool:");
    console.log("      Total Collected:", hre.ethers.formatEther(poolStats.totalCollected), "ETH");
    console.log("      Current Balance:", hre.ethers.formatEther(poolStats.currentBalance), "ETH");
    console.log("      Reserve Ratio:  ", poolStats.reserveRatio.toString(), "%");
    console.log("");

    const lenderProfile = await lenderIncentives.getLenderProfile(lender.address);
    console.log("   Lender Profile:");
    console.log("      Total Lent:     ", hre.ethers.formatEther(lenderProfile.totalLent), "ETH");
    console.log("      Active Loans:   ", lenderProfile.activeLoanCount.toString());
    console.log("      Successful:     ", lenderProfile.successfulLoanCount.toString());
    console.log("");

    // ========================================
    // Summary
    // ========================================
    console.log("🎉 ============================================");
    console.log("🎉 Interaction Script Complete!");
    console.log("🎉 ============================================\n");

    console.log("📋 Summary:");
    console.log("   ✅ Participants registered");
    console.log("   ✅ Escrow created (ID:", escrowId.toString() + ")");
    console.log("   ✅ Milestone approved & released");
    console.log("   ✅ System stats retrieved");
    console.log("");

    console.log("🔗 Next Steps:");
    console.log("   - Approve & release remaining milestones");
    console.log("   - Test dispute resolution");
    console.log("   - Test guarantor system with new escrow");
    console.log("");

  } catch (error) {
    console.error("❌ Interaction failed:", error);
    process.exit(1);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });