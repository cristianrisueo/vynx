# Testing

This document describes the VynX V1 test suite (Vault + Router + 4 Strategies), including structure, files, coverage and execution details.

---

## Overview

All tests run against a real **Ethereum Mainnet fork** via Alchemy. No mocks are used: interactions with Lido, Aave v3, Curve and Uniswap V3 are real against the blockchain state. This guarantees that the tested behavior is identical to production.

```
test/
├── unit/                    # Unit tests per contract
│   ├── Vault.t.sol
│   ├── StrategyManager.t.sol
│   ├── LidoStrategy.t.sol
│   ├── AaveStrategy.t.sol
│   ├── CurveStrategy.t.sol
│   ├── UniswapV3Strategy.t.sol
│   └── Router.t.sol
├── integration/             # End-to-end integration tests
│   └── FullFlow.t.sol
├── fuzz/                    # Stateless fuzz tests
│   └── Fuzz.t.sol
└── invariant/               # Stateful invariant tests
    ├── Invariants.t.sol
    └── Handler.sol
```

**Total: 160 tests** (145 unit + 10 integration + 6 fuzz + 4 invariants × 32 runs)

> The 149 tests without invariants pass consistently. The 11 failures that may appear in `forge coverage` are always HTTP 429 (RPC rate limiting), not code errors.

### Execution

```bash
# Configure RPC
export MAINNET_RPC_URL="https://eth-mainnet.g.alchemy.com/v2/<API_KEY>"

# Run unit + integration + fuzz (149 tests, excluding invariants)
forge test --no-match-path "test/invariant/*" -vv

# Run invariant tests (requires Anvil with rate limiting)
./script/run_invariants_offline.sh

# Coverage (requires --ir-minimum due to stack-too-deep)
forge coverage --no-match-path "test/invariant/*" --ir-minimum
```

---

## 1. Unit Tests

Isolated tests per contract. They validate each public function with happy paths and revert paths.

### Vault.t.sol — `test/unit/Vault.t.sol`

50 tests covering the ERC4626 vault: deposits, withdrawals, minting, redeeming, fees, idle buffer, keeper incentives, emergency exit and admin.

| Test | Description |
| --- | --- |
| `test_Deposit_Basic` | Depositing generates shares and updates idle buffer |
| `test_Deposit_TriggersAllocation` | Deposit exceeding threshold sends funds to strategies |
| `test_Deposit_RevertZero` | Revert if amount is 0 |
| `test_Deposit_RevertBelowMin` | Revert if amount < min_deposit |
| `test_Deposit_RevertExceedsMaxTVL` | Revert if max_tvl is exceeded |
| `test_Deposit_RevertWhenPaused` | Revert if vault is paused |
| `test_Mint_Basic` | Directly minting shares works correctly |
| `test_Mint_RevertZero` | Revert if shares is 0 |
| `test_Mint_RevertExceedsMaxTVL` | Revert if mint would exceed max_tvl |
| `test_Mint_RevertWhenPaused` | Revert if vault is paused |
| `test_Mint_TriggersAllocation` | Mint exceeding threshold sends funds to strategies |
| `test_Withdraw_FromIdle` | Withdrawal served from idle buffer |
| `test_Withdraw_FromStrategies` | Withdrawal that requires pulling from strategies |
| `test_Withdraw_FullAmount` | Full withdrawal works correctly |
| `test_Withdraw_WithAllowance` | Withdrawal with third-party allowance |
| `test_Withdraw_WorksWhenPaused` | Withdraw works even with vault paused |
| `test_Withdraw_FromStrategiesWhenPaused` | Withdraw from strategies works with vault paused |
| `test_Redeem_Basic` | Redeem burns shares and returns assets |
| `test_Redeem_WorksWhenPaused` | Redeem works even with vault paused |
| `test_AllocateIdle_RevertBelowThreshold` | Revert if idle < threshold when forcing manual allocation |
| `test_AllocateIdle_RevertWhenPaused` | Revert if vault is paused |
| `test_TotalAssets_IdlePlusManager` | totalAssets = idle_weth + manager.totalAssets() |
| `test_MaxDeposit_RespectsMaxTVL` | maxDeposit respects the maximum TVL |
| `test_MaxDeposit_AfterPartialDeposit` | maxDeposit updates after partial deposit |
| `test_MaxDeposit_ReturnsZeroAtCapacity` | maxDeposit returns 0 when max_tvl is reached |
| `test_MaxDeposit_ReturnsZeroWhenPaused` | maxDeposit returns 0 if vault is paused |
| `test_MaxMint_RespectsMaxTVL` | maxMint respects the maximum TVL |
| `test_FeeDistribution` | Fee distribution: 80% treasury (shares), 20% founder (WETH) |
| `test_HarvestWithExternalKeeper` | External keeper receives 1% of profit as incentive |
| `test_HarvestWithOfficialKeeper` | Official keeper receives no incentive |
| `test_Harvest_ZeroProfit` | Harvest with 0 profit does not distribute fees |
| `test_Harvest_RevertWhenPaused` | Revert if vault is paused |
| `test_Admin_OnlyOwnerCanSetParams` | Only the owner can modify parameters |
| `test_Getters_ReturnCorrectValues` | Getters return configured values |
| `test_SetPerformanceFee_RevertExceedsBasisPoints` | Revert if fee > 10000 bp |
| `test_SetFeeSplit_RevertInvalidSum` | Revert if splits don't add up to 10000 bp |
| `test_SetKeeperIncentive_RevertExceedsBasisPoints` | Revert if incentive > 10000 bp |
| `test_SetStrategyManager_RevertZeroAddress` | Revert if address(0) |
| `test_SetStrategyManager_Valid` | Strategy manager update works |
| `test_SetTreasury_RevertZeroAddress` | Revert if address(0) |
| `test_SetFounder_RevertZeroAddress` | Revert if address(0) |
| `test_SetTreasuryAndFounder_Valid` | Treasury and founder update works |
| `test_Constructor_RevertInvalidStrategyManager` | Revert if strategy manager is address(0) |
| `test_Constructor_RevertInvalidTreasury` | Revert if treasury is address(0) |
| `test_Constructor_RevertInvalidFounder` | Revert if founder is address(0) |
| `test_SyncIdleBuffer_UpdatesAfterExternalTransfer` | syncIdleBuffer reconciles idle_buffer with real WETH balance |
| `test_SyncIdleBuffer_EmitsEvent` | Emits IdleBufferSynced with correct values |
| `test_SyncIdleBuffer_Idempotent` | Calling syncIdleBuffer twice is idempotent |
| `test_SyncIdleBuffer_RevertIfNotOwner` | Only the owner can call syncIdleBuffer |
| `test_EmergencyFlow_EndToEnd` | Full flow: deposit → pause → emergencyExit → syncIdleBuffer → withdraw |

**Coverage**: 92.51% lines, 88.02% statements, 55.26% branches, 100.00% functions

### StrategyManager.t.sol — `test/unit/StrategyManager.t.sol`

24 tests covering allocation, withdrawals, rebalancing, strategy management, emergency exit and admin.

| Test | Description |
| --- | --- |
| `test_InitializeVault_RevertIfAlreadyInitialized` | Vault cannot be initialized twice |
| `test_Allocate_Basic` | Funds are distributed to strategies |
| `test_Allocate_RevertIfNotVault` | Only the vault can call allocate |
| `test_Allocate_RevertZero` | Revert if amount is 0 |
| `test_Allocate_RevertNoStrategies` | Revert if no strategies are registered |
| `test_WithdrawTo_Basic` | Proportional withdrawal from strategies works |
| `test_WithdrawTo_RevertIfNotVault` | Only the vault can call withdrawTo |
| `test_WithdrawTo_RevertZero` | Revert if amount is 0 |
| `test_AddStrategy_Basic` | Adding a strategy increments the counter |
| `test_AddStrategy_RevertDuplicate` | Revert if strategy already exists |
| `test_RemoveStrategy_Basic` | Removing a strategy decrements the counter |
| `test_RemoveStrategy_RevertNotFound` | Revert if strategy does not exist |
| `test_Rebalance_ExecutesSuccessfully` | Rebalance moves funds after APY change |
| `test_Rebalance_RevertIfNotProfitable` | Revert if rebalance is not profitable |
| `test_TotalAssets_SumsAllStrategies` | totalAssets correctly sums all strategies |
| `test_StrategiesCount` | Returns the correct number of strategies |
| `test_GetAllStrategiesInfo` | Returns correct info (names, APYs, TVLs, targets) |
| `test_Admin_OnlyOwnerCanSetParams` | Only the owner can modify manager parameters |
| `test_EmergencyExit_DrainsAllStrategies` | emergencyExit drains all strategies and transfers WETH to vault |
| `test_EmergencyExit_EmitsCorrectEvent` | Emits EmergencyExit with correct total_rescued and strategies_drained |
| `test_EmergencyExit_ManagerBalanceZero` | Manager WETH balance is ~0 after emergencyExit |
| `test_EmergencyExit_NoStrategies` | emergencyExit with 0 strategies does not revert (no-op) |
| `test_EmergencyExit_RevertIfNotOwner` | Only the owner can call emergencyExit |
| `test_EmergencyExit_ZeroBalanceStrategies` | emergencyExit with zero-balance strategies is a no-op |

**Coverage**: 81.46% lines, 81.27% statements, 52.08% branches, 100.00% functions

### LidoStrategy.t.sol — `test/unit/LidoStrategy.t.sol`

14 tests covering integration with Lido (staking ETH → wstETH).

| Test | Description |
| --- | --- |
| `test_Deposit_Basic` | Deposit converts WETH → ETH → wstETH correctly |
| `test_Deposit_RevertIfNotManager` | Only the manager can deposit |
| `test_Deposit_RevertZeroAmount` | Revert if amount is 0 |
| `test_Withdraw_Basic` | Partial withdrawal: wstETH → Uniswap V3 swap → WETH |
| `test_Withdraw_Full` | Full withdrawal leaves balance at 0 |
| `test_Withdraw_RevertIfNotManager` | Only the manager can withdraw |
| `test_Withdraw_RevertZeroAmount` | Revert if amount is 0 |
| `test_Harvest_AlwaysReturnsZero` | Harvest always returns 0 (yield via exchange rate) |
| `test_Harvest_RevertIfNotManager` | Only the manager can harvest |
| `test_TotalAssets_ZeroWithoutDeposits` | totalAssets is 0 without deposits |
| `test_TotalAssets_GrowsWithTime` | totalAssets grows over time (exchange rate) |
| `test_Apy_ReturnsValidValue` | APY returns 400 bp (4%) |
| `test_Name` | Returns correct name |
| `test_Asset` | Returns the WETH address |

**Coverage**: 90.91% lines, 91.30% statements, 66.67% branches, 90.00% functions

### AaveStrategy.t.sol — `test/unit/AaveStrategy.t.sol`

10 tests covering integration with Aave v3 (supply wstETH → aWstETH).

| Test | Description |
| --- | --- |
| `test_Deposit_Basic` | Deposit: WETH → ETH → wstETH → Aave supply → aWstETH |
| `test_Deposit_RevertIfNotManager` | Only the manager can deposit |
| `test_Withdraw_Basic` | Partial withdrawal: aWstETH → wstETH → swap → WETH |
| `test_Withdraw_Full` | Full withdrawal leaves balance at 0 |
| `test_Withdraw_RevertIfNotManager` | Only the manager can withdraw |
| `test_Apy_ReturnsValidValue` | Dynamic APY from Aave liquidity rate |
| `test_Name` | Returns correct name |
| `test_Asset` | Returns the WETH address |
| `test_AvailableLiquidity` | Available liquidity in Aave > 0 |
| `test_TotalAssets_ZeroWithoutDeposits` | totalAssets is 0 without deposits |

