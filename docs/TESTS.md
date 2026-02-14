# Testing

This document describes the Multi-Strategy Vault test suite, including structure, files, coverage and execution particularities.

---

## Overview

All tests run against a **real Ethereum Mainnet fork** via Alchemy. No mocks are used: the interactions with Aave v3 and Compound v3 are real against the blockchain state. This guarantees that the tested behavior is identical to production.

```
test/
├── unit/                    # Unit tests per contract
│   ├── StrategyVault.t.sol
│   ├── StrategyManager.t.sol
│   ├── AaveStrategy.t.sol
│   └── CompoundStrategy.t.sol
├── integration/             # End-to-end integration tests
│   └── FullFlow.t.sol
├── fuzz/                    # Stateless fuzz tests
│   └── Fuzz.t.sol
└── invariant/               # Stateful invariant tests
    ├── Invariants.t.sol
    └── Handler.sol
```

**Total: 75 tests** (61 unit + 6 integration + 5 fuzz + 3 invariant)

### Execution

```bash
# Set up RPC
export MAINNET_RPC_URL="https://eth-mainnet.g.alchemy.com/v2/<API_KEY>"

# Run unit + integration + fuzz
forge test -vv

# Run invariant tests (requires Anvil with rate limiting)
./script/run_invariants_offline.sh
```

---

## 1. Unit Tests

Isolated tests per contract. They validate each public function with happy paths and revert paths.

### StrategyVault.t.sol — `test/unit/StrategyVault.t.sol`

22 tests covering the ERC4626 vault: deposits, withdrawals, minting, redeeming, fees, idle buffer and admin.

| Test                                     | Description                                              |
| ---------------------------------------- | -------------------------------------------------------- |
| `test_Deposit_Basic`                     | Depositing generates shares and updates idle buffer      |
| `test_Deposit_TriggersAllocation`        | Deposit exceeding threshold sends funds to strategies    |
| `test_Deposit_RevertZero`                | Revert if amount is 0                                    |
| `test_Deposit_RevertBelowMin`            | Revert if amount < min_deposit                           |
| `test_Deposit_RevertExceedsMaxTVL`       | Revert if it exceeds max_tvl                             |
| `test_Deposit_RevertWhenPaused`          | Revert if vault is paused                                |
| `test_Mint_Basic`                        | Minting shares directly works correctly                  |
| `test_Mint_RevertZero`                   | Revert if shares is 0                                    |
| `test_Withdraw_FromIdle`                 | Withdrawal served from idle buffer                       |
| `test_Withdraw_FromStrategies`           | Withdrawal that requires withdrawing from strategies     |
| `test_Withdraw_FeeCalculation`           | 2% fee is charged correctly                              |
| `test_Withdraw_RevertZero`              | Revert if amount is 0                                    |
| `test_Withdraw_RevertWhenPaused`         | Revert if vault is paused                                |
| `test_Redeem_Basic`                      | Redeem burns shares and returns net assets                |
| `test_Redeem_RevertZero`                 | Revert if shares is 0                                    |
| `test_AllocateIdle_RevertBelowThreshold` | Revert if idle < threshold when forcing manual allocation|
| `test_TotalAssets_IdlePlusManager`       | totalAssets = idle_weth + manager.totalAssets()           |
| `test_MaxDeposit_RespectsMaxTVL`         | maxDeposit respects the maximum TVL                      |
| `test_MaxMint_RespectsMaxTVL`            | maxMint respects the maximum TVL                         |
| `test_Admin_OnlyOwnerCanSetParams`       | Only the owner can modify parameters                     |
| `test_Preview_WithdrawIncludesFee`       | previewWithdraw includes the fee in the calculation      |
| `test_Preview_RedeemDeductsFee`          | previewRedeem deducts the fee from the result            |

**Coverage**: 85.37% lines, 85.38% statements, 50.00% branches, 80.00% functions

### StrategyManager.t.sol — `test/unit/StrategyManager.t.sol`

18 tests covering allocation, withdrawals, rebalancing, strategy management and admin.

| Test                                              | Description                                          |
| ------------------------------------------------- | ---------------------------------------------------- |
| `test_InitializeVault_RevertIfAlreadyInitialized` | Cannot initialize the vault twice                    |
| `test_Allocate_Basic`                             | Funds are distributed to strategies                  |
| `test_Allocate_RevertIfNotVault`                  | Only the vault can call allocate                     |
| `test_Allocate_RevertZero`                        | Revert if amount is 0                                |
| `test_Allocate_RevertNoStrategies`                | Revert if no strategies are registered               |
| `test_WithdrawTo_Basic`                           | Proportional withdrawal from strategies works        |
| `test_WithdrawTo_RevertIfNotVault`                | Only the vault can call withdrawTo                   |
| `test_WithdrawTo_RevertZero`                      | Revert if amount is 0                                |
| `test_AddStrategy_Basic`                          | Adding a strategy increments the counter             |
| `test_AddStrategy_RevertDuplicate`                | Revert if the strategy already exists                |
| `test_RemoveStrategy_Basic`                       | Removing a strategy decrements the counter           |
| `test_RemoveStrategy_RevertNotFound`              | Revert if the strategy does not exist                |
| `test_Rebalance_ExecutesSuccessfully`             | Rebalance moves funds after changing max allocation  |
| `test_Rebalance_RevertIfNotProfitable`            | Revert if the rebalance is not profitable            |
| `test_TotalAssets_SumsAllStrategies`              | totalAssets correctly sums all strategies            |
| `test_StrategiesCount`                            | Returns the correct number of strategies             |
| `test_GetAllStrategiesInfo`                       | Returns correct info (names, APYs, TVLs, targets)    |
| `test_Admin_OnlyOwnerCanSetParams`                | Only the owner can modify manager parameters         |

**Coverage**: 95.43% lines, 93.04% statements, 76.47% branches, 100.00% functions

### AaveStrategy.t.sol — `test/unit/AaveStrategy.t.sol`

10 tests covering the direct integration with Aave v3.

| Test                                   | Description                                   |
| -------------------------------------- | --------------------------------------------- |
| `test_Deposit_Basic`                   | Deposit into Aave generates aTokens correctly |
| `test_Deposit_RevertIfNotManager`      | Only the manager can deposit                  |
| `test_Withdraw_Basic`                  | Partial withdrawal returns WETH to the manager|
| `test_Withdraw_Full`                   | Full withdrawal leaves balance at 0           |
| `test_Withdraw_RevertIfNotManager`     | Only the manager can withdraw                 |
| `test_Apy_ReturnsValidValue`           | APY is in a reasonable range (0-50%)          |
| `test_Name`                            | Returns "Aave v3 WETH Strategy"               |
| `test_Asset`                           | Returns the WETH address                      |
| `test_AvailableLiquidity`              | Available liquidity in Aave > 0               |
| `test_TotalAssets_ZeroWithoutDeposits` | totalAssets is 0 without deposits             |

**Coverage**: 88.89% lines, 93.10% statements, 60.00% branches, 100.00% functions

### CompoundStrategy.t.sol — `test/unit/CompoundStrategy.t.sol`

11 tests covering the direct integration with Compound v3.

| Test                                   | Description                                         |
| -------------------------------------- | --------------------------------------------------- |
| `test_Deposit_Basic`                   | Deposit into Compound registers balance correctly   |
| `test_Deposit_RevertIfNotManager`      | Only the manager can deposit                        |
| `test_Withdraw_Basic`                  | Partial withdrawal returns WETH to the manager      |
| `test_Withdraw_Full`                   | Full withdrawal leaves balance at 0                 |
| `test_Withdraw_RevertIfNotManager`     | Only the manager can withdraw                       |
| `test_Apy_ReturnsValidValue`           | APY is in a reasonable range (0-50%)                |
| `test_Name`                            | Returns "Compound v3 WETH Strategy"                 |
| `test_Asset`                           | Returns the WETH address                            |
| `test_GetSupplyRate`                   | Compound supply rate is > 0                         |
| `test_GetUtilization`                  | Compound utilization rate is > 0                    |
| `test_TotalAssets_ZeroWithoutDeposits` | totalAssets is 0 without deposits                   |

