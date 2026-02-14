# System Architecture

This document describes the high-level architecture of VynX V1, explaining the contract hierarchy, the ownership flow, key design decisions, and how WETH circulates through the system.

## Overview

### What Problem Does It Solve?

Users who want to maximize their yield in DeFi face several challenges:

1. **Complexity**: Managing positions across multiple protocols (Aave, Compound, etc.) requires technical knowledge
2. **Constant monitoring**: APYs fluctuate and you have to manually rebalance to optimize returns
3. **Gas costs**: Moving funds between protocols is expensive, especially for small holdings
4. **Single protocol risk**: Being 100% in a single protocol increases risk
5. **Unclaimed rewards**: Protocols like Aave and Compound emit reward tokens that you have to claim, swap, and reinvest manually

VynX V1 solves these problems through:

- **Automated aggregation**: Users deposit once and the protocol manages multiple strategies
- **Weighted allocation**: Smart distribution based on APY (higher yield = higher percentage)
- **Smart rebalancing**: Only executes when the APY difference between strategies exceeds the threshold (2%)
- **Idle buffer**: Accumulates small deposits to amortize gas across multiple users
- **Diversification**: Spreads risk between Aave and Compound with limits (max 50%, min 10%)
- **Automated harvest**: Harvests rewards (AAVE/COMP), swap to WETH via Uniswap V3, automatic reinvestment
- **Keeper incentive system**: Anyone can execute harvest and receive 1% of the profit as incentive

### High-Level Architecture

```
User (EOA)
    |
    | deposit(WETH) / withdraw(WETH)
    v
┌─────────────────────────────────────────────────────┐
│              Vault (ERC4626)                        │
│  - Mints/burns shares (vxWETH)                      │
│  - Idle buffer (accumulates up to 10 ETH)           │
│  - Performance fee (20% on harvest profits)         │
│  - Keeper incentive system (1% for ext. keepers)    │
│  - Circuit breakers (max TVL, min deposit)          │
└─────────────────────────────────────────────────────┘
    |                                       |
    | allocate(WETH) / withdrawTo(WETH)     | harvest()
    v                                       v
┌─────────────────────────────────────────────────────┐
│           StrategyManager (Brain)                   │
│  - Calculates weighted allocation                   │
│  - Distributes according to APY                     │
│  - Executes profitable rebalances                   │
│  - Withdraws proportionally                         │
│  - Coordinates fail-safe harvest of all strategies  │
└─────────────────────────────────────────────────────┘
    |
    |--------------------+--------------------+
    |                    |                    |
    v                    v                    v
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│AaveStrategy │    │CompoundStrat│    │Future Strat │
│  (IStrategy)│    │  (IStrategy)│    │  (IStrategy)│
│  + harvest  │    │  + harvest  │    │  + harvest  │
│  + Uniswap  │    │  + Uniswap  │    │  + Uniswap  │
└─────────────┘    └─────────────┘    └─────────────┘
    |                    |                    |
    v                    v                    v
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│  Aave Pool  │    │Compound Comet│   │    New      │
│   (aWETH)   │    │  (internal) │    │  Protocol   │
└─────────────┘    └─────────────┘    └─────────────┘
    |                    |
    v                    v
┌──────────────────────────────────────────┐
│         Uniswap V3 Router                │
│  - Swap AAVE → WETH (0.3% fee)          │
│  - Swap COMP → WETH (0.3% fee)          │
│  - Max slippage: 1%                      │
└──────────────────────────────────────────┘
```

## Contract Hierarchy

### 1. Vault.sol (User Layer)

**Responsibilities:**
- ERC4626 interface for users (deposit, withdraw, mint, redeem)
- Idle buffer management (accumulation of pending WETH)
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
- `StrategyManager.withdrawTo()`: When users withdraw and idle is not enough
- `StrategyManager.harvest()`: When someone executes harvest()

**Called by:**
- Users (EOAs or contracts): deposit, withdraw, mint, redeem
- Keepers/Anyone: harvest(), allocateIdle()
- Owner: Administrative functions (pause, setters)

### 2. StrategyManager.sol (Logic Layer)

**Responsibilities:**
- Calculate weighted allocation based on strategy APY
- Distribute WETH among strategies according to calculated targets
- Execute rebalances when they are profitable
- Withdraw proportionally from strategies
- Coordinate fail-safe harvest (if one strategy fails, the rest continue)

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
- Anyone: rebalance() (if profitable)

