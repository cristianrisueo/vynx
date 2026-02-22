# Testing

Este documento describe la suite de tests de VynX V2 (Vault + Router + 4 Estrategias), incluyendo estructura, ficheros, coverage y particularidades de ejecución.

---

## Visión General

Todos los tests se ejecutan contra un **fork de Ethereum Mainnet** real mediante Alchemy. No se utilizan mocks: las interacciones con Lido, Aave v3, Curve y Uniswap V3 son reales contra el estado del blockchain. Esto garantiza que el comportamiento testeado es idéntico al de producción.

```
test/
├── unit/                    # Tests unitarios por contrato
│   ├── Vault.t.sol
│   ├── StrategyManager.t.sol
│   ├── LidoStrategy.t.sol
│   ├── AaveStrategy.t.sol
│   ├── CurveStrategy.t.sol
│   ├── UniswapV3Strategy.t.sol
│   └── Router.t.sol
├── integration/             # Tests de integración end-to-end
│   └── FullFlow.t.sol
├── fuzz/                    # Fuzz tests stateless
│   └── Fuzz.t.sol
└── invariant/               # Invariant tests stateful
    ├── Invariants.t.sol
    └── Handler.sol
```

**Total: 160 tests** (145 unitarios + 10 integración + 6 fuzz + 4 invariantes × 32 runs)

> Los 149 tests sin invariantes pasan consistentemente. Los 11 fallos que pueden aparecer en `forge coverage` son siempre HTTP 429 (rate limiting del RPC), no errores de código.

### Ejecución

```bash
# Configurar RPC
export MAINNET_RPC_URL="https://eth-mainnet.g.alchemy.com/v2/<API_KEY>"

# Ejecutar unit + integration + fuzz (149 tests, excluyendo invariantes)
forge test --no-match-path "test/invariant/*" -vv

# Ejecutar invariant tests (requiere Anvil con rate limiting)
./script/run_invariants_offline.sh

# Coverage (requiere --ir-minimum por stack-too-deep)
forge coverage --no-match-path "test/invariant/*" --ir-minimum
```

---

## 1. Tests Unitarios

Tests aislados por contrato. Validan cada función pública con happy paths y revert paths.

### Vault.t.sol — `test/unit/Vault.t.sol`

50 tests que cubren el vault ERC4626: deposits, withdrawals, minting, redeeming, fees, idle buffer, keeper incentives, emergency exit y admin.

