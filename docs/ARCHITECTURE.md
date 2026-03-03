# System Architecture

This document describes the high-level architecture of VynX V1, explaining the contract hierarchy, ownership flow, key design decisions, the multi-token peripheral Router, and how WETH circulates through the system.

## Overview

### What Problem Does It Solve?

Users who want to maximize their yield in DeFi face several challenges:

1. **Complexity**: Managing positions across multiple protocols (Lido, Aave, Curve, Uniswap V3) requires deep technical knowledge
2. **Constant monitoring**: APYs fluctuate and you have to manually rebalance to optimize returns
3. **Gas costs**: Moving funds between protocols is expensive, especially for small holdings
4. **Single protocol risk**: Being 100% in one protocol increases risk
5. **Unharvested rewards**: Protocols like Curve and Aave emit reward tokens that must be claimed, swapped and reinvested manually
6. **Yield stacking**: Strategies like Aave wstETH combine Lido staking + Aave lending but are difficult to manage manually

VynX V1 solves these problems through:

- **Automated aggregation**: Users deposit once and the protocol manages multiple strategies
- **Weighted allocation**: Intelligent distribution based on APY (higher yield = higher percentage)
- **Intelligent rebalancing**: Only executes when the APY difference between strategies exceeds the tier-configured threshold
- **Idle buffer**: Accumulates small deposits to amortize gas across multiple users
- **Diversification**: Spreads risk across strategies with configurable per-tier limits
- **Automated harvesting**: Harvests rewards (CRV, AAVE), swaps to WETH via Uniswap V3, automatic reinvestment
- **Keeper incentive system**: Anyone can execute harvest and receive 1% of the profit as incentive
- **Two risk tiers**: Balanced (conservative) and Aggressive (higher potential yield)

### Risk Tiers

VynX V1 is deployed as **two independent vaults**, each with its own StrategyManager and set of strategies:

| Tier       | Strategies                           | Max Alloc/Strategy    | Min Alloc/Strategy    |
| ---------- | ------------------------------------ | --------------------- | --------------------- |
| Balanced   | LidoStrategy + AaveStrategy + Curve  | 50%                   | 20%                   |
| Aggressive | CurveStrategy + UniswapV3Strategy    | 70%                   | 10%                   |

Each vault has its own `TierConfig` that parameterizes its behavior:

```solidity
struct TierConfig {
    uint256 max_allocation_per_strategy;  // Balanced: 5000 bp | Aggressive: 7000 bp
    uint256 min_allocation_threshold;     // Balanced: 2000 bp | Aggressive: 1000 bp
    uint256 rebalance_threshold;          // Balanced: 200 bp  | Aggressive: 300 bp
    uint256 min_tvl_for_rebalance;        // Balanced: 8 ETH   | Aggressive: 12 ETH
}
```

### High-Level Architecture

```
User (EOA)
    |
    |─── deposit(WETH) / withdraw(WETH) ──────────────────────────┐
    |                                                              |
    | zapDepositETH() / zapDepositERC20()                          |
    | zapWithdrawETH() / zapWithdrawERC20()                        |
    v                                                              |
┌─────────────────────────────────────────────────────┐            |
│              Router (Periphery)                     │            |
│  - Wrap ETH → WETH                                  │            |
│  - Swap ERC20 → WETH (Uniswap V3)                  │            |
│  - Swap WETH → ERC20 (Uniswap V3)                  │            |
│  - Unwrap WETH → ETH                                │            |
│  - Stateless (never retains funds)                  │            |
│  - ReentrancyGuard + slippage protection            │            |
└─────────────────────────────────────────────────────┘            |
    |                                                              |
    | vault.deposit(WETH) / vault.redeem(shares)                   |
    v                                                              v
┌───────────────────────────────────────────────────────────────┐
│                      Vault (ERC4626)                          │
│  - Mints/burns shares (vxWETH)                                │
│  - Configurable idle buffer per tier (8-12 ETH)               │
│  - Performance fee (20% on harvest profits)                   │
│  - Keeper incentive system (1% for ext. keepers)              │
│  - Circuit breakers (max TVL, min deposit)                    │
└───────────────────────────────────────────────────────────────┘
    |                                       |
    | allocate(WETH) / withdrawTo(WETH)     | harvest()
    v                                       v
┌───────────────────────────────────────────────────────────────┐
│                  StrategyManager (Brain)                      │
│  - Calculates weighted allocation based on APY                │
│  - Distributes according to calculated targets                │
│  - Executes profitable rebalances                             │
│  - Withdraws proportionally                                   │
│  - Coordinates fail-safe harvest across all strategies        │
└───────────────────────────────────────────────────────────────┘
    |
    ├── BALANCED TIER ──────────────────────────────────────────┐
    |                                                           |
    v                   v                   v                   |
┌──────────────┐  ┌──────────────┐  ┌──────────────┐           |
│LidoStrategy  │  │AaveStrategy  │  │CurveStrategy │           |
│ APY: 4%      │  │APY: dynamic  │  │ APY: 6%      │           |
│ harvest: 0   │  │(Aave rate)   │  │ harvest: CRV │           |
└──────────────┘  └──────────────┘  └──────────────┘           |
    |                   |                   |                   |
    v                   v                   v                   |
┌──────────────┐  ┌──────────────┐  ┌──────────────┐           |
│  Lido +      │  │  Lido +      │  │ Curve pool   │           |
│  wstETH      │  │  Aave wstETH │  │ + gauge      │           |
└──────────────┘  └──────────────┘  └──────────────┘           |
                                                                |
    ├── AGGRESSIVE TIER ────────────────────────────────────────┘
    |
    v                       v
┌──────────────┐      ┌──────────────────────┐
│CurveStrategy │      │ UniswapV3Strategy    │
│ APY: 6%      │      │ APY: 14% (variable)  │
│ harvest: CRV │      │ harvest: LP fees     │
└──────────────┘      └──────────────────────┘
    |                       |
    v                       v
┌──────────────┐      ┌──────────────────────┐
│ Curve pool   │      │ WETH/USDC pool 0.05% │
│ stETH/ETH    │      │ NFT position ±10%    │
│ + gauge CRV  │      └──────────────────────┘
└──────────────┘
```

