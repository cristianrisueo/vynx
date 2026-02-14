# User Flows

This document describes the step-by-step user flows of VynX V1, with sequence diagrams and concrete numerical examples.

---

## 1. Deposit Flow

### General Description

The user deposits WETH into the vault and receives shares (vxWETH). The WETH accumulates in the idle buffer until reaching the threshold (10 ETH), at which point it auto-invests into the strategies.

### Step-by-Step Flow

```
┌─────────┐          ┌──────────┐          ┌────────────┐          ┌──────────┐          ┌───────────┐
│  User   │          │  Vault   │          │  Manager   │          │ Strategy │          │ Protocol  │
└────┬────┘          └────┬─────┘          └─────┬──────┘          └────┬─────┘          └─────┬─────┘
     │                    │                      │                       │                      │
     │ 1. approve(vault)  │                      │                       │                      │
     ├───────────────────>│                      │                       │                      │
     │                    │                      │                       │                      │
     │ 2. deposit(100)    │                      │                       │                      │
     ├───────────────────>│                      │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 3. Verifies:         │                       │                      │
     │                    │    - assets >= 0.01  │                       │                      │
     │                    │    - TVL + assets    │                       │                      │
     │                    │      <= max_tvl      │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 4. Calculates shares │                       │                      │
     │                    │    previewDeposit()  │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 5. transferFrom      │                       │                      │
     │<───────────────────┤    (user, vault, 100)│                       │                      │
     │                    │                      │                       │                      │
     │                    │ 6. idle_buffer += 100│                       │                      │
     │                    │                      │                       │                      │
     │                    │ 7. _mint(shares)     │                       │                      │
     │<───────────────────┤                      │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 8. if idle >= 10 ETH │                       │                      │
     │                    │    _allocateIdle()   │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 9. transfer(manager) │                       │                      │
     │                    ├─────────────────────>│                       │                      │
     │                    │                      │                       │                      │
     │                    │ 10. allocate(100)    │                       │                      │
     │                    ├─────────────────────>│                       │                      │
     │                    │                      │                       │                      │
     │                    │                      │ 11. _computeTargets() │                      │
     │                    │                      │     - Aave: 50%       │                      │
     │                    │                      │     - Compound: 50%   │                      │
     │                    │                      │                       │                      │
     │                    │                      │ 12. transfer(aave, 50)│                      │
     │                    │                      ├──────────────────────>│                      │
     │                    │                      │                       │                      │
     │                    │                      │ 13. deposit(50)       │                      │
     │                    │                      ├──────────────────────>│                      │
     │                    │                      │                       │ 14. supply(weth, 50) │
     │                    │                      │                       ├─────────────────────>│
     │                    │                      │                       │                      │
     │                    │                      │ 15. transfer(comp, 50)│                      │
     │                    │                      ├──────────────────────>│                      │
     │                    │                      │                       │                      │
     │                    │                      │ 16. deposit(50)       │                      │
     │                    │                      ├──────────────────────>│                      │
     │                    │                      │                       │ 17. supply(weth, 50) │
     │                    │                      │                       ├─────────────────────>│
     │                    │                      │                       │                      │
     │ 18. Deposited event│                      │                       │                      │
     │<───────────────────┤                      │                       │                      │
     │                    │                      │                       │                      │
```

### Step Details

**1-2. Approval and Deposit**
```solidity
// User approves WETH to the vault
IERC20(weth).approve(address(vault), 100 ether);

// User deposits 100 WETH
uint256 shares = vault.deposit(100 ether, msg.sender);
```

**3. Security Checks**
```solidity
// Verify minimum deposit
if (assets < min_deposit) revert Vault__DepositBelowMinimum();
// min_deposit = 0.01 ETH

// Verify circuit breaker
if (totalAssets() + assets > max_tvl) revert Vault__MaxTVLExceeded();
// max_tvl = 1000 ETH
```