| Test | Descripción |
| --- | --- |
| `test_Deposit_Basic` | Depositar genera shares y actualiza idle buffer |
| `test_Deposit_TriggersAllocation` | Depósito que supera threshold envía fondos a estrategias |
| `test_Deposit_RevertZero` | Revert si amount es 0 |
| `test_Deposit_RevertBelowMin` | Revert si amount < min_deposit |
| `test_Deposit_RevertExceedsMaxTVL` | Revert si excede max_tvl |
| `test_Deposit_RevertWhenPaused` | Revert si vault está pausado |
| `test_Mint_Basic` | Mint shares directamente funciona correctamente |
| `test_Mint_RevertZero` | Revert si shares es 0 |
| `test_Mint_RevertExceedsMaxTVL` | Revert si mint excedería max_tvl |
| `test_Mint_RevertWhenPaused` | Revert si vault está pausado |
| `test_Mint_TriggersAllocation` | Mint que supera threshold envía fondos a estrategias |
| `test_Withdraw_FromIdle` | Retiro servido desde idle buffer |
| `test_Withdraw_FromStrategies` | Retiro que requiere retirar de estrategias |
| `test_Withdraw_FullAmount` | Retiro total funciona correctamente |
| `test_Withdraw_WithAllowance` | Retiro con allowance de tercero |
| `test_Withdraw_WorksWhenPaused` | Withdraw funciona incluso con vault pausado |
| `test_Withdraw_FromStrategiesWhenPaused` | Withdraw de estrategias funciona con vault pausado |
| `test_Redeem_Basic` | Redeem quema shares y devuelve assets |
| `test_Redeem_WorksWhenPaused` | Redeem funciona incluso con vault pausado |
| `test_AllocateIdle_RevertBelowThreshold` | Revert si idle < threshold al forzar allocation manual |
| `test_AllocateIdle_RevertWhenPaused` | Revert si vault está pausado |
| `test_TotalAssets_IdlePlusManager` | totalAssets = idle_weth + manager.totalAssets() |
| `test_MaxDeposit_RespectsMaxTVL` | maxDeposit respeta el TVL máximo |
| `test_MaxDeposit_AfterPartialDeposit` | maxDeposit se actualiza tras depósito parcial |
| `test_MaxDeposit_ReturnsZeroAtCapacity` | maxDeposit devuelve 0 al alcanzar max_tvl |
| `test_MaxDeposit_ReturnsZeroWhenPaused` | maxDeposit devuelve 0 si vault pausado |
| `test_MaxMint_RespectsMaxTVL` | maxMint respeta el TVL máximo |
| `test_FeeDistribution` | Distribución de fees: 80% treasury (shares), 20% founder (WETH) |
| `test_HarvestWithExternalKeeper` | Keeper externo recibe 1% de profit como incentivo |
| `test_HarvestWithOfficialKeeper` | Keeper oficial no recibe incentivo |
| `test_Harvest_ZeroProfit` | Harvest con profit 0 no distribuye fees |
| `test_Harvest_RevertWhenPaused` | Revert si vault está pausado |
| `test_Admin_OnlyOwnerCanSetParams` | Solo el owner puede modificar parámetros |
| `test_Getters_ReturnCorrectValues` | Getters devuelven valores configurados |
| `test_SetPerformanceFee_RevertExceedsBasisPoints` | Revert si fee > 10000 bp |
| `test_SetFeeSplit_RevertInvalidSum` | Revert si splits no suman 10000 bp |
| `test_SetKeeperIncentive_RevertExceedsBasisPoints` | Revert si incentivo > 10000 bp |
| `test_SetStrategyManager_RevertZeroAddress` | Revert si address(0) |
| `test_SetStrategyManager_Valid` | Actualización de strategy manager funciona |
| `test_SetTreasury_RevertZeroAddress` | Revert si address(0) |
| `test_SetFounder_RevertZeroAddress` | Revert si address(0) |
| `test_SetTreasuryAndFounder_Valid` | Actualización de treasury y founder funciona |
| `test_Constructor_RevertInvalidStrategyManager` | Revert si strategy manager es address(0) |
| `test_Constructor_RevertInvalidTreasury` | Revert si treasury es address(0) |
| `test_Constructor_RevertInvalidFounder` | Revert si founder es address(0) |
| `test_SyncIdleBuffer_UpdatesAfterExternalTransfer` | syncIdleBuffer reconcilia idle_buffer con balance real de WETH |
| `test_SyncIdleBuffer_EmitsEvent` | Emite IdleBufferSynced con valores correctos |
| `test_SyncIdleBuffer_Idempotent` | Llamar syncIdleBuffer dos veces es idempotente |
| `test_SyncIdleBuffer_RevertIfNotOwner` | Solo el owner puede llamar syncIdleBuffer |
| `test_EmergencyFlow_EndToEnd` | Flujo completo: deposit → pause → emergencyExit → syncIdleBuffer → withdraw |

**Coverage**: 92.51% lines, 88.02% statements, 55.26% branches, 100.00% functions

### StrategyManager.t.sol — `test/unit/StrategyManager.t.sol`

24 tests que cubren allocation, withdrawals, rebalancing, gestión de estrategias, emergency exit y admin.

