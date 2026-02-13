# Arquitectura del Sistema

Este documento describe la arquitectura de alto nivel de VynX V1, explicando la jerarquía de contratos, el flujo de ownership, las decisiones de diseño clave y cómo circula el WETH a través del sistema.

## Visión General

### ¿Qué Problema Resuelve?

Los usuarios que quieren maximizar su yield en DeFi enfrentan varios desafíos:

1. **Complejidad**: Gestionar posiciones en múltiples protocolos (Aave, Compound, etc.) requiere conocimiento técnico
2. **Monitoreo constante**: Los APYs fluctúan y hay que rebalancear manualmente para optimizar rendimientos
3. **Costes de gas**: Mover fondos entre protocolos es caro, especialmente para holdings pequeños
4. **Riesgo de protocolo único**: Estar 100% en un solo protocolo aumenta el riesgo
5. **Rewards sin cosechar**: Protocolos como Aave y Compound emiten reward tokens que hay que claimear, swapear y reinvertir manualmente

VynX V1 resuelve estos problemas mediante:

- **Agregación automatizada**: Los usuarios depositan una vez y el protocolo gestiona múltiples estrategias
- **Weighted allocation**: Distribución inteligente basada en APY (mayor rendimiento = mayor porcentaje)
- **Rebalancing inteligente**: Solo ejecuta cuando la diferencia de APY entre estrategias supera el threshold (2%)
- **Idle buffer**: Acumula depósitos pequeños para amortizar gas entre múltiples usuarios
- **Diversificación**: Reparte riesgo entre Aave y Compound con límites (max 50%, min 10%)
- **Harvest automatizado**: Cosecha rewards (AAVE/COMP), swap a WETH via Uniswap V3, reinversión automática
- **Keeper incentive system**: Cualquiera puede ejecutar harvest y recibir 1% del profit como incentivo

### Arquitectura de Alto Nivel

```
Usuario (EOA)
    |
    | deposit(WETH) / withdraw(WETH)
    v
┌─────────────────────────────────────────────────────┐
│              Vault (ERC4626)                        │
│  - Mintea/quema shares (vxWETH)                     │
│  - Idle buffer (acumula hasta 10 ETH)               │
│  - Performance fee (20% sobre profits de harvest)   │
│  - Keeper incentive system (1% para keepers ext.)   │
│  - Circuit breakers (max TVL, min deposit)          │
└─────────────────────────────────────────────────────┘
    |                                       |
    | allocate(WETH) / withdrawTo(WETH)     | harvest()
    v                                       v
┌─────────────────────────────────────────────────────┐
│           StrategyManager (Cerebro)                 │
│  - Calcula weighted allocation                      │
│  - Distribuye según APY                             │
│  - Ejecuta rebalanceos rentables                    │
│  - Retira proporcionalmente                         │
│  - Coordina harvest fail-safe de todas estrategias  │
└─────────────────────────────────────────────────────┘
    |
    |--------------------+--------------------+
    |                    |                    |
    v                    v                    v
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│AaveStrategy │    │CompoundStrat│    │Future Strat │
│  (IStrategy)│    │  (IStrategy)│    │  (IStrategy)│
│  + harvest  │    │  + harvest  │    │  + harvest  │
│  + Uniswap  │    │  + Uniswap  │    │  + Uniswap  │
└─────────────┘    └─────────────┘    └─────────────┘
    |                    |                    |
    v                    v                    v
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│  Aave Pool  │    │Compound Comet│   │   Nuevo     │
│   (aWETH)   │    │  (interno)  │    │  Protocolo  │
└─────────────┘    └─────────────┘    └─────────────┘
    |                    |
    v                    v
┌──────────────────────────────────────────┐
│         Uniswap V3 Router                │
│  - Swap AAVE → WETH (0.3% fee)          │
│  - Swap COMP → WETH (0.3% fee)          │
│  - Max slippage: 1%                      │
└──────────────────────────────────────────┘
```

## Jerarquía de Contratos

### 1. Vault.sol (Capa de Usuario)

