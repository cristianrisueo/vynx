# Contract Documentation

This document provides detailed technical documentation of each contract in the VynX V1 protocol, including state variables, main functions, events, and modifiers.

---

## Vault.sol

**Location**: `src/core/Vault.sol`

### Purpose

ERC4626 Vault that acts as the main interface for users. Mints tokenized shares (vxWETH) proportional to deposited assets, accumulates WETH in an idle buffer to optimize gas, coordinates reward harvesting with performance fee distribution, and manages the keeper incentive system.

### Inheritance

- `ERC4626` (OpenZeppelin): Standard tokenized vault implementation
- `ERC20` (OpenZeppelin): Shares token (vxWETH, dynamic name: "VynX {SYMBOL} Vault")
- `Ownable` (OpenZeppelin): Administrative access control
- `Pausable` (OpenZeppelin): Emergency stop for deposits/withdrawals/harvest

### Called By

- **Users (EOAs/contracts)**: `deposit()`, `mint()`, `withdraw()`, `redeem()`
- **Keepers/Anyone**: `harvest()`, `allocateIdle()`
- **Owner**: Administrative functions (pause, setters)

### Calls To

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
uint256 public last_harvest;                          // Timestamp of last harvest
uint256 public total_harvested;                       // Total gross profit accumulated

// Harvest parameters
uint256 public min_profit_for_harvest = 0.1 ether;   // Minimum profit to execute harvest
uint256 public keeper_incentive = 100;                // 1% (100 bp) of profit for ext. keepers

// Fee parameters
uint256 public performance_fee = 2000;                // 20% (2000 bp) on profits
uint256 public treasury_split = 8000;                 // 80% of perf fee → treasury (shares)
uint256 public founder_split = 2000;                  // 20% of perf fee → founder (WETH)

// Circuit breakers
uint256 public min_deposit = 0.01 ether;              // Anti-spam, anti-rounding
uint256 public idle_threshold = 10 ether;             // Threshold for auto-allocate
uint256 public max_tvl = 1000 ether;                  // Maximum allowed TVL
```

### Main Functions

#### deposit(uint256 assets, address receiver) → uint256 shares

Deposits WETH into the vault and mints shares to the user.

**Flow:**
1. Verifies `assets >= min_deposit` (0.01 ETH)
2. Verifies `totalAssets() + assets <= max_tvl` (circuit breaker)
3. Calculates shares using `previewDeposit(assets)` (before changing state)
4. Transfers WETH from user to vault (`SafeERC20.safeTransferFrom`)
5. Increments `idle_buffer += assets` (accumulates in buffer)
6. Mints shares to receiver (`_mint`)
7. If `idle_buffer >= idle_threshold` (10 ETH), auto-executes `_allocateIdle()`

**Modifiers**: `whenNotPaused`

**Events**: `Deposited(receiver, assets, shares)`

---

#### mint(uint256 shares, address receiver) → uint256 assets

Mints exact amount of shares depositing the necessary assets.

**Flow:**
1. Verifies `shares > 0`
2. Calculates necessary assets using `previewMint(shares)`
3. Same as `deposit()` from here on

**Modifiers**: `whenNotPaused`

**Events**: `Deposited(receiver, assets, shares)`

---

#### withdraw(uint256 assets, address receiver, address owner) → uint256 shares

Withdraws exact amount of WETH burning the necessary shares.

**Flow:**
1. Calculates shares to burn using `previewWithdraw(assets)`
2. Verifies allowance if `msg.sender != owner` (`_spendAllowance`)
3. Burns shares from owner (`_burn`) - **CEI pattern**
4. Calculates `from_idle = min(idle_buffer, assets)`
5. Calculates `from_strategies = assets - from_idle`
6. If `from_strategies > 0`, calls `manager.withdrawTo(from_strategies, vault)`
7. Verifies rounding tolerance: `assets - to_transfer < 20 wei`
8. Transfers net `assets` to `receiver`

**Modifiers**: `whenNotPaused`

**Events**: `Withdrawn(receiver, assets, shares)`

**Note on rounding**: External protocols (Aave, Compound) round down ~1-2 wei per operation. The vault tolerates up to 20 wei of difference (margin for ~10 future strategies). If the difference exceeds 20 wei, it reverts with "Excessive rounding" (serious accounting issue).

---

#### redeem(uint256 shares, address receiver, address owner) → uint256 assets

Burns exact shares and withdraws proportional WETH.

**Flow:**
1. Calculates net assets using `previewRedeem(shares)`
2. Same as `withdraw()` from here on

**Modifiers**: `whenNotPaused`

**Events**: `Withdrawn(receiver, assets, shares)`

---

#### harvest() → uint256 profit

Harvests rewards from all strategies and distributes performance fees.

**Preconditions**: Vault not paused. Anyone can call.

**Flow:**
1. Calls `IStrategyManager(strategy_manager).harvest()` → gets `profit`
2. If `profit < min_profit_for_harvest` (0.1 ETH) → return 0 (doesn't distribute)
3. If caller is not an official keeper:
   - Calculates `keeper_reward = (profit * keeper_incentive) / BASIS_POINTS`
   - Pays from `idle_buffer` if sufficient, otherwise withdraws from strategies
   - Transfers `keeper_reward` WETH to caller
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
// Caller is external keeper (not official)
//
// keeper_reward = 5.5 * 100 / 10000 = 0.055 WETH → paid to keeper
// net_profit = 5.5 - 0.055 = 5.445 WETH
// perf_fee = 5.445 * 2000 / 10000 = 1.089 WETH
// treasury_amount = 1.089 * 8000 / 10000 = 0.8712 WETH → mints shares to treasury
// founder_amount = 1.089 * 2000 / 10000 = 0.2178 WETH → transfers WETH to founder
```