**Coverage**: 71.95% lines, 69.89% statements, 41.67% branches, 91.67% functions

### CurveStrategy.t.sol — `test/unit/CurveStrategy.t.sol`

15 tests covering integration with Curve (LP stETH/ETH + gauge staking).

| Test | Description |
| --- | --- |
| `test_Deposit_Basic` | Deposit: WETH → ETH → stETH → add_liquidity → gauge stake |
| `test_Deposit_RevertIfNotManager` | Only the manager can deposit |
| `test_Deposit_RevertZeroAmount` | Revert if amount is 0 |
| `test_Withdraw_Basic` | Partial withdrawal: gauge unstake → remove_liquidity → ETH → WETH |
| `test_Withdraw_Full` | Full withdrawal leaves balance at 0 |
| `test_Withdraw_RevertIfNotManager` | Only the manager can withdraw |
| `test_Withdraw_RevertZeroAmount` | Revert if amount is 0 |
| `test_Harvest_WithRewards` | Harvest: CRV → Uniswap swap → reinvests as LP |
| `test_Harvest_RevertIfNotManager` | Only the manager can harvest |
| `test_TotalAssets_ZeroWithoutDeposits` | totalAssets is 0 without deposits |
| `test_TotalAssets_GrowsWithTime` | totalAssets grows with virtual_price |
| `test_LpBalance_ZeroWithoutDeposits` | LP balance is 0 without deposits |
| `test_Apy_ReturnsValidValue` | APY returns 600 bp (6%) |
| `test_Name` | Returns correct name |
| `test_Asset` | Returns the WETH address |

**Coverage**: 95.12% lines, 97.09% statements, 71.43% branches, 100.00% functions

### UniswapV3Strategy.t.sol — `test/unit/UniswapV3Strategy.t.sol`

16 tests covering integration with Uniswap V3 (concentrated WETH/USDC liquidity).

| Test | Description |
| --- | --- |
| `test_Deposit_Basic` | Deposit: WETH → 50% swap USDC → mint NFT position |
| `test_Deposit_IncreasesExistingPosition` | Second deposit increases existing position |
| `test_Deposit_RevertIfNotManager` | Only the manager can deposit |
| `test_Deposit_RevertZeroAmount` | Revert if amount is 0 |
| `test_Withdraw_Basic` | Partial withdrawal: decrease liquidity → collect → swap → WETH |
| `test_Withdraw_Full_BurnsNFT` | Full withdrawal burns the position NFT |
| `test_Withdraw_RevertIfNotManager` | Only the manager can withdraw |
| `test_Withdraw_RevertNoPosition` | Revert if no position is open (tokenId = 0) |
| `test_Withdraw_RevertZeroAmount` | Revert if amount is 0 |
| `test_Harvest_CollectsFees` | Harvest collects WETH + USDC fees and reinvests |
| `test_Harvest_RevertIfNotManager` | Only the manager can harvest |
| `test_TotalAssets_ZeroWithoutDeposits` | totalAssets is 0 without deposits |
| `test_Ticks_AreValid` | Position ticks are valid (±960) |
| `test_Apy_ReturnsValidValue` | APY returns 1400 bp (14%) |
| `test_Name` | Returns correct name |
| `test_Asset` | Returns the WETH address |

**Coverage**: 75.21% lines, 75.51% statements, 50.00% branches, 100.00% functions

### Router.t.sol — `test/unit/Router.t.sol`

15 tests covering the peripheral Router: zap deposits (ETH/ERC20), zap withdrawals (ETH/ERC20), slippage, stateless.

