import "dotenv/config";

import "@nomicfoundation/hardhat-ethers";
import "@nomicfoundation/hardhat-toolbox";
import "@openzeppelin/hardhat-upgrades";
import "hardhat-tracer";
import { HardhatUserConfig } from "hardhat/config";

import "./tasks/deploy";

const privateKey: string | undefined = process.env.PRIVATE_KEY;
if (!privateKey) {
  throw new Error("Please set your PRIVATE_KEY in a .env file");
}

const config: HardhatUserConfig = {
  solidity: {
    compilers: [
      {
        version: "0.8.28",
        settings: {
          viaIR: true,
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
    ],
    overrides: {},
  },
  // defaultNetwork: "bscTestnet",
  networks: {
    hardhat: {
      accounts: {
        mnemonic:
          "here is where your twelve words mnemonic should be put my friend",
      },
      chainId: 31337,
    },
    bscTestnet: {
      url:
        process.env.RPC_URL_BSC_TESTNET ||
        "https://data-seed-prebsc-1-s1.binance.org:8545",
      accounts: [`0x${privateKey}`],
    },
    bscMainnet: {
      url:
        process.env.RPC_URL_BSC_MAINNET || "https://bsc-dataseed.binance.org",
      accounts: [`0x${privateKey}`],
    },
    sepolia: {
      url:
        process.env.RPC_URL_SEPOLIA || "https://eth-sepolia.public.blastapi.io",
      accounts: [`0x${privateKey}`],
    },
    baseSepolia: {
      url: process.env.RPC_URL_BASE_SEPOLIA || "https://sepolia.base.org",
      accounts: [`0x${privateKey}`],
    },
    baseMainnet: {
      url: process.env.RPC_URL_BASE_MAINNET || "https://mainnet.base.org",
      accounts: [`0x${privateKey}`],
    },
  },
  typechain: {
    outDir: "typechain",
    target: "ethers-v6",
  },
  etherscan: {
    apiKey: {
      bscTestnet: process.env.ETHERSCAN_API_KEY_BSC_TESTNET ?? "",
      bsc: process.env.ETHERSCAN_API_KEY_BSC_MAINNET ?? "",
      sepolia: process.env.ETHERSCAN_API_KEY_SEPOLIA ?? "",
    }
  },
};

export default config;