**Coverage**: 88.24% lines, 92.59% statements, 60.00% branches, 100.00% functions

---

## 2. Integration Tests

### FullFlow.t.sol — `test/integration/FullFlow.t.sol`

6 end-to-end tests that validate complete flows crossing vault -> manager -> strategies -> real protocols.

| Test                                 | Description                                                                                 |
| ------------------------------------ | ------------------------------------------------------------------------------------------- |
| `test_E2E_DepositAllocateWithdraw`   | Full happy path: deposit -> allocation to strategies -> withdraw with fees                  |
| `test_E2E_MultipleUsersConcurrent`   | Multiple users (Alice + Bob) depositing and withdrawing concurrently                        |
| `test_E2E_DepositRebalanceWithdraw`  | Deposit -> change max allocation -> rebalance -> withdraw without loss of funds             |
| `test_E2E_PauseUnpauseRecovery`      | Deposit -> pause (blocks operations) -> unpause -> withdraw works correctly                 |
| `test_E2E_RemoveStrategyAndWithdraw` | Deposit -> remove Compound strategy -> withdraw from Aave without locked funds              |
| `test_E2E_YieldAccrual`              | Deposit -> advance 30 days -> verify that totalAssets grew from real Aave/Compound yield    |

---

## 3. Fuzz Tests

### Fuzz.t.sol — `test/fuzz/Fuzz.t.sol`

5 stateless tests with random inputs. Each test receives random values bounded to valid ranges (min_deposit to max_tvl) and verifies properties that must hold for any input.

| Test                                     | Description                                                                 |
| ---------------------------------------- | --------------------------------------------------------------------------- |
| `testFuzz_Deposit_GeneratesShares`       | For any valid amount, deposit generates shares > 0 and totalAssets grows    |
| `testFuzz_Withdraw_NeverExceedsDeposit`  | For any partial withdraw, the user does not extract more than deposited     |
| `testFuzz_Withdraw_FeeAlwaysCollected`   | For any valid withdrawal, the fee receiver always collects                  |
| `testFuzz_Redeem_BurnsExactShares`       | Redeem burns exactly the indicated shares, no more no less                  |
| `testFuzz_DepositRedeem_NeverProfitable` | Deposit -> immediate redeem never generates profit (2% fee prevents it)    |

Configuration: 256 runs per test (configurable in `foundry.toml`).

---

## 4. Invariant Tests

### Invariants.t.sol — `test/invariant/Invariants.t.sol`

3 stateful invariants. Unlike fuzz tests, Foundry executes **random sequences** of operations (deposit, withdraw, deposit, withdraw...) and after each sequence verifies that the global properties hold.

| Invariant                          | Property                                                                       |
| ---------------------------------- | ------------------------------------------------------------------------------ |
| `invariant_VaultIsSolvent`         | totalAssets >= totalSupply (the vault can cover all shares)                    |
| `invariant_AccountingIsConsistent` | idle_weth + manager.totalAssets() == vault.totalAssets() (accounting adds up)  |
| `invariant_SupplyIsCoherent`       | Sum of individual balances <= totalSupply (shares are not created out of thin air) |

### Handler.sol — `test/invariant/Handler.sol`

Intermediary contract that bounds the calls to the vault so the fuzzer does not waste time on useless reverts. It exposes two actions:

- **`deposit(actor_seed, amount)`**: Picks a random actor, bounds amount to the available space in the vault and deposits
- **`withdraw(actor_seed, amount)`**: Picks an actor with shares, bounds amount to their maximum withdrawable and withdraws

Includes ghost variables (`ghost_totalDeposited`, `ghost_totalWithdrawn`) for tracking.

### Invariant Tests Execution

The invariant tests generate a significantly higher volume of RPC calls than normal tests (32 runs x 15 depth = 480 operation sequences). This quickly exhausts the rate limit of Alchemy's free tier and other providers (HTTP 429).

