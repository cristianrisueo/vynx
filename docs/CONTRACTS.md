# Documentación de Contratos

Este documento proporciona documentación técnica detallada de cada contrato del protocolo VynX V1, incluyendo variables de estado, funciones principales, eventos y modificadores.

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
mapping(address => bool) public isOfficialKeeper;    // Keepers oficiales (sin incentivo)

// Direcciones de fee recipients
address public treasury_address;                      // Recibe 80% perf fee en SHARES
address public founder_address;                       // Recibe 20% perf fee en WETH

// Estado del idle buffer
uint256 public idle_buffer;                           // WETH acumulado pendiente de invertir

// Contadores de harvest
uint256 public last_harvest;                          // Timestamp del último harvest
uint256 public total_harvested;                       // Profit bruto total acumulado

// Parámetros de harvest
uint256 public min_profit_for_harvest = 0.1 ether;   // Profit mínimo para ejecutar harvest
uint256 public keeper_incentive = 100;                // 1% (100 bp) del profit para keepers ext.

// Parámetros de fees
uint256 public performance_fee = 2000;                // 20% (2000 bp) sobre profits
uint256 public treasury_split = 8000;                 // 80% del perf fee → treasury (shares)
uint256 public founder_split = 2000;                  // 20% del perf fee → founder (WETH)

// Circuit breakers
uint256 public min_deposit = 0.01 ether;              // Anti-spam, anti-rounding
uint256 public idle_threshold = 10 ether;             // Threshold para auto-allocate
uint256 public max_tvl = 1000 ether;                  // TVL máximo permitido
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
7. Si `idle_buffer >= idle_threshold` (10 ETH), auto-ejecuta `_allocateIdle()`

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

**Nota sobre rounding**: Protocolos externos (Aave, Compound) redondean a la baja ~1-2 wei por operación. El vault tolera hasta 20 wei de diferencia (margen para ~10 estrategias futuras). Si la diferencia excede 20 wei, revierte con "Excessive rounding" (problema de accounting serio).

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
2. Si `profit < min_profit_for_harvest` (0.1 ETH) → return 0 (no distribuye)
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
event Harvested(uint256 profit, uint256 performanceFee, uint256 timestamp);
event PerformanceFeeDistributed(uint256 treasuryAmount, uint256 founderAmount);
event IdleAllocated(uint256 amount);
event StrategyManagerUpdated(address indexed newManager);
event PerformanceFeeUpdated(uint256 oldFee, uint256 newFee);
event FeeSplitUpdated(uint256 treasurySplit, uint256 founderSplit);
event MinDepositUpdated(uint256 oldMin, uint256 newMin);
event IdleThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
event MaxTVLUpdated(uint256 oldMax, uint256 newMax);
event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
event FounderUpdated(address indexed oldFounder, address indexed newFounder);
event OfficialKeeperUpdated(address indexed keeper, bool status);
event MinProfitForHarvestUpdated(uint256 oldMin, uint256 newMin);
event KeeperIncentiveUpdated(uint256 oldIncentive, uint256 newIncentive);
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
mapping(IStrategy => uint256) public targetAllocation;       // En basis points

// Parámetros de allocation
uint256 public max_allocation_per_strategy = 5000;           // 50%
uint256 public min_allocation_threshold = 1000;              // 10%

// Parámetros de rebalancing
uint256 public rebalance_threshold = 200;                    // 2% diferencia de APY
uint256 public min_tvl_for_rebalance = 10 ether;
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
   - Escribe targets al storage: `targetAllocation[strategy] = target`
3. Para cada estrategia con `target > 0`:
   - Calcula `amount = (assets * target) / BASIS_POINTS`
   - Transfiere `amount` WETH a la estrategia
   - Llama `strategy.deposit(amount)`
   - Emite `Allocated(strategy, amount)`

**Modificadores**: `onlyVault`

**Eventos**: `Allocated(strategy, assets)` por cada estrategia

**Ejemplo:**
```solidity
// Si recibe 100 WETH y targets son [5000, 5000] (50%, 50%):
// - AaveStrategy recibe 50 WETH
// - CompoundStrategy recibe 50 WETH
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
   - Llama `strategy.withdraw(to_withdraw)` → captura `actualWithdrawn`
   - Acumula `total_withdrawn += actualWithdrawn`
5. Transfiere `total_withdrawn` WETH del manager al receiver

**Modificadores**: `onlyVault`

**Nota**: Retira proporcionalmente para mantener ratios. NO recalcula target allocation (ahorro de gas). Usa `actualWithdrawn` para contabilizar rounding de protocolos externos.

**Ejemplo:**
```solidity
// Estado: Aave 70 WETH, Compound 30 WETH (total 100 WETH)
// Usuario retira 50 WETH
// - De Aave: 50 * 70/100 = 35 WETH (real: ~34.999999999999999998)
// - De Compound: 50 * 30/100 = 15 WETH (real: ~14.999999999999999999)
// Resultado: Aave 35 WETH, Compound 15 WETH (mantiene ratio 70/30)
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

**Nota**: El fail-safe es crítico — si Aave harvest falla por falta de rewards, Compound harvest continúa normalmente.

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

**Ejemplo:**
```solidity
// Estado actual: Aave 70 WETH (3.5% APY), Compound 30 WETH (6% APY)
// Targets: Aave ~37% (37 WETH), Compound ~63% (63 WETH)
// Rebalance:
//   1. Retira 33 WETH de Aave
//   2. Deposita 33 WETH en Compound
// Estado final: Aave 37 WETH, Compound 63 WETH
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

**Ejemplo de cálculo:**
```solidity
// Aave APY: 3.5% (350 bp), Compound APY: 6% (600 bp)
// Diferencia: 600 - 350 = 250 bp
// Threshold: 200 bp
// 250 >= 200 → ✅ shouldRebalance = true
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
2. Elimina target: `delete targetAllocation[strategies[index]]`
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
3. Escribe a storage: `targetAllocation[strategies[i]] = computed[i]`
4. Emite `TargetAllocationUpdated()`

---

### Inicialización

```solidity
// Constructor: solo recibe asset
constructor(address _asset)

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
event Rebalanced(address indexed fromStrategy, address indexed toStrategy, uint256 assets);
event Harvested(uint256 totalProfit);
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

## AaveStrategy.sol

**Ubicación**: `src/strategies/AaveStrategy.sol`

### Propósito

Integración con Aave v3 para depositar WETH y generar yield mediante lending. Incluye harvest de rewards AAVE con swap automático a WETH via Uniswap V3 y reinversión automática (auto-compound).

### Implementa

- `IStrategy`: Interfaz estándar de estrategias

### Llamado Por

- **StrategyManager**: `deposit()`, `withdraw()`, `harvest()`, `totalAssets()`, `apy()`

### Llama A

- **IPool (Aave v3)**: `supply()`, `withdraw()`, `getReserveData()`
- **IRewardsController (Aave)**: `claimAllRewards()` — claimea AAVE tokens acumulados
- **ISwapRouter (Uniswap V3)**: `exactInputSingle()` — swap AAVE → WETH
- **IERC20(WETH)**: Transferencias con SafeERC20

### Variables de Estado

```solidity
// Constantes
uint256 public constant BASIS_POINTS = 10000;
uint256 public constant MAX_SLIPPAGE_BPS = 100;       // 1% max slippage en swaps

