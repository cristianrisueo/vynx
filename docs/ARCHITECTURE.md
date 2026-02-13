# Arquitectura del Sistema

Este documento describe la arquitectura de alto nivel del Multi-Strategy Vault, explicando la jerarquía de contratos, el flujo de ownership, las decisiones de diseño clave y cómo circula el WETH a través del sistema.

## Visión General

### ¿Qué Problema Resuelve?

Los usuarios que quieren maximizar su yield en DeFi enfrentan varios desafíos:

1. **Complejidad**: Gestionar posiciones en múltiples protocolos (Aave, Compound, etc.) requiere conocimiento técnico
2. **Monitoreo constante**: Los APYs fluctúan y hay que rebalancear manualmente para optimizar rendimientos
3. **Costes de gas**: Mover fondos entre protocolos es caro, especialmente para holdings pequeños
4. **Riesgo de protocolo único**: Estar 100% en un solo protocolo aumenta el riesgo

Multi-Strategy Vault resuelve estos problemas mediante:

- **Agregación automatizada**: Los usuarios depositan una vez y el protocolo gestiona múltiples estrategias
- **Weighted allocation**: Distribución inteligente basada en APY (mayor rendimiento = mayor porcentaje)
- **Rebalancing inteligente**: Solo ejecuta cuando el profit semanal supera 2x el coste de gas
- **Idle buffer**: Acumula depósitos pequeños para amortizar gas entre múltiples usuarios
- **Diversificación**: Reparte riesgo entre Aave y Compound con límites (max 50%, min 10%)

### Arquitectura de Alto Nivel

```
Usuario (EOA)
    |
    | deposit(WETH) / withdraw(WETH)
    v
┌─────────────────────────────────────────┐
│       StrategyVault (ERC4626)           │
│  - Mintea/quema shares (msvWETH)        │
│  - Idle buffer (acumula hasta 10 ETH)   │
│  - Withdrawal fee (2%)                  │
│  - Circuit breakers (max TVL, min dep)  │
└─────────────────────────────────────────┘
    |
    | allocate(WETH) / withdrawTo(WETH)
    v
┌─────────────────────────────────────────┐
│        StrategyManager (Cerebro)        │
│  - Calcula weighted allocation          │
│  - Distribuye según APY                 │
│  - Ejecuta rebalanceos rentables        │
│  - Retira proporcionalmente             │
└─────────────────────────────────────────┘
    |
    |--------------------+--------------------+
    |                    |                    |
    v                    v                    v
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│AaveStrategy │    │CompoundStrat│    │Future Strat │
│  (IStrategy)│    │  (IStrategy)│    │  (IStrategy)│
└─────────────┘    └─────────────┘    └─────────────┘
    |                    |                    |
    v                    v                    v
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│  Aave Pool  │    │Compound Comet│   │   Nuevo     │
│   (aWETH)   │    │  (interno)  │    │  Protocolo  │
└─────────────┘    └─────────────┘    └─────────────┘
```

## Jerarquía de Contratos

### 1. StrategyVault.sol (Capa de Usuario)

**Responsabilidades:**
- Interfaz ERC4626 para usuarios (deposit, withdraw, mint, redeem)
- Gestión del idle buffer (acumulación de WETH pendiente)
- Cobro de withdrawal fees (2%)
- Circuit breakers (max TVL, min deposit)
- Pausable (emergency stop)

**Hereda de:**
- `ERC4626` (OpenZeppelin): Estándar de vault tokenizado
- `Ownable` (OpenZeppelin): Control de acceso admin
- `Pausable` (OpenZeppelin): Emergency stop

**Llama a:**
- `StrategyManager.allocate()`: Cuando idle buffer alcanza threshold
- `StrategyManager.withdrawTo()`: Cuando usuarios retiran y idle no alcanza

**Es llamado por:**
- Usuarios (EOAs o contratos): deposit, withdraw, mint, redeem

### 2. StrategyManager.sol (Capa de Lógica)

**Responsabilidades:**
- Calcular weighted allocation basado en APY de estrategias
- Distribuir WETH entre estrategias según targets calculados
- Ejecutar rebalanceos cuando son rentables
- Retirar proporcionalmente de estrategias

**Hereda de:**
- `Ownable` (OpenZeppelin): Control de acceso admin

**Llama a:**
- `IStrategy.deposit()`: Para cada estrategia durante allocate
- `IStrategy.withdraw()`: Para cada estrategia durante withdrawTo/rebalance
- `IStrategy.apy()`: Para calcular weighted allocation
- `IStrategy.totalAssets()`: Para conocer TVL por estrategia