### 3. AaveStrategy.sol & CompoundStrategy.sol (Integration Layer)

**Responsibilities:**
- Implement `IStrategy` interface
- Deposit WETH into underlying protocol
- Withdraw WETH + yield from protocol
- Report current APY of the protocol
- Report TVL under management
- **Harvest**: Claim reward tokens (AAVE/COMP), swap to WETH via Uniswap V3, reinvest

**Implements:**
- `IStrategy`: Standard interface (deposit, withdraw, harvest, totalAssets, apy, name, asset)

**Calls:**
- **AaveStrategy**: `IPool.supply()`, `IPool.withdraw()`, `IPool.getReserveData()`, `IRewardsController.claimAllRewards()`, `ISwapRouter.exactInputSingle()`
- **CompoundStrategy**: `ICometMarket.supply()`, `ICometMarket.withdraw()`, `ICometMarket.balanceOf()`, `ICometMarket.getSupplyRate()`, `ICometRewards.claim()`, `ISwapRouter.exactInputSingle()`

**Called by:**
- `StrategyManager`: deposit(), withdraw(), harvest()

## Harvest Flow

The harvest is one of the most important features of VynX V1. It coordinates the harvesting of rewards from all protocols, swap to WETH, and fee distribution.

```
Keeper / Bot / User
  └─> vault.harvest()
       │
       │ 1. Calls the strategy manager
       └─> manager.harvest()  [fail-safe: try-catch per strategy]
            │
            ├─> aave_strategy.harvest()
            │    └─> rewards_controller.claimAllRewards([aToken])
            │    └─> Receives AAVE tokens
            │    └─> uniswap_router.exactInputSingle(AAVE → WETH, 0.3% fee, 1% max slippage)
            │    └─> aave_pool.supply(weth, amount_out)  [auto-compound]
            │    └─> return profit_aave
            │
            ├─> compound_strategy.harvest()
            │    └─> compound_rewards.claim(comet, strategy, true)
            │    └─> Receives COMP tokens
            │    └─> uniswap_router.exactInputSingle(COMP → WETH, 0.3% fee, 1% max slippage)
            │    └─> compound_comet.supply(weth, amount_out)  [auto-compound]
            │    └─> return profit_compound
            │
            └─> return total_profit = profit_aave + profit_compound
       │
       │ 2. Verifies profit >= min_profit_for_harvest (0.1 ETH)
       │    If not enough → return 0 (does not distribute fees)
       │
       │ 3. Pays keeper incentive (only if not official keeper)
       │    keeper_reward = total_profit * 1% = keeper_incentive
       │    Pays from idle_buffer first, if not enough withdraws from strategies
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

### Numerical Harvest Example

**State**: TVL = 500 WETH. Aave has 250 WETH, Compound has 250 WETH.

```
1. Aave harvest:
   - Claims 50 accumulated AAVE tokens
   - Swap: 50 AAVE → 2.5 WETH (via Uniswap V3, 0.3% fee)
   - Re-supply: 2.5 WETH → Aave Pool
   - profit_aave = 2.5 WETH

2. Compound harvest:
   - Claims 100 accumulated COMP tokens
   - Swap: 100 COMP → 3.0 WETH (via Uniswap V3, 0.3% fee)
   - Re-supply: 3.0 WETH → Compound Comet
   - profit_compound = 3.0 WETH

3. total_profit = 2.5 + 3.0 = 5.5 WETH
   ✅ 5.5 >= 0.1 ETH (min_profit_for_harvest) → continues

4. Keeper incentive (caller is external keeper):
   keeper_reward = 5.5 * 100 / 10000 = 0.055 WETH
   → Transferred to the keeper

5. Net profit and performance fee:
   net_profit = 5.5 - 0.055 = 5.445 WETH
   perf_fee = 5.445 * 2000 / 10000 = 1.089 WETH

6. Performance fee distribution:
   treasury_amount = 1.089 * 8000 / 10000 = 0.8712 WETH → mints shares
   founder_amount = 1.089 * 2000 / 10000 = 0.2178 WETH → transfers WETH