**Responsabilidades:**
- Interfaz ERC4626 para usuarios (deposit, withdraw, mint, redeem)
- Gestión del idle buffer (acumulación de WETH pendiente)
- Coordinación de harvest y distribución de performance fees
- Keeper incentive system (official keepers vs externos)
- Circuit breakers (max TVL, min deposit)
- Pausable (emergency stop)

**Hereda de:**
- `ERC4626` (OpenZeppelin): Estándar de vault tokenizado
- `ERC20` (OpenZeppelin): Token de shares (vxWETH)
- `Ownable` (OpenZeppelin): Control de acceso admin
- `Pausable` (OpenZeppelin): Emergency stop

**Llama a:**
- `StrategyManager.allocate()`: Cuando idle buffer alcanza threshold
- `StrategyManager.withdrawTo()`: Cuando usuarios retiran y idle no alcanza
- `StrategyManager.harvest()`: Cuando alguien ejecuta harvest()

**Es llamado por:**
- Usuarios (EOAs o contratos): deposit, withdraw, mint, redeem
- Keepers/Cualquiera: harvest(), allocateIdle()
- Owner: Funciones administrativas (pause, setters)

### 2. StrategyManager.sol (Capa de Lógica)

**Responsabilidades:**
- Calcular weighted allocation basado en APY de estrategias
- Distribuir WETH entre estrategias según targets calculados
- Ejecutar rebalanceos cuando son rentables
- Retirar proporcionalmente de estrategias
- Coordinar harvest fail-safe (si una estrategia falla, las demás continúan)

**Hereda de:**
- `Ownable` (OpenZeppelin): Control de acceso admin

**Llama a:**
- `IStrategy.deposit()`: Para cada estrategia durante allocate
- `IStrategy.withdraw()`: Para cada estrategia durante withdrawTo/rebalance
- `IStrategy.harvest()`: Para cada estrategia durante harvest (con try-catch)
- `IStrategy.apy()`: Para calcular weighted allocation
- `IStrategy.totalAssets()`: Para conocer TVL por estrategia

**Es llamado por:**
- `Vault`: allocate(), withdrawTo(), harvest()
- Owner: addStrategy(), removeStrategy()
- Cualquiera: rebalance() (si es rentable)

### 3. AaveStrategy.sol & CompoundStrategy.sol (Capa de Integración)

**Responsabilidades:**
- Implementar interfaz `IStrategy`
- Depositar WETH en protocolo subyacente
- Retirar WETH + yield de protocolo
- Reportar APY actual del protocolo
- Reportar TVL bajo gestión
- **Harvest**: Claimear reward tokens (AAVE/COMP), swap a WETH via Uniswap V3, reinvertir

**Implementa:**
- `IStrategy`: Interfaz estándar (deposit, withdraw, harvest, totalAssets, apy, name, asset)

**Llama a:**
- **AaveStrategy**: `IPool.supply()`, `IPool.withdraw()`, `IPool.getReserveData()`, `IRewardsController.claimAllRewards()`, `ISwapRouter.exactInputSingle()`
- **CompoundStrategy**: `ICometMarket.supply()`, `ICometMarket.withdraw()`, `ICometMarket.balanceOf()`, `ICometMarket.getSupplyRate()`, `ICometRewards.claim()`, `ISwapRouter.exactInputSingle()`

**Es llamado por:**
- `StrategyManager`: deposit(), withdraw(), harvest()

## Flujo de Harvest

El harvest es una de las features más importantes de VynX V1. Coordina la cosecha de rewards de todos los protocolos, swap a WETH, y distribución de fees.