To solve this, a script is used that launches **Anvil as a local proxy** with controlled rate limiting:

```bash
./script/run_invariants_offline.sh
```

**How the script works:**

1. **Anvil with rate limiting**: Launches Anvil with `--compute-units-per-second 10` to control the speed of RPC calls to the remote node
2. **Cache warmup**: Runs a simple integration test so that Foundry caches the Aave and Compound contracts in `~/.foundry/cache`
3. **Controlled fuzzing**: Runs the invariant tests against local Anvil (which serves from cache) instead of directly against Alchemy
4. **Automatic cleanup**: Kills Anvil processes and removes temporary files

**Script options:**

```bash
# Default: 32 runs x 15 depth = 480 calls
./script/run_invariants_offline.sh

# More runs (more exhaustive)
./script/run_invariants_offline.sh -r 64

# Custom block
./script/run_invariants_offline.sh -b 21800000

# If it still fails due to rate limit, reduce runs
./script/run_invariants_offline.sh -r 16
```

### Execution Result

All 3 invariant tests ran successfully during the protocol's development, validating the system's critical properties:

```
Ran 3 tests for test/invariant/Invariants.t.sol:InvariantsTest
[PASS] invariant_AccountingIsConsistent() (runs: 32, calls: 480, reverts: 0)
[PASS] invariant_SupplyIsCoherent() (runs: 32, calls: 480, reverts: 0)
[PASS] invariant_VaultIsSolvent() (runs: 32, calls: 480, reverts: 1)

Suite result: ok. 3 passed; 0 failed; 0 skipped
```

**Execution statistics (32 runs)**:
- Total sequences executed: 480 (32 runs x 15 depth)
- Operations performed: ~950 calls to the vault (deposit + withdraw)
- Expected reverts: 1 (edge case where withdraw exceeds available liquidity)
- Execution time: ~100s with Anvil as proxy

**Important**: The invariant tests require an **RPC cooldown period** between executions. If they are run immediately after other tests that consume many calls (like the deployment dry-run), they may fail with HTTP 429 due to cumulative rate limiting from Alchemy's free tier. This is **normal** and does not indicate a problem in the code — simply wait 5-10 minutes or use an RPC with a higher rate limit (Alchemy Growth Plan or local node).

---

## Global Coverage

```
╭─────────────────────────────────+──────────+──────────────+────────────+─────────╮
│ Contract                        │ Lines    │ Statements   │ Branches   │ Funcs   │
╞═════════════════════════════════╪══════════╪══════════════╪════════════╪═════════╡
│ StrategyVault.sol               │ 85.37%   │ 85.38%       │ 50.00%    │ 80.00%  │
│ StrategyManager.sol             │ 95.43%   │ 93.04%       │ 76.47%    │ 100.00% │
│ AaveStrategy.sol                │ 88.89%   │ 93.10%       │ 60.00%    │ 100.00% │
│ CompoundStrategy.sol            │ 88.24%   │ 92.59%       │ 60.00%    │ 100.00% │
╞═════════════════════════════════╪══════════╪══════════════╪════════════╪═════════╡
│ Total                           │ 84.34%   │ 83.59%       │ 61.76%    │ 88.06%  │
╰─────────────────────────────────+──────────+──────────────+────────────+─────────╯
```

**Note**: The reported coverage only includes unit, integration and fuzz tests. The invariant tests are run via Anvil and are not reflected in `forge coverage`.

---

## Conventions

- **Naming**: `test_Feature_Behavior` for unit/integration, `testFuzz_` for fuzz, `invariant_` for invariants
- **Helpers**: `_deposit()` and `_withdraw()` in each file to reduce duplication in happy paths
- **Separators**: Solmate style (`//*`) to organize sections within each contract
- **Tolerances**: `assertApproxEqRel` with 0.1% (0.001e18) to compensate for real Aave/Compound fees
- **No mocks**: 100% of interactions are against real Mainnet contracts via fork
