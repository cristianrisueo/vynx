# Security Considerations

This document analyzes the security posture of VynX V1, including trust assumptions, attack vectors considered, implemented protections, centralization points, and known limitations.

---

## 1. Trust Assumptions (What We Trust)

The VynX V1 protocol **explicitly trusts** the following external components:

### Aave v3

**Trust level**: High

**Reasons:**
- Audited multiple times by Trail of Bits, OpenZeppelin, Consensys Diligence, etc.
- Battle-tested with >$5B TVL on mainnet for years
- Robust security track record (no major hacks)
- Open-source code reviewed by the community

**Accepted risks:**
- If Aave suffers an exploit, we could lose funds deposited in AaveStrategy
- Mitigation: Weighted allocation limits exposure to 50% maximum

### Compound v3

**Trust level**: High

**Reasons:**
- Audited by OpenZeppelin, ChainSecurity, etc.
- Battle-tested with >$3B TVL on mainnet
- Compound v2 has a track record of years without critical hacks
- V3 is a more secure and gas-efficient rewrite

**Accepted risks:**
- If Compound suffers an exploit, we could lose funds deposited in CompoundStrategy
- Mitigation: Weighted allocation limits exposure to 50% maximum

### Uniswap V3

**Trust level**: High

**Reasons:**
- Most established DEX on Ethereum
- Extensively audited
- Used by thousands of protocols for programmatic swaps

**Accepted risks:**
- If Uniswap has a bug, reward swaps during harvest could fail or return less WETH
- If there isn't enough liquidity in AAVE/WETH or COMP/WETH pools, harvest fails
- Mitigation: Max slippage of 1%, fail-safe in StrategyManager (if harvest fails, continues with other strategies)

### OpenZeppelin Contracts

**Trust level**: Very High

**Reasons:**
- Industry standard (ERC4626, ERC20, Ownable, Pausable)
- Exhaustively audited
- Used by thousands of DeFi protocols

**Components used:**
- `ERC4626`: Tokenized vault standard
- `SafeERC20`: Safe token transfers
- `Ownable`: Admin access control
- `Pausable`: Emergency stop
- `Math`: Safe math operations

### WETH (Wrapped Ether)

**Trust level**: Very High

**Reasons:**
- Canonical Ethereum contract
- Simple and audited code
- No admin keys or upgradeability

---

## 2. Attack Vectors Considered

The protocol has been designed considering the following common DeFi attack vectors:

### 2.1 Reentrancy Attacks

**Description**: Attacker recursively calls functions before state is updated.

**Implemented protections:**

1. **CEI Pattern (Checks-Effects-Interactions)**
```solidity
// CORRECT: Burns shares BEFORE transferring assets
function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares) internal {
    _burn(owner, shares);                    // Effect (modifies state)
    // ... withdrawal from idle/strategies    // Interaction (external calls)
    IERC20(asset).safeTransfer(receiver, amount); // Interaction
}
```

2. **SafeERC20 for all transfers**
```solidity
using SafeERC20 for IERC20;

IERC20(asset).safeTransfer(receiver, amount);     // Does not use direct transfer()
IERC20(asset).safeTransferFrom(user, vault, amt); // Handles reverts correctly
```

3. **No callbacks to users**
- The vault never calls user functions (no hooks)
- Only interacts with known contracts (strategies, WETH, Uniswap)

**Assessment**: Protected

---

### 2.2 Front-Running Rebalances

**Description**: Attacker observes a pending rebalance tx and deposits right before to capture immediate benefit.

**Analysis:**
```solidity
// Scenario:
// 1. Keeper calls rebalance() (moves funds to better strategy)
// 2. Attacker sees tx in mempool
// 3. Attacker deposits with higher gas price
// 4. Rebalance executes (increases effective APY)
// 5. Attacker withdraws immediately

// Result: Attacker captures part of future yield
```

**Implemented mitigations:**

1. **Permissionless public rebalance**
   - Anyone can execute rebalance() if shouldRebalance() passes
   - No special benefit for the executor
   - MEV is minimal (no direct arbitrage)

2. **Yield accrues over time**
   - Rebalance benefit materializes over weeks
   - Attacker cannot "flash-rebalance-withdraw"

3. **No immediate benefit**
   - Rebalance only moves funds between strategies
   - Does not generate instant profit that can be extracted

**Assessment**: Mitigated (economically unprofitable)

---

### 2.3 Rounding Attacks (Inflation Attack)

**Description**: Attacker manipulates the share/asset price by donating assets to cause rounding losses.

**Classic scenario:**
```solidity
// 1. Attacker is first depositor: deposit(1 wei)
//    shares = 1, totalAssets = 1
//
// 2. Attacker donates 1000 ETH directly to the vault (not via deposit)
//    totalAssets = 1000 ETH + 1 wei
//
// 3. Victim deposits 2000 ETH
//    shares = (2000 * 1) / 1000 = 2 shares (rounded down)
//    totalAssets = 3000 ETH
//
// 4. Attacker redeem(1 share)
//    assets = (1 * 3000) / 3 = 1000 ETH
//
// Result: Attacker stole 1000 ETH from the victim
```

**Implemented protections:**

1. **Minimum deposit of 0.01 ETH**
```solidity
uint256 public min_deposit = 0.01 ether;

function deposit(uint256 assets, address receiver) public {
    if (assets < min_deposit) revert Vault__DepositBelowMinimum();
    // ...
}
```

**Attack cost analysis:**
- To make the attack profitable, attacker would need to donate >100 ETH
- First deposit is 0.01 ETH (not 1 wei)
- Share/asset ratio cannot be efficiently manipulated
- Attack cost > potential benefit

2. **Standard OpenZeppelin ERC4626**
- Audited implementation with known protections

**Assessment**: Protected (prohibitive attack cost)

---

### 2.4 Flash Loan Attacks

**Description**: Attacker takes a flash loan to manipulate the vault's price or state.

**Applicability analysis:**

1. **No price oracle**
   - The vault does not use external prices
   - Strategy APY comes from protocols (Aave/Compound)
   - APY cannot be manipulated with flash loans

2. **No weighted voting by shares**
   - Shares only determine proportion of assets
   - No governance attackable with flash loans

3. **No instant arbitrage**
   - No withdrawal fee but also no way to extract value in a single transaction
   - Flash loan -> deposit -> withdraw returns the same (minus rounding wei)

**Scenarios considered:**
```solidity
// NOT POSSIBLE: Manipulate APY
// APY comes directly from Aave/Compound
// Flash loan cannot change Aave's liquidity rate

// NOT POSSIBLE: Arbitrage share/asset price
// deposit and withdraw are symmetric (ERC4626 standard)

// NOT POSSIBLE: Vote with borrowed shares
// No governance system exists
```

**Assessment**: Not applicable (no viable attack vectors)

---

### 2.5 Keeper Incentive Risks

**Description**: Risks associated with the keeper incentive system and public harvest.

**Vectors considered:**

1. **Spamming harvest() when there are no rewards**
```solidity
// Scenario: Attacker calls harvest() repeatedly
// Result: profit < min_profit_for_harvest -> return 0
// No incentive paid, no fees distributed
// Only gas wasted by the attacker

// Protection: min_profit_for_harvest = 0.1 ETH
// If profit < 0.1 ETH, harvest does not execute distribution
```

2. **Front-running harvest**
```solidity
// Scenario: Keeper A sees that there are accumulated rewards
// Attacker B front-runs harvest() with higher gas
// Result: Attacker B receives 1% keeper incentive
// Keeper A spends gas without receiving anything

// Mitigation: This is the expected design — normal MEV
// The 1% incentive is low enough to not be very profitable to front-run
// Official keepers don't compete for incentive
```

3. **Malicious official keeper**
```solidity
// Scenario: Owner marks an address as official
// Official keeper harvests without paying incentive
// Result: More profit for the protocol, not for keeper

// This is not a risk — it's a feature
// Official keepers belong to the protocol and don't need incentive
```

**Assessment**: Mitigated (spam is unprofitable, MEV is expected and tolerable)

---

### 2.6 Uniswap Swap Risks

**Description**: Risks associated with swapping reward tokens to WETH via Uniswap V3.

**Vectors considered:**

1. **Sandwich attack on swaps**
```solidity
// Scenario:
// 1. Bot detects harvest() with large swap in mempool
// 2. Front-runs: buys WETH with the reward token
// 3. harvest() executes swap (worse price due to impact)
// 4. Back-runs: sells WETH

// Mitigation: MAX_SLIPPAGE_BPS = 100 (1% max)
// If the sandwich causes > 1% slippage, the tx reverts
// With pool_fee of 0.3%, the margin for sandwich is very limited
uint256 min_amount_out = (claimed * 9900) / 10000;
```

2. **Pool with low liquidity**
```solidity
// Scenario: AAVE/WETH or COMP/WETH pool has low liquidity
// harvest swap gets bad price or reverts

// Mitigation:
// - AAVE/WETH and COMP/WETH pools are highly liquid on mainnet
// - If swap reverts, StrategyManager fail-safe continues with other strategies
// - Profit is not lost, only postponed to the next harvest
```

3. **Reward token depegs or loses value**
```solidity
// Scenario: AAVE or COMP loses significant value
// Swap returns less WETH than expected

// Mitigation:
// - 1% slippage protects against extreme losses
// - If the swap fails, fail-safe continues
// - Lost rewards are a fraction of total yield (most comes from lending)
```

**Assessment**: Mitigated (slippage protection + fail-safe)

---

### 2.7 Withdrawal Rounding

**Description**: External protocols (Aave, Compound) round withdrawals down, causing micro-differences between requested and received assets.

**Technical analysis:**
```solidity
// Aave v3: aave_pool.withdraw() may return assets - 1 wei
// Compound v3: compound_comet.withdraw() may return assets - 1 or -2 wei

// Pattern in CompoundStrategy:
uint256 balance_before = IERC20(asset).balanceOf(address(this));
compound_comet.withdraw(asset, assets);
uint256 balance_after = IERC20(asset).balanceOf(address(this));
uint256 actual_withdrawn = balance_after - balance_before;
// actual_withdrawn may be assets - 1 or assets - 2
```

**Tolerance in Vault:**
```solidity
// Vault accepts up to 20 wei of difference
if (to_transfer < assets) {
    require(assets - to_transfer < 20, "Excessive rounding");
}

// Why 20 wei?
// - 2 current strategies x ~2 wei/operation = ~4 wei
// - Future plan: ~10 strategies x ~2 wei = ~20 wei (conservative margin)
// - Cost to user: ~$0.00000000000005 with ETH at $2,500
```

**Can an attacker exploit this?**
```solidity
// NO: 20 wei is insignificant (~$0.00000000000005)
// NO: Rounding always benefits the protocol (rounded down)
// NO: There is no accumulation of rounding errors between operations
// Rounding is resolved per operation, it does not propagate
```

**Assessment**: Deliberately tolerated (trivial cost, standard in DeFi)

---

## 3. Implemented Protections

### 3.1 Access Control

**Modifiers used:**

```solidity
// Vault
modifier onlyOwner()        // Admin functions (pause, setters)
modifier whenNotPaused()    // Deposits, withdraws, harvest

// StrategyManager
modifier onlyOwner()        // Add/remove strategies, setters
modifier onlyVault()        // allocate(), withdrawTo(), harvest()

// Strategies
modifier onlyManager()      // deposit(), withdraw(), harvest()
```

**Permission hierarchy:**
```
Vault Owner
  |
Vault (contract)
  | (only vault can call)
StrategyManager (contract)
  | (only manager can call)
Strategies (contracts)
  |
External protocols (Aave/Compound/Uniswap)
```

---

### 3.2 Circuit Breakers

**1. Max TVL (Vault)**
```solidity
uint256 public max_tvl = 1000 ether;

function deposit(uint256 assets, address receiver) public {
    if (totalAssets() + assets > max_tvl) {
        revert Vault__MaxTVLExceeded();
    }
    // ...
}
```

**Purpose:**
- Limits total protocol exposure
- Useful during testing/audit phase
- Owner can increase when it's safe

---

**2. Min Deposit (Vault)**
```solidity
uint256 public min_deposit = 0.01 ether;

function deposit(uint256 assets, address receiver) public {
    if (assets < min_deposit) {
        revert Vault__DepositBelowMinimum();
    }
    // ...
}
```

**Purposes:**
- **Anti-spam**: Prevents many small deposits that accumulate gas
- **Anti-rounding attack**: Makes rounding attacks prohibitively expensive

---

**3. Allocation Caps (Manager)**
```solidity
uint256 public max_allocation_per_strategy = 5000;  // 50%
uint256 public min_allocation_threshold = 1000;     // 10%
```

**Purpose:**
- **Max cap (50%)**: Limits exposure to a single strategy/protocol
- **Min threshold (10%)**: Avoids allocating insignificant amounts (gas waste)

---

**4. Max Strategies (Manager)**
```solidity
uint256 public constant MAX_STRATEGIES = 10;  // Hard-coded
```

**Purpose:**
- Prevents gas DoS in allocate/withdrawTo/harvest/rebalance loops
- With 10 strategies, each loop has a predictable cost

---

**5. Min Profit for Harvest (Vault)**
```solidity
uint256 public min_profit_for_harvest = 0.1 ether;
```

**Purpose:**
- Prevents unprofitable harvests (gas > profit)
- Prevents harvest() spam by attackers

---

### 3.3 Emergency Stop (Pausable)

```solidity
contract Vault is IVault, ERC4626, Ownable, Pausable {
    function deposit(...) public whenNotPaused { }
    function mint(...) public whenNotPaused { }
    function withdraw(...) public whenNotPaused { }
    function redeem(...) public whenNotPaused { }
    function harvest() external whenNotPaused { }
    function allocateIdle() external whenNotPaused { }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
```

**When to use:**
- A vulnerability is detected in the vault or strategies
- A hack in Aave/Compound/Uniswap affects funds
- Critical bug in weighted allocation or harvest
- While investigating anomalous behavior

**What it pauses:**
- New deposits
- New withdrawals
- Harvest
- AllocateIdle
- Does not pause rebalances (manager is separate)

**Note:** The manager's owner should remove compromised strategies during a pause.

---

### 3.4 SafeERC20 Usage

**All IERC20 operations use SafeERC20:**
```solidity
using SafeERC20 for IERC20;

// Instead of:
IERC20(asset).transfer(receiver, amount);           // ❌
IERC20(asset).transferFrom(user, vault, amount);    // ❌

// We use:
IERC20(asset).safeTransfer(receiver, amount);       // ✅
IERC20(asset).safeTransferFrom(user, vault, amount);// ✅
```

**SafeERC20 protections:**
- Handles tokens that don't return bool on transfer (legacy tokens)
- Reverts if transfer fails silently
- Verifies return value correctly

---

### 3.5 Harvest Fail-Safe

```solidity
// StrategyManager.harvest() uses try-catch
for (uint256 i = 0; i < strategies.length; i++) {
    try strategies[i].harvest() returns (uint256 profit) {
        total_profit += profit;
    } catch Error(string memory reason) {
        emit HarvestFailed(address(strategies[i]), reason);
        // Continues with the next strategy
    }
}
```

**Purpose:**
- If AaveStrategy.harvest() fails (no rewards, Uniswap reverts, etc.), CompoundStrategy.harvest() continues
- Prevents a single failure from blocking the entire harvest
- Emits event for monitoring

---

### 3.6 Slippage Protection on Swaps

```solidity
// In AaveStrategy and CompoundStrategy
uint256 public constant MAX_SLIPPAGE_BPS = 100;  // 1%

uint256 min_amount_out = (claimed * (BASIS_POINTS - MAX_SLIPPAGE_BPS)) / BASIS_POINTS;
// = claimed * 9900 / 10000 (minimum 99% of expected value)

uniswap_router.exactInputSingle(
    // ...
    amountOutMinimum: min_amount_out,  // Reverts if output < 99%
    // ...
);
```

**Purpose:**
- Prevents sandwich attacks (maximum 1% impact)
- Protects against pools with low liquidity
- If the swap can't achieve 99%+, it reverts (and fail-safe continues)

---

## 4. Centralization Points

The protocol has centralization points controlled by owners. In production, these should be multisigs.

### 4.1 Vault Owner

**Can:**

1. **Pause deposits/withdrawals/harvest**
```solidity
vault.pause();
// All deposits, withdraws, and harvest are blocked
```

2. **Change protocol parameters**
```solidity
vault.setPerformanceFee(5000);             // Increases fee to 50%
vault.setFeeSplit(5000, 5000);             // Changes split to 50/50
vault.setMinDeposit(1 ether);             // Raises minimum deposit
vault.setIdleThreshold(100 ether);        // Changes when to invest
vault.setMaxTVL(10000 ether);             // Increases circuit breaker
vault.setKeeperIncentive(500);            // Raises incentive to 5%
vault.setMinProfitForHarvest(1 ether);    // Raises harvest threshold
```

3. **Change critical addresses**
```solidity
vault.setTreasury(new_treasury);           // Changes who receives fees
vault.setFounder(new_founder);             // Changes founder address
vault.setStrategyManager(new_manager);     // Changes strategy manager
vault.setOfficialKeeper(keeper, true);     // Marks official keepers
```

**Cannot:**
- Steal funds directly
- Transfer WETH from the vault without going through withdraw
- Mint shares without depositing assets
- Modify user balances

**Recommended mitigations:**
- Use a multisig (Gnosis Safe) as owner
- Timelock for sensitive parameter changes
- Events emitted for transparency

---

### 4.2 Manager Owner

**Can:**

1. **Add malicious strategies**
```solidity
// RISK: Owner can add a fake strategy
manager.addStrategy(address(malicious_strategy));

// malicious_strategy.deposit() could:
// - Not deposit into a real protocol
// - Transfer WETH to attacker's address
// - Report fake totalAssets()
// - harvest() could steal funds
```

2. **Remove strategies**
```solidity
// Only if balance = 0 (protection against accidental loss)
manager.removeStrategy(index);
```

3. **Change allocation parameters**
```solidity
manager.setMaxAllocationPerStrategy(10000); // Allows 100% in one strategy
manager.setMinAllocationThreshold(0);       // Allows micro-allocations
manager.setRebalanceThreshold(0);           // Allows rebalances without APY difference
```

**Cannot:**
- Call allocate(), withdrawTo(), or harvest() (only vault can)
- Steal WETH directly from the manager
- Deposit/withdraw from strategies directly

**Recommended mitigations:**
- Multisig as owner
- Whitelist of allowed strategies (off-chain governance)
- Audit strategies before adding
- Monitoring of critical parameters

---

### 4.3 Single Point of Failure

**Critical scenario:**
```
Owner EOA loses private key
  -> Cannot pause vault
  -> Cannot remove compromised strategy
  -> Funds could be at risk
```

**Recommended solutions for production:**

1. **Gnosis Safe Multisig (3/5 or 4/7)**
   - Requires multiple signatures for critical actions
   - Prevents loss of a single key

2. **Timelock**
   ```solidity
   // Parameter changes have a 24-48h delay
   // Users can withdraw if they disagree
   ```

3. **Granular roles (OpenZeppelin AccessControl)**
   ```solidity
   PAUSER_ROLE      -> Can pause (trusted keeper)
   STRATEGY_ROLE    -> Can add/remove strategies (DAO)
   PARAM_ROLE       -> Can adjust parameters (multisig)
   ```

---

## 5. Known Limitations

The protocol has deliberate limitations (v1) and known trade-offs:

### 5.1 WETH Only

**Limitation:**
- Only supports WETH as asset
- No multi-asset vault

**Reasons:**
- v1 simplicity
- Aave and Compound have better rates for ETH/WETH
- Multi-asset requires price oracles (larger attack surface)

**Roadmap:**
- v2: Multi-asset with Chainlink price feeds

---

### 5.2 Basic Weighted Allocation

**Limitation:**
- Simple algorithm: allocation proportional to APY
- Does not consider volatility, liquidity, history

**Current formula:**
```solidity
target[i] = (strategy_apy[i] * BASIS_POINTS) / total_apy
// With caps: max 50%, min 10%
```