## Contract Hierarchy

### 1. Vault.sol (User Layer)

**Responsibilities:**
- ERC4626 interface for users (deposit, withdraw, mint, redeem)
- Idle buffer management (accumulation of WETH pending investment)
- Harvest coordination and performance fee distribution
- Keeper incentive system (official keepers vs external)
- Circuit breakers (max TVL, min deposit)
- Pausable (emergency stop)

**Inherits from:**
- `ERC4626` (OpenZeppelin): Tokenized vault standard
- `ERC20` (OpenZeppelin): Shares token (vxWETH)
- `Ownable` (OpenZeppelin): Admin access control
- `Pausable` (OpenZeppelin): Emergency stop

**Calls:**
- `StrategyManager.allocate()`: When idle buffer reaches threshold
- `StrategyManager.withdrawTo()`: When users withdraw and idle is insufficient
- `StrategyManager.harvest()`: When someone executes harvest()

**Called by:**
- Users (EOAs or contracts): deposit, withdraw, mint, redeem
- Keepers/Anyone: harvest(), allocateIdle()
- Owner: Administrative functions (pause, setters)

### 2. StrategyManager.sol (Logic Layer)

**Responsibilities:**
- Calculate weighted allocation based on strategy APY
- Distribute WETH across strategies according to calculated targets
- Execute rebalances when profitable (configurable threshold)
- Withdraw proportionally from strategies
- Coordinate fail-safe harvest (if one strategy fails, the others continue)

**Inherits from:**
- `Ownable` (OpenZeppelin): Admin access control

**Calls:**
- `IStrategy.deposit()`: For each strategy during allocate
- `IStrategy.withdraw()`: For each strategy during withdrawTo/rebalance
- `IStrategy.harvest()`: For each strategy during harvest (with try-catch)
- `IStrategy.apy()`: To calculate weighted allocation
- `IStrategy.totalAssets()`: To know TVL per strategy

**Called by:**
- `Vault`: allocate(), withdrawTo(), harvest()
- Owner: addStrategy(), removeStrategy()
- Anyone: rebalance() (if it passes the profitability check)

### 3. Router.sol (Peripheral Layer)

**Responsibilities:**
- Multi-token entry point for users who don't have WETH
- Wrap ETH → WETH and deposit in the vault in a single transaction
- Swap ERC20 → WETH via Uniswap V3 and deposit in the vault
- Redeem shares → unwrap WETH → ETH and send to user
- Redeem shares → swap WETH → ERC20 via Uniswap V3 and send to user
- Guarantee stateless design (never retains funds)

**Inherits from:**
- `IRouter`: Router interface (events and functions)
- `ReentrancyGuard` (OpenZeppelin): Reentrancy protection