**4. Shares Calculation**
```solidity
// If first deposit: shares = assets
// If TVL already exists: shares = (assets * totalSupply) / totalAssets()
shares = previewDeposit(assets);

// First deposit example:
// shares = 100 ether (1:1)

// Second deposit example (TVL already exists):
// totalSupply = 1000 shares, totalAssets = 1050 WETH (accumulated yield)
// shares = (100 * 1000) / 1050 = 95.24 shares
// The second user pays the current price that reflects the yield
```

**6. Accumulation in Idle Buffer**
```solidity
idle_buffer += assets;  // Accumulates in buffer without investing yet
```

**8-9. Auto-Allocate (Conditional)**
```solidity
if (idle_buffer >= idle_threshold) {  // threshold = 10 ETH
    _allocateIdle();
}
```

**11. Weighted Allocation Calculation**
```solidity
// Let's assume APYs:
// Aave: 5% (500 bp), Compound: 5% (500 bp)
// total_apy = 1000 bp

// Target for Aave: (500 * 10000) / 1000 = 5000 bp = 50%
// Target for Compound: (500 * 10000) / 1000 = 5000 bp = 50%

// Apply caps (max 50%, min 10%):
// Aave: 50% (within limits)
// Compound: 50% (within limits)
```

**12-17. Distribution to Strategies**
```solidity
// For each strategy:
uint256 amount_for_strategy = (assets * target) / 10000;

// Aave: (100 * 5000) / 10000 = 50 WETH
// Compound: (100 * 5000) / 10000 = 50 WETH

IERC20(asset).safeTransfer(address(strategy), amount);
strategy.deposit(amount);
```

### Full Numerical Example

**Scenario**: Alice deposits 5 ETH, Bob deposits 5 ETH (reaches threshold), Charlie deposits 5 ETH.

**Initial state:**
- `idle_buffer = 0`
- `idle_threshold = 10 ETH`

**1. Alice deposits 5 ETH**
```
idle_buffer = 5 ETH
shares_alice = 5 ETH (first deposit, 1:1)
totalSupply = 5 shares
totalAssets = 5 ETH (all in idle)

❌ NO auto-allocate (5 < 10)
```

**2. Bob deposits 5 ETH**
```
idle_buffer = 10 ETH
shares_bob = (5 * 5) / 5 = 5 shares
totalSupply = 10 shares
totalAssets = 10 ETH

✅ AUTO-ALLOCATE (10 >= 10)
  → idle_buffer = 0
  → Manager receives 10 ETH
  → Distributes: Aave 5 ETH, Compound 5 ETH
  → totalAssets = 0 (idle) + 10 (strategies) = 10 ETH
```

**3. Charlie deposits 5 ETH**
```
idle_buffer = 5 ETH
shares_charlie = (5 * 10) / 10 = 5 shares
totalSupply = 15 shares
totalAssets = 5 (idle) + 10 (strategies) = 15 ETH

❌ NO auto-allocate (5 < 10)
```

**Idle Buffer Benefit:**
- Alice and Bob shared the gas cost of 1 allocate instead of paying for 2 separate ones
- Total gas cost: ~300k gas (instead of 600k if they deposited directly)
- Savings: 50% gas for both users

---

## 2. Withdraw Flow

### General Description

The user withdraws WETH from the vault by burning shares. If there's enough WETH in the idle buffer, it's withdrawn from there (gas-efficient). If not, the vault requests funds from the manager, which withdraws proportionally from all strategies. The vault tolerates up to 20 wei of rounding due to external protocol rounding.

### Step-by-Step Flow

