# User Flows

This document describes the step-by-step user flows of VynX V1, with sequence diagrams and concrete numerical examples.

---

## 1. Deposit Flow

### Overview

The user deposits WETH into the vault and receives shares (vxWETH). The WETH accumulates in the idle buffer until it reaches the configurable threshold per tier (8 ETH Balanced / 12 ETH Aggressive), at which point it is auto-invested into the strategies of the corresponding tier.

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
     │                    │ 3. Verifica:         │                       │                      │
     │                    │    - assets >= 0.01  │                       │                      │
     │                    │    - TVL + assets    │                       │                      │
     │                    │      <= max_tvl      │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 4. Calcula shares    │                       │                      │
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
     │                    │ 8. if idle >=        │                       │                      │
     │                    │    idle_threshold    │                       │                      │
     │                    │    (8-12 ETH)        │                       │                      │
     │                    │    _allocateIdle()   │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 9. transfer(manager) │                       │                      │
     │                    ├─────────────────────>│                       │                      │
     │                    │                      │                       │                      │
     │                    │ 10. allocate(100)    │                       │                      │
     │                    ├─────────────────────>│                       │                      │
     │                    │                      │                       │                      │
     │                    │                      │ 11. _computeTargets() │                      │
     │                    │                      │  [Balanced tier]      │                      │
     │                    │                      │  - Lido:   ~26.67%    │                      │
     │                    │                      │  - Aave:   ~33.33%    │                      │
     │                    │                      │  - Curve:  ~40.00%    │                      │
     │                    │                      │  [Aggressive tier]    │                      │
     │                    │                      │  - Curve:     50%     │                      │
     │                    │                      │  - UniswapV3: 50%     │                      │
     │                    │                      │                       │                      │
     │                    │                      │ 12. transfer(lido/    │                      │
     │                    │                      │     curve, amount)    │                      │
     │                    │                      ├──────────────────────>│                      │
     │                    │                      │                       │                      │
     │                    │                      │ 13. deposit(amount)   │                      │
     │                    │                      ├──────────────────────>│                      │
     │                    │                      │                       │ 14. unwrap/stake/    │
     │                    │                      │                       │     supply/mint      │
     │                    │                      │                       ├─────────────────────>│
     │                    │                      │                       │                      │
     │                    │                      │ 15. transfer(next     │                      │
     │                    │                      │     strategy, amount) │                      │
     │                    │                      ├──────────────────────>│                      │
     │                    │                      │                       │                      │
     │                    │                      │ 16. deposit(amount)   │                      │
     │                    │                      ├──────────────────────>│                      │
     │                    │                      │                       │ 17. unwrap/stake/    │
     │                    │                      │                       │     supply/mint      │
     │                    │                      │                       ├─────────────────────>│
     │                    │                      │                       │                      │
     │ 18. Deposited event│                      │                       │                      │
     │<───────────────────┤                      │                       │                      │
     │                    │                      │                       │                      │
```

### Step Detail

**1-2. Approval and Deposit**
```solidity
// User approves WETH to the vault
IERC20(weth).approve(address(vault), 100 ether);

// User deposits 100 WETH
uint256 shares = vault.deposit(100 ether, msg.sender);
```

**3. Security Checks**
```solidity
// Checks minimum deposit
if (assets < min_deposit) revert Vault__DepositBelowMinimum();
// min_deposit = 0.01 ETH

// Checks circuit breaker
if (totalAssets() + assets > max_tvl) revert Vault__MaxTVLExceeded();
// max_tvl = 1000 ETH
```

**4. Shares Calculation**
```solidity
// If it's the first deposit: shares = assets
// If TVL already exists: shares = (assets * totalSupply) / totalAssets()
shares = previewDeposit(assets);

// First deposit example:
// shares = 100 ether (1:1)

// Second deposit example (TVL already exists):
// totalSupply = 1000 shares, totalAssets = 1050 WETH (accumulated yield)
// shares = (100 * 1000) / 1050 = 95.24 shares
// The second user pays the current price that reflects the yield
```

**6. Idle Buffer Accumulation**
```solidity
idle_buffer += assets;  // Accumulates in buffer without investing yet
```

**8-9. Auto-Allocate (Conditional)**
```solidity
if (idle_buffer >= idle_threshold) {  // threshold: 8 ETH (Balanced) / 12 ETH (Aggressive)
    _allocateIdle();
}
```

**11. Weighted Allocation Calculation (Balanced tier example)**
```solidity
// Assume APYs (Balanced tier):
// Lido: 4% (400 bp), Aave: 5% (500 bp), Curve: 6% (600 bp)
// total_apy = 1500 bp

// Target for Lido:  (400 * 10000) / 1500 = 2667 bp = 26.67%
// Target for Aave:  (500 * 10000) / 1500 = 3333 bp = 33.33%
// Target for Curve: (600 * 10000) / 1500 = 4000 bp = 40.00%

// Applies caps (max 50%, min 20%):
// Lido:  26.67% (within limits)
// Aave:  33.33% (within limits)
// Curve: 40.00% (within limits)
```

**12-17. Distribution to Strategies**
```solidity
// For each strategy:
uint256 amount_for_strategy = (assets * target) / 10000;

// Balanced tier (100 WETH):
// Lido:  (100 * 2667) / 10000 = 26.67 WETH → WETH → unwrap ETH → Lido stETH → wrap wstETH
// Aave:  (100 * 3333) / 10000 = 33.33 WETH → WETH → unwrap → Lido stETH → wstETH → Aave supply → aWstETH
// Curve: (100 * 4000) / 10000 = 40.00 WETH → WETH → unwrap → 50% to stETH → add_liquidity → gauge stake

IERC20(asset).safeTransfer(address(strategy), amount);
strategy.deposit(amount);
```

### Complete Numerical Example

**Scenario**: Alice deposits 4 ETH, Bob deposits 4 ETH (Balanced threshold of 8 ETH not yet reached), Carol deposits 4 ETH (threshold is reached).

**Initial state:**
- `idle_buffer = 0`
- `idle_threshold: 8 ETH (Balanced) / 12 ETH (Aggressive)`

**1. Alice deposits 4 ETH**
```
idle_buffer = 4 ETH
shares_alice = 4 ETH (first deposit, 1:1)
totalSupply = 4 shares
totalAssets = 4 ETH (all in idle)

NO auto-allocate (4 < 8)
```

**2. Bob deposits 4 ETH**
```
idle_buffer = 8 ETH
shares_bob = (4 * 4) / 4 = 4 shares
totalSupply = 8 shares
totalAssets = 8 ETH