**Calls:**
- `IERC4626(vault).deposit()`: To deposit WETH in the vault
- `IERC4626(vault).redeem()`: To redeem shares from the vault
- `ISwapRouter(uniswap).exactInputSingle()`: For ERC20 ↔ WETH swaps
- `WETH.deposit()` / `WETH.withdraw()`: For ETH wrap/unwrap

**Called by:**
- Users (EOAs or contracts): zapDepositETH, zapDepositERC20, zapWithdrawETH, zapWithdrawERC20

**Important note**: The Router is a normal user of the Vault — it has no special privileges. Anyone can interact directly with the Vault if they have WETH.

### 4. Strategies (Integration Layer)

All strategies implement `IStrategy` with the same interface: `deposit`, `withdraw`, `harvest`, `totalAssets`, `apy`, `name`, `asset`.

#### LidoStrategy.sol
**Purpose:** Liquid staking with auto-compounding via wstETH.

**Deposit flow:**
```
WETH → unwrap → ETH → Lido.submit() → stETH → wstETH.wrap() → hold wstETH
```

**Withdrawal flow:**
```
wstETH → Uniswap V3 swap (wstETH→WETH, 0.05% fee) → WETH → manager
```

**Harvest:** Always returns 0. The yield is embedded in the wstETH/stETH exchange rate, which grows automatically without needing active harvest.

**APY:** Hardcoded 4% (400 bp). Reflects Lido staking historical APY.

#### AaveStrategy.sol (wstETH)
**Purpose:** Double yield — Lido staking (4%) + Aave lending (~3.5%) on wstETH.

**Deposit flow:**
```
WETH → ETH → Lido → stETH → wstETH.wrap() → Aave.supply(wstETH) → aWstETH
```

**Withdrawal flow:**
```
Aave.withdraw(wstETH) → aWstETH burned → wstETH → unwrap → stETH
→ Curve stETH/ETH.exchange() → ETH → WETH.deposit() → WETH → manager
```

**Harvest:**
```
RewardsController.claimAllRewards([aWstETH]) → AAVE tokens
→ Uniswap exactInputSingle(AAVE→WETH, 0.3% fee) → WETH
→ WETH → ETH → wstETH → Aave.supply() [auto-compound]
→ return profit_weth
```

**APY:** Dynamic — reads `IPool.getReserveData(wstETH).liquidityRate` from Aave v3 and converts from RAY (27 decimals) to basis points.

#### CurveStrategy.sol
**Purpose:** Liquidity in the Curve stETH/ETH pool plus gauge CRV rewards.

**Deposit flow:**
```
WETH → ETH → Lido.submit() → stETH
→ CurvePool.add_liquidity([ETH, stETH]) → LP tokens
→ CurveGauge.deposit(LP) → gauge deposited
```

**Withdrawal flow:**
```
CurveGauge.withdraw(LP) → LP tokens
→ CurvePool.remove_liquidity_one_coin(LP, 0) → ETH
→ WETH.deposit() → WETH → manager
```

**Harvest:**
```
CurveGauge.claim_rewards() → CRV tokens
→ Uniswap exactInputSingle(CRV→WETH, 0.3% fee) → WETH
→ WETH → ETH → stETH → add_liquidity → LP → gauge.deposit() [auto-compound]
→ return profit_weth
```

**APY:** Hardcoded 6% (600 bp). Estimated ~1-2% in trading fees + ~4% in gauge CRV rewards.

#### UniswapV3Strategy.sol
**Purpose:** Concentrated liquidity in the Uniswap V3 WETH/USDC 0.05% pool.

**Deposit flow:**
```
WETH → swap 50% WETH→USDC (Uniswap exactInputSingle, 0.05% fee)
→ if no position: positionManager.mint(tickLower, tickUpper, WETH, USDC) → tokenId saved
→ if existing position: positionManager.increaseLiquidity(tokenId, WETH, USDC)
```

**Withdrawal flow:**
```
positionManager.decreaseLiquidity(tokenId, proportional_liquidity)
→ positionManager.collect(tokenId) → WETH + USDC
→ if liquidity = 0: positionManager.burn(tokenId), token_id = 0
→ swap USDC→WETH (Uniswap exactInputSingle) → everything in WETH
→ WETH → manager
```

**Harvest:**
```
positionManager.collect(tokenId) → WETH + USDC (accumulated fees)
→ swap USDC→WETH → everything in WETH → register as profit
→ swap 50% WETH→USDC → positionManager.increaseLiquidity() [auto-compound]
→ return profit_weth
```

**APY:** Hardcoded 14% (1400 bp). Highly variable depending on pool volume. Historical estimate.