| Test | Descripción |
| --- | --- |
| `test_InitializeVault_RevertIfAlreadyInitialized` | No se puede inicializar el vault dos veces |
| `test_Allocate_Basic` | Fondos se distribuyen a las estrategias |
| `test_Allocate_RevertIfNotVault` | Solo el vault puede llamar allocate |
| `test_Allocate_RevertZero` | Revert si amount es 0 |
| `test_Allocate_RevertNoStrategies` | Revert si no hay estrategias registradas |
| `test_WithdrawTo_Basic` | Retiro proporcional de estrategias funciona |
| `test_WithdrawTo_RevertIfNotVault` | Solo el vault puede llamar withdrawTo |
| `test_WithdrawTo_RevertZero` | Revert si amount es 0 |
| `test_AddStrategy_Basic` | Añadir estrategia incrementa el contador |
| `test_AddStrategy_RevertDuplicate` | Revert si la estrategia ya existe |
| `test_RemoveStrategy_Basic` | Remover estrategia decrementa el contador |
| `test_RemoveStrategy_RevertNotFound` | Revert si la estrategia no existe |
| `test_Rebalance_ExecutesSuccessfully` | Rebalance mueve fondos tras cambio de APY |
| `test_Rebalance_RevertIfNotProfitable` | Revert si el rebalance no es rentable |
| `test_TotalAssets_SumsAllStrategies` | totalAssets suma correctamente todas las estrategias |
| `test_StrategiesCount` | Devuelve el número correcto de estrategias |
| `test_GetAllStrategiesInfo` | Devuelve info correcta (names, APYs, TVLs, targets) |
| `test_Admin_OnlyOwnerCanSetParams` | Solo el owner puede modificar parámetros del manager |
| `test_EmergencyExit_DrainsAllStrategies` | emergencyExit drena todas las estrategias y transfiere WETH al vault |
| `test_EmergencyExit_EmitsCorrectEvent` | Emite EmergencyExit con total_rescued y strategies_drained correctos |
| `test_EmergencyExit_ManagerBalanceZero` | Balance de WETH del manager es ~0 tras emergencyExit |
| `test_EmergencyExit_NoStrategies` | emergencyExit con 0 estrategias no revierte (no-op) |
| `test_EmergencyExit_RevertIfNotOwner` | Solo el owner puede llamar emergencyExit |
| `test_EmergencyExit_ZeroBalanceStrategies` | emergencyExit con estrategias sin balance es un no-op |

**Coverage**: 81.46% lines, 81.27% statements, 52.08% branches, 100.00% functions

### LidoStrategy.t.sol — `test/unit/LidoStrategy.t.sol`

14 tests que cubren la integración con Lido (staking ETH → wstETH).

| Test | Descripción |
| --- | --- |
| `test_Deposit_Basic` | Depósito convierte WETH → ETH → wstETH correctamente |
| `test_Deposit_RevertIfNotManager` | Solo el manager puede depositar |
| `test_Deposit_RevertZeroAmount` | Revert si amount es 0 |
| `test_Withdraw_Basic` | Retiro parcial: wstETH → Uniswap V3 swap → WETH |
| `test_Withdraw_Full` | Retiro total deja balance en 0 |
| `test_Withdraw_RevertIfNotManager` | Solo el manager puede retirar |
| `test_Withdraw_RevertZeroAmount` | Revert si amount es 0 |
| `test_Harvest_AlwaysReturnsZero` | Harvest siempre retorna 0 (yield via exchange rate) |
| `test_Harvest_RevertIfNotManager` | Solo el manager puede hacer harvest |
| `test_TotalAssets_ZeroWithoutDeposits` | totalAssets es 0 sin depósitos |
| `test_TotalAssets_GrowsWithTime` | totalAssets crece con el tiempo (exchange rate) |
| `test_Apy_ReturnsValidValue` | APY devuelve 400 bp (4%) |
| `test_Name` | Devuelve nombre correcto |
| `test_Asset` | Devuelve la dirección de WETH |

**Coverage**: 90.91% lines, 91.30% statements, 66.67% branches, 90.00% functions

### AaveStrategy.t.sol — `test/unit/AaveStrategy.t.sol`

10 tests que cubren la integración con Aave v3 (supply wstETH → aWstETH).

| Test | Descripción |
| --- | --- |
| `test_Deposit_Basic` | Depósito: WETH → ETH → wstETH → Aave supply → aWstETH |
| `test_Deposit_RevertIfNotManager` | Solo el manager puede depositar |
| `test_Withdraw_Basic` | Retiro parcial: aWstETH → wstETH → swap → WETH |
| `test_Withdraw_Full` | Retiro total deja balance en 0 |
| `test_Withdraw_RevertIfNotManager` | Solo el manager puede retirar |
| `test_Apy_ReturnsValidValue` | APY dinámico desde Aave liquidity rate |
| `test_Name` | Devuelve nombre correcto |
| `test_Asset` | Devuelve la dirección de WETH |
| `test_AvailableLiquidity` | Liquidez disponible en Aave > 0 |
| `test_TotalAssets_ZeroWithoutDeposits` | totalAssets es 0 sin depósitos |

**Coverage**: 71.95% lines, 69.89% statements, 41.67% branches, 91.67% functions

### CurveStrategy.t.sol — `test/unit/CurveStrategy.t.sol`

15 tests que cubren la integración con Curve (LP stETH/ETH + gauge staking).

| Test | Descripción |
| --- | --- |
| `test_Deposit_Basic` | Depósito: WETH → ETH → stETH → add_liquidity → gauge stake |
| `test_Deposit_RevertIfNotManager` | Solo el manager puede depositar |
| `test_Deposit_RevertZeroAmount` | Revert si amount es 0 |
| `test_Withdraw_Basic` | Retiro parcial: gauge unstake → remove_liquidity → ETH → WETH |
| `test_Withdraw_Full` | Retiro total deja balance en 0 |
| `test_Withdraw_RevertIfNotManager` | Solo el manager puede retirar |
| `test_Withdraw_RevertZeroAmount` | Revert si amount es 0 |
| `test_Harvest_WithRewards` | Harvest: CRV → Uniswap swap → reinvierte como LP |
| `test_Harvest_RevertIfNotManager` | Solo el manager puede hacer harvest |
| `test_TotalAssets_ZeroWithoutDeposits` | totalAssets es 0 sin depósitos |
| `test_TotalAssets_GrowsWithTime` | totalAssets crece con virtual_price |
| `test_LpBalance_ZeroWithoutDeposits` | LP balance es 0 sin depósitos |
| `test_Apy_ReturnsValidValue` | APY devuelve 600 bp (6%) |
| `test_Name` | Devuelve nombre correcto |
| `test_Asset` | Devuelve la dirección de WETH |

**Coverage**: 95.12% lines, 97.09% statements, 71.43% branches, 100.00% functions

### UniswapV3Strategy.t.sol — `test/unit/UniswapV3Strategy.t.sol`

16 tests que cubren la integración con Uniswap V3 (liquidez concentrada WETH/USDC).

| Test | Descripción |
| --- | --- |
| `test_Deposit_Basic` | Depósito: WETH → 50% swap USDC → mint NFT position |
| `test_Deposit_IncreasesExistingPosition` | Segundo depósito incrementa posición existente |
| `test_Deposit_RevertIfNotManager` | Solo el manager puede depositar |
| `test_Deposit_RevertZeroAmount` | Revert si amount es 0 |
| `test_Withdraw_Basic` | Retiro parcial: decrease liquidity → collect → swap → WETH |
| `test_Withdraw_Full_BurnsNFT` | Retiro total quema el NFT de la posición |
| `test_Withdraw_RevertIfNotManager` | Solo el manager puede retirar |
| `test_Withdraw_RevertNoPosition` | Revert si no hay posición abierta (tokenId = 0) |
| `test_Withdraw_RevertZeroAmount` | Revert si amount es 0 |
| `test_Harvest_CollectsFees` | Harvest recolecta fees WETH + USDC y reinvierte |
| `test_Harvest_RevertIfNotManager` | Solo el manager puede hacer harvest |
| `test_TotalAssets_ZeroWithoutDeposits` | totalAssets es 0 sin depósitos |
| `test_Ticks_AreValid` | Ticks de la posición son válidos (±960) |
| `test_Apy_ReturnsValidValue` | APY devuelve 1400 bp (14%) |
| `test_Name` | Devuelve nombre correcto |
| `test_Asset` | Devuelve la dirección de WETH |