7. Result:
   - TVL increases from reinvested rewards (5.5 WETH gross)
   - Keeper receives: 0.055 WETH
   - Treasury receives: shares equivalent to 0.8712 WETH (auto-compound)
   - Founder receives: 0.2178 WETH (liquid)
   - Users benefit from the rest of the compounded yield
```

## Ownership Flow

The protocol uses a hierarchical ownership model for granular control:

```
Vault Owner (EOA)
    |
    +--> Vault.pause()                          # Emergency stop
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
    +--> AaveStrategy.deposit()                 # Manager only
    +--> AaveStrategy.withdraw()                # Manager only
    +--> AaveStrategy.harvest()                 # Manager only
    +--> CompoundStrategy.deposit()             # Manager only
    +--> CompoundStrategy.withdraw()            # Manager only
    +--> CompoundStrategy.harvest()             # Manager only
         (Via onlyManager modifier)
```

**Key points:**

1. **Vault Owner ≠ Manager Owner**: They can be different EOAs for separation of concerns
2. **Only vault can call the manager**: `onlyVault` modifier protects allocate/withdrawTo/harvest
3. **Only manager can call strategies**: `onlyManager` modifier protects deposit/withdraw/harvest
4. **Anyone can execute rebalance**: If it passes the profitability check in `shouldRebalance()`
5. **Anyone can execute harvest**: External keepers receive incentive, official ones do not

## Call Chain

### Deposit Flow

```
User
  └─> vault.deposit(100 WETH)
       └─> IERC20(weth).transferFrom(user, vault, 100)
       └─> idle_buffer += 100
       └─> _mint(user, shares)
       └─> if (idle_buffer >= 10 ETH):
            └─> _allocateIdle()
                 └─> IERC20(weth).transfer(manager, 100)
                 └─> manager.allocate(100)
                      └─> _calculateTargetAllocation()
                           └─> _computeTargets() // APY-based weighted allocation
                      └─> for each strategy:
                           └─> IERC20(weth).transfer(strategy, 50)
                           └─> strategy.deposit(50)
                                └─> AaveStrategy: aave_pool.supply(weth, 50)
                                └─> CompoundStrategy: compound_comet.supply(weth, 50)
```

### Withdraw Flow

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
                           └─> AaveStrategy: aave_pool.withdraw(weth, amount)
                           └─> CompoundStrategy: compound_comet.withdraw(weth, amount)
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
       └─> Verifies TVL >= min_tvl_for_rebalance
       └─> Calculates max_apy and min_apy among strategies
       └─> return (max_apy - min_apy) >= rebalance_threshold
  └─> manager.rebalance()
       └─> _calculateTargetAllocation() // Recalculates fresh targets
       └─> for each strategy:
            └─> current_balance = strategy.totalAssets()
            └─> target_balance = (total_tvl * target) / 10000
            └─> if (current > target): Add to excess
            └─> if (target > current): Add to deficit
       └─> For strategies with excess:
            └─> strategy.withdraw(excess)
       └─> For strategies with deficit:
            └─> IERC20(weth).transfer(manager → strategy, amount)
            └─> strategy.deposit(amount)
```

## Key Architectural Decisions

### 1. Why Weighted Allocation vs All-or-Nothing?

**Decision**: Use weighted allocation (50% Aave, 50% Compound) instead of 100% in the best strategy.

**Reasons**:
- **Risk diversification**: If Aave has an exploit, we only lose 50%
- **Liquidity**: Compound might not have liquidity to absorb all the TVL
- **Educational**: Weighted allocation is more sophisticated and realistic
- **Trade-off**: We sacrifice ~0.5% APY for greater security and robustness

**Alternative considered**: All-or-nothing (100% in best APY)
- Pros: Maximizes absolute yield
- Cons: High risk, liquidity issues, more frequent rebalances

### 2. Why Idle Buffer vs Direct Deposit?

**Decision**: Accumulate deposits in a buffer until reaching 10 ETH before investing.

**Reasons**:
- **Gas optimization**: One allocate for 10 users (1 ETH each) vs 10 separate allocates
- **Shared cost**: Users share the allocation gas proportionally
- **Efficient withdrawals**: If there's idle, small withdrawals don't touch strategies (massive savings)
- **Trade-off**: WETH in idle buffer generates no yield (~0 APY during accumulation)