**Note on the NFT position:** The strategy maintains ONE NFT position (`token_id`). The tick range is calculated once in the constructor: current tick ± 960 ticks (≈ ±10% price). If the position is completely emptied, the NFT is burned and `token_id` resets to 0.

## Harvest Flow

Harvest in V1 varies by strategy. The StrategyManager coordinates with fail-safe (try-catch) so that if one strategy fails, the others continue.

```
Keeper / Bot / User
  └─> vault.harvest()
       │
       │ 1. Calls the strategy manager
       └─> manager.harvest()  [fail-safe: try-catch per strategy]
            │
            ├─> lido_strategy.harvest()
            │    └─> return 0  (yield auto-compounded in wstETH exchange rate)
            │
            ├─> aave_strategy.harvest()
            │    └─> rewards_controller.claimAllRewards([aWstETH])
            │    └─> Receives AAVE tokens
            │    └─> uniswap_router.exactInputSingle(AAVE → WETH, 0.3% fee)
            │    └─> WETH → wstETH → aave_pool.supply(wstETH)  [auto-compound]
            │    └─> return profit_aave
            │
            ├─> curve_strategy.harvest()
            │    └─> gauge.claim_rewards()
            │    └─> Receives CRV tokens
            │    └─> uniswap_router.exactInputSingle(CRV → WETH, 0.3% fee)
            │    └─> WETH → ETH → stETH → pool.add_liquidity → gauge  [auto-compound]
            │    └─> return profit_curve
            │
            └─> return total_profit (sum of those that succeeded)
       │
       │ 2. Verifies profit >= min_profit_for_harvest (Balanced: 0.08 ETH, Aggressive: 0.12 ETH)
       │    If not enough → return 0 (no fee distribution)
       │
       │ 3. Pays keeper incentive (only if not official keeper)
       │    keeper_reward = total_profit * 1% = keeper_incentive
       │    Pays from idle_buffer first, withdraws from strategies if not enough
       │
       │ 4. Calculates performance fee on net profit
       │    net_profit = total_profit - keeper_reward
       │    perf_fee = net_profit * 20%
       │
       │ 5. Distributes performance fee
       │    treasury: 80% of perf_fee → receives SHARES (auto-compound)
       │    founder: 20% of perf_fee → receives WETH (liquid)
       │
       │ 6. Updates counters
       │    last_harvest = block.timestamp
       │    total_harvested += total_profit
       │
       └─> emit Harvested(total_profit, perf_fee, timestamp)
```

### Numerical Harvest Example (Balanced Tier)

**State**: TVL = 500 WETH. Lido: 200 WETH, Aave wstETH: 200 WETH, Curve: 100 WETH.

```
1. Lido harvest:
   - return 0 (yield embedded in wstETH exchange rate)
   - profit_lido = 0

2. Aave harvest:
   - Claims 50 accumulated AAVE tokens
   - Swap: 50 AAVE → 2.0 WETH (via Uniswap V3, 0.3% fee)
   - Re-supply: 2.0 WETH → wstETH → Aave Pool
   - profit_aave = 2.0 WETH

3. Curve harvest:
   - Claims 200 accumulated CRV tokens
   - Swap: 200 CRV → 1.5 WETH (via Uniswap V3, 0.3% fee)
   - Reinvests: 1.5 WETH → ETH → stETH → add_liquidity → gauge
   - profit_curve = 1.5 WETH

4. total_profit = 0 + 2.0 + 1.5 = 3.5 WETH
   ✅ 3.5 >= 0.08 ETH (min_profit_for_harvest Balanced) → continues

5. Keeper incentive (caller is external keeper):
   keeper_reward = 3.5 * 100 / 10000 = 0.035 WETH
   → Transferred to keeper

6. Net profit and performance fee:
   net_profit = 3.5 - 0.035 = 3.465 WETH
   perf_fee = 3.465 * 2000 / 10000 = 0.693 WETH

7. Performance fee distribution:
   treasury_amount = 0.693 * 8000 / 10000 = 0.5544 WETH → mints shares
   founder_amount = 0.693 * 2000 / 10000 = 0.1386 WETH → transfers WETH

8. Result:
   - Keeper receives: 0.035 WETH
   - Treasury receives: shares equivalent to 0.5544 WETH (auto-compound)
   - Founder receives: 0.1386 WETH (liquid)
   - Users benefit from the rest of the compounded yield
```

## Ownership Flow

The protocol uses a hierarchical ownership model for granular control:

```
Vault Owner (EOA)
    |
    +--> Vault.pause()                          # Emergency stop (blocks inflows, not outflows)
    +--> Vault.unpause()                        # Resumes normal operations
    +--> Vault.syncIdleBuffer()                 # Reconciles idle_buffer after emergencyExit
    +--> Vault.setPerformanceFee()              # Adjust performance fee
    +--> Vault.setFeeSplit()                    # Adjust treasury/founder split
    +--> Vault.setMinDeposit()                  # Adjust minimum deposit
    +--> Vault.setIdleThreshold()               # Adjust idle threshold
    +--> Vault.setMaxTVL()                      # Adjust circuit breaker
    +--> Vault.setTreasury()                    # Change treasury address
    +--> Vault.setFounder()                     # Change founder address
    +--> Vault.setStrategyManager()             # Change strategy manager
    +--> Vault.setOfficialKeeper()              # Add/remove official keepers
    +--> Vault.setMinProfitForHarvest()         # Adjust min profit for harvest
    +--> Vault.setKeeperIncentive()             # Adjust keeper incentive

Manager Owner (EOA)
    |
    +--> StrategyManager.emergencyExit()        # Drains ALL strategies to vault
    +--> StrategyManager.addStrategy()          # Add new strategies
    +--> StrategyManager.removeStrategy()       # Remove strategies
    +--> StrategyManager.setMaxAllocation()     # Adjust caps
    +--> StrategyManager.setRebalanceThreshold()# Adjust rebalance threshold
    +--> StrategyManager.setMinTVLForRebalance()# Adjust minimum TVL

Vault (Contract)
    |
    +--> StrategyManager.allocate()             # Vault only
    +--> StrategyManager.withdrawTo()           # Vault only
    +--> StrategyManager.harvest()              # Vault only
         (Via onlyVault modifier)

StrategyManager (Contract)
    |
    +--> LidoStrategy.deposit/withdraw/harvest  # Manager only
    +--> AaveStrategy.deposit/withdraw/harvest  # Manager only
    +--> CurveStrategy.deposit/withdraw/harvest # Manager only
    +--> UniswapV3Strategy.deposit/withdraw/harvest # Manager only
         (Via onlyManager modifier)
```

**Key points:**

1. **Vault Owner ≠ Manager Owner**: Can be different EOAs for separation of concerns
2. **Only vault can call manager**: `onlyVault` modifier protects allocate/withdrawTo/harvest
3. **Only manager can call strategies**: `onlyManager` modifier protects deposit/withdraw/harvest
4. **Anyone can execute rebalance**: If it passes the profitability check in `shouldRebalance()`
5. **Anyone can execute harvest**: External keepers receive incentive, official ones don't
6. **Router has no privileges**: The Router is a normal user of the Vault, with no ownership or special permissions

## Call Chain

### Deposit Flow

```
User
  └─> vault.deposit(100 WETH)
       └─> IERC20(weth).transferFrom(user, vault, 100)
       └─> idle_buffer += 100
       └─> _mint(user, shares)
       └─> if (idle_buffer >= idle_threshold [8-12 ETH]):
            └─> _allocateIdle()
                 └─> IERC20(weth).transfer(manager, idle_buffer)
                 └─> manager.allocate(idle_buffer)
                      └─> _calculateTargetAllocation()
                           └─> _computeTargets() // APY-based weighted allocation
                      └─> for each strategy:
                           └─> IERC20(weth).transfer(strategy, target_amount)
                           └─> strategy.deposit(target_amount)
                                └─> LidoStrategy: ETH → wstETH
                                └─> AaveStrategy: ETH → wstETH → Aave.supply()
                                └─> CurveStrategy: ETH → stETH → pool.add_liquidity() → gauge
                                └─> UniswapV3Strategy: swap 50%→USDC → mint/increase position
```

### Withdrawal Flow

```
User
  └─> vault.withdraw(100 WETH)
       └─> shares = previewWithdraw(100)  // Calculates shares to burn
       └─> _burn(user, shares)
       └─> from_idle = min(idle_buffer, 100)
       └─> from_strategies = 100 - from_idle
       └─> if (from_strategies > 0):
            └─> manager.withdrawTo(from_strategies, vault)
                 └─> for each strategy:
                      └─> to_withdraw = (from_strategies * strategy_balance) / total_assets
                      └─> strategy.withdraw(to_withdraw)
                           └─> LidoStrategy: wstETH → swap WETH (Uniswap)
                           └─> AaveStrategy: Aave.withdraw → wstETH → stETH → Curve → ETH → WETH
                           └─> CurveStrategy: gauge.withdraw → pool.remove_liquidity → ETH → WETH
                           └─> UniswapV3Strategy: decreaseLiquidity → collect → swap USDC→WETH
                      └─> IERC20(weth).transfer(strategy → manager)
                 └─> IERC20(weth).transfer(manager → vault)
       └─> Verifies rounding tolerance (< 20 wei difference)
       └─> IERC20(weth).transfer(vault → user)
```