```
┌─────────┐          ┌──────────┐          ┌────────────┐          ┌──────────┐          ┌───────────┐
│  User   │          │  Vault   │          │  Manager   │          │ Strategy │          │ Protocol  │
└────┬────┘          └────┬─────┘          └─────┬──────┘          └────┬─────┘          └─────┬─────┘
     │                    │                      │                       │                      │
     │ 1. withdraw(100)   │                      │                       │                      │
     ├───────────────────>│                      │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 2. Calculates shares │                       │                      │
     │                    │    previewWithdraw() │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 3. Verifies allowance│                       │                      │
     │                    │    (if caller != own)│                       │                      │
     │                    │                      │                       │                      │
     │                    │ 4. _burn(shares)     │                       │                      │
     │                    │    [CEI pattern]     │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 5. from_idle = min   │                       │                      │
     │                    │    (idle_buffer, 100)│                       │                      │
     │                    │                      │                       │                      │
     │                    │ 6. if from_idle < 100│                       │                      │
     │                    │    withdrawTo(manag) │                       │                      │
     │                    ├─────────────────────>│                       │                      │
     │                    │                      │                       │                      │
     │                    │                      │ 7. for each strategy: │                      │
     │                    │                      │    proportional calc  │                      │
     │                    │                      │                       │                      │
     │                    │                      │ 8. withdraw(amount)   │                      │
     │                    │                      ├──────────────────────>│                      │
     │                    │                      │                       │ 9. withdraw(weth)    │
     │                    │                      │                       ├─────────────────────>│
     │                    │                      │                       │                      │
     │                    │                      │ 10. transfer(manager) │                      │
     │                    │                      │<──────────────────────┤                      │
     │                    │                      │                       │                      │
     │                    │ 11. transfer(vault)  │                       │                      │
     │                    │<─────────────────────┤                       │                      │
     │                    │                      │                       │                      │
     │                    │ 12. Verifies rounding│                       │                      │
     │                    │    (< 20 wei diff)   │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 13. transfer(user)   │                       │                      │
     │<───────────────────┤    amount = 100      │                       │                      │
     │                    │                      │                       │                      │
     │ 14. Withdrawn event│                      │                       │                      │
     │<───────────────────┤                      │                       │                      │
     │                    │                      │                       │                      │
```

### Step Details

**1-2. Withdrawal Request and Shares Calculation**
```solidity
// User withdraws 100 WETH
uint256 shares = vault.withdraw(100 ether, msg.sender, msg.sender);

// Calculates shares to burn (ERC4626 standard, no withdrawal fee)
shares = previewWithdraw(100 ether);
// shares = convertToShares(100) = (100 * totalSupply) / totalAssets()
```

**4. Share Burning (CEI Pattern)**
```solidity
// CRITICAL: Burns shares BEFORE transferring assets (prevents reentrancy)
_burn(owner, shares);
```

**5-6. Strategic Withdrawal (Idle first, Strategies second)**
```solidity
uint256 from_idle = assets.min(idle_buffer);
uint256 from_strategies = assets - from_idle;

if (from_idle > 0) {
    idle_buffer -= from_idle;
}

if (from_strategies > 0) {
    IStrategyManager(strategy_manager).withdrawTo(from_strategies, address(this));
}
```

**7-10. Proportional Withdrawal from Strategies**
```solidity
// Manager.withdrawTo() withdraws proportionally to maintain ratios
uint256 total_assets = totalAssets();

for (uint256 i = 0; i < strategies.length; i++) {
    uint256 strategy_balance = strategies[i].totalAssets();

    // Proportional withdrawal
    uint256 to_withdraw = (assets * strategy_balance) / total_assets;

    // Capture actual amount withdrawn (protocol rounding)
    uint256 actual_withdrawn = strategy.withdraw(to_withdraw);
    total_withdrawn += actual_withdrawn;
}

IERC20(asset).safeTransfer(receiver, total_withdrawn);
```

**12. Rounding Tolerance Verification**
```solidity
uint256 to_transfer = assets.min(balance);

if (to_transfer < assets) {
    // Tolerates up to 20 wei of difference (Aave/Compound rounding)
    require(assets - to_transfer < 20, "Excessive rounding");
}
```

**13. Transfer to User**
```solidity
IERC20(asset).safeTransfer(receiver, to_transfer);
```

### Full Numerical Example

**Scenario**: Alice withdraws 100 WETH. Vault has 5 ETH idle, rest in strategies.

**Initial state:**
```
idle_buffer = 5 ETH
Aave: 70 ETH
Compound: 30 ETH
total_assets = 105 ETH
```

**1. Alice calls withdraw(100 ETH)**
```
Alice's shares: calculates previewWithdraw(100)
```

