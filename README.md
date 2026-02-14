# VynX Protocol v1

Yield optimization protocol (yield aggregator) built with Solidity 0.8.33 and Foundry. Implements an ERC4626 vault that distributes WETH across multiple DeFi strategies (Aave v3 and Compound v3) and automatically harvests rewards via Uniswap V3 to maximize compound yield.

## Description

VynX is an automated asset management protocol that allows users to deposit WETH and benefit from intelligent diversification across different lending protocols. The system continuously calculates the best distribution ratios based on the APYs offered by each protocol and executes rebalances when they are profitable (when the profit exceeds 2x the gas cost).

The vault implements advanced optimizations such as an idle buffer that accumulates small deposits to amortize gas costs, withdrawal fees to incentivize long-term holding, performance fees with treasury/founder split, automatic reward harvesting (AAVE, COMP) with swap to WETH via Uniswap V3, and circuit breakers for protocol protection.

## Main Features

- **ERC4626 Vault**: Industry standard with tokenized shares (vynxWETH)
- **Weighted Allocation**: Intelligent distribution based on each strategy's APY
- **Idle Buffer**: Accumulates deposits up to a configurable threshold to optimize gas
- **Intelligent Rebalancing**: Only executes when `profit_semanal > gas_cost x 2`
- **Automated Harvest**: Harvests rewards from Aave/Compound, swaps via Uniswap V3, automatic reinvestment
- **Performance Fees**: 20% on profits, split 80/20 between treasury and founder
- **Keeper System**: Official keepers (no incentive) and external keepers (with WETH incentive)
- **Allocation Limits**: Maximum 50%, minimum 10% per strategy
- **Withdrawal Fee**: Configurable on withdrawals
- **Circuit Breakers**: Maximum TVL, minimum deposit
- **Pausable**: Emergency stop in case of vulnerabilities
- **Integration with Battle-Tested Protocols**: Aave v3, Compound v3, Uniswap V3

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

## Quick Start

```solidity
// 1. Approve WETH to the vault
IERC20(weth).approve(address(vault), amount);

// 2. Deposit WETH and receive shares
uint256 shares = vault.deposit(amount, msg.sender);

// 3. Withdraw WETH (burns shares, pays withdrawal fee)
uint256 assets = vault.withdraw(amount, msg.sender, msg.sender);
```

## Project Structure

```
vynx/
├── src/
│   ├── core/
│   │   ├── Vault.sol              # ERC4626 Vault with idle buffer and fees
│   │   └── StrategyManager.sol    # Allocation and rebalancing engine
│   ├── strategies/
│   │   ├── AaveStrategy.sol       # Aave v3 integration + harvest via Uniswap V3
│   │   └── CompoundStrategy.sol   # Compound v3 integration + harvest via Uniswap V3
│   └── interfaces/
│       ├── core/
│       │   ├── IVault.sol         # Vault interface
│       │   ├── IStrategyManager.sol # Manager interface
│       │   └── IStrategy.sol      # Standard strategy interface
│       └── compound/
│           ├── ICometMarket.sol   # Compound v3 Comet interface
│           └── ICometRewards.sol  # Compound v3 Rewards interface
├── test/
│   ├── unit/                      # Unit tests per contract
│   ├── integration/               # E2E protocol tests
│   ├── fuzz/                      # Stateless fuzz tests
│   └── invariant/                 # Stateful invariant tests
├── script/
│   ├── Deploy.s.sol               # Mainnet deployment script
│   └── run_invariants_offline.sh  # Script to run invariant tests via Anvil
├── lib/                           # Dependencies (OpenZeppelin, Aave, Uniswap, Forge)
├── foundry.toml                   # Foundry configuration
└── README.md                      # This file
```

## Testing

93 tests run against a real Ethereum Mainnet fork (no mocks). The tests cover unit flows, end-to-end integration, stateless fuzz testing, and stateful invariant testing.

```bash
# Set up RPC
export MAINNET_RPC_URL="https://eth-mainnet.g.alchemy.com/v2/<API_KEY>"

# Run unit + integration + fuzz (93 tests)
forge test --no-match-path "test/invariant/*" -vv

# Run invariant tests via Anvil (3 invariants)
# Invariant tests generate a high volume of RPC calls.
# The script launches Anvil as a local proxy with controlled rate limiting
./script/run_invariants_offline.sh

# Coverage (excluding invariants)
forge coverage --no-match-path "test/invariant/*"
```

| Layer | Tests | Files |
|-------|-------|-------|
| Unit | 73 | `test/unit/Vault.t.sol`, `test/unit/StrategyManager.t.sol`, `test/unit/AaveStrategy.t.sol`, `test/unit/CompoundStrategy.t.sol` |
| Integration | 6 | `test/integration/FullFlow.t.sol` |
| Fuzz | 4 (256 runs each) | `test/fuzz/Fuzz.t.sol` |
| Invariant | 3 (32 runs x 15 depth) | `test/invariant/Invariants.t.sol` |

### Invariant Test Results

The invariant tests run 32 runs with depth 15 (480 total calls) to verify critical protocol properties under random operations. All invariants **PASSED** correctly:

#### `invariant_AccountingIsConsistent()` - Consistent Accounting
Verifies that the sum of assets in strategies + idle buffer == total reported.