### Rebalance Flow

```
Keeper / Bot / User
  └─> manager.shouldRebalance()
       └─> Verifies >= 2 strategies
       └─> Verifies TVL >= min_tvl_for_rebalance (8 or 12 ETH depending on tier)
       └─> Calculates max_apy and min_apy across strategies
       └─> return (max_apy - min_apy) >= rebalance_threshold (200 or 300 bp depending on tier)
  └─> manager.rebalance()
       └─> _calculateTargetAllocation() // Recalculates fresh targets
       └─> for each strategy:
            └─> current_balance = strategy.totalAssets()
            └─> target_balance = (total_tvl * target) / 10000
            └─> if (current > target): Adds to excess
            └─> if (target > current): Adds to need
       └─> For strategies with excess:
            └─> strategy.withdraw(excess)
       └─> For strategies with need:
            └─> IERC20(weth).transfer(manager → strategy, amount)
            └─> strategy.deposit(amount)
```

## Emergency Exit Flow

When an active exploit or critical bug is detected, the protocol allows draining all strategies and returning funds to the vault.

```
Vault Owner                        Manager Owner
    |                                    |
    | 1. vault.pause()                   |
    |    Blocks: deposit, mint,          |
    |    harvest, allocateIdle           |
    |    Does NOT block: withdraw, redeem|
    |                                    |
    |                                    | 2. manager.emergencyExit()
    |                                    |    For each strategy:
    |                                    |      try strategy.withdraw(all)
    |                                    |        → accumulates rescued
    |                                    |      catch → emit HarvestFailed
    |                                    |    Transfers total_rescued → vault
    |                                    |    emit EmergencyExit(...)
    |                                    |
    | 3. vault.syncIdleBuffer()          |
    |    idle_buffer = WETH.balanceOf(vault)
    |    emit IdleBufferSynced(old, new) |
    |                                    |
    v                                    v
    Vault paused, funds in idle,
    users can withdraw via
    withdraw() / redeem()
```

**Design without deployment script:** The 3 transactions are independent and non-atomic. If the Vault and Manager have different owners, each executes their step. A Foundry script doesn't provide atomicity nor can it sign for two different EOAs, so the sequence is executed manually (cast, Etherscan, or multisig UI).

---

## Key Architectural Decisions

### 1. Why Two Tiers vs One Single Vault?

**Decision**: Deploy two independent vaults (Balanced and Aggressive) instead of a single vault with all strategies.

**Reasons**:
- **Different risk profiles**: Conservative users shouldn't be exposed to UniswapV3 (concentrated IL). Aggressive users don't necessarily want Lido's lower yield
- **Different parameters**: Each tier needs different `idle_threshold`, `rebalance_threshold`, `max_allocation`
- **Operational simplicity**: Each vault is autonomous and independently auditable
- **Trade-off**: The protocol manages two instances instead of one; liquidity is not consolidated

### 2. Why Weighted Allocation vs All-or-Nothing?

**Decision**: Use weighted allocation proportional to APY instead of 100% in the best strategy.

**Reasons**:
- **Risk diversification**: If one strategy has an exploit, we only lose the allocated portion
- **Liquidity**: Some protocols can't absorb all the TVL
- **Trade-off**: Marginal yield is sacrificed for greater security and robustness

### 3. Why Idle Buffer vs Direct Deposit?

**Decision**: Accumulate deposits in a buffer until reaching 8-12 ETH before investing.

**Reasons**:
- **Gas optimization**: One allocate for N users vs N separate allocates
- **Shared cost**: Users share the allocation gas proportionally
- **Efficient withdrawals**: If there's idle, small withdrawals don't touch strategies (massive savings)
- **Trade-off**: WETH in idle buffer doesn't generate yield during accumulation

**Break-even analysis:**
- Allocate cost: ~300k gas × 50 gwei = 0.015 ETH
- If 10 users deposit 0.8 ETH each: 0.015 / 10 = 0.0015 ETH per user
- vs each user paying 0.015 ETH: 90% savings

### 4. Why Does LidoStrategy Harvest Return 0?

**Decision**: Don't implement active harvest in LidoStrategy; yield grows automatically in the wstETH/stETH exchange rate.