**2. Shares calculation (ERC4626, no fee)**
```
shares = convertToShares(100)
```

**3. Burns shares (CEI pattern)**

**4. Withdrawal from idle buffer**
```
from_idle = min(5, 100) = 5 ETH
idle_buffer = 0
```

**5. Withdrawal from manager**
```
from_strategies = 100 - 5 = 95 WETH

Total in strategies = 70 + 30 = 100 WETH

From Aave: (95 * 70) / 100 = 66.5 WETH (actual: ~66.499999999999999998 due to rounding)
From Compound: (95 * 30) / 100 = 28.5 WETH (actual: ~28.499999999999999999 due to rounding)
```

**6. Rounding verification**
```
to_transfer = min(100, actual_balance)
Difference: 100 - 99.999999999999999997 = 3 wei
3 < 20 → ✅ Within tolerance
```

**7. Final state**
```
idle_buffer = 0
Aave: 70 - 66.5 = 3.5 ETH
Compound: 30 - 28.5 = 1.5 ETH
total_assets = 0 + 3.5 + 1.5 = 5 ETH

Alice receives: ~100 WETH (minus ~3 wei due to rounding)
```

**Proportional Withdrawal Benefit:**
- Does not require recalculating target allocations (gas savings)
- Maintains original ratios between strategies
- If all strategies have liquidity, the withdrawal always works

---

## 3. Harvest Flow

### General Description

The harvest collects rewards (AAVE/COMP tokens) from all strategies, converts them to WETH via Uniswap V3, auto-reinvests them, and distributes performance fees. Anyone can execute harvest -- external keepers receive 1% of the profit as an incentive, official keepers don't charge.

### Step-by-Step Flow

```
┌─────────┐          ┌──────────┐          ┌────────────┐          ┌──────────┐          ┌───────────┐
│ Keeper  │          │  Vault   │          │  Manager   │          │ Strategy │          │ Protocol  │
└────┬────┘          └────┬─────┘          └─────┬──────┘          └────┬─────┘          └─────┬─────┘
     │                    │                      │                       │                      │
     │ 1. harvest()       │                      │                       │                      │
     ├───────────────────>│                      │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 2. manager.harvest() │                       │                      │
     │                    ├─────────────────────>│                       │                      │
     │                    │                      │                       │                      │
     │                    │                      │ 3. try aave.harvest() │                      │
     │                    │                      ├──────────────────────>│                      │
     │                    │                      │                       │ 4. claimAllRewards() │
     │                    │                      │                       ├─────────────────────>│
     │                    │                      │                       │<─ AAVE tokens ───────┤
     │                    │                      │                       │                      │
     │                    │                      │                       │ 5. swap AAVE → WETH  │
     │                    │                      │                       │   via Uniswap V3     │
     │                    │                      │                       │   (0.3% fee, 1% slip)│
     │                    │                      │                       │                      │
     │                    │                      │                       │ 6. supply(weth)      │
     │                    │                      │                       ├─────────────────────>│
     │                    │                      │                       │   [auto-compound]    │
     │                    │                      │                       │                      │
     │                    │                      │ 7. return profit_aave │                      │
     │                    │                      │<──────────────────────┤                      │
     │                    │                      │                       │                      │
     │                    │                      │ 8. try comp.harvest() │                      │
     │                    │                      ├──────────────────────>│                      │
     │                    │                      │                       │ 9. claim(comet)      │
     │                    │                      │                       ├─────────────────────>│
     │                    │                      │                       │<─ COMP tokens ───────┤
     │                    │                      │                       │                      │
     │                    │                      │                       │ 10. swap COMP → WETH │
     │                    │                      │                       │   via Uniswap V3     │
     │                    │                      │                       │                      │
     │                    │                      │                       │ 11. supply(weth)     │
     │                    │                      │                       ├─────────────────────>│
     │                    │                      │                       │   [auto-compound]    │
     │                    │                      │                       │                      │
     │                    │                      │ 12. return profit_comp│                      │
     │                    │                      │<──────────────────────┤                      │
     │                    │                      │                       │                      │
     │                    │ 13. total_profit     │                       │                      │
     │                    │<─────────────────────┤                       │                      │
     │                    │                      │                       │                      │
     │                    │ 14. if profit >=     │                       │                      │
     │                    │     0.1 ETH:         │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 15. Pays keeper      │                       │                      │
     │<───────────────────┤     incentive (1%)   │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 16. Calculates perf  │                       │                      │
     │                    │     fee (20% net     │                       │                      │
     │                    │     profit)          │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 17. Mint shares      │                       │                      │
     │                    │     → treasury (80%) │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 18. Transfer WETH    │                       │                      │
     │                    │     → founder (20%)  │                       │                      │
     │                    │                      │                       │                      │
     │ 19. Harvested event│                      │                       │                      │
     │<───────────────────┤                      │                       │                      │
     │                    │                      │                       │                      │
```

