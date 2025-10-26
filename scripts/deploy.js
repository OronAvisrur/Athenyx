const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  console.log("🚀 Starting Athenyx Protocol Deployment...\n");

  const [deployer] = await hre.ethers.getSigners();
  console.log("📝 Deploying contracts with account:", deployer.address);
  console.log("💰 Account balance:", hre.ethers.formatEther(await hre.ethers.provider.getBalance(deployer.address)), "ETH\n");

  const deployedAddresses = {};

  try {
    // ========================================
    // Step 1: Deploy GuarantorRegistry
    // ========================================
    console.log("📦 [1/4] Deploying GuarantorRegistry...");
    const GuarantorRegistry = await hre.ethers.getContractFactory("GuarantorRegistry");
    const guarantorRegistry = await GuarantorRegistry.deploy();
    await guarantorRegistry.waitForDeployment();
    const guarantorRegistryAddress = await guarantorRegistry.getAddress();
    deployedAddresses.GuarantorRegistry = guarantorRegistryAddress;
    console.log("✅ GuarantorRegistry deployed to:", guarantorRegistryAddress);
    console.log("");

    // ========================================
    // Step 2: Deploy InsurancePool
    // ========================================
    console.log("📦 [2/4] Deploying InsurancePool...");
    const treasuryAddress = deployer.address; // Use deployer as treasury for now
    const InsurancePool = await hre.ethers.getContractFactory("InsurancePool");
    const insurancePool = await InsurancePool.deploy(treasuryAddress);
    await insurancePool.waitForDeployment();
    const insurancePoolAddress = await insurancePool.getAddress();
    deployedAddresses.InsurancePool = insurancePoolAddress;
    console.log("✅ InsurancePool deployed to:", insurancePoolAddress);
    console.log("   Treasury address:", treasuryAddress);
    console.log("");

    // ========================================
    // Step 3: Deploy LenderIncentives
    // ========================================
    console.log("📦 [3/4] Deploying LenderIncentives...");
    const LenderIncentives = await hre.ethers.getContractFactory("LenderIncentives");
    const lenderIncentives = await LenderIncentives.deploy();
    await lenderIncentives.waitForDeployment();
    const lenderIncentivesAddress = await lenderIncentives.getAddress();
    deployedAddresses.LenderIncentives = lenderIncentivesAddress;
    console.log("✅ LenderIncentives deployed to:", lenderIncentivesAddress);
    console.log("");

    // ========================================
    // Step 4: Deploy Athenyx Core
    // ========================================
    console.log("📦 [4/4] Deploying Athenyx Core...");
    const Athenyx = await hre.ethers.getContractFactory("Athenyx");
    const athenyx = await Athenyx.deploy(
      guarantorRegistryAddress,
      insurancePoolAddress,
      lenderIncentivesAddress
    );
    await athenyx.waitForDeployment();
    const athenyxAddress = await athenyx.getAddress();
    deployedAddresses.Athenyx = athenyxAddress;
    console.log("✅ Athenyx Core deployed to:", athenyxAddress);
    console.log("");

    // ========================================
    // Step 5: Configure Permissions
    // ========================================
    console.log("⚙️  Configuring contract permissions...\n");

    console.log("   Setting Athenyx Core address in GuarantorRegistry...");
    let tx = await guarantorRegistry.setAthenyxCore(athenyxAddress);
    await tx.wait();
    console.log("   ✅ Done");

    console.log("   Setting Athenyx Core address in InsurancePool...");
    tx = await insurancePool.setAthenyxCore(athenyxAddress);
    await tx.wait();
    console.log("   ✅ Done");

    console.log("   Setting Athenyx Core address in LenderIncentives...");
    tx = await lenderIncentives.setAthenyxCore(athenyxAddress);
    await tx.wait();
    console.log("   ✅ Done");

    console.log("   Setting GuarantorRegistry address in LenderIncentives...");
    tx = await lenderIncentives.setGuarantorRegistry(guarantorRegistryAddress);
    await tx.wait();
    console.log("   ✅ Done\n");

    // ========================================
    // Step 6: Save Deployment Info
    // ========================================
    const deploymentInfo = {
      network: hre.network.name,
      deployer: deployer.address,
      timestamp: new Date().toISOString(),
      contracts: deployedAddresses,
      configuration: {
        treasury: treasuryAddress,
        minimumReputationPrimary: 200,
        minimumReputationSecondary: 100,
        baseInterestRate: "5%",
        insurancePremiumRate: "10%"
      }
    };

    const deploymentsDir = path.join(__dirname, "..", "deployments");
    if (!fs.existsSync(deploymentsDir)) {
      fs.mkdirSync(deploymentsDir);
    }

    const filename = `${hre.network.name}-${Date.now()}.json`;
    const filepath = path.join(deploymentsDir, filename);
    fs.writeFileSync(filepath, JSON.stringify(deploymentInfo, null, 2));

    const latestPath = path.join(deploymentsDir, `${hre.network.name}-latest.json`);
    fs.writeFileSync(latestPath, JSON.stringify(deploymentInfo, null, 2));

    console.log("💾 Deployment info saved to:", filepath);
    console.log("💾 Latest deployment saved to:", latestPath);
    console.log("");

    // ========================================
    // Step 7: Summary
    // ========================================
    console.log("🎉 ============================================");
    console.log("🎉 Athenyx Protocol Deployment Complete!");
    console.log("🎉 ============================================\n");

    console.log("📋 Contract Addresses:");
    console.log("   GuarantorRegistry:", guarantorRegistryAddress);
    console.log("   InsurancePool:    ", insurancePoolAddress);
    console.log("   LenderIncentives: ", lenderIncentivesAddress);
    console.log("   Athenyx Core:     ", athenyxAddress);
    console.log("");

    console.log("🔗 Next Steps:");
    console.log("   1. Verify contracts on block explorer");
    console.log("   2. Run interaction script: npm run interact");
    console.log("   3. Run tests: npm test");
    console.log("");

    console.log("📚 Documentation: https://docs.athenyx.protocol");
    console.log("");

  } catch (error) {
    console.error("❌ Deployment failed:", error);
    process.exit(1);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });