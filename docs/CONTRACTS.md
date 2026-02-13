# Documentación de Contratos

Este documento proporciona documentación técnica detallada de cada contrato del protocolo Multi-Strategy Vault, incluyendo variables de estado, funciones principales, eventos y modificadores.

---

## StrategyVault.sol

**Ubicación**: `src/core/StrategyVault.sol`

### Propósito

Vault ERC4626 que actúa como interfaz principal para usuarios. Mintea shares tokenizadas (msvWETH) en proporción a los assets depositados, acumula WETH en un idle buffer para optimizar gas, y gestiona withdrawal fees del 2%.

### Herencia

- `ERC4626` (OpenZeppelin): Implementación estándar de vault tokenizado
- `ERC20` (OpenZeppelin): Token de shares (msvWETH)
- `Ownable` (OpenZeppelin): Control de acceso administrativo
- `Pausable` (OpenZeppelin): Emergency stop para deposits/withdrawals

### Llamado Por

- **Usuarios (EOAs/contratos)**: `deposit()`, `mint()`, `withdraw()`, `redeem()`
- **Owner**: Funciones administrativas (pause, setters)
- **Cualquiera**: `allocateIdle()` (si idle >= threshold)

### Llama A

- **StrategyManager**: `allocate()` cuando idle buffer alcanza threshold, `withdrawTo()` cuando usuarios retiran
- **IERC20(WETH)**: Transferencias de WETH (SafeERC20)

### Variables de Estado Clave

```solidity
// Inmutables
StrategyManager public immutable strategy_manager;  // Motor de allocation

// Configuración del protocolo
address public fee_receiver;           // Recibe withdrawal fees (2%)
uint256 public withdrawal_fee;         // 200 basis points = 2%
uint256 public idle_threshold;         // 10 ether (threshold para auto-allocate)
uint256 public max_tvl;                // 1000 ether (circuit breaker)
uint256 public min_deposit;            // 0.01 ether (anti-spam, anti-rounding)

// Estado del idle buffer
uint256 public idle_weth;              // WETH acumulado pendiente de invertir
```

### Funciones Principales

#### deposit(uint256 assets, address receiver) → uint256 shares

Deposita WETH en el vault y mintea shares al usuario.

**Flujo:**
1. Verifica `assets >= min_deposit` (0.01 ETH)
2. Verifica `totalAssets() + assets <= max_tvl` (circuit breaker)
3. Calcula shares usando `previewDeposit(assets)` (antes de cambiar estado)
4. Transfiere WETH del usuario al vault (`SafeERC20.safeTransferFrom`)
5. Incrementa `idle_weth += assets` (acumula en buffer)
6. Mintea shares al receiver (`_mint`)
7. Si `idle_weth >= idle_threshold` (10 ETH), auto-ejecuta `_allocateIdle()`

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
1. Verifica `assets > 0`
2. Calcula shares a quemar usando `previewWithdraw(assets)` (incluye fee)
3. Verifica allowance si `msg.sender != owner` (`_spendAllowance`)
4. Quema shares del owner (`_burn`) - **CEI pattern**
5. Calcula fee: `fee = (assets * 200) / (10000 - 200)` = 2.04 WETH por 100 WETH netos
6. Calcula gross: `gross = assets + fee` = 102.04 WETH
7. Llama `_withdrawAssets(gross, receiver, fee)`:
   - Retira primero de `idle_weth` si hay disponible
   - Si no alcanza, llama `manager.withdrawTo(remaining, vault)`
8. Transfiere `fee` al `fee_receiver`
9. Transfiere `assets` netos al `receiver`

**Modificadores**: `whenNotPaused`

**Eventos**: `FeeCollected(fee_receiver, fee)`, `Withdrawn(receiver, assets, shares)`

---

#### redeem(uint256 shares, address receiver, address owner) → uint256 assets

Quema shares exactas y retira WETH proporcional (menos fee).

**Flujo:**
1. Verifica `shares > 0`
2. Calcula assets netos usando `previewRedeem(shares)` (ya descuenta fee)
3. Calcula valor bruto de shares: `gross_value = super.previewRedeem(shares)`
4. Calcula fee: `fee = (gross_value * 200) / 10000`
5. Similar a `withdraw()` a partir de aquí

**Modificadores**: `whenNotPaused`

**Eventos**: `FeeCollected(fee_receiver, fee)`, `Withdrawn(receiver, assets, shares)`