AUTO-ALLOCATE (8 >= 8, Balanced threshold)
  → idle_buffer = 0
  → Manager receives 8 ETH
  → Distributes (Balanced): Lido 2.67 ETH, Aave 3.33 ETH, Curve 4 ETH (approx. 26.67/33.33/40%)
  → totalAssets = 0 (idle) + 10 (strategies) = 10 ETH
```

**3. Charlie deposits 5 ETH**
```
idle_buffer = 5 ETH
shares_charlie = (5 * 8) / 8 = 5 shares
totalSupply = 13 shares
totalAssets = 5 (idle) + 10 (strategies) = 15 ETH

NO auto-allocate (5 < 8)
```

**Idle Buffer Benefit:**
- Alice and Bob shared the gas cost of 1 allocate instead of paying 2 separate ones
- Total gas cost: ~300k gas (instead of 600k if they deposited directly)
- Savings: 50% gas for both users

---

## 2. Withdrawal Flow

### Overview

The user withdraws WETH from the vault by burning shares. If there is enough WETH in the idle buffer, it is withdrawn from there (gas-efficient). If not, the vault requests funds from the manager, which withdraws proportionally from all strategies. The vault tolerates up to 20 wei of rounding from external protocol rounding.

> **Security Note**: `withdraw()` and `redeem()` work **always**, even when the vault is paused. In DeFi, pausing blocks entries (deposit, mint) but never exits: a user must be able to recover their funds regardless of the vault's state.

### Step-by-Step Flow

```
┌─────────┐          ┌──────────┐          ┌────────────┐          ┌──────────┐          ┌───────────┐
│  User   │          │  Vault   │          │  Manager   │          │ Strategy │          │ Protocol  │
└────┬────┘          └────┬─────┘          └─────┬──────┘          └────┬─────┘          └─────┬─────┘
     │                    │                      │                       │                      │
     │ 1. withdraw(100)   │                      │                       │                      │
     ├───────────────────>│                      │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 2. Calcula shares    │                       │                      │
     │                    │    previewWithdraw() │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 3. Verifica allowance│                       │                      │
     │                    │    (si caller != own)│                       │                      │
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
     │                    │ 12. Verifica rounding│                       │                      │
     │                    │    (< 20 wei diff)   │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 13. transfer(user)   │                       │                      │
     │<───────────────────┤    amount = 100      │                       │                      │
     │                    │                      │                       │                      │
     │ 14. Withdrawn event│                      │                       │                      │
     │<───────────────────┤                      │                       │                      │
     │                    │                      │                       │                      │
```

### Step Detail

**1-2. Withdrawal Request and Shares Calculation**
```solidity
// User withdraws 100 WETH
uint256 shares = vault.withdraw(100 ether, msg.sender, msg.sender);

// Calculates shares to burn (ERC4626 standard, no withdrawal fee)
shares = previewWithdraw(100 ether);
// shares = convertToShares(100) = (100 * totalSupply) / totalAssets()
```

**4. Shares Burn (CEI Pattern)**
```solidity
// CRITICAL: Burns shares BEFORE transferring assets (prevents reentrancy)
_burn(owner, shares);
```

**5-6. Strategic Withdrawal (Idle first, then Strategies)**
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
// In V1 there can be up to 3 strategies (Balanced) or 2 (Aggressive)
uint256 total_assets = totalAssets();

for (uint256 i = 0; i < strategies.length; i++) {
    uint256 strategy_balance = strategies[i].totalAssets();

    // Proportional withdrawal
    uint256 to_withdraw = (assets * strategy_balance) / total_assets;

    // Captures actual amount withdrawn (protocol rounding)
    uint256 actual_withdrawn = strategy.withdraw(to_withdraw);
    total_withdrawn += actual_withdrawn;
}

IERC20(asset).safeTransfer(receiver, total_withdrawn);
```

Each strategy converts its position to WETH before returning funds:
- **LidoStrategy**: wstETH → swap to WETH via Uniswap V3
- **AaveStrategy**: aWstETH → Aave withdraw → wstETH → swap to WETH via Uniswap V3
- **CurveStrategy**: gauge unstake → remove_liquidity_one_coin → ETH → wrap to WETH
- **UniswapV3Strategy**: decrease liquidity → collect → swap USDC to WETH if needed

**12. Rounding Tolerance Check**
```solidity
uint256 to_transfer = assets.min(balance);

if (to_transfer < assets) {
    // Tolerates up to 20 wei of difference (Aave/Lido/Curve rounding)
    require(assets - to_transfer < 20, "Excessive rounding");
}
```

**13. Transfer to User**
```solidity
IERC20(asset).safeTransfer(receiver, to_transfer);
```

### Complete Numerical Example

**Scenario**: Alice withdraws 100 WETH. Balanced Vault has 5 ETH idle, rest in strategies.

**Initial state:**
```
idle_buffer = 5 ETH
LidoStrategy:  35 ETH
AaveStrategy:  35 ETH
CurveStrategy: 30 ETH
total_assets = 105 ETH
```

**1. Alice calls withdraw(100 ETH)**
```
Alice's Shares: calculates previewWithdraw(100)
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

Total in strategies = 35 + 35 + 30 = 100 WETH

From LidoStrategy:  (95 * 35) / 100 = 33.25 WETH (wstETH → Uniswap V3 → WETH)
From AaveStrategy:  (95 * 35) / 100 = 33.25 WETH (aWstETH → Aave withdraw → wstETH → Uniswap V3 → WETH)
From CurveStrategy: (95 * 30) / 100 = 28.50 WETH (gauge unstake → remove_liquidity_one_coin → ETH → wrap WETH)
```

**6. Rounding check**
```
to_transfer = min(100, actual_balance)
Difference: 100 - 99.999999999999999997 = 3 wei
3 < 20 → Within tolerance
```

**7. Final state**
```
idle_buffer = 0
LidoStrategy:  35 - 33.25 = 1.75 ETH
AaveStrategy:  35 - 33.25 = 1.75 ETH
CurveStrategy: 30 - 28.50 = 1.50 ETH
total_assets = 0 + 1.75 + 1.75 + 1.50 = 5 ETH

Alice receives: ~100 WETH (minus ~3 wei for rounding)
```

**Proportional Withdrawal Benefit:**
- Does not require recalculating target allocations (gas savings)
- Maintains original ratios between strategies
- If all strategies have liquidity, the withdrawal always works

---

## 3. Harvest Flow