**Coverage**: 75.21% lines, 75.51% statements, 50.00% branches, 100.00% functions

### Router.t.sol — `test/unit/Router.t.sol`

15 tests que cubren el Router periférico: zap deposits (ETH/ERC20), zap withdrawals (ETH/ERC20), slippage, stateless.

| Test | Descripción |
| --- | --- |
| `test_ZapDepositETH_Success` | Depositar ETH genera shares correctamente |
| `test_ZapDepositETH_RevertsIfZeroAmount` | Revert si msg.value es 0 |
| `test_ZapDepositETH_StatelessEnforcement` | Router balance WETH = 0 tras depósito |
| `test_ZapDepositETH_EmitsEvent` | Emite ZapDeposit correctamente |
| `test_ZapDepositERC20_Success_USDC` | Depositar USDC → swap → shares funciona |
| `test_ZapDepositERC20_RevertsIfZeroAddress` | Revert si token_in es address(0) |
| `test_ZapDepositERC20_RevertsIfTokenIsWETH` | Revert si token_in es WETH (usar vault directo) |
| `test_ZapDepositERC20_RevertsIfZeroAmount` | Revert si amount_in es 0 |
| `test_ZapDepositERC20_SlippageProtection` | Revierte si min_weth_out demasiado alto |
| `test_ZapWithdrawETH_Success` | Retirar shares → recibir ETH funciona |
| `test_ZapWithdrawETH_RevertsIfZeroShares` | Revert si shares es 0 |
| `test_ZapWithdrawETH_StatelessEnforcement` | Router balance = 0 tras retiro |
| `test_ZapWithdrawERC20_Success_USDC` | Retirar shares → recibir USDC funciona |
| `test_ZapWithdrawERC20_RevertsIfTokenIsWETH` | Revert si token_out es WETH |
| `test_ZapWithdrawERC20_OnlyChecksTokenOutBalance` | Solo verifica balance de token_out (no WETH) |

**Coverage**: 98.36% lines, 80.95% statements, 28.57% branches, 100.00% functions

---

## 2. Tests de Integración

### FullFlow.t.sol — `test/integration/FullFlow.t.sol`

10 tests end-to-end que validan flujos completos cruzando vault → manager → strategies → protocolos reales + flujos Router.

| Test | Descripción |
| --- | --- |
| `test_E2E_DepositAllocateWithdraw` | Happy path completo: deposit → allocation a estrategias → withdraw |
| `test_E2E_MultipleUsersConcurrent` | Múltiples usuarios (Alice + Bob) depositando y retirando concurrentemente |
| `test_E2E_DepositRebalanceWithdraw` | Deposit → cambio de APY → rebalance → withdraw sin pérdida de fondos |
| `test_E2E_PauseUnpauseRecovery` | Deposit → pause (bloquea operaciones) → unpause → withdraw funciona |
| `test_E2E_RemoveStrategyAndWithdraw` | Deposit → eliminar estrategia → withdraw sin fondos bloqueados |
| `test_E2E_YieldAccrual` | Deposit → avanza 30 días → comprueba que totalAssets creció por yield real |
| `test_E2E_Router_DepositUSDC_WithdrawUSDC` | Depositar USDC vía Router → retirarlo en USDC |
| `test_E2E_Router_DepositETH_WithdrawETH` | Depositar ETH vía Router → retirarlo en ETH |
| `test_E2E_Router_DepositDAI_WithdrawUSDC` | Depositar DAI → retirar USDC (tokens diferentes) |
| `test_E2E_Router_DepositWBTC_UsesPool3000` | WBTC usa pool 0.3% (no 0.05%) |

---

## 3. Fuzz Tests