// Inmutables
address public immutable manager;                       // StrategyManager autorizado
IPool private immutable aave_pool;                     // Aave v3 Pool
IRewardsController private immutable rewards_controller;// Aave rewards controller
address private immutable asset_address;               // WETH
IAToken private immutable a_token;                     // aWETH (rebasing token)
address private immutable reward_token;                // AAVE governance token
ISwapRouter private immutable uniswap_router;          // Uniswap V3 Router
uint24 private immutable pool_fee;                     // 3000 (0.3%)
```

### Funciones Principales

#### deposit(uint256 assets) → uint256 shares

Deposita WETH en Aave v3.

**Precondición**: WETH debe estar en la estrategia (transferido por manager).

**Flujo:**
1. Llama `aave_pool.supply(weth, assets, address(this), 0)`
2. Recibe aWETH 1:1 (shares = assets)
3. Emite `Deposited(msg.sender, assets, shares)`

**Modificadores**: `onlyManager`

**Nota**: aWETH hace rebase automático, el balance incrementa con yield.

---

#### withdraw(uint256 assets) → uint256 actualWithdrawn

Retira WETH de Aave v3.

**Flujo:**
1. Llama `aave_pool.withdraw(weth, assets, address(this))`
2. Quema aWETH, recibe WETH (1:1 + yield acumulado)
3. Transfiere WETH al manager: `safeTransfer(msg.sender, actualWithdrawn)`
4. Emite `Withdrawn(msg.sender, actualWithdrawn, assets)`

**Modificadores**: `onlyManager`

---

#### harvest() → uint256 profit

Cosecha rewards AAVE, swap a WETH via Uniswap V3, re-invierte en Aave.

**Flujo:**
1. Construye array con dirección del aToken
2. Llama `rewards_controller.claimAllRewards([aToken])` → recibe AAVE tokens
3. Si no hay rewards → return 0
4. Calcula `min_amount_out = (claimed * (BASIS_POINTS - MAX_SLIPPAGE_BPS)) / BASIS_POINTS`
   - Con MAX_SLIPPAGE_BPS = 100: `min_out = claimed * 9900 / 10000` (1% slippage max)
5. Ejecuta swap via Uniswap V3:
   ```solidity
   uniswap_router.exactInputSingle(
       tokenIn: reward_token,     // AAVE
       tokenOut: asset_address,   // WETH
       fee: pool_fee,             // 3000 (0.3%)
       recipient: address(this),
       amountIn: claimed,
       amountOutMinimum: min_amount_out,
       sqrtPriceLimitX96: 0
   )
   ```
6. Re-supply: `aave_pool.supply(weth, amount_out, address(this), 0)` (auto-compound)
7. Return `profit = amount_out`
8. Emite `Harvested(msg.sender, profit)`

**Modificadores**: `onlyManager`

---

#### totalAssets() → uint256

Balance actual de WETH en Aave (incluye yield).

```solidity
function totalAssets() external view returns (uint256) {
    return a_token.balanceOf(address(this));
}
```

**Nota**: aWETH hace rebase, balance incrementa automáticamente con yield.

---

#### apy() → uint256

APY actual de Aave para WETH.

**Flujo:**
1. Obtiene reserve data: `aave_pool.getReserveData(weth)`
2. Extrae liquidity rate (en RAY = 1e27)
3. Convierte a basis points: `apy = liquidity_rate / 1e23`

**Ejemplo:**
```solidity
// liquidity_rate = 35000000000000000000000000 (RAY)
// apy = 35000000000000000000000000 / 1e23 = 350 basis points = 3.5%
```

---

### Funciones de Utilidad

```solidity
function availableLiquidity() external view returns (uint256)
    // Liquidez disponible en Aave para withdraws

function aTokenBalance() external view returns (uint256)
    // Balance de aWETH de la estrategia

function pendingRewards() external view returns (uint256)
    // Rewards AAVE pendientes de claimear