**Reasons**:
- **wstETH mechanics**: wstETH is a token with a growing exchange rate — each wstETH is worth more stETH over time. There are no rewards to claim externally
- **Gas efficiency**: No active harvest, no claim or swap transactions
- **Trade-off**: The harvest() function exists for IStrategy compatibility but returns 0. The real yield is captured at withdrawal time (wstETH is converted to WETH at the updated exchange rate)

### 5. Why Does AaveStrategy Deposit wstETH and Not WETH Directly?

**Decision**: Convert WETH → wstETH before depositing in Aave, instead of depositing WETH directly.

**Reasons**:
- **Double yield**: wstETH in Aave generates Lido staking yield (~4%) + Aave lending yield (~3.5%) simultaneously
- **Added complexity**: The withdrawal is more complex (Aave → wstETH → stETH → Curve → ETH → WETH)
- **Trade-off**: Higher total yield in exchange for greater complexity and stacked risk

### 6. Why Variable Keeper Incentive?

**Decision**: Anyone can execute `harvest()` and external keepers receive 1% of the profit as incentive. Official keepers earn nothing.

**Reasons**:
- **Decentralization**: Doesn't depend on a single keeper to execute harvest
- **Economic incentive**: External keepers have an economic reason to monitor and execute
- **Minimum threshold**: `min_profit_for_harvest` (0.08-0.12 ETH) prevents unprofitable harvests
- **Trade-off**: 1% of profit goes to external keepers, but guarantees execution

### 7. Why Does Treasury Receive Shares and Founder Receives WETH?

**Decision**: Asymmetric distribution of the performance fee — treasury in shares, founder in assets.

**Reasons**:
- **Treasury (80% → shares)**: Auto-compound. Shares increase in value with each harvest, generating more compounded yield. Aligns treasury incentives with protocol growth
- **Founder (20% → WETH)**: Immediate liquidity to cover operational costs. The founder needs liquid funds
- **Trade-off**: Treasury shares are illiquid. Founder receives less but in liquid form

### 8. Why Peripheral Router vs Multi-Asset Vault?

**Decision**: Create a separate Router that swaps tokens to WETH before depositing, instead of modifying the Vault to accept multiple assets directly.

**Reasons**:
- **Pure vault**: The Vault remains a standard ERC4626 with a single asset (WETH), easy to audit
- **Separation of concerns**: Swap complexity lives in a separate contract with no custody of funds
- **No additional risk to the Vault**: If the Router has a bug, the Vault and funds are unaffected
- **Composability**: The Router is just another user of the Vault; other contracts can integrate directly
- **Trade-off**: The user pays Uniswap V3 swap slippage (0.05%-1% depending on the pool)

### 9. Why Stateless Router?

**Decision**: The Router never retains funds between transactions. It verifies balance 0 at the end of each operation.

**Reasons**:
- **Security**: If the Router is exploited, there are no funds to steal
- **Simplicity**: No state to manage, no balance invariants to maintain
- **Gas**: No storage writes for balance tracking

**Pattern**:
```solidity
// At the end of each function:
if (IERC20(weth).balanceOf(address(this)) != 0) revert Router__FundsStuck();
```

### 10. Why Single Position in UniswapV3Strategy?

**Decision**: Maintain a single NFT position with a fixed range (±960 ticks ≈ ±10%) instead of multiple ranges.

**Reasons**:
- **Simplicity**: A single tokenId to manage, a single range
- **Gas efficiency**: Each increase/decrease affects one position, not N
- **Trade-off**: If the price exits the ±10% range, the position stops generating fees until it returns. The wide range reduces this risk vs narrower ranges that maximize APY but are more volatile

## WETH Flow

### WETH States in the System

