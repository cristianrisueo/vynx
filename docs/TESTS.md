# Testing

Este documento describe la suite de tests de VynX V2 (Vault + Router), incluyendo estructura, ficheros, coverage y particularidades de ejecución.

---

## Visión General

Todos los tests se ejecutan contra un **fork de Ethereum Mainnet** real mediante Alchemy. No se utilizan mocks: las interacciones con Aave v3 y Compound v3 son reales contra el estado del blockchain. Esto garantiza que el comportamiento testeado es idéntico al de producción.

```
test/
├── unit/                    # Tests unitarios por contrato
│   ├── Vault.t.sol
│   ├── StrategyManager.t.sol
│   ├── AaveStrategy.t.sol
│   ├── CompoundStrategy.t.sol
│   └── Router.t.sol
├── integration/             # Tests de integración end-to-end
│   └── FullFlow.t.sol
├── fuzz/                    # Fuzz tests stateless
│   └── Fuzz.t.sol
└── invariant/               # Invariant tests stateful
    ├── Invariants.t.sol
    └── Handler.sol
```

**Total: 96 tests** (76 unitarios + 10 integración + 6 fuzz + 4 invariantes)

### Ejecución

```bash
# Configurar RPC
export MAINNET_RPC_URL="https://eth-mainnet.g.alchemy.com/v2/<API_KEY>"

# Ejecutar unit + integration + fuzz
forge test -vv

# Ejecutar invariant tests (requiere Anvil con rate limiting)
./script/run_invariants_offline.sh
```

---

## 1. Tests Unitarios

Tests aislados por contrato. Validan cada función pública con happy paths y revert paths.

### Vault.t.sol — `test/unit/Vault.t.sol`

22 tests que cubren el vault ERC4626: deposits, withdrawals, minting, redeeming, fees, idle buffer y admin.

| Test                                     | Descripción                                              |
| ---------------------------------------- | -------------------------------------------------------- |
| `test_Deposit_Basic`                     | Depositar genera shares y actualiza idle buffer          |
| `test_Deposit_TriggersAllocation`        | Depósito que supera threshold envía fondos a estrategias |
| `test_Deposit_RevertZero`                | Revert si amount es 0                                    |
| `test_Deposit_RevertBelowMin`            | Revert si amount < min_deposit                           |
| `test_Deposit_RevertExceedsMaxTVL`       | Revert si excede max_tvl                                 |
| `test_Deposit_RevertWhenPaused`          | Revert si vault está pausado                             |
| `test_Mint_Basic`                        | Mint shares directamente funciona correctamente          |
| `test_Mint_RevertZero`                   | Revert si shares es 0                                    |
| `test_Withdraw_FromIdle`                 | Retiro servido desde idle buffer                         |
| `test_Withdraw_FromStrategies`           | Retiro que requiere retirar de estrategias               |
| `test_Withdraw_FeeCalculation`           | Fee del 2% se cobra correctamente                        |
| `test_Withdraw_RevertZero`               | Revert si amount es 0                                    |
| `test_Withdraw_RevertWhenPaused`         | Revert si vault está pausado                             |
| `test_Redeem_Basic`                      | Redeem quema shares y devuelve assets netos              |
| `test_Redeem_RevertZero`                 | Revert si shares es 0                                    |
| `test_AllocateIdle_RevertBelowThreshold` | Revert si idle < threshold al forzar allocation manual   |
| `test_TotalAssets_IdlePlusManager`       | totalAssets = idle_weth + manager.totalAssets()          |
| `test_MaxDeposit_RespectsMaxTVL`         | maxDeposit respeta el TVL máximo                         |
| `test_MaxMint_RespectsMaxTVL`            | maxMint respeta el TVL máximo                            |
| `test_Admin_OnlyOwnerCanSetParams`       | Solo el owner puede modificar parámetros                 |
| `test_Preview_WithdrawIncludesFee`       | previewWithdraw incluye fee en el cálculo                |
| `test_Preview_RedeemDeductsFee`          | previewRedeem descuenta fee del resultado                |

**Coverage**: 85.37% lines, 85.38% statements, 50.00% branches, 80.00% functions

### StrategyManager.t.sol — `test/unit/StrategyManager.t.sol`

18 tests que cubren allocation, withdrawals, rebalancing, gestión de estrategias y admin.

