# VynX V1 - Multi-Strategy DeFi Vault

Risk-tiered yield aggregator built with Solidity 0.8.33 and Foundry. Educational reference implementation showcasing advanced DeFi patterns.

## Overview

VynX V1 is an ERC4626-compliant vault that automatically allocates WETH across multiple lending protocols (Aave v3, Compound v3) to optimize yield through weighted allocation based on APY.

**Key Features:**

- ERC4626 tokenized vault (composable)
- Multi-strategy allocation (Aave + Compound)
- Idle buffer for gas optimization
- Harvest mechanism with performance fees (20%)
- Automatic rebalancing when profitable
- Comprehensive test coverage (90%+)

## Architecture

```
Vault (ERC4626)
  └─> StrategyManager
       ├─> AaveStrategy
       └─> CompoundStrategy
```

## Quick Start

```bash
# Install dependencies
forge install

# Run tests
forge test

# Deploy to Sepolia
forge script script/Deploy.s.sol --rpc-url sepolia --broadcast
```

## Technical Specs

- **Solidity:** 0.8.33
- **Framework:** Foundry
- **Standards:** ERC4626, ERC20
- **Protocols:** Aave v3, Compound v3
- **Network:** Ethereum Sepolia (testnet)

## Testing

```bash
forge test                 # All tests
forge test --gas-report    # Gas report
forge coverage             # Coverage report
```

## Documentation

- [Architecture](docs/ARCHITECTURE.md) - System design
- [Contracts](docs/CONTRACTS.md) - Contract documentation
- [Security](docs/SECURITY.md) - Security considerations

## License

MIT, check license file for more info.
