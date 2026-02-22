# Arquitectura del Sistema

Este documento describe la arquitectura de alto nivel de VynX V2, explicando la jerarquía de contratos, el flujo de ownership, las decisiones de diseño clave, el Router periférico multi-token y cómo circula el WETH a través del sistema.

## Visión General

### ¿Qué Problema Resuelve?

Los usuarios que quieren maximizar su yield en DeFi enfrentan varios desafíos:

1. **Complejidad**: Gestionar posiciones en múltiples protocolos (Lido, Aave, Curve, Uniswap V3) requiere conocimiento técnico profundo
2. **Monitoreo constante**: Los APYs fluctúan y hay que rebalancear manualmente para optimizar rendimientos
3. **Costes de gas**: Mover fondos entre protocolos es caro, especialmente para holdings pequeños
4. **Riesgo de protocolo único**: Estar 100% en un solo protocolo aumenta el riesgo
5. **Rewards sin cosechar**: Protocolos como Curve y Aave emiten reward tokens que hay que claimear, swapear y reinvertir manualmente
6. **Yield stacking**: Estrategias como Aave wstETH combinan Lido staking + Aave lending pero son difíciles de gestionar manualmente

VynX V2 resuelve estos problemas mediante:

- **Agregación automatizada**: Los usuarios depositan una vez y el protocolo gestiona múltiples estrategias
- **Weighted allocation**: Distribución inteligente basada en APY (mayor rendimiento = mayor porcentaje)
- **Rebalancing inteligente**: Solo ejecuta cuando la diferencia de APY entre estrategias supera el threshold configurado por tier
- **Idle buffer**: Acumula depósitos pequeños para amortizar gas entre múltiples usuarios
- **Diversificación**: Reparte riesgo entre estrategias con límites configurables por tier
- **Harvest automatizado**: Cosecha rewards (CRV, AAVE), swap a WETH via Uniswap V3, reinversión automática
- **Keeper incentive system**: Cualquiera puede ejecutar harvest y recibir 1% del profit como incentivo
- **Dos tiers de riesgo**: Balanced (conservador) y Aggressive (mayor rendimiento potencial)

### Tiers de Riesgo

VynX V2 se despliega en **dos vaults independientes**, cada uno con su propio StrategyManager y conjunto de estrategias:

| Tier       | Estrategias                          | Máx. Alloc/Estrategia | Mín. Alloc/Estrategia |
| ---------- | ------------------------------------ | --------------------- | --------------------- |
| Balanced   | LidoStrategy + AaveStrategy + Curve  | 50%                   | 20%                   |
| Aggressive | CurveStrategy + UniswapV3Strategy    | 70%                   | 10%                   |

Cada vault tiene su propio `TierConfig` que parametriza el comportamiento:

```solidity
struct TierConfig {
    uint256 max_allocation_per_strategy;  // Balanced: 5000 bp | Aggressive: 7000 bp
    uint256 min_allocation_threshold;     // Balanced: 2000 bp | Aggressive: 1000 bp
    uint256 rebalance_threshold;          // Balanced: 200 bp  | Aggressive: 300 bp
    uint256 min_tvl_for_rebalance;        // Balanced: 8 ETH   | Aggressive: 12 ETH
}
```

### Arquitectura de Alto Nivel

```
Usuario (EOA)
    |
    |─── deposit(WETH) / withdraw(WETH) ──────────────────────────┐
    |                                                              |
    | zapDepositETH() / zapDepositERC20()                          |
    | zapWithdrawETH() / zapWithdrawERC20()                        |
    v                                                              |
┌─────────────────────────────────────────────────────┐            |
│              Router (Periphery)                     │            |
│  - Wrap ETH → WETH                                  │            |
│  - Swap ERC20 → WETH (Uniswap V3)                  │            |
│  - Swap WETH → ERC20 (Uniswap V3)                  │            |
│  - Unwrap WETH → ETH                                │            |
│  - Stateless (nunca retiene fondos)                 │            |
│  - ReentrancyGuard + slippage protection            │            |
└─────────────────────────────────────────────────────┘            |
    |                                                              |
    | vault.deposit(WETH) / vault.redeem(shares)                   |
    v                                                              v
┌───────────────────────────────────────────────────────────────┐
│                      Vault (ERC4626)                          │
│  - Mintea/quema shares (vxWETH)                               │
│  - Idle buffer configurable por tier (8-12 ETH)               │
│  - Performance fee (20% sobre profits de harvest)             │
│  - Keeper incentive system (1% para keepers ext.)             │
│  - Circuit breakers (max TVL, min deposit)                    │
└───────────────────────────────────────────────────────────────┘
    |                                       |
    | allocate(WETH) / withdrawTo(WETH)     | harvest()
    v                                       v
┌───────────────────────────────────────────────────────────────┐
│                  StrategyManager (Cerebro)                    │
│  - Calcula weighted allocation basado en APY                  │
│  - Distribuye según targets calculados                        │
│  - Ejecuta rebalanceos rentables                              │
│  - Retira proporcionalmente                                   │
│  - Coordina harvest fail-safe de todas las estrategias        │
└───────────────────────────────────────────────────────────────┘
    |
    ├── TIER BALANCED ──────────────────────────────────────────┐
    |                                                           |
    v                   v                   v                   |
┌──────────────┐  ┌──────────────┐  ┌──────────────┐           |
│LidoStrategy  │  │AaveStrategy  │  │CurveStrategy │           |
│ APY: 4%      │  │APY: dinámico │  │ APY: 6%      │           |
│ harvest: 0   │  │(Aave rate)   │  │ harvest: CRV │           |
└──────────────┘  └──────────────┘  └──────────────┘           |
    |                   |                   |                   |
    v                   v                   v                   |
┌──────────────┐  ┌──────────────┐  ┌──────────────┐           |
│  Lido +      │  │  Lido +      │  │ Curve pool   │           |
│  wstETH      │  │  Aave wstETH │  │ + gauge      │           |
└──────────────┘  └──────────────┘  └──────────────┘           |
                                                                |
    ├── TIER AGGRESSIVE ────────────────────────────────────────┘
    |
    v                       v
┌──────────────┐      ┌──────────────────────┐
│CurveStrategy │      │ UniswapV3Strategy    │
│ APY: 6%      │      │ APY: 14% (variable)  │
│ harvest: CRV │      │ harvest: fees LP     │
└──────────────┘      └──────────────────────┘
    |                       |
    v                       v
┌──────────────┐      ┌──────────────────────┐
│ Curve pool   │      │ WETH/USDC pool 0.05% │
│ stETH/ETH    │      │ NFT position ±10%    │
│ + gauge CRV  │      └──────────────────────┘
└──────────────┘
```

## Jerarquía de Contratos

### 1. Vault.sol (Capa de Usuario)

**Responsabilidades:**
- Interfaz ERC4626 para usuarios (deposit, withdraw, mint, redeem)
- Gestión del idle buffer (acumulación de WETH pendiente de invertir)
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
- Ejecutar rebalanceos cuando son rentables (threshold configurable)
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
- Cualquiera: rebalance() (si pasa el check de rentabilidad)

### 3. Router.sol (Capa Periférica)

**Responsabilidades:**
- Punto de entrada multi-token para usuarios que no tienen WETH
- Wrap ETH → WETH y deposit en el vault en una sola transacción
- Swap ERC20 → WETH via Uniswap V3 y deposit en el vault
- Redeem shares → unwrap WETH → ETH y enviar al usuario
- Redeem shares → swap WETH → ERC20 via Uniswap V3 y enviar al usuario
- Garantizar diseño stateless (nunca retiene fondos)

**Hereda de:**
- `IRouter`: Interfaz del Router (eventos y funciones)
- `ReentrancyGuard` (OpenZeppelin): Protección contra reentrancy

**Llama a:**
- `IERC4626(vault).deposit()`: Para depositar WETH en el vault
- `IERC4626(vault).redeem()`: Para redimir shares del vault
- `ISwapRouter(uniswap).exactInputSingle()`: Para swaps ERC20 ↔ WETH
- `WETH.deposit()` / `WETH.withdraw()`: Para wrap/unwrap ETH

**Es llamado por:**
- Usuarios (EOAs o contratos): zapDepositETH, zapDepositERC20, zapWithdrawETH, zapWithdrawERC20

**Nota importante**: El Router es un usuario normal del Vault — no tiene privilegios especiales. Cualquiera puede interactuar directamente con el Vault si tiene WETH.

### 4. Estrategias (Capa de Integración)

Todas las estrategias implementan `IStrategy` con la misma interfaz: `deposit`, `withdraw`, `harvest`, `totalAssets`, `apy`, `name`, `asset`.

#### LidoStrategy.sol
**Propósito:** Staking líquido con auto-compounding via wstETH.

**Flujo de depósito:**
```
WETH → unwrap → ETH → Lido.submit() → stETH → wstETH.wrap() → hold wstETH
```

**Flujo de retiro:**
```
wstETH → Uniswap V3 swap (wstETH→WETH, 0.05% fee) → WETH → manager
```

**Harvest:** Siempre retorna 0. El yield está embebido en el tipo de cambio wstETH/stETH, que crece automáticamente sin necesidad de harvest activo.

**APY:** 4% hardcodeado (400 bp). Refleja el APY histórico de Lido staking.

#### AaveStrategy.sol (wstETH)
**Propósito:** Doble yield — Lido staking (4%) + Aave lending (~3.5%) sobre wstETH.

**Flujo de depósito:**
```
WETH → ETH → Lido → stETH → wstETH.wrap() → Aave.supply(wstETH) → aWstETH
```

**Flujo de retiro:**
```
Aave.withdraw(wstETH) → aWstETH burned → wstETH → unwrap → stETH
→ Curve stETH/ETH.exchange() → ETH → WETH.deposit() → WETH → manager
```

**Harvest:**
```
RewardsController.claimAllRewards([aWstETH]) → AAVE tokens
→ Uniswap exactInputSingle(AAVE→WETH, 0.3% fee) → WETH
→ WETH → ETH → wstETH → Aave.supply() [auto-compound]
→ return profit_weth
```

**APY:** Dinámico — lee `IPool.getReserveData(wstETH).liquidityRate` de Aave v3 y convierte de RAY (27 decimales) a basis points.

#### CurveStrategy.sol
**Propósito:** Liquidez en el pool stETH/ETH de Curve más rewards de gauge CRV.

**Flujo de depósito:**
```
WETH → ETH → Lido.submit() → stETH
→ CurvePool.add_liquidity([ETH, stETH]) → LP tokens
→ CurveGauge.deposit(LP) → gauge deposited
```

**Flujo de retiro:**
```
CurveGauge.withdraw(LP) → LP tokens
→ CurvePool.remove_liquidity_one_coin(LP, 0) → ETH
→ WETH.deposit() → WETH → manager
```

**Harvest:**
```
CurveGauge.claim_rewards() → CRV tokens
→ Uniswap exactInputSingle(CRV→WETH, 0.3% fee) → WETH
→ WETH → ETH → stETH → add_liquidity → LP → gauge.deposit() [auto-compound]
→ return profit_weth
```

**APY:** 6% hardcodeado (600 bp). Estimado de ~1-2% en trading fees + ~4% en rewards CRV del gauge.

#### UniswapV3Strategy.sol
**Propósito:** Liquidez concentrada en el pool WETH/USDC 0.05% de Uniswap V3.

**Flujo de depósito:**
```
WETH → swap 50% WETH→USDC (Uniswap exactInputSingle, 0.05% fee)
→ si sin posición: positionManager.mint(tickLower, tickUpper, WETH, USDC) → tokenId guardado
→ si posición existente: positionManager.increaseLiquidity(tokenId, WETH, USDC)
```

**Flujo de retiro:**
```
positionManager.decreaseLiquidity(tokenId, proportional_liquidity)
→ positionManager.collect(tokenId) → WETH + USDC
→ si liquidez = 0: positionManager.burn(tokenId), token_id = 0
→ swap USDC→WETH (Uniswap exactInputSingle) → todo en WETH
→ WETH → manager
```

**Harvest:**
```
positionManager.collect(tokenId) → WETH + USDC (fees acumulados)
→ swap USDC→WETH → todo en WETH → registra como profit
→ swap 50% WETH→USDC → positionManager.increaseLiquidity() [auto-compound]
→ return profit_weth
```

**APY:** 14% hardcodeado (1400 bp). Altamente variable según volumen del pool. Estimado histórico.

**Nota sobre la posición NFT:** La estrategia mantiene UNA posición NFT (`token_id`). El rango de ticks se calcula una sola vez en el constructor: tick actual ± 960 ticks (≈ ±10% de precio). Si la posición se vacía completamente, el NFT se quema y `token_id` se resetea a 0.

## Flujo de Harvest

El harvest en V2 varía por estrategia. El StrategyManager coordina con fail-safe (try-catch) para que si una estrategia falla, las demás continúan.

```
Keeper / Bot / Usuario
  └─> vault.harvest()
       │
       │ 1. Llama al strategy manager
       └─> manager.harvest()  [fail-safe: try-catch por estrategia]
            │
            ├─> lido_strategy.harvest()
            │    └─> return 0  (yield auto-compuesto en tipo de cambio wstETH)
            │
            ├─> aave_strategy.harvest()
            │    └─> rewards_controller.claimAllRewards([aWstETH])
            │    └─> Recibe AAVE tokens
            │    └─> uniswap_router.exactInputSingle(AAVE → WETH, 0.3% fee)
            │    └─> WETH → wstETH → aave_pool.supply(wstETH)  [auto-compound]
            │    └─> return profit_aave
            │
            ├─> curve_strategy.harvest()
            │    └─> gauge.claim_rewards()
            │    └─> Recibe CRV tokens
            │    └─> uniswap_router.exactInputSingle(CRV → WETH, 0.3% fee)
            │    └─> WETH → ETH → stETH → pool.add_liquidity → gauge  [auto-compound]
            │    └─> return profit_curve
            │
            └─> return total_profit (suma de los que hayan tenido éxito)
       │
       │ 2. Verifica profit >= min_profit_for_harvest (Balanced: 0.08 ETH, Aggressive: 0.12 ETH)
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

### Ejemplo Numérico de Harvest (Tier Balanced)

**Estado**: TVL = 500 WETH. Lido: 200 WETH, Aave wstETH: 200 WETH, Curve: 100 WETH.

```
1. Lido harvest:
   - return 0 (yield embebido en wstETH exchange rate)
   - profit_lido = 0

2. Aave harvest:
   - Claimea 50 AAVE tokens acumulados
   - Swap: 50 AAVE → 2.0 WETH (via Uniswap V3, 0.3% fee)
   - Re-supply: 2.0 WETH → wstETH → Aave Pool
   - profit_aave = 2.0 WETH

3. Curve harvest:
   - Claimea 200 CRV tokens acumulados
   - Swap: 200 CRV → 1.5 WETH (via Uniswap V3, 0.3% fee)
   - Re-invierte: 1.5 WETH → ETH → stETH → add_liquidity → gauge
   - profit_curve = 1.5 WETH

4. total_profit = 0 + 2.0 + 1.5 = 3.5 WETH
   ✅ 3.5 >= 0.08 ETH (min_profit_for_harvest Balanced) → continúa

5. Keeper incentive (caller es keeper externo):
   keeper_reward = 3.5 * 100 / 10000 = 0.035 WETH
   → Transferido al keeper

6. Net profit y performance fee:
   net_profit = 3.5 - 0.035 = 3.465 WETH
   perf_fee = 3.465 * 2000 / 10000 = 0.693 WETH

7. Distribución de performance fee:
   treasury_amount = 0.693 * 8000 / 10000 = 0.5544 WETH → mintea shares
   founder_amount = 0.693 * 2000 / 10000 = 0.1386 WETH → transfiere WETH

8. Resultado:
   - Keeper recibe: 0.035 WETH
   - Treasury recibe: shares equivalentes a 0.5544 WETH (auto-compound)
   - Founder recibe: 0.1386 WETH (liquid)
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
    +--> LidoStrategy.deposit/withdraw/harvest  # Solo manager
    +--> AaveStrategy.deposit/withdraw/harvest  # Solo manager
    +--> CurveStrategy.deposit/withdraw/harvest # Solo manager
    +--> UniswapV3Strategy.deposit/withdraw/harvest # Solo manager
         (Mediante modificador onlyManager)
```

**Puntos clave:**

1. **Owner del Vault ≠ Owner del Manager**: Pueden ser diferentes EOAs para separación de concerns
2. **Solo vault puede llamar al manager**: Modificador `onlyVault` protege allocate/withdrawTo/harvest
3. **Solo manager puede llamar a strategies**: Modificador `onlyManager` protege deposit/withdraw/harvest
4. **Cualquiera puede ejecutar rebalance**: Si pasa el check de rentabilidad en `shouldRebalance()`
5. **Cualquiera puede ejecutar harvest**: Keepers externos reciben incentivo, oficiales no
6. **Router sin privilegios**: El Router es un usuario normal del Vault, sin ownership ni permisos especiales

## Cadena de Llamadas

### Flujo de Deposit

```
Usuario
  └─> vault.deposit(100 WETH)
       └─> IERC20(weth).transferFrom(usuario, vault, 100)
       └─> idle_buffer += 100
       └─> _mint(usuario, shares)
       └─> if (idle_buffer >= idle_threshold [8-12 ETH]):
            └─> _allocateIdle()
                 └─> IERC20(weth).transfer(manager, idle_buffer)
                 └─> manager.allocate(idle_buffer)
                      └─> _calculateTargetAllocation()
                           └─> _computeTargets() // APY-based weighted allocation
                      └─> for cada estrategia:
                           └─> IERC20(weth).transfer(strategy, target_amount)
                           └─> strategy.deposit(target_amount)
                                └─> LidoStrategy: ETH → wstETH
                                └─> AaveStrategy: ETH → wstETH → Aave.supply()
                                └─> CurveStrategy: ETH → stETH → pool.add_liquidity() → gauge
                                └─> UniswapV3Strategy: swap 50%→USDC → mint/increase position
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
                           └─> LidoStrategy: wstETH → swap WETH (Uniswap)
                           └─> AaveStrategy: Aave.withdraw → wstETH → stETH → Curve → ETH → WETH
                           └─> CurveStrategy: gauge.withdraw → pool.remove_liquidity → ETH → WETH
                           └─> UniswapV3Strategy: decreaseLiquidity → collect → swap USDC→WETH
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
       └─> Verifica TVL >= min_tvl_for_rebalance (8 o 12 ETH según tier)
       └─> Calcula max_apy y min_apy entre estrategias
       └─> return (max_apy - min_apy) >= rebalance_threshold (200 o 300 bp según tier)
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

### 1. ¿Por Qué Dos Tiers vs Un Solo Vault?

**Decisión**: Desplegar dos vaults independientes (Balanced y Aggressive) en lugar de un único vault con todas las estrategias.

**Razones**:
- **Perfiles de riesgo distintos**: Usuarios conservadores no deberían estar expuestos a UniswapV3 (IL concentrado). Usuarios agresivos no necesariamente quieren el rendimiento más bajo de Lido
- **Parámetros diferentes**: Cada tier necesita distintos `idle_threshold`, `rebalance_threshold`, `max_allocation`
- **Simplicidad operativa**: Cada vault es autónomo y auditable independientemente
- **Trade-off**: El protocolo gestiona dos instancias en lugar de una; la liquidez no está consolidada

### 2. ¿Por Qué Weighted Allocation vs All-or-Nothing?

**Decisión**: Usar weighted allocation proporcional al APY en lugar de 100% en la mejor estrategia.

**Razones**:
- **Diversificación de riesgo**: Si una estrategia tiene un exploit, solo perdemos la parte asignada
- **Liquidez**: Algunos protocolos no pueden absorber todo el TVL
- **Trade-off**: Se sacrifica rendimiento marginal por mayor seguridad y robustez

### 3. ¿Por Qué Idle Buffer vs Deposit Directo?

**Decisión**: Acumular depósitos en un buffer hasta alcanzar 8-12 ETH antes de invertir.

**Razones**:
- **Optimización de gas**: Un allocate para N usuarios vs N allocates separados
- **Coste compartido**: Los usuarios comparten el gas de allocation proporcionalmente
- **Retiros eficientes**: Si hay idle, los retiros pequeños no tocan estrategias (ahorro masivo)
- **Trade-off**: WETH en idle buffer no genera yield durante acumulación

**Análisis de break-even:**
- Allocate cost: ~300k gas × 50 gwei = 0.015 ETH
- Si 10 usuarios depositan 0.8 ETH cada uno: 0.015 / 10 = 0.0015 ETH por usuario
- vs cada usuario pagando 0.015 ETH: Ahorro del 90%

### 4. ¿Por Qué LidoStrategy Harvest Retorna 0?

**Decisión**: No implementar harvest activo en LidoStrategy; el yield crece automáticamente en el tipo de cambio wstETH/stETH.

**Razones**:
- **Funcionamiento de wstETH**: El wstETH es un token con exchange rate creciente — cada wstETH vale más stETH con el tiempo. No hay rewards a claimear externamente
- **Gas efficiency**: Sin harvest activo, sin transacciones de claim ni swap
- **Trade-off**: La función harvest() existe por compatibilidad con IStrategy pero retorna 0. El yield real se captura al momento del withdraw (el wstETH se convierte a WETH a tipo de cambio actualizado)

### 5. ¿Por Qué AaveStrategy Deposita wstETH y No WETH Directo?

**Decisión**: Convertir WETH → wstETH antes de depositar en Aave, en lugar de depositar WETH directamente.

**Razones**:
- **Doble yield**: wstETH en Aave genera Lido staking yield (~4%) + Aave lending yield (~3.5%) simultáneamente
- **Complejidad adicional**: El withdraw es más complejo (Aave → wstETH → stETH → Curve → ETH → WETH)
- **Trade-off**: Mayor yield total a cambio de mayor complejidad y riesgo apilado

### 6. ¿Por Qué Keeper Incentive Variable?

**Decisión**: Cualquiera puede ejecutar `harvest()` y los keepers externos reciben 1% del profit como incentivo. Los keepers oficiales no cobran.

**Razones**:
- **Descentralización**: No depende de un solo keeper para ejecutar harvest
- **Incentivo económico**: Keepers externos tienen razón económica para monitorizar y ejecutar
- **Threshold mínimo**: `min_profit_for_harvest` (0.08-0.12 ETH) previene harvests no rentables
- **Trade-off**: El 1% del profit se pierde a keepers externos, pero garantiza ejecución

### 7. ¿Por Qué Treasury Recibe Shares y Founder Recibe WETH?

**Decisión**: Distribución asimétrica del performance fee — treasury en shares, founder en assets.

