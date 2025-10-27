import { ethers, EventLog, formatEther, formatUnits, parseEther } from "ethers";
import fs from "fs";
import { task } from "hardhat/config";
import { HardhatRuntimeEnvironment } from "hardhat/types";

type Config = {
  contractAddress: string;
  implAddress: string;
  baseURI: string;
  feeBps: number;
  feeRecipient: string;
  admin: string;
};

const configPath = (hre: HardhatRuntimeEnvironment) => {
  return `Lmsr1155Markets.${hre.network.name}.json`;
};

const getConfig = (hre: HardhatRuntimeEnvironment) => {
  const path = configPath(hre);
  if (!fs.existsSync(path)) return undefined;
  const config = fs.readFileSync(path, "utf8");
  return JSON.parse(config) as Config;
};

const writeConfig = (hre: HardhatRuntimeEnvironment, config: Config) => {
  fs.writeFileSync(configPath(hre), JSON.stringify(config, null, 2));
};

task("Lmsr1155Markets:initFileConfig").setAction(async ({}, hre) => {
  const config = getConfig(hre);
  if (config) {
    console.log(`Config already exists for network: ${hre.network.name}`);
    return;
  }

  const [signer] = await hre.ethers.getSigners();

  writeConfig(hre, {
    contractAddress: "",
    implAddress: "",
    baseURI: "",
    feeBps: 100,
    feeRecipient: signer.address,
    admin: signer.address,
  });
});

task("Lmsr1155Markets:deploy")
  .addFlag("verify", "Verify contracts at Etherscan")
  .setAction(async ({ verify }, hre) => {
    const config = getConfig(hre);
    if (!config) {
      console.error(`Config not found for network: ${hre.network.name}`);
      return;
    }

    const [signer] = await hre.ethers.getSigners();
    if (
      !config.admin ||
      config.admin === "" ||
      config.admin === ethers.ZeroAddress
    ) {
      config.admin = signer.address;
    }

    if (
      !config.feeRecipient ||
      config.feeRecipient === "" ||
      config.feeRecipient === ethers.ZeroAddress
    ) {
      config.feeRecipient = signer.address;
    }

    const contractFactory = await hre.ethers.getContractFactory(
      "Lmsr1155Markets"
    );
    const contract = await hre.upgrades.deployProxy(contractFactory, [
      config.baseURI,
      config.feeBps,
      config.feeRecipient,
      config.admin,
    ]);
    await contract.waitForDeployment();

    config.contractAddress = await contract.getAddress();
    config.implAddress = await hre.upgrades.erc1967.getImplementationAddress(
      config.contractAddress
    );

    writeConfig(hre, config);

    console.log(`Deployed Lmsr1155Markets to ${config.contractAddress}`);
    console.log(`Impl Address: ${config.implAddress}`);

    if (verify) {
      await hre.run("verify:verify", {
        address: config.contractAddress,
        constructorArguments: [],
      });
    }
  });

task("Lmsr1155Markets:setFeeConfig")
  .addParam("feeBps", "Fee in basis points (1e4 = 100%)")
  .addParam("feeRecipient", "Address to receive fees")
  .setAction(async ({ feeBps, feeRecipient }, hre) => {
    const config = getConfig(hre);
    if (!config) {
      console.error(`Config not found for network: ${hre.network.name}`);
      return;
    }

    const contract = await hre.ethers.getContractAt(
      "Lmsr1155Markets",
      config.contractAddress
    );

    const tx = await contract.setFeeConfig(feeBps, feeRecipient);
    await tx.wait();

    config.feeBps = feeBps;
    config.feeRecipient = feeRecipient;
    writeConfig(hre, config);

    console.log(
      `Set fee config to ${feeBps} bps, ${feeRecipient}. Transaction hash: ${tx.hash}`
    );
  });

task("Lmsr1155Markets:pause").setAction(async ({}, hre) => {
  const config = getConfig(hre);
  if (!config) {
    console.error(`Config not found for network: ${hre.network.name}`);
    return;
  }

  const contract = await hre.ethers.getContractAt(
    "Lmsr1155Markets",
    config.contractAddress
  );

  const tx = await contract.pause();
  await tx.wait();

  console.log(`Paused Lmsr1155Markets. Transaction hash: ${tx.hash}`);
});

