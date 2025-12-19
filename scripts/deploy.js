const {
  RpcProvider,
  Account,
  CallData, // We will use this dynamically now
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
  const nodeUrl = process.env.STARKNET_NODE_URL || "http://localhost:8080/rpc";
  const provider = new RpcProvider({ nodeUrl });

  const accountAddress = process.env.STARKNET_ACCOUNT_ADDRESS;
  if (!accountAddress)
    throw new Error("❌ Missing STARKNET_ACCOUNT_ADDRESS in .env");

  // SECURITY: Prompt for Private Key (No .env storage)
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
  // Helper to Declare or Get Hash
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
    // Return artifacts too, we need the ABI for the fix!
    return { classHash, abi: artifacts.sierra.abi };
  }

  // Load all artifacts and ABIs
  const gameInfo = await deployOrGetClassHash("StarkZuriGamification");
  const profileInfo = await deployOrGetClassHash("StarkZuriProfile");
  const tokenInfo = await deployOrGetClassHash("MockERC20");
  const hubInfo = await deployOrGetClassHash("StarkZuriHub");

  // ================= 4. DEPLOYMENT (THE FIX IS HERE) =================
  // We now use 'new CallData(abi)' so it knows how to handle ByteArrays!

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

  // --- C. Deploy Mock USDC (CRITICAL FIX) ---
  console.log("⏳ Deploying Mock USDC...");
  // FIX: Using ABI-aware CallData handles 'ByteArray' correctly
  const tokenCallData = new CallData(tokenInfo.abi);
  const tokenConstructor = tokenCallData.compile("constructor", {
    name: "Mock USDC",
    symbol: "mUSDC",
    initial_supply: 100000000000000n,
    recipient: accountAddress,
  });

  const tokenDeploy = await account.deployContract({
    classHash: tokenInfo.classHash,
    constructorCalldata: tokenConstructor,
  });
  await provider.waitForTransaction(tokenDeploy.transaction_hash);
  const tokenAddress = tokenDeploy.contract_address;
  console.log(`💵 Mock USDC Deployed: ${tokenAddress}`);

  // --- D. Deploy Hub ---
  console.log("⏳ Deploying Hub...");
  const hubCallData = new CallData(hubInfo.abi);
  const hubConstructor = hubCallData.compile("constructor", [
    tokenAddress,
    accountAddress,
    gameAddress,
    accountAddress,
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
  console.log(`REACT_APP_GAMIFICATION_ADDRESS=${gameAddress}`);
  console.log(`REACT_APP_PROFILE_ADDRESS=${profileAddress}`);
  console.log(`REACT_APP_USDC_ADDRESS=${tokenAddress}`);
  console.log(`REACT_APP_HUB_ADDRESS=${hubAddress}`);
  console.log("=============================================");
}

main().catch((error) => {
  console.error("❌ Fatal Error:", error);
  process.exit(1);
});