### Overview

Harvest collects rewards from all active strategies, converts them to WETH, and automatically reinvests them in each strategy. Each strategy in V1 has a different harvest mechanism. LidoStrategy does not generate active rewards (yield comes from the wstETH/stETH exchange rate). AaveStrategy, CurveStrategy, and UniswapV3Strategy do generate harvestable rewards. Anyone can execute harvest — external keepers receive 1% of the profit as an incentive, official keepers do not charge.

The minimum profit threshold for a harvest to be profitable is configurable per tier: `min_profit_for_harvest: 0.08 ETH (Balanced) / 0.12 ETH (Aggressive)`.

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
     │                    │                      │ 3. try lido.harvest() │                      │
     │                    │                      ├──────────────────────>│                      │
     │                    │                      │                       │ (yield via exchange  │
     │                    │                      │                       │  rate, no tx needed) │
     │                    │                      │ 4. return 0           │                      │
     │                    │                      │<──────────────────────┤                      │
     │                    │                      │                       │                      │
     │                    │                      │ 5. try aave.harvest() │                      │
     │                    │                      ├──────────────────────>│                      │
     │                    │                      │                       │ 6. claimAllRewards() │
     │                    │                      │                       ├─────────────────────>│
     │                    │                      │                       │<─ AAVE tokens ───────┤
     │                    │                      │                       │                      │
     │                    │                      │                       │ 7. swap AAVE → WETH  │
     │                    │                      │                       │   via Uniswap V3     │
     │                    │                      │                       │                      │
     │                    │                      │                       │ 8. WETH → wstETH     │
     │                    │                      │                       │   via Lido + wrap    │
     │                    │                      │                       │                      │
     │                    │                      │                       │ 9. supply(wstETH)    │
     │                    │                      │                       ├─────────────────────>│
     │                    │                      │                       │   [auto-compound]    │
     │                    │                      │                       │                      │
     │                    │                      │ 10. return profit_aave│                      │
     │                    │                      │<──────────────────────┤                      │
     │                    │                      │                       │                      │
     │                    │                      │11. try curve.harvest()│                      │
     │                    │                      ├──────────────────────>│                      │
     │                    │                      │                       │12. gauge.claim_rewards│
     │                    │                      │                       ├─────────────────────>│
     │                    │                      │                       │<─ CRV tokens ────────┤
     │                    │                      │                       │                      │
     │                    │                      │                       │13. swap CRV → WETH   │
     │                    │                      │                       │   via Uniswap V3     │
     │                    │                      │                       │                      │
     │                    │                      │                       │14. WETH → stETH →    │
     │                    │                      │                       │    add_liquidity →   │
     │                    │                      │                       │    stake en gauge    │
     │                    │                      │                       ├─────────────────────>│
     │                    │                      │                       │   [auto-compound]    │
     │                    │                      │                       │                      │
     │                    │                      │15. return profit_curve│                      │
     │                    │                      │<──────────────────────┤                      │
     │                    │                      │                       │                      │
     │                    │                      │16. try uni.harvest()  │                      │
     │                    │                      ├──────────────────────>│                      │
     │                    │                      │                       │17. collect(fees)     │
     │                    │                      │                       ├─────────────────────>│
     │                    │                      │                       │<─ WETH + USDC ───────┤
     │                    │                      │                       │                      │
     │                    │                      │                       │18. swap USDC → WETH  │
     │                    │                      │                       │   via Uniswap V3     │
     │                    │                      │                       │                      │
     │                    │                      │                       │19. reinvest: mint    │
     │                    │                      │                       │    new LP position   │
     │                    │                      │                       ├─────────────────────>│
     │                    │                      │                       │   [auto-compound]    │
     │                    │                      │                       │                      │
     │                    │                      │20. return profit_uni  │                      │
     │                    │                      │<──────────────────────┤                      │
     │                    │                      │                       │                      │
     │                    │ 21. total_profit     │                       │                      │
     │                    │<─────────────────────┤                       │                      │
     │                    │                      │                       │                      │
     │                    │ 22. if profit >=     │                       │                      │
     │                    │  min_profit_for_harv │                       │                      │
     │                    │  (0.08/0.12 ETH):    │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 23. Pays keeper      │                       │                      │
     │<───────────────────┤     incentive (1%)   │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 24. Calculates perf  │                       │                      │
     │                    │     fee (20% net     │                       │                      │
     │                    │     profit)          │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 25. Mint shares      │                       │                      │
     │                    │     → treasury (80%) │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 26. Transfer WETH    │                       │                      │
     │                    │     → founder (20%)  │                       │                      │
     │                    │                      │                       │                      │
     │ 27. Harvested event│                      │                       │                      │
     │<───────────────────┤                      │                       │                      │
     │                    │                      │                       │                      │
```

### Step Detail

**1. Anyone Can Execute Harvest**
```solidity
// External keeper (receives 1% incentive)
vault.harvest();

// Official keeper (receives no incentive)
vault.harvest();

// It doesn't matter who calls — the difference is only whether they collect an incentive
```

**2-20. Fail-Safe Harvest in StrategyManager**
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

**3-4. LidoStrategy.harvest() — yield via exchange rate**
```solidity
// LidoStrategy performs no active action on harvest.
// Yield accumulates automatically in the wstETH/stETH exchange rate.
// The value of wstETH in WETH rises with each Lido rebase.
// harvest() always returns 0.
function harvest() external returns (uint256) {
    return 0;
}
```

**5-10. AaveStrategy.harvest() — AAVE rewards → wstETH → Aave**
```solidity
// 1. Claims AAVE rewards from Aave v3 RewardsController
address[] memory assets_list = new address[](1);
assets_list[0] = address(a_wst_eth_token);
(, uint256[] memory amounts) = rewards_controller.claimAllRewards(assets_list, address(this));

// 2. If no rewards → return 0
uint256 claimed_aave = amounts[0];
if (claimed_aave == 0) return 0;

// 3. Swap AAVE → WETH via Uniswap V3 (with 1% slippage protection)
uint256 weth_received = uniswap_router.exactInputSingle(
    ISwapRouter.ExactInputSingleParams({
        tokenIn: aave_token,
        tokenOut: weth,
        fee: 3000,          // 0.3%
        recipient: address(this),
        amountIn: claimed_aave,
        amountOutMinimum: (claimed_aave_value_in_weth * 9900) / 10000,
        sqrtPriceLimitX96: 0
    })
);

// 4. WETH → ETH → submit to Lido → stETH → wrap → wstETH
IWETH(weth).withdraw(weth_received);
uint256 st_eth = lido.submit{value: weth_received}(address(0));
uint256 wst_eth = IWstETH(wst_eth_token).wrap(st_eth);

// 5. Auto-compound: re-supply wstETH to Aave v3
aave_pool.supply(address(wst_eth_token), wst_eth, address(this), 0);

return weth_received;  // profit expressed in WETH
```

**11-15. CurveStrategy.harvest() — CRV rewards → LP tokens → gauge**
```solidity
// 1. Claims CRV rewards from Curve gauge
curve_gauge.claim_rewards(address(this));
uint256 crv_balance = IERC20(crv_token).balanceOf(address(this));

if (crv_balance == 0) return 0;

// 2. Swap CRV → WETH via Uniswap V3 (with 1% slippage protection)
uint256 weth_received = uniswap_router.exactInputSingle(
    ISwapRouter.ExactInputSingleParams({
        tokenIn: crv_token,
        tokenOut: weth,
        fee: 3000,          // 0.3%
        recipient: address(this),
        amountIn: crv_balance,
        amountOutMinimum: (crv_value_in_weth * 9900) / 10000,
        sqrtPriceLimitX96: 0
    })
);

// 3. WETH → ETH → 50% to stETH via Lido
IWETH(weth).withdraw(weth_received);
uint256 half = weth_received / 2;
uint256 st_eth = lido.submit{value: half}(address(0));

// 4. add_liquidity to Curve stETH/ETH pool → LP tokens
uint256[2] memory amounts = [weth_received - half, st_eth];
uint256 lp_received = curve_pool.add_liquidity{value: weth_received - half}(amounts, 0);

// 5. Auto-compound: stake LP tokens in gauge
curve_gauge.deposit(lp_received);

return weth_received;  // profit expressed in WETH
```

**16-20. UniswapV3Strategy.harvest() — WETH+USDC fees → new LP position**
```solidity
// 1. Collect fees accumulated in the NFT position
(uint256 weth_fees, uint256 usdc_fees) = nonfungible_position_manager.collect(
    INonfungiblePositionManager.CollectParams({
        tokenId: position_token_id,
        recipient: address(this),
        amount0Max: type(uint128).max,
        amount1Max: type(uint128).max
    })
);

if (weth_fees == 0 && usdc_fees == 0) return 0;

// 2. Swap USDC → WETH via Uniswap V3
uint256 weth_from_usdc = 0;
if (usdc_fees > 0) {
    weth_from_usdc = uniswap_router.exactInputSingle(
        ISwapRouter.ExactInputSingleParams({
            tokenIn: usdc,
            tokenOut: weth,
            fee: 500,           // 0.05%
            recipient: address(this),
            amountIn: usdc_fees,
            amountOutMinimum: (usdc_fees_value_in_weth * 9900) / 10000,
            sqrtPriceLimitX96: 0
        })
    );
}

uint256 total_weth = weth_fees + weth_from_usdc;

// 3. Reinvest: 50% swap to USDC → mint new LP position (or increase existing one)
uint256 half_weth = total_weth / 2;
uint256 usdc_for_lp = uniswap_router.exactInputSingle(...);  // WETH → USDC

nonfungible_position_manager.mint(
    INonfungiblePositionManager.MintParams({
        token0: weth,
        token1: usdc,
        fee: 500,
        tickLower: current_tick - 960,
        tickUpper: current_tick + 960,
        amount0Desired: half_weth,
        amount1Desired: usdc_for_lp,
        amount0Min: 0,
        amount1Min: 0,
        recipient: address(this),
        deadline: block.timestamp
    })
);

return total_weth;  // profit expressed in WETH
```

**22-26. Fee Distribution in Vault**
```solidity
// Checks minimum profit (configurable per tier)
if (profit < min_profit_for_harvest) return 0;
// Balanced: 0.08 ETH | Aggressive: 0.12 ETH

// Pays external keeper (only if not official)
uint256 keeper_reward = 0;
if (!is_official_keeper[msg.sender]) {
    keeper_reward = (profit * keeper_incentive) / BASIS_POINTS;  // 1%
    IERC20(asset).safeTransfer(msg.sender, keeper_reward);
}

// Calculates performance fee on net profit
uint256 net_profit = profit - keeper_reward;
uint256 perf_fee = (net_profit * performance_fee) / BASIS_POINTS;  // 20%

// Distributes:
// Treasury (80% perf fee) → mints shares (auto-compound)
uint256 treasury_amount = (perf_fee * treasury_split) / BASIS_POINTS;
uint256 treasury_shares = convertToShares(treasury_amount);
_mint(treasury_address, treasury_shares);

// Founder (20% perf fee) → transfers WETH (liquid)
uint256 founder_amount = (perf_fee * founder_split) / BASIS_POINTS;
IERC20(asset).safeTransfer(founder_address, founder_amount);
```

### Complete Numerical Example

**Scenario**: External keeper executes harvest on Balanced tier after 1 month of accumulation.

**Initial state:**
```
TVL = 500 WETH (Balanced tier)
LidoStrategy:  167 WETH in wstETH (APY 4% via exchange rate)
AaveStrategy:  167 WETH in aWstETH + accumulated AAVE rewards
CurveStrategy: 166 WETH in gauge LP tokens + accumulated CRV rewards
idle_buffer = 2 ETH
```

**1. StrategyManager.harvest() (fail-safe)**
```
LidoStrategy.harvest():
  - No active action (yield in wstETH/stETH exchange rate)
  - profit_lido = 0 (TVL already reflects yield via totalAssets())

AaveStrategy.harvest():
  - Claims: 30 AAVE tokens
  - Swap: 30 AAVE → 1.5 WETH (Uniswap V3, 0.3% fee)
  - WETH → ETH → Lido stETH → wrap wstETH
  - Re-supply: wstETH → Aave Pool
  - profit_aave = 1.5 WETH

CurveStrategy.harvest():
  - Claims: 200 CRV tokens
  - Swap: 200 CRV → 2.0 WETH (Uniswap V3, 0.3% fee)
  - WETH → ETH → 50% to stETH via Lido → add_liquidity → stake in gauge
  - profit_curve = 2.0 WETH