---

#### totalAssets() → uint256

Calcula TVL total bajo gestión del vault.

```solidity
function totalAssets() public view returns (uint256) {
    return idle_weth + strategy_manager.totalAssets();
}
```

**Incluye:**
- `idle_weth`: WETH físico en el vault (pendiente de invertir)
- `strategy_manager.totalAssets()`: Suma de WETH en todas las estrategias (incluye yield)

---

### Funciones Internas

#### _allocateIdle()

Transfiere idle buffer al StrategyManager para inversión.

**Flujo:**
1. Guarda `amount = idle_weth`
2. Resetea `idle_weth = 0`
3. Transfiere WETH al manager (`safeTransfer`)
4. Llama `manager.allocate(amount)`

**Llamada desde:**
- `deposit()` / `mint()` si `idle_weth >= idle_threshold`
- `allocateIdle()` (externa, cualquiera puede llamar)
- `forceAllocateIdle()` (owner only)

---

#### _withdrawAssets(uint256 gross_amount, address receiver, uint256 fee)

Helper para retirar assets del vault (idle + manager si necesario).

**Flujo:**
1. Calcula `from_idle = min(idle_weth, gross_amount)`
2. Resta `idle_weth -= from_idle`
3. Calcula `from_manager = gross_amount - from_idle`
4. Si `from_manager > 0`, llama `manager.withdrawTo(from_manager, vault)`
5. Calcula `assets_net = gross_amount - fee`
6. Transfiere `fee` al `fee_receiver`
7. Transfiere `assets_net` al `receiver`

---

### Funciones Administrativas

```solidity
// Emergency stop
function pause() external onlyOwner
function unpause() external onlyOwner

// Configuración del idle buffer
function setIdleThreshold(uint256 new_threshold) external onlyOwner
function allocateIdle() external  // Cualquiera si idle >= threshold
function forceAllocateIdle() external onlyOwner  // Sin check de threshold

// Circuit breakers
function setMaxTVL(uint256 new_max_tvl) external onlyOwner
function setMinDeposit(uint256 new_min_deposit) external onlyOwner

// Fees
function setWithdrawalFee(uint256 new_withdrawal_fee) external onlyOwner
function setWithdrawalFeeReceiver(address new_fee_receiver) external onlyOwner
```

### Funciones de Consulta

```solidity
function investedAssets() external view returns (uint256)
    // TVL en estrategias (sin idle)

function idleAssets() external view returns (uint256)
    // WETH en idle buffer

function canAllocate() external view returns (bool)
    // True si idle_weth >= idle_threshold

function maxDeposit(address) public view override returns (uint256)
    // Máximo que se puede depositar (respeta max_tvl, paused)

function maxWithdraw(address owner) public view override returns (uint256)
    // Máximo que owner puede retirar

function previewRedeem(uint256 shares) public view override returns (uint256)
    // Assets netos que recibe usuario (descuenta fee)

function previewWithdraw(uint256 assets) public view override returns (uint256)
    // Shares necesarias para retirar assets (incluye fee)
```

### Eventos Importantes

```solidity
event Deposited(address indexed user, uint256 assets, uint256 shares);
event Withdrawn(address indexed user, uint256 assets, uint256 shares);
event IdleAllocated(uint256 amount);
event FeeCollected(address indexed fee_receiver, uint256 fee_amount);
event IdleThresholdUpdated(uint256 old_threshold, uint256 new_threshold);
event MaxTVLUpdated(uint256 old_max, uint256 new_max);
event MinDepositUpdated(uint256 old_min, uint256 new_min);
event WithdrawalFeeUpdated(uint256 indexed old_fee, uint256 indexed new_fee);
event FeeReceiverUpdated(address indexed old_receiver, address indexed new_receiver);
```

### Errores Custom

```solidity
error StrategyVault__ZeroAmount();
error StrategyVault__BelowMinDeposit();
error StrategyVault__MaxTVLExceeded();
error StrategyVault__IdleBelowThreshold();
```

---

## StrategyManager.sol

**Ubicación**: `src/core/StrategyManager.sol`

### Propósito

Cerebro del protocolo que calcula weighted allocation basado en APY, distribuye assets entre estrategias, ejecuta rebalanceos rentables y retira proporcionalmente durante withdrawals.

### Herencia

- `Ownable` (OpenZeppelin): Control de acceso administrativo

### Llamado Por

- **StrategyVault**: `allocate()`, `withdrawTo()` (modificador `onlyVault`)
- **Owner**: `addStrategy()`, `removeStrategy()`, setters
- **Cualquiera**: `rebalance()` (si `shouldRebalance()` es true)

### Llama A

- **IStrategy**: `deposit()`, `withdraw()`, `totalAssets()`, `apy()`

### Variables de Estado Clave

```solidity
// Inmutables
address public immutable vault;        // StrategyVault autorizado
address public immutable asset;        // WETH

// Estrategias disponibles
IStrategy[] public strategies;
mapping(address => bool) public is_strategy;
mapping(IStrategy => uint256) public target_allocation;  // En basis points

// Parámetros de allocation
uint256 public max_allocation_per_strategy = 5000;  // 50%
uint256 public min_allocation_threshold = 1000;     // 10%

// Parámetros de rebalancing
uint256 public rebalance_threshold = 200;           // 2% diferencia de APY
uint256 public min_tvl_for_rebalance = 10 ether;
uint256 public gas_cost_multiplier = 200;           // 2x margen
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
   - Calcula `amount = (assets * target) / 10000`
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
   - Llama `strategy.withdraw(to_withdraw)` (WETH va al manager)
5. Transfiere `assets` WETH del manager al receiver

**Modificadores**: `onlyVault`

**Nota**: Retira proporcionalmente para mantener ratios. NO recalcula target allocation (ahorro de gas).

**Ejemplo:**
```solidity
// Estado: Aave 70 WETH, Compound 30 WETH (total 100 WETH)
// Usuario retira 50 WETH
// - De Aave: 50 * 70/100 = 35 WETH
// - De Compound: 50 * 30/100 = 15 WETH
// Resultado: Aave 35 WETH, Compound 15 WETH (mantiene ratio 70/30)
```

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
   - Calcula `target_balance = (total_tvl * target) / 10000`
   - Si `current > target`: Añade a array de exceso
   - Si `target > current`: Añade a array de necesidad
5. Para cada estrategia con exceso:
   - Retira exceso: `strategy.withdraw(excess)`
   - Para cada estrategia con necesidad:
     - Calcula `to_transfer = min(available, needed)`
     - Transfiere WETH a estrategia destino
     - Deposita: `strategy.deposit(to_transfer)`
     - Emite `Rebalanced(from_strategy, to_strategy, amount)`

**Modificadores**: Ninguno (público)

**Eventos**: `Rebalanced(from_strategy, to_strategy, assets)`

**Ejemplo:**
```solidity
// Estado actual: Aave 70 WETH (5% APY), Compound 30 WETH (6% APY)
// Targets: Aave 45% (45 WETH), Compound 55% (55 WETH)
// Rebalance:
//   1. Retira 25 WETH de Aave
//   2. Deposita 25 WETH en Compound
// Estado final: Aave 45 WETH, Compound 55 WETH
```

---

#### shouldRebalance() → bool

Calcula si un rebalance es rentable comparando profit esperado vs gas cost.

**Flujo:**
1. Verifica `strategies.length >= 2` y `totalAssets() >= min_tvl`
2. Calcula targets temporales usando `_computeTargets()` (no modifica storage)
3. Verifica que al menos un target sea > 0
4. Para cada estrategia:
   - Calcula delta entre `current_balance` y `target_balance`
   - Si `target > current`: Suma profit esperado `(delta * strategy.apy()) / 10000`
   - Cuenta número de movimientos necesarios
5. Calcula `weekly_profit = (annual_profit * 7) / 365`
6. Estima `gas_cost = (num_moves * 300000) * tx.gasprice`
7. Retorna `weekly_profit > (gas_cost * gas_multiplier / 100)`

**Nota**: Es función `view` (no modifica estado), puede ser llamada por bots/frontends.

**Ejemplo de cálculo:**
```solidity
// Estado: Aave 70 WETH (5%), Compound 30 WETH (6%)
// Targets: Aave 45 WETH, Compound 55 WETH
// Movimiento: 25 WETH Aave → Compound
//
// Profit anual: 25 * 6% = 1.5 WETH
// Profit semanal: 1.5 * 7/365 = 0.0287 WETH
//
// Gas: 2 movimientos * 300k = 600k gas
// Gas cost: 600k * 50 gwei = 0.03 ETH
// Con multiplier 2x: 0.06 ETH
//
// Decisión: 0.0287 < 0.06 → NO rebalancear
```

---

### Funciones de Gestión de Estrategias

#### addStrategy(address strategy)

Agrega nueva estrategia al manager.

**Flujo:**
1. Verifica que estrategia no exista (`!is_strategy[strategy]`)
2. Añade al array: `strategies.push(IStrategy(strategy))`
3. Marca como existente: `is_strategy[strategy] = true`
4. Recalcula target allocations: `_calculateTargetAllocation()`

**Modificadores**: `onlyOwner`

**Eventos**: `StrategyAdded(strategy)`, `TargetAllocationsUpdated()`

---

#### removeStrategy(address strategy)

Remueve estrategia del manager.

**Precondición**: Estrategia debe tener balance cero antes de remover.

**Flujo:**
1. Verifica que estrategia exista
2. Encuentra índice en array
3. Elimina target: `delete target_allocation[strategies[index]]`
4. Swap & pop: `strategies[index] = strategies[length-1]; strategies.pop()`
5. Marca como no existente: `is_strategy[strategy] = false`
6. Recalcula targets para estrategias restantes

**Modificadores**: `onlyOwner`

**Eventos**: `StrategyRemoved(strategy)`, `TargetAllocationsUpdated()`

---

### Funciones Internas

#### _computeTargets() → uint256[]

Calcula targets de allocation basados en APY con caps.

**Algoritmo:**
1. Si no hay estrategias: retorna array vacío
2. Suma APYs de todas las estrategias: `total_apy`
3. Si `total_apy == 0`: distribuye equitativamente (`10000 / strategies.length`)
4. Para cada estrategia:
   - Calcula target sin caps: `uncapped = (apy * 10000) / total_apy`
   - Aplica límites:
     - Si `uncapped > max_allocation`: target = max (50%)
     - Si `uncapped < min_threshold`: target = 0 (10%)
     - Sino: target = uncapped
5. Normaliza para que sumen 10000:
   - Suma todos los targets
   - Si no suma 10000: `target[i] = (target[i] * 10000) / total_targets`
6. Retorna array de targets

**Usado por**: `_calculateTargetAllocation()` (escribe a storage), `shouldRebalance()` (solo lectura)

---

#### _calculateTargetAllocation()

Calcula targets y escribe a storage.

**Flujo:**
1. Si no hay estrategias: retorna
2. Llama `_computeTargets()` para obtener array de targets
3. Escribe a storage: `target_allocation[strategies[i]] = computed[i]`
4. Emite `TargetAllocationsUpdated()`

---

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
```

### Setters Administrativos

```solidity
function setRebalanceThreshold(uint256 new_threshold) external onlyOwner
function setMinTVLForRebalance(uint256 new_min_tvl) external onlyOwner
function setGasCostMultiplier(uint256 new_multiplier) external onlyOwner
function setMaxAllocationPerStrategy(uint256 new_max) external onlyOwner
    // Recalcula targets después
function setMinAllocationThreshold(uint256 new_min) external onlyOwner
    // Recalcula targets después
```

### Eventos Importantes

```solidity
event Allocated(address indexed strategy, uint256 assets);
event Rebalanced(address indexed from_strategy, address indexed to_strategy, uint256 assets);
event StrategyAdded(address indexed strategy);
event StrategyRemoved(address indexed strategy);
event TargetAllocationsUpdated();
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
error StrategyManager__RebalanceNotProfitable();
error StrategyManager__ZeroAmount();
error StrategyManager__OnlyVault();
```

---

## AaveStrategy.sol

**Ubicación**: `src/strategies/AaveStrategy.sol`

### Propósito

Integración con Aave v3 para depositar WETH y generar yield mediante lending.

### Implementa

- `IStrategy`: Interfaz estándar de estrategias

### Llamado Por

- **StrategyManager**: `deposit()`, `withdraw()`, `totalAssets()`, `apy()`

### Llama A

- **IPool (Aave v3)**: `supply()`, `withdraw()`, `getReserveData()`
- **IERC20(WETH)**: Transferencias con SafeERC20

### Variables de Estado

```solidity
address public immutable manager;          // StrategyManager autorizado
IPool private immutable aave_pool;         // Aave v3 Pool
IAToken private immutable a_weth;          // aWETH (rebasing token)
address private immutable weth_address;    // WETH
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

**Eventos**: `Deposited(manager, assets, shares)`

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

**Eventos**: `Withdrawn(manager, actualWithdrawn, assets)`

---

#### totalAssets() → uint256

Balance actual de WETH en Aave (incluye yield).

```solidity
function totalAssets() external view returns (uint256) {
    return a_weth.balanceOf(address(this));
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
```

---

## CompoundStrategy.sol

**Ubicación**: `src/strategies/CompoundStrategy.sol`

### Propósito

Integración con Compound v3 para depositar WETH y generar yield mediante lending.

### Implementa

- `IStrategy`: Interfaz estándar de estrategias

### Llamado Por

- **StrategyManager**: `deposit()`, `withdraw()`, `totalAssets()`, `apy()`

### Llama A

- **IComet (Compound v3)**: `supply()`, `withdraw()`, `balanceOf()`, `getSupplyRate()`, `getUtilization()`
- **IERC20(WETH)**: Transferencias con SafeERC20

### Variables de Estado

```solidity
address public immutable manager;               // StrategyManager autorizado
IComet private immutable compound_comet;        // Compound v3 Comet
address private immutable weth_address;         // WETH
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

**Eventos**: `Deposited(manager, assets, shares)`

**Nota**: Compound v3 usa accounting interno (no tokens), balance incrementa con yield.

---

#### withdraw(uint256 assets) → uint256 actualWithdrawn

Retira WETH de Compound v3.

**Flujo:**
1. Llama `compound_comet.withdraw(weth, assets)`
2. Balance interno de Compound decrementa, recibe WETH
3. Transfiere WETH al manager: `safeTransfer(msg.sender, actualWithdrawn)`
4. Emite `Withdrawn(msg.sender, actualWithdrawn, assets)`

**Modificadores**: `onlyManager`

**Eventos**: `Withdrawn(manager, actualWithdrawn, assets)`

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
   // APY = rate * seconds_per_year / 1e18 * 10000
   // Simplificado: (rate * 315360000000) / 1e18
   apyBasisPoints = (uint256(rate) * 315360000000) / 1e18;
   ```

**Ejemplo:**
```solidity
// supply_rate = 1000000000000000 (1e15 per second)
// APY = (1e15 * 31536000 * 10000) / 1e18 = 315 basis points = 3.15%
```

---

### Funciones de Utilidad

```solidity
function getSupplyRate() external view returns (uint256)
    // Supply rate actual de Compound (convertido a uint256)

function getUtilization() external view returns (uint256)
    // Utilization actual del pool (borrowed / supplied)
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
```

---

## IStrategy.sol

**Ubicación**: `src/interfaces/IStrategy.sol`

### Propósito

Interfaz estándar que todas las estrategias deben implementar para permitir que StrategyManager las trate de forma uniforme.

### Funciones Requeridas

```solidity
function deposit(uint256 assets) external returns (uint256 shares);
function withdraw(uint256 assets) external returns (uint256 actualWithdrawn);
function totalAssets() external view returns (uint256 total);
function apy() external view returns (uint256 apyBasisPoints);
function name() external view returns (string memory strategyName);
function asset() external view returns (address assetAddress);
```

### Eventos

```solidity
event Deposited(address indexed caller, uint256 assets, uint256 shares);
event Withdrawn(address indexed caller, uint256 assets, uint256 shares);
```

### Nota Importante

La interfaz NO incluye `mint()` / `redeem()` porque esas funciones son del ERC4626 vault, no de las estrategias individuales. Las estrategias solo necesitan `deposit()` / `withdraw()`.

---

## IComet.sol

**Ubicación**: `src/interfaces/IComet.sol`

### Propósito

Interfaz simplificada de Compound v3 Comet con solo las funciones necesarias para CompoundStrategy.

### Decisión de Diseño

**¿Por qué interfaz custom en lugar de librerías oficiales?**
- Compound v3: Librerías oficiales tienen dependencias complejas e indexadas
- Solo necesitamos 5 funciones
- Aave: Usamos librerías oficiales porque están limpias y bien estructuradas
- Compound: Interfaz custom es más pragmática (trade-off: inconsistencia vs simplicidad)

### Funciones

```solidity
function supply(address asset, uint256 amount) external;
function withdraw(address asset, uint256 amount) external;
function balanceOf(address account) external view returns (uint256 balance);
function getSupplyRate(uint256 utilization) external view returns (uint64 rate);
function getUtilization() external view returns (uint256 utilization);
```

---

**Siguiente lectura**: [FLOWS.md](FLOWS.md) - Flujos de usuario paso a paso