| Test | Description |
| --- | --- |
| `test_ZapDepositETH_Success` | Depositing ETH generates shares correctly |
| `test_ZapDepositETH_RevertsIfZeroAmount` | Revert if msg.value is 0 |
| `test_ZapDepositETH_StatelessEnforcement` | Router WETH balance = 0 after deposit |
| `test_ZapDepositETH_EmitsEvent` | Emits ZapDeposit correctly |
| `test_ZapDepositERC20_Success_USDC` | Depositing USDC → swap → shares works |
| `test_ZapDepositERC20_RevertsIfZeroAddress` | Revert if token_in is address(0) |
| `test_ZapDepositERC20_RevertsIfTokenIsWETH` | Revert if token_in is WETH (use vault directly) |
| `test_ZapDepositERC20_RevertsIfZeroAmount` | Revert if amount_in is 0 |
| `test_ZapDepositERC20_SlippageProtection` | Reverts if min_weth_out is too high |
| `test_ZapWithdrawETH_Success` | Withdrawing shares → receiving ETH works |
| `test_ZapWithdrawETH_RevertsIfZeroShares` | Revert if shares is 0 |
| `test_ZapWithdrawETH_StatelessEnforcement` | Router balance = 0 after withdrawal |
| `test_ZapWithdrawERC20_Success_USDC` | Withdrawing shares → receiving USDC works |
| `test_ZapWithdrawERC20_RevertsIfTokenIsWETH` | Revert if token_out is WETH |
| `test_ZapWithdrawERC20_OnlyChecksTokenOutBalance` | Only checks token_out balance (not WETH) |

**Coverage**: 98.36% lines, 80.95% statements, 28.57% branches, 100.00% functions

---

## 2. Integration Tests

### FullFlow.t.sol — `test/integration/FullFlow.t.sol`

10 end-to-end tests validating complete flows crossing vault → manager → strategies → real protocols + Router flows.

| Test | Description |
| --- | --- |
| `test_E2E_DepositAllocateWithdraw` | Full happy path: deposit → allocation to strategies → withdraw |
| `test_E2E_MultipleUsersConcurrent` | Multiple users (Alice + Bob) depositing and withdrawing concurrently |
| `test_E2E_DepositRebalanceWithdraw` | Deposit → APY change → rebalance → withdraw with no fund loss |
| `test_E2E_PauseUnpauseRecovery` | Deposit → pause (blocks operations) → unpause → withdraw works |
| `test_E2E_RemoveStrategyAndWithdraw` | Deposit → remove strategy → withdraw with no funds locked |
| `test_E2E_YieldAccrual` | Deposit → advance 30 days → verify totalAssets grew from real yield |
| `test_E2E_Router_DepositUSDC_WithdrawUSDC` | Deposit USDC via Router → withdraw in USDC |
| `test_E2E_Router_DepositETH_WithdrawETH` | Deposit ETH via Router → withdraw in ETH |
| `test_E2E_Router_DepositDAI_WithdrawUSDC` | Deposit DAI → withdraw USDC (different tokens) |
| `test_E2E_Router_DepositWBTC_UsesPool3000` | WBTC uses 0.3% pool (not 0.05%) |

---

## 3. Fuzz Tests

### Fuzz.t.sol — `test/fuzz/Fuzz.t.sol`

6 stateless tests with random inputs. Each test receives random values bounded to valid ranges and verifies properties that must hold for any input.

| Test | Runs | Description |
| --- | --- | --- |
| `testFuzz_Deposit_GeneratesShares` | 256 | For any valid amount, deposit generates shares > 0 and totalAssets grows |
| `testFuzz_Withdraw_NeverExceedsDeposit` | 257 | For any partial withdraw, the user does not extract more than deposited |
| `testFuzz_Redeem_BurnsExactShares` | 257 | Redeem burns exactly the indicated shares, no more no less |
| `testFuzz_DepositRedeem_NeverProfitable` | 257 | Deposit → immediate redeem never generates profit |
| `testFuzz_Router_ZapDepositETH` | 256 | zapDepositETH with any valid amount (0.01-1000 ETH) generates shares |
| `testFuzz_Router_ZapDepositERC20` | 256 | zapDepositERC20 with any valid amount and pool_fee generates shares |