task("Lmsr1155Markets:unpause").setAction(async ({}, hre) => {
  const config = getConfig(hre);
  if (!config) {
    console.error(`Config not found for network: ${hre.network.name}`);
    return;
  }

  const contract = await hre.ethers.getContractAt(
    "Lmsr1155Markets",
    config.contractAddress
  );

  const tx = await contract.unpause();
  await tx.wait();

  console.log(`Unpaused Lmsr1155Markets. Transaction hash: ${tx.hash}`);
});

task("Lmsr1155Markets:setBaseURI")
  .addParam("baseUri", "Base URI for market metadata")
  .setAction(async ({ baseUri }, hre) => {
    const config = getConfig(hre);
    if (!config) {
      console.error(`Config not found for network: ${hre.network.name}`);
      return;
    }

    const contract = await hre.ethers.getContractAt(
      "Lmsr1155Markets",
      config.contractAddress
    );

    const tx = await contract.setBaseURI(baseUri);
    await tx.wait();

    config.baseURI = baseUri;
    writeConfig(hre, config);

    console.log(`Set base URI to ${baseUri}. Transaction hash: ${tx.hash}`);
  });

task("Lmsr1155Markets:createMarket")
  .addParam("collateral", "Collateral token address")
  .addOptionalParam(
    "bWad",
    "LMSR weight for the market (default: 5e18)",
    "100000000000000000000"
  )
  .addParam("closeTime", "Close time for the market (ISO string)")
  .addParam("oracle", "Oracle address")
  .addParam("metadataUri", "Metadata URI for the market")
  .setAction(
    async ({ collateral, bWad, closeTime, oracle, metadataUri }, hre) => {
      const config = getConfig(hre);
      if (!config) {
        console.error(`Config not found for network: ${hre.network.name}`);
        return;
      }

      const closeTimeConverted = Math.floor(
        new Date(closeTime).getTime() / 1000
      );

      const contract = await hre.ethers.getContractAt(
        "Lmsr1155Markets",
        config.contractAddress
      );

      const tx = await contract.createMarket(
        collateral,
        bWad,
        closeTimeConverted,
        oracle,
        metadataUri
      );
      const receipt = await tx.wait();

      console.log(
        `Created market with collateral ${collateral} and bWad ${bWad}. Transaction hash: ${tx.hash}`
      );

      const marketId = receipt?.logs.find(
        (log): log is EventLog =>
          "fragment" in log && log.fragment?.name === "MarketCreated"
      )?.args?.[0];
      console.log(`Market ID: ${marketId}`);

      const yesId = await contract.yesId(marketId);
      console.log(`Yes ID: ${yesId}`);

      const noId = await contract.noId(marketId);
      console.log(`No ID: ${noId}`);
    }
  );

task("Lmsr1155Markets:marketStatus")
  .addParam("marketId", "Target market identifier")
  .setAction(async ({ marketId }, hre) => {
    const config = getConfig(hre);
    if (!config) {
      console.error(`Config not found for network: ${hre.network.name}`);
      return;
    }

    const contract = await hre.ethers.getContractAt(
      "Lmsr1155Markets",
      config.contractAddress
    );

    const status = await contract.marketStatus(marketId);
    console.log(`Market status:`);
    console.log(`Outcome: ${status.outc}`);
    console.log(`bWad: ${formatEther(status.bWad)}`);
    console.log(`qYesWad: ${formatEther(status.qYesWad)}`);
    console.log(`qNoWad: ${formatEther(status.qNoWad)}`);
    console.log(`Collateral: ${status.collateral}`);
    console.log(
      `Close time: ${new Date(Number(status.closeTime) * 1000).toISOString()}`
    );
    console.log(`Oracle: ${status.oracle}`);

    const priceYes = await contract.priceYes(marketId);
    console.log(`Price YES: ${priceYes}`);

    const priceNo = await contract.priceNo(marketId);
    console.log(`Price NO: ${priceNo}`);
  });