**Break-even analysis**:
- Allocate cost: ~300k gas x 50 gwei = 0.015 ETH
- If 10 users deposit 1 ETH each: 0.015 / 10 = 0.0015 ETH per user
- vs each user paying 0.015 ETH: 90% savings

**Alternative considered**: Direct deposit without buffer
- Pros: Immediate yield from deposit 1
- Cons: Prohibitive gas for small deposits

### 3. Why Variable Keeper Incentive?

**Decision**: Anyone can execute `harvest()` and external keepers receive 1% of the profit as incentive. Official keepers do not get paid.

**Reasons**:
- **Decentralization**: Does not depend on a single keeper to execute harvest
- **Economic incentive**: External keepers have an economic reason to monitor and execute
- **Official keepers**: The protocol can execute harvest without paying incentive (savings for users)
- **Minimum threshold**: `min_profit_for_harvest = 0.1 ETH` prevents unprofitable harvests
- **Trade-off**: 1% of profit is lost to external keepers, but guarantees execution

**Alternative considered**: Official keepers only
- Pros: No incentive costs
- Cons: Single point of failure, harvest doesn't execute if keeper goes down

### 4. Why Does Treasury Receive Shares and Founder Receives WETH?

**Decision**: Asymmetric distribution of the performance fee — treasury in shares, founder in assets.

**Reasons**:
- **Treasury (80% → shares)**: Auto-compound. Shares go up in value with each harvest, generating more compounded yield. Aligns treasury incentives with protocol growth
- **Founder (20% → WETH)**: Immediate liquidity to cover operational costs (servers, audits, development). The founder needs liquid funds, not illiquid shares
- **Trade-off**: Treasury shares are illiquid (selling would dilute other holders). Founder receives less but in liquid form

**Alternative considered**: Both in shares or both in WETH
- Both in shares: Founder can't cover costs
- Both in WETH: Treasury doesn't auto-compound, protocol grows slower

### 5. Why Tolerate Withdrawal Rounding?

**Decision**: Tolerate up to 20 wei of difference between requested and received assets when withdrawing.

**Reasons**:
- **External protocols round down**: Aave and Compound lose ~1-2 wei per operation when rounding down
- **Scalability**: With 2 strategies today and plans for ~10 in the future: 2 wei x 10 = 20 wei conservative margin
- **Cost to user**: $0.00000000000005 with ETH at $2,500 (irrelevant)
- **Balance before/after pattern**: Strategies measure `balance_after - balance_before` to capture the amount actually withdrawn
- **Trade-off**: The user absorbs the rounding cost (standard in DeFi)

**Alternative considered**: Require strict exactness
- Pros: Perfect accounting
- Cons: Frequent reverts over 1 wei, terrible UX, transactions fail

### 6. Why Custom Compound Interface vs Official Library?

**Decision**: Create custom interfaces (`ICometMarket.sol`, `ICometRewards.sol`) instead of using Compound's official libraries.

**Reasons**:
- **Simplicity**: We only need the functions we use
- **Dirty official libraries**: Complex dependencies, indexed versions, heavy structure
- **Partial consistency**: Aave has clean libraries (we use them), Compound does not (custom interface)
- **Trade-off**: Inconsistency (Aave = libraries, Compound = interface) vs pragmatism

**Aave comparison**:
- Aave: `@aave/contracts/interfaces/IPool.sol` - clean and straightforward
- Compound: Official libraries with unnecessary dependencies

### 7. Why Rebalancing Based on APY Difference?

**Decision**: Rebalance when `max_apy - min_apy >= rebalance_threshold` (2%), without on-chain gas cost calculation.

**Reasons**:
- **Simplicity**: Simple and predictable formula, easy to audit
- **Effectiveness**: If the APY difference is significant, moving funds is worth it regardless of gas
- **Gas-efficient**: No need for `tx.gasprice` on-chain or complex gas estimations
- **Trade-off**: Could execute rebalances with high gas (but the 2% threshold already filters unprofitable cases)

**Alternative considered**: Profit vs gas cost calculation on-chain (multi-strategy-vault)
- Pros: More precise
- Cons: More complex, more gas for the check itself, `tx.gasprice` not always reliable

## WETH Flow

### WETH States in the System