### Step Details

**1. Anyone Can Execute Harvest**
```solidity
// External keeper (receives 1% incentive)
vault.harvest();

// Official keeper (does not receive incentive)
vault.harvest();

// It doesn't matter who calls -- the only difference is whether they charge an incentive
```

**2-12. Fail-Safe Harvest in StrategyManager**
```solidity
// Manager iterates all strategies with try-catch
uint256 total_profit = 0;

for (uint256 i = 0; i < strategies.length; i++) {
    try strategies[i].harvest() returns (uint256 profit) {
        total_profit += profit;
    } catch Error(string memory reason) {
        // If one fails, the others continue
        emit HarvestFailed(address(strategies[i]), reason);
    }
}

return total_profit;
```

**3-6. AaveStrategy.harvest() (inside the try)**
```solidity
// 1. Claims AAVE rewards
address[] memory assets = new address[](1);
assets[0] = address(a_token);
(, uint256[] memory amounts) = rewards_controller.claimAllRewards(assets, address(this));

// 2. If no rewards → return 0
uint256 claimed = amounts[0];
if (claimed == 0) return 0;

// 3. Calculate slippage protection
uint256 min_amount_out = (claimed * 9900) / 10000;  // 1% max slippage

// 4. Swap AAVE → WETH via Uniswap V3
uint256 amount_out = uniswap_router.exactInputSingle(
    ISwapRouter.ExactInputSingleParams({
        tokenIn: reward_token,        // AAVE
        tokenOut: asset_address,      // WETH
        fee: pool_fee,                // 3000 (0.3%)
        recipient: address(this),
        amountIn: claimed,
        amountOutMinimum: min_amount_out,
        sqrtPriceLimitX96: 0
    })
);

// 5. Auto-compound: re-supply WETH to Aave
aave_pool.supply(asset_address, amount_out, address(this), 0);

return amount_out;  // profit
```

**14-18. Fee Distribution in Vault**
```solidity
// Verify minimum profit
if (profit < min_profit_for_harvest) return 0;  // 0.1 ETH

// Pay external keeper (only if not official)
uint256 keeper_reward = 0;
if (!is_official_keeper[msg.sender]) {
    keeper_reward = (profit * keeper_incentive) / BASIS_POINTS;  // 1%
    IERC20(asset).safeTransfer(msg.sender, keeper_reward);
}

// Calculate performance fee on net profit
uint256 net_profit = profit - keeper_reward;
uint256 perf_fee = (net_profit * performance_fee) / BASIS_POINTS;  // 20%

// Distribute:
// Treasury (80% perf fee) → mints shares (auto-compound)
uint256 treasury_amount = (perf_fee * treasury_split) / BASIS_POINTS;
uint256 treasury_shares = convertToShares(treasury_amount);
_mint(treasury_address, treasury_shares);

// Founder (20% perf fee) → transfers WETH (liquid)
uint256 founder_amount = (perf_fee * founder_split) / BASIS_POINTS;
IERC20(asset).safeTransfer(founder_address, founder_amount);
```

### Full Numerical Example

**Scenario**: External keeper executes harvest after 1 month of accumulation.

**Initial state:**
```
TVL = 500 WETH
Aave: 250 WETH + accumulated AAVE rewards
Compound: 250 WETH + accumulated COMP rewards
idle_buffer = 2 ETH
```