**Es llamado por:**
- `StrategyVault`: allocate(), withdrawTo()
- Owner: addStrategy(), removeStrategy()
- Cualquiera: rebalance() (si es rentable)

### 3. AaveStrategy.sol & CompoundStrategy.sol (Capa de Integración)

**Responsabilidades:**
- Implementar interfaz `IStrategy`
- Depositar WETH en protocolo subyacente
- Retirar WETH + yield de protocolo
- Reportar APY actual del protocolo
- Reportar TVL bajo gestión

**Implementa:**
- `IStrategy`: Interfaz estándar (deposit, withdraw, totalAssets, apy, name, asset)

**Llama a:**
- **AaveStrategy**: `IPool.supply()`, `IPool.withdraw()`, `IPool.getReserveData()`
- **CompoundStrategy**: `IComet.supply()`, `IComet.withdraw()`, `IComet.balanceOf()`, `IComet.getSupplyRate()`

**Es llamado por:**
- `StrategyManager`: deposit(), withdraw()

## Flujo de Ownership

El protocolo utiliza un modelo de ownership jerárquico para control granular:

```
Owner del Vault (EOA)
    |
    +--> StrategyVault.pause()                # Emergency stop
    +--> StrategyVault.setIdleThreshold()     # Ajustar threshold
    +--> StrategyVault.setMaxTVL()            # Ajustar circuit breaker
    +--> StrategyVault.setWithdrawalFee()     # Ajustar fees

Owner del Manager (EOA)
    |
    +--> StrategyManager.addStrategy()        # Agregar nuevas estrategias
    +--> StrategyManager.removeStrategy()     # Remover estrategias
    +--> StrategyManager.setMaxAllocation()   # Ajustar caps
    +--> StrategyManager.setGasCostMultiplier() # Ajustar profitabilidad

StrategyVault (Contrato)
    |
    +--> StrategyManager.allocate()           # Solo vault
    +--> StrategyManager.withdrawTo()         # Solo vault
         (Mediante modificador onlyVault)

StrategyManager (Contrato)
    |
    +--> AaveStrategy.deposit()               # Solo manager
    +--> AaveStrategy.withdraw()              # Solo manager
    +--> CompoundStrategy.deposit()           # Solo manager
    +--> CompoundStrategy.withdraw()          # Solo manager
         (Mediante modificador onlyManager)
```

**Puntos clave:**

1. **Owner del Vault ≠ Owner del Manager**: Pueden ser diferentes EOAs para separación de concerns
2. **Solo vault puede llamar al manager**: Modificador `onlyVault` protege allocate/withdrawTo
3. **Solo manager puede llamar a strategies**: Modificador `onlyManager` protege deposit/withdraw
4. **Cualquiera puede ejecutar rebalance**: Si pasa el check de rentabilidad en `shouldRebalance()`

## Cadena de Llamadas

### Flujo de Deposit

```
Usuario
  └─> vault.deposit(100 WETH)
       └─> IERC20(weth).transferFrom(usuario, vault, 100)
       └─> idle_weth += 100
       └─> _mint(usuario, shares)
       └─> if (idle_weth >= 10 ETH):
            └─> _allocateIdle()
                 └─> IERC20(weth).transfer(manager, 100)
                 └─> manager.allocate(100)
                      └─> _calculateTargetAllocation()
                           └─> _computeTargets() // APY-based weighted allocation
                      └─> for cada estrategia:
                           └─> IERC20(weth).transfer(strategy, 50)
                           └─> strategy.deposit(50)
                                └─> AaveStrategy: aave_pool.supply(weth, 50)
                                └─> CompoundStrategy: compound_comet.supply(weth, 50)
```

### Flujo de Withdraw

```
Usuario
  └─> vault.withdraw(100 WETH)
       └─> shares = previewWithdraw(100)  // Calcula shares a quemar
       └─> _burn(usuario, shares)
       └─> fee = (100 * 200) / (10000 - 200) = 2.04 WETH
       └─> gross_amount = 100 + 2.04 = 102.04 WETH
       └─> _withdrawAssets(102.04, usuario, 2.04)
            └─> from_idle = min(idle_weth, 102.04)
            └─> from_manager = 102.04 - from_idle
            └─> if (from_manager > 0):
                 └─> manager.withdrawTo(from_manager, vault)
                      └─> for cada estrategia:
                           └─> to_withdraw = (from_manager * strategy_balance) / total_assets
                           └─> strategy.withdraw(to_withdraw)
                                └─> AaveStrategy: aave_pool.withdraw(weth, amount)
                                └─> CompoundStrategy: compound_comet.withdraw(weth, amount)
                           └─> IERC20(weth).transfer(strategy, manager, amount)
                      └─> IERC20(weth).transfer(manager, vault, from_manager)
            └─> IERC20(weth).transfer(vault, fee_receiver, 2.04)
            └─> IERC20(weth).transfer(vault, usuario, 100)
```