---

#### totalAssets() → uint256

Calculates total TVL under vault management.

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

Returns maximum depositable before reaching max_tvl. Returns 0 if paused.

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

Returns maximum mintable shares before reaching max_tvl. Returns 0 if paused.

---

### Internal Functions

#### _allocateIdle()

Transfers idle buffer to StrategyManager for investment.

**Flow:**
1. Saves `to_allocate = idle_buffer`
2. Resets `idle_buffer = 0`
3. Transfers WETH to manager (`safeTransfer`)
4. Calls `manager.allocate(to_allocate)`

**Called from:**
- `deposit()` / `mint()` if `idle_buffer >= idle_threshold`
- `allocateIdle()` (external, anyone can call if idle >= threshold)

---

#### _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)

Override of ERC4626._withdraw with custom withdrawal logic.

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

#### _distributePerformanceFee(uint256 perf_fee)

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

Brain of the protocol that calculates weighted allocation based on APY, distributes assets among strategies, executes profitable rebalances, withdraws proportionally during withdrawals, and coordinates fail-safe harvest of all strategies.

### Inheritance

- `Ownable` (OpenZeppelin): Administrative access control

### Called By

- **Vault**: `allocate()`, `withdrawTo()`, `harvest()` (`onlyVault` modifier)
- **Owner**: `addStrategy()`, `removeStrategy()`, setters
- **Anyone**: `rebalance()` (if `shouldRebalance()` is true)

### Calls To

- **IStrategy**: `deposit()`, `withdraw()`, `harvest()`, `totalAssets()`, `apy()`

### Key State Variables

```solidity
// Constants
uint256 public constant BASIS_POINTS = 10000;               // 100% = 10000 bp
uint256 public constant MAX_STRATEGIES = 10;                 // Prevents gas DoS on loops

// Immutables
address public immutable asset;                              // WETH

// Vault (set via initialize, once only)
address public vault;                                        // Authorized vault

// Available strategies
IStrategy[] public strategies;
mapping(address => bool) public is_strategy;
mapping(IStrategy => uint256) public target_allocation;       // In basis points

// Allocation parameters
uint256 public max_allocation_per_strategy = 5000;           // 50%
uint256 public min_allocation_threshold = 1000;              // 10%

// Rebalancing parameters
uint256 public rebalance_threshold = 200;                    // 2% APY difference
uint256 public min_tvl_for_rebalance = 10 ether;
```

### Main Functions

#### allocate(uint256 assets)

Distributes WETH among strategies according to target allocation.

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

**Example:**
```solidity
// If it receives 100 WETH and targets are [5000, 5000] (50%, 50%):
// - AaveStrategy receives 50 WETH
// - CompoundStrategy receives 50 WETH
```

---

#### withdrawTo(uint256 assets, address receiver)

Withdraws WETH from strategies proportionally and transfers to receiver.

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