total_profit = 0 + 1.5 + 2.0 = 3.5 WETH
```

**2. Threshold check**
```
3.5 WETH >= 0.08 ETH (min_profit_for_harvest, Balanced tier)
Continues with distribution
```

**3. Payment to external keeper**
```
keeper_reward = 3.5 * 100 / 10000 = 0.035 WETH
→ Paid from idle_buffer (2 ETH available)
→ idle_buffer = 2 - 0.035 = 1.965 ETH
→ Transfers 0.035 WETH to keeper
```

**4. Performance fee**
```
net_profit = 3.5 - 0.035 = 3.465 WETH
perf_fee = 3.465 * 2000 / 10000 = 0.693 WETH
```

**5. Performance fee distribution**
```
treasury_amount = 0.693 * 8000 / 10000 = 0.5544 WETH
→ Mints equivalent shares of 0.5544 WETH to treasury_address
→ Shares auto-compound (increase in value with each future harvest)

founder_amount = 0.693 * 2000 / 10000 = 0.1386 WETH
→ Withdraws from idle_buffer: 1.965 - 0.1386 = 1.826 ETH remaining
→ Transfers 0.1386 WETH to founder_address
```

**6. Final state**
```
TVL = 500 + 3.5 (reinvested rewards) = 503.5 WETH
idle_buffer = 1.826 ETH
LidoStrategy:  167 WETH (implicit yield in exchange rate)
AaveStrategy:  168.5 WETH (includes 1.5 WETH reinvested as wstETH)
CurveStrategy: 168.0 WETH (includes 2.0 WETH reinvested as LP gauge)

Keeper received: 0.035 WETH
Treasury received: shares worth 0.5544 WETH
Founder received: 0.1386 WETH
Users benefit: compounded yield in strategies
```

**If the caller were an official keeper:**
```
keeper_reward = 0 (official, does not charge)
net_profit = 3.5 WETH (no discount)
perf_fee = 3.5 * 2000 / 10000 = 0.7 WETH
treasury_amount = 0.56 WETH (more for the protocol)
founder_amount = 0.14 WETH (more for the founder)
```

---

## 4. Rebalance Flow

### Overview

When APYs change, the optimal distribution changes. A keeper (bot or user) can execute rebalance() to move funds between strategies within a tier. The rebalance only executes if the APY difference between the best and worst strategy exceeds the tier threshold: 200 bp (2%) for Balanced or 300 bp (3%) for Aggressive. The minimum TVL for the rebalance to be valid is: 8 ETH (Balanced) / 12 ETH (Aggressive).

### Step-by-Step Flow

```
┌─────────┐          ┌────────────┐          ┌──────────┐          ┌───────────┐
│ Keeper  │          │  Manager   │          │ Strategy │          │ Protocol  │
└────┬────┘          └─────┬──────┘          └────┬─────┘          └─────┬─────┘
     │                     │                       │                      │
     │ 1. shouldRebalance()│                       │                      │
     ├────────────────────>│                       │                      │
     │                     │                       │                      │
     │                     │ 2. Verifica:          │                      │
     │                     │    - >= 2 strategies  │                      │
     │                     │    - TVL >= 8 ETH     │                      │
     │                     │      (Balanced) /     │                      │
     │                     │      12 ETH (Aggress) │                      │
     │                     │    - max_apy - min_apy│                      │
     │                     │      >= 200 bp (Bal.) │                      │
     │                     │      >= 300 bp (Agg.) │                      │
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
     │                     │    targets            │                      │
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
     │                     │                       │ 12. supply/stake/    │
     │                     │                       │     mint position    │
     │                     │                       ├─────────────────────>│
     │                     │                       │                      │
     │ 13. Rebalanced event│                       │                      │
     │<────────────────────┤                       │                      │
     │                     │                       │                      │
```

### Step Detail

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

// Requires minimum TVL (configurable per tier)
if (totalAssets() < min_tvl_for_rebalance) return false;
// Balanced: 8 ETH | Aggressive: 12 ETH

// Calculates APY difference
uint256 max_apy = 0;
uint256 min_apy = type(uint256).max;

for (uint256 i = 0; i < strategies.length; i++) {
    uint256 apy = strategies[i].apy();
    if (apy > max_apy) max_apy = apy;
    if (apy < min_apy) min_apy = apy;
}

// Rebalance if difference >= tier rebalance_threshold
// Balanced: 200 bp (2%) | Aggressive: 300 bp (3%)
return (max_apy - min_apy) >= rebalance_threshold;
```

### Complete Numerical Example

**Scenario (Balanced tier)**: AaveStrategy APY drops from 5% to 3% (reduction in available liquidity), making the rebalance profitable.

**Initial state (targets per previous APYs: Lido 4%, Aave 5%, Curve 6%):**
```
LidoStrategy:  20 WETH (20% — minimum 20% target applied)
AaveStrategy:  33 WETH (33% — proportional target)
CurveStrategy: 47 WETH (47% — higher weight due to higher APY)
total_tvl = 100 WETH
```

**Market change:**
```
LidoStrategy:  4% APY (unchanged, 400 bp)
AaveStrategy:  3% APY (dropped 2%, 300 bp) — Aave liquidity decreases
CurveStrategy: 6% APY (unchanged, 600 bp)
```

**1. Keeper calls shouldRebalance()**
```
max_apy = 600 bp (CurveStrategy)
min_apy = 300 bp (AaveStrategy)
difference = 600 - 300 = 300 bp

Balanced rebalance_threshold = 200 bp
300 >= 200 → shouldRebalance = true
```

**2. Keeper executes rebalance()**
```
Recalculates targets with new APYs:
- total_apy = 400 + 300 + 600 = 1300 bp
- Lido:  (400 * 10000) / 1300 = 3077 bp = 30.77%
- Aave:  (300 * 10000) / 1300 = 2308 bp = 23.08%
- Curve: (600 * 10000) / 1300 = 4615 bp = 46.15%

Applies caps (max 50%, min 20% for Balanced):
- Lido:  30.77% (within limits)
- Aave:  23.08% (within limits, > 20%)
- Curve: 46.15% (within limits, < 50%)

Target balances:
- Lido:  100 * 30.77% = 30.77 WETH
- Aave:  100 * 23.08% = 23.08 WETH
- Curve: 100 * 46.15% = 46.15 WETH

Deltas (actual vs target):
- Lido:  20 - 30.77 = -10.77 WETH (needs more funds)
- Aave:  33 - 23.08 = +9.92 WETH (excess, APY dropped)
- Curve: 47 - 46.15 = +0.85 WETH (minimal excess)
```