| Test                                              | Descripción                                          |
| ------------------------------------------------- | ---------------------------------------------------- |
| `test_InitializeVault_RevertIfAlreadyInitialized` | No se puede inicializar el vault dos veces           |
| `test_Allocate_Basic`                             | Fondos se distribuyen a las estrategias              |
| `test_Allocate_RevertIfNotVault`                  | Solo el vault puede llamar allocate                  |
| `test_Allocate_RevertZero`                        | Revert si amount es 0                                |
| `test_Allocate_RevertNoStrategies`                | Revert si no hay estrategias registradas             |
| `test_WithdrawTo_Basic`                           | Retiro proporcional de estrategias funciona          |
| `test_WithdrawTo_RevertIfNotVault`                | Solo el vault puede llamar withdrawTo                |
| `test_WithdrawTo_RevertZero`                      | Revert si amount es 0                                |
| `test_AddStrategy_Basic`                          | Añadir estrategia incrementa el contador             |
| `test_AddStrategy_RevertDuplicate`                | Revert si la estrategia ya existe                    |
| `test_RemoveStrategy_Basic`                       | Remover estrategia decrementa el contador            |
| `test_RemoveStrategy_RevertNotFound`              | Revert si la estrategia no existe                    |
| `test_Rebalance_ExecutesSuccessfully`             | Rebalance mueve fondos tras cambiar max allocation   |
| `test_Rebalance_RevertIfNotProfitable`            | Revert si el rebalance no es rentable                |
| `test_TotalAssets_SumsAllStrategies`              | totalAssets suma correctamente todas las estrategias |
| `test_StrategiesCount`                            | Devuelve el número correcto de estrategias           |
| `test_GetAllStrategiesInfo`                       | Devuelve info correcta (names, APYs, TVLs, targets)  |
| `test_Admin_OnlyOwnerCanSetParams`                | Solo el owner puede modificar parámetros del manager |

**Coverage**: 95.43% lines, 93.04% statements, 76.47% branches, 100.00% functions

### AaveStrategy.t.sol — `test/unit/AaveStrategy.t.sol`

10 tests que cubren la integración directa con Aave v3.

| Test                                   | Descripción                                   |
| -------------------------------------- | --------------------------------------------- |
| `test_Deposit_Basic`                   | Depósito en Aave genera aTokens correctamente |
| `test_Deposit_RevertIfNotManager`      | Solo el manager puede depositar               |
| `test_Withdraw_Basic`                  | Retiro parcial devuelve WETH al manager       |
| `test_Withdraw_Full`                   | Retiro total deja balance en 0                |
| `test_Withdraw_RevertIfNotManager`     | Solo el manager puede retirar                 |
| `test_Apy_ReturnsValidValue`           | APY está en rango razonable (0-50%)           |
| `test_Name`                            | Devuelve "Aave v3 WETH Strategy"              |
| `test_Asset`                           | Devuelve la dirección de WETH                 |
| `test_AvailableLiquidity`              | Liquidez disponible en Aave > 0               |
| `test_TotalAssets_ZeroWithoutDeposits` | totalAssets es 0 sin depósitos                |

**Coverage**: 88.89% lines, 93.10% statements, 60.00% branches, 100.00% functions

### CompoundStrategy.t.sol — `test/unit/CompoundStrategy.t.sol`

11 tests que cubren la integración directa con Compound v3.

| Test                                   | Descripción                                         |
| -------------------------------------- | --------------------------------------------------- |
| `test_Deposit_Basic`                   | Depósito en Compound registra balance correctamente |
| `test_Deposit_RevertIfNotManager`      | Solo el manager puede depositar                     |
| `test_Withdraw_Basic`                  | Retiro parcial devuelve WETH al manager             |
| `test_Withdraw_Full`                   | Retiro total deja balance en 0                      |
| `test_Withdraw_RevertIfNotManager`     | Solo el manager puede retirar                       |
| `test_Apy_ReturnsValidValue`           | APY está en rango razonable (0-50%)                 |
| `test_Name`                            | Devuelve "Compound v3 WETH Strategy"                |
| `test_Asset`                           | Devuelve la dirección de WETH                       |
| `test_GetSupplyRate`                   | Supply rate de Compound es > 0                      |
| `test_GetUtilization`                  | Utilization rate de Compound es > 0                 |
| `test_TotalAssets_ZeroWithoutDeposits` | totalAssets es 0 sin depósitos                      |

**Coverage**: 88.24% lines, 92.59% statements, 60.00% branches, 100.00% functions

### Router.t.sol — `test/unit/Router.t.sol`

15 tests que cubren el Router periférico: zap deposits (ETH/ERC20), zap withdrawals (ETH/ERC20), slippage, stateless.