**1. StrategyManager.harvest() (fail-safe)**
```
AaveStrategy.harvest():
  - Claims: 50 AAVE tokens
  - Swap: 50 AAVE → 2.5 WETH (Uniswap V3, 0.3% fee)
  - Min amount out: 50 * 9900 / 10000 = 49.5 AAVE equiv (1% slippage)
  - Re-supply: 2.5 WETH → Aave Pool
  - profit_aave = 2.5 WETH

CompoundStrategy.harvest():
  - Claims: 100 COMP tokens
  - Swap: 100 COMP → 3.0 WETH (Uniswap V3, 0.3% fee)
  - Re-supply: 3.0 WETH → Compound Comet
  - profit_compound = 3.0 WETH

total_profit = 2.5 + 3.0 = 5.5 WETH
```

**2. Threshold verification**
```
5.5 WETH >= 0.1 ETH (min_profit_for_harvest)
✅ Continues with distribution
```

**3. Payment to external keeper**
```
keeper_reward = 5.5 * 100 / 10000 = 0.055 WETH
→ Pays from idle_buffer (2 ETH available, only needs 0.055)
→ idle_buffer = 2 - 0.055 = 1.945 ETH
→ Transfers 0.055 WETH to the keeper
```

**4. Performance fee**
```
net_profit = 5.5 - 0.055 = 5.445 WETH
perf_fee = 5.445 * 2000 / 10000 = 1.089 WETH
```

**5. Performance fee distribution**
```
treasury_amount = 1.089 * 8000 / 10000 = 0.8712 WETH
→ Mints shares equivalent to 0.8712 WETH to treasury_address
→ Shares auto-compound (increase in value with each future harvest)

founder_amount = 1.089 * 2000 / 10000 = 0.2178 WETH
→ Withdraws from idle_buffer: 1.945 - 0.2178 = 1.7272 ETH remaining
→ Transfers 0.2178 WETH to founder_address
```

**6. Final state**
```
TVL = 500 + 5.5 (reinvested rewards) = 505.5 WETH
idle_buffer = 1.7272 ETH
Aave: 252.5 WETH
Compound: 253.0 WETH

Keeper received: 0.055 WETH
Treasury received: shares for 0.8712 WETH
Founder received: 0.2178 WETH
Users benefit: compounded yield in strategies
```

**If the caller were an official keeper:**
```
keeper_reward = 0 (official, doesn't charge)
net_profit = 5.5 WETH (no discount)
perf_fee = 5.5 * 2000 / 10000 = 1.1 WETH
treasury_amount = 0.88 WETH (more for the protocol)
founder_amount = 0.22 WETH (more for the founder)
```

---

## 4. Rebalance Flow

### General Description

When APYs change, the optimal distribution changes. A keeper (bot or user) can execute rebalance() to move funds between strategies. The rebalance only executes if the APY difference between the best and worst strategy exceeds the 2% threshold.

### Step-by-Step Flow