task("Lmsr1155Markets:quoteBuy")
  .addParam("marketId", "Target market identifier")
  .addParam("amount", "Amount of collateral to quote")
  .setAction(async ({ marketId, amount }, hre) => {
    const config = getConfig(hre);
    if (!config) {
      console.error(`Config not found for network: ${hre.network.name}`);
      return;
    }

    const contract = await hre.ethers.getContractAt(
      "Lmsr1155Markets",
      config.contractAddress
    );

    const market = await contract.marketStatus(marketId);
    const marketCollateral = market.collateral;
    const collateral = await hre.ethers.getContractAt(
      "ERC20",
      marketCollateral
    );
    const collateralDecimals = await collateral.decimals();

    const priceYes = await contract.priceYes(marketId);
    console.log(`Price YES: ${formatUnits(priceYes, collateralDecimals)}`);

    const priceNo = await contract.priceNo(marketId);
    console.log(`Price NO: ${formatUnits(priceNo, collateralDecimals)}`);

    const amountBN = parseEther(amount);

    const quoteBuyYes = await contract.quoteBuyYes(marketId, amountBN);
    console.log(
      `Quote for ${amount} of collateral to buy YES: ${formatUnits(
        quoteBuyYes,
        collateralDecimals
      )}`
    );

    const quoteBuyNo = await contract.quoteBuyNo(marketId, amountBN);
    console.log(
      `Quote for ${amount} of collateral to buy NO: ${formatUnits(
        quoteBuyNo,
        collateralDecimals
      )}`
    );

    const quoteBuyYesForCost = await contract.quoteBuyYesForCost(
      marketId,
      quoteBuyYes
    );
    console.log(
      `Cost for ${formatEther(quoteBuyYes)} of YES to buy YES: ${formatUnits(
        quoteBuyYesForCost,
        collateralDecimals
      )}`
    );

    const quoteBuyNoForCost = await contract.quoteBuyNoForCost(
      marketId,
      quoteBuyNo
    );
    console.log(
      `Cost for ${formatEther(quoteBuyNo)} of NO to buy NO: ${formatUnits(
        quoteBuyNoForCost,
        collateralDecimals
      )}`
    );

    const quoteBuyYesWithFee = await contract.quoteBuyYesWithFee(
      marketId,
      amountBN
    );
    console.log(
      `Quote for ${amount} of collateral to buy YES with fee: ${quoteBuyYesWithFee}`
    );

    const quoteBuyNoWithFee = await contract.quoteBuyNoWithFee(
      marketId,
      amountBN
    );
    console.log(
      `Quote for ${amount} of collateral to buy NO with fee: ${quoteBuyNoWithFee}`
    );
  });

task("Lmsr1155Markets:quoteSell")
  .addParam("marketId", "Target market identifier")
  .addParam("amount", "Amount of collateral to quote")
  .setAction(async ({ marketId, amount }, hre) => {
    const config = getConfig(hre);
    if (!config) {
      console.error(`Config not found for network: ${hre.network.name}`);
      return;
    }

    const contract = await hre.ethers.getContractAt(
      "Lmsr1155Markets",
      config.contractAddress
    );

    const priceYes = await contract.priceYes(marketId);
    console.log(`Price YES: ${priceYes}`);

    const priceNo = await contract.priceNo(marketId);
    console.log(`Price NO: ${priceNo}`);

    const quoteSellYes = await contract.quoteSellYes(marketId, amount);
    console.log(`Quote for ${amount} of YES to sell: ${quoteSellYes}`);

    const quoteSellNo = await contract.quoteSellNo(marketId, amount);
    console.log(`Quote for ${amount} of NO to sell: ${quoteSellNo}`);

    const quoteSellYesWithFee = await contract.quoteSellYesWithFee(
      marketId,
      amount
    );
    console.log(
      `Quote for ${amount} of YES to sell with fee: ${quoteSellYesWithFee}`
    );

    const quoteSellNoWithFee = await contract.quoteSellNoWithFee(
      marketId,
      amount
    );
    console.log(
      `Quote for ${amount} of NO to sell with fee: ${quoteSellNoWithFee}`
    );
  });