```

### Modificadores

```solidity
modifier onlyManager() {
    if (msg.sender != manager) revert AaveStrategy__OnlyManager();
    _;
}
```

### Errores Custom

```solidity
error AaveStrategy__DepositFailed();
error AaveStrategy__WithdrawFailed();
error AaveStrategy__OnlyManager();
error AaveStrategy__HarvestFailed();
error AaveStrategy__SwapFailed();
```

---

## CompoundStrategy.sol

**Ubicación**: `src/strategies/CompoundStrategy.sol`

### Propósito

Integración con Compound v3 para depositar WETH y generar yield mediante lending. Incluye harvest de rewards COMP con swap automático a WETH via Uniswap V3 y reinversión automática (auto-compound).

### Implementa

- `IStrategy`: Interfaz estándar de estrategias

### Llamado Por

- **StrategyManager**: `deposit()`, `withdraw()`, `harvest()`, `totalAssets()`, `apy()`

### Llama A

- **ICometMarket (Compound v3)**: `supply()`, `withdraw()`, `balanceOf()`, `getSupplyRate()`, `getUtilization()`
- **ICometRewards (Compound v3)**: `claim()` — claimea COMP tokens acumulados
- **ISwapRouter (Uniswap V3)**: `exactInputSingle()` — swap COMP → WETH
- **IERC20(WETH)**: Transferencias con SafeERC20

### Variables de Estado

```solidity
// Constantes
uint256 public constant BASIS_POINTS = 10000;
uint256 public constant MAX_SLIPPAGE_BPS = 100;       // 1% max slippage en swaps

// Inmutables
address public immutable manager;                       // StrategyManager autorizado
ICometMarket private immutable compound_comet;         // Compound v3 Comet
ICometRewards private immutable compound_rewards;      // Compound rewards controller
address private immutable asset_address;               // WETH
address private immutable reward_token;                // COMP token
ISwapRouter private immutable uniswap_router;          // Uniswap V3 Router
uint24 private immutable pool_fee;                     // 3000 (0.3%)
```

### Funciones Principales

#### deposit(uint256 assets) → uint256 shares

Deposita WETH en Compound v3.

**Precondición**: WETH debe estar en la estrategia (transferido por manager).

**Flujo:**
1. Llama `compound_comet.supply(weth, assets)`
2. Balance interno de Compound incrementa (no hay cToken en v3)
3. Retorna shares = assets (1:1)
4. Emite `Deposited(msg.sender, assets, shares)`

**Modificadores**: `onlyManager`

**Nota**: Compound v3 usa accounting interno (no tokens), balance incrementa con yield.

---

#### withdraw(uint256 assets) → uint256 actualWithdrawn

Retira WETH de Compound v3.

**Flujo:**
1. Captura `balance_before = IERC20(asset).balanceOf(address(this))`
2. Llama `compound_comet.withdraw(weth, assets)`
3. Captura `balance_after = IERC20(asset).balanceOf(address(this))`
4. Calcula `actualWithdrawn = balance_after - balance_before` (captura rounding)
5. Transfiere WETH al manager: `safeTransfer(msg.sender, actualWithdrawn)`
6. Emite `Withdrawn(msg.sender, actualWithdrawn, assets)`

**Modificadores**: `onlyManager`

**Nota**: Usa pattern `balance_before/balance_after` para capturar el monto realmente retirado. Compound puede redondear ~1-2 wei a la baja.

---

#### harvest() → uint256 profit

Cosecha rewards COMP, swap a WETH via Uniswap V3, re-invierte en Compound.

**Flujo:**
1. Llama `compound_rewards.claim(comet, address(this), true)` → recibe COMP tokens
2. Obtiene `reward_amount = IERC20(reward_token).balanceOf(address(this))`
3. Si no hay rewards → return 0
4. Calcula `min_amount_out = (reward_amount * 9900) / 10000` (1% slippage max)
5. Ejecuta swap via Uniswap V3:
   ```solidity
   uniswap_router.exactInputSingle(
       tokenIn: reward_token,     // COMP
       tokenOut: asset_address,   // WETH
       fee: pool_fee,             // 3000 (0.3%)
       recipient: address(this),
       amountIn: reward_amount,
       amountOutMinimum: min_amount_out,
       sqrtPriceLimitX96: 0
   )
   ```
6. Re-supply: `compound_comet.supply(weth, amount_out)` (auto-compound)
7. Return `profit = amount_out`
8. Emite `Harvested(msg.sender, profit)`

**Modificadores**: `onlyManager`

---

#### totalAssets() → uint256

Balance actual de WETH en Compound (incluye yield).

```solidity
function totalAssets() external view returns (uint256) {
    return compound_comet.balanceOf(address(this));
}
```

**Nota**: Balance interno incluye yield acumulado automáticamente.

---

#### apy() → uint256

APY actual de Compound para WETH.

**Flujo:**
1. Obtiene utilization: `utilization = compound_comet.getUtilization()`
2. Obtiene supply rate: `rate = compound_comet.getSupplyRate(utilization)` (uint64, por segundo)
3. Convierte a APY anual en basis points:
   ```solidity
   // rate está en base 1e18 por segundo
   // APY = rate * seconds_per_year * 10000 / 1e18
   // Simplificado: (rate * 315360000000) / 1e18
   apyBasisPoints = (uint256(rate) * 315360000000) / 1e18;
   ```

**Ejemplo:**
```solidity
// supply_rate = 1000000000000000 (1e15 per second)
// APY = (1e15 * 315360000000) / 1e18 = 315 basis points = 3.15%
```

---

### Funciones de Utilidad

```solidity
function getSupplyRate() external view returns (uint256)
    // Supply rate actual de Compound (convertido a uint256)