```
0. Router (temporary, stateless)
   └─> ETH received → wrap to WETH → deposit in vault (doesn't retain)
   └─> ERC20 received → swap to WETH (Uniswap V3) → deposit in vault (doesn't retain)
   └─> Shares redeemed → WETH received → unwrap to ETH → send to user
   └─> Shares redeemed → WETH received → swap to ERC20 (Uniswap V3) → send to user

1. User EOA
   └─> WETH in user's wallet

2. Idle Buffer (vault.idle_buffer)
   └─> Physical balance in Vault
   └─> Doesn't generate yield
   └─> Accounting: vault.idle_buffer (state variable)

3. In Manager (temporary)
   └─> Physical balance in StrategyManager (only during allocate/rebalance)
   └─> Immediately transferred to strategies

4. In Strategies
   ├─> LidoStrategy:
   │    └─> Effective balance: wstETH.balanceOf(strategy) × wstETH/ETH exchange rate
   │    └─> Yield: Automatically included in wstETH exchange rate
   │    └─> No external rewards
   │
   ├─> AaveStrategy (wstETH):
   │    └─> Effective balance in Aave Pool as aWstETH
   │    └─> Yield: Lido staking (wstETH exchange rate) + Aave lending (aToken rebase)
   │    └─> Rewards: AAVE tokens (claimed during harvest)
   │
   ├─> CurveStrategy:
   │    └─> Effective balance: LP tokens staked in gauge (virtual price grows with trading fees)
   │    └─> Yield: Pool trading fees (accumulated in virtual price)
   │    └─> Rewards: CRV tokens from gauge (claimed during harvest)
   │
   └─> UniswapV3Strategy:
        └─> Effective balance: WETH-equivalent value of LP position (weth + usdc × price)
        └─> Yield: Trading fees from 0.05% WETH/USDC pool
        └─> Rewards: Fees in WETH and USDC (collected during harvest or withdrawal)

5. Uniswap V3 (temporary, during harvest/withdrawal)
   └─> AAVE/CRV → WETH swap (harvest for AaveStrategy and CurveStrategy)
   └─> wstETH → WETH swap (withdrawal from LidoStrategy)
   └─> USDC → WETH or WETH → USDC (UniswapV3Strategy)

6. Back to User
   └─> WETH in user's wallet (net)
```

### Accounting vs Physical Balance

It's critical to understand that **totalAssets() is accounting, not physical balance**:

```solidity
// Vault.totalAssets()
function totalAssets() public view returns (uint256) {
    return idle_buffer + IStrategyManager(strategy_manager).totalAssets();
}

// StrategyManager.totalAssets()
function totalAssets() public view returns (uint256) {
    uint256 total = 0;
    for (uint256 i = 0; i < strategies.length; i++) {
        total += strategies[i].totalAssets();
    }
    return total;
}

// LidoStrategy.totalAssets() — WETH value of wstETH at current exchange rate
function totalAssets() external view returns (uint256) {
    return IWstETH(wsteth).getStETHByWstETH(wstEthBalance());
}

// AaveStrategy.totalAssets() — aWstETH balance × wstETH exchange rate
function totalAssets() external view returns (uint256) {
    uint256 a_wst_eth_balance = IERC20(a_wst_eth).balanceOf(address(this));
    return IWstETH(wst_eth).getStETHByWstETH(a_wst_eth_balance);
}

// CurveStrategy.totalAssets() — LP × virtual_price (in ETH equivalent)
function totalAssets() external view returns (uint256) {
    uint256 lp = ICurveGauge(gauge).balanceOf(address(this));
    return FullMath.mulDiv(lp, ICurvePool(pool).get_virtual_price(), 1e18);
}

// UniswapV3Strategy.totalAssets() — calculates WETH equivalent of the NFT position
function totalAssets() external view returns (uint256) {
    // Uses LiquidityAmounts + sqrtPriceX96 from pool to calculate WETH + USDC,
    // then converts USDC to WETH using the pool's current price
    return _totalAssets();
}
```

## Known Limitations

1. **WETH only in the Vault**: The Vault natively accepts only WETH. Other tokens require going through the Router
2. **Manual rebalancing**: Requires external keepers (not automatic on-chain)
3. **Weighted allocation v1**: Basic algorithm proportional to APY
4. **Single vault owner**: Centralized ownership (multisig recommended in production)
5. **Idle buffer without yield**: Accumulated WETH doesn't generate yield during the accumulation period
6. **Illiquid treasury shares**: The treasury receives shares that can't be sold easily without diluting holders
7. **Harvest depends on Uniswap liquidity**: If there's no AAVE/WETH or CRV/WETH liquidity, the swap fails (fail-safe: the affected strategy doesn't contribute to profit that harvest)
8. **Max 10 strategies**: Hard-coded limit in StrategyManager to prevent gas DoS in loops
9. **Router depends on Uniswap V3 liquidity**: If there's no pool for a token with WETH, the Router can't operate with that token
10. **UniswapV3 out-of-range**: If the price exits the ±10% range, the position stops generating fees (expected behavior of concentrated Uniswap V3, not verified in tests)
11. **Hardcoded APYs in Lido, Curve and UniswapV3**: Only AaveStrategy reads APY on-chain. Hardcoded APYs in other strategies are historical estimates that may differ from reality

---

**Next reading**: [CONTRACTS.md](CONTRACTS.md) - Detailed documentation per contract