```
Keeper / Bot / Usuario
  └─> vault.harvest()
       │
       │ 1. Llama al strategy manager
       └─> manager.harvest()  [fail-safe: try-catch por estrategia]
            │
            ├─> aave_strategy.harvest()
            │    └─> rewards_controller.claimAllRewards([aToken])
            │    └─> Recibe AAVE tokens
            │    └─> uniswap_router.exactInputSingle(AAVE → WETH, 0.3% fee, 1% max slippage)
            │    └─> aave_pool.supply(weth, amount_out)  [auto-compound]
            │    └─> return profit_aave
            │
            ├─> compound_strategy.harvest()
            │    └─> compound_rewards.claim(comet, strategy, true)
            │    └─> Recibe COMP tokens
            │    └─> uniswap_router.exactInputSingle(COMP → WETH, 0.3% fee, 1% max slippage)
            │    └─> compound_comet.supply(weth, amount_out)  [auto-compound]
            │    └─> return profit_compound
            │
            └─> return total_profit = profit_aave + profit_compound
       │
       │ 2. Verifica profit >= min_profit_for_harvest (0.1 ETH)
       │    Si no alcanza → return 0 (no distribuye fees)
       │
       │ 3. Paga keeper incentive (solo si no es official keeper)
       │    keeper_reward = total_profit * 1% = keeper_incentive
       │    Paga desde idle_buffer primero, si no alcanza retira de estrategias
       │
       │ 4. Calcula performance fee sobre net profit
       │    net_profit = total_profit - keeper_reward
       │    perf_fee = net_profit * 20%
       │
       │ 5. Distribuye performance fee
       │    treasury: 80% del perf_fee → recibe SHARES (auto-compound)
       │    founder: 20% del perf_fee → recibe WETH (liquid)
       │
       │ 6. Actualiza contadores
       │    last_harvest = block.timestamp
       │    total_harvested += total_profit
       │
       └─> emit Harvested(total_profit, perf_fee, timestamp)
```

### Ejemplo Numérico de Harvest

**Estado**: TVL = 500 WETH. Aave tiene 250 WETH, Compound tiene 250 WETH.

```
1. Aave harvest:
   - Claimea 50 AAVE tokens acumulados
   - Swap: 50 AAVE → 2.5 WETH (via Uniswap V3, 0.3% fee)
   - Re-supply: 2.5 WETH → Aave Pool
   - profit_aave = 2.5 WETH

2. Compound harvest:
   - Claimea 100 COMP tokens acumulados
   - Swap: 100 COMP → 3.0 WETH (via Uniswap V3, 0.3% fee)
   - Re-supply: 3.0 WETH → Compound Comet
   - profit_compound = 3.0 WETH

3. total_profit = 2.5 + 3.0 = 5.5 WETH
   ✅ 5.5 >= 0.1 ETH (min_profit_for_harvest) → continúa

4. Keeper incentive (caller es keeper externo):
   keeper_reward = 5.5 * 100 / 10000 = 0.055 WETH
   → Transferido al keeper

5. Net profit y performance fee:
   net_profit = 5.5 - 0.055 = 5.445 WETH
   perf_fee = 5.445 * 2000 / 10000 = 1.089 WETH

6. Distribución de performance fee:
   treasury_amount = 1.089 * 8000 / 10000 = 0.8712 WETH → mintea shares
   founder_amount = 1.089 * 2000 / 10000 = 0.2178 WETH → transfiere WETH

7. Resultado:
   - TVL aumenta por rewards reinvertidos (5.5 WETH bruto)
   - Keeper recibe: 0.055 WETH
   - Treasury recibe: shares equivalentes a 0.8712 WETH (auto-compound)
   - Founder recibe: 0.2178 WETH (liquid)
   - Usuarios se benefician del resto del yield compuesto
```

## Flujo de Ownership

El protocolo utiliza un modelo de ownership jerárquico para control granular:

```
Owner del Vault (EOA)
    |
    +--> Vault.pause()                          # Emergency stop
    +--> Vault.setPerformanceFee()              # Ajustar performance fee
    +--> Vault.setFeeSplit()                    # Ajustar split treasury/founder
    +--> Vault.setMinDeposit()                  # Ajustar depósito mínimo
    +--> Vault.setIdleThreshold()               # Ajustar idle threshold
    +--> Vault.setMaxTVL()                      # Ajustar circuit breaker
    +--> Vault.setTreasury()                    # Cambiar treasury address
    +--> Vault.setFounder()                     # Cambiar founder address
    +--> Vault.setStrategyManager()             # Cambiar strategy manager
    +--> Vault.setOfficialKeeper()              # Agregar/remover keepers oficiales
    +--> Vault.setMinProfitForHarvest()         # Ajustar min profit para harvest
    +--> Vault.setKeeperIncentive()             # Ajustar incentivo de keepers

Owner del Manager (EOA)
    |
    +--> StrategyManager.addStrategy()          # Agregar nuevas estrategias
    +--> StrategyManager.removeStrategy()       # Remover estrategias
    +--> StrategyManager.setMaxAllocation()     # Ajustar caps
    +--> StrategyManager.setRebalanceThreshold()# Ajustar threshold de rebalance
    +--> StrategyManager.setMinTVLForRebalance()# Ajustar TVL mínimo

Vault (Contrato)
    |
    +--> StrategyManager.allocate()             # Solo vault
    +--> StrategyManager.withdrawTo()           # Solo vault
    +--> StrategyManager.harvest()              # Solo vault
         (Mediante modificador onlyVault)

StrategyManager (Contrato)
    |
    +--> AaveStrategy.deposit()                 # Solo manager
    +--> AaveStrategy.withdraw()                # Solo manager
    +--> AaveStrategy.harvest()                 # Solo manager
    +--> CompoundStrategy.deposit()             # Solo manager
    +--> CompoundStrategy.withdraw()            # Solo manager
    +--> CompoundStrategy.harvest()             # Solo manager
         (Mediante modificador onlyManager)
```

**Puntos clave:**

1. **Owner del Vault ≠ Owner del Manager**: Pueden ser diferentes EOAs para separación de concerns
2. **Solo vault puede llamar al manager**: Modificador `onlyVault` protege allocate/withdrawTo/harvest
3. **Solo manager puede llamar a strategies**: Modificador `onlyManager` protege deposit/withdraw/harvest
4. **Cualquiera puede ejecutar rebalance**: Si pasa el check de rentabilidad en `shouldRebalance()`
5. **Cualquiera puede ejecutar harvest**: Keepers externos reciben incentivo, oficiales no

## Cadena de Llamadas

### Flujo de Deposit

```
Usuario
  └─> vault.deposit(100 WETH)
       └─> IERC20(weth).transferFrom(usuario, vault, 100)
       └─> idle_buffer += 100
       └─> _mint(usuario, shares)
       └─> if (idle_buffer >= 10 ETH):
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
       └─> from_idle = min(idle_buffer, 100)
       └─> from_strategies = 100 - from_idle
       └─> if (from_strategies > 0):
            └─> manager.withdrawTo(from_strategies, vault)
                 └─> for cada estrategia:
                      └─> to_withdraw = (from_strategies * strategy_balance) / total_assets
                      └─> strategy.withdraw(to_withdraw)
                           └─> AaveStrategy: aave_pool.withdraw(weth, amount)
                           └─> CompoundStrategy: compound_comet.withdraw(weth, amount)
                      └─> IERC20(weth).transfer(strategy → manager)
                 └─> IERC20(weth).transfer(manager → vault)
       └─> Verifica rounding tolerance (< 20 wei diferencia)
       └─> IERC20(weth).transfer(vault → usuario)
```

### Flujo de Rebalance

