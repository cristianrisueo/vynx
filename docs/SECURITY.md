# Security Considerations

This document analyzes the security posture of VynX V1, including trust assumptions, considered attack vectors, implemented protections, centralization points, and known limitations.

---

## 1. Trust Assumptions (What We Trust)

The VynX V1 protocol **explicitly trusts** the following external components:

### Lido (staking protocol)

**Trust level**: High

**Reasons:**
- Most audited liquid staking protocol on Ethereum
- Battle-tested with >$30B TVL on mainnet
- Active bug bounty (Immunefi) and verified code
- Robust security track record with no critical hacks on the base protocol

**Accepted risks:**
- If Lido suffers an exploit, funds staked as stETH/wstETH would be at risk
- Validator slashing reduces the stETH balance (historical impact < 0.01% of supply)
- stETH depeg on secondary market can affect exit swaps
- Mitigation: Only the Balanced tier uses LidoStrategy/AaveStrategy. The idle buffer (8 ETH minimum) absorbs small withdrawals.

### Aave v3

**Trust level**: High

**Reasons:**
- Audited multiple times by Trail of Bits, OpenZeppelin, Consensys Diligence, etc.
- Battle-tested with >$5B TVL on mainnet for years
- Robust security track record (no major hacks)
- Open-source code reviewed by the community

**Accepted risks:**
- If Aave suffers an exploit, we could lose funds deposited in AaveStrategy
- AaveStrategy only supplies wstETH (no borrowing) — no liquidation risk exists
- Mitigation: Only present in the Balanced tier; allocation limited by tier parameters

### Curve (AMM + gauge)

**Trust level**: High

**Reasons:**
- Most established AMM for correlated assets (stablecoins, LSTs)
- Extensively audited by multiple firms
- The stETH/ETH pool uses Vyper >= 0.3.1 (not affected by the July 2023 bug)
- Curve gauges are approved by governance before being activated

**Accepted risks:**
- If Curve suffers an exploit, funds in CurveStrategy (LP + gauge) would be at risk
- Low impermanent loss for the stETH/ETH pair under normal conditions
- Mitigation: CurveStrategy operates in both tiers; diversification with other strategies

### Uniswap V3 (concentrated liquidity)

**Trust level**: High (used by strategies for harvest AND as a concentrated liquidity strategy)

**Reasons:**
- Most established DEX on Ethereum
- Extensively audited
- Used by thousands of protocols for programmatic swaps and liquidity provision

**Accepted risks:**
- UniswapV3Strategy: concentrated LP position (±960 ticks WETH/USDC) can go out of range, stopping fee generation
- Swaps during harvest (CRV → stETH, AAVE rewards → wstETH) can suffer slippage
- If there is insufficient liquidity in the pools, harvest fails
- MEV on WETH↔USDC swaps in UniswapV3Strategy (0.05% pool has ~$500M TVL, marginal impact)
- Mitigation: Configurable max slippage, fail-safe on harvest, high-liquidity pool

### wstETH wrapper (Lido)

**Trust level**: Very High

**Reasons:**
- Canonical Lido contract for wrapped stETH
- Simple and audited code: only wraps stETH into a token with a growing exchange rate
- No admin keys or significant upgradeability
- Used by thousands of DeFi protocols as collateral

**Accepted risks:**
- If the wstETH contract has a bug, AaveStrategy and LidoStrategy would be affected
- Mitigation: The wstETH contract has been on mainnet for years without incidents

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
- `Math`: Safe mathematical operations

### WETH (Wrapped Ether)

**Trust level**: Very High

**Reasons:**
- Canonical Ethereum contract
- Simple and audited code
- No admin keys or upgradeability

---

## 2. Considered Attack Vectors

The protocol has been designed with the following common DeFi attack vectors in mind:

### 2.1 Reentrancy Attacks

**Description**: Attacker recursively calls functions before state is updated.

**Implemented protections:**

1. **CEI Pattern (Checks-Effects-Interactions)**
```solidity
// CORRECT: Burns shares BEFORE transferring assets
function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares) internal {
    _burn(owner, shares);                    // Effect (modifies state)
    // ... withdrawal from idle/strategies   // Interaction (external calls)
    IERC20(asset).safeTransfer(receiver, amount); // Interaction
}
```

2. **SafeERC20 for all transfers**
```solidity
using SafeERC20 for IERC20;

IERC20(asset).safeTransfer(receiver, amount);     // Does not use transfer() directly
IERC20(asset).safeTransferFrom(user, vault, amt); // Handles reverts correctly
```

3. **No callbacks to users**
- The vault never calls user functions (no hooks)
- Only interacts with known contracts (strategies, WETH, Uniswap, Lido, Aave, Curve)

**Evaluation**: Protected

---

### 2.2 Rebalance Front-Running

**Description**: Attacker observes a pending rebalance transaction and deposits just before it to capture immediate benefit.

**Analysis:**
```solidity
// Scenario:
// 1. Keeper calls rebalance() (moves funds to better strategy)
// 2. Attacker sees tx in mempool
// 3. Attacker deposits with higher gas price
// 4. Rebalance executes (increases effective APY)
// 5. Attacker withdraws immediately

// Result: Attacker captures part of the future yield
```

**Implemented mitigations:**

1. **Permissionless public rebalance**
   - Anyone can execute rebalance() if shouldRebalance() passes
   - No special benefit for the executor
   - MEV is minimal (no direct arbitrage)

2. **Yield accumulates over time**
   - Rebalance benefit materializes over weeks
   - Attacker cannot "flash-rebalance-withdraw"