**Potential improvements (v2+):**
- Sharpe ratio (reward/risk)
- Available liquidity in protocols
- APY history (not just snapshot)
- Machine learning to predict APYs

---

### 5.3 Idle Buffer Does Not Generate Yield

**Limitation:**
- WETH in idle buffer is not invested
- During accumulation (0-10 ETH), there is no yield

**Trade-off:**
```
Gas savings > yield lost on idle

Example:
- 5 ETH idle for 1 day
- Lost APY: 5% annual = 0.0007 ETH/day
- Gas saved: 0.015 ETH (by not doing allocate alone)
- Net benefit: 0.015 - 0.0007 = 0.0143 ETH
```

**Alternative considered:**
- Auto-compound idle into Aave (adds complexity)

---

### 5.4 Manual Rebalancing

**Limitation:**
- No automatic on-chain rebalancing
- Requires external keepers or users

**Reasons:**
- Rebalancing on every deposit would be extremely expensive
- Keepers can choose optimal timing (low gas)
- shouldRebalance() is view (keepers can simulate off-chain)

**Mitigations:**
- Anyone can execute (permissionless)
- 2% threshold prevents unnecessary executions

---

### 5.5 Illiquid Treasury Shares

**Limitation:**
- Treasury receives performance fees in shares (vxWETH)
- Shares cannot be easily sold without diluting holders

**Consequences:**
- Treasury accumulates shares that auto-compound (good long-term yield)
- But cannot easily convert to liquid assets without impacting share price

**Trade-off:**
- Auto-compound > immediate liquidity for treasury
- Founder receives liquid (WETH) for operational costs
- If treasury needs liquidity, it can redeem shares gradually

---

### 5.6 Harvest Depends on Uniswap Liquidity

**Limitation:**
- If AAVE/WETH or COMP/WETH pools on Uniswap V3 don't have liquidity, harvest fails
- Rewards accumulate without converting to WETH

**Mitigations:**
- AAVE/WETH and COMP/WETH pools are highly liquid on mainnet
- Fail-safe in StrategyManager allows individual strategies to fail
- Rewards are not lost, they just accumulate for the next successful harvest
- 1% slippage protects against temporarily illiquid pools

---

### 5.7 Max 10 Strategies

**Limitation:**
- Maximum 10 active strategies simultaneously (hard-coded)

**Reasons:**
- Prevents gas DoS in loops (allocate, withdrawTo, harvest, rebalance)
- With 10 strategies, gas cost is predictable and reasonable
- More than 10 strategies probably don't add significant diversification

---

## 6. Audit Recommendations

If this protocol were to go to mainnet, the audit should focus on:

### 6.1 Critical Math

**Focus areas:**

1. **Performance fee calculation and distribution**
```solidity
// Overflow possible in (profit * keeper_incentive) / BASIS_POINTS?
// What happens if performance_fee = 10000 (100%)?
// What happens if treasury_split + founder_split != BASIS_POINTS?
```

2. **Weighted allocation in _computeTargets()**
```solidity
// Does normalization sum exactly to 10000?
// What happens if total_apy = 0?
// What happens if a strategy reports APY = type(uint256).max?
```

3. **Shares <-> assets conversion (ERC4626)**
```solidity
// Are previewWithdraw and previewRedeem consistent?
// Can there be rounding that benefits the attacker?
// Does minting shares to treasury during harvest affect the exchange rate?
```

---

### 6.2 Edge Cases

**Extreme scenarios to test:**

1. **First deposit = min_deposit (0.01 ETH)**
   - Are shares calculated correctly?
   - Vulnerable to rounding attacks?

2. **One strategy with APY = 0**
   - Does _computeTargets() handle it correctly?
   - Does it receive allocation or get skipped?

3. **All strategies with APY = 0**
   - Does equal distribution work?

4. **Strategy.withdraw() reverts (lack of liquidity)**
   - Can the user withdraw or does the entire withdraw fail?

5. **Harvest when idle_buffer = 0 and keeper needs payment**
   - Does it correctly withdraw from strategies to pay keeper?