Setup: 256 runs per test (configurable in `foundry.toml`).

---

## 4. Invariant Tests

### Invariants.t.sol — `test/invariant/Invariants.t.sol`

4 stateful invariants. Unlike fuzz tests, Foundry executes **random sequences** of operations (deposit, withdraw, harvest, routerZapDeposit, routerZapWithdraw...) and after each sequence verifies that global properties are maintained.

| Invariant | Property |
| --- | --- |
| `invariant_VaultIsSolvent` | totalAssets >= 99% × totalSupply (vault can cover all shares, 1% tolerance for fees) |
| `invariant_AccountingIsConsistent` | idle_weth + manager.totalAssets() == vault.totalAssets() (accounting balances) |
| `invariant_SupplyIsCoherent` | Sum of individual balances <= totalSupply (no shares created out of thin air) |
| `invariant_RouterAlwaysStateless` | Router never retains WETH or ETH between transactions (balance always 0) |

### Handler.sol — `test/invariant/Handler.sol`

Intermediary contract that bounds calls to the vault and router so the fuzzer doesn't waste time on useless reverts. Exposes actions:

**Direct vault:**
- **`deposit(actor_seed, amount)`**: Picks a random actor, bounds amount to available vault space and deposits
- **`withdraw(actor_seed, amount)`**: Picks an actor with shares, bounds amount to their maximum withdrawable and withdraws
- **`harvest()`**: Advances 1-7 days and executes harvest if there is minimum profit

**Router:**
- **`routerZapDepositETH(actor_seed, amount)`**: Deposits ETH via Router
- **`routerZapDepositUSDC(actor_seed, amount)`**: Deposits USDC via Router (swap + deposit)
- **`routerZapWithdrawETH(actor_seed, shares)`**: Withdraws shares via Router → receives ETH

Includes ghost variables (`ghost_totalDeposited`, `ghost_totalWithdrawn`) for tracking.

### Execution of Invariant Tests

The invariant tests generate a significantly larger volume of RPC calls than normal tests (32 runs × 15 depth = 480 operation sequences). This quickly exhausts the rate limit of Alchemy's free tier and other providers (HTTP 429).

To solve this, a script is used that launches **Anvil as a local proxy** with controlled rate limiting:

```bash
./script/run_invariants_offline.sh
```

**How the script works:**

1. **Anvil with rate limiting**: Launches Anvil with `--compute-units-per-second 10` to control the speed of RPC calls to the remote node
2. **Cache warmup**: Runs a simple integration test so Foundry caches Lido, Aave, Curve and Uniswap V3 contracts in `~/.foundry/cache`
3. **Controlled fuzzing**: Runs the invariant tests against local Anvil (which serves from cache) instead of directly against Alchemy
4. **Automatic cleanup**: Kills Anvil processes and removes temporary files

**Script options:**

```bash
# Default: 32 runs × 15 depth = 480 calls
./script/run_invariants_offline.sh

# More runs (more exhaustive)
./script/run_invariants_offline.sh -r 64

# Custom block
./script/run_invariants_offline.sh -b 21800000

# If still failing due to rate limit, reduce runs
./script/run_invariants_offline.sh -r 16
```

### Execution Results

The 4 invariant tests ran successfully, validating the critical properties of the system:

```
Ran 4 tests for test/invariant/Invariants.t.sol:InvariantsTest
[PASS] invariant_AccountingIsConsistent() (runs: 32, calls: 480, reverts: 75)
[PASS] invariant_RouterAlwaysStateless()  (runs: 32, calls: 480, reverts: 55)
[PASS] invariant_SupplyIsCoherent()       (runs: 32, calls: 480, reverts: 62)
[PASS] invariant_VaultIsSolvent()         (runs: 32, calls: 480, reverts: 55)

Suite result: ok. 4 passed; 0 failed; 0 skipped; finished in 177.15s (645.46s CPU time)
```