### Flujo de Rebalance

```
Keeper / Bot / Usuario
  └─> manager.shouldRebalance()
       └─> return profit_semanal > gas_cost * 2
  └─> manager.rebalance()
       └─> _calculateTargetAllocation() // Recalcula targets frescos
       └─> for cada estrategia:
            └─> current_balance = strategy.totalAssets()
            └─> target_balance = (total_tvl * target_allocation) / 10000
            └─> if (current_balance > target_balance):
                 └─> excess = current_balance - target_balance
                 └─> strategy.withdraw(excess)
            └─> if (current_balance < target_balance):
                 └─> needed = target_balance - current_balance
       └─> Mueve excesos a estrategias con necesidad:
            └─> IERC20(weth).transfer(manager, to_strategy, amount)
            └─> to_strategy.deposit(amount)
```

## Decisiones Arquitectónicas Clave

### 1. ¿Por Qué Weighted Allocation vs All-or-Nothing?

**Decisión**: Usar weighted allocation (50% Aave, 50% Compound) en lugar de 100% en la mejor estrategia.

**Razones**:
- **Diversificación de riesgo**: Si Aave tiene un exploit, solo perdemos el 50%
- **Liquidez**: Compound podría no tener liquidez para absorber todo el TVL
- **Educacional**: Weighted allocation es más sofisticado y realista
- **Trade-off**: Sacrificamos ~0.5% APY por mayor seguridad y robustez

**Alternativa considerada**: All-or-nothing (100% en mejor APY)
- Pros: Maximiza rendimiento absoluto
- Contras: Alto riesgo, problemas de liquidez, rebalances más frecuentes

### 2. ¿Por Qué Idle Buffer vs Deposit Directo?

**Decisión**: Acumular depósitos en un buffer hasta alcanzar 10 ETH antes de invertir.

**Razones**:
- **Optimización de gas**: Un allocate para 10 usuarios (1 ETH cada uno) vs 10 allocates separados
- **Coste compartido**: Los usuarios comparten el gas de allocation proporcionalmente
- **Retiros eficientes**: Si hay idle, los retiros pequeños no tocan estrategias (ahorro masivo)
- **Trade-off**: WETH en idle buffer no genera yield (~0 APY durante acumulación)

**Análisis de break-even**:
- Allocate cost: ~300k gas × 50 gwei = 0.015 ETH
- Si 10 usuarios depositan 1 ETH cada uno: 0.015 / 10 = 0.0015 ETH por usuario
- vs cada usuario pagando 0.015 ETH: Ahorro del 90%

**Alternativa considerada**: Deposit directo sin buffer
- Pros: Yield inmediato desde depósito 1
- Contras: Gas prohibitivo para depósitos pequeños

### 3. ¿Por Qué Interfaz Custom Compound vs Librería Oficial?

**Decisión**: Crear `IComet.sol` personalizada en lugar de usar las librerías oficiales de Compound.

**Razones**:
- **Simplicidad**: Solo necesitamos 5 funciones (supply, withdraw, balanceOf, getSupplyRate, getUtilization)
- **Librerías oficiales sucias**: Dependencias complejas, versiones indexadas, estructura pesada
- **Consistencia parcial**: Aave tiene librerías limpias (las usamos), Compound no (interfaz custom)
- **Trade-off**: Inconsistencia (Aave = librerías, Compound = interfaz) vs pragmatismo

**Comparación Aave**:
- Aave: `@aave/contracts/interfaces/IPool.sol` - limpia y directa ✅
- Compound: Librerías oficiales con dependencias innecesarias ❌

### 4. ¿Por Qué Rebalancing Manual vs Automático On-Chain?

**Decisión**: Rebalancing ejecutado externamente (keeper bots, usuarios) en lugar de automático on-chain.

**Razones**:
- **Coste de gas**: Rebalancear en cada deposit sería carísimo
- **Flexibilidad**: Keepers pueden elegir momento óptimo (gas bajo)
- **Incentivos**: Cualquiera puede ejecutar y capturar MEV si hay algún beneficio
- **Trade-off**: Requiere infraestructura externa (bots)