**Note**: Withdraws proportionally to maintain ratios. Does NOT recalculate target allocation (gas savings). Uses `actual_withdrawn` to account for rounding from external protocols.

**Example:**
```solidity
// State: Aave 70 WETH, Compound 30 WETH (total 100 WETH)
// User withdraws 50 WETH
// - From Aave: 50 * 70/100 = 35 WETH (actual: ~34.999999999999999998)
// - From Compound: 50 * 30/100 = 15 WETH (actual: ~14.999999999999999999)
// Result: Aave 35 WETH, Compound 15 WETH (maintains 70/30 ratio)
```

---

#### harvest() → uint256 total_profit

Harvests rewards from all strategies with fail-safe.

**Flow:**
1. For each strategy:
   - `try strategy.harvest()` → accumulates profit on success
   - `catch` → emits `HarvestFailed(strategy, reason)` and continues
2. Returns `total_profit` (sum of individual profits)

**Modifiers**: `onlyVault`

**Events**: `Harvested(total_profit)`, `HarvestFailed(strategy, reason)` if any fails

**Note**: The fail-safe is critical — if Aave harvest fails due to lack of rewards, Compound harvest continues normally.

---

#### rebalance()

Adjusts each strategy to its target allocation by moving only the necessary deltas.

**Precondition**: `shouldRebalance()` must be true (reverts if not).

**Flow:**
1. Verifies profitability with `shouldRebalance()`
2. Recalculates fresh targets: `_calculateTargetAllocation()`
3. Gets `total_tvl = totalAssets()`
4. For each strategy:
   - Calculates `current_balance = strategy.totalAssets()`
   - Calculates `target_balance = (total_tvl * target) / BASIS_POINTS`
   - If `current > target`: Adds to excess array
   - If `target > current`: Adds to need array
5. For each strategy with excess:
   - Withdraws excess: `strategy.withdraw(excess)`
6. For each strategy with need:
   - Calculates `to_transfer = min(available, needed)`
   - Transfers WETH to destination strategy
   - Deposits: `strategy.deposit(to_transfer)`
   - Emits `Rebalanced(from_strategy, to_strategy, amount)`

**Modifiers**: None (public)

**Events**: `Rebalanced(from_strategy, to_strategy, assets)`

**Example:**
```solidity
// Current state: Aave 70 WETH (3.5% APY), Compound 30 WETH (6% APY)
// Targets: Aave ~37% (37 WETH), Compound ~63% (63 WETH)
// Rebalance:
//   1. Withdraw 33 WETH from Aave
//   2. Deposit 33 WETH into Compound
// Final state: Aave 37 WETH, Compound 63 WETH
```

---

#### shouldRebalance() → bool

Checks whether a rebalance is profitable by comparing APY difference between strategies.

**Flow:**
1. Verifies `strategies.length >= 2`
2. Verifies `totalAssets() >= min_tvl_for_rebalance` (10 ETH)
3. Calculates `max_apy` and `min_apy` across all strategies
4. Returns `(max_apy - min_apy) >= rebalance_threshold` (200 bp = 2%)

**Note**: It's a `view` function (doesn't modify state), can be called by bots/frontends.

**Calculation example:**
```solidity
// Aave APY: 3.5% (350 bp), Compound APY: 6% (600 bp)
// Difference: 600 - 350 = 250 bp
// Threshold: 200 bp
// 250 >= 200 → shouldRebalance = true
```

---

### Strategy Management Functions

#### addStrategy(address strategy)

Adds a new strategy to the manager.

**Flow:**
1. Verifies strategy doesn't exist (`!is_strategy[strategy]`)
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

**Precondition**: Strategy must have zero balance before removal.

**Flow:**
1. Verifies strategy at `index` has `totalAssets() == 0`
2. Deletes target: `delete target_allocation[strategies[index]]`
3. Swap & pop: `strategies[index] = strategies[length-1]; strategies.pop()`
4. Marks as non-existing: `is_strategy[strategy] = false`
5. Recalculates targets for remaining strategies

**Modifiers**: `onlyOwner`

**Events**: `StrategyRemoved(strategy)`, `TargetAllocationUpdated()`

---

### Internal Functions

#### _computeTargets() → uint256[]

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

**Used by**: `_calculateTargetAllocation()` (writes to storage), `shouldRebalance()` doesn't use it directly (compares APYs)

