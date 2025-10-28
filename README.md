# Timeless Market

A decentralized prediction market platform built on Ethereum using Logarithmic Market Scoring Rule (LMSR) automated market maker with ERC1155 outcome shares.

## Deployed Contracts

### BSC Mainnet
- **Lmsr1155Markets**: [`0xe8DcBEefB9C601E10BD77847D45f6EBCcbe9C294`](https://bscscan.com/address/0xe8DcBEefB9C601E10BD77847D45f6EBCcbe9C294)

## Overview

Timeless Market is a multi-market binary prediction platform that allows users to create, trade, and resolve prediction markets. Each market represents a binary outcome (YES/NO) question that can be traded until a specified close time, after which an oracle resolves the market.

### Key Features

- **LMSR AMM**: Uses Logarithmic Market Scoring Rule for automated market making
- **ERC1155 Tokens**: Each market has two token types (YES and NO shares)
- **Multi-Market Support**: Deploy and manage multiple prediction markets
- **Oracle Resolution**: Markets are resolved by designated oracles
- **Fee Management**: Configurable trading fees with designated recipients
- **Upgradeable**: Uses OpenZeppelin's upgradeable proxy pattern

### Contract Architecture

- **Lmsr1155Markets**: Main contract implementing LMSR AMM with ERC1155 outcome shares
- Each market `m` has two ERC1155 token IDs:
  - YES token ID = `marketId << 1 | 1`
  - NO token ID = `marketId << 1 | 0`

## Installation

### Prerequisites

- Node.js (v16 or higher)
- Yarn package manager
- Git

### Setup

1. Clone the repository:
```bash
git clone <repository-url>
cd solidity-contracts
```

2. Install dependencies:
```bash
yarn install
```

3. Create environment file:
```bash
cp .env.example .env
```

4. Configure your `.env` file:
```env
PRIVATE_KEY=your_private_key_here
```

5. Compile contracts:
```bash
npx hardhat compile
```

## Deployment

### 1. Initialize Configuration

First, initialize the configuration file for your target network:

```bash
npx hardhat Lmsr1155Markets:initFileConfig --network <network_name>
```

This creates a configuration file `Lmsr1155Markets.<network_name>.json` with default settings.

### 2. Configure Parameters

Edit the generated configuration file to set:
- `baseURI`: Base URI for market metadata
- `feeBps`: Trading fee in basis points (e.g., 100 = 1%)
- `feeRecipient`: Address to receive trading fees
- `admin`: Admin address for the contract

### 3. Deploy Contract

Deploy the Lmsr1155Markets contract:

```bash
npx hardhat Lmsr1155Markets:deploy --network <network_name>
```

Add `--verify` flag to automatically verify the contract on Etherscan:

```bash
npx hardhat Lmsr1155Markets:deploy --verify --network <network_name>
```

## Usage

### Market Management

#### Create a Market

```bash
npx hardhat Lmsr1155Markets:createMarket \
  --collateral <token_address> \
  --close-time "2024-12-31T23:59:59Z" \
  --oracle <oracle_address> \
  --metadata-uri "metadata.json" \
  --network <network_name>
```

Optional parameters:
- `--b-wad <value>`: LMSR liquidity parameter (default: 100e18)

#### Check Market Status

```bash
npx hardhat Lmsr1155Markets:marketStatus \
  --market-id <market_id> \
  --network <network_name>
```

#### Set Base URI

```bash
npx hardhat Lmsr1155Markets:setBaseURI \
  --base-uri "https://api.example.com/metadata/" \
  --network <network_name>
```

### Trading Operations

#### Get Price Quotes

Quote buying YES/NO shares:
```bash
npx hardhat Lmsr1155Markets:quoteBuy \
  --market-id <market_id> \
  --amount <collateral_amount> \
  --network <network_name>
```

Quote selling YES/NO shares:
```bash
npx hardhat Lmsr1155Markets:quoteSell \
  --market-id <market_id> \
  --amount <collateral_amount> \
  --network <network_name>
```

#### Buy Shares

Buy YES shares:
```bash
npx hardhat Lmsr1155Markets:buyYes \
  --market-id <market_id> \
  --amount <collateral_amount> \
  --slippage <slippage_bps> \
  --network <network_name>
```

Buy NO shares:
```bash
npx hardhat Lmsr1155Markets:buyNo \
  --market-id <market_id> \
  --amount <collateral_amount> \
  --slippage <slippage_bps> \
  --network <network_name>
```

#### Sell Shares

Sell YES shares:
```bash
npx hardhat Lmsr1155Markets:sellYes \
  --market-id <market_id> \
  --amount <shares_amount> \
  --slippage <slippage_bps> \
  --network <network_name>
```

Sell NO shares:
```bash
npx hardhat Lmsr1155Markets:sellNo \
  --market-id <market_id> \
  --amount <shares_amount> \
  --slippage <slippage_bps> \
  --network <network_name>
```

### Market Resolution

#### Resolve Market

Only the designated oracle can resolve a market:

> **Note**: The oracle will fetch data from [Pyth Network Benchmarks](https://benchmarks.pyth.network/) to compare and submit the final result.

```bash
npx hardhat Lmsr1155Markets:resolve \
  --market-id <market_id> \
  --outcome <outcome_value> \
  --network <network_name>
```

Outcome values:
- `1`: YES
- `2`: NO  
- `3`: Invalid

#### Redeem Winnings

After market resolution, users can redeem their winning shares:

```bash
npx hardhat Lmsr1155Markets:redeem \
  --market-id <market_id> \
  --network <network_name>
```

### Administrative Functions

#### Set Fee Configuration

```bash
npx hardhat Lmsr1155Markets:setFeeConfig \
  --fee-bps <fee_basis_points> \
  --fee-recipient <recipient_address> \
  --network <network_name>
```

#### Pause/Unpause Contract

Pause the contract:
```bash
npx hardhat Lmsr1155Markets:pause --network <network_name>
```

Unpause the contract:
```bash
npx hardhat Lmsr1155Markets:unpause --network <network_name>
```

### Contract Maintenance

#### Upgrade Contract

```bash
npx hardhat Lmsr1155Markets:upgrade --network <network_name>
```

Add `--verify` to verify the new implementation:
```bash
npx hardhat Lmsr1155Markets:upgrade --verify --network <network_name>
```

#### Verify Contract

```bash
npx hardhat Lmsr1155Markets:verify --network <network_name>
```

## Configuration Files

After deployment, configuration files are automatically created:
- `Lmsr1155Markets.<network>.json`: Contains deployed contract addresses and configuration

Example configuration:
```json
{
  "contractAddress": "0x...",
  "implAddress": "0x...",
  "baseURI": "https://api.example.com/metadata/",
  "feeBps": 100,
  "feeRecipient": "0x...",
  "admin": "0x..."
}
```

## Security Considerations

- Always verify contract addresses before interacting
- Use appropriate slippage settings for trading
- Ensure oracles are trusted and reliable
- Test thoroughly on testnets before mainnet deployment
- Keep private keys secure and never commit them to version control

## License

MIT License - see LICENSE file for details.

## Support

For questions and support, please refer to the project documentation or create an issue in the repository.