**3. Rebalance execution**
```
1. Withdraws 9.92 WETH from AaveStrategy:
   aWstETH → Aave withdraw → wstETH → Uniswap V3 → WETH

2. Withdraws 0.85 WETH from CurveStrategy:
   gauge unstake → remove_liquidity_one_coin → ETH → wrap WETH

3. Transfers 10.77 WETH to LidoStrategy:
   WETH → unwrap ETH → Lido stETH → wrap wstETH

Final state:
- LidoStrategy:  30.77 WETH (30.77%)
- AaveStrategy:  23.08 WETH (23.08%)
- CurveStrategy: 46.15 WETH (46.15%)
- Funds now generate more yield by being better distributed
```

**Scenario where rebalance does not trigger (Balanced tier):**
```
LidoStrategy:  4% APY (400 bp)
AaveStrategy:  5% APY (500 bp)
CurveStrategy: 6% APY (600 bp)
difference = 600 - 400 = 200 bp

200 >= 200 (Balanced rebalance_threshold) → shouldRebalance = true (right at the limit)

If the difference were 199 bp:
199 < 200 → shouldRebalance = false → Not worth moving funds
```

**Scenario where rebalance does not trigger (Aggressive tier):**
```
CurveStrategy:     6% APY (600 bp)
UniswapV3Strategy: 8% APY (800 bp)
difference = 800 - 600 = 200 bp

Aggressive rebalance_threshold = 300 bp
200 < 300 → shouldRebalance = false → The difference does not justify the rebalance gas cost
```

---

## 5. Idle Buffer Allocation Flow

### Overview

The idle buffer accumulates small deposits to save gas. Multiple users share the cost of a single allocate. The threshold is configurable per tier: 8 ETH for Balanced and 12 ETH for Aggressive.

### Example with 3 Users (Balanced tier, idle_threshold = 8 ETH)

**Configuration:**
- `idle_threshold: 8 ETH (Balanced) / 12 ETH (Aggressive)`
- `idle_buffer = 0` initially

**User 1: Alice deposits 4 ETH**
```
State before:
  idle_buffer = 0

Alice.deposit(4 ETH)
  → idle_buffer = 4 ETH
  → shares_alice = 4
  → totalAssets = 4 ETH (all in idle)

Check: idle_buffer (4) < threshold (8)
NO auto-allocate

State after:
  idle_buffer = 4 ETH (accumulating)
  totalAssets = 4 ETH
```

**User 2: Bob deposits 4 ETH**
```
State before:
  idle_buffer = 4 ETH

Bob.deposit(4 ETH)
  → idle_buffer = 8 ETH
  → shares_bob = (4 * 4) / 4 = 4
  → totalAssets = 8 ETH

Check: idle_buffer (8) >= threshold (8)
AUTO-ALLOCATE!

_allocateIdle():
  1. to_allocate = 8 ETH
  2. idle_buffer = 0
  3. Transfer 8 ETH to manager
  4. manager.allocate(8 ETH) — Balanced tier
     → LidoStrategy  receives 2.13 ETH (26.67%)
        WETH → unwrap ETH → Lido stETH → wrap wstETH
     → AaveStrategy  receives 2.67 ETH (33.33%)
        WETH → unwrap → Lido stETH → wstETH → Aave supply → aWstETH
     → CurveStrategy receives 3.20 ETH (40.00%)
        WETH → unwrap → 50% to stETH → add_liquidity → gauge stake

State after:
  idle_buffer = 0
  LidoStrategy:  2.13 ETH
  AaveStrategy:  2.67 ETH
  CurveStrategy: 3.20 ETH
  totalAssets = 0 + 2.13 + 2.67 + 3.20 = 8 ETH
```

**User 3: Charlie deposits 4 ETH**
```
State before:
  idle_buffer = 0
  LidoStrategy:  2.13 ETH
  AaveStrategy:  2.67 ETH
  CurveStrategy: 3.20 ETH

Charlie.deposit(4 ETH)
  → idle_buffer = 4 ETH
  → shares_charlie = (4 * 8) / 8 = 4
  → totalAssets = 4 + 2.13 + 2.67 + 3.20 = 12 ETH

Check: idle_buffer (4) < threshold (8)
NO auto-allocate (cycle repeats)

State after:
  idle_buffer = 4 ETH (accumulating again)
  LidoStrategy:  2.13 ETH
  AaveStrategy:  2.67 ETH
  CurveStrategy: 3.20 ETH
  totalAssets = 12 ETH
```

### Gas Analysis

**Without idle buffer (3 separate allocates, 3 strategies):**
```
Alice:   350k gas * 50 gwei = 0.0175 ETH
Bob:     350k gas * 50 gwei = 0.0175 ETH
Charlie: 350k gas * 50 gwei = 0.0175 ETH

Total gas: 1050k
Total cost: 0.0525 ETH
```

**With idle buffer (1 shared allocate for Alice + Bob):**
```
Alice:   0 ETH (no allocate)
Bob:     350k gas * 50 gwei = 0.0175 ETH (triggers allocate for Alice + Bob)
Charlie: 0 ETH (no allocate yet)

Total gas: 350k
Total cost: 0.0175 ETH

Savings: 0.0525 - 0.0175 = 0.035 ETH (66% savings)
Cost per user: 0.0175 / 2 = 0.00875 ETH
```

### Manual Allocate Flow

**Anyone can call allocateIdle() if idle >= threshold:**
```solidity
// Keeper sees that idle_buffer = 8 ETH (Balanced) or 12 ETH (Aggressive)
vault.allocateIdle();

// Vault executes:
if (idle_buffer < idle_threshold) revert Vault__InsufficientIdleBuffer();
_allocateIdle();
```

---

## 6. Router Flows (Multi-Token)

### Overview

The Router allows depositing and withdrawing using native ETH or any ERC20 with a Uniswap V3 pool, without needing to hold WETH beforehand. The Router swaps the token to WETH, deposits into the Vault, and the user receives shares directly.

### Flow: Depositing USDC via Router

**Scenario**: Alice has 5000 USDC and wants to deposit into VynX without having to manually buy WETH.