```
┌─────────┐          ┌────────────┐          ┌──────────┐          ┌───────────┐
│ Keeper  │          │  Manager   │          │ Strategy │          │ Protocol  │
└────┬────┘          └─────┬──────┘          └────┬─────┘          └─────┬─────┘
     │                     │                       │                      │
     │ 1. shouldRebalance()│                       │                      │
     ├────────────────────>│                       │                      │
     │                     │                       │                      │
     │                     │ 2. Verifies:          │                      │
     │                     │    - >= 2 strategies   │                      │
     │                     │    - TVL >= 10 ETH    │                      │
     │                     │    - max_apy - min_apy│                      │
     │                     │      >= 200 bp (2%)   │                      │
     │                     │                       │                      │
     │<────────────────────┤ 3. return true/false  │                      │
     │                     │                       │                      │
     │ 4. rebalance()      │                       │                      │
     ├────────────────────>│                       │                      │
     │                     │                       │                      │
     │                     │ 5. shouldRebalance()  │                      │
     │                     │    [reverts if false] │                      │
     │                     │                       │                      │
     │                     │ 6. Recalculates       │                      │
     │                     │    targets             │                      │
     │                     │    _calculateTargets()│                      │
     │                     │                       │                      │
     │                     │ 7. for excess strats: │                      │
     │                     │     withdraw(excess)  │                      │
     │                     ├──────────────────────>│                      │
     │                     │                       │ 8. withdraw(weth)    │
     │                     │                       ├─────────────────────>│
     │                     │                       │                      │
     │                     │ 9. transfer(manager)  │                      │
     │                     │<──────────────────────┤                      │
     │                     │                       │                      │
     │                     │ 10. for needed strats:│                      │
     │                     │     transfer(strategy)│                      │
     │                     ├──────────────────────>│                      │
     │                     │                       │                      │
     │                     │ 11. deposit(amount)   │                      │
     │                     ├──────────────────────>│                      │
     │                     │                       │ 12. supply(weth)     │
     │                     │                       ├─────────────────────>│
     │                     │                       │                      │
     │ 13. Rebalanced event│                       │                      │
     │<────────────────────┤                       │                      │
     │                     │                       │                      │
```

### Step Details

**1. Profitability Check**
```solidity
// Keeper calls view function first (off-chain check)
bool should = manager.shouldRebalance();

if (should) {
    manager.rebalance();
}
```

**2. shouldRebalance() Logic**
```solidity
// Requires >= 2 strategies
if (strategies.length < 2) return false;

// Requires minimum TVL
if (totalAssets() < min_tvl_for_rebalance) return false;  // 10 ETH

// Calculate APY difference
uint256 max_apy = 0;
uint256 min_apy = type(uint256).max;

for (uint256 i = 0; i < strategies.length; i++) {
    uint256 apy = strategies[i].apy();
    if (apy > max_apy) max_apy = apy;
    if (apy < min_apy) min_apy = apy;
}

// Rebalance if difference >= 2% (200 bp)
return (max_apy - min_apy) >= rebalance_threshold;
```

### Full Numerical Example

**Scenario**: Compound APY rises from 5% to 8%, rebalance becomes profitable.

**Initial state (50/50 targets):**
```
Aave: 50 WETH (5% APY = 500 bp)
Compound: 50 WETH (5% APY = 500 bp)
total_tvl = 100 WETH
```

**Market change:**
```
Aave: 5% APY (no change, 500 bp)
Compound: 8% APY (rose 3%, 800 bp)
```

**1. Keeper calls shouldRebalance()**
```
max_apy = 800 bp (Compound)
min_apy = 500 bp (Aave)
difference = 800 - 500 = 300 bp

300 >= 200 (rebalance_threshold)
✅ shouldRebalance = true
```

**2. Keeper executes rebalance()**
```
Recalculates targets:
- total_apy = 500 + 800 = 1300 bp
- Aave: (500 * 10000) / 1300 = 3846 bp = 38.46%
- Compound: (800 * 10000) / 1300 = 6154 bp = 61.54%

Target balances:
- Aave: 100 * 38.46% = 38.46 WETH
- Compound: 100 * 61.54% = 61.54 WETH

Deltas:
- Aave: 50 - 38.46 = +11.54 WETH (excess)
- Compound: 50 - 61.54 = -11.54 WETH (needs more)
```

**3. Rebalance execution**
```
Movement:
1. Withdraws 11.54 WETH from Aave (aave_pool.withdraw)
2. Transfers 11.54 WETH to CompoundStrategy
3. Deposits 11.54 WETH into Compound (compound_comet.supply)

Final state:
- Aave: 38.46 WETH (38.46%)
- Compound: 61.54 WETH (61.54%)
- Funds now generate more yield by being better distributed
```

**Scenario where rebalance does not happen:**
```
Aave: 4% APY (400 bp)
Compound: 5% APY (500 bp)
difference = 500 - 400 = 100 bp

100 < 200 (rebalance_threshold)
❌ shouldRebalance = false → Not worth moving funds
```

---

## 5. Idle Buffer Allocation Flow

### General Description