function getUtilization() external view returns (uint256)
    // Utilization actual del pool (borrowed / supplied)

function pendingRewards() external view returns (uint256)
    // Rewards COMP pendientes de claimear
```

### Modificadores

```solidity
modifier onlyManager() {
    if (msg.sender != manager) revert CompoundStrategy__OnlyManager();
    _;
}
```

### Errores Custom

```solidity
error CompoundStrategy__DepositFailed();
error CompoundStrategy__WithdrawFailed();
error CompoundStrategy__OnlyManager();
error CompoundStrategy__HarvestFailed();
error CompoundStrategy__SwapFailed();
```

---

## IStrategy.sol

**Ubicación**: `src/interfaces/core/IStrategy.sol`

### Propósito

Interfaz estándar que todas las estrategias deben implementar para permitir que StrategyManager las trate de forma uniforme.

### Funciones Requeridas

```solidity
function deposit(uint256 assets) external returns (uint256 shares);
function withdraw(uint256 assets) external returns (uint256 actualWithdrawn);
function harvest() external returns (uint256 profit);
function totalAssets() external view returns (uint256 total);
function apy() external view returns (uint256 apyBasisPoints);
function name() external view returns (string memory strategyName);
function asset() external view returns (address assetAddress);
```

### Eventos

```solidity
event Deposited(address indexed caller, uint256 assets, uint256 shares);
event Withdrawn(address indexed caller, uint256 assets, uint256 shares);
event Harvested(address indexed caller, uint256 profit);
```

### Nota Importante

La interfaz incluye `harvest()` como función requerida — todas las estrategias de VynX V1 deben soportar cosecha de rewards. El `actualWithdrawn` en `withdraw()` permite contabilizar el rounding de protocolos externos.

---

## ICometMarket.sol & ICometRewards.sol

**Ubicación**: `src/interfaces/compound/ICometMarket.sol` y `src/interfaces/compound/ICometRewards.sol`

### Propósito

Interfaces simplificadas de Compound v3 con solo las funciones necesarias para CompoundStrategy.

### Decisión de Diseño

**¿Por qué interfaces custom en lugar de librerías oficiales?**
- Compound v3: Librerías oficiales tienen dependencias complejas e indexadas
- Solo necesitamos las funciones que usamos
- Aave: Usamos librerías oficiales porque están limpias y bien estructuradas
- Compound: Interfaz custom es más pragmática (trade-off: inconsistencia vs simplicidad)

### ICometMarket — Funciones

```solidity
function supply(address asset, uint256 amount) external;
function withdraw(address asset, uint256 amount) external;
function balanceOf(address account) external view returns (uint256 balance);
function getSupplyRate(uint256 utilization) external view returns (uint64 rate);
function getUtilization() external view returns (uint256 utilization);
```

### ICometRewards — Funciones

```solidity
function claim(address comet, address src, bool shouldAccrue) external;
function getRewardOwed(address comet, address account) external returns (RewardOwed memory);
```

---

**Siguiente lectura**: [FLOWS.md](FLOWS.md) - Flujos de usuario paso a paso