```
┌─────────┐          ┌──────────┐          ┌────────────┐          ┌──────────┐
│  Alice  │          │  Router  │          │ Uniswap V3 │          │  Vault   │
└────┬────┘          └────┬─────┘          └─────┬──────┘          └────┬─────┘
     │                    │                      │                       │
     │ 1. approve(router) │                      │                       │
     │ ───────────────────>                      │                       │
     │                    │                      │                       │
     │ 2. zapDepositERC20 │                      │                       │
     │    (USDC, 5000e6)  │                      │                       │
     │ ───────────────────>                      │                       │
     │                    │                      │                       │
     │                    │ 3. transferFrom      │                       │
     │                    │    (alice → router)  │                       │
     │<────────────────────                      │                       │
     │                    │                      │                       │
     │                    │ 4. approve(uniswap)  │                       │
     │                    │ ────────────────────>│                       │
     │                    │                      │                       │
     │                    │ 5. exactInputSingle  │                       │
     │                    │    USDC → WETH       │                       │
     │                    │ ────────────────────>│                       │
     │                    │<─ 2.1 WETH ──────────│                       │
     │                    │                      │                       │
     │                    │ 6. vault.deposit(2.1 WETH, alice)             │
     │                    │ ─────────────────────────────────────────────>│
     │<─ shares ──────────────────────────────────────────────────────────│
     │                    │                      │                       │
     │                    │ 7. balance check     │                       │
     │                    │    (must be 0)       │                       │
     │                    │                      │                       │
```

**Final state:**
- Alice spent: 5000 USDC
- Alice received: ~2.1 vault shares (equivalent to ~2.1 WETH deposited)
- Router balance: 0 (stateless verified)

### Flow: Withdrawing to Native ETH via Router

**Scenario**: Alice has shares and wants to withdraw in native ETH (not WETH).

```
┌─────────┐          ┌──────────┐          ┌──────────┐
│  Alice  │          │  Router  │          │  Vault   │
└────┬────┘          └────┬─────┘          └────┬─────┘
     │                    │                      │
     │ 1. vault.approve   │                      │
     │    (router, shares)│                      │
     │ ───────────────────>                      │
     │                    │                      │
     │ 2. zapWithdrawETH  │                      │
     │    (shares)        │                      │
     │ ───────────────────>                      │
     │                    │                      │
     │                    │ 3. transferFrom      │
     │                    │    (alice → router)  │
     │<────────────────────                      │
     │                    │                      │
     │                    │ 4. vault.redeem      │
     │                    │    (shares, router)  │
     │                    │ ────────────────────>│
     │                    │<─ WETH ──────────────│
     │                    │                      │
     │                    │ 5. WETH.withdraw()   │
     │                    │    (unwrap)          │
     │                    │                      │
     │                    │ 6. transfer ETH      │
     │<─ ETH ──────────────                      │
     │                    │                      │
     │                    │ 7. balance check     │
     │                    │    (must be 0)       │
     │                    │                      │
```

**Final state:**
- Alice burned: shares
- Alice received: native ETH (not WETH)
- Router balance: 0 WETH, 0 ETH (stateless verified)

### Numerical Example: Multi-Token Deposit Round-Trip

**Setup:** Alice deposits 5000 USDC → withdraws in DAI (different tokens).

**1. Deposit (USDC → WETH → shares)**
```
Alice has: 5000 USDC
Pool USDC/WETH (Uniswap V3, fee 0.05%): 1 USDC ≈ 0.00042 WETH

zapDepositERC20(USDC, 5000e6, 500, min_weth_out):
  - Swap: 5000 USDC → 2.1 WETH (slippage + fee ≈ 0.1%)
  - Deposit: 2.1 WETH → 2.1 shares (1:1 ratio first deposit)

Alice receives: 2.1 shares
Router balance: 0 (stateless)
```

**2. Withdrawal (shares → WETH → DAI)**
```
Alice has: 2.1 shares
Pool WETH/DAI (Uniswap V3, fee 0.05%): 1 WETH ≈ 2380 DAI

zapWithdrawERC20(2.1 shares, DAI, 500, min_dai_out):
  - Redeem: 2.1 shares → 2.1 WETH
  - Swap: 2.1 WETH → 4998 DAI (slippage + fee ≈ 0.1%)

Alice receives: 4998 DAI
Alice net spent: 2 USDC (slippage + fees from two swaps)
Router balance: 0 WETH, 0 DAI (stateless)
```

---

## 7. Emergency Exit Flow

### Overview

Emergency Exit is the last-resort mechanism to drain all strategies when a critical bug or active exploit is detected. It transfers all assets to the vault so users can withdraw. The sequence consists of 3 independent (non-atomic) transactions executed by the owners of the vault and the manager.

> **Important**: If the Vault and Manager have different owners, each owner executes their step. If `emergencyExit()` reverts, the vault remains paused but funds stay safe in the strategies — no assets are lost.

### Step-by-Step Flow

```
┌──────────────┐          ┌──────────┐          ┌────────────┐          ┌──────────┐
│   Owner(s)   │          │  Vault   │          │  Manager   │          │ Strategy │
└──────┬───────┘          └────┬─────┘          └─────┬──────┘          └────┬─────┘
       │                       │                      │                       │
       │ 1. vault.pause()      │                      │                       │
       ├──────────────────────>│                      │                       │
       │                       │ Blocks deposit,      │                       │
       │                       │ mint, harvest,       │                       │
       │                       │ allocateIdle         │                       │
       │                       │                      │                       │
       │                       │ withdraw/redeem      │                       │
       │                       │ remain enabled       │                       │
       │                       │                      │                       │
       │ 2. manager.emergencyExit()                   │                       │
       ├─────────────────────────────────────────────>│                       │
       │                       │                      │                       │
       │                       │                      │ 3. for each strategy: │
       │                       │                      │    balance = totalAssets()
       │                       │                      │    if balance == 0:   │
       │                       │                      │      skip             │
       │                       │                      │                       │
       │                       │                      │ 4. try withdraw(bal)  │
       │                       │                      ├──────────────────────>│
       │                       │                      │                       │
       │                       │                      │ 5. actual_withdrawn   │
       │                       │                      │<──────────────────────┤
       │                       │                      │                       │
       │                       │                      │ (if it fails: emit    │
       │                       │                      │  HarvestFailed,       │
       │                       │                      │  continues with the   │
       │                       │                      │  next strategy)       │
       │                       │                      │                       │
       │                       │ 6. safeTransfer(     │                       │
       │                       │    vault, total)     │                       │
       │                       │<─────────────────────┤                       │
       │                       │                      │                       │
       │                       │                      │ 7. emit EmergencyExit │
       │                       │                      │    (timestamp, total, │
       │                       │                      │     strategies_drained)│
       │                       │                      │                       │
       │ 8. vault.syncIdleBuffer()                    │                       │
       ├──────────────────────>│                      │                       │
       │                       │ 9. idle_buffer =     │                       │
       │                       │    WETH.balanceOf(    │                       │
       │                       │      address(this))  │                       │
       │                       │                      │                       │
       │                       │ 10. emit             │                       │
       │                       │   IdleBufferSynced   │                       │
       │                       │   (old, new)         │                       │
       │                       │                      │                       │
```