```
Keeper / Bot / Usuario
  └─> manager.shouldRebalance()
       └─> Verifica >= 2 estrategias
       └─> Verifica TVL >= min_tvl_for_rebalance
       └─> Calcula max_apy y min_apy entre estrategias
       └─> return (max_apy - min_apy) >= rebalance_threshold
  └─> manager.rebalance()
       └─> _calculateTargetAllocation() // Recalcula targets frescos
       └─> for cada estrategia:
            └─> current_balance = strategy.totalAssets()
            └─> target_balance = (total_tvl * target) / 10000
            └─> if (current > target): Añade a exceso
            └─> if (target > current): Añade a necesidad
       └─> Para estrategias con exceso:
            └─> strategy.withdraw(excess)
       └─> Para estrategias con necesidad:
            └─> IERC20(weth).transfer(manager → strategy, amount)
            └─> strategy.deposit(amount)
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

### 3. ¿Por Qué Keeper Incentive Variable?

**Decisión**: Cualquiera puede ejecutar `harvest()` y los keepers externos reciben 1% del profit como incentivo. Los keepers oficiales no cobran.

**Razones**:
- **Descentralización**: No depende de un solo keeper para ejecutar harvest
- **Incentivo económico**: Keepers externos tienen razón económica para monitorizar y ejecutar
- **Keepers oficiales**: El protocolo puede ejecutar harvest sin pagar incentivo (ahorro para usuarios)
- **Threshold mínimo**: `min_profit_for_harvest = 0.1 ETH` previene harvests no rentables
- **Trade-off**: El 1% del profit se pierde a keepers externos, pero garantiza ejecución

**Alternativa considerada**: Solo keepers oficiales
- Pros: Sin costos de incentivo
- Contras: Punto único de fallo, harvest no se ejecuta si keeper cae

### 4. ¿Por Qué Treasury Recibe Shares y Founder Recibe WETH?

**Decisión**: Distribución asimétrica del performance fee — treasury en shares, founder en assets.

**Razones**:
- **Treasury (80% → shares)**: Auto-compound. Las shares suben de valor con cada harvest, generando más yield compuesto. Alinea incentivos del treasury con crecimiento del protocolo
- **Founder (20% → WETH)**: Liquidez inmediata para cubrir costes operativos (servidores, auditorías, desarrollo). El founder necesita liquid funds, no shares ilíquidas
- **Trade-off**: Treasury shares son ilíquidas (vender diluiría a otros holders). Founder recibe menos pero en liquid

**Alternativa considerada**: Ambos en shares o ambos en WETH
- Ambos en shares: Founder no puede cubrir costes
- Ambos en WETH: Treasury no auto-compounds, protocolo crece más lento

### 5. ¿Por Qué Tolerar Withdrawal Rounding?

**Decisión**: Tolerar hasta 20 wei de diferencia entre assets solicitados y recibidos al retirar.

**Razones**:
- **Protocolos externos redondean**: Aave y Compound pierden ~1-2 wei por operación al redondear a la baja
- **Escalabilidad**: Con 2 estrategias hoy y plan de ~10 futuras: 2 wei × 10 = 20 wei de margen conservador
- **Costo para usuario**: $0.00000000000005 con ETH a $2,500 (irrelevante)
- **Balance before/after pattern**: Las strategies miden `balance_after - balance_before` para capturar el monto realmente retirado
- **Trade-off**: El usuario asume el costo del redondeo (estándar en DeFi)

**Alternativa considerada**: Requerir exactitud estricta
- Pros: Accounting perfecto
- Contras: Reverts frecuentes por 1 wei, UX terrible, transacciones fallan

### 6. ¿Por Qué Interfaz Custom Compound vs Librería Oficial?

**Decisión**: Crear interfaces custom (`ICometMarket.sol`, `ICometRewards.sol`) en lugar de usar las librerías oficiales de Compound.

**Razones**:
- **Simplicidad**: Solo necesitamos las funciones que usamos
- **Librerías oficiales sucias**: Dependencias complejas, versiones indexadas, estructura pesada
- **Consistencia parcial**: Aave tiene librerías limpias (las usamos), Compound no (interfaz custom)
- **Trade-off**: Inconsistencia (Aave = librerías, Compound = interfaz) vs pragmatismo

**Comparación Aave**:
- Aave: `@aave/contracts/interfaces/IPool.sol` - limpia y directa
- Compound: Librerías oficiales con dependencias innecesarias

### 7. ¿Por Qué Rebalancing Basado en Diferencia de APY?

**Decisión**: Rebalancear cuando `max_apy - min_apy >= rebalance_threshold` (2%), sin cálculo de gas cost on-chain.

**Razones**:
- **Simplicidad**: Fórmula simple y predecible, fácil de auditar
- **Efectividad**: Si la diferencia de APY es significativa, mover fondos vale la pena independientemente del gas
- **Gas-efficient**: No necesita `tx.gasprice` on-chain ni estimaciones complejas de gas
- **Trade-off**: Podría ejecutar rebalances con gas alto (pero el threshold del 2% ya filtra casos no rentables)

**Alternativa considerada**: Cálculo profit vs gas cost on-chain (multi-strategy-vault)
- Pros: Más preciso
- Contras: Más complejo, más gas por la propia comprobación, `tx.gasprice` no siempre fiable

## Flujo de WETH

### Estados del WETH en el Sistema

```
1. Usuario EOA
   └─> WETH en wallet del usuario

