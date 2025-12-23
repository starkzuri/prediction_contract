const {
  RpcProvider,
  Account,
  CallData,
  hash,
  json,
  ETransactionVersion,
} = require("starknet");
const fs = require("fs");
const path = require("path");
const readline = require("readline");
require("dotenv").config();

async function main() {
  console.log("🚀 Starting StarkZuri Ecosystem Deployment...");

  // ================= 1. CONFIGURATION =================
  const nodeUrl =
    process.env.STARKNET_NODE_URL ||
    "https://starknet-sepolia.public.blastapi.io/rpc/v0_7";
  const provider = new RpcProvider({ nodeUrl });

  const accountAddress = process.env.STARKNET_ACCOUNT_ADDRESS;
  if (!accountAddress)
    throw new Error("❌ Missing STARKNET_ACCOUNT_ADDRESS in .env");

  // SECURITY: Prompt for Private Key
  console.log(`👤 Deploying for Account: ${accountAddress}`);

  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });
  const privateKey = await new Promise((resolve) => {
    rl.question("🔐 Enter your Starknet Private Key: ", (answer) => {
      rl.close();
      resolve(answer.trim());
    });
  });

  if (!privateKey) throw new Error("❌ Private Key is required.");
  const account = new Account({
    provider: provider,
    address: accountAddress,
    signer: privateKey,
    cairoVersion: "1",
    transactionVersion: ETransactionVersion.V3,
  });

  // ================= 2. ARTIFACT LOADER =================
  const BASE_PATH = path.resolve(__dirname, "../starkzuri/target/dev");

  function getArtifacts(contractName) {
    const fileName = `starkzuri_${contractName}`;
    const sierraPath = path.join(BASE_PATH, `${fileName}.contract_class.json`);
    const casmPath = path.join(
      BASE_PATH,
      `${fileName}.compiled_contract_class.json`
    );

    if (!fs.existsSync(sierraPath))
      throw new Error(`❌ Artifact not found: ${sierraPath}`);

    return {
      sierra: json.parse(fs.readFileSync(sierraPath).toString("ascii")),
      casm: json.parse(fs.readFileSync(casmPath).toString("ascii")),
    };
  }

  // ================= 3. DECLARE CONTRACTS =================
  async function deployOrGetClassHash(name) {
    const artifacts = getArtifacts(name);
    const classHash = hash.computeContractClassHash(artifacts.sierra);

    try {
      await provider.getClassByHash(classHash);
      console.log(`✅ ${name} already declared: ${classHash}`);
    } catch (e) {
      console.log(`⏳ Declaring ${name}...`);
      const declareTx = await account.declare({
        contract: artifacts.sierra,
        casm: artifacts.casm,
      });
      await provider.waitForTransaction(declareTx.transaction_hash);
      console.log(`🎉 ${name} Declared! Hash: ${classHash}`);
    }
    return { classHash, abi: artifacts.sierra.abi };
  }

  // Load artifacts (Skipping MockERC20 since we use Real ETH now)
  const gameInfo = await deployOrGetClassHash("StarkZuriGamification");
  const profileInfo = await deployOrGetClassHash("StarkZuriProfile");
  const hubInfo = await deployOrGetClassHash("StarkZuriHub");

  // ================= 4. DEPLOYMENT =================

  // --- A. Deploy Gamification ---
  console.log("\n⏳ Deploying Gamification...");
  const gameCallData = new CallData(gameInfo.abi);
  const gameConstructor = gameCallData.compile("constructor", [accountAddress]);

  const gameDeploy = await account.deployContract({
    classHash: gameInfo.classHash,
    constructorCalldata: gameConstructor,
  });
  await provider.waitForTransaction(gameDeploy.transaction_hash);
  const gameAddress = gameDeploy.contract_address;
  console.log(`🎮 Gamification Deployed: ${gameAddress}`);

  // --- B. Deploy Profile ---
  console.log("⏳ Deploying Profile...");
  const profileCallData = new CallData(profileInfo.abi);
  const profileConstructor = profileCallData.compile("constructor", [
    accountAddress,
  ]);

  const profileDeploy = await account.deployContract({
    classHash: profileInfo.classHash,
    constructorCalldata: profileConstructor,
  });
  await provider.waitForTransaction(profileDeploy.transaction_hash);
  const profileAddress = profileDeploy.contract_address;
  console.log(`🆔 Profile Deployed: ${profileAddress}`);

  // --- C. SET TOKEN ADDRESS (THE FIX) ---
  console.log("ℹ️ Using Official Sepolia ETH as Payment Token...");
  // Official Starknet Sepolia ETH Address
  const tokenAddress =
    "0x0512feac6339ff7889822cb5aa2a86c848e9d392bb0e3e237c008674feed8343";

  // --- D. Deploy Hub ---
  console.log("⏳ Deploying Hub...");
  const hubCallData = new CallData(hubInfo.abi);

  // Constructor: [token_address, fee_collector, gamification_contract, profile_contract]
  const hubConstructor = hubCallData.compile("constructor", [
    tokenAddress, // <--- NOW USING REAL ETH
    accountAddress, // Fee Recipient
    gameAddress,
    accountAddress, // (Placeholder for Oracle/Owner if needed)
  ]);

  const hubDeploy = await account.deployContract({
    classHash: hubInfo.classHash,
    constructorCalldata: hubConstructor,
  });
  await provider.waitForTransaction(hubDeploy.transaction_hash);
  const hubAddress = hubDeploy.contract_address;
  console.log(`🏦 Hub Deployed: ${hubAddress}`);

  // ================= 5. POST-DEPLOYMENT SETUP =================
  console.log("\n🔗 Configuring Permissions...");

  const { transaction_hash: authTx } = await account.execute({
    contractAddress: gameAddress,
    entrypoint: "set_controller",
    calldata: CallData.compile([hubAddress, 1]),
  });

  console.log("⏳ Waiting for auth transaction...");
  await provider.waitForTransaction(authTx);
  console.log("✅ Hub authorized to award XP!");

  // ================= 6. SUMMARY =================
  console.log("\n=============================================");
  console.log("       🎉 DEPLOYMENT COMPLETE 🎉");
  console.log("=============================================");
  console.log(`VITE_GAMIFICATION_ADDRESS=${gameAddress}`);
  console.log(`VITE_PROFILE_ADDRESS=${profileAddress}`);
  // Hardcoded Logic: This address is static for Sepolia
  console.log(`VITE_USDC_ADDRESS=${tokenAddress}`);
  console.log(`VITE_HUB_ADDRESS=${hubAddress}`);
  console.log("=============================================");
  console.log("👉 Update your frontend .env file with these VITE_ values!");
}

main().catch((error) => {
  console.error("❌ Fatal Error:", error);
  process.exit(1);
});