---

#### _calculateTargetAllocation()

Calculates targets and writes to storage.

**Flow:**
1. If no strategies: returns
2. Calls `_computeTargets()` to get array of targets
3. Writes to storage: `target_allocation[strategies[i]] = computed[i]`
4. Emits `TargetAllocationUpdated()`

---

### Initialization

```solidity
// Constructor: only receives asset
constructor(address _asset)

// initialize: resolves circular dependency vault <-> manager
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
    // Complete information of all strategies
    // Warning: Gas intensive (~1M gas), only for off-chain queries
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

## AaveStrategy.sol

**Location**: `src/strategies/AaveStrategy.sol`

### Purpose

Integration with Aave v3 to deposit WETH and generate yield through lending. Includes AAVE reward harvesting with automatic swap to WETH via Uniswap V3 and automatic reinvestment (auto-compound).

### Implements

- `IStrategy`: Standard strategy interface

### Called By

- **StrategyManager**: `deposit()`, `withdraw()`, `harvest()`, `totalAssets()`, `apy()`

### Calls To

- **IPool (Aave v3)**: `supply()`, `withdraw()`, `getReserveData()`
- **IRewardsController (Aave)**: `claimAllRewards()` — claims accumulated AAVE tokens
- **ISwapRouter (Uniswap V3)**: `exactInputSingle()` — swap AAVE → WETH
- **IERC20(WETH)**: Transfers with SafeERC20

### State Variables

```solidity
// Constants
uint256 public constant BASIS_POINTS = 10000;
uint256 public constant MAX_SLIPPAGE_BPS = 100;       // 1% max slippage on swaps

// Immutables
address public immutable manager;                       // Authorized StrategyManager
IPool private immutable aave_pool;                     // Aave v3 Pool
IRewardsController private immutable rewards_controller;// Aave rewards controller
address private immutable asset_address;               // WETH
IAToken private immutable a_token;                     // aWETH (rebasing token)
address private immutable reward_token;                // AAVE governance token
ISwapRouter private immutable uniswap_router;          // Uniswap V3 Router
uint24 private immutable pool_fee;                     // 3000 (0.3%)
```

### Main Functions

#### deposit(uint256 assets) → uint256 shares

Deposits WETH into Aave v3.

**Precondition**: WETH must be in the strategy (transferred by manager).

**Flow:**
1. Calls `aave_pool.supply(weth, assets, address(this), 0)`
2. Receives aWETH 1:1 (shares = assets)
3. Emits `Deposited(msg.sender, assets, shares)`

**Modifiers**: `onlyManager`

**Note**: aWETH rebases automatically, balance increases with yield.

---

#### withdraw(uint256 assets) → uint256 actual_withdrawn

Withdraws WETH from Aave v3.

**Flow:**
1. Calls `aave_pool.withdraw(weth, assets, address(this))`
2. Burns aWETH, receives WETH (1:1 + accumulated yield)
3. Transfers WETH to manager: `safeTransfer(msg.sender, actual_withdrawn)`
4. Emits `Withdrawn(msg.sender, actual_withdrawn, assets)`

**Modifiers**: `onlyManager`

---

#### harvest() → uint256 profit

Harvests AAVE rewards, swaps to WETH via Uniswap V3, re-invests in Aave.

**Flow:**
1. Builds array with the aToken address
2. Calls `rewards_controller.claimAllRewards([aToken])` → receives AAVE tokens
3. If no rewards → return 0
4. Calculates `min_amount_out = (claimed * (BASIS_POINTS - MAX_SLIPPAGE_BPS)) / BASIS_POINTS`
   - With MAX_SLIPPAGE_BPS = 100: `min_out = claimed * 9900 / 10000` (1% max slippage)
5. Executes swap via Uniswap V3:
   ```solidity
   uniswap_router.exactInputSingle(
       tokenIn: reward_token,     // AAVE
       tokenOut: asset_address,   // WETH
       fee: pool_fee,             // 3000 (0.3%)
       recipient: address(this),
       amountIn: claimed,
       amountOutMinimum: min_amount_out,
       sqrtPriceLimitX96: 0
   )
   ```
6. Re-supply: `aave_pool.supply(weth, amount_out, address(this), 0)` (auto-compound)
7. Return `profit = amount_out`
8. Emits `Harvested(msg.sender, profit)`

**Modifiers**: `onlyManager`

---

#### totalAssets() → uint256

Current WETH balance in Aave (includes yield).

```solidity
function totalAssets() external view returns (uint256) {
    return a_token.balanceOf(address(this));
}
```

**Note**: aWETH rebases, balance increases automatically with yield.

---

#### apy() → uint256

Current Aave APY for WETH.

**Flow:**
1. Gets reserve data: `aave_pool.getReserveData(weth)`
2. Extracts liquidity rate (in RAY = 1e27)
3. Converts to basis points: `apy = liquidity_rate / 1e23`

**Example:**
```solidity
// liquidity_rate = 35000000000000000000000000 (RAY)
// apy = 35000000000000000000000000 / 1e23 = 350 basis points = 3.5%
```

---

### Utility Functions

```solidity
function availableLiquidity() external view returns (uint256)
    // Available liquidity in Aave for withdraws