6. **Harvest returns profit < min_profit_for_harvest**
   - Do rewards accumulate without distributing fees?

7. **Strategy.harvest() reverts**
   - Does fail-safe continue with other strategies?

---

### 6.3 Integration with External Protocols

**Verify:**

1. **Aave v3 returns expected values**
   - What happens if `getReserveData()` reverts?
   - Can `claimAllRewards()` return 0 without reverting?

2. **Compound v3 returns uint64 in getSupplyRate()**
   - Is the conversion to uint256 safe?
   - Overflow when multiplying by 315360000000?
   - Can `claim()` return 0 without reverting?

3. **Uniswap V3 swap edge cases**
   - What happens if the pool doesn't exist?
   - What happens if the deadline expires?
   - Does slippage protection work with very small amounts?

4. **aTokens (Aave) rebase correctly**
   - Does `balanceOf()` always include accumulated yield?

---

### 6.4 Reentrancy

**Points of attention:**

1. **Do all external calls follow CEI?**
   - Especially in `_withdraw()`, `harvest()`, `_distributePerformanceFee()`

2. **Does SafeERC20 protect against reentrancy via ERC777?**
   - WETH is not ERC777, but good practice

3. **Can harvest() be called recursively?**
   - Through strategy.harvest() -> callback -> vault.harvest()

---

### 6.5 Access Control

**Verify:**

1. **Are all setters onlyOwner?**
2. **Are allocate/withdrawTo/harvest really onlyVault?**
3. **Are deposit/withdraw/harvest of strategies onlyManager?**
4. **Can rebalance be called by anyone? (it should be public)**
5. **Can initialize() only be called once?**

---

## 7. Security Conclusion

### Protocol Strengths

**Modular and clear architecture**
- Separation of concerns (Vault, Manager, Strategies)
- Easy to audit and reason about

**Use of industry standards**
- ERC4626 (OpenZeppelin)
- SafeERC20 for all transfers
- Pausable for emergency stop

**Economic protections**
- Min deposit prevents rounding attacks
- Min profit prevents harvest spam
- Slippage protection on swaps (1%)

**Multiple circuit breakers**
- Max TVL, min deposit, allocation caps, max strategies
- Emergency pause

**Harvest fail-safe**
- Individual try-catch per strategy
- If one fails, the others continue

**Permissionless for critical operations**
- Rebalance is public (anyone can execute if it's profitable)
- Harvest is public (incentivized for external keepers)
- AllocateIdle is public (if idle >= threshold)

### Known Weaknesses

**Ownership centralization**
- Single point of failure if owner loses key
- Mitigation: Use multisig in production

**Trust in added strategies**
- Owner can add a malicious strategy
- Mitigation: Whitelist + audits

**Dependency on external protocols**
- If Aave/Compound/Uniswap have an exploit, funds are at risk
- Mitigation: Allocation caps (max 50%), fail-safe harvest

**Illiquid treasury shares**
- Treasury accumulates shares it cannot easily sell
- Mitigation: Deliberate design (auto-compound > liquidity)

**Harvest depends on Uniswap**
- If reward token pools don't have liquidity, harvest fails
- Mitigation: Fail-safe, rewards accumulate for next attempt

### Final Recommendations

**To launch on mainnet:**

1. **Professional audit** (Trail of Bits, OpenZeppelin, Consensys)
2. **Extended testnet** (Sepolia -> Mainnet)
3. **Bug bounty** (Immunefi, Code4rena)
4. **Multisig as owner** (minimum 3/5)
5. **On-chain monitoring** (Forta, Tenderly)
6. **Documented emergency playbook**
7. **Gradual TVL** (start with max_tvl = 100 ETH, increase gradually)

**For educational use:**
- Code is production-grade and secure
- Architecture is solid and extensible
- Good practices implemented (CEI, SafeERC20, fail-safe, slippage protection)
- DO NOT use on mainnet without a formal audit

---

**End of security documentation.**

For more information, see:
- [ARCHITECTURE.md](ARCHITECTURE.md) - Design decisions
- [CONTRACTS.md](CONTRACTS.md) - Contract documentation
- [FLOWS.md](FLOWS.md) - User flows
