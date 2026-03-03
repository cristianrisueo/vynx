# VynX Protocol v1

Yield aggregator protocol built with Solidity 0.8.33 and Foundry. Implements an ERC4626 vault that distributes WETH across multiple DeFi strategies (Lido, Aave wstETH, Curve and Uniswap V3) in two independent risk tiers: **Balanced** and **Aggressive**. Includes a peripheral Router that allows depositing and withdrawing with any token (ETH, USDC, DAI, WBTC...) by automatically swapping via Uniswap V3.

## Description

VynX is an automated asset management protocol that allows users to deposit WETH and benefit from intelligent diversification across different DeFi protocols. The system continuously calculates the best distribution ratios based on the APYs offered by each strategy and executes rebalances when they are profitable.

The protocol is deployed in two independent configurations with different risk/yield profiles. Each configuration is an independent ERC4626 vault with its own StrategyManager and its own set of strategies.

The vault implements advanced optimizations such as an idle buffer that accumulates deposits to amortize gas costs, performance fees with treasury/founder split, automatic reward harvesting with swap to WETH via Uniswap V3, and circuit breakers for protocol protection.

The protocol includes a **peripheral Router** that acts as a multi-token entry point. Users can deposit native ETH, USDC, DAI, WBTC or any token with a Uniswap V3/WETH pool, and the Router automatically performs the swap to WETH and deposits into the Vault in a single transaction. The ERC4626 vault stays pure (WETH only) while the Router handles all multi-token complexity.

## Key Features

- **ERC4626 Vault**: Industry standard with tokenized shares (vxWETH)
- **Two Risk Tiers**: Balanced (Lido + Aave wstETH + Curve) and Aggressive (Curve + Uniswap V3)
- **Weighted Allocation**: Intelligent distribution based on each strategy's APY
- **Idle Buffer**: Accumulates deposits up to a configurable threshold to optimize gas
- **Intelligent Rebalancing**: Only executes when the APY difference exceeds the tier-configured threshold
- **Automated Harvesting**: Harvests rewards from each strategy, swaps via Uniswap V3, automatic reinvestment
- **Performance Fees**: 20% on profits, 80/20 split between treasury and founder
- **Keeper System**: Official keepers (no incentive) and external keepers (with WETH incentive)
- **Allocation Limits**: Configurable per tier (max 50-70%, min 10-20% per strategy)
- **Circuit Breakers**: Maximum TVL, minimum deposit
- **Pausable**: Emergency stop (blocks inflows, withdrawals always enabled)
- **Emergency Exit**: Full strategy drainage with fail-safe and accounting reconciliation
- **Battle-Tested Protocol Integrations**: Lido, Aave v3, Curve, Uniswap V3
- **Multi-Token Router**: Deposits and withdrawals with ETH, USDC, DAI, WBTC or any token with a Uniswap V3/WETH pool
- **Zap Deposit/Withdraw**: Swap + deposit or redeem + swap in a single transaction via Router
- **Stateless Router**: The Router never retains funds between transactions (internal balance check)
- **Slippage Protection**: `min_weth_out` / `min_token_out` parameter on all Router functions

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (forge, cast, anvil)
- Solidity 0.8.33
- Git

## Installation

```bash
# Clone the repository
git clone https://github.com/cristianrisueo/vynx.git
cd vynx

# Install dependencies
forge install

# Compile contracts
forge build
```

## Deployment

VynX V1 is deployed and verified on **Ethereum Mainnet**.

### Balanced Tier