**Razones**:
- **Treasury (80% → shares)**: Auto-compound. Las shares suben de valor con cada harvest, generando más yield compuesto. Alinea incentivos del treasury con crecimiento del protocolo
- **Founder (20% → WETH)**: Liquidez inmediata para cubrir costes operativos. El founder necesita liquid funds
- **Trade-off**: Treasury shares son ilíquidas. Founder recibe menos pero en liquid

### 8. ¿Por Qué Router Periférico vs Multi-Asset Vault?

**Decisión**: Crear un Router separado que swapea tokens a WETH antes de depositar, en lugar de modificar el Vault para aceptar múltiples assets directamente.

**Razones**:
- **Vault puro**: El Vault sigue siendo un ERC4626 estándar con un solo asset (WETH), fácil de auditar
- **Separación de concerns**: La complejidad del swap vive en un contrato separado sin fondos custodiados
- **Sin riesgo adicional al Vault**: Si el Router tiene un bug, el Vault y los fondos no se ven afectados
- **Composabilidad**: El Router es un usuario más del Vault, otros contratos pueden integrarse directamente
- **Trade-off**: El usuario paga slippage del swap en Uniswap V3 (0.05%-1% dependiendo del pool)

### 9. ¿Por Qué Router Stateless?

**Decisión**: El Router nunca retiene fondos entre transacciones. Verifica balance 0 al final de cada operación.

**Razones**:
- **Seguridad**: Si el Router es explotado, no hay fondos que robar
- **Simplicidad**: No hay estado que gestionar ni invariantes de balance que mantener
- **Gas**: Sin storage writes para tracking de balances

**Patrón**:
```solidity
// Al final de cada función:
if (IERC20(weth).balanceOf(address(this)) != 0) revert Router__FundsStuck();
```

### 10. ¿Por Qué Posición Única en UniswapV3Strategy?

**Decisión**: Mantener una sola posición NFT con rango fijo (±960 ticks ≈ ±10%) en lugar de múltiples rangos.

**Razones**:
- **Simplicidad**: Un solo tokenId que gestionar, un solo rango
- **Gas efficiency**: Cada increase/decrease afecta a una posición, no a N
- **Trade-off**: Si el precio sale del rango ±10%, la posición deja de generar fees hasta que vuelva. El rango amplio reduce este riesgo vs rangos más estrechos que maximizan APY pero son más volátiles

## Flujo de WETH

### Estados del WETH en el Sistema

```
0. Router (temporal, stateless)
   └─> ETH recibido → wrap a WETH → deposit en vault (no retiene)
   └─> ERC20 recibido → swap a WETH (Uniswap V3) → deposit en vault (no retiene)
   └─> Shares redimidas → WETH recibido → unwrap a ETH → enviar al usuario
   └─> Shares redimidas → WETH recibido → swap a ERC20 (Uniswap V3) → enviar al usuario

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
   ├─> LidoStrategy:
   │    └─> Balance efectivo: wstETH.balanceOf(strategy) × wstETH/ETH exchange rate
   │    └─> Yield: Incluido automáticamente en tipo de cambio wstETH
   │    └─> Sin rewards externos
   │
   ├─> AaveStrategy (wstETH):
   │    └─> Balance efectivo en Aave Pool como aWstETH
   │    └─> Yield: Lido staking (exchange rate wstETH) + Aave lending (aToken rebase)
   │    └─> Rewards: AAVE tokens (claimeados durante harvest)
   │
   ├─> CurveStrategy:
   │    └─> Balance efectivo: LP tokens stakeados en gauge (virtual price crece con trading fees)
   │    └─> Yield: Trading fees del pool (acumulados en virtual price)
   │    └─> Rewards: CRV tokens del gauge (claimeados durante harvest)
   │
   └─> UniswapV3Strategy:
        └─> Balance efectivo: valor WETH-equivalente de la posición LP (weth + usdc × precio)
        └─> Yield: Trading fees del pool 0.05% WETH/USDC
        └─> Rewards: Fees en WETH y USDC (colectados durante harvest o withdraw)

5. Uniswap V3 (temporal, durante harvest/retiro)
   └─> AAVE/CRV → WETH swap (harvest de AaveStrategy y CurveStrategy)
   └─> wstETH → WETH swap (withdraw de LidoStrategy)
   └─> USDC → WETH o WETH → USDC (UniswapV3Strategy)

6. De vuelta al Usuario
   └─> WETH en wallet del usuario (neto)
```