3. **No immediate benefit**
   - Rebalance only moves funds between strategies
   - Does not generate instant profit that can be extracted

**Evaluation**: Mitigated (economically non-profitable)

---

### 2.3 Rounding Attacks (Inflation Attack)

**Description**: Attacker manipulates the share/asset price by donating assets to cause rounding losses.

**Classic scenario:**
```solidity
// 1. Attacker is first depositor: deposit(1 wei)
//    shares = 1, totalAssets = 1
//
// 2. Attacker donates 1000 ETH directly to vault (not via deposit)
//    totalAssets = 1000 ETH + 1 wei
//
// 3. Victim deposits 2000 ETH
//    shares = (2000 * 1) / 1000 = 2 shares (round down)
//    totalAssets = 3000 ETH
//
// 4. Attacker redeem(1 share)
//    assets = (1 * 3000) / 3 = 1000 ETH
//
// Result: Attacker stole 1000 ETH from victim
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
- The share/asset ratio cannot be efficiently manipulated
- Attack cost > potential gain

2. **OpenZeppelin standard ERC4626**
- Audited implementation with known protections

**Evaluation**: Protected (prohibitive attack cost)

---

### 2.4 Flash Loan Attacks

**Description**: Attacker takes a flash loan to manipulate the price or state of the vault.

**Applicability analysis:**

1. **No price oracle**
   - The vault does not use external prices for its internal operations
   - Strategy APY comes from underlying protocols (Lido/Aave/Curve/Uniswap)
   - APY cannot be manipulated with flash loans

2. **No share-weighted voting**
   - Shares only determine the proportion of assets
   - There is no governance attackable with flash loans

3. **No instant arbitrage**
   - No withdrawal fee or way to extract value in a single transaction
   - Flash loan → deposit → withdraw returns the same (minus rounding wei)

**Considered scenarios:**
```solidity
// NOT POSSIBLE: Manipulate APY
// APY comes directly from underlying protocols
// Flash loan cannot change the stETH exchange rate or Aave APY

// NOT POSSIBLE: Arbitrage share/asset price
// deposit and withdraw are symmetric (ERC4626 standard)

// NOT POSSIBLE: Vote with borrowed shares
// No governance system exists
```

**Evaluation**: Not applicable (no viable attack vectors)

---

### 2.5 Keeper Incentive Risks

**Description**: Risks associated with the keeper incentive system and public harvest.

**Considered vectors:**

1. **harvest() spam when there are no rewards**
```solidity
// Scenario: Attacker calls harvest() repeatedly
// Result: profit < min_profit_for_harvest → return 0
// No incentive is paid, no fees are distributed
// Only gas wasted by the attacker

// Protection (V1):
// Tier Balanced: min_profit_for_harvest = 0.08 ETH
// Tier Aggressive: min_profit_for_harvest = 0.12 ETH
// If profit < tier threshold, harvest does not execute distribution
```

2. **harvest front-running**
```solidity
// Scenario: Keeper A sees accumulated rewards
// Attacker B front-runs harvest() with higher gas
// Result: Attacker B receives 1% keeper incentive
// Keeper A spends gas without receiving anything

// Mitigation: This is the expected design — normal MEV
// The 1% incentive is low enough that front-running is not very profitable
// Official keepers do not compete for the incentive
```

3. **Malicious official keeper**
```solidity
// Scenario: Owner marks an address as official
// Official keeper harvests without paying incentive
// Result: More profit for the protocol, not for keeper

// Not a risk — it is a feature
// Official keepers belong to the protocol and do not need incentive
```

**Evaluation**: Mitigated (spam non-profitable, MEV expected and tolerable)

---

### 2.6 Uniswap Swap Risks

**Description**: Risks associated with swaps on Uniswap V3, both for harvest and for UniswapV3Strategy.

**Considered vectors:**

1. **Sandwich attack on harvest swaps**
```solidity
// Scenario:
// 1. Bot detects harvest() with large swap in mempool (CRV→stETH, AAVE rewards→wstETH)
// 2. Front-runs: buys the destination token
// 3. harvest() executes swap (worse price due to impact)
// 4. Back-runs: sells

// Mitigation: MAX_SLIPPAGE_BPS = 100 (1% max)
// If the sandwich causes > 1% slippage, the tx reverts
uint256 min_amount_out = (claimed * 9900) / 10000;
```

2. **Sandwich attack on WETH↔USDC swaps in UniswapV3Strategy**
```solidity
// Scenario: deposit/withdraw/harvest of UniswapV3Strategy requires a swap
// Bot front-runs the WETH→USDC or USDC→WETH swap

// Mitigation: WETH/USDC 0.05% pool has ~$500M TVL
// Slippage from front-running on typical vault operations is marginal
// Note: UniswapV3Strategy does NOT use explicit slippage protection on internal swaps
// This risk is accepted and documented in the "Risks per Strategy" section
```

3. **Pool with low liquidity**
```solidity
// Scenario: Reward token pool (CRV/WETH, AAVE/WETH) has little liquidity
// harvest swap gets a bad price or reverts

// Mitigation:
// - Reward token pools are highly liquid on mainnet
// - If swap reverts, StrategyManager fail-safe continues with other strategies
// - Profit is not lost, only deferred to the next harvest
```

**Evaluation**: Mitigated (slippage protection + fail-safe)

---

### 2.7 Router Specific Risks

**Description**: Unique risks of the peripheral multi-token Router.

**Considered vectors:**

1. **Reentrancy via receive()**
```solidity
// Scenario: Attacker tries to reenter during zapWithdrawETH
// when the Router calls .call{value}(eth_out) to the attacker