### Fuzz.t.sol — `test/fuzz/Fuzz.t.sol`

6 tests stateless con inputs aleatorios. Cada test recibe valores aleatorios acotados a rangos válidos y verifica propiedades que deben cumplirse para cualquier input.

| Test | Runs | Descripción |
| --- | --- | --- |
| `testFuzz_Deposit_GeneratesShares` | 256 | Para cualquier amount válido, deposit genera shares > 0 y totalAssets crece |
| `testFuzz_Withdraw_NeverExceedsDeposit` | 257 | Para cualquier withdraw parcial, el usuario no extrae más de lo depositado |
| `testFuzz_Redeem_BurnsExactShares` | 257 | Redeem quema exactamente las shares indicadas, ni más ni menos |
| `testFuzz_DepositRedeem_NeverProfitable` | 257 | Deposit → redeem inmediato nunca genera profit |
| `testFuzz_Router_ZapDepositETH` | 256 | zapDepositETH con cualquier amount válido (0.01-1000 ETH) genera shares |
| `testFuzz_Router_ZapDepositERC20` | 256 | zapDepositERC20 con cualquier amount y pool_fee válido genera shares |

Configuración: 256 runs por test (configurable en `foundry.toml`).

---

## 4. Invariant Tests

### Invariants.t.sol — `test/invariant/Invariants.t.sol`

4 invariantes stateful. A diferencia de los fuzz tests, Foundry ejecuta **secuencias aleatorias** de operaciones (deposit, withdraw, harvest, routerZapDeposit, routerZapWithdraw...) y tras cada secuencia verifica que las propiedades globales se mantengan.

| Invariante | Propiedad |
| --- | --- |
| `invariant_VaultIsSolvent` | totalAssets >= 99% × totalSupply (el vault puede cubrir todas las shares, 1% tolerancia por fees) |
| `invariant_AccountingIsConsistent` | idle_weth + manager.totalAssets() == vault.totalAssets() (contabilidad cuadra) |
| `invariant_SupplyIsCoherent` | Suma de balances individuales <= totalSupply (no se crean shares de la nada) |
| `invariant_RouterAlwaysStateless` | Router nunca retiene WETH ni ETH entre transacciones (balance siempre 0) |

### Handler.sol — `test/invariant/Handler.sol`

Contrato intermediario que acota las llamadas al vault y router para que el fuzzer no pierda tiempo en reverts inútiles. Expone acciones:

**Vault directo:**
- **`deposit(actor_seed, amount)`**: Elige un actor aleatorio, acota amount al espacio disponible en el vault y deposita
- **`withdraw(actor_seed, amount)`**: Elige un actor con shares, acota amount a su máximo retirable y retira
- **`harvest()`**: Avanza 1-7 días y ejecuta harvest si hay profit mínimo

**Router:**
- **`routerZapDepositETH(actor_seed, amount)`**: Deposita ETH vía Router
- **`routerZapDepositUSDC(actor_seed, amount)`**: Deposita USDC vía Router (swap + deposit)
- **`routerZapWithdrawETH(actor_seed, shares)`**: Retira shares vía Router → recibe ETH

Incluye ghost variables (`ghost_totalDeposited`, `ghost_totalWithdrawn`) para tracking.

### Ejecución de Invariant Tests

Los invariant tests generan un volumen de llamadas RPC significativamente mayor que los tests normales (32 runs × 15 depth = 480 secuencias de operaciones). Esto agota rápidamente el rate limit del free tier de Alchemy y otros proveedores (HTTP 429).

Para solucionarlo, se utiliza un script que lanza **Anvil como proxy local** con rate limiting controlado:

```bash
./script/run_invariants_offline.sh
```

**Cómo funciona el script:**