**Protección**: `shouldRebalance()` verifica que sea rentable antes de permitir ejecución.

### 5. ¿Por Qué Withdrawal Fee del 2%?

**Decisión**: Cobrar 2% sobre retiros en lugar de entrada/performance fee.

**Razones**:
- **Incentiva HODL**: Penaliza retiros tempranos, beneficia holders de largo plazo
- **Gas-efficient**: Cálculo simple durante withdraw (no requiere tracking de entry price)
- **Revenue para protocolo**: Fondea desarrollo, auditorías, recompensas de keepers
- **Trade-off**: Penaliza legítimos withdrawals necesarios

**Alternativas consideradas**:
- Performance fee (20% de ganancias): Requiere high water mark, mucho más complejo
- Deposit fee: Penaliza nuevos usuarios (malo para crecimiento)

## Flujo de WETH

### Estados del WETH en el Sistema

```
1. Usuario EOA
   └─> WETH en wallet del usuario

2. Idle Buffer (vault.idle_weth)
   └─> Balance físico en StrategyVault
   └─> No genera yield
   └─> Accounting: vault.idle_weth (variable de estado)

3. En Manager (temporal)
   └─> Balance físico en StrategyManager (solo durante allocate/rebalance)
   └─> Inmediatamente transferido a estrategias

4. En Estrategias
   ├─> AaveStrategy:
   │    └─> Balance físico en Aave Pool
   │    └─> Accounting: a_weth.balanceOf(strategy) (aTokens, hacen rebase automático)
   │    └─> Yield: Incluido automáticamente en aToken balance
   │
   └─> CompoundStrategy:
        └─> Balance físico en Compound Comet
        └─> Accounting: compound_comet.balanceOf(strategy) (interno, no token)
        └─> Yield: Incluido automáticamente en balance interno

5. De vuelta al Usuario
   └─> WETH en wallet del usuario (neto - fee)
   └─> Fee en wallet del fee_receiver
```

### Accounting vs Balance Físico

Es crucial entender que **totalAssets() es accounting, no balance físico**:

```solidity
// StrategyVault.totalAssets()
function totalAssets() public view returns (uint256) {
    return idle_weth + strategy_manager.totalAssets();
    // idle_weth: Balance físico en vault
    // strategy_manager.totalAssets(): Suma de assets en estrategias
}

// StrategyManager.totalAssets()
function totalAssets() public view returns (uint256) {
    uint256 total = 0;
    for (uint256 i = 0; i < strategies.length; i++) {
        total += strategies[i].totalAssets(); // Accounting de estrategias
    }
    return total;
}

// AaveStrategy.totalAssets()
function totalAssets() external view returns (uint256) {
    return a_weth.balanceOf(address(this));
    // aWETH hace rebase → balance aumenta con yield automáticamente
}

// CompoundStrategy.totalAssets()
function totalAssets() external view returns (uint256) {
    return compound_comet.balanceOf(address(this));
    // Balance interno de Compound → incluye yield automáticamente
}
```

**Ejemplo numérico:**

Usuario deposita 100 WETH:
1. `vault.idle_weth = 100` (físico en vault)
2. `vault.totalAssets() = 100` (accounting)

Idle alcanza threshold, allocate:
1. `vault.idle_weth = 0` (físico movido a manager → estrategias)
2. `aave_strategy balance = 50 aWETH` (físico en Aave)
3. `compound_strategy balance = 50 WETH` (físico en Compound)
4. `vault.totalAssets() = 0 + manager.totalAssets() = 100` (accounting)

Después de 1 mes (yield del 5% APY):
1. `aave_strategy.totalAssets() = 50.2` (aWETH rebase incluye yield)
2. `compound_strategy.totalAssets() = 50.2` (balance interno incluye yield)
3. `vault.totalAssets() = 0 + 100.4 = 100.4` (accounting refleja yield)
4. Usuario puede retirar 100.4 WETH (shares = 100 en precio de entrada, valen más ahora)

## Limitaciones Conocidas

1. **Solo WETH**: Arquitectura actual no soporta multi-asset (planificado para v2)
2. **Rebalancing manual**: Requiere keepers externos (no automático on-chain)
3. **Sin performance fees**: Solo withdrawal fee (high water mark en v2)
4. **Weighted allocation v1**: Algoritmo básico (machine learning en v3?)
5. **Single vault owner**: Centralización del ownership (multisig en producción)
6. **Idle buffer sin yield**: WETH acumulado no genera rendimiento

---

**Siguiente lectura**: [CONTRACTS.md](CONTRACTS.md) - Documentación detallada por contrato