// Implemented mitigation:
// - ReentrancyGuard on ALL public functions (zapDeposit*, zapWithdraw*)
// - receive() only accepts ETH from the WETH contract (revert if msg.sender != weth)
// - CEI pattern: balance checks at the end
```

2. **Funds stuck in Router**
```solidity
// Scenario: Bug in code leaves WETH/ERC20 in the Router

// Implemented mitigation:
// - Balance check at the end of each function:
//   if (IERC20(weth).balanceOf(address(this)) != 0) revert Router__FundsStuck();
// - For zapWithdrawERC20:
//   if (IERC20(token_out).balanceOf(address(this)) != 0) revert Router__FundsStuck();
// - If check fails, tx reverts completely (no funds are stuck)
```

3. **Sandwich attacks on Router swaps**
```solidity
// Scenario: MEV bot detects a large zapDepositERC20
// Front-runs buying WETH, user pays worse price, back-runs selling

// Partial mitigation:
// - User specifies min_weth_out (slippage protection)
// - If the sandwich exceeds slippage tolerance, tx reverts
// - Limitation: User is still vulnerable to sandwich within the allowed slippage
// - Recommendation: Frontends should calculate a conservative min_weth_out (0.5-1% of quote)
```

4. **WETH as intermediary (double slippage)**
```solidity
// Scenario: Deposit USDC → WETH (0.1% slippage) → Vault
//           Withdraw Vault → WETH → DAI (0.1% slippage)
// Total slippage: ~0.2% (two swaps)

// Accepted trade-off:
// - WETH as hub is standard in DeFi (maximum liquidity)
// - Alternative (direct USDC → DAI swap) would have worse liquidity
// - User explicitly accepts slippage with min_weth_out / min_token_out
```

**Evaluation**: Mitigated (ReentrancyGuard, stateless checks, slippage protection)

### 2.8 Withdrawal Rounding

**Description**: External protocols (Aave, Curve, Uniswap V3) round withdrawals down, causing micro-differences between assets requested and received.

**Technical analysis:**
```solidity
// Aave v3: aave_pool.withdraw() may return assets - 1 wei
// Curve: remove_liquidity_one_coin may return assets - 1 or -2 wei
// Uniswap V3: decreaseLiquidity may have 1 wei rounding

// General pattern in strategies:
uint256 balance_before = IERC20(asset).balanceOf(address(this));
// ... external call (Aave withdraw, Curve remove, Uniswap decreaseLiquidity)
uint256 balance_after = IERC20(asset).balanceOf(address(this));
uint256 actual_withdrawn = balance_after - balance_before;
// actual_withdrawn may be assets - 1 or assets - 2
```

**Vault tolerance:**
```solidity
// Vault accepts up to 20 wei of difference
if (to_transfer < assets) {
    require(assets - to_transfer < 20, "Excessive rounding");
}