**Execution statistics (32 runs)**:

| Handler Action | Calls (average) | Reverts (average) | Notes |
| --- | --- | --- | --- |
| `deposit` | ~76 | 0 | Never reverts (amount bounded) |
| `harvest` | ~84 | 0 | Never reverts (time skip guaranteed) |
| `routerZapDepositETH` | ~82 | ~6 | Reverts due to max_tvl |
| `routerZapDepositUSDC` | ~81 | ~6 | Reverts due to slippage/max_tvl |
| `routerZapWithdrawETH` | ~83 | ~23 | Reverts due to insufficient shares |
| `withdraw` | ~74 | ~27 | Reverts due to insufficient shares |

- Total sequences executed: 1,920 (4 invariants × 32 runs × 15 depth)
- Execution time: ~177s with Anvil as proxy

**Important**: The invariant tests require an **RPC cooldown period** between runs. If run immediately after other tests that consume many calls, they may fail with HTTP 429 due to accumulated rate limiting from Alchemy's free tier. This is **normal** and does not indicate a code problem — just wait 5-10 minutes or use an RPC with a higher rate limit.

---

## Overall Coverage

```
╭──────────────────────────────+──────────────────+──────────────────+─────────────────+──────────────────╮
│ Contract                      │ Lines            │ Statements       │ Branches        │ Functions        │
╞══════════════════════════════╪══════════════════╪══════════════════╪═════════════════╪══════════════════╡
│ Vault.sol                     │ 92.51% (173/187) │ 88.02% (169/192) │ 55.26% (21/38)  │ 100.00% (41/41)  │
│ StrategyManager.sol           │ 81.46% (167/205) │ 81.27% (217/267) │ 52.08% (25/48)  │ 100.00% (20/20)  │
│ AaveStrategy.sol              │ 71.95% (59/82)   │ 69.89% (65/93)   │ 41.67% (5/12)   │ 91.67% (11/12)   │
│ CurveStrategy.sol             │ 95.12% (78/82)   │ 97.09% (100/103) │ 71.43% (5/7)    │ 100.00% (10/10)  │
│ LidoStrategy.sol              │ 90.91% (40/44)   │ 91.30% (42/46)   │ 66.67% (4/6)    │ 90.00% (9/10)    │
│ UniswapV3Strategy.sol         │ 75.21% (91/121)  │ 75.51% (111/147) │ 50.00% (15/30)  │ 100.00% (10/10)  │
│ Router.sol                    │ 98.36% (60/61)   │ 80.95% (68/84)   │ 28.57% (6/21)   │ 100.00% (10/10)  │
╞══════════════════════════════╪══════════════════╪══════════════════╪═════════════════╪══════════════════╡
│ **Total**                     │ **85.42% (668/782)** │ **82.83% (772/932)** │ **50.00% (81/162)** │ **98.23% (111/113)** │
╰──────────────────────────────+──────────────────+──────────────────+─────────────────+──────────────────╯
```

**Note**: The reported coverage only includes unit, integration and fuzz tests. Invariant tests run via Anvil and are not reflected in `forge coverage`. `--ir-minimum` is required due to stack-too-deep in UniswapV3Strategy.

---

## Conventions

- **Naming**: `test_Feature_Behavior` for unit/integration, `testFuzz_` for fuzz, `invariant_` for invariants
- **Helpers**: `_deposit()` and `_withdraw()` in each file to reduce duplication in happy paths
- **Separators**: Solmate style (`//*`) to organize sections within each contract
- **Tolerances**: `assertApproxEqRel` with 0.1% (0.001e18) to compensate for real fees/slippage from Lido/Aave/Curve/Uniswap V3
- **Pool seeding**: Tests seed Uniswap V3 pools (wstETH/WETH) with concentrated liquidity to prevent excessive slippage in fork
- **No mocks**: 100% of interactions are against real Mainnet contracts via fork