### Step Detail

**Step 1: Pause the Vault**
```solidity
// Vault Owner executes:
vault.pause();

// Effect: blocks deposit(), mint(), harvest(), allocateIdle()
// withdraw() and redeem() continue to work (users can exit)
```

**Step 2: Drain Strategies**
```solidity
// Manager Owner executes:
manager.emergencyExit();

// Iterates all strategies with try-catch (fail-safe)
// If a strategy fails, emits HarvestFailed and continues with the others
// Transfers all rescued WETH to the vault in a single transfer
```

**Step 3: Reconcile Accounting**
```solidity
// Vault Owner executes:
vault.syncIdleBuffer();

// idle_buffer = IERC20(asset()).balanceOf(address(this))
// Necessary because emergencyExit() transfers WETH directly to the vault
// without going through deposit() or _allocateIdle(), desynchronizing idle_buffer
```

### Complete Numerical Example

**Scenario**: A bug is detected in CurveStrategy. The owner executes the emergency sequence to rescue all funds from the Balanced tier.

**Initial state:**
```
idle_buffer = 3 ETH
LidoStrategy:  30 ETH in wstETH
AaveStrategy:  35 ETH in aWstETH
CurveStrategy: 32 ETH in gauge LP (strategy with bug)
totalAssets = 3 + 30 + 35 + 32 = 100 ETH
```

**1. vault.pause()**
```
State: vault paused
- deposit() → reverts
- mint() → reverts
- harvest() → reverts
- allocateIdle() → reverts
- withdraw() → works ✓
- redeem() → works ✓
```

**2. manager.emergencyExit()**
```
Iterates strategies:

LidoStrategy (30 ETH):
  try withdraw(30 ETH):
    wstETH → unwrap → stETH → swap → WETH
    actual_withdrawn = 29.999999999999999998 ETH (2 wei dust from wstETH/stETH conversion)
  ✓ success

AaveStrategy (35 ETH):
  try withdraw(35 ETH):
    aWstETH → Aave withdraw → wstETH → swap → WETH
    actual_withdrawn = 34.999999999999999999 ETH (1 wei dust)
  ✓ success

CurveStrategy (32 ETH):
  try withdraw(32 ETH):
    gauge unstake → remove_liquidity → BUG! → reverts
  ✗ catch → emit HarvestFailed(curveStrategy, "bug error message")
  Continues with remaining strategies

total_rescued = 29.999...998 + 34.999...999 = 64.999...997 ETH
strategies_drained = 2

safeTransfer(vault, 64.999...997 ETH)
emit EmergencyExit(block.timestamp, 64.999...997, 2)
```

**3. vault.syncIdleBuffer()**
```
old_buffer = 3 ETH (previous value, outdated)
real_balance = WETH.balanceOf(vault) = 3 + 64.999...997 = 67.999...997 ETH
idle_buffer = 67.999...997 ETH (synchronized with real balance)

emit IdleBufferSynced(3 ETH, 67.999...997 ETH)
```

**Final state:**
```
idle_buffer = 67.999...997 ETH (synchronized)
LidoStrategy:  ~0 ETH (drained, possible 1-2 wei dust)
AaveStrategy:  ~0 ETH (drained, possible 1 wei dust)
CurveStrategy: 32 ETH (could not be drained — requires manual action)
totalAssets = 67.999...997 + 0 + 0 + 32 = 99.999...997 ETH

Users can call withdraw() / redeem() to recover funds from idle_buffer.
The owner must handle CurveStrategy separately (removeStrategy, patch, etc.).
```

### Edge Cases

| Case | Behavior |
|------|----------|
| All strategies with balance 0 | `emergencyExit()` completes without error, `total_rescued = 0` |
| One strategy reverts | try-catch captures the error, emits `HarvestFailed`, continues with the others |
| All strategies revert | `total_rescued = 0`, nothing is transferred, but the `EmergencyExit` event is emitted anyway |
| Residual dust (1-2 wei) | Normal in wstETH/stETH conversions. Does not affect the operation |
| `syncIdleBuffer` without prior `emergencyExit` | Works correctly — simply synchronizes `idle_buffer` with the real balance |
| Vault Owner != Manager Owner | Each owner executes their step. Does not require atomic coordination |

---

## Flow Summary

| Flow | Trigger | Auto/Manual | Gas Optimization | Fee |
|------|---------|-------------|------------------|-----|
| **Deposit** | User deposits | Auto if idle >= idle_threshold (8-12 ETH per tier) | Idle buffer (50-66% savings) | None |
| **Withdrawal** | User withdraws | Manual (user calls) | Withdraws from idle first | None (only rounding ~wei) |
| **Harvest** | Keeper/Anyone | Manual (incentivized) | Fail-safe, auto-compound per strategy | 20% perf fee + 1% keeper |
| **Rebalance** | APY changes > threshold | Manual (keeper/anyone) | Only if APY diff >= 200 bp (Bal.) / 300 bp (Agg.) | None |
| **Idle Allocate** | idle >= threshold | Auto on deposit, or manual | Amortizes gas among users | None |
| **Router Deposit** | User with ERC20/ETH | Manual (user calls) | Swap + deposit in 1 tx | Uniswap slippage (0.05-1%) |
| **Router Withdrawal** | User wants ERC20/ETH | Manual (user calls) | Redeem + swap in 1 tx | Uniswap slippage (0.05-1%) |
| **Emergency Exit** | Critical bug / exploit | Manual (owner, 3 txs) | try-catch fail-safe per strategy | None |

### Quick reference of parameters per tier

| Parameter | Balanced (Lido + Aave + Curve) | Aggressive (Curve + UniswapV3) |
|-----------|-------------------------------|-------------------------------|
| `idle_threshold` | 8 ETH | 12 ETH |
| `min_tvl_for_rebalance` | 8 ETH | 12 ETH |
| `rebalance_threshold` | 200 bp (2%) | 300 bp (3%) |
| `min_profit_for_harvest` | 0.08 ETH | 0.12 ETH |
| `max_allocation_per_strategy` | 5000 bp (50%) | 7000 bp (70%) |
| `min_allocation_threshold` | 2000 bp (20%) | 1000 bp (10%) |
| `max_tvl` | 1000 ETH | 1000 ETH |

---

**Next reading**: [SECURITY.md](SECURITY.md) - Security considerations and implemented protections