| Test                                     | Descripción                                              |
| ---------------------------------------- | -------------------------------------------------------- |
| `test_ZapDepositETH_Success`             | Depositar ETH genera shares correctamente                |
| `test_ZapDepositETH_RevertsIfZeroAmount` | Revert si msg.value es 0                                 |
| `test_ZapDepositETH_StatelessEnforcement`| Router balance WETH = 0 tras depósito                    |
| `test_ZapDepositETH_EmitsEvent`          | Emite ZapDeposit correctamente                           |
| `test_ZapDepositERC20_Success_USDC`      | Depositar USDC → swap → shares funciona                  |
| `test_ZapDepositERC20_RevertsIfZeroAddress`| Revert si token_in es address(0)                       |
| `test_ZapDepositERC20_RevertsIfTokenIsWETH`| Revert si token_in es WETH (usar vault directo)       |
| `test_ZapDepositERC20_RevertsIfZeroAmount` | Revert si amount_in es 0                               |
| `test_ZapDepositERC20_SlippageProtection`| Revierte si min_weth_out demasiado alto                  |
| `test_ZapWithdrawETH_Success`            | Retirar shares → recibir ETH funciona                    |
| `test_ZapWithdrawETH_RevertsIfZeroShares`| Revert si shares es 0                                    |
| `test_ZapWithdrawETH_StatelessEnforcement`| Router balance = 0 tras retiro                          |
| `test_ZapWithdrawERC20_Success_USDC`     | Retirar shares → recibir USDC funciona                   |
| `test_ZapWithdrawERC20_RevertsIfTokenIsWETH`| Revert si token_out es WETH                           |
| `test_ZapWithdrawERC20_OnlyChecksTokenOutBalance`| Solo verifica balance de token_out (no WETH)       |

**Coverage**: 94.29% lines, 94.44% statements, 78.57% branches, 100.00% functions

---

## 2. Tests de Integración

### FullFlow.t.sol — `test/integration/FullFlow.t.sol`

10 tests end-to-end que validan flujos completos cruzando vault → manager → strategies → protocolos reales + flujos Router.

| Test                                 | Descripción                                                                                 |
| ------------------------------------ | ------------------------------------------------------------------------------------------- |
| `test_E2E_DepositAllocateWithdraw`   | Happy path completo: deposit → allocation a estrategias → withdraw con fees                 |
| `test_E2E_MultipleUsersConcurrent`   | Múltiples usuarios (Alice + Bob) depositando y retirando concurrentemente                   |
| `test_E2E_DepositRebalanceWithdraw`  | Deposit → cambio de max allocation → rebalance → withdraw sin pérdida de fondos             |
| `test_E2E_PauseUnpauseRecovery`      | Deposit → pause (bloquea operaciones) → unpause → withdraw funciona correctamente           |
| `test_E2E_RemoveStrategyAndWithdraw` | Deposit → eliminar estrategia Compound → withdraw desde Aave sin fondos bloqueados          |
| `test_E2E_YieldAccrual`              | Deposit → avanza 30 días → comprueba que totalAssets creció por yield real de Aave/Compound |
| `test_E2E_Router_DepositUSDC_WithdrawUSDC` | Depositar USDC vía Router → retirarlo en USDC                                      |
| `test_E2E_Router_DepositETH_WithdrawETH`   | Depositar ETH vía Router → retirarlo en ETH                                        |
| `test_E2E_Router_DepositDAI_WithdrawUSDC`  | Depositar DAI → retirar USDC (tokens diferentes)                                    |
| `test_E2E_Router_DepositWBTC_UsesPool3000` | WBTC usa pool 0.3% (no 0.05%)                                                       |

---

## 3. Fuzz Tests

### Fuzz.t.sol — `test/fuzz/Fuzz.t.sol`

6 tests stateless con inputs aleatorios. Cada test recibe valores aleatorios acotados a rangos válidos y verifica propiedades que deben cumplirse para cualquier input.

| Test                                     | Descripción                                                                 |
| ---------------------------------------- | --------------------------------------------------------------------------- |
| `testFuzz_Deposit_GeneratesShares`       | Para cualquier amount válido, deposit genera shares > 0 y totalAssets crece |
| `testFuzz_Withdraw_NeverExceedsDeposit`  | Para cualquier withdraw parcial, el usuario no extrae más de lo depositado  |
| `testFuzz_Redeem_BurnsExactShares`       | Redeem quema exactamente las shares indicadas, ni más ni menos              |
| `testFuzz_DepositRedeem_NeverProfitable` | Deposit → redeem inmediato nunca genera profit                              |
| `testFuzz_Router_ZapDepositETH`          | zapDepositETH con cualquier amount válido (0.01-1000 ETH) genera shares     |
| `testFuzz_Router_ZapDepositERC20`        | zapDepositERC20 con cualquier amount y pool_fee válido genera shares        |

Configuración: 256 runs por test (configurable en `foundry.toml`).

---

## 4. Invariant Tests

### Invariants.t.sol — `test/invariant/Invariants.t.sol`

4 invariantes stateful. A diferencia de los fuzz tests, Foundry ejecuta **secuencias aleatorias** de operaciones (deposit, withdraw, routerZapDeposit, routerZapWithdraw...) y tras cada secuencia verifica que las propiedades globales se mantengan.

