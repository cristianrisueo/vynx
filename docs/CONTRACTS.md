# Contract Documentation

This document provides detailed technical documentation for each contract in the VynX V1 protocol, including state variables, main functions, events, and modifiers.

**Documented contracts:**

- [Vault.sol](#vaultsol) — ERC4626 vault with idle buffer and fees
- [StrategyManager.sol](#strategymanagersol) — Allocation and rebalancing engine
- [LidoStrategy.sol](#lidostrategysol) — Lido staking: WETH → wstETH (auto-compound)
- [AaveStrategy.sol](#aavestrategy-wstethsol) — Double yield: wstETH + Aave lending
- [CurveStrategy.sol](#curvestrategysol) — Curve stETH/ETH LP + gauge CRV
- [UniswapV3Strategy.sol](#uniswapv3strategysol) — Concentrated liquidity WETH/USDC ±10%
- [IStrategy.sol](#istrategysol) — Standard strategy interface
- [Router.sol](#routersol) — Multi-token router (ETH/ERC20 → WETH → Vault)
- [IRouter.sol](#iroutersol) — Router interface

---

## Vault.sol

**Location**: `src/core/Vault.sol`

### Purpose

ERC4626 Vault that acts as the main user interface. Mints tokenized shares (vxWETH) proportional to deposited assets, accumulates WETH in an idle buffer to optimize gas, coordinates reward harvesting with performance fee distribution, and manages the keeper incentive system.

### Inheritance

- `ERC4626` (OpenZeppelin): Standard tokenized vault implementation
- `ERC20` (OpenZeppelin): Shares token (vxWETH, dynamic name: "VynX {SYMBOL} Vault")
- `Ownable` (OpenZeppelin): Administrative access control
- `Pausable` (OpenZeppelin): Emergency stop for deposits/mint/harvest/allocateIdle (withdrawals always enabled)

### Called By

- **Users (EOAs/contracts)**: `deposit()`, `mint()`, `withdraw()`, `redeem()`
- **Keepers/Anyone**: `harvest()`, `allocateIdle()`
- **Owner**: Administrative functions (pause, setters)

### Calls

- **StrategyManager**: `allocate()` when idle buffer reaches threshold, `withdrawTo()` when users withdraw, `harvest()` when someone harvests
- **IERC20(WETH)**: WETH transfers (SafeERC20)

### Key State Variables

```solidity
// Constants
uint256 public constant BASIS_POINTS = 10000;       // 100% = 10000 basis points

// Strategy manager address
address public strategy_manager;                      // Allocation and harvest engine

// Keeper system
mapping(address => bool) public is_official_keeper;    // Official keepers (no incentive)

// Fee recipient addresses
address public treasury_address;                      // Receives 80% perf fee in SHARES
address public founder_address;                       // Receives 20% perf fee in WETH

// Idle buffer state
uint256 public idle_buffer;                           // Accumulated WETH pending investment

// Harvest counters
uint256 public last_harvest;                          // Last harvest timestamp
uint256 public total_harvested;                       // Total gross profit accumulated

// Harvest parameters (configurable per tier)
uint256 public min_profit_for_harvest;               // 0.08 ETH (Balanced) / 0.12 ETH (Aggressive)
uint256 public keeper_incentive = 100;               // 1% (100 bp) of profit for ext. keepers

// Fee parameters
uint256 public performance_fee = 2000;               // 20% (2000 bp) on profits
uint256 public treasury_split = 8000;                // 80% of perf fee → treasury (shares)
uint256 public founder_split = 2000;                 // 20% of perf fee → founder (WETH)

// Circuit breakers (configurable per tier)
uint256 public min_deposit = 0.01 ether;             // Anti-spam, anti-rounding
uint256 public idle_threshold;                       // 8 ETH (Balanced) / 12 ETH (Aggressive)
uint256 public max_tvl = 1000 ether;                 // Maximum allowed TVL
```

### Main Functions

#### deposit(uint256 assets, address receiver) → uint256 shares

Deposits WETH into the vault and mints shares to the user.

**Flow:**

1. Verifies `assets >= min_deposit` (0.01 ETH)
2. Verifies `totalAssets() + assets <= max_tvl` (circuit breaker)
3. Calculates shares using `previewDeposit(assets)` (before changing state)
4. Transfers WETH from the user to the vault (`SafeERC20.safeTransferFrom`)
5. Increments `idle_buffer += assets` (accumulates in buffer)
6. Mints shares to the receiver (`_mint`)
7. If `idle_buffer >= idle_threshold` (8 ETH Balanced / 12 ETH Aggressive), auto-executes `_allocateIdle()`

**Modifiers**: `whenNotPaused`

**Events**: `Deposited(receiver, assets, shares)`

---

#### mint(uint256 shares, address receiver) → uint256 assets

Mints an exact amount of shares by depositing the required assets.

**Flow:**

1. Verifies `shares > 0`
2. Calculates required assets using `previewMint(shares)`
3. Similar to `deposit()` from here on

**Modifiers**: `whenNotPaused`

**Events**: `Deposited(receiver, assets, shares)`

---

#### withdraw(uint256 assets, address receiver, address owner) → uint256 shares

Withdraws an exact amount of WETH by burning the required shares.

**Flow:**

1. Calculates shares to burn using `previewWithdraw(assets)`
2. Verifies allowance if `msg.sender != owner` (`_spendAllowance`)
3. Burns shares from owner (`_burn`) - **CEI pattern**
4. Calculates `from_idle = min(idle_buffer, assets)`
5. Calculates `from_strategies = assets - from_idle`
6. If `from_strategies > 0`, calls `manager.withdrawTo(from_strategies, vault)`
7. Verifies rounding tolerance: `assets - to_transfer < 20 wei`
8. Transfers net `assets` to the `receiver`

**Modifiers**: None (always enabled, even when the vault is paused)

**Events**: `Withdrawn(receiver, assets, shares)`

**Note on rounding**: External protocols (Aave, Curve, Uniswap V3) may round down ~1-2 wei per operation. The vault tolerates up to 20 wei of difference (margin for up to ~10 strategies). If the difference exceeds 20 wei, it reverts with "Excessive rounding" (serious accounting issue).

---

#### redeem(uint256 shares, address receiver, address owner) → uint256 assets

Burns an exact amount of shares and withdraws proportional WETH.

**Flow:**

1. Calculates net assets using `previewRedeem(shares)`
2. Similar to `withdraw()` from here on

**Modifiers**: None (always enabled, even when the vault is paused)

**Events**: `Withdrawn(receiver, assets, shares)`

---

#### harvest() → uint256 profit

Harvests rewards from all strategies and distributes performance fees.

**Preconditions**: Vault not paused. Anyone can call.

**Flow:**

1. Calls `IStrategyManager(strategy_manager).harvest()` → obtains `profit`
2. If `profit < min_profit_for_harvest` (0.08 ETH Balanced / 0.12 ETH Aggressive) → return 0 (does not distribute)
3. If caller is not an official keeper:
   - Calculates `keeper_reward = (profit * keeper_incentive) / BASIS_POINTS`
   - Pays from `idle_buffer` if sufficient, otherwise withdraws from strategies
   - Transfers `keeper_reward` WETH to the caller
4. Calculates `net_profit = profit - keeper_reward`
5. Calculates `perf_fee = (net_profit * performance_fee) / BASIS_POINTS`
6. Distributes fees via `_distributePerformanceFee(perf_fee)`:
   - Treasury: `treasury_amount = (perf_fee * treasury_split) / BP` → mints shares
   - Founder: `founder_amount = (perf_fee * founder_split) / BP` → transfers WETH
7. Updates `last_harvest = block.timestamp`, `total_harvested += profit`

**Modifiers**: `whenNotPaused`

**Events**: `Harvested(profit, perf_fee, timestamp)`, `PerformanceFeeDistributed(treasury_amount, founder_amount)`

**Numerical example:**

```solidity
// profit = 5.5 WETH (from strategy harvest)
// Caller is an external keeper (not official)
//
// keeper_reward = 5.5 * 100 / 10000 = 0.055 WETH → paid to keeper
// net_profit = 5.5 - 0.055 = 5.445 WETH
// perf_fee = 5.445 * 2000 / 10000 = 1.089 WETH
// treasury_amount = 1.089 * 8000 / 10000 = 0.8712 WETH → mints shares to treasury
// founder_amount = 1.089 * 2000 / 10000 = 0.2178 WETH → transfers WETH to founder
```

---

#### totalAssets() → uint256

Calculates the total TVL under the vault's management.

```solidity
function totalAssets() public view returns (uint256) {
    return idle_buffer + IStrategyManager(strategy_manager).totalAssets();
}
```

**Includes:**

- `idle_buffer`: Physical WETH in the vault (pending investment)
- `strategy_manager.totalAssets()`: Sum of WETH across all strategies (includes yield)

---

#### maxDeposit(address) → uint256

Returns the maximum depositable amount before reaching max_tvl. Returns 0 if paused.

```solidity
function maxDeposit(address) public view returns (uint256) {
    if (paused()) return 0;
    uint256 current = totalAssets();
    if (current >= max_tvl) return 0;
    return max_tvl - current;
}
```

---

#### maxMint(address) → uint256

Returns the maximum mintable shares before reaching max_tvl. Returns 0 if paused.

---

### Internal Functions

#### \_allocateIdle()

Transfers the idle buffer to the StrategyManager for investment.

**Flow:**

1. Saves `to_allocate = idle_buffer`
2. Resets `idle_buffer = 0`
3. Transfers WETH to the manager (`safeTransfer`)
4. Calls `manager.allocate(to_allocate)`

**Called from:**

- `deposit()` / `mint()` if `idle_buffer >= idle_threshold`
- `allocateIdle()` (external, anyone can call if idle >= threshold)

---

#### \_withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)

Override of ERC4626.\_withdraw with custom withdrawal logic.

**Flow:**

1. Reduces allowance if `caller != owner`
2. Burns shares from owner (CEI pattern)
3. Calculates `from_idle = min(idle_buffer, assets)`
4. Subtracts `idle_buffer -= from_idle`
5. If `from_strategies > 0`, calls `manager.withdrawTo(from_strategies, vault)`
6. Gets `balance = IERC20(asset).balanceOf(address(this))`
7. Calculates `to_transfer = min(assets, balance)`
8. Verifies rounding: `assets - to_transfer < 20` (reverts if exceeded)
9. Transfers to receiver

---

#### \_distributePerformanceFee(uint256 perf_fee)

Distributes performance fees between treasury and founder.

**Flow:**

1. `treasury_amount = (perf_fee * treasury_split) / BASIS_POINTS`
2. `founder_amount = (perf_fee * founder_split) / BASIS_POINTS`
3. Treasury: converts `treasury_amount` to shares → `_mint(treasury_address, treasury_shares)`
4. Founder: withdraws from idle_buffer or strategies → `safeTransfer(founder_address, founder_amount)`

---

### Administrative Functions

```solidity
// Emergency stop
function pause() external onlyOwner
function unpause() external onlyOwner

// Fee configuration
function setPerformanceFee(uint256 new_fee) external onlyOwner      // Max: 10000 (100%)
function setFeeSplit(uint256 new_treasury, uint256 new_founder) external onlyOwner
    // Requires: new_treasury + new_founder == BASIS_POINTS

// Idle buffer configuration
function setIdleThreshold(uint256 new_threshold) external onlyOwner
function allocateIdle() external whenNotPaused  // Anyone if idle >= threshold

// Circuit breakers
function setMaxTVL(uint256 new_max) external onlyOwner
function setMinDeposit(uint256 new_min) external onlyOwner

// Addresses
function setTreasury(address new_treasury) external onlyOwner       // No address(0)
function setFounder(address new_founder) external onlyOwner         // No address(0)
function setStrategyManager(address new_manager) external onlyOwner // No address(0)

// Keeper system
function setOfficialKeeper(address keeper, bool status) external onlyOwner
function setMinProfitForHarvest(uint256 new_min) external onlyOwner
function setKeeperIncentive(uint256 new_incentive) external onlyOwner

// Emergency exit support
function syncIdleBuffer() external onlyOwner  // Reconciles idle_buffer with real WETH balance
    // Use after manager.emergencyExit() to correct accounting
```

---

#### syncIdleBuffer()

Reconciles `idle_buffer` with the contract's real WETH balance.

**When to use:** After executing `manager.emergencyExit()`, which transfers WETH directly to the vault without going through `deposit()`, leaving `idle_buffer` out of sync.

**Flow:**

1. Saves previous value: `old_buffer = idle_buffer`
2. Reads real balance: `real_balance = IERC20(asset()).balanceOf(address(this))`
3. Updates: `idle_buffer = real_balance`
4. Emits `IdleBufferSynced(old_buffer, real_balance)`

**Modifiers**: `onlyOwner`

**Events**: `IdleBufferSynced(old_buffer, new_buffer)`

**Complete emergency sequence:**

```solidity
vault.pause();             // 1. Blocks new deposits
manager.emergencyExit();   // 2. Drains strategies to vault
vault.syncIdleBuffer();    // 3. Reconciles accounting
```

### Important Events

```solidity
event Deposited(address indexed user, uint256 assets, uint256 shares);
event Withdrawn(address indexed user, uint256 assets, uint256 shares);
event Harvested(uint256 profit, uint256 performance_fee, uint256 timestamp);
event PerformanceFeeDistributed(uint256 treasury_amount, uint256 founder_amount);
event IdleAllocated(uint256 amount);
event StrategyManagerUpdated(address indexed new_manager);
event PerformanceFeeUpdated(uint256 old_fee, uint256 new_fee);
event FeeSplitUpdated(uint256 treasury_split, uint256 founder_split);
event MinDepositUpdated(uint256 old_min, uint256 new_min);
event IdleThresholdUpdated(uint256 old_threshold, uint256 new_threshold);
event MaxTVLUpdated(uint256 old_max, uint256 new_max);
event TreasuryUpdated(address indexed old_treasury, address indexed new_treasury);
event FounderUpdated(address indexed old_founder, address indexed new_founder);
event OfficialKeeperUpdated(address indexed keeper, bool status);
event MinProfitForHarvestUpdated(uint256 old_min, uint256 new_min);
event KeeperIncentiveUpdated(uint256 old_incentive, uint256 new_incentive);
event IdleBufferSynced(uint256 old_buffer, uint256 new_buffer);
```

### Custom Errors

```solidity
error Vault__DepositBelowMinimum();
error Vault__MaxTVLExceeded();
error Vault__InsufficientIdleBuffer();
error Vault__InvalidPerformanceFee();
error Vault__InvalidFeeSplit();
error Vault__InvalidTreasuryAddress();
error Vault__InvalidFounderAddress();
error Vault__InvalidStrategyManagerAddress();
```

---

## StrategyManager.sol

**Location**: `src/core/StrategyManager.sol`

### Purpose

The brain of the protocol — calculates weighted allocation based on APY, distributes assets across strategies, executes profitable rebalances, proportionally withdraws during withdrawals, and coordinates fail-safe harvesting across all strategies.

### Inheritance

- `Ownable` (OpenZeppelin): Administrative access control

### Called By

- **Vault**: `allocate()`, `withdrawTo()`, `harvest()` (modifier `onlyVault`)
- **Owner**: `addStrategy()`, `removeStrategy()`, setters
- **Anyone**: `rebalance()` (if `shouldRebalance()` is true)

### Calls

- **IStrategy**: `deposit()`, `withdraw()`, `harvest()`, `totalAssets()`, `apy()`

### Key State Variables

```solidity
// Constants
uint256 public constant BASIS_POINTS = 10000;               // 100% = 10000 bp
uint256 public constant MAX_STRATEGIES = 10;                 // Prevents gas DoS in loops

// Immutables
address public immutable asset;                              // WETH

// Vault (set via initialize, only once)
address public vault;                                        // Authorized vault

// Available strategies
IStrategy[] public strategies;
mapping(address => bool) public is_strategy;
mapping(IStrategy => uint256) public target_allocation;       // In basis points

// Allocation parameters (configurable per tier)
uint256 public max_allocation_per_strategy;   // 5000 bp Balanced (50%) / 7000 bp Aggressive (70%)
uint256 public min_allocation_threshold;      // 2000 bp Balanced (20%) / 1000 bp Aggressive (10%)

// Rebalancing parameters (configurable per tier)
uint256 public rebalance_threshold;           // 200 bp Balanced (2%) / 300 bp Aggressive (3%)
uint256 public min_tvl_for_rebalance;         // 8 ETH Balanced / 12 ETH Aggressive
```

### Main Functions

#### allocate(uint256 assets)

Distributes WETH across strategies according to target allocation.

**Precondition**: Vault must transfer WETH to the manager before calling.

**Flow:**

1. Verifies `assets > 0` and `strategies.length > 0`
2. Calls `_calculateTargetAllocation()`:
   - Gets APY from each strategy
   - Calculates targets using `_computeTargets()` (weighted allocation)
   - Writes targets to storage: `target_allocation[strategy] = target`
3. For each strategy with `target > 0`:
   - Calculates `amount = (assets * target) / BASIS_POINTS`
   - Transfers `amount` WETH to the strategy
   - Calls `strategy.deposit(amount)`
   - Emits `Allocated(strategy, amount)`

**Modifiers**: `onlyVault`

**Events**: `Allocated(strategy, assets)` for each strategy

**Example (Balanced Tier with 3 strategies):**

```solidity
// If it receives 100 WETH and targets are [3000, 4000, 3000] (30%, 40%, 30%):
// - LidoStrategy receives 30 WETH
// - AaveStrategy receives 40 WETH
// - CurveStrategy receives 30 WETH
```

---

#### withdrawTo(uint256 assets, address receiver)

Withdraws WETH from strategies proportionally and transfers to the receiver.

**Flow:**

1. Verifies `assets > 0`
2. Gets `total_assets = totalAssets()`
3. If `total_assets == 0`, returns (edge case)
4. For each strategy:
   - Gets `strategy_balance = strategy.totalAssets()`
   - If `strategy_balance == 0`, continues
   - Calculates proportional: `to_withdraw = (assets * strategy_balance) / total_assets`
   - Calls `strategy.withdraw(to_withdraw)` → captures `actual_withdrawn`
   - Accumulates `total_withdrawn += actual_withdrawn`
5. Transfers `total_withdrawn` WETH from manager to receiver

**Modifiers**: `onlyVault`

**Note**: Withdraws proportionally to maintain ratios. Does NOT recalculate target allocation (gas savings). Uses `actual_withdrawn` to account for external protocol rounding.

**Example (Balanced Tier with 3 strategies):**

```solidity
// State: Lido 40 WETH, Aave 40 WETH, Curve 20 WETH (total 100 WETH)
// User withdraws 50 WETH
// - From Lido:  50 * 40/100 = 20 WETH
// - From Aave:  50 * 40/100 = 20 WETH
// - From Curve: 50 * 20/100 = 10 WETH
// Result: Lido 20, Aave 20, Curve 10 (maintains 40/40/20 ratios)
```

---

#### harvest() → uint256 total_profit

Harvests rewards from all strategies with fail-safe.

**Flow:**

1. For each strategy:
   - `try strategy.harvest()` → accumulates profit if successful
   - `catch` → emits `HarvestFailed(strategy, reason)` and continues
2. Returns `total_profit` (sum of individual profits)

**Modifiers**: `onlyVault`

**Events**: `Harvested(total_profit)`, `HarvestFailed(strategy, reason)` if any fail

**Note**: The fail-safe is critical — if CurveStrategy harvest fails due to lack of rewards, LidoStrategy and AaveStrategy continue normally. LidoStrategy always returns 0 from harvest (no active harvesting).

---

#### rebalance()

Adjusts each strategy to its target allocation by moving only the necessary deltas.

**Precondition**: `shouldRebalance()` must be true (reverts otherwise).

**Flow:**

1. Verifies profitability with `shouldRebalance()`
2. Recalculates fresh targets: `_calculateTargetAllocation()`
3. Gets `total_tvl = totalAssets()`
4. For each strategy:
   - Calculates `current_balance = strategy.totalAssets()`
   - Calculates `target_balance = (total_tvl * target) / BASIS_POINTS`
   - If `current > target`: adds to excess array
   - If `target > current`: adds to need array
5. For each strategy with excess:
   - Withdraws excess: `strategy.withdraw(excess)`
6. For each strategy with need:
   - Calculates `to_transfer = min(available, needed)`
   - Transfers WETH to destination strategy
   - Deposits: `strategy.deposit(to_transfer)`
   - Emits `Rebalanced(from_strategy, to_strategy, amount)`

**Modifiers**: None (public)

**Events**: `Rebalanced(from_strategy, to_strategy, assets)`

**Example (Aggressive Tier: Curve 6% vs UniswapV3 14%):**

```solidity
// Current state: Curve 50 WETH (6% APY), UniswapV3 50 WETH (14% APY)
// Recalculated targets: Curve ~30% (30 WETH), UniswapV3 ~70% (70 WETH)
// Rebalance:
//   1. Withdraws 20 WETH from CurveStrategy
//   2. Deposits 20 WETH into UniswapV3Strategy
// Final state: Curve 30 WETH, UniswapV3 70 WETH
// (APY difference: 14-6 = 8% >= 3% threshold → valid rebalance)
```

---

#### shouldRebalance() → bool

Verifies whether a rebalance is profitable by comparing the APY difference between strategies.

**Flow:**

1. Verifies `strategies.length >= 2`
2. Verifies `totalAssets() >= min_tvl_for_rebalance` (10 ETH)
3. Calculates `max_apy` and `min_apy` across all strategies
4. Returns `(max_apy - min_apy) >= rebalance_threshold` (200 bp = 2%)

**Note**: It is a `view` function (does not modify state), can be called by bots/frontends.

**Calculation example (Aggressive Tier):**

```solidity
// Curve APY: 6% (600 bp), UniswapV3 APY: 14% (1400 bp)
// Difference: 1400 - 600 = 800 bp
// Aggressive Threshold: 300 bp
// 800 >= 300 → ✅ shouldRebalance = true
```

---

### Strategy Management Functions

#### addStrategy(address strategy)

Adds a new strategy to the manager.

**Flow:**

1. Verifies strategy does not already exist (`!is_strategy[strategy]`)
2. Verifies `strategies.length < MAX_STRATEGIES` (max 10)
3. Verifies `strategy.asset() == asset` (same underlying)
4. Adds to array: `strategies.push(IStrategy(strategy))`
5. Marks as existing: `is_strategy[strategy] = true`
6. Recalculates target allocations: `_calculateTargetAllocation()`

**Modifiers**: `onlyOwner`

**Events**: `StrategyAdded(strategy)`, `TargetAllocationUpdated()`

---

#### removeStrategy(uint256 index)

Removes a strategy from the manager by index.

**Precondition**: Strategy must have a zero balance before removal.

**Flow:**

1. Verifies that strategy at `index` has `totalAssets() == 0`
2. Deletes target: `delete target_allocation[strategies[index]]`
3. Swap & pop: `strategies[index] = strategies[length-1]; strategies.pop()`
4. Marks as non-existent: `is_strategy[strategy] = false`
5. Recalculates targets for remaining strategies

**Modifiers**: `onlyOwner`

**Events**: `StrategyRemoved(strategy)`, `TargetAllocationUpdated()`

---

#### emergencyExit()

Drains all active strategies and transfers assets to the vault in case of emergency.

**Precondition**: Only callable by the manager owner. No timelock.

**Flow:**

1. Initializes accumulators: `total_rescued = 0`, `strategies_drained = 0`
2. For each active strategy:
   - Gets `strategy_balance = strategy.totalAssets()`
   - If `strategy_balance == 0`, skips (continue)
   - `try strategy.withdraw(strategy_balance)`:
     - If successful: `total_rescued += actual_withdrawn`, `strategies_drained++`
     - If it fails: emits `HarvestFailed(strategy, reason)` and continues
3. If `total_rescued > 0`: transfers all rescued WETH to the vault in a single transfer
4. Emits `EmergencyExit(block.timestamp, total_rescued, strategies_drained)`

**Modifiers**: `onlyOwner`

**Events**: `EmergencyExit(timestamp, total_rescued, strategies_drained)`, `HarvestFailed(strategy, reason)` if any strategy fails

**Note on fail-safe:** Uses the same try-catch pattern as `harvest()` — if a strategy is buggy or frozen, the others drain correctly. The problematic strategy is handled manually separately.

**Note on dust:** After draining, strategies may retain 1-2 wei of dust from rounding in conversions (e.g.: wstETH/stETH). This is expected and does not represent a loss of funds.

**Mandatory post-exit sequence:**

```solidity
vault.pause();             // 1. Stops new deposits
manager.emergencyExit();   // 2. Drains strategies
vault.syncIdleBuffer();    // 3. Reconciles idle_buffer with real balance
```

---

### Internal Functions

#### \_computeTargets() → uint256[]

Calculates allocation targets based on APY with caps.

**Algorithm:**

1. If no strategies: returns empty array
2. Sums APYs of all strategies: `total_apy`
3. If `total_apy == 0`: distributes equally (`BASIS_POINTS / strategies.length`)
4. For each strategy:
   - Calculates uncapped target: `uncapped = (apy * BASIS_POINTS) / total_apy`
   - Applies limits:
     - If `uncapped > max_allocation`: target = max (50%)
     - If `uncapped < min_threshold`: target = 0 (10%)
     - Otherwise: target = uncapped
5. Normalizes so they sum to 10000:
   - Sums all targets
   - If they don't sum to 10000: `target[i] = (target[i] * BASIS_POINTS) / total_targets`
6. Returns array of targets

**Used by**: `_calculateTargetAllocation()` (writes to storage), `shouldRebalance()` does not use it directly (compares APYs)

---

#### \_calculateTargetAllocation()

Calculates targets and writes to storage.

**Flow:**

1. If no strategies: returns
2. Calls `_computeTargets()` to get targets array
3. Writes to storage: `target_allocation[strategies[i]] = computed[i]`
4. Emits `TargetAllocationUpdated()`

---

### Initialization

```solidity
// Constructor: receives asset and TierConfig
constructor(address _asset, TierConfig memory tier_config)
    // tier_config.max_allocation_per_strategy: 5000 (Balanced) / 7000 (Aggressive)
    // tier_config.min_allocation_threshold: 2000 (Balanced) / 1000 (Aggressive)
    // tier_config.rebalance_threshold: 200 (Balanced) / 300 (Aggressive)
    // tier_config.min_tvl_for_rebalance: 8 ETH (Balanced) / 12 ETH (Aggressive)

// initialize: resolves circular dependency vault ↔ manager
function initialize(address _vault) external onlyOwner
    // Can only be called once (reverts if vault != address(0))
```

### Query Functions

```solidity
function totalAssets() public view returns (uint256)
    // Sum of assets across all strategies

function strategiesCount() external view returns (uint256)
    // Number of available strategies

function getAllStrategiesInfo() external view returns (
    string[] memory names,
    uint256[] memory apys,
    uint256[] memory tvls,
    uint256[] memory targets
)
    // Complete information for all strategies
    // ⚠️ Gas intensive (~1M gas), for off-chain queries only
```

### Administrative Setters

```solidity
function setRebalanceThreshold(uint256 new_threshold) external onlyOwner
function setMinTVLForRebalance(uint256 new_min_tvl) external onlyOwner
function setMaxAllocationPerStrategy(uint256 new_max) external onlyOwner
    // Recalculates targets afterwards
function setMinAllocationThreshold(uint256 new_min) external onlyOwner
    // Recalculates targets afterwards
```

### Important Events

```solidity
event Allocated(address indexed strategy, uint256 assets);
event Rebalanced(address indexed from_strategy, address indexed to_strategy, uint256 assets);
event Harvested(uint256 total_profit);
event StrategyAdded(address indexed strategy);
event StrategyRemoved(address indexed strategy);
event TargetAllocationUpdated();
event HarvestFailed(address indexed strategy, string reason);
event Initialized(address indexed vault);
event EmergencyExit(uint256 timestamp, uint256 total_rescued, uint256 strategies_drained);
```

### Modifiers

```solidity
modifier onlyVault() {
    if (msg.sender != vault) revert StrategyManager__OnlyVault();
    _;
}
```

### Custom Errors

```solidity
error StrategyManager__NoStrategiesAvailable();
error StrategyManager__StrategyAlreadyExists();
error StrategyManager__StrategyNotFound();
error StrategyManager__StrategyHasAssets();
error StrategyManager__RebalanceNotProfitable();
error StrategyManager__ZeroAmount();
error StrategyManager__OnlyVault();
error StrategyManager__VaultAlreadyInitialized();
error StrategyManager__AssetMismatch();
error StrategyManager__InvalidVaultAddress();
```

---

## LidoStrategy.sol

**Location**: `src/strategies/LidoStrategy.sol`

### Purpose

Liquid staking with auto-compounding via wstETH. Deposits WETH into Lido to obtain stETH and wraps it into wstETH. Yield grows automatically in the wstETH/stETH exchange rate without the need for active harvesting. Estimated APY: **4% (400 bp)**.

### Tier

Available in: **Balanced**

### Implements

- `IStrategy`: Standard strategy interface

### Called By

- **StrategyManager**: `deposit()`, `withdraw()`, `harvest()`, `totalAssets()`, `apy()`

### Calls

- **IWETH**: `withdraw()` — unwrap WETH to ETH to send to Lido
- **ILido**: `receive()` — sends ETH, receives stETH (submit via `receive()`)
- **IWstETH**: `wrap(stETH)` — converts stETH to wstETH; `getStETHByWstETH()` — current price
- **ISwapRouter (Uniswap V3)**: `exactInputSingle()` — swap wstETH → WETH during withdraw

### State Variables

```solidity
// Immutables
address public immutable manager;            // Authorized StrategyManager
address private immutable asset_address;     // WETH
address private immutable wsteth;            // wstETH token
address private immutable lido;              // Lido stETH contract
ISwapRouter private immutable swap_router;   // Uniswap V3 Router

// Hardcoded APY
uint256 private constant LIDO_APY = 400;     // 4% (400 bp)
```

### Main Functions

#### deposit(uint256 assets) → uint256 shares

Converts WETH to wstETH via Lido and retains it.

**Precondition**: WETH must be in the strategy (transferred by manager).

**Flow:**

1. `IWETH(asset_address).withdraw(assets)` — unwrap WETH to ETH
2. `ILido(lido).receive{value: assets}()` — submit ETH to Lido → receives stETH
3. `IWstETH(wsteth).wrap(steth_balance)` — converts stETH to wstETH
4. Emits `Deposited(msg.sender, assets, shares)`

**Modifiers**: `onlyManager`

---

#### withdraw(uint256 assets) → uint256 actual_withdrawn

Swaps wstETH → WETH via Uniswap V3 and transfers to manager.

**Flow:**

1. Calculates `wsteth_to_sell`: proportion of wstETH corresponding to `assets` WETH
2. Swap: `uniswap_router.exactInputSingle(wstETH → WETH, 0.05% fee, 99% min out)`
3. Transfers WETH to manager
4. Emits `Withdrawn(msg.sender, actual_withdrawn, assets)`

**Modifiers**: `onlyManager`

**Note**: The swap is performed in the wstETH/WETH 0.05% Uniswap V3 pool. A maximum of 1% slippage is applied.

---

#### harvest() → uint256 profit

**Always returns 0.** Lido yield is auto-compounded in the wstETH/stETH exchange rate. There are no external rewards to claim.

**Modifiers**: `onlyManager`

---

#### totalAssets() → uint256

WETH-equivalent value of all wstETH in custody.

```solidity
function totalAssets() external view returns (uint256) {
    uint256 wst_balance = wstEthBalance();
    return IWstETH(wsteth).getStETHByWstETH(wst_balance);
    // getStETHByWstETH converts wstETH to stETH using the current exchange rate
    // stETH ≈ ETH ≈ WETH (reasonably stable peg)
}
```

**Note**: The value grows automatically over time as the wstETH/stETH exchange rate increases with staking rewards.

---

#### apy() → uint256

Returns hardcoded APY: 400 bp (4%).

---

### Utility Functions

```solidity
function wstEthBalance() public view returns (uint256)
    // wstETH balance of the strategy
```

### Custom Errors

```solidity
error LidoStrategy__OnlyManager();
error LidoStrategy__ZeroAmount();
error LidoStrategy__DepositFailed();
error LidoStrategy__SwapFailed();
```

---

## AaveStrategy (wstETH).sol

**Location**: `src/strategies/AaveStrategy.sol`

### Purpose

Double yield — deposits wstETH into Aave v3, earning Lido staking yield (~4%) + Aave lending yield (~3.5%) simultaneously. Includes AAVE reward harvesting with automatic swap to WETH and reinvestment as wstETH (auto-compound). APY: **dynamic** (reads Aave liquidity rate on-chain).

### Tier

Available in: **Balanced**

### Implements

- `IStrategy`: Standard strategy interface

### Called By

- **StrategyManager**: `deposit()`, `withdraw()`, `harvest()`, `totalAssets()`, `apy()`

### Calls

- **IWETH**: `withdraw()` — unwrap WETH to ETH
- **ILido**: `receive()` — ETH → stETH
- **IWstETH**: `wrap()` / `unwrap()` — stETH ↔ wstETH
- **IPool (Aave v3)**: `supply(wstETH)`, `withdraw(wstETH)`, `getReserveData(wstETH)`
- **IRewardsController (Aave)**: `claimAllRewards([aWstETH])` — claims AAVE tokens
- **ISwapRouter (Uniswap V3)**: `exactInputSingle()` — swap AAVE → WETH (harvest), swap stETH → ETH via Curve (withdraw)
- **ICurvePool**: `exchange(stETH, ETH)` — during withdraw to convert stETH to ETH

### State Variables

```solidity
// Immutables
address public immutable manager;                    // Authorized StrategyManager
IPool private immutable aave_pool;                   // Aave v3 Pool
IRewardsController private immutable rewards_controller; // Aave rewards controller
address private immutable asset_address;             // WETH
address private immutable a_wst_eth;                 // aWstETH (Aave rebasing token)
address private immutable wst_eth;                   // wstETH token
address private immutable lido;                      // Lido stETH contract
address private immutable st_eth;                    // stETH token
address private immutable reward_token;              // AAVE governance token
ISwapRouter private immutable uniswap_router;        // Uniswap V3 Router
ICurvePool private immutable curve_pool;             // Curve stETH/ETH pool (for withdraw)
uint24 private immutable pool_fee;                   // 3000 (0.3%)
```

### Main Functions

#### deposit(uint256 assets) → uint256 shares

WETH → ETH → stETH → wstETH → Aave supply.

**Precondition**: WETH must be in the strategy (transferred by manager).

**Flow:**

1. `IWETH.withdraw(assets)` — unwrap to ETH
2. `ILido.receive{value: assets}()` — ETH → stETH
3. `IWstETH.wrap(steth_balance)` — stETH → wstETH
4. `aave_pool.supply(wst_eth, wsteth_balance, address(this), 0)` — wstETH → aWstETH
5. Emits `Deposited(msg.sender, assets, shares)`

**Modifiers**: `onlyManager`

---

#### withdraw(uint256 assets) → uint256 actual_withdrawn

aWstETH → wstETH → stETH → ETH (Curve) → WETH.

**Flow:**

1. Calculates `wsteth_to_withdraw` proportional to `assets`
2. `aave_pool.withdraw(wst_eth, wsteth_to_withdraw, address(this))` — aWstETH → wstETH
3. `IWstETH.unwrap(wsteth_received)` — wstETH → stETH
4. `curve_pool.exchange(1, 0, steth_amount, min_eth_out)` — stETH → ETH (index 1→0)
5. `IWETH.deposit{value: eth_received}()` — ETH → WETH
6. Transfers WETH to manager
7. Emits `Withdrawn(msg.sender, actual_withdrawn, assets)`

**Modifiers**: `onlyManager`

---

#### harvest() → uint256 profit

Claims AAVE rewards → swap WETH → reinvests as wstETH in Aave.

**Flow:**

1. `rewards_controller.claimAllRewards([a_wst_eth])` → receives AAVE tokens
2. If no rewards → return 0
3. Swap: `uniswap_router.exactInputSingle(AAVE → WETH, 0.3% fee, 1% max slippage)`
4. `IWETH.withdraw(weth_received)` → ETH → stETH → wstETH → `aave_pool.supply(wstETH)` [auto-compound]
5. Return `profit = weth_received`
6. Emits `Harvested(msg.sender, profit)`

**Modifiers**: `onlyManager`

---

#### totalAssets() → uint256

WETH value of the aWstETH in custody using the current wstETH exchange rate.

```solidity
function totalAssets() external view returns (uint256) {
    uint256 a_wst_eth_balance = IERC20(a_wst_eth).balanceOf(address(this));
    return IWstETH(wst_eth).getStETHByWstETH(a_wst_eth_balance);
    // aWstETH rebases automatically; getStETHByWstETH converts at the current exchange rate
}
```

---

#### apy() → uint256

Dynamic Aave APY for wstETH. Reads `liquidityRate` on-chain.

**Flow:**

1. `aave_pool.getReserveData(wst_eth)` → `DataTypes.ReserveData`
2. Extracts `liquidityRate` (in RAY = 1e27)
3. Converts: `apy = liquidityRate / 1e23` (RAY → basis points)

**Example:**

```solidity
// liquidityRate wstETH = 35000000000000000000000000 (RAY) ≈ 3.5%
// apy = 35000000000000000000000000 / 1e23 = 350 basis points
// (Does not include the Lido staking yield — that is accounted for via exchange rate)
```

---

### Utility Functions

```solidity
function availableLiquidity() external view returns (uint256)
    // Available liquidity in Aave v3 for wstETH withdrawals

function aTokenBalance() external view returns (uint256)
    // aWstETH balance of the strategy

function pendingRewards() external view returns (uint256)
    // Pending AAVE rewards to claim
```

### Custom Errors

```solidity
error AaveStrategy__DepositFailed();
error AaveStrategy__WithdrawFailed();
error AaveStrategy__OnlyManager();
error AaveStrategy__HarvestFailed();
error AaveStrategy__SwapFailed();
error AaveStrategy__ZeroAmount();
```

---

## CurveStrategy.sol

**Location**: `src/strategies/CurveStrategy.sol`

### Purpose

Liquidity provision in the Curve stETH/ETH pool and staking of LP tokens in the gauge to accumulate CRV rewards. Generates yield from two sources: trading fees from the pool (~1-2%) + CRV rewards from the gauge (~4%). Estimated APY: **6% (600 bp)**.

### Tier

Available in: **Balanced** and **Aggressive**

### Implements

- `IStrategy`: Standard strategy interface

### Called By

- **StrategyManager**: `deposit()`, `withdraw()`, `harvest()`, `totalAssets()`, `apy()`

### Calls

- **IWETH**: `withdraw()` — unwrap WETH to ETH
- **ILido**: `receive()` — ETH → stETH (during deposit, to balance the pair)
- **ICurvePool**: `add_liquidity([eth, steth])`, `remove_liquidity_one_coin(lp, 0)`, `get_virtual_price()`
- **ICurveGauge**: `deposit(LP)`, `withdraw(LP)`, `claim_rewards()`, `balanceOf()`
- **ISwapRouter (Uniswap V3)**: `exactInputSingle(CRV → WETH, 0.3% fee)` — during harvest

### State Variables

```solidity
// Immutables
address public immutable manager;            // Authorized StrategyManager
address private immutable asset_address;     // WETH
ICurvePool private immutable pool;           // Curve stETH/ETH pool
ICurveGauge private immutable gauge;         // Curve gauge (LP staking)
address private immutable lp_token;          // Pool LP token
address private immutable lido;              // Lido stETH contract
address private immutable crv_token;         // CRV governance token
ISwapRouter private immutable swap_router;   // Uniswap V3 Router

// Hardcoded APY
uint256 private constant CURVE_APY = 600;    // 6% (600 bp)
```

### Main Functions

#### deposit(uint256 assets) → uint256 shares

WETH → ETH → stETH → add_liquidity → LP → gauge stake.

**Precondition**: WETH must be in the strategy (transferred by manager).

**Flow:**

1. `IWETH.withdraw(assets)` — unwrap WETH to ETH
2. Splits ETH into two halves: 50% sent to Lido, 50% used as direct ETH
3. `ILido.receive{value: half}()` — ETH → stETH
4. `pool.add_liquidity([eth_half, steth_received], min_lp_out)` — ETH + stETH → LP tokens
5. `gauge.deposit(lp_balance)` — stakes LP in gauge
6. Emits `Deposited(msg.sender, assets, shares)`

**Modifiers**: `onlyManager`

---

#### withdraw(uint256 assets) → uint256 actual_withdrawn

gauge.withdraw → remove_liquidity_one_coin → ETH → WETH.

**Flow:**

1. Calculates `lp_to_withdraw` proportional to `assets` / `totalAssets()`
2. `gauge.withdraw(lp_to_withdraw)` — unstakes LP from gauge
3. `pool.remove_liquidity_one_coin(lp_to_withdraw, 0, min_eth_out)` — LP → ETH (index 0)
4. `IWETH.deposit{value: eth_received}()` — ETH → WETH
5. Transfers WETH to manager
6. Emits `Withdrawn(msg.sender, actual_withdrawn, assets)`

**Modifiers**: `onlyManager`

---

#### harvest() → uint256 profit

Claims CRV rewards → swap WETH → reinvests as LP.

**Flow:**

1. `gauge.claim_rewards()` → receives CRV tokens
2. If CRV balance == 0 → return 0
3. Swap: `uniswap_router.exactInputSingle(CRV → WETH, 0.3% fee, no min_out)`
4. Records `profit = weth_received`
5. Reinvests: ETH + stETH → `pool.add_liquidity` → `gauge.deposit` [auto-compound]
6. Emits `Harvested(msg.sender, profit)`

**Modifiers**: `onlyManager`

---

#### totalAssets() → uint256

WETH value of the staked LP tokens using the pool's virtual price.

```solidity
function totalAssets() external view returns (uint256) {
    uint256 lp = ICurveGauge(gauge).balanceOf(address(this));
    return FullMath.mulDiv(lp, ICurvePool(pool).get_virtual_price(), 1e18);
    // virtual_price grows over time reflecting accumulated trading fees
    // Expressed in ETH equivalent (1e18 = 1 ETH per LP)
}
```

---

#### apy() → uint256

Returns hardcoded APY: 600 bp (6%).

---

### Utility Functions

```solidity
function lpBalance() public view returns (uint256)
    // Balance of LP tokens staked in the gauge
```

### Custom Errors

```solidity
error CurveStrategy__OnlyManager();
error CurveStrategy__ZeroAmount();
error CurveStrategy__DepositFailed();
error CurveStrategy__WithdrawFailed();
error CurveStrategy__SwapFailed();
```

---

## UniswapV3Strategy.sol

**Location**: `src/strategies/UniswapV3Strategy.sol`

### Purpose

Concentrated liquidity provision in the Uniswap V3 WETH/USDC 0.05% pool to capture trading fees. Maintains a unique NFT position with a fixed range of ±960 ticks (≈ ±10% of the current price at deploy time). Estimated APY: **14% (1400 bp)**, highly variable based on pool volume.

### Tier

Available in: **Aggressive**

### Implements

- `IStrategy`: Standard strategy interface

### Called By

- **StrategyManager**: `deposit()`, `withdraw()`, `harvest()`, `totalAssets()`, `apy()`

### Calls

- **INonfungiblePositionManager**: `mint()`, `increaseLiquidity()`, `decreaseLiquidity()`, `collect()`, `burn()`, `positions()`
- **ISwapRouter**: `exactInputSingle(WETH ↔ USDC, 0.05% fee)` — to balance the pair in each operation
- **IUniswapV3Pool**: `slot0()` — reads current price (sqrtPriceX96) to calculate the position's value

### State Variables

```solidity
// Immutables (calculated in constructor)
address public immutable manager;                    // Authorized StrategyManager
address private immutable asset_address;             // WETH
INonfungiblePositionManager private immutable position_manager;
ISwapRouter private immutable swap_router;
IUniswapV3Pool private immutable pool;               // WETH/USDC 0.05% pool
address private immutable weth;
address private immutable usdc;                      // 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
address private immutable token0;                    // The lower address (USDC in WETH/USDC)
address private immutable token1;                    // The higher address (WETH in WETH/USDC)
bool private immutable weth_is_token0;               // false in WETH/USDC (USDC < WETH in addr)
int24 public immutable lower_tick;                   // tick_current - 960
int24 public immutable upper_tick;                   // tick_current + 960

// Mutable state
uint256 public token_id;                             // Active NFT ID (0 = no position)

// Constants
uint24 private constant POOL_FEE = 500;              // 0.05% pool fee tier
int24 private constant TICK_SPACING = 10;            // Tick spacing for 0.05% pool
int24 private constant TICK_RANGE = 960;             // ±960 ticks ≈ ±10% of price
uint256 private constant UNISWAP_V3_APY = 1400;     // 14% (historical estimate)
```

**Addresses mainnet:**

- Pool WETH/USDC 0.05%: `0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640`
- NonfungiblePositionManager: `0xC36442b4a4522E871399CD717aBDD847Ab11FE88`
- SwapRouter: `0xE592427A0AEce92De3Edee1F18E0157C05861564`
- USDC: `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`

### Main Functions

#### deposit(uint256 assets) → uint256 shares

WETH → swap 50% to USDC → mint/increaseLiquidity NFT.

**Precondition**: WETH must be in the strategy (transferred by manager).

**Flow:**

1. Swap 50% of WETH to USDC: `exactInputSingle(WETH → USDC, 0.05% fee)`
2. If `token_id == 0` (first time):
   - `position_manager.mint(token0, token1, 500, lower_tick, upper_tick, amounts...)` → saves `token_id`
3. If `token_id > 0` (existing position):
   - `position_manager.increaseLiquidity(token_id, amounts...)`
4. Emits `Deposited(msg.sender, assets, assets)`

**Modifiers**: `onlyManager`

---

#### withdraw(uint256 assets) → uint256 actual_withdrawn

decreaseLiquidity → collect → swap USDC → WETH → if empty, burn NFT.

**Flow:**

1. Gets `total_liquidity` from the position via `positions(token_id)`
2. Calculates `liquidity_to_remove` proportionally: `total_liquidity * assets / _totalAssets()`
3. `position_manager.decreaseLiquidity(token_id, liquidity_to_remove, ...)` — tokens move to "owed"
4. `position_manager.collect(token_id, max_amounts)` → receives WETH + USDC
5. If `remaining_liquidity == 0`: `position_manager.burn(token_id)`, `token_id = 0`
6. Swap USDC → WETH: `exactInputSingle(USDC → WETH, 0.05% fee)`
7. Transfers all WETH to manager
8. Emits `Withdrawn(msg.sender, actual_withdrawn, assets)`

**Modifiers**: `onlyManager`

---

#### harvest() → uint256 profit

collect fees (WETH+USDC) → swap USDC → WETH → records profit → reinvests.

**Flow:**

1. If `token_id == 0` → return 0 (no active position)
2. `position_manager.collect(token_id, max_amounts)` → collects accumulated fees (WETH + USDC)
3. If collected == 0 → return 0
4. Swap `USDC → WETH`: `exactInputSingle(USDC → WETH, 0.05% fee)` → everything in WETH
5. Records `profit = total_weth`
6. Reinvests: swap 50% WETH → USDC → `position_manager.increaseLiquidity(token_id, ...)`
7. Emits `Harvested(msg.sender, profit)`

**Modifiers**: `onlyManager`

---

#### totalAssets() → uint256

Calculates the WETH value of the NFT position using the pool's current price.

**Internally (\_totalAssets):**

1. If `token_id == 0` → return 0
2. Gets `liquidity`, `tokens_owed0`, `tokens_owed1` from `positions(token_id)`
3. Reads `sqrtPriceX96` from `pool.slot0()`
4. Uses `LiquidityAmounts.getAmountsForLiquidity()` to convert liquidity to amount0/amount1
5. Adds pending fees (`tokens_owed0`, `tokens_owed1`)
6. Converts USDC to WETH using `sqrtPriceX96` and `FullMath.mulDiv()` to avoid overflow
7. Returns `weth_amount + weth_from_usdc`

**Note**: The `TickMath`, `LiquidityAmounts`, and `FullMath` libraries are ports of the Uniswap V3 libraries used internally by the protocol.

---

#### apy() → uint256

Returns hardcoded APY: 1400 bp (14%). Highly variable based on WETH/USDC pool volume.

---

### Custom Errors

```solidity
error UniswapV3Strategy__OnlyManager();
error UniswapV3Strategy__ZeroAmount();
error UniswapV3Strategy__MintFailed();
error UniswapV3Strategy__SwapFailed();
error UniswapV3Strategy__InsufficientLiquidity();
```

---

## IStrategy.sol

**Location**: `src/interfaces/core/IStrategy.sol`

### Purpose

Standard interface that all strategies must implement to allow StrategyManager to treat them uniformly.

### Required Functions

```solidity
function deposit(uint256 assets) external returns (uint256 shares);
function withdraw(uint256 assets) external returns (uint256 actual_withdrawn);
function harvest() external returns (uint256 profit);
function totalAssets() external view returns (uint256 total);
function apy() external view returns (uint256 apy_basis_points);
function name() external view returns (string memory strategy_name);
function asset() external view returns (address asset_address);
```

### Events

```solidity
event Deposited(address indexed caller, uint256 assets, uint256 shares);
event Withdrawn(address indexed caller, uint256 assets, uint256 shares);
event Harvested(address indexed caller, uint256 profit);
```

### Important Note

The interface includes `harvest()` as a required function — all VynX V1 strategies implement this method. In LidoStrategy, `harvest()` always returns 0 (yield is auto-compounded). The `actual_withdrawn` in `withdraw()` allows accounting for rounding from external protocols.

---

## Router.sol

**Location**: `src/periphery/Router.sol`

### Purpose

Stateless peripheral contract that allows depositing into and withdrawing from the Vault using native ETH or any ERC20 token with a Uniswap V3 pool. Acts as a multi-token entry point without requiring the user to hold WETH beforehand.

### Inheritance

- `IRouter`: Router interface (events and functions)
- `ReentrancyGuard` (OpenZeppelin): Reentrancy protection on all public functions

### Called By

- **Users (EOAs/contracts)**: `zapDepositETH()`, `zapDepositERC20()`, `zapWithdrawETH()`, `zapWithdrawERC20()`

### Calls

- **IERC4626(vault)**: `deposit()`, `redeem()`
- **ISwapRouter(uniswap)**: `exactInputSingle()` for ERC20 ↔ WETH swaps
- **WETH**: `deposit()` (wrap), `withdraw()` (unwrap) via low-level calls

### State Variables

```solidity
// Immutables (set in constructor)
address public immutable weth;         // WETH token address
address public immutable vault;        // VynX Vault address (ERC4626)
address public immutable swap_router;  // Uniswap V3 SwapRouter address
```

### Constructor

```solidity
constructor(address _weth, address _vault, address _swap_router)
```

**Flow:**

1. Validates that no address is `address(0)` (reverts with `Router__ZeroAddress`)
2. Sets the 3 immutable variables
3. Approves the vault to transfer unlimited WETH: `IERC20(weth).forceApprove(vault, type(uint256).max)`

### Main Functions

#### zapDepositETH() payable → uint256 shares

Deposits native ETH into the vault (wrap → deposit).

**Flow:**

1. Verifies `msg.value > 0`
2. Wraps ETH to WETH: `_wrapETH(msg.value)`
3. Deposits WETH into vault: `vault.deposit(msg.value, msg.sender)` → shares to user
4. Verifies stateless: `balanceOf(this) == 0`
5. Emits `ZapDeposit(msg.sender, address(0), msg.value, msg.value, shares)`

#### zapDepositERC20(token_in, amount_in, pool_fee, min_weth_out) → uint256 shares

Deposits ERC20 into the vault (swap → deposit).

**Flow:**

1. Validates: `token_in != address(0)`, `token_in != weth`, `amount_in > 0`
2. Transfers `token_in` from user to Router
3. Swaps `token_in → WETH`: `_swapToWETH(token_in, amount_in, pool_fee, min_weth_out)`
4. Deposits WETH into vault → shares to user
5. Verifies stateless
6. Emits `ZapDeposit(msg.sender, token_in, amount_in, weth_out, shares)`

#### zapWithdrawETH(shares) → uint256 eth_out

Withdraws shares from the vault and receives native ETH (redeem → unwrap).

**Flow:**

1. Validates `shares > 0`
2. Transfers shares from user to Router (requires prior approval)
3. Redeems shares: `vault.redeem(shares, address(this), address(this))` → WETH to Router
4. Unwraps WETH to ETH: `_unwrapWETH(weth_redeemed)`
5. Transfers ETH to user via low-level call
6. Verifies stateless
7. Emits `ZapWithdraw(msg.sender, shares, weth_redeemed, address(0), eth_out)`

#### zapWithdrawERC20(shares, token_out, pool_fee, min_token_out) → uint256 amount_out

Withdraws shares from the vault and receives ERC20 (redeem → swap).

**Flow:**

1. Validates: `token_out != address(0)`, `token_out != weth`, `shares > 0`
2. Transfers shares from user to Router
3. Redeems shares → WETH to Router
4. Swaps `WETH → token_out`: `_swapFromWETH(weth_redeemed, token_out, pool_fee, min_token_out)`
5. Transfers `token_out` to user
6. Verifies stateless (`token_out` balance == 0)
7. Emits `ZapWithdraw(msg.sender, shares, weth_redeemed, token_out, amount_out)`

### Internal Functions

#### \_wrapETH(uint256 amount)

```solidity
(bool success,) = weth.call{value: amount}(abi.encodeWithSignature("deposit()"));
if (!success) revert Router__ETHWrapFailed();
```

#### \_unwrapWETH(uint256 amount) → uint256 eth_out

```solidity
(bool success,) = weth.call(abi.encodeWithSignature("withdraw(uint256)", amount));
if (!success) revert Router__ETHUnwrapFailed();
return amount;
```

#### \_swapToWETH(token_in, amount_in, pool_fee, min_weth_out) → uint256 weth_out

```solidity
IERC20(token_in).forceApprove(swap_router, amount_in);
weth_out = ISwapRouter(swap_router).exactInputSingle({
    tokenIn: token_in,
    tokenOut: weth,
    fee: pool_fee,
    recipient: address(this),
    deadline: block.timestamp,
    amountIn: amount_in,
    amountOutMinimum: min_weth_out,
    sqrtPriceLimitX96: 0
});
if (weth_out < min_weth_out) revert Router__SlippageExceeded();
```

#### \_swapFromWETH(weth_in, token_out, pool_fee, min_token_out) → uint256 amount_out

Similar to `_swapToWETH` but inverting tokenIn/tokenOut.

### receive() Function

```solidity
receive() external payable {
    if (msg.sender != weth) revert Router__UnauthorizedETHSender();
}
```

**Purpose**: Only accepts ETH from the WETH contract (during unwrap). Prevents accidental ETH transfers.

### Events

Inherited from `IRouter`:

```solidity
event ZapDeposit(
    address indexed user,
    address indexed token_in,  // address(0) if ETH
    uint256 amount_in,
    uint256 weth_out,
    uint256 shares_out
);

event ZapWithdraw(
    address indexed user,
    uint256 shares_in,
    uint256 weth_redeemed,
    address indexed token_out,  // address(0) if ETH
    uint256 amount_out
);
```

### Custom Errors

```solidity
error Router__ZeroAddress();
error Router__ZeroAmount();
error Router__SlippageExceeded();
error Router__ETHWrapFailed();
error Router__FundsStuck();
error Router__UseVaultForWETH();
error Router__UnauthorizedETHSender();
error Router__ETHUnwrapFailed();
```

### Addresses Mainnet

### Balanced Tier

| Contract        | Address                                                                                                                 |
| --------------- | ----------------------------------------------------------------------------------------------------------------------- |
| StrategyManager | [`0xA0d462b84C2431463bDACDC2C5bc3172FC927B0B`](https://etherscan.io/address/0xa0d462b84c2431463bdacdc2c5bc3172fc927b0b) |
| Vault (vxWETH)  | [`0x9D002dF2A5B632C0D8022a4738C1fa7465d88444`](https://etherscan.io/address/0x9d002df2a5b632c0d8022a4738c1fa7465d88444) |
| LidoStrategy    | [`0xf8d1E54A07A47BB03833493EAEB7FE7432B53FCB`](https://etherscan.io/address/0xf8d1e54a07a47bb03833493eaeb7fe7432b53fcb) |
| AaveStrategy    | [`0x8135Ed49ffFeEF4a1Bb5909c5bA96EEe9D4ed32A`](https://etherscan.io/address/0x8135ed49fffeef4a1bb5909c5ba96eee9d4ed32a) |
| CurveStrategy   | [`0xF0C57C9c1974a14602074D85cfB1Bc251B67Dc00`](https://etherscan.io/address/0xf0c57c9c1974a14602074d85cfb1bc251b67dc00) |
| Router          | [`0x3286c0cB7Bbc7DD4cC7C8752E3D65e275E1B1044`](https://etherscan.io/address/0x3286c0cb7bbc7dd4cc7c8752e3d65e275e1b1044) |

### Aggressive Tier

| Contract          | Address                                                                                                                 |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------- |
| StrategyManager   | [`0xcCa54463BD2aEDF1773E9c3f45c6a954Aa9D9706`](https://etherscan.io/address/0xcca54463bd2aedf1773e9c3f45c6a954aa9d9706) |
| Vault (vxWETH)    | [`0xA8cA9d84e35ac8F5af6F1D91fe4bE1C0BAf44296`](https://etherscan.io/address/0xa8ca9d84e35ac8f5af6f1d91fe4be1c0baf44296) |
| CurveStrategy     | [`0x312510B911fA47D55c9f1a055B1987D51853A7DE`](https://etherscan.io/address/0x312510b911fa47d55c9f1a055b1987d51853a7de) |
| UniswapV3Strategy | [`0x653D9C2dF3A32B872aEa4E3b4e7436577C5eEB62`](https://etherscan.io/address/0x653d9c2df3a32b872aea4e3b4e7436577c5eeb62) |
| Router            | [`0xE898661760299f88e2B271a088987dacB8Fb3dE6`](https://etherscan.io/address/0xe898661760299f88e2b271a088987dacb8fb3de6) |

---

## IRouter.sol

**Location**: `src/interfaces/periphery/IRouter.sol`

### Purpose

Standard Router interface that defines events and public functions. Any Router implementation must comply with this interface.

### Events

```solidity
event ZapDeposit(
    address indexed user,
    address indexed token_in,
    uint256 amount_in,
    uint256 weth_out,
    uint256 shares_out
);

event ZapWithdraw(
    address indexed user,
    uint256 shares_in,
    uint256 weth_redeemed,
    address indexed token_out,
    uint256 amount_out
);
```

### Required Functions

```solidity
function weth() external view returns (address);
function vault() external view returns (address);
function swap_router() external view returns (address);

function zapDepositETH() external payable returns (uint256 shares);
function zapDepositERC20(address token_in, uint256 amount_in, uint24 pool_fee, uint256 min_weth_out)
    external returns (uint256 shares);
function zapWithdrawETH(uint256 shares) external returns (uint256 eth_out);
function zapWithdrawERC20(uint256 shares, address token_out, uint24 pool_fee, uint256 min_token_out)
    external returns (uint256 amount_out);
```

---

**Next reading**: [FLOWS.md](FLOWS.md) — Step-by-step user flows with all 4 V1 strategies