1. **Anvil con rate limiting**: Lanza Anvil con `--compute-units-per-second 10` para controlar la velocidad de llamadas RPC al nodo remoto
2. **Warmup del cache**: Ejecuta un test de integración simple para que Foundry cachee los contratos de Lido, Aave, Curve y Uniswap V3 en `~/.foundry/cache`
3. **Fuzzing controlado**: Ejecuta los invariant tests contra Anvil local (que sirve del cache) en lugar de directamente contra Alchemy
4. **Cleanup automático**: Mata procesos Anvil y elimina archivos temporales

**Opciones del script:**

```bash
# Default: 32 runs × 15 depth = 480 calls
./script/run_invariants_offline.sh

# Más runs (más exhaustivo)
./script/run_invariants_offline.sh -r 64

# Bloque custom
./script/run_invariants_offline.sh -b 21800000

# Si sigue fallando por rate limit, reducir runs
./script/run_invariants_offline.sh -r 16
```

### Resultado de Ejecución

Los 4 invariant tests se ejecutaron exitosamente, validando las propiedades críticas del sistema:

```
Ran 4 tests for test/invariant/Invariants.t.sol:InvariantsTest
[PASS] invariant_AccountingIsConsistent() (runs: 32, calls: 480, reverts: 75)
[PASS] invariant_RouterAlwaysStateless()  (runs: 32, calls: 480, reverts: 55)
[PASS] invariant_SupplyIsCoherent()       (runs: 32, calls: 480, reverts: 62)
[PASS] invariant_VaultIsSolvent()         (runs: 32, calls: 480, reverts: 55)

Suite result: ok. 4 passed; 0 failed; 0 skipped; finished in 177.15s (645.46s CPU time)
```

**Estadísticas de ejecución (32 runs)**:

| Acción Handler | Calls (promedio) | Reverts (promedio) | Notas |
| --- | --- | --- | --- |
| `deposit` | ~76 | 0 | Nunca revierte (amount acotado) |
| `harvest` | ~84 | 0 | Nunca revierte (skip time garantizado) |
| `routerZapDepositETH` | ~82 | ~6 | Reverts por max_tvl |
| `routerZapDepositUSDC` | ~81 | ~6 | Reverts por slippage/max_tvl |
| `routerZapWithdrawETH` | ~83 | ~23 | Reverts por shares insuficientes |
| `withdraw` | ~74 | ~27 | Reverts por shares insuficientes |

- Total de secuencias ejecutadas: 1,920 (4 invariantes × 32 runs × 15 depth)
- Tiempo de ejecución: ~177s con Anvil como proxy

**Importante**: Los invariant tests requieren un **periodo de cooldown del RPC** entre ejecuciones. Si se ejecutan inmediatamente después de otros tests que consumen muchas llamadas, pueden fallar con HTTP 429 debido al rate limiting acumulado del free tier de Alchemy. Esto es **normal** y no indica un problema en el código — simplemente espera 5-10 minutos o usa un RPC con mayor rate limit.

---

## Coverage Global

```
╭──────────────────────────────+──────────────────+──────────────────+─────────────────+──────────────────╮
│ Contrato                      │ Lines            │ Statements       │ Branches        │ Functions        │
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

**Nota**: El coverage reportado solo incluye unit, integration y fuzz tests. Los invariant tests se ejecutan vía Anvil y no se reflejan en `forge coverage`. Se requiere `--ir-minimum` por stack-too-deep en UniswapV3Strategy.

---

## Convenciones

- **Naming**: `test_Feature_Behavior` para unit/integration, `testFuzz_` para fuzz, `invariant_` para invariantes
- **Helpers**: `_deposit()` y `_withdraw()` en cada fichero para reducir duplicación en happy paths
- **Separadores**: Estilo Solmate (`//*`) para organizar secciones dentro de cada contrato
- **Tolerancias**: `assertApproxEqRel` con 0.1% (0.001e18) para compensar fees/slippage reales de Lido/Aave/Curve/Uniswap V3
- **Pool seeding**: Los tests seedean pools de Uniswap V3 (wstETH/WETH) con liquidez concentrada para prevenir slippage excesivo en fork
- **Sin mocks**: 100% de las interacciones son contra contratos reales de Mainnet vía fork
