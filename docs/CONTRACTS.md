# Documentación de Contratos

Este documento proporciona documentación técnica detallada de cada contrato del protocolo VynX V2, incluyendo variables de estado, funciones principales, eventos y modificadores.

**Contratos documentados:**
- [Vault.sol](#vaultsol) — ERC4626 vault con idle buffer y fees
- [StrategyManager.sol](#strategymanagersol) — Motor de allocation y rebalancing
- [LidoStrategy.sol](#lidostrategysol) — Lido staking: WETH → wstETH (auto-compound)
- [AaveStrategy.sol](#aavestrategy-wstethsol) — Doble yield: wstETH + Aave lending
- [CurveStrategy.sol](#curvestrategysol) — Curve stETH/ETH LP + gauge CRV
- [UniswapV3Strategy.sol](#uniswapv3strategysol) — Liquidez concentrada WETH/USDC ±10%
- [IStrategy.sol](#istrategysol) — Interfaz estándar de estrategias
- [Router.sol](#routersol) — Router multi-token (ETH/ERC20 → WETH → Vault)
- [IRouter.sol](#iroutersol) — Interfaz del Router

---

## Vault.sol

**Ubicación**: `src/core/Vault.sol`

### Propósito

Vault ERC4626 que actúa como interfaz principal para usuarios. Mintea shares tokenizadas (vxWETH) en proporción a los assets depositados, acumula WETH en un idle buffer para optimizar gas, coordina harvest de rewards con distribución de performance fees, y gestiona el keeper incentive system.

### Herencia

- `ERC4626` (OpenZeppelin): Implementación estándar de vault tokenizado
- `ERC20` (OpenZeppelin): Token de shares (vxWETH, nombre dinámico: "VynX {SYMBOL} Vault")
- `Ownable` (OpenZeppelin): Control de acceso administrativo
- `Pausable` (OpenZeppelin): Emergency stop para deposits/withdrawals/harvest

### Llamado Por

- **Usuarios (EOAs/contratos)**: `deposit()`, `mint()`, `withdraw()`, `redeem()`
- **Keepers/Cualquiera**: `harvest()`, `allocateIdle()`
- **Owner**: Funciones administrativas (pause, setters)

### Llama A

- **StrategyManager**: `allocate()` cuando idle buffer alcanza threshold, `withdrawTo()` cuando usuarios retiran, `harvest()` cuando alguien cosecha
- **IERC20(WETH)**: Transferencias de WETH (SafeERC20)

### Variables de Estado Clave

```solidity
// Constantes
uint256 public constant BASIS_POINTS = 10000;       // 100% = 10000 basis points

// Dirección del strategy manager
address public strategy_manager;                      // Motor de allocation y harvest

// Keeper system
mapping(address => bool) public is_official_keeper;    // Keepers oficiales (sin incentivo)

// Direcciones de fee recipients
address public treasury_address;                      // Recibe 80% perf fee en SHARES
address public founder_address;                       // Recibe 20% perf fee en WETH

// Estado del idle buffer
uint256 public idle_buffer;                           // WETH acumulado pendiente de invertir

// Contadores de harvest
uint256 public last_harvest;                          // Timestamp del último harvest
uint256 public total_harvested;                       // Profit bruto total acumulado

// Parámetros de harvest (configurables por tier)
uint256 public min_profit_for_harvest;               // 0.08 ETH (Balanced) / 0.12 ETH (Aggressive)
uint256 public keeper_incentive = 100;               // 1% (100 bp) del profit para keepers ext.

// Parámetros de fees
uint256 public performance_fee = 2000;               // 20% (2000 bp) sobre profits
uint256 public treasury_split = 8000;                // 80% del perf fee → treasury (shares)
uint256 public founder_split = 2000;                 // 20% del perf fee → founder (WETH)

// Circuit breakers (configurables por tier)
uint256 public min_deposit = 0.01 ether;             // Anti-spam, anti-rounding
uint256 public idle_threshold;                       // 8 ETH (Balanced) / 12 ETH (Aggressive)
uint256 public max_tvl = 1000 ether;                 // TVL máximo permitido
```

### Funciones Principales

#### deposit(uint256 assets, address receiver) → uint256 shares

Deposita WETH en el vault y mintea shares al usuario.

**Flujo:**
1. Verifica `assets >= min_deposit` (0.01 ETH)
2. Verifica `totalAssets() + assets <= max_tvl` (circuit breaker)
3. Calcula shares usando `previewDeposit(assets)` (antes de cambiar estado)
4. Transfiere WETH del usuario al vault (`SafeERC20.safeTransferFrom`)
5. Incrementa `idle_buffer += assets` (acumula en buffer)
6. Mintea shares al receiver (`_mint`)
7. Si `idle_buffer >= idle_threshold` (8 ETH Balanced / 12 ETH Aggressive), auto-ejecuta `_allocateIdle()`

**Modificadores**: `whenNotPaused`

**Eventos**: `Deposited(receiver, assets, shares)`

---

#### mint(uint256 shares, address receiver) → uint256 assets

Mintea cantidad exacta de shares depositando los assets necesarios.

**Flujo:**
1. Verifica `shares > 0`
2. Calcula assets necesarios usando `previewMint(shares)`
3. Similar a `deposit()` a partir de aquí

**Modificadores**: `whenNotPaused`

**Eventos**: `Deposited(receiver, assets, shares)`

---

#### withdraw(uint256 assets, address receiver, address owner) → uint256 shares

Retira cantidad exacta de WETH quemando shares necesarias.

**Flujo:**
1. Calcula shares a quemar usando `previewWithdraw(assets)`
2. Verifica allowance si `msg.sender != owner` (`_spendAllowance`)
3. Quema shares del owner (`_burn`) - **CEI pattern**
4. Calcula `from_idle = min(idle_buffer, assets)`
5. Calcula `from_strategies = assets - from_idle`
6. Si `from_strategies > 0`, llama `manager.withdrawTo(from_strategies, vault)`
7. Verifica rounding tolerance: `assets - to_transfer < 20 wei`
8. Transfiere `assets` netos al `receiver`

**Modificadores**: `whenNotPaused`

**Eventos**: `Withdrawn(receiver, assets, shares)`

**Nota sobre rounding**: Protocolos externos (Aave, Curve, Uniswap V3) pueden redondear a la baja ~1-2 wei por operación. El vault tolera hasta 20 wei de diferencia (margen para hasta ~10 estrategias). Si la diferencia excede 20 wei, revierte con "Excessive rounding" (problema de accounting serio).

---

#### redeem(uint256 shares, address receiver, address owner) → uint256 assets

Quema shares exactas y retira WETH proporcional.

**Flujo:**
1. Calcula assets netos usando `previewRedeem(shares)`
2. Similar a `withdraw()` a partir de aquí

**Modificadores**: `whenNotPaused`

**Eventos**: `Withdrawn(receiver, assets, shares)`

---

#### harvest() → uint256 profit

Cosecha rewards de todas las estrategias y distribuye performance fees.

**Precondiciones**: Vault no pausado. Cualquiera puede llamar.

**Flujo:**
1. Llama `IStrategyManager(strategy_manager).harvest()` → obtiene `profit`
2. Si `profit < min_profit_for_harvest` (0.08 ETH Balanced / 0.12 ETH Aggressive) → return 0 (no distribuye)
3. Si caller no es keeper oficial:
   - Calcula `keeper_reward = (profit * keeper_incentive) / BASIS_POINTS`
   - Paga desde `idle_buffer` si hay suficiente, sino retira de estrategias
   - Transfiere `keeper_reward` WETH al caller
4. Calcula `net_profit = profit - keeper_reward`
5. Calcula `perf_fee = (net_profit * performance_fee) / BASIS_POINTS`
6. Distribuye fees via `_distributePerformanceFee(perf_fee)`:
   - Treasury: `treasury_amount = (perf_fee * treasury_split) / BP` → mintea shares
   - Founder: `founder_amount = (perf_fee * founder_split) / BP` → transfiere WETH
7. Actualiza `last_harvest = block.timestamp`, `total_harvested += profit`

**Modificadores**: `whenNotPaused`

**Eventos**: `Harvested(profit, perf_fee, timestamp)`, `PerformanceFeeDistributed(treasury_amount, founder_amount)`

**Ejemplo numérico:**
```solidity
// profit = 5.5 WETH (de harvest de estrategias)
// Caller es keeper externo (no oficial)
//
// keeper_reward = 5.5 * 100 / 10000 = 0.055 WETH → pagado al keeper
// net_profit = 5.5 - 0.055 = 5.445 WETH
// perf_fee = 5.445 * 2000 / 10000 = 1.089 WETH
// treasury_amount = 1.089 * 8000 / 10000 = 0.8712 WETH → mintea shares al treasury
// founder_amount = 1.089 * 2000 / 10000 = 0.2178 WETH → transfiere WETH al founder
```

---

#### totalAssets() → uint256

Calcula TVL total bajo gestión del vault.

```solidity
function totalAssets() public view returns (uint256) {
    return idle_buffer + IStrategyManager(strategy_manager).totalAssets();
}
```

**Incluye:**
- `idle_buffer`: WETH físico en el vault (pendiente de invertir)
- `strategy_manager.totalAssets()`: Suma de WETH en todas las estrategias (incluye yield)

---

#### maxDeposit(address) → uint256

Retorna máximo depositible antes de alcanzar max_tvl. Retorna 0 si pausado.

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

Retorna máximo de shares minteables antes de alcanzar max_tvl. Retorna 0 si pausado.

---

### Funciones Internas

#### _allocateIdle()

Transfiere idle buffer al StrategyManager para inversión.

**Flujo:**
1. Guarda `to_allocate = idle_buffer`
2. Resetea `idle_buffer = 0`
3. Transfiere WETH al manager (`safeTransfer`)
4. Llama `manager.allocate(to_allocate)`

**Llamada desde:**
- `deposit()` / `mint()` si `idle_buffer >= idle_threshold`
- `allocateIdle()` (externa, cualquiera puede llamar si idle >= threshold)

---

#### _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)

Override de ERC4626._withdraw con lógica custom de retiro.

**Flujo:**
1. Reduce allowance si `caller != owner`
2. Quema shares del owner (CEI pattern)
3. Calcula `from_idle = min(idle_buffer, assets)`
4. Resta `idle_buffer -= from_idle`
5. Si `from_strategies > 0`, llama `manager.withdrawTo(from_strategies, vault)`
6. Obtiene `balance = IERC20(asset).balanceOf(address(this))`
7. Calcula `to_transfer = min(assets, balance)`
8. Verifica rounding: `assets - to_transfer < 20` (revierte si excede)
9. Transfiere al receiver

---

#### _distributePerformanceFee(uint256 perf_fee)

Distribuye performance fees entre treasury y founder.

**Flujo:**
1. `treasury_amount = (perf_fee * treasury_split) / BASIS_POINTS`
2. `founder_amount = (perf_fee * founder_split) / BASIS_POINTS`
3. Treasury: convierte `treasury_amount` a shares → `_mint(treasury_address, treasury_shares)`
4. Founder: retira de idle_buffer o estrategias → `safeTransfer(founder_address, founder_amount)`

---

### Funciones Administrativas

```solidity
// Emergency stop
function pause() external onlyOwner
function unpause() external onlyOwner

// Configuración de fees
function setPerformanceFee(uint256 new_fee) external onlyOwner      // Max: 10000 (100%)
function setFeeSplit(uint256 new_treasury, uint256 new_founder) external onlyOwner
    // Requiere: new_treasury + new_founder == BASIS_POINTS

// Configuración del idle buffer
function setIdleThreshold(uint256 new_threshold) external onlyOwner
function allocateIdle() external whenNotPaused  // Cualquiera si idle >= threshold

// Circuit breakers
function setMaxTVL(uint256 new_max) external onlyOwner
function setMinDeposit(uint256 new_min) external onlyOwner

// Direcciones
function setTreasury(address new_treasury) external onlyOwner       // No address(0)
function setFounder(address new_founder) external onlyOwner         // No address(0)
function setStrategyManager(address new_manager) external onlyOwner // No address(0)

// Keeper system
function setOfficialKeeper(address keeper, bool status) external onlyOwner
function setMinProfitForHarvest(uint256 new_min) external onlyOwner
function setKeeperIncentive(uint256 new_incentive) external onlyOwner
```

### Eventos Importantes

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

### Errores Custom

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

**Ubicación**: `src/core/StrategyManager.sol`

### Propósito

Cerebro del protocolo que calcula weighted allocation basado en APY, distribuye assets entre estrategias, ejecuta rebalanceos rentables, retira proporcionalmente durante withdrawals, y coordina harvest fail-safe de todas las estrategias.

### Herencia

- `Ownable` (OpenZeppelin): Control de acceso administrativo

### Llamado Por

- **Vault**: `allocate()`, `withdrawTo()`, `harvest()` (modificador `onlyVault`)
- **Owner**: `addStrategy()`, `removeStrategy()`, setters
- **Cualquiera**: `rebalance()` (si `shouldRebalance()` es true)

### Llama A

- **IStrategy**: `deposit()`, `withdraw()`, `harvest()`, `totalAssets()`, `apy()`

### Variables de Estado Clave

```solidity
// Constantes
uint256 public constant BASIS_POINTS = 10000;               // 100% = 10000 bp
uint256 public constant MAX_STRATEGIES = 10;                 // Previene gas DoS en loops

// Inmutables
address public immutable asset;                              // WETH

// Vault (set via initialize, una sola vez)
address public vault;                                        // Vault autorizado

// Estrategias disponibles
IStrategy[] public strategies;
mapping(address => bool) public is_strategy;
mapping(IStrategy => uint256) public target_allocation;       // En basis points

// Parámetros de allocation (configurables por tier)
uint256 public max_allocation_per_strategy;   // 5000 bp Balanced (50%) / 7000 bp Aggressive (70%)
uint256 public min_allocation_threshold;      // 2000 bp Balanced (20%) / 1000 bp Aggressive (10%)

// Parámetros de rebalancing (configurables por tier)
uint256 public rebalance_threshold;           // 200 bp Balanced (2%) / 300 bp Aggressive (3%)
uint256 public min_tvl_for_rebalance;         // 8 ETH Balanced / 12 ETH Aggressive
```

### Funciones Principales

#### allocate(uint256 assets)

Distribuye WETH entre estrategias según target allocation.

**Precondición**: Vault debe transferir WETH al manager antes de llamar.

**Flujo:**
1. Verifica `assets > 0` y `strategies.length > 0`
2. Llama `_calculateTargetAllocation()`:
   - Obtiene APY de cada estrategia
   - Calcula targets usando `_computeTargets()` (weighted allocation)
   - Escribe targets al storage: `target_allocation[strategy] = target`
3. Para cada estrategia con `target > 0`:
   - Calcula `amount = (assets * target) / BASIS_POINTS`
   - Transfiere `amount` WETH a la estrategia
   - Llama `strategy.deposit(amount)`
   - Emite `Allocated(strategy, amount)`

**Modificadores**: `onlyVault`

**Eventos**: `Allocated(strategy, assets)` por cada estrategia

**Ejemplo (Tier Balanced con 3 estrategias):**
```solidity
// Si recibe 100 WETH y targets son [3000, 4000, 3000] (30%, 40%, 30%):
// - LidoStrategy recibe 30 WETH
// - AaveStrategy recibe 40 WETH
// - CurveStrategy recibe 30 WETH
```

---

#### withdrawTo(uint256 assets, address receiver)

Retira WETH de estrategias proporcionalmente y transfiere al receiver.

**Flujo:**
1. Verifica `assets > 0`
2. Obtiene `total_assets = totalAssets()`
3. Si `total_assets == 0`, retorna (edge case)
4. Para cada estrategia:
   - Obtiene `strategy_balance = strategy.totalAssets()`
   - Si `strategy_balance == 0`, continúa
   - Calcula proporcional: `to_withdraw = (assets * strategy_balance) / total_assets`
   - Llama `strategy.withdraw(to_withdraw)` → captura `actual_withdrawn`
   - Acumula `total_withdrawn += actual_withdrawn`
5. Transfiere `total_withdrawn` WETH del manager al receiver

**Modificadores**: `onlyVault`

**Nota**: Retira proporcionalmente para mantener ratios. NO recalcula target allocation (ahorro de gas). Usa `actual_withdrawn` para contabilizar rounding de protocolos externos.

**Ejemplo (Tier Balanced con 3 estrategias):**
```solidity
// Estado: Lido 40 WETH, Aave 40 WETH, Curve 20 WETH (total 100 WETH)
// Usuario retira 50 WETH
// - De Lido:  50 * 40/100 = 20 WETH
// - De Aave:  50 * 40/100 = 20 WETH
// - De Curve: 50 * 20/100 = 10 WETH
// Resultado: Lido 20, Aave 20, Curve 10 (mantiene ratios 40/40/20)
```

---

#### harvest() → uint256 total_profit

Cosecha rewards de todas las estrategias con fail-safe.

**Flujo:**
1. Para cada estrategia:
   - `try strategy.harvest()` → acumula profit si éxito
   - `catch` → emite `HarvestFailed(strategy, reason)` y continúa
2. Retorna `total_profit` (suma de profits individuales)

**Modificadores**: `onlyVault`

**Eventos**: `Harvested(total_profit)`, `HarvestFailed(strategy, reason)` si alguna falla

**Nota**: El fail-safe es crítico — si CurveStrategy harvest falla por falta de rewards, LidoStrategy y AaveStrategy continúan normalmente. LidoStrategy siempre retorna 0 desde harvest (sin harvest activo).

---

#### rebalance()

Ajusta cada estrategia a su target allocation moviendo solo deltas necesarios.

**Precondición**: `shouldRebalance()` debe ser true (revierte si no).

**Flujo:**
1. Verifica rentabilidad con `shouldRebalance()`
2. Recalcula targets frescos: `_calculateTargetAllocation()`
3. Obtiene `total_tvl = totalAssets()`
4. Para cada estrategia:
   - Calcula `current_balance = strategy.totalAssets()`
   - Calcula `target_balance = (total_tvl * target) / BASIS_POINTS`
   - Si `current > target`: Añade a array de exceso
   - Si `target > current`: Añade a array de necesidad
5. Para cada estrategia con exceso:
   - Retira exceso: `strategy.withdraw(excess)`
6. Para cada estrategia con necesidad:
   - Calcula `to_transfer = min(available, needed)`
   - Transfiere WETH a estrategia destino
   - Deposita: `strategy.deposit(to_transfer)`
   - Emite `Rebalanced(from_strategy, to_strategy, amount)`

**Modificadores**: Ninguno (público)

**Eventos**: `Rebalanced(from_strategy, to_strategy, assets)`

**Ejemplo (Tier Aggressive: Curve 6% vs UniswapV3 14%):**
```solidity
// Estado actual: Curve 50 WETH (6% APY), UniswapV3 50 WETH (14% APY)
// Targets recalculados: Curve ~30% (30 WETH), UniswapV3 ~70% (70 WETH)
// Rebalance:
//   1. Retira 20 WETH de CurveStrategy
//   2. Deposita 20 WETH en UniswapV3Strategy
// Estado final: Curve 30 WETH, UniswapV3 70 WETH
// (APY diferencia: 14-6 = 8% >= 3% threshold → rebalance válido)
```

---

#### shouldRebalance() → bool

Verifica si un rebalance es rentable comparando diferencia de APY entre estrategias.

**Flujo:**
1. Verifica `strategies.length >= 2`
2. Verifica `totalAssets() >= min_tvl_for_rebalance` (10 ETH)
3. Calcula `max_apy` y `min_apy` entre todas las estrategias
4. Retorna `(max_apy - min_apy) >= rebalance_threshold` (200 bp = 2%)

**Nota**: Es función `view` (no modifica estado), puede ser llamada por bots/frontends.

**Ejemplo de cálculo (Tier Aggressive):**
```solidity
// Curve APY: 6% (600 bp), UniswapV3 APY: 14% (1400 bp)
// Diferencia: 1400 - 600 = 800 bp
// Threshold Aggressive: 300 bp
// 800 >= 300 → ✅ shouldRebalance = true
```

---

### Funciones de Gestión de Estrategias

#### addStrategy(address strategy)

Agrega nueva estrategia al manager.

**Flujo:**
1. Verifica que estrategia no exista (`!is_strategy[strategy]`)
2. Verifica `strategies.length < MAX_STRATEGIES` (max 10)
3. Verifica `strategy.asset() == asset` (mismo underlying)
4. Añade al array: `strategies.push(IStrategy(strategy))`
5. Marca como existente: `is_strategy[strategy] = true`
6. Recalcula target allocations: `_calculateTargetAllocation()`

**Modificadores**: `onlyOwner`

**Eventos**: `StrategyAdded(strategy)`, `TargetAllocationUpdated()`

---

#### removeStrategy(uint256 index)

Remueve estrategia del manager por índice.

**Precondición**: Estrategia debe tener balance cero antes de remover.

**Flujo:**
1. Verifica que estrategia en `index` tenga `totalAssets() == 0`
2. Elimina target: `delete target_allocation[strategies[index]]`
3. Swap & pop: `strategies[index] = strategies[length-1]; strategies.pop()`
4. Marca como no existente: `is_strategy[strategy] = false`
5. Recalcula targets para estrategias restantes

**Modificadores**: `onlyOwner`

**Eventos**: `StrategyRemoved(strategy)`, `TargetAllocationUpdated()`

---

### Funciones Internas

#### _computeTargets() → uint256[]

Calcula targets de allocation basados en APY con caps.

**Algoritmo:**
1. Si no hay estrategias: retorna array vacío
2. Suma APYs de todas las estrategias: `total_apy`
3. Si `total_apy == 0`: distribuye equitativamente (`BASIS_POINTS / strategies.length`)
4. Para cada estrategia:
   - Calcula target sin caps: `uncapped = (apy * BASIS_POINTS) / total_apy`
   - Aplica límites:
     - Si `uncapped > max_allocation`: target = max (50%)
     - Si `uncapped < min_threshold`: target = 0 (10%)
     - Sino: target = uncapped
5. Normaliza para que sumen 10000:
   - Suma todos los targets
   - Si no suma 10000: `target[i] = (target[i] * BASIS_POINTS) / total_targets`
6. Retorna array de targets

**Usado por**: `_calculateTargetAllocation()` (escribe a storage), `shouldRebalance()` no lo usa directamente (compara APYs)

---

#### _calculateTargetAllocation()

Calcula targets y escribe a storage.

**Flujo:**
1. Si no hay estrategias: retorna
2. Llama `_computeTargets()` para obtener array de targets
3. Escribe a storage: `target_allocation[strategies[i]] = computed[i]`
4. Emite `TargetAllocationUpdated()`

---

### Inicialización

```solidity
// Constructor: recibe asset y TierConfig
constructor(address _asset, TierConfig memory tier_config)
    // tier_config.max_allocation_per_strategy: 5000 (Balanced) / 7000 (Aggressive)
    // tier_config.min_allocation_threshold: 2000 (Balanced) / 1000 (Aggressive)
    // tier_config.rebalance_threshold: 200 (Balanced) / 300 (Aggressive)
    // tier_config.min_tvl_for_rebalance: 8 ETH (Balanced) / 12 ETH (Aggressive)

// initialize: resuelve dependencia circular vault ↔ manager
function initialize(address _vault) external onlyOwner
    // Solo se puede llamar una vez (revierte si vault != address(0))
```

### Funciones de Consulta

```solidity
function totalAssets() public view returns (uint256)
    // Suma de assets en todas las estrategias

function strategiesCount() external view returns (uint256)
    // Número de estrategias disponibles

function getAllStrategiesInfo() external view returns (
    string[] memory names,
    uint256[] memory apys,
    uint256[] memory tvls,
    uint256[] memory targets
)
    // Información completa de todas las estrategias
    // ⚠️ Gas intensive (~1M gas), solo para off-chain queries
```

### Setters Administrativos

```solidity
function setRebalanceThreshold(uint256 new_threshold) external onlyOwner
function setMinTVLForRebalance(uint256 new_min_tvl) external onlyOwner
function setMaxAllocationPerStrategy(uint256 new_max) external onlyOwner
    // Recalcula targets después
function setMinAllocationThreshold(uint256 new_min) external onlyOwner
    // Recalcula targets después
```

### Eventos Importantes

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

### Modificadores

```solidity
modifier onlyVault() {
    if (msg.sender != vault) revert StrategyManager__OnlyVault();
    _;
}
```

### Errores Custom

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

## LidoStrategy.sol

**Ubicación**: `src/strategies/LidoStrategy.sol`

### Propósito

Staking líquido con auto-compounding via wstETH. Deposita WETH en Lido para obtener stETH y lo wrappea en wstETH. El yield crece automáticamente en el tipo de cambio wstETH/stETH sin necesidad de harvest activo. APY estimado: **4% (400 bp)**.

### Tier

Disponible en: **Balanced**

### Implementa

- `IStrategy`: Interfaz estándar de estrategias

### Llamado Por

- **StrategyManager**: `deposit()`, `withdraw()`, `harvest()`, `totalAssets()`, `apy()`

### Llama A

- **IWETH**: `withdraw()` — unwrap WETH a ETH para enviar a Lido
- **ILido**: `receive()` — envía ETH, recibe stETH (submit via `receive()`)
- **IWstETH**: `wrap(stETH)` — convierte stETH a wstETH; `getStETHByWstETH()` — precio actual
- **ISwapRouter (Uniswap V3)**: `exactInputSingle()` — swap wstETH → WETH durante withdraw

### Variables de Estado

```solidity
// Inmutables
address public immutable manager;            // StrategyManager autorizado
address private immutable asset_address;     // WETH
address private immutable wsteth;            // wstETH token
address private immutable lido;              // Lido stETH contract
ISwapRouter private immutable swap_router;   // Uniswap V3 Router

// APY hardcodeado
uint256 private constant LIDO_APY = 400;     // 4% (400 bp)
```

### Funciones Principales

#### deposit(uint256 assets) → uint256 shares

Convierte WETH a wstETH vía Lido y lo retiene.

**Precondición**: WETH debe estar en la estrategia (transferido por manager).

**Flujo:**
1. `IWETH(asset_address).withdraw(assets)` — unwrap WETH a ETH
2. `ILido(lido).receive{value: assets}()` — submit ETH a Lido → recibe stETH
3. `IWstETH(wsteth).wrap(steth_balance)` — convierte stETH a wstETH
4. Emite `Deposited(msg.sender, assets, shares)`

**Modificadores**: `onlyManager`

---

#### withdraw(uint256 assets) → uint256 actual_withdrawn

Swap wstETH → WETH via Uniswap V3 y transfiere al manager.

**Flujo:**
1. Calcula `wsteth_to_sell`: proporción de wstETH correspondiente a `assets` WETH
2. Swap: `uniswap_router.exactInputSingle(wstETH → WETH, 0.05% fee, 99% min out)`
3. Transfiere WETH al manager
4. Emite `Withdrawn(msg.sender, actual_withdrawn, assets)`

**Modificadores**: `onlyManager`

**Nota**: El swap se realiza en el pool wstETH/WETH 0.05% de Uniswap V3. Se aplica 1% máximo de slippage.

---

#### harvest() → uint256 profit

**Siempre retorna 0.** El yield de Lido es auto-compuesto en el tipo de cambio wstETH/stETH. No hay rewards externos que claimear.

**Modificadores**: `onlyManager`

---

#### totalAssets() → uint256

Valor WETH-equivalente de todo el wstETH en custodia.

```solidity
function totalAssets() external view returns (uint256) {
    uint256 wst_balance = wstEthBalance();
    return IWstETH(wsteth).getStETHByWstETH(wst_balance);
    // getStETHByWstETH convierte wstETH a stETH usando el tipo de cambio actual
    // stETH ≈ ETH ≈ WETH (peg razonablemente estable)
}
```

**Nota**: El valor crece automáticamente con el tiempo a medida que el tipo de cambio wstETH/stETH aumenta con los rewards del staking.

---

#### apy() → uint256

Retorna APY hardcodeado: 400 bp (4%).

---

### Funciones de Utilidad

```solidity
function wstEthBalance() public view returns (uint256)
    // Balance de wstETH de la estrategia
```

### Errores Custom

```solidity
error LidoStrategy__OnlyManager();
error LidoStrategy__ZeroAmount();
error LidoStrategy__DepositFailed();
error LidoStrategy__SwapFailed();
```

---

## AaveStrategy (wstETH).sol

**Ubicación**: `src/strategies/AaveStrategy.sol`

### Propósito

Doble yield — deposita wstETH en Aave v3 obteniendo Lido staking yield (~4%) + Aave lending yield (~3.5%) simultáneamente. Incluye harvest de rewards AAVE con swap automático a WETH y reinversión como wstETH (auto-compound). APY: **dinámico** (lee Aave liquidity rate on-chain).

### Tier

Disponible en: **Balanced**

### Implementa

- `IStrategy`: Interfaz estándar de estrategias

### Llamado Por

- **StrategyManager**: `deposit()`, `withdraw()`, `harvest()`, `totalAssets()`, `apy()`

### Llama A

- **IWETH**: `withdraw()` — unwrap WETH a ETH
- **ILido**: `receive()` — ETH → stETH
- **IWstETH**: `wrap()` / `unwrap()` — stETH ↔ wstETH
- **IPool (Aave v3)**: `supply(wstETH)`, `withdraw(wstETH)`, `getReserveData(wstETH)`
- **IRewardsController (Aave)**: `claimAllRewards([aWstETH])` — claimea AAVE tokens
- **ISwapRouter (Uniswap V3)**: `exactInputSingle()` — swap AAVE → WETH (harvest), swap stETH → ETH via Curve (withdraw)
- **ICurvePool**: `exchange(stETH, ETH)` — durante withdraw para convertir stETH a ETH

### Variables de Estado

```solidity
// Inmutables
address public immutable manager;                    // StrategyManager autorizado
IPool private immutable aave_pool;                   // Aave v3 Pool
IRewardsController private immutable rewards_controller; // Aave rewards controller
address private immutable asset_address;             // WETH
address private immutable a_wst_eth;                 // aWstETH (rebasing token Aave)
address private immutable wst_eth;                   // wstETH token
address private immutable lido;                      // Lido stETH contract
address private immutable st_eth;                    // stETH token
address private immutable reward_token;              // AAVE governance token
ISwapRouter private immutable uniswap_router;        // Uniswap V3 Router
ICurvePool private immutable curve_pool;             // Curve stETH/ETH pool (para withdraw)
uint24 private immutable pool_fee;                   // 3000 (0.3%)
```

### Funciones Principales

#### deposit(uint256 assets) → uint256 shares

WETH → ETH → stETH → wstETH → Aave supply.

**Precondición**: WETH debe estar en la estrategia (transferido por manager).

**Flujo:**
1. `IWETH.withdraw(assets)` — unwrap a ETH
2. `ILido.receive{value: assets}()` — ETH → stETH
3. `IWstETH.wrap(steth_balance)` — stETH → wstETH
4. `aave_pool.supply(wst_eth, wsteth_balance, address(this), 0)` — wstETH → aWstETH
5. Emite `Deposited(msg.sender, assets, shares)`

**Modificadores**: `onlyManager`

---

#### withdraw(uint256 assets) → uint256 actual_withdrawn

aWstETH → wstETH → stETH → ETH (Curve) → WETH.

**Flujo:**
1. Calcula `wsteth_to_withdraw` proporcional a `assets`
2. `aave_pool.withdraw(wst_eth, wsteth_to_withdraw, address(this))` — aWstETH → wstETH
3. `IWstETH.unwrap(wsteth_received)` — wstETH → stETH
4. `curve_pool.exchange(1, 0, steth_amount, min_eth_out)` — stETH → ETH (índice 1→0)
5. `IWETH.deposit{value: eth_received}()` — ETH → WETH
6. Transfiere WETH al manager
7. Emite `Withdrawn(msg.sender, actual_withdrawn, assets)`

**Modificadores**: `onlyManager`

---

#### harvest() → uint256 profit

Claimea AAVE rewards → swap WETH → reinvierte como wstETH en Aave.

**Flujo:**
1. `rewards_controller.claimAllRewards([a_wst_eth])` → recibe AAVE tokens
2. Si no hay rewards → return 0
3. Swap: `uniswap_router.exactInputSingle(AAVE → WETH, 0.3% fee, 1% max slippage)`
4. `IWETH.withdraw(weth_received)` → ETH → stETH → wstETH → `aave_pool.supply(wstETH)` [auto-compound]
5. Return `profit = weth_received`
6. Emite `Harvested(msg.sender, profit)`

**Modificadores**: `onlyManager`

---

#### totalAssets() → uint256

Valor en WETH del aWstETH en custodia usando tipo de cambio wstETH actual.

```solidity
function totalAssets() external view returns (uint256) {
    uint256 a_wst_eth_balance = IERC20(a_wst_eth).balanceOf(address(this));
    return IWstETH(wst_eth).getStETHByWstETH(a_wst_eth_balance);
    // aWstETH hace rebase automático; getStETHByWstETH convierte al tipo de cambio actual
}
```

---

#### apy() → uint256

APY dinámico de Aave para wstETH. Lee `liquidityRate` on-chain.

**Flujo:**
1. `aave_pool.getReserveData(wst_eth)` → `DataTypes.ReserveData`
2. Extrae `liquidityRate` (en RAY = 1e27)
3. Convierte: `apy = liquidityRate / 1e23` (RAY → basis points)

**Ejemplo:**
```solidity
// liquidityRate wstETH = 35000000000000000000000000 (RAY) ≈ 3.5%
// apy = 35000000000000000000000000 / 1e23 = 350 basis points
// (No incluye el Lido staking yield — ese se contabiliza vía tipo de cambio)
```

---

### Funciones de Utilidad

```solidity
function availableLiquidity() external view returns (uint256)
    // Liquidez disponible en Aave v3 para wstETH withdraws

function aTokenBalance() external view returns (uint256)
    // Balance de aWstETH de la estrategia

function pendingRewards() external view returns (uint256)
    // Rewards AAVE pendientes de claimear
```

### Errores Custom

```solidity
error AaveStrategy__DepositFailed();
error AaveStrategy__WithdrawFailed();
error AaveStrategy__OnlyManager();
error AaveStrategy__HarvestFailed();
error AaveStrategy__SwapFailed();
error AaveStrategy__ZeroAmount();
```

---

## CurveStrategy.sol

**Ubicación**: `src/strategies/CurveStrategy.sol`

### Propósito

Provisión de liquidez en el pool stETH/ETH de Curve y staking de LP tokens en el gauge para acumular rewards CRV. Genera yield de dos fuentes: trading fees del pool (~1-2%) + rewards CRV del gauge (~4%). APY estimado: **6% (600 bp)**.

### Tier

Disponible en: **Balanced** y **Aggressive**

### Implementa

- `IStrategy`: Interfaz estándar de estrategias

### Llamado Por

- **StrategyManager**: `deposit()`, `withdraw()`, `harvest()`, `totalAssets()`, `apy()`

### Llama A

- **IWETH**: `withdraw()` — unwrap WETH a ETH
- **ILido**: `receive()` — ETH → stETH (durante depósito, para balancear el par)
- **ICurvePool**: `add_liquidity([eth, steth])`, `remove_liquidity_one_coin(lp, 0)`, `get_virtual_price()`
- **ICurveGauge**: `deposit(LP)`, `withdraw(LP)`, `claim_rewards()`, `balanceOf()`
- **ISwapRouter (Uniswap V3)**: `exactInputSingle(CRV → WETH, 0.3% fee)` — durante harvest

### Variables de Estado

```solidity
// Inmutables
address public immutable manager;            // StrategyManager autorizado
address private immutable asset_address;     // WETH
ICurvePool private immutable pool;           // Curve stETH/ETH pool
ICurveGauge private immutable gauge;         // Curve gauge (staking de LP)
address private immutable lp_token;          // LP token del pool
address private immutable lido;              // Lido stETH contract
address private immutable crv_token;         // CRV governance token
ISwapRouter private immutable swap_router;   // Uniswap V3 Router

// APY hardcodeado
uint256 private constant CURVE_APY = 600;    // 6% (600 bp)
```

### Funciones Principales

#### deposit(uint256 assets) → uint256 shares

WETH → ETH → stETH → add_liquidity → LP → gauge stake.

**Precondición**: WETH debe estar en la estrategia (transferido por manager).

**Flujo:**
1. `IWETH.withdraw(assets)` — unwrap WETH a ETH
2. Divide ETH en dos mitades: 50% se envía a Lido, 50% se usa como ETH directo
3. `ILido.receive{value: half}()` — ETH → stETH
4. `pool.add_liquidity([eth_half, steth_received], min_lp_out)` — ETH + stETH → LP tokens
5. `gauge.deposit(lp_balance)` — stakea LP en gauge
6. Emite `Deposited(msg.sender, assets, shares)`

**Modificadores**: `onlyManager`

---

#### withdraw(uint256 assets) → uint256 actual_withdrawn

gauge.withdraw → remove_liquidity_one_coin → ETH → WETH.

**Flujo:**
1. Calcula `lp_to_withdraw` proporcional a `assets` / `totalAssets()`
2. `gauge.withdraw(lp_to_withdraw)` — desestakea LP del gauge
3. `pool.remove_liquidity_one_coin(lp_to_withdraw, 0, min_eth_out)` — LP → ETH (índice 0)
4. `IWETH.deposit{value: eth_received}()` — ETH → WETH
5. Transfiere WETH al manager
6. Emite `Withdrawn(msg.sender, actual_withdrawn, assets)`

**Modificadores**: `onlyManager`

---

#### harvest() → uint256 profit

Claimea CRV rewards → swap WETH → reinvierte como LP.

**Flujo:**
1. `gauge.claim_rewards()` → recibe CRV tokens
2. Si balance CRV == 0 → return 0
3. Swap: `uniswap_router.exactInputSingle(CRV → WETH, 0.3% fee, sin min_out)`
4. Registra `profit = weth_received`
5. Reinvierte: ETH + stETH → `pool.add_liquidity` → `gauge.deposit` [auto-compound]
6. Emite `Harvested(msg.sender, profit)`

**Modificadores**: `onlyManager`

---

#### totalAssets() → uint256

Valor WETH de los LP tokens stakeados usando virtual price del pool.

```solidity
function totalAssets() external view returns (uint256) {
    uint256 lp = ICurveGauge(gauge).balanceOf(address(this));
    return FullMath.mulDiv(lp, ICurvePool(pool).get_virtual_price(), 1e18);
    // virtual_price crece con el tiempo reflejando trading fees acumulados
    // Expresado en ETH equivalente (1e18 = 1 ETH por LP)
}
```

---

#### apy() → uint256

Retorna APY hardcodeado: 600 bp (6%).

---

### Funciones de Utilidad

```solidity
function lpBalance() public view returns (uint256)
    // Balance de LP tokens stakeados en el gauge
```

### Errores Custom

```solidity
error CurveStrategy__OnlyManager();
error CurveStrategy__ZeroAmount();
error CurveStrategy__DepositFailed();
error CurveStrategy__WithdrawFailed();
error CurveStrategy__SwapFailed();
```

---

## UniswapV3Strategy.sol

**Ubicación**: `src/strategies/UniswapV3Strategy.sol`

### Propósito

Provisión de liquidez concentrada en el pool WETH/USDC 0.05% de Uniswap V3 para capturar trading fees. Mantiene una posición NFT única con rango fijo de ±960 ticks (≈ ±10% del precio actual en el momento del deploy). APY estimado: **14% (1400 bp)**, altamente variable según volumen del pool.

### Tier

Disponible en: **Aggressive**

### Implementa

- `IStrategy`: Interfaz estándar de estrategias

### Llamado Por

- **StrategyManager**: `deposit()`, `withdraw()`, `harvest()`, `totalAssets()`, `apy()`

### Llama A

- **INonfungiblePositionManager**: `mint()`, `increaseLiquidity()`, `decreaseLiquidity()`, `collect()`, `burn()`, `positions()`
- **ISwapRouter**: `exactInputSingle(WETH ↔ USDC, 0.05% fee)` — para balancear el par en cada operación
- **IUniswapV3Pool**: `slot0()` — lee precio actual (sqrtPriceX96) para calcular valor de la posición

### Variables de Estado

```solidity
// Inmutables (calculados en constructor)
address public immutable manager;                    // StrategyManager autorizado
address private immutable asset_address;             // WETH
INonfungiblePositionManager private immutable position_manager;
ISwapRouter private immutable swap_router;
IUniswapV3Pool private immutable pool;               // WETH/USDC 0.05% pool
address private immutable weth;
address private immutable usdc;                      // 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
address private immutable token0;                    // El menor en dirección (USDC en WETH/USDC)
address private immutable token1;                    // El mayor en dirección (WETH en WETH/USDC)
bool private immutable weth_is_token0;               // false en WETH/USDC (USDC < WETH en addr)
int24 public immutable lower_tick;                   // tick_actual - 960
int24 public immutable upper_tick;                   // tick_actual + 960

// Estado mutable
uint256 public token_id;                             // ID del NFT activo (0 = sin posición)

// Constantes
uint24 private constant POOL_FEE = 500;              // 0.05% fee tier del pool
int24 private constant TICK_SPACING = 10;            // Tick spacing del pool 0.05%
int24 private constant TICK_RANGE = 960;             // ±960 ticks ≈ ±10% de precio
uint256 private constant UNISWAP_V3_APY = 1400;     // 14% (estimado histórico)
```

**Addresses mainnet:**
- Pool WETH/USDC 0.05%: `0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640`
- NonfungiblePositionManager: `0xC36442b4a4522E871399CD717aBDD847Ab11FE88`
- SwapRouter: `0xE592427A0AEce92De3Edee1F18E0157C05861564`
- USDC: `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`

### Funciones Principales

#### deposit(uint256 assets) → uint256 shares

WETH → swap 50% a USDC → mint/increaseLiquidity NFT.

**Precondición**: WETH debe estar en la estrategia (transferido por manager).

**Flujo:**
1. Swap 50% del WETH a USDC: `exactInputSingle(WETH → USDC, 0.05% fee)`
2. Si `token_id == 0` (primera vez):
   - `position_manager.mint(token0, token1, 500, lower_tick, upper_tick, amounts...)` → guarda `token_id`
3. Si `token_id > 0` (posición existente):
   - `position_manager.increaseLiquidity(token_id, amounts...)`
4. Emite `Deposited(msg.sender, assets, assets)`

**Modificadores**: `onlyManager`

---

#### withdraw(uint256 assets) → uint256 actual_withdrawn

decreaseLiquidity → collect → swap USDC → WETH → si vacío, burn NFT.

**Flujo:**
1. Obtiene `total_liquidity` de la posición via `positions(token_id)`
2. Calcula `liquidity_to_remove` proporcional: `total_liquidity * assets / _totalAssets()`
3. `position_manager.decreaseLiquidity(token_id, liquidity_to_remove, ...)` — tokens pasan a "owed"
4. `position_manager.collect(token_id, max_amounts)` → recibe WETH + USDC
5. Si `remaining_liquidity == 0`: `position_manager.burn(token_id)`, `token_id = 0`
6. Swap USDC → WETH: `exactInputSingle(USDC → WETH, 0.05% fee)`
7. Transfiere todo el WETH al manager
8. Emite `Withdrawn(msg.sender, actual_withdrawn, assets)`

**Modificadores**: `onlyManager`

---

#### harvest() → uint256 profit

collect fees (WETH+USDC) → swap USDC → WETH → registra profit → reinvierte.

**Flujo:**
1. Si `token_id == 0` → return 0 (sin posición activa)
2. `position_manager.collect(token_id, max_amounts)` → recoge fees acumulados (WETH + USDC)
3. Si collected == 0 → return 0
4. Swap `USDC → WETH`: `exactInputSingle(USDC → WETH, 0.05% fee)` → todo en WETH
5. Registra `profit = total_weth`
6. Reinvierte: swap 50% WETH → USDC → `position_manager.increaseLiquidity(token_id, ...)`
7. Emite `Harvested(msg.sender, profit)`

**Modificadores**: `onlyManager`

---

#### totalAssets() → uint256

Calcula valor WETH de la posición NFT usando precio actual del pool.

**Internamente (_totalAssets):**
1. Si `token_id == 0` → return 0
2. Obtiene `liquidity`, `tokens_owed0`, `tokens_owed1` de `positions(token_id)`
3. Lee `sqrtPriceX96` de `pool.slot0()`
4. Usa `LiquidityAmounts.getAmountsForLiquidity()` para convertir liquidez a amount0/amount1
5. Suma fees pendientes (`tokens_owed0`, `tokens_owed1`)
6. Convierte USDC a WETH usando `sqrtPriceX96` y `FullMath.mulDiv()` para evitar overflow
7. Retorna `weth_amount + weth_from_usdc`

**Nota**: Las bibliotecas `TickMath`, `LiquidityAmounts` y `FullMath` son ports de las librerías de Uniswap V3 usadas internamente por el protocolo.

---

#### apy() → uint256

Retorna APY hardcodeado: 1400 bp (14%). Altamente variable según volumen del pool WETH/USDC.

---

### Errores Custom

```solidity
error UniswapV3Strategy__OnlyManager();
error UniswapV3Strategy__ZeroAmount();
error UniswapV3Strategy__MintFailed();
error UniswapV3Strategy__SwapFailed();
error UniswapV3Strategy__InsufficientLiquidity();
```

---

## IStrategy.sol

**Ubicación**: `src/interfaces/core/IStrategy.sol`

### Propósito

Interfaz estándar que todas las estrategias deben implementar para permitir que StrategyManager las trate de forma uniforme.

### Funciones Requeridas

```solidity
function deposit(uint256 assets) external returns (uint256 shares);
function withdraw(uint256 assets) external returns (uint256 actual_withdrawn);
function harvest() external returns (uint256 profit);
function totalAssets() external view returns (uint256 total);
function apy() external view returns (uint256 apy_basis_points);
function name() external view returns (string memory strategy_name);
function asset() external view returns (address asset_address);
```

### Eventos

```solidity
event Deposited(address indexed caller, uint256 assets, uint256 shares);
event Withdrawn(address indexed caller, uint256 assets, uint256 shares);
event Harvested(address indexed caller, uint256 profit);
```

### Nota Importante

La interfaz incluye `harvest()` como función requerida — todas las estrategias de VynX V2 implementan este método. En LidoStrategy, `harvest()` retorna siempre 0 (el yield es auto-compuesto). El `actual_withdrawn` en `withdraw()` permite contabilizar el rounding de protocolos externos.

---

## Router.sol

**Ubicación**: `src/periphery/Router.sol`

### Propósito

Contrato periférico stateless que permite depositar y retirar del Vault usando ETH nativo o cualquier token ERC20 con pool de Uniswap V3. Actúa como punto de entrada multi-token sin requerir que el usuario tenga WETH previamente.

### Herencia

- `IRouter`: Interfaz del Router (eventos y funciones)
- `ReentrancyGuard` (OpenZeppelin): Protección contra reentrancy en todas las funciones públicas

### Llamado Por

- **Usuarios (EOAs/contratos)**: `zapDepositETH()`, `zapDepositERC20()`, `zapWithdrawETH()`, `zapWithdrawERC20()`

### Llama A

- **IERC4626(vault)**: `deposit()`, `redeem()`
- **ISwapRouter(uniswap)**: `exactInputSingle()` para swaps ERC20 ↔ WETH
- **WETH**: `deposit()` (wrap), `withdraw()` (unwrap) via low-level calls

### Variables de Estado

```solidity
// Inmutables (establecidas en constructor)
address public immutable weth;         // Dirección del token WETH
address public immutable vault;        // Dirección del Vault VynX (ERC4626)
address public immutable swap_router;  // Dirección del Uniswap V3 SwapRouter
```

### Constructor

```solidity
constructor(address _weth, address _vault, address _swap_router)
```

**Flujo:**
1. Valida que ninguna dirección sea `address(0)` (revierte con `Router__ZeroAddress`)
2. Establece las 3 variables inmutables
3. Aprueba al vault transfer de WETH ilimitado: `IERC20(weth).forceApprove(vault, type(uint256).max)`

### Funciones Principales

#### zapDepositETH() payable → uint256 shares

Deposita ETH nativo en el vault (wrap → deposit).

**Flujo:**
1. Verifica `msg.value > 0`
2. Wrappea ETH a WETH: `_wrapETH(msg.value)`
3. Deposita WETH en vault: `vault.deposit(msg.value, msg.sender)` → shares al usuario
4. Verifica stateless: `balanceOf(this) == 0`
5. Emite `ZapDeposit(msg.sender, address(0), msg.value, msg.value, shares)`

#### zapDepositERC20(token_in, amount_in, pool_fee, min_weth_out) → uint256 shares

Deposita ERC20 en el vault (swap → deposit).

**Flujo:**
1. Valida: `token_in != address(0)`, `token_in != weth`, `amount_in > 0`
2. Transfiere `token_in` del usuario al Router
3. Swapea `token_in → WETH`: `_swapToWETH(token_in, amount_in, pool_fee, min_weth_out)`
4. Deposita WETH en vault → shares al usuario
5. Verifica stateless
6. Emite `ZapDeposit(msg.sender, token_in, amount_in, weth_out, shares)`

#### zapWithdrawETH(shares) → uint256 eth_out

Retira shares del vault y recibe ETH nativo (redeem → unwrap).

**Flujo:**
1. Valida `shares > 0`
2. Transfiere shares del usuario al Router (requiere aprobación previa)
3. Redime shares: `vault.redeem(shares, address(this), address(this))` → WETH al Router
4. Unwrappea WETH a ETH: `_unwrapWETH(weth_redeemed)`
5. Transfiere ETH al usuario via low-level call
6. Verifica stateless
7. Emite `ZapWithdraw(msg.sender, shares, weth_redeemed, address(0), eth_out)`

#### zapWithdrawERC20(shares, token_out, pool_fee, min_token_out) → uint256 amount_out

Retira shares del vault y recibe ERC20 (redeem → swap).

**Flujo:**
1. Valida: `token_out != address(0)`, `token_out != weth`, `shares > 0`
2. Transfiere shares del usuario al Router
3. Redime shares → WETH al Router
4. Swapea `WETH → token_out`: `_swapFromWETH(weth_redeemed, token_out, pool_fee, min_token_out)`
5. Transfiere `token_out` al usuario
6. Verifica stateless (balance de `token_out` == 0)
7. Emite `ZapWithdraw(msg.sender, shares, weth_redeemed, token_out, amount_out)`

### Funciones Internas

#### _wrapETH(uint256 amount)

```solidity
(bool success,) = weth.call{value: amount}(abi.encodeWithSignature("deposit()"));
if (!success) revert Router__ETHWrapFailed();
```

#### _unwrapWETH(uint256 amount) → uint256 eth_out

```solidity
(bool success,) = weth.call(abi.encodeWithSignature("withdraw(uint256)", amount));
if (!success) revert Router__ETHUnwrapFailed();
return amount;
```

#### _swapToWETH(token_in, amount_in, pool_fee, min_weth_out) → uint256 weth_out

```solidity
IERC20(token_in).forceApprove(swap_router, amount_in);
weth_out = ISwapRouter(swap_router).exactInputSingle({
    tokenIn: token_in,
    tokenOut: weth,
    fee: pool_fee,
    recipient: address(this),
    deadline: block.timestamp,
    amountIn: amount_in,
    amountOutMinimum: min_weth_out,
    sqrtPriceLimitX96: 0
});
if (weth_out < min_weth_out) revert Router__SlippageExceeded();
```

#### _swapFromWETH(weth_in, token_out, pool_fee, min_token_out) → uint256 amount_out

Similar a `_swapToWETH` pero invirtiendo tokenIn/tokenOut.

### Función receive()

```solidity
receive() external payable {
    if (msg.sender != weth) revert Router__UnauthorizedETHSender();
}
```

**Propósito**: Solo acepta ETH del contrato WETH (durante unwrap). Previene envíos accidentales de ETH.

### Eventos

Heredados de `IRouter`:

```solidity
event ZapDeposit(
    address indexed user,
    address indexed token_in,  // address(0) si es ETH
    uint256 amount_in,
    uint256 weth_out,
    uint256 shares_out
);

event ZapWithdraw(
    address indexed user,
    uint256 shares_in,
    uint256 weth_redeemed,
    address indexed token_out,  // address(0) si es ETH
    uint256 amount_out
);
```

### Errores Custom

```solidity
error Router__ZeroAddress();
error Router__ZeroAmount();
error Router__SlippageExceeded();
error Router__ETHWrapFailed();
error Router__FundsStuck();
error Router__UseVaultForWETH();
error Router__UnauthorizedETHSender();
error Router__ETHUnwrapFailed();
```

---

## IRouter.sol

**Ubicación**: `src/interfaces/periphery/IRouter.sol`

### Propósito

Interfaz estándar del Router que define eventos y funciones públicas. Cualquier implementación del Router debe cumplir esta interfaz.

### Eventos

```solidity
event ZapDeposit(
    address indexed user,
    address indexed token_in,
    uint256 amount_in,
    uint256 weth_out,
    uint256 shares_out
);

event ZapWithdraw(
    address indexed user,
    uint256 shares_in,
    uint256 weth_redeemed,
    address indexed token_out,
    uint256 amount_out
);
```

### Funciones Requeridas

```solidity
function weth() external view returns (address);
function vault() external view returns (address);
function swap_router() external view returns (address);

function zapDepositETH() external payable returns (uint256 shares);
function zapDepositERC20(address token_in, uint256 amount_in, uint24 pool_fee, uint256 min_weth_out)
    external returns (uint256 shares);
function zapWithdrawETH(uint256 shares) external returns (uint256 eth_out);
function zapWithdrawERC20(uint256 shares, address token_out, uint24 pool_fee, uint256 min_token_out)
    external returns (uint256 amount_out);
```

---

**Siguiente lectura**: [FLOWS.md](FLOWS.md) — Flujos de usuario paso a paso con las 4 estrategias V2