2. Idle Buffer (vault.idle_buffer)
   └─> Balance físico en Vault
   └─> No genera yield
   └─> Accounting: vault.idle_buffer (variable de estado)

3. En Manager (temporal)
   └─> Balance físico en StrategyManager (solo durante allocate/rebalance)
   └─> Inmediatamente transferido a estrategias

4. En Estrategias
   ├─> AaveStrategy:
   │    └─> Balance físico en Aave Pool
   │    └─> Accounting: a_token.balanceOf(strategy) (aTokens, hacen rebase automático)
   │    └─> Yield: Incluido automáticamente en aToken balance
   │    └─> Rewards: AAVE tokens (claimeados durante harvest)
   │
   └─> CompoundStrategy:
        └─> Balance físico en Compound Comet
        └─> Accounting: compound_comet.balanceOf(strategy) (interno, no token)
        └─> Yield: Incluido automáticamente en balance interno
        └─> Rewards: COMP tokens (claimeados durante harvest)

5. Uniswap V3 (temporal, durante harvest)
   └─> AAVE/COMP → WETH swap
   └─> 0.3% pool fee, max 1% slippage
   └─> WETH resultante se re-invierte en el protocolo

6. De vuelta al Usuario
   └─> WETH en wallet del usuario (neto)
```

### Accounting vs Balance Físico

Es crucial entender que **totalAssets() es accounting, no balance físico**:

```solidity
// Vault.totalAssets()
function totalAssets() public view returns (uint256) {
    return idle_buffer + IStrategyManager(strategy_manager).totalAssets();
    // idle_buffer: Balance pendiente de invertir
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
    return a_token.balanceOf(address(this));
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
1. `vault.idle_buffer = 100` (físico en vault)
2. `vault.totalAssets() = 100` (accounting)

Idle alcanza threshold, allocate:
1. `vault.idle_buffer = 0` (físico movido a manager → estrategias)
2. `aave_strategy balance = 50 aWETH` (físico en Aave)
3. `compound_strategy balance = 50 WETH` (físico en Compound)
4. `vault.totalAssets() = 0 + manager.totalAssets() = 100` (accounting)

Después de 1 mes (yield del 5% APY):
1. `aave_strategy.totalAssets() = 50.2` (aWETH rebase incluye yield)
2. `compound_strategy.totalAssets() = 50.2` (balance interno incluye yield)
3. `vault.totalAssets() = 0 + 100.4 = 100.4` (accounting refleja yield)
4. Usuario puede retirar 100.4 WETH (shares = 100 en precio de entrada, valen más ahora)

Harvest ejecutado (rewards acumulados):
1. AaveStrategy claimea AAVE tokens → swap a 2.5 WETH → re-supply a Aave
2. CompoundStrategy claimea COMP tokens → swap a 3.0 WETH → re-supply a Compound
3. total_profit = 5.5 WETH (reinvertido, totalAssets sube)
4. Performance fee distribuido: treasury (shares), founder (WETH)

## Limitaciones Conocidas

1. **Solo WETH**: Arquitectura actual no soporta multi-asset (planificado para v2)
2. **Rebalancing manual**: Requiere keepers externos (no automático on-chain)
3. **Weighted allocation v1**: Algoritmo básico proporcional a APY (machine learning en v3?)
4. **Single vault owner**: Centralización del ownership (multisig en producción)
5. **Idle buffer sin yield**: WETH acumulado no genera rendimiento
6. **Treasury shares ilíquidas**: El treasury recibe shares que no puede vender fácilmente sin diluir a holders
7. **Harvest depende de liquidez Uniswap**: Si no hay liquidez AAVE/WETH o COMP/WETH, el swap falla
8. **Max 10 estrategias**: Límite hard-coded en StrategyManager para prevenir gas DoS en loops

---

**Siguiente lectura**: [CONTRACTS.md](CONTRACTS.md) - Documentación detallada por contrato