### Accounting vs Balance Físico

Es crucial entender que **totalAssets() es accounting, no balance físico**:

```solidity
// Vault.totalAssets()
function totalAssets() public view returns (uint256) {
    return idle_buffer + IStrategyManager(strategy_manager).totalAssets();
}

// StrategyManager.totalAssets()
function totalAssets() public view returns (uint256) {
    uint256 total = 0;
    for (uint256 i = 0; i < strategies.length; i++) {
        total += strategies[i].totalAssets();
    }
    return total;
}

// LidoStrategy.totalAssets() — valor WETH de wstETH a tipo de cambio actual
function totalAssets() external view returns (uint256) {
    return IWstETH(wsteth).getStETHByWstETH(wstEthBalance());
}

// AaveStrategy.totalAssets() — aWstETH balance × tipo de cambio wstETH
function totalAssets() external view returns (uint256) {
    uint256 a_wst_eth_balance = IERC20(a_wst_eth).balanceOf(address(this));
    return IWstETH(wst_eth).getStETHByWstETH(a_wst_eth_balance);
}

// CurveStrategy.totalAssets() — LP × virtual_price (en ETH equivalente)
function totalAssets() external view returns (uint256) {
    uint256 lp = ICurveGauge(gauge).balanceOf(address(this));
    return FullMath.mulDiv(lp, ICurvePool(pool).get_virtual_price(), 1e18);
}

// UniswapV3Strategy.totalAssets() — calcula WETH equivalente de la posición NFT
function totalAssets() external view returns (uint256) {
    // Usa LiquidityAmounts + sqrtPriceX96 del pool para calcular WETH + USDC,
    // luego convierte USDC a WETH usando el precio actual del pool
    return _totalAssets();
}
```

## Limitaciones Conocidas

1. **Solo WETH en el Vault**: El Vault solo acepta WETH nativamente. Otros tokens requieren pasar por el Router
2. **Rebalancing manual**: Requiere keepers externos (no automático on-chain)
3. **Weighted allocation v1**: Algoritmo básico proporcional a APY
4. **Single vault owner**: Centralización del ownership (multisig recomendado en producción)
5. **Idle buffer sin yield**: WETH acumulado no genera rendimiento durante el periodo de acumulación
6. **Treasury shares ilíquidas**: El treasury recibe shares que no puede vender fácilmente sin diluir a holders
7. **Harvest depende de liquidez Uniswap**: Si no hay liquidez AAVE/WETH o CRV/WETH, el swap falla (fail-safe: la estrategia afectada no contribuye al profit ese harvest)
8. **Max 10 estrategias**: Límite hard-coded en StrategyManager para prevenir gas DoS en loops
9. **Router depende de liquidez Uniswap V3**: Si no hay pool para un token con WETH, el Router no puede operar con ese token
10. **UniswapV3 out-of-range**: Si el precio sale del rango ±10%, la posición deja de generar fees (comportamiento esperado de Uniswap V3 concentrado, no verificado en tests)
11. **APYs hardcodeados en Lido, Curve y UniswapV3**: Solo AaveStrategy lee el APY on-chain. Los APYs hardcodeados en las demás estrategias son estimados históricos que pueden diferir de la realidad

---

**Siguiente lectura**: [CONTRACTS.md](CONTRACTS.md) - Documentación detallada por contrato