task("Lmsr1155Markets:buyYes")
  .addParam("marketId", "Target market identifier")
  .addParam("amount", "Amount of collateral to buy YES")
  .addOptionalParam(
    "slippage",
    "Slippage tolerance in basis points (default: 50)"
  )
  .setAction(async ({ marketId, amount, slippage = 50 }, hre) => {
    const config = getConfig(hre);
    if (!config) {
      console.error(`Config not found for network: ${hre.network.name}`);
      return;
    }

    const contract = await hre.ethers.getContractAt(
      "Lmsr1155Markets",
      config.contractAddress
    );

    const market = await contract.marketStatus(marketId);
    const collateralContract = await hre.ethers.getContractAt(
      "IERC20",
      market.collateral
    );

    const amountBN = hre.ethers.parseUnits(amount, 18);
    const [signer] = await hre.ethers.getSigners();

    const quoteBuyYes = await contract.quoteBuyYes(marketId, amountBN);
    console.log(`Quote for ${amount} of collateral to buy YES: ${quoteBuyYes}`);

    const maxCostWad = (quoteBuyYes * BigInt(10000)) / BigInt(10000 - slippage);
    console.log(
      `Max cost for ${amount} of collateral to buy YES: ${maxCostWad}`
    );

    const allowance = await collateralContract.allowance(
      signer.address,
      config.contractAddress
    );
    if (allowance < maxCostWad) {
      const approveTx = await collateralContract.approve(
        config.contractAddress,
        ethers.MaxUint256
      );
      await approveTx.wait();

      console.log(
        `Approved ${config.contractAddress} to spend MaxUint256 of collateral`
      );
    }

    const tx = await contract.buyYes(marketId, amountBN, maxCostWad);
    await tx.wait();

    console.log(
      `Bought YES with ${amount} of collateral. Transaction hash: ${tx.hash}`
    );
  });

task("Lmsr1155Markets:buyNo")
  .addParam("marketId", "Target market identifier")
  .addParam("amount", "Amount of collateral to buy NO")
  .addOptionalParam(
    "slippage",
    "Slippage tolerance in basis points (default: 50)"
  )
  .setAction(async ({ marketId, amount, slippage = 50 }, hre) => {
    const config = getConfig(hre);
    if (!config) {
      console.error(`Config not found for network: ${hre.network.name}`);
      return;
    }

    const contract = await hre.ethers.getContractAt(
      "Lmsr1155Markets",
      config.contractAddress
    );

    const market = await contract.marketStatus(marketId);
    const collateralContract = await hre.ethers.getContractAt(
      "IERC20",
      market.collateral
    );

    const [signer] = await hre.ethers.getSigners();
    const amountBN = hre.ethers.parseUnits(amount, 18);

    const quoteBuyNo = await contract.quoteBuyNo(marketId, amountBN);
    console.log(`Quote for ${amount} of collateral to buy NO: ${quoteBuyNo}`);

    const maxCostWad = (quoteBuyNo * BigInt(10000)) / BigInt(10000 - slippage);
    console.log(
      `Max cost for ${amount} of collateral to buy NO: ${maxCostWad}`
    );

    const allowance = await collateralContract.allowance(
      signer.address,
      config.contractAddress
    );
    if (allowance < maxCostWad) {
      const approveTx = await collateralContract.approve(
        config.contractAddress,
        ethers.MaxUint256
      );
      await approveTx.wait();

      console.log(
        `Approved ${config.contractAddress} to spend MaxUint256 of collateral`
      );
    }

    const tx = await contract.buyNo(marketId, amountBN, maxCostWad);
    await tx.wait();

    console.log(
      `Bought NO with ${amount} of collateral. Transaction hash: ${tx.hash}`
    );
  });

task("Lmsr1155Markets:sellYes")
  .addParam("marketId", "Target market identifier")
  .addParam("amount", "Amount of YES to sell")
  .addOptionalParam(
    "slippage",
    "Slippage tolerance in basis points (default: 50)"
  )
  .setAction(async ({ marketId, amount, slippage = 50 }, hre) => {
    const config = getConfig(hre);
    if (!config) {
      console.error(`Config not found for network: ${hre.network.name}`);
      return;
    }

    const contract = await hre.ethers.getContractAt(
      "Lmsr1155Markets",
      config.contractAddress
    );

    const amountBN = hre.ethers.parseUnits(amount, 18);

    const quoteSellYes = await contract.quoteSellYes(marketId, amountBN);
    console.log(`Quote for ${amount} of YES to sell: ${quoteSellYes}`);

    const minPayoutWad =
      (quoteSellYes * BigInt(10000)) / BigInt(10000 + slippage);
    console.log(`Min payout for ${amount} of YES to sell: ${minPayoutWad}`);

    const tx = await contract.sellYes(marketId, amountBN, minPayoutWad);
    await tx.wait();

    console.log(`Sold YES with ${amount} of YES. Transaction hash: ${tx.hash}`);
  });