The idle buffer accumulates small deposits to save gas. Multiple users share the cost of a single allocate.

### 3-User Example

**Configuration:**
- `idle_threshold = 10 ETH`
- `idle_buffer = 0` initial

**User 1: Alice deposits 5 ETH**
```
State before:
  idle_buffer = 0

Alice.deposit(5 ETH)
  → idle_buffer = 5 ETH
  → shares_alice = 5
  → totalAssets = 5 ETH (all in idle)

Check: idle_buffer (5) < threshold (10)
❌ NO auto-allocate

State after:
  idle_buffer = 5 ETH (accumulating)
  totalAssets = 5 ETH
```

**User 2: Bob deposits 5 ETH**
```
State before:
  idle_buffer = 5 ETH

Bob.deposit(5 ETH)
  → idle_buffer = 10 ETH
  → shares_bob = (5 * 5) / 5 = 5
  → totalAssets = 10 ETH

Check: idle_buffer (10) >= threshold (10)
✅ AUTO-ALLOCATE!

_allocateIdle():
  1. to_allocate = 10 ETH
  2. idle_buffer = 0
  3. Transfer 10 ETH to manager
  4. manager.allocate(10 ETH)
     → Aave receives 5 ETH
     → Compound receives 5 ETH

State after:
  idle_buffer = 0
  Aave: 5 ETH
  Compound: 5 ETH
  totalAssets = 0 + 5 + 5 = 10 ETH
```

**User 3: Charlie deposits 5 ETH**
```
State before:
  idle_buffer = 0
  Aave: 5 ETH
  Compound: 5 ETH

Charlie.deposit(5 ETH)
  → idle_buffer = 5 ETH
  → shares_charlie = (5 * 10) / 10 = 5
  → totalAssets = 5 + 5 + 5 = 15 ETH

Check: idle_buffer (5) < threshold (10)
❌ NO auto-allocate (cycle repeats)

State after:
  idle_buffer = 5 ETH (accumulating again)
  Aave: 5 ETH
  Compound: 5 ETH
  totalAssets = 15 ETH
```

### Gas Analysis

**Without idle buffer (3 separate allocates):**
```
Alice: 300k gas * 50 gwei = 0.015 ETH
Bob: 300k gas * 50 gwei = 0.015 ETH
Charlie: 300k gas * 50 gwei = 0.015 ETH

Total gas: 900k
Total cost: 0.045 ETH
```

**With idle buffer (1 shared allocate for Alice + Bob):**
```
Alice: 0 ETH (no allocate)
Bob: 300k gas * 50 gwei = 0.015 ETH (triggers allocate for Alice + Bob)
Charlie: 0 ETH (no allocate yet)

Total gas: 300k
Total cost: 0.015 ETH

Savings: 0.045 - 0.015 = 0.03 ETH (66% savings)
Cost per user: 0.015 / 2 = 0.0075 ETH
```

### Manual Allocate Flow

**Anyone can call allocateIdle() if idle >= threshold:**
```solidity
// Keeper sees that idle_buffer = 10 ETH
vault.allocateIdle();

// Vault executes:
if (idle_buffer < idle_threshold) revert Vault__InsufficientIdleBuffer();
_allocateIdle();
```

---

## Flow Summary

| Flow | Trigger | Auto/Manual | Gas Optimization | Fee |
|------|---------|-------------|------------------|-----|
| **Deposit** | User deposits | Auto if idle >= 10 ETH | Idle buffer (50-66% savings) | None |
| **Withdraw** | User withdraws | Manual (user calls) | Withdraws from idle first | None (only rounding ~wei) |
| **Harvest** | Keeper/Anyone | Manual (incentivized) | Fail-safe, auto-compound | 20% perf fee + 1% keeper |
| **Rebalance** | APY changes > 2% | Manual (keeper/anyone) | Only if APY diff >= threshold | None |
| **Idle Allocate** | idle >= threshold | Auto on deposit, or manual | Amortizes gas across users | None |

---

**Next reading**: [SECURITY.md](SECURITY.md) - Security considerations and implemented protections