| Contract | Address |
|---|---|
| StrategyManager | [`0xA0d462b84C2431463bDACDC2C5bc3172FC927B0B`](https://etherscan.io/address/0xa0d462b84c2431463bdacdc2c5bc3172fc927b0b) |
| Vault (vxWETH) | [`0x9D002dF2A5B632C0D8022a4738C1fa7465d88444`](https://etherscan.io/address/0x9d002df2a5b632c0d8022a4738c1fa7465d88444) |
| LidoStrategy | [`0xf8d1E54A07A47BB03833493EAEB7FE7432B53FCB`](https://etherscan.io/address/0xf8d1e54a07a47bb03833493eaeb7fe7432b53fcb) |
| AaveStrategy | [`0x8135Ed49ffFeEF4a1Bb5909c5bA96EEe9D4ed32A`](https://etherscan.io/address/0x8135ed49fffeef4a1bb5909c5ba96eee9d4ed32a) |
| CurveStrategy | [`0xF0C57C9c1974a14602074D85cfB1Bc251B67Dc00`](https://etherscan.io/address/0xf0c57c9c1974a14602074d85cfb1bc251b67dc00) |
| Router | [`0x3286c0cB7Bbc7DD4cC7C8752E3D65e275E1B1044`](https://etherscan.io/address/0x3286c0cb7bbc7dd4cc7c8752e3d65e275e1b1044) |

### Aggressive Tier

| Contract | Address |
|---|---|
| StrategyManager | [`0xcCa54463BD2aEDF1773E9c3f45c6a954Aa9D9706`](https://etherscan.io/address/0xcca54463bd2aedf1773e9c3f45c6a954aa9d9706) |
| Vault (vxWETH) | [`0xA8cA9d84e35ac8F5af6F1D91fe4bE1C0BAf44296`](https://etherscan.io/address/0xa8ca9d84e35ac8f5af6f1d91fe4be1c0baf44296) |
| CurveStrategy | [`0x312510B911fA47D55c9f1a055B1987D51853A7DE`](https://etherscan.io/address/0x312510b911fa47d55c9f1a055b1987d51853a7de) |
| UniswapV3Strategy | [`0x653D9C2dF3A32B872aEa4E3b4e7436577C5eEB62`](https://etherscan.io/address/0x653d9c2df3a32b872aea4e3b4e7436577c5eeb62) |
| Router | [`0xE898661760299f88e2B271a088987dacB8Fb3dE6`](https://etherscan.io/address/0xe898661760299f88e2b271a088987dacb8fb3de6) |

## Quick Start

### Direct deposit (WETH)

```solidity
// 1. Approve WETH to the vault
IERC20(weth).approve(address(vault), amount);

// 2. Deposit WETH and receive shares
uint256 shares = vault.deposit(amount, msg.sender);

// 3. Withdraw WETH (burns shares)
uint256 assets = vault.withdraw(amount, msg.sender, msg.sender);
```

### Via Router (ETH, USDC, DAI, WBTC...)

```solidity
// Deposit native ETH → receive shares
uint256 shares = router.zapDepositETH{value: msg.value}();

// Deposit USDC → swap to WETH → receive shares
IERC20(usdc).approve(address(router), amount);
uint256 shares = router.zapDepositERC20(usdc, amount, 500, min_weth_out);

// Withdraw shares → receive native ETH
IERC20(vault).approve(address(router), shares);
uint256 eth_out = router.zapWithdrawETH(shares);

// Withdraw shares → receive USDC
IERC20(vault).approve(address(router), shares);
uint256 usdc_out = router.zapWithdrawERC20(shares, usdc, 500, min_usdc_out);
```

## Project Structure

```
vynx/
├── src/
│   ├── core/
│   │   ├── Vault.sol              # ERC4626 vault with idle buffer and fees
│   │   └── StrategyManager.sol    # Allocation and rebalancing engine
│   ├── periphery/
│   │   └── Router.sol             # Multi-token router (ETH/ERC20 → WETH → Vault)
│   ├── strategies/
│   │   ├── LidoStrategy.sol       # Lido staking: WETH → wstETH (auto-compounded yield)
│   │   ├── AaveStrategy.sol       # Aave wstETH: WETH → wstETH → Aave (double yield)
│   │   ├── CurveStrategy.sol      # Curve stETH/ETH LP + gauge CRV rewards
│   │   └── UniswapV3Strategy.sol  # Uniswap V3 WETH/USDC concentrated liquidity ±10%
│   ├── libraries/
│   │   ├── TickMath.sol           # sqrtPrice calculation from ticks
│   │   ├── FullMath.sol           # Multiplications with 512-bit precision
│   │   ├── LiquidityAmounts.sol   # Liquidity ↔ token amount conversion
│   │   └── FixedPoint96.sol       # Q96 constant for Uniswap V3 prices
│   └── interfaces/
│       ├── core/
│       │   ├── IVault.sol         # Vault interface
│       │   └── IStrategyManager.sol # Manager interface
│       ├── strategies/
│       │   ├── IStrategy.sol      # Standard strategy interface
│       │   ├── lido/
│       │   │   ├── ILido.sol      # Lido stETH interface
│       │   │   └── IWstETH.sol    # wstETH interface (wrap/unwrap)
│       │   ├── curve/
│       │   │   ├── ICurvePool.sol # Curve stETH/ETH pool interface
│       │   │   └── ICurveGauge.sol # Curve gauge interface
│       │   └── uniswap/
│       │       └── INonfungiblePositionManager.sol # Uniswap V3 NFT positions interface
│       └── periphery/
│           └── IRouter.sol        # Router interface
├── test/
│   ├── unit/                      # Unit tests per contract
│   ├── integration/               # Protocol E2E tests
│   ├── fuzz/                      # Stateless fuzz tests
│   └── invariant/                 # Stateful invariant tests
├── script/
│   ├── DeployBalanced.s.sol       # Deploy Balanced tier (Lido + Aave + Curve)
│   ├── DeployAggressive.s.sol     # Deploy Aggressive tier (Curve + Uniswap V3)
│   ├── DeployRouters.s.sol        # Deploy peripheral Routers (one per vault)
│   └── run_invariants_offline.sh  # Script to run invariant tests via Anvil
├── lib/                           # Dependencies (OpenZeppelin, Aave, Uniswap, Forge)
├── foundry.toml                   # Foundry configuration
└── README.md                      # This file
```

## Testing

149 tests run against a real Ethereum Mainnet fork (no mocks). Tests cover unit flows, end-to-end integration, stateless fuzz testing, and stateful invariant testing.

```bash
# Set RPC
export MAINNET_RPC_URL="https://eth-mainnet.g.alchemy.com/v2/<API_KEY>"

# Run unit + integration + fuzz (149 tests)
forge test --no-match-path "test/invariant/*" -vv

# Run invariant tests via Anvil (4 invariants)
# Invariant tests generate a high volume of RPC calls.
# The script launches Anvil as a local proxy with controlled rate limiting
./script/run_invariants_offline.sh

# Coverage (excluding invariants)
forge coverage --no-match-path "test/invariant/*" --ir-minimum
```

| Layer       | Tests                  | Files                                                                                                                                                                                                    |
| ----------- | ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Unit        | 145                    | `test/unit/Vault.t.sol`, `test/unit/StrategyManager.t.sol`, `test/unit/LidoStrategy.t.sol`, `test/unit/AaveStrategy.t.sol`, `test/unit/CurveStrategy.t.sol`, `test/unit/UniswapV3Strategy.t.sol`, `test/unit/Router.t.sol` |
| Integration | 10                     | `test/integration/FullFlow.t.sol`                                                                                                                                                                        |
| Fuzz        | 6 (256 runs each)      | `test/fuzz/Fuzz.t.sol`                                                                                                                                                                                   |
| Invariant   | 4 (32 runs x 15 depth) | `test/invariant/Invariants.t.sol`                                                                                                                                                                        |

### Invariant Test Results

The invariant tests run 32 runs with depth 15 (480 total calls) to verify critical protocol properties under random operations. All invariants **PASSED** correctly:

#### `invariant_AccountingIsConsistent()` - Consistent Accounting

Verifies that the sum of assets in strategies + idle buffer == total reported.

#### `invariant_SupplyIsCoherent()` - Coherent Supply

Verifies that totalSupply of shares >= sum of known user balances.

#### `invariant_VaultIsSolvent()` - Vault Solvency

Verifies that the vault can always cover all withdrawals (full solvency, with 1% tolerance for fees).

#### `invariant_RouterAlwaysStateless()` - Stateless Router

Verifies that the Router never retains WETH or ETH between transactions.

**Result**: `4 tests passed, 0 failed, 0 skipped`

### Coverage

| Contract              | Lines      | Statements | Branches   | Functions  |
| --------------------- | ---------- | ---------- | ---------- | ---------- |
| Vault.sol             | 92.51%     | 88.02%     | 55.26%     | 100.00%    |
| StrategyManager.sol   | 81.46%     | 81.27%     | 52.08%     | 100.00%    |
| AaveStrategy.sol      | 71.95%     | 69.89%     | 41.67%     | 91.67%     |
| CurveStrategy.sol     | 95.12%     | 97.09%     | 71.43%     | 100.00%    |
| LidoStrategy.sol      | 90.91%     | 91.30%     | 66.67%     | 90.00%     |
| UniswapV3Strategy.sol | 75.21%     | 75.51%     | 50.00%     | 100.00%    |
| Router.sol            | 98.36%     | 80.95%     | 28.57%     | 100.00%    |
| **Total**             | **85.42%** | **82.83%** | **50.00%** | **98.23%** |

## Environment Variables

Create a `.env` file at the root of the project with the following variables:

| Variable            | Description                                                         |
| ------------------- | ------------------------------------------------------------------- |
| `MAINNET_RPC_URL`   | Ethereum Mainnet RPC (Alchemy, Infura, etc.)                        |
| `PRIVATE_KEY`       | Deployer private key (without `0x` prefix) for `--broadcast`       |
| `ETHERSCAN_API_KEY` | Etherscan API key for contract verification                         |
| `TREASURY_ADDRESS`  | Address that receives 80% of performance fees                       |
| `FOUNDER_ADDRESS`   | Address that receives 20% of performance fees                       |

> **IMPORTANT**: `TREASURY_ADDRESS` and `FOUNDER_ADDRESS` must be set before any mainnet
> broadcast. The deploy scripts will revert with a clear message if either variable
> is missing or is `address(0)`.
> `PRIVATE_KEY` is only required for the broadcast step (`--broadcast`); dry-run
> doesn't need it.

## Deployment

The protocol is deployed in two independent configurations depending on the desired risk profile.
Always follow the two-step process: first a dry-run to verify the simulation,
then the real broadcast only if the dry-run was successful.

### Balanced Tier: Lido + Aave wstETH + Curve

```bash
# Step 1: dry run — verifies everything compiles and simulates correctly
forge script script/DeployBalanced.s.sol \
  --rpc-url $MAINNET_RPC_URL

# Step 2: real broadcast only if dry run was successful
forge script script/DeployBalanced.s.sol \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

### Aggressive Tier: Curve + Uniswap V3

```bash
# Step 1: dry run — verifies everything compiles and simulates correctly
forge script script/DeployAggressive.s.sol \
  --rpc-url $MAINNET_RPC_URL

# Step 2: real broadcast only if dry run was successful
forge script script/DeployAggressive.s.sol \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

## Tier Selection Guide

| Criteria                   | Balanced                          | Aggressive                        |
| -------------------------- | --------------------------------- | --------------------------------- |
| **Strategies**             | Lido + Aave wstETH + Curve        | Curve + Uniswap V3                |
| **Estimated APY**          | 4–7% (conservative)               | 6–14% (variable)                  |
| **Main risk**              | stETH depeg, smart contract risk  | Concentrated IL, out-of-range risk|
| **User profile**           | Long-term, lower volatility       | Higher risk tolerance             |

## Protocol Parameters

### Balanced Tier

| Parameter                     | Value     | Description                                       |
| ----------------------------- | --------- | ------------------------------------------------- |
| `idle_threshold`              | 8 ETH     | Minimum accumulation for auto-allocate            |
| `max_tvl`                     | 1000 ETH  | Maximum allowed TVL (circuit breaker)             |
| `min_profit_for_harvest`      | 0.08 ETH  | Minimum profit to execute harvest                 |
| `performance_fee`             | 20%       | Fee on profits (80% treasury, 20% founder)        |
| `max_allocation_per_strategy` | 50%       | Maximum allocation per strategy                   |
| `min_allocation_threshold`    | 20%       | Minimum allocation per strategy                   |
| `rebalance_threshold`         | 2%        | APY difference to execute rebalance               |
| `min_tvl_for_rebalance`       | 8 ETH     | Minimum TVL required to rebalance                 |

### Aggressive Tier

| Parameter                     | Value     | Description                                       |
| ----------------------------- | --------- | ------------------------------------------------- |
| `idle_threshold`              | 12 ETH    | Minimum accumulation for auto-allocate            |
| `max_tvl`                     | 1000 ETH  | Maximum allowed TVL (circuit breaker)             |
| `min_profit_for_harvest`      | 0.12 ETH  | Minimum profit to execute harvest                 |
| `performance_fee`             | 20%       | Fee on profits (80% treasury, 20% founder)        |
| `max_allocation_per_strategy` | 70%       | Maximum allocation per strategy                   |
| `min_allocation_threshold`    | 10%       | Minimum allocation per strategy                   |
| `rebalance_threshold`         | 3%        | APY difference to execute rebalance               |
| `min_tvl_for_rebalance`       | 12 ETH    | Minimum TVL required to rebalance                 |

## Documentation

- **[ARCHITECTURE.md](docs/ARCHITECTURE.md)** - System design, diagrams and data flows
- **[CONTRACTS.md](docs/CONTRACTS.md)** - Contract specifications, functions and parameters
- **[FLOWS.md](docs/FLOWS.md)** - Detailed operational flows (deposit, withdraw, harvest, rebalance, router)
- **[SECURITY.md](docs/SECURITY.md)** - Security considerations, trust assumptions and limitations
- **[TESTS.md](docs/TESTS.md)** - Test suite, coverage and conventions

## Security & Emergency Procedures

### Withdrawals Always Enabled

Withdrawals (`withdraw`, `redeem`) **are never blocked**, not even when the vault is paused. The pause only blocks new deposits (`deposit`, `mint`), `harvest` and `allocateIdle`. A user can always recover their funds.

### Emergency Exit

If an active exploit or critical bug is detected, the protocol allows draining all strategies and returning funds to the vault:

```solidity
// 1. Pause the vault (blocks new deposits, withdrawals remain enabled)
vault.pause();

// 2. Drain all strategies to the vault (try-catch per strategy)
manager.emergencyExit();

// 3. Reconcile vault accounting
vault.syncIdleBuffer();
```

After this sequence, all funds are in the vault's idle buffer and users can withdraw normally via `withdraw()` or `redeem()`.

**Fail-safe**: If a strategy fails during drainage, the others continue. The problematic strategy is handled separately.

For detailed security documentation, see [SECURITY.md](docs/SECURITY.md).

## Educational Notes

This project is production-grade code built with:

- Production-grade code (CEI pattern, SafeERC20, etc.)
- English comments
- Variables in snake_case (educational style)
- Modular and extensible architecture
- **NOT audited** - Do not use on mainnet with real funds

## Trust Architecture

The protocol trusts:

- **Lido**: Audited and battle-tested liquid staking protocol
- **Aave v3**: Audited and battle-tested lending protocol
- **Curve Finance**: DEX specialized in stablecoins/correlated assets; stETH/ETH pool with historical exploit on gauge (Vyper, July 2023) patched
- **Uniswap V3**: DEX for concentrated liquidity and reward swaps to WETH
- **OpenZeppelin**: Industry standard contracts (ERC4626, Ownable, Pausable, ReentrancyGuard)
- **WETH**: Canonical Ethereum contract for ETH wrap/unwrap

## License

MIT License - See [LICENSE](LICENSE) for more details

## Interactive Documentation

```bash
forge doc --serve --port 4000
```

Generates and serves the project's NatSpec documentation at `http://localhost:4000`.

---

**Author**: @cristianrisueo
**Version**: 1.0.0
**Target Network**: Ethereum Mainnet
**Solidity**: 0.8.33
**Framework**: Foundry