task("Lmsr1155Markets:sellNo")
  .addParam("marketId", "Target market identifier")
  .addParam("amount", "Amount of NO to sell")
  .addOptionalParam(
    "slippage",
    "Slippage tolerance in basis points (default: 50)"
  )
  .setAction(async ({ marketId, amount, slippage = 50 }, hre) => {
    const config = getConfig(hre);
    if (!config) {
      console.error(`Config not found for network: ${hre.network.name}`);
      return;
    }

    const contract = await hre.ethers.getContractAt(
      "Lmsr1155Markets",
      config.contractAddress
    );

    const quoteSellNo = await contract.quoteSellNo(marketId, amount);
    console.log(`Quote for ${amount} of NO to sell: ${quoteSellNo}`);

    const minPayoutWad =
      (quoteSellNo * BigInt(10000)) / BigInt(10000 + slippage);
    console.log(`Min payout for ${amount} of NO to sell: ${minPayoutWad}`);

    const amountBN = hre.ethers.parseUnits(amount, 18);

    const tx = await contract.sellNo(marketId, amountBN, minPayoutWad);
    await tx.wait();

    console.log(`Sold NO with ${amount} of NO. Transaction hash: ${tx.hash}`);
  });

task("Lmsr1155Markets:resolve")
  .addParam("marketId", "Target market identifier")
  .addParam("outcome", "Final outcome (1 for YES, 2 for NO, 3 for Invalid)")
  .setAction(async ({ marketId, outcome }, hre) => {
    const config = getConfig(hre);
    if (!config) {
      console.error(`Config not found for network: ${hre.network.name}`);
      return;
    }

    const contract = await hre.ethers.getContractAt(
      "Lmsr1155Markets",
      config.contractAddress
    );

    const tx = await contract.resolve(marketId, outcome);
    await tx.wait();

    console.log(`Resolved market ${marketId}. Transaction hash: ${tx.hash}`);
  });

task("Lmsr1155Markets:redeem")
  .addParam("marketId", "Target market identifier")
  .setAction(async ({ marketId }, hre) => {
    const config = getConfig(hre);
    if (!config) {
      console.error(`Config not found for network: ${hre.network.name}`);
      return;
    }

    const [signer] = await hre.ethers.getSigners();

    const contract = await hre.ethers.getContractAt(
      "Lmsr1155Markets",
      config.contractAddress
    );

    const yesId = await contract.yesId(marketId);
    const yesTokenBal = await contract.balanceOf(signer.address, yesId);
    console.log(`YES token balance: ${yesTokenBal}`);

    const noId = await contract.noId(marketId);
    const noTokenBal = await contract.balanceOf(signer.address, noId);
    console.log(`NO token balance: ${noTokenBal}`);

    const tx = await contract.redeem(marketId);
    await tx.wait();

    console.log(`Redeemed market ${marketId}. Transaction hash: ${tx.hash}`);
  });

task("Lmsr1155Markets:upgrade")
  .addFlag("verify", "Verify contract after upgrade")
  .setAction(async ({ verify }, hre) => {
    const config = getConfig(hre);
    if (!config) {
      console.error(`Config not found for network: ${hre.network.name}`);
      return;
    }

    const contractFactory = await hre.ethers.getContractFactory(
      "Lmsr1155Markets"
    );

    const contract = await hre.upgrades.upgradeProxy(
      config.contractAddress,
      contractFactory
    );
    await contract.waitForDeployment();

    config.implAddress = await hre.upgrades.erc1967.getImplementationAddress(
      config.contractAddress
    );

    writeConfig(hre, config);

    console.log(`Upgraded contract address: ${config.contractAddress}`);
    console.log(`Implementation address: ${config.implAddress}`);

    if (verify) {
      await hre.run("verify:verify", {
        address: config.contractAddress,
        constructorArguments: [],
      });
    }
  });

task("Lmsr1155Markets:verify").setAction(async ({}, hre) => {
  const config = getConfig(hre);
  if (!config) {
    console.error(`Config not found for network: ${hre.network.name}`);
    return;
  }

  await hre.run("verify:verify", {
    address: config.contractAddress,
    constructorArguments: [],
  });
});