| Invariante                         | Propiedad                                                                      |
| ---------------------------------- | ------------------------------------------------------------------------------ |
| `invariant_VaultIsSolvent`         | totalAssets >= totalSupply (el vault puede cubrir todas las shares)            |
| `invariant_AccountingIsConsistent` | idle_weth + manager.totalAssets() == vault.totalAssets() (contabilidad cuadra) |
| `invariant_SupplyIsCoherent`       | Suma de balances individuales <= totalSupply (no se crean shares de la nada)   |
| `invariant_RouterAlwaysStateless`  | Router nunca retiene WETH ni ETH entre transacciones (balance siempre 0)       |

### Handler.sol — `test/invariant/Handler.sol`

Contrato intermediario que acota las llamadas al vault y router para que el fuzzer no pierda tiempo en reverts inútiles. Expone acciones:

**Vault directo:**
- **`deposit(actor_seed, amount)`**: Elige un actor aleatorio, acota amount al espacio disponible en el vault y deposita
- **`withdraw(actor_seed, amount)`**: Elige un actor con shares, acota amount a su máximo retirable y retira
- **`harvest()`**: Ejecuta harvest si hay profit mínimo

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
2. **Warmup del cache**: Ejecuta un test de integración simple para que Foundry cachee los contratos de Aave y Compound en `~/.foundry/cache`
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

Los 3 invariant tests se ejecutaron exitosamente durante el desarrollo del protocolo, validando las propiedades críticas del sistema:

```
Ran 3 tests for test/invariant/Invariants.t.sol:InvariantsTest
[PASS] invariant_AccountingIsConsistent() (runs: 32, calls: 480, reverts: 0)
[PASS] invariant_SupplyIsCoherent() (runs: 32, calls: 480, reverts: 0)
[PASS] invariant_VaultIsSolvent() (runs: 32, calls: 480, reverts: 1)

Suite result: ok. 3 passed; 0 failed; 0 skipped
```

**Estadísticas de ejecución (32 runs)**:
- Total de secuencias ejecutadas: 480 (32 runs × 15 depth)
- Operaciones realizadas: ~950 llamadas al vault (deposit + withdraw)
- Reverts esperados: 1 (caso edge donde withdraw excede liquidez disponible)
- Tiempo de ejecución: ~100s con Anvil como proxy

**Importante**: Los invariant tests requieren un **periodo de cooldown del RPC** entre ejecuciones. Si se ejecutan inmediatamente después de otros tests que consumen muchas llamadas (como el dry-run del deployment), pueden fallar con HTTP 429 debido al rate limiting acumulado del free tier de Alchemy. Esto es **normal** y no indica un problema en el código — simplemente espera 5-10 minutos o usa un RPC con mayor rate limit (Alchemy Growth Plan o nodo local).

---

## Coverage Global

```
╭─────────────────────────────────+──────────+──────────────+────────────+─────────╮
│ Contrato                        │ Lines    │ Statements   │ Branches   │ Funcs   │
╞═════════════════════════════════╪══════════╪══════════════╪════════════╪═════════╡
│ Vault.sol                       │ 95.32%   │ 92.98%       │ 76.67%    │ 100.00% │
│ StrategyManager.sol             │ 75.57%   │ 69.53%       │ 56.41%    │ 100.00% │
│ AaveStrategy.sol                │ 70.49%   │ 70.18%       │ 50.00%    │ 91.67%  │
│ CompoundStrategy.sol            │ 80.70%   │ 86.00%       │ 70.00%    │ 91.67%  │
│ Router.sol                      │ 94.29%   │ 94.44%       │ 78.57%    │ 100.00% │
╞═════════════════════════════════╪══════════╪══════════════╪════════════╪═════════╡
│ Total                           │ 84.52%   │ 81.23%       │ 66.18%    │ 97.83%  │
╰─────────────────────────────────+──────────+──────────────+────────────+─────────╯
```

**Nota**: El coverage reportado solo incluye unit, integration y fuzz tests. Los invariant tests se ejecutan vía Anvil y no se reflejan en `forge coverage`.

---

## Convenciones

- **Naming**: `test_Feature_Behavior` para unit/integration, `testFuzz_` para fuzz, `invariant_` para invariantes
- **Helpers**: `_deposit()` y `_withdraw()` en cada fichero para reducir duplicación en happy paths
- **Separadores**: Estilo Solmate (`//*`) para organizar secciones dentro de cada contrato
- **Tolerancias**: `assertApproxEqRel` con 0.1% (0.001e18) para compensar fees reales de Aave/Compound
- **Sin mocks**: 100% de las interacciones son contra contratos reales de Mainnet vía fork