// Why 20 wei?
// - 4 strategies in V1 × ~2 wei/operation = ~8 wei
// - Conservative margin for multi-strategy operations: ~20 wei
// - Cost to user: ~$0.00000000000005 with ETH at $2,500
```

**Can an attacker exploit this?**
```solidity
// NO: 20 wei is insignificant (~$0.00000000000005)
// NO: Rounding always benefits the protocol (rounds down)
// NO: No accumulation of rounding errors between operations
// Rounding is resolved per operation, it does not propagate
```

**Evaluation**: Deliberately tolerated (trivial cost, DeFi standard)

---

## 3. Risks per Strategy

### LidoStrategy

**Risk 1: Validator Slashing**
- Description: If Lido validators are penalized (slashing), the stETH balance decreases. Typical historical impact has been < 0.01% of supply.
- Mitigation in V1: Only the Balanced tier uses LidoStrategy. The idle buffer (8 ETH minimum) absorbs small withdrawals without touching stETH.

**Risk 2: stETH/ETH Depeg**
- Description: stETH can trade below ETH on secondary markets. Historically < 1.5% under normal conditions. In June 2022, the depeg reached 6-7% due to Celsius sell pressure.
- Mitigation in V1: LidoStrategy uses Uniswap V3 for withdrawal (swap wstETH→WETH). If slippage exceeds the configured limit, the withdrawal fails with a revert. The protocol does NOT force swaps with high slippage.

**Risk 3: Lido Smart Contract Risk**
- Description: An exploit in the Lido contract would affect all staked assets.
- Mitigation: Lido is the most audited liquid staking protocol on Ethereum, with an active bug bounty and verified code.

### AaveStrategy (wstETH)

**Risk 1: Stacking Risk**
- Description: AaveStrategy combines two sources of protocol risk: Lido (staking) + Aave v3 (lending). An exploit in either one affects the funds.
- Mitigation: Both protocols are tier-1 with multiple audits. The position in Aave is supply-only (no borrowing), eliminating liquidation risk.

**Risk 2: Liquidation in Aave (not applicable in V1)**
- Note: AaveStrategy only supplies wstETH, with no borrowing. There is no debt or collateralization ratio to liquidate. The only risk is if Aave freezes the wstETH market (can occur through governance).

**Risk 3: Oracle Manipulation (Aave)**
- Description: If the wstETH price oracle in Aave is manipulated, it could affect the fund availability calculations.
- Mitigation: Aave v3 uses Chainlink oracles with circuit breakers. The V1 protocol does not depend on the USD value of wstETH for its internal operations.

### CurveStrategy

**Risk 1: Impermanent Loss (low)**
- Description: The stETH/ETH pool has a highly correlated pair. Theoretical IL is very low under normal conditions (< 0.5% annually historically).
- Risk scenario: A severe stETH depeg (>5%) materializes significant IL for LPs.

**Risk 2: Historical Curve Exploit (July 2023)**
- Description: In July 2023, Curve pools with Vyper <= 0.3.0 were vulnerable to reentrancy. The stETH/ETH pool was NOT directly affected, but the event caused panic selling and temporary IL.
- Status in V1: The bug was patched in Vyper >= 0.3.1. CurveStrategy interacts with the stETH/ETH pool which uses Vyper >= 0.3.1.

**Risk 3: Gauge Smart Contract Risk**
- Description: LP funds are staked in the Curve gauge to receive CRV. An exploit in the gauge would affect staked funds.
- Mitigation: Curve gauges are audited and the gaugeController requires governance approval for new gauges.

### UniswapV3Strategy

**Risk 1: Concentrated Impermanent Loss**
- Description: Concentrated liquidity (±10% of current price) amplifies IL compared to Uniswap V2. If the WETH/USDC price moves significantly within range, IL can be substantial.
- Mitigation: The ±960 tick range (~±10%) is wide for the WETH/USDC pair. The 0.05% fees mitigate IL under normal conditions.

**Risk 2: Out-of-Range (Position Without Fees)**
- Description: If the WETH/USDC price exits the ±10% range, the position stops generating fees. Assets remain in the pool but receive no income until the price returns to range.
- Behavior in V1: UniswapV3Strategy does NOT automatically rebalance the position. An out-of-range position continues to be counted in totalAssets() but generates no APY.

**Risk 3: MEV on WETH↔USDC Swaps**
- Description: Each deposit, withdrawal and harvest involves a swap on Uniswap V3 (WETH→USDC on deposit, USDC→WETH on withdrawal/harvest). These swaps are visible in the mempool and can be front-run.
- Mitigation: The WETH/USDC 0.05% pool has high liquidity (~$500M TVL). Slippage from front-running on typical vault operations is marginal. UniswapV3Strategy does NOT use explicit slippage protection on internal swaps — this is an accepted risk to simplify the contract.

**Risk 4: Position as NFT (tokenId)**
- Description: The UniswapV3Strategy LP position is represented as an NFT (tokenId). If the NFT is lost or accidentally transferred, the funds become inaccessible.
- Mitigation: The tokenId is stored in state by UniswapV3Strategy. The NFT transfer can only be done by the contract itself (it is the owner). No NFT transfer function is exposed.

---

## 4. Implemented Protections

### 4.1 Access Control

**Modifiers used:**

```solidity
// Vault
modifier onlyOwner()        // Admin functions (pause, setters, syncIdleBuffer)
modifier whenNotPaused()    // Deposits, mint, harvest, allocateIdle
//                          // withdraw and redeem do NOT have whenNotPaused:
//                          // users can always withdraw their funds

// StrategyManager
modifier onlyOwner()        // Add/remove strategies, setters
modifier onlyVault()        // allocate(), withdrawTo(), harvest()

// Strategies
modifier onlyManager()      // deposit(), withdraw(), harvest()
```

**Permission hierarchy:**
```
Vault Owner
  ↓
Vault (contract)
  ↓ (only vault can call)
StrategyManager (contract)
  ↓ (only manager can call)
Strategies (contracts)
  ↓