```
1. User EOA
   └─> WETH in user's wallet

2. Idle Buffer (vault.idle_buffer)
   └─> Physical balance in Vault
   └─> Does not generate yield
   └─> Accounting: vault.idle_buffer (state variable)

3. In Manager (temporary)
   └─> Physical balance in StrategyManager (only during allocate/rebalance)
   └─> Immediately transferred to strategies

4. In Strategies
   ├─> AaveStrategy:
   │    └─> Physical balance in Aave Pool
   │    └─> Accounting: a_token.balanceOf(strategy) (aTokens, auto-rebase)
   │    └─> Yield: Automatically included in aToken balance
   │    └─> Rewards: AAVE tokens (claimed during harvest)
   │
   └─> CompoundStrategy:
        └─> Physical balance in Compound Comet
        └─> Accounting: compound_comet.balanceOf(strategy) (internal, not a token)
        └─> Yield: Automatically included in internal balance
        └─> Rewards: COMP tokens (claimed during harvest)

5. Uniswap V3 (temporary, during harvest)
   └─> AAVE/COMP → WETH swap
   └─> 0.3% pool fee, max 1% slippage
   └─> Resulting WETH is reinvested into the protocol

6. Back to User
   └─> WETH in user's wallet (net)
```

### Accounting vs Physical Balance

It is crucial to understand that **totalAssets() is accounting, not physical balance**:

```solidity
// Vault.totalAssets()
function totalAssets() public view returns (uint256) {
    return idle_buffer + IStrategyManager(strategy_manager).totalAssets();
    // idle_buffer: Balance pending investment
    // strategy_manager.totalAssets(): Sum of assets in strategies
}

// StrategyManager.totalAssets()
function totalAssets() public view returns (uint256) {
    uint256 total = 0;
    for (uint256 i = 0; i < strategies.length; i++) {
        total += strategies[i].totalAssets(); // Strategy accounting
    }
    return total;
}

// AaveStrategy.totalAssets()
function totalAssets() external view returns (uint256) {
    return a_token.balanceOf(address(this));
    // aWETH rebases → balance increases with yield automatically
}

// CompoundStrategy.totalAssets()
function totalAssets() external view returns (uint256) {
    return compound_comet.balanceOf(address(this));
    // Compound internal balance → includes yield automatically
}
```

**Numerical example:**

User deposits 100 WETH:
1. `vault.idle_buffer = 100` (physical in vault)
2. `vault.totalAssets() = 100` (accounting)

Idle reaches threshold, allocate:
1. `vault.idle_buffer = 0` (physical moved to manager → strategies)
2. `aave_strategy balance = 50 aWETH` (physical in Aave)
3. `compound_strategy balance = 50 WETH` (physical in Compound)
4. `vault.totalAssets() = 0 + manager.totalAssets() = 100` (accounting)

After 1 month (5% APY yield):
1. `aave_strategy.totalAssets() = 50.2` (aWETH rebase includes yield)
2. `compound_strategy.totalAssets() = 50.2` (internal balance includes yield)
3. `vault.totalAssets() = 0 + 100.4 = 100.4` (accounting reflects yield)
4. User can withdraw 100.4 WETH (shares = 100 at entry price, worth more now)

Harvest executed (accumulated rewards):
1. AaveStrategy claims AAVE tokens → swap to 2.5 WETH → re-supply to Aave
2. CompoundStrategy claims COMP tokens → swap to 3.0 WETH → re-supply to Compound
3. total_profit = 5.5 WETH (reinvested, totalAssets goes up)
4. Performance fee distributed: treasury (shares), founder (WETH)

## Known Limitations

1. **WETH only**: Current architecture does not support multi-asset (planned for v2)
2. **Manual rebalancing**: Requires external keepers (not automatic on-chain)
3. **Weighted allocation v1**: Basic algorithm proportional to APY (machine learning in v3?)
4. **Single vault owner**: Ownership centralization (multisig in production)
5. **Idle buffer without yield**: Accumulated WETH does not generate returns
6. **Illiquid treasury shares**: The treasury receives shares it cannot easily sell without diluting holders
7. **Harvest depends on Uniswap liquidity**: If there is no AAVE/WETH or COMP/WETH liquidity, the swap fails
8. **Max 10 strategies**: Hard-coded limit in StrategyManager to prevent gas DoS in loops

---

**Next reading**: [CONTRACTS.md](CONTRACTS.md) - Detailed per-contract documentation