function aTokenBalance() external view returns (uint256)
    // Strategy's aWETH balance

function pendingRewards() external view returns (uint256)
    // Pending AAVE rewards to claim
```

### Modifiers

```solidity
modifier onlyManager() {
    if (msg.sender != manager) revert AaveStrategy__OnlyManager();
    _;
}
```

### Custom Errors

```solidity
error AaveStrategy__DepositFailed();
error AaveStrategy__WithdrawFailed();
error AaveStrategy__OnlyManager();
error AaveStrategy__HarvestFailed();
error AaveStrategy__SwapFailed();
```

---

## CompoundStrategy.sol

**Location**: `src/strategies/CompoundStrategy.sol`

### Purpose

Integration with Compound v3 to deposit WETH and generate yield through lending. Includes COMP reward harvesting with automatic swap to WETH via Uniswap V3 and automatic reinvestment (auto-compound).

### Implements

- `IStrategy`: Standard strategy interface

### Called By

- **StrategyManager**: `deposit()`, `withdraw()`, `harvest()`, `totalAssets()`, `apy()`

### Calls To

- **ICometMarket (Compound v3)**: `supply()`, `withdraw()`, `balanceOf()`, `getSupplyRate()`, `getUtilization()`
- **ICometRewards (Compound v3)**: `claim()` — claims accumulated COMP tokens
- **ISwapRouter (Uniswap V3)**: `exactInputSingle()` — swap COMP → WETH
- **IERC20(WETH)**: Transfers with SafeERC20

### State Variables

```solidity
// Constants
uint256 public constant BASIS_POINTS = 10000;
uint256 public constant MAX_SLIPPAGE_BPS = 100;       // 1% max slippage on swaps