```
✓ PASSED (runs: 32, calls: 480, reverts: 0)
┌──────────┬──────────┬───────┬─────────┬──────────┐
│ Contract │ Selector │ Calls │ Reverts │ Discards │
├──────────┼──────────┼───────┼─────────┼──────────┤
│ Handler  │ deposit  │ 161   │ 0       │ 0        │
│ Handler  │ harvest  │ 157   │ 0       │ 0        │
│ Handler  │ withdraw │ 162   │ 0       │ 0        │
└──────────┴──────────┴───────┴─────────┴──────────┘
```

#### `invariant_SupplyIsCoherent()` - Coherent Supply
Verifies that totalSupply of shares == sum of user balances.

```
✓ PASSED (runs: 32, calls: 480, reverts: 0)
┌──────────┬──────────┬───────┬─────────┬──────────┐
│ Contract │ Selector │ Calls │ Reverts │ Discards │
├──────────┼──────────┼───────┼─────────┼──────────┤
│ Handler  │ deposit  │ 155   │ 0       │ 0        │
│ Handler  │ harvest  │ 141   │ 0       │ 0        │
│ Handler  │ withdraw │ 184   │ 0       │ 0        │
└──────────┴──────────┴───────┴─────────┴──────────┘
```

#### `invariant_VaultIsSolvent()` - Vault Solvency
Verifies that the vault can always cover all withdrawals (total solvency).

```
✓ PASSED (runs: 32, calls: 480, reverts: 0)
┌──────────┬──────────┬───────┬─────────┬──────────┐
│ Contract │ Selector │ Calls │ Reverts │ Discards │
├──────────┼──────────┼───────┼─────────┼──────────┤
│ Handler  │ deposit  │ 144   │ 0       │ 0        │
│ Handler  │ harvest  │ 177   │ 0       │ 0        │
│ Handler  │ withdraw │ 159   │ 0       │ 0        │
└──────────┴──────────┴───────┴─────────┴──────────┘
```

**Result**: `3 tests passed, 0 failed, 0 skipped` in 86.03s (246.29s CPU time)

### Coverage

| Contract | Lines | Statements | Branches | Functions |
|----------|-------|------------|----------|-----------|
| Vault.sol | 95.32% | 92.98% | 76.67% | 100.00% |
| StrategyManager.sol | 75.57% | 69.53% | 56.41% | 100.00% |
| AaveStrategy.sol | 70.49% | 70.18% | 50.00% | 91.67% |
| CompoundStrategy.sol | 80.70% | 86.00% | 70.00% | 91.67% |
| **Total** | **82.80%** | **79.06%** | **64.04%** | **97.59%** |

## Deployment

The protocol is deployed on Ethereum Mainnet. The script automatically detects the addresses for WETH, Aave v3 Pool, Compound v3 Comet, and Uniswap V3 Router.

```bash
# Set deployer private key
export PRIVATE_KEY="0x..."
export MAINNET_RPC_URL="https://eth-mainnet.g.alchemy.com/v2/<API_KEY>"

# Dry-run (simulates without executing)
forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL -vvv

# Real deploy
forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL --broadcast --verify
```

The deployer is set as owner and fee_receiver. Estimated cost: ~0.012 ETH.

## Documentation

- **[ARCHITECTURE.md](docs/ARCHITECTURE.md)** - System design, diagrams, and data flows
- **[CONTRACTS.md](docs/CONTRACTS.md)** - Contract specifications, functions, and parameters
- **[FLOWS.md](docs/FLOWS.md)** - Detailed operational flows (deposit, withdraw, harvest, rebalance)
- **[SECURITY.md](docs/SECURITY.md)** - Security considerations, trust assumptions, and limitations

## Protocol Parameters

| Parameter | Initial Value | Description |
|-----------|--------------|-------------|
| `idle_threshold` | 10 ETH | Minimum accumulation for auto-allocate |
| `max_tvl` | 1000 ETH | Maximum allowed TVL (circuit breaker) |
| `min_deposit` | 0.01 ETH | Minimum deposit (anti-spam) |
| `withdrawal_fee` | 2% (200 bp) | Fee on withdrawals |
| `performance_fee` | 20% (2000 bp) | Fee on profits (80% treasury, 20% founder) |
| `max_allocation_per_strategy` | 50% (5000 bp) | Maximum allocation per strategy |
| `min_allocation_threshold` | 10% (1000 bp) | Minimum allocation per strategy |
| `gas_cost_multiplier` | 2x (200) | Safety margin for rebalancing |

## Educational Considerations

This project is **educational** and is built with:

- Production-grade code (CEI pattern, SafeERC20, etc.)
- Comments originally written in Spanish, translated to English for this release
- Variables in snake_case (educational style)
- Modular and extensible architecture
- **NOT audited** - Do not use on mainnet with real funds

## Trust Architecture

The protocol relies on:
- **Aave v3**: Audited and battle-tested protocol
- **Compound v3**: Audited and battle-tested protocol
- **Uniswap V3**: DEX for swapping rewards to WETH
- **OpenZeppelin**: Industry standard contracts (ERC4626, Ownable, Pausable)

## License

MIT License - See [LICENSE](LICENSE) for more details

---

**Author**: @cristianrisueo
**Version**: 1.0.0
**Target Network**: Ethereum Mainnet
**Solidity**: 0.8.33
**Framework**: Foundry