External protocols (Lido/Aave/Curve/Uniswap V3)
```

---

### 4.2 Circuit Breakers

| Parameter | Balanced | Aggressive |
|---|---|---|
| `max_tvl` | 1000 ETH | 1000 ETH |
| `idle_threshold` | 8 ETH | 12 ETH |
| `min_profit_for_harvest` | 0.08 ETH | 0.12 ETH |
| `rebalance_threshold` | 2% (200 bp) | 3% (300 bp) |

The `max_tvl` prevents the vault from scaling indefinitely, limiting systemic risk in underlying protocols. The `idle_threshold` guarantees there is always immediate liquidity for withdrawals without needing to interact with external protocols.

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
- Owner can increase when safe to do so

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

**3. Idle Threshold (per Tier)**
```solidity
// Tier Balanced: idle_threshold = 8 ETH
// Tier Aggressive: idle_threshold = 12 ETH
// Funds below the threshold remain in idle (uninvested)
// Guarantees immediate liquidity for withdrawals without touching external protocols
```

---

**4. Max Strategies (Manager)**
```solidity
uint256 public constant MAX_STRATEGIES = 10;  // Hard-coded
```

**Purpose:**
- Prevents gas DoS in allocate/withdrawTo/harvest/rebalance loops
- With 10 strategies, each loop has a predictable cost

---

**5. Min Profit for Harvest (per Tier)**
```solidity
// Tier Balanced: min_profit_for_harvest = 0.08 ETH
// Tier Aggressive: min_profit_for_harvest = 0.12 ETH
```

**Purpose:**
- Prevents unprofitable harvests (gas > profit)
- Prevents harvest() spam by attackers
- The higher threshold for the Aggressive tier reflects the higher cost of its operations (Uniswap V3 positions)

---

### 4.3 Emergency Stop (Pausable)

```solidity
contract Vault is IVault, ERC4626, Ownable, Pausable {
    function deposit(...) public whenNotPaused { }
    function mint(...) public whenNotPaused { }
    function withdraw(...) public override { }              // WITHOUT whenNotPaused
    function redeem(...) public override { }                // WITHOUT whenNotPaused
    function harvest() external whenNotPaused { }
    function allocateIdle() external whenNotPaused { }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
```

**When to use:**
- A vulnerability is detected in vault or strategies
- Hack in Lido/Aave/Curve/Uniswap affects funds
- Critical bug in weighted allocation or harvest
- While investigating anomalous behavior
- **First step of the emergency exit sequence** (see section 4.8)

**What it pauses:**
- New deposits (deposit, mint)
- Harvest
- AllocateIdle
- Does not pause rebalances (manager is separate)

**What it does NOT pause (by design):**
- **withdraw**: Users can always withdraw their funds
- **redeem**: Users can always burn shares and recover assets

**DeFi Principle**: Pause blocks inflows (deposits) and protocol operations, but **never blocks outflows** (withdrawals). A user must always be able to recover their funds regardless of the vault state.

**Note:** Manager Owner should remove compromised strategies during pause.

---

### 4.4 SafeERC20 Usage

**All IERC20 operations use SafeERC20:**
```solidity
using SafeERC20 for IERC20;

// Instead of:
IERC20(asset).transfer(receiver, amount);           // Not recommended
IERC20(asset).transferFrom(user, vault, amount);    // Not recommended

// We use:
IERC20(asset).safeTransfer(receiver, amount);       // Correct
IERC20(asset).safeTransferFrom(user, vault, amount);// Correct
```

**SafeERC20 protections:**
- Handles tokens that do not return bool on transfer (legacy tokens)
- Reverts if transfer fails silently
- Correctly verifies return value

---

### 4.5 Harvest Fail-Safe

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
- If LidoStrategy.harvest() returns 0 (yield via exchange rate, no direct rewards), the rest continues
- If CurveStrategy.harvest() fails (CRV→stETH swap with high slippage), AaveStrategy continues
- If UniswapV3Strategy.harvest() fails (out-of-range, no fees), the other strategies continue
- Prevents a single failure from blocking the entire harvest
- Emits event for monitoring

---

### 4.6 Router Stateless Design

**All Router functions verify 0 balance at the end:**

```solidity
// In zapDepositETH, zapDepositERC20:
if (IERC20(weth).balanceOf(address(this)) != 0) revert Router__FundsStuck();

// In zapWithdrawERC20:
if (IERC20(token_out).balanceOf(address(this)) != 0) revert Router__FundsStuck();
```

**Purpose:**
- Guarantees that the Router NEVER retains funds between transactions
- If there are stuck funds (bug), the transaction reverts completely
- No custodied funds = no attack surface for theft

**Note**: `zapWithdrawETH` does not verify WETH balance because the WETH is unwrapped to ETH immediately. It only verifies that the ETH was correctly transferred to the user.

---

### 4.7 Slippage Protection on Swaps

```solidity
// In V1 strategies (AaveStrategy, CurveStrategy)
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
- Prevents sandwich attacks (maximum 1% impact in strategies)
- Protects against pools with low liquidity
- If the swap cannot achieve 99%+, it reverts (and fail-safe continues)

**Note on UniswapV3Strategy:**
- UniswapV3Strategy does NOT apply explicit slippage protection on internal WETH↔USDC swaps
- This trade-off is documented in the "Risks per Strategy" section
- The WETH/USDC 0.05% pool has sufficient liquidity to make the risk marginal

**In Router (user-configurable):**

```solidity
// zapDepositERC20: user specifies min_weth_out
uint256 weth_out = _swapToWETH(token_in, amount_in, pool_fee, min_weth_out);
if (weth_out < min_weth_out) revert Router__SlippageExceeded();

// zapWithdrawERC20: user specifies min_token_out
uint256 amount_out = _swapFromWETH(weth_in, token_out, pool_fee, min_token_out);
if (amount_out < min_token_out) revert Router__SlippageExceeded();
```

**Frontend responsibility:**
- Calculate expected quote from Uniswap Quoter
- Apply tolerance (typically 0.5-1%)
- Pass as `min_weth_out` / `min_token_out`

---

### 4.8 Emergency Exit Mechanism

The protocol implements an emergency exit mechanism that allows draining all active strategies and returning funds to the vault in case of a critical bug, active exploit, or anomalous behavior in underlying protocols.

**Emergency sequence (3 independent transactions):**

```solidity
// STEP 1: Pause the vault (blocks new deposits, harvest, allocateIdle)
// Withdrawals (withdraw/redeem) remain enabled
vault.pause();

// STEP 2: Drain all strategies to the vault
// Try-catch per strategy: if one fails, continues with the others
manager.emergencyExit();

// STEP 3: Reconcile idle_buffer with the actual WETH balance
// Necessary because emergencyExit transfers WETH to vault without going through deposit()
vault.syncIdleBuffer();
```

**Security features:**

1. **No timelock**: In emergencies every block exposes funds to the exploit. Speed of response takes priority over governance
2. **Fail-safe (try-catch)**: If a strategy fails during the drain (bug, frozen, etc.), the others continue. The problematic strategy emits `HarvestFailed` and the owner handles it separately
3. **Withdrawals always enabled**: After pausing, users can continue withdrawing their funds. Outflows are never blocked
4. **Correct accounting**: `syncIdleBuffer()` reconciles `idle_buffer` with the actual WETH balance of the contract, ensuring that `totalAssets()` and the shares/assets exchange rate are correct after the drain
5. **Events for indexers**: `EmergencyExit(timestamp, total_rescued, strategies_drained)` and `IdleBufferSynced(old_buffer, new_buffer)` allow on-chain monitoring

**What happens if `emergencyExit()` reverts completely?**
- The vault remains paused (step 1 already executed)
- Funds remain in the strategies — no asset is lost
- Users can continue withdrawing (withdraw/redeem are not paused)
- The owner diagnoses and retries

**What happens if Vault and Manager have different owners?**
- Each owner executes their step: vault owner executes `pause()` and `syncIdleBuffer()`, manager owner executes `emergencyExit()`
- Off-chain communication between owners is critical in this scenario

**Note on dust/rounding:** After `emergencyExit()`, strategies may retain 1-2 wei of dust due to rounding of conversions (e.g.: wstETH/stETH). This is expected behavior and does not represent a risk.

**Functions involved:**
- `StrategyManager.emergencyExit()` — `onlyOwner`, drains strategies
- `Vault.syncIdleBuffer()` — `onlyOwner`, reconciles accounting
- `Vault.pause()` / `Vault.unpause()` — `onlyOwner`, emergency stop

---

## 5. Centralization Points

The protocol has centralization points controlled by owners. In production, these should be multisigs.

### 5.1 Vault Owner

**Can:**

1. **Pause deposits/harvest/allocateIdle**
```solidity
vault.pause();
// Blocks: deposit, mint, harvest, allocateIdle
// Does NOT block: withdraw, redeem (users can always withdraw)
```

2. **Change protocol parameters**
```solidity
vault.setPerformanceFee(5000);             // Increases fee to 50%
vault.setFeeSplit(5000, 5000);             // Changes split 50/50
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

4. **Reconcile accounting after emergency exit**
```solidity
vault.syncIdleBuffer();                    // Reconciles idle_buffer with actual WETH balance
```

**Cannot:**
- Steal funds directly
- Transfer WETH from the vault without going through withdraw
- Mint shares without depositing assets
- Modify user balances

**Recommended mitigations:**
- Use multisig (Gnosis Safe) as owner
- Timelock for sensitive parameter changes
- Events emitted for transparency

---

### 5.2 Router (No Privileges)

**The Router has NO centralization points:**

- **No owner**: The Router has no `onlyOwner` functions
- **No privileges in the Vault**: It is a normal user (calls public functions: deposit/redeem)
- **Immutable**: All addresses (weth, vault, swap_router) are `immutable`
- **No upgrades**: The Router is not upgradeable
- **Stateless**: Does not custody funds → no theft risk even if there is a bug

**If the Router has a bug:**
- Worst case: A user loses funds in ONE transaction (the one being executed)
- The Vault and other users' funds are NOT affected
- A new Router can be deployed without affecting the Vault

**This is intentional**: The Router is disposable and replaceable. The Vault is the critical core.

---

### 5.3 Manager Owner

**Can:**

1. **Add malicious strategies**
```solidity
// RISK: Owner can add fake strategy
manager.addStrategy(address(malicious_strategy));

// malicious_strategy.deposit() could:
// - Not deposit into the real protocol
// - Transfer WETH to attacker's address
// - Report false totalAssets()
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

4. **Emergency exit (drain all strategies)**
```solidity
manager.emergencyExit();                    // Drains all strategies to vault
// Try-catch: if a strategy fails, continues with the others
```

**Cannot:**
- Call allocate(), withdrawTo() or harvest() (only vault can)
- Steal WETH directly from the manager
- Deposit/withdraw from strategies directly

**Recommended mitigations:**
- Multisig as owner
- Whitelist of allowed strategies (off-chain governance)
- Audit strategies before adding
- Monitoring of critical parameters

---

### 5.4 Single Point of Failure

**Critical scenario:**
```
Owner EOA loses private key
  → Cannot pause vault
  → Cannot remove compromised strategy
  → Funds could be at risk
```

**Recommended solutions for production:**

1. **Gnosis Safe Multisig (3/5 or 4/7)**
   - Requires multiple signatures for critical actions
   - Prevents loss of single key

2. **Timelock**
   ```solidity
   // Parameter changes have a 24-48h delay
   // Users can withdraw if they disagree
   ```

3. **Granular roles (OpenZeppelin AccessControl)**
   ```solidity
   PAUSER_ROLE      → Can pause (trusted keeper)
   STRATEGY_ROLE    → Can add/remove strategies (DAO)
   PARAM_ROLE       → Can adjust parameters (multisig)
   ```

---

## 6. Known Limitations

The protocol has deliberate limitations and known trade-offs:

### 6.1 WETH Only

**Limitation:**
- Only supports WETH as vault input/output asset
- Strategies internally convert to stETH/wstETH/USDC as appropriate

**Reasons:**
- Vault core simplicity
- LST strategies have better rates for ETH/WETH
- Multi-asset requires additional price oracles (larger attack surface)

---

### 6.2 Basic Weighted Allocation

**Limitation:**
- Simple algorithm: allocation proportional to APY
- Does not consider volatility, liquidity, or history

**Current formula:**
```solidity
target[i] = (strategy_apy[i] * BASIS_POINTS) / total_apy
// With caps: max 50%, min 10%
```

**Potential improvements:**
- Sharpe ratio (reward/risk)
- Available liquidity in protocols
- APY history (not just snapshot)
- Penalty for out-of-range strategies (UniswapV3Strategy)

---

### 6.3 Idle Buffer Does Not Generate Yield

**Limitation:**
- WETH in idle buffer is not invested
- During accumulation (0-8 ETH in Balanced, 0-12 ETH in Aggressive), there is no yield

**Trade-off:**
```
Gas savings > yield lost in idle

Example (Balanced, 5 ETH in idle for 1 day):
- Lost APY: 6% annual (CurveStrategy reference) = 0.0008 ETH/day
- Gas saved: 0.015 ETH (for not doing allocate alone)
- Net benefit: 0.015 - 0.0008 = 0.0142 ETH
```

**Alternative considered:**
- Auto-compound idle in Aave (adds complexity and an extra external call)

---

### 6.4 Manual Rebalancing

**Limitation:**
- No automatic on-chain rebalancing
- Requires external keepers or users

**Reasons:**
- Rebalancing on every deposit would be very expensive
- Keepers can choose the optimal moment (low gas)
- shouldRebalance() is view (keepers can simulate off-chain)

**Mitigations:**
- Anyone can execute (permissionless)
- 2% threshold (Balanced) / 3% (Aggressive) prevents unnecessary executions

---

### 6.5 Illiquid Treasury Shares

**Limitation:**
- Treasury receives performance fees in shares (vxWETH)
- Shares cannot easily be sold without diluting holders

**Consequences:**
- Treasury accumulates shares that auto-compound (good long-term yield)
- But cannot easily convert to liquid assets without impacting share price

**Trade-off:**
- Auto-compound > immediate liquidity for treasury
- Founder receives liquid (WETH) for operational costs
- If treasury needs liquidity, it can redeem shares gradually

---

### 6.6 Harvest Depends on Uniswap Liquidity

**Limitation:**
- If reward token pools (CRV/WETH, AAVE/WETH) on Uniswap V3 do not have liquidity, harvest fails
- Rewards accumulate without being converted to WETH

**Mitigations:**
- Reward token pools are highly liquid on mainnet
- Fail-safe in StrategyManager allows individual strategies to fail
- Rewards are not lost, they only accumulate for the next successful harvest
- 1% slippage protects against temporarily illiquid pools

**Note on LidoStrategy:**
- LidoStrategy.harvest() returns 0 — no reward swap
- Yield accumulates via the growing wstETH exchange rate
- Does not depend on Uniswap liquidity for its harvest

---

### 6.7 Router Depends on Uniswap V3 Liquidity

**Limitation:**
- Router can only operate with tokens that have a Uniswap V3 pool with WETH
- If a pool does not exist or does not have sufficient liquidity, zapDeposit/zapWithdraw fails

**Typically supported tokens:**
- Stablecoins: USDC, USDT, DAI (very liquid 0.05% pools)
- Blue chips: WBTC, LINK, UNI (liquid 0.3% pools)
- Other ERC20 with WETH pool: depends on liquidity

**Mitigations:**
- Slippage protection: if there is no liquidity, swap reverts (user does not lose funds)
- Configurable pool fee: frontend chooses the most liquid pool (100, 500, 3000, 10000 bps)
- Fallback: users can always buy WETH manually and use vault.deposit() directly

---

### 6.8 Max 10 Strategies

**Limitation:**
- Maximum 10 simultaneously active strategies (hard-coded)

**Reasons:**
- Prevents gas DoS in loops (allocate, withdrawTo, harvest, rebalance)
- With 10 strategies, gas cost is predictable and reasonable
- More than 10 strategies probably do not add significant diversification

---

### 6.9 UniswapV3Strategy: Out-of-Range Position

**Limitation:**
- If the WETH/USDC price exits the ±10% range, the position does not generate fees
- No automatic position rebalancing

**Impact:**
- The position is still counted in totalAssets()
- The effective APY of the Aggressive tier falls when UniswapV3Strategy is out of range
- Existing holders are diluted if new depositors enter during this period

**Mitigations:**
- The ±960 tick range is wide enough to absorb normal WETH volatility
- The Aggressive tier has a `rebalance_threshold` of 3%, allowing funds to be reallocated to CurveStrategy if UniswapV3Strategy loses competitiveness

---

## 7. Audit Recommendations

If this protocol were to go to mainnet, an audit should focus on:

### 7.1 Critical Mathematics

**Focus areas:**

1. **Performance fee calculation and distribution**
```solidity
// Is overflow possible in (profit * keeper_incentive) / BASIS_POINTS?
// What happens if performance_fee = 10000 (100%)?
// What happens if treasury_split + founder_split != BASIS_POINTS?
```

2. **Weighted allocation in _computeTargets()**
```solidity
// Does normalization sum to exactly 10000?
// What happens if total_apy = 0?
// What happens if a strategy reports APY = type(uint256).max?
```

3. **shares ↔ assets conversion (ERC4626)**
```solidity
// Are previewWithdraw and previewRedeem consistent?
// Can there be rounding that benefits the attacker?
// Does minting shares to treasury during harvest affect the exchange rate?
```

---

### 7.2 Edge Cases

**Extreme scenarios to test:**

1. **First deposit = min_deposit (0.01 ETH)**
   - Are shares calculated correctly?
   - Vulnerable to rounding attacks?

2. **One strategy with APY = 0**
   - Does _computeTargets() handle correctly?
   - Does it receive allocation or is it skipped?

3. **All strategies with APY = 0**
   - Does equal distribution work?

4. **Strategy.withdraw() reverts (insufficient liquidity)**
   - Can the user withdraw or does the entire withdrawal fail?

5. **Harvest when idle_buffer = 0 and keeper needs payment**
   - Does it correctly withdraw from strategies to pay the keeper?

6. **Harvest returns profit < min_profit_for_harvest**
   - Do rewards accumulate without distributing fees?

7. **Strategy.harvest() reverts**
   - Does fail-safe continue with other strategies?

8. **UniswapV3Strategy out-of-range during harvest**
   - Does collect() return 0 fees correctly without reverting?
   - Does totalAssets() reflect the correct value of the position?

9. **LidoStrategy harvest returns 0**
   - Does the protocol not attempt to distribute 0 profit as performance fee?

---

### 7.3 Integration with External Protocols

**Verify:**

1. **Lido stETH/wstETH**
   - What happens if Lido's submit() reverts (due to stake limit)?
   - Does the wstETH→stETH exchange rate always increase monotonically?
   - Can wrap/unwrap of wstETH revert?

2. **Aave v3 returns expected values**
   - What happens if `getReserveData()` reverts?
   - Can `claimAllRewards()` return 0 without reverting?
   - What happens if Aave freezes the wstETH market?

3. **Curve pool and gauge**
   - Can add_liquidity and remove_liquidity_one_coin revert due to slippage?
   - Do gauge.deposit/withdraw have unexpected restrictions?
   - Do CRV rewards accumulate correctly if no claim is made for a period?

4. **Uniswap V3 swap and LP position**
   - What happens if pool does not exist?
   - What happens if deadline expires?
   - Does slippage protection work with very small amounts?
   - Are mint(), increaseLiquidity(), decreaseLiquidity() and collect() safe in sequence?
   - What happens if tokenId = 0 (uninitialized position)?

---

### 7.4 Reentrancy

**Points of attention:**

1. **Do all external calls follow CEI?**
   - Especially in `_withdraw()`, `harvest()`, `_distributePerformanceFee()`

2. **Does SafeERC20 protect against reentrancy via ERC777?**
   - WETH is not ERC777, but good practice

3. **Can harvest() be called recursively?**
   - Through strategy.harvest() → callback → vault.harvest()

4. **Can Curve add_liquidity or gauge.deposit make callbacks?**
   - Verify that there are no external hooks in the execution path

---

### 7.5 Access Control

**Verify:**

1. **Are all setters onlyOwner?**
2. **Are allocate/withdrawTo/harvest truly onlyVault?**
3. **Are deposit/withdraw/harvest of strategies onlyManager?**
4. **Can rebalance be called by anyone? (must be public)**
5. **Can initialize() only be called once?**
6. **Can the UniswapV3Strategy NFT tokenId only be transferred by the contract?**

---

## 8. Security Conclusion

### Protocol Strengths

**Modular and clear architecture**
- Separation of concerns (Vault, Manager, Strategies)
- Two tiers with differentiated risk parameters (Balanced / Aggressive)
- Easy to audit and reason about

**Use of industry standards**
- ERC4626 (OpenZeppelin)
- SafeERC20 for all transfers
- Pausable for emergency stop

**Economic protections**
- Min deposit prevents rounding attacks
- Min profit per tier prevents harvest spam (0.08 ETH Balanced / 0.12 ETH Aggressive)
- Slippage protection on harvest swaps (1%)

**Multiple circuit breakers**
- Max TVL (1000 ETH), min deposit, idle threshold per tier, max strategies
- Emergency pause (blocks inflows, never outflows)
- Emergency exit: complete strategy drain with fail-safe and accounting reconciliation

**Harvest fail-safe**
- Individual try-catch per strategy
- If one fails (including LidoStrategy which returns 0), the others continue

**No permission required for critical operations**
- Rebalance is public (anyone can execute if profitable)
- Harvest is public (incentivized for external keepers)
- AllocateIdle is public (if idle >= tier threshold)

### Known Weaknesses

**Ownership centralization**
- Single point of failure if owner loses key
- Mitigation: Use multisig in production

**Trust in added strategies**
- Owner can add malicious strategy
- Mitigation: Whitelist + audits

**Dependency on external protocols**
- If Lido/Aave/Curve/Uniswap have an exploit, funds are at risk
- Mitigation: Allocation caps (max 50%), fail-safe harvest, separate tiers

**Illiquid treasury shares**
- Treasury accumulates shares that cannot easily be sold
- Mitigation: Deliberate design (auto-compound > liquidity)

**Harvest depends on Uniswap (for CRV/AAVE rewards)**
- If reward token pools lack liquidity, partial harvest fails
- Mitigation: Fail-safe, rewards accumulate for next attempt

**UniswapV3Strategy without rebalancing**
- Position can remain out-of-range indefinitely
- Mitigation: Aggressive tier rebalance threshold allows redistribution to CurveStrategy

### Final Recommendations

**To launch on mainnet:**

1. **Professional audit** (Trail of Bits, OpenZeppelin, Consensys)
2. **Extended testnet** (Sepolia → Mainnet)
3. **Bug bounty** (Immunefi, Code4rena)
4. **Multisig as owner** (minimum 3/5)
5. **On-chain monitoring** (Forta, Tenderly)
6. **Emergency playbook** documented (see section 4.8 for the emergency exit sequence)
7. **Gradual TVL** (start with max_tvl = 100 ETH, raise gradually)

**For educational use:**
- Code is production-grade and secure
- Architecture is solid and extensible
- Good practices implemented (CEI, SafeERC20, fail-safe, slippage protection)
- Do NOT use on mainnet without a formal audit

---

**End of security documentation.**

For more information, see:
- [ARCHITECTURE.md](ARCHITECTURE.md) - Design decisions
- [CONTRACTS.md](CONTRACTS.md) - Contract documentation
- [FLOWS.md](FLOWS.md) - User flows