// Immutables
address public immutable manager;                       // Authorized StrategyManager
ICometMarket private immutable compound_comet;         // Compound v3 Comet
ICometRewards private immutable compound_rewards;      // Compound rewards controller
address private immutable asset_address;               // WETH
address private immutable reward_token;                // COMP token
ISwapRouter private immutable uniswap_router;          // Uniswap V3 Router
uint24 private immutable pool_fee;                     // 3000 (0.3%)
```

### Main Functions

#### deposit(uint256 assets) → uint256 shares

Deposits WETH into Compound v3.

**Precondition**: WETH must be in the strategy (transferred by manager).

**Flow:**
1. Calls `compound_comet.supply(weth, assets)`
2. Compound's internal balance increments (no cToken in v3)
3. Returns shares = assets (1:1)
4. Emits `Deposited(msg.sender, assets, shares)`

**Modifiers**: `onlyManager`

**Note**: Compound v3 uses internal accounting (no tokens), balance increases with yield.

---

#### withdraw(uint256 assets) → uint256 actual_withdrawn

Withdraws WETH from Compound v3.

**Flow:**
1. Captures `balance_before = IERC20(asset).balanceOf(address(this))`
2. Calls `compound_comet.withdraw(weth, assets)`
3. Captures `balance_after = IERC20(asset).balanceOf(address(this))`
4. Calculates `actual_withdrawn = balance_after - balance_before` (captures rounding)
5. Transfers WETH to manager: `safeTransfer(msg.sender, actual_withdrawn)`
6. Emits `Withdrawn(msg.sender, actual_withdrawn, assets)`

**Modifiers**: `onlyManager`

**Note**: Uses `balance_before/balance_after` pattern to capture the actually withdrawn amount. Compound may round down ~1-2 wei.

---

#### harvest() → uint256 profit

Harvests COMP rewards, swaps to WETH via Uniswap V3, re-invests in Compound.

**Flow:**
1. Calls `compound_rewards.claim(comet, address(this), true)` → receives COMP tokens
2. Gets `reward_amount = IERC20(reward_token).balanceOf(address(this))`
3. If no rewards → return 0
4. Calculates `min_amount_out = (reward_amount * 9900) / 10000` (1% max slippage)
5. Executes swap via Uniswap V3:
   ```solidity
   uniswap_router.exactInputSingle(
       tokenIn: reward_token,     // COMP
       tokenOut: asset_address,   // WETH
       fee: pool_fee,             // 3000 (0.3%)
       recipient: address(this),
       amountIn: reward_amount,
       amountOutMinimum: min_amount_out,
       sqrtPriceLimitX96: 0
   )
   ```
6. Re-supply: `compound_comet.supply(weth, amount_out)` (auto-compound)
7. Return `profit = amount_out`
8. Emits `Harvested(msg.sender, profit)`

**Modifiers**: `onlyManager`

---

#### totalAssets() → uint256

Current WETH balance in Compound (includes yield).

```solidity
function totalAssets() external view returns (uint256) {
    return compound_comet.balanceOf(address(this));
}
```

**Note**: Internal balance includes automatically accumulated yield.

---

#### apy() → uint256

Current Compound APY for WETH.

**Flow:**
1. Gets utilization: `utilization = compound_comet.getUtilization()`
2. Gets supply rate: `rate = compound_comet.getSupplyRate(utilization)` (uint64, per second)
3. Converts to annual APY in basis points:
   ```solidity
   // rate is in base 1e18 per second
   // APY = rate * seconds_per_year * 10000 / 1e18
   // Simplified: (rate * 315360000000) / 1e18
   apy_basis_points = (uint256(rate) * 315360000000) / 1e18;
   ```

**Example:**
```solidity
// supply_rate = 1000000000000000 (1e15 per second)
// APY = (1e15 * 315360000000) / 1e18 = 315 basis points = 3.15%
```

---

### Utility Functions

```solidity
function getSupplyRate() external view returns (uint256)
    // Current Compound supply rate (converted to uint256)

function getUtilization() external view returns (uint256)
    // Current pool utilization (borrowed / supplied)

function pendingRewards() external view returns (uint256)
    // Pending COMP rewards to claim
```

### Modifiers

```solidity
modifier onlyManager() {
    if (msg.sender != manager) revert CompoundStrategy__OnlyManager();
    _;
}
```

### Custom Errors

```solidity
error CompoundStrategy__DepositFailed();
error CompoundStrategy__WithdrawFailed();
error CompoundStrategy__OnlyManager();
error CompoundStrategy__HarvestFailed();
error CompoundStrategy__SwapFailed();
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

The interface includes `harvest()` as a required function — all VynX V1 strategies must support reward harvesting. The `actual_withdrawn` in `withdraw()` allows accounting for rounding from external protocols.

---

## ICometMarket.sol & ICometRewards.sol

**Location**: `src/interfaces/compound/ICometMarket.sol` and `src/interfaces/compound/ICometRewards.sol`

### Purpose

Simplified Compound v3 interfaces with only the functions needed for CompoundStrategy.

### Design Decision

**Why custom interfaces instead of official libraries?**
- Compound v3: Official libraries have complex and indexed dependencies
- We only need the functions we actually use
- Aave: We use official libraries because they're clean and well-structured
- Compound: Custom interface is more pragmatic (trade-off: inconsistency vs simplicity)

### ICometMarket — Functions

```solidity
function supply(address asset, uint256 amount) external;
function withdraw(address asset, uint256 amount) external;
function balanceOf(address account) external view returns (uint256 balance);
function getSupplyRate(uint256 utilization) external view returns (uint64 rate);
function getUtilization() external view returns (uint256 utilization);
```

### ICometRewards — Functions

```solidity
function claim(address comet, address src, bool shouldAccrue) external;
function getRewardOwed(address comet, address account) external returns (RewardOwed memory);
```

---

**Next reading**: [FLOWS.md](FLOWS.md) - Step-by-step user flows
