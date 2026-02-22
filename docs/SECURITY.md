# Consideraciones de Seguridad

Este documento analiza la postura de seguridad de VynX V2, incluyendo trust assumptions, vectores de ataque considerados, protecciones implementadas, puntos de centralización y limitaciones conocidas.

---

## 1. Trust Assumptions (En Qué Confiamos)

El protocolo VynX V2 **confía explícitamente** en los siguientes componentes externos:

### Lido (staking protocol)

**Nivel de confianza**: Alto

**Razones:**
- Protocolo de liquid staking más auditado de Ethereum
- Battle-tested con >$30B TVL en mainnet
- Bug bounty activo (Immunefi) y código verificado
- Historial de seguridad robusto sin hacks críticos al protocolo base

**Riesgos aceptados:**
- Si Lido sufre un exploit, los fondos stakeados como stETH/wstETH estarían en riesgo
- Slashing de validadores reduce el balance de stETH (impacto histórico < 0.01% del supply)
- Depeg de stETH en mercado secundario puede afectar swaps de salida
- Mitigación: Solo el tier Balanced usa LidoStrategy/AaveStrategy. El idle buffer (8 ETH mínimo) absorbe retiros pequeños.

### Aave v3

**Nivel de confianza**: Alto

**Razones:**
- Auditado múltiples veces por Trail of Bits, OpenZeppelin, Consensys Diligence, etc.
- Battle-tested con >$5B TVL en mainnet durante años
- Historial de seguridad robusto (sin hacks mayores)
- Código open-source revisado por comunidad

**Riesgos aceptados:**
- Si Aave sufre un exploit, podríamos perder fondos depositados en AaveStrategy
- AaveStrategy solo hace supply de wstETH (sin borrowing) — no existe riesgo de liquidación
- Mitigación: Solo presente en tier Balanced; allocation limitada por parámetros del tier

### Curve (AMM + gauge)

**Nivel de confianza**: Alto

**Razones:**
- AMM más establecido para activos correlacionados (stablecoins, LSTs)
- Auditado extensivamente por múltiples firmas
- El pool stETH/ETH usa Vyper >= 0.3.1 (no afectado por el bug de julio 2023)
- Los gauges de Curve son aprobados por governance antes de ser activados

**Riesgos aceptados:**
- Si Curve sufre un exploit, los fondos en CurveStrategy (LP + gauge) estarían en riesgo
- Impermanent loss bajo para el par stETH/ETH en condiciones normales
- Mitigación: CurveStrategy opera en ambos tiers; diversificación con otras strategies

### Uniswap V3 (concentrated liquidity)

**Nivel de confianza**: Alto (usado por strategies para harvest Y como estrategia de liquidez concentrada)

**Razones:**
- DEX más establecido de Ethereum
- Auditado extensivamente
- Usado por miles de protocolos para swaps programáticos y provisión de liquidez

**Riesgos aceptados:**
- UniswapV3Strategy: posición LP concentrada (±960 ticks WETH/USDC) puede salir de rango, dejando de generar fees
- Swaps en harvest (CRV → stETH, AAVE rewards → wstETH) pueden sufrir slippage
- Si no hay liquidez suficiente en los pools, harvest falla
- MEV en swaps WETH↔USDC de UniswapV3Strategy (pool 0.05% tiene ~$500M TVL, impacto marginal)
- Mitigación: Slippage max configurable, fail-safe en harvest, pool de alta liquidez

### wstETH wrapper (Lido)

**Nivel de confianza**: Muy Alto

**Razones:**
- Contrato canónico de Lido para el wrapped stETH
- Código simple y auditado: solo wrappea stETH en un token con exchange rate creciente
- No tiene admin keys ni upgradeability significativa
- Usado por miles de protocolos DeFi como colateral

**Riesgos aceptados:**
- Si el contrato wstETH tiene un bug, AaveStrategy y LidoStrategy se verían afectadas
- Mitigación: El contrato wstETH lleva años en mainnet sin incidentes

### OpenZeppelin Contracts

**Nivel de confianza**: Muy Alto

**Razones:**
- Estándar de industria (ERC4626, ERC20, Ownable, Pausable)
- Auditados exhaustivamente
- Usados por miles de protocolos DeFi

**Componentes usados:**
- `ERC4626`: Estándar de vault tokenizado
- `SafeERC20`: Transferencias seguras de tokens
- `Ownable`: Control de acceso admin
- `Pausable`: Emergency stop
- `Math`: Operaciones matemáticas seguras

### WETH (Wrapped Ether)

**Nivel de confianza**: Muy Alto

**Razones:**
- Contrato canónico de Ethereum
- Código simple y auditado
- No hay admin keys ni upgradeability

---

## 2. Vectores de Ataque Considerados

El protocolo ha sido diseñado considerando los siguientes vectores de ataque comunes en DeFi:

### 2.1 Reentrancy Attacks

**Descripción**: Atacante llama recursivamente funciones antes de que el estado se actualice.

**Protecciones implementadas:**

1. **CEI Pattern (Checks-Effects-Interactions)**
```solidity
// CORRECTO: Quema shares ANTES de transferir assets
function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares) internal {
    _burn(owner, shares);                    // Effect (modifica estado)
    // ... retiro de idle/strategies          // Interaction (external calls)
    IERC20(asset).safeTransfer(receiver, amount); // Interaction
}
```

2. **SafeERC20 para todas las transferencias**
```solidity
using SafeERC20 for IERC20;

IERC20(asset).safeTransfer(receiver, amount);     // No usa transfer() directo
IERC20(asset).safeTransferFrom(user, vault, amt); // Maneja reverts correctamente
```

3. **No hay callbacks a usuarios**
- El vault nunca llama funciones de usuarios (no hay hooks)
- Solo interactúa con contratos conocidos (strategies, WETH, Uniswap, Lido, Aave, Curve)

**Evaluación**: Protegido

---

### 2.2 Front-Running de Rebalances

**Descripción**: Atacante observa tx de rebalance pendiente y deposita justo antes para capturar beneficio inmediato.

**Análisis:**
```solidity
// Escenario:
// 1. Keeper llama rebalance() (mueve fondos a mejor estrategia)
// 2. Atacante ve tx en mempool
// 3. Atacante deposita con mayor gas price
// 4. Rebalance ejecuta (aumenta APY efectivo)
// 5. Atacante retira inmediatamente

// Resultado: Atacante captura parte del yield futuro
```

**Mitigaciones implementadas:**

1. **Rebalance público sin permiso**
   - Cualquiera puede ejecutar rebalance() si pasa shouldRebalance()
   - No hay beneficio especial para el ejecutor
   - MEV es mínimo (no hay arbitraje directo)

2. **Yield acumula con tiempo**
   - Beneficio del rebalance se materializa durante semanas
   - Atacante no puede "flash-rebalance-withdraw"

3. **Sin beneficio inmediato**
   - El rebalance solo mueve fondos entre estrategias
   - No genera profit instantáneo que se pueda extraer

**Evaluación**: Mitigado (económicamente no-rentable)

---

### 2.3 Rounding Attacks (Inflation Attack)

**Descripción**: Atacante manipula el precio share/asset donando assets para causar pérdidas por redondeo.

**Escenario clásico:**
```solidity
// 1. Atacante es primer depositor: deposit(1 wei)
//    shares = 1, totalAssets = 1
//
// 2. Atacante dona 1000 ETH directamente al vault (no via deposit)
//    totalAssets = 1000 ETH + 1 wei
//
// 3. Víctima deposita 2000 ETH
//    shares = (2000 * 1) / 1000 = 2 shares (redondeo down)
//    totalAssets = 3000 ETH
//
// 4. Atacante redeem(1 share)
//    assets = (1 * 3000) / 3 = 1000 ETH
//
// Resultado: Atacante robó 1000 ETH de víctima
```

**Protecciones implementadas:**

1. **Depósito mínimo de 0.01 ETH**
```solidity
uint256 public min_deposit = 0.01 ether;

function deposit(uint256 assets, address receiver) public {
    if (assets < min_deposit) revert Vault__DepositBelowMinimum();
    // ...
}
```

**Análisis de coste de ataque:**
- Para hacer ataque rentable, atacante necesitaría donar >100 ETH
- Primer depósito es 0.01 ETH (no 1 wei)
- Ratio share/asset no puede ser manipulado eficientemente
- Coste del ataque > beneficio potencial

2. **ERC4626 estándar de OpenZeppelin**
- Implementación auditada con protecciones conocidas

**Evaluación**: Protegido (coste de ataque prohibitivo)

---

### 2.4 Flash Loan Attacks

**Descripción**: Atacante toma préstamo flash para manipular precio o estado del vault.

**Análisis de aplicabilidad:**

1. **No hay oracle de precios**
   - El vault no usa precios externos para sus operaciones internas
   - APY de estrategias viene de protocolos subyacentes (Lido/Aave/Curve/Uniswap)
   - No se puede manipular APY con flash loans

2. **No hay weighted voting por shares**
   - Shares solo determinan proporción de assets
   - No hay governance atacable con flash loans

3. **Sin arbitraje instantáneo**
   - No hay withdrawal fee ni forma de extraer valor en una transacción
   - Flash loan → deposit → withdraw retorna lo mismo (menos rounding wei)

**Escenarios considerados:**
```solidity
// NO POSIBLE: Manipular APY
// APY viene de protocolos subyacentes directamente
// Flash loan no puede cambiar el exchange rate de stETH o el APY de Aave

// NO POSIBLE: Arbitrar precio share/asset
// deposit y withdraw son simétricos (ERC4626 standard)

// NO POSIBLE: Votación con shares prestadas
// No existe sistema de governance
```

**Evaluación**: No aplicable (sin vectores de ataque viables)

---

### 2.5 Keeper Incentive Risks

**Descripción**: Riesgos asociados al sistema de keeper incentive y harvest público.

**Vectores considerados:**

1. **Spam de harvest() cuando no hay rewards**
```solidity
// Escenario: Atacante llama harvest() repetidamente
// Resultado: profit < min_profit_for_harvest → return 0
// No se paga incentivo, no se distribuyen fees
// Solo gas wasted por el atacante

// Protección (V2):
// Tier Balanced: min_profit_for_harvest = 0.08 ETH
// Tier Aggressive: min_profit_for_harvest = 0.12 ETH
// Si profit < threshold del tier, harvest no ejecuta distribución
```

2. **Front-running de harvest**
```solidity
// Escenario: Keeper A ve que hay rewards acumulados
// Atacante B front-runs harvest() con gas más alto
// Resultado: Atacante B recibe 1% keeper incentive
// Keeper A gasta gas sin recibir nada

// Mitigación: Este es el diseño esperado — MEV normal
// El 1% incentive es suficientemente bajo para no ser muy rentable de front-runear
// Keepers oficiales no compiten por incentive
```

3. **Keeper oficial malicioso**
```solidity
// Escenario: Owner marca una address como oficial
// Keeper oficial harvesta sin pagar incentive
// Resultado: Más profit para el protocolo, no para keeper

// No es un riesgo — es una feature
// Keepers oficiales son del protocolo y no necesitan incentivo
```

**Evaluación**: Mitigado (spam no-rentable, MEV esperado y tolerable)

---

### 2.6 Uniswap Swap Risks

**Descripción**: Riesgos asociados a swaps en Uniswap V3, tanto para harvest como para la UniswapV3Strategy.

**Vectores considerados:**

1. **Sandwich attack en swaps de harvest**
```solidity
// Escenario:
// 1. Bot detecta harvest() con swap grande en mempool (CRV→stETH, AAVE rewards→wstETH)
// 2. Front-runs: compra el token de destino
// 3. harvest() ejecuta swap (peor precio por impacto)
// 4. Back-runs: vende

// Mitigación: MAX_SLIPPAGE_BPS = 100 (1% max)
// Si el sandwich causa > 1% slippage, la tx revierte
uint256 min_amount_out = (claimed * 9900) / 10000;
```

2. **Sandwich attack en swaps WETH↔USDC de UniswapV3Strategy**
```solidity
// Escenario: deposit/withdraw/harvest de UniswapV3Strategy requiere swap
// Bot front-runs el swap WETH→USDC o USDC→WETH

// Mitigación: Pool WETH/USDC 0.05% tiene ~$500M TVL
// El slippage por frontrunning en operaciones típicas del vault es marginal
// Nota: UniswapV3Strategy NO usa slippage protection explícita en swaps internos
// Este riesgo está aceptado y documentado en la sección "Riesgos por Estrategia"
```

3. **Pool con baja liquidez**
```solidity
// Escenario: Pool de reward tokens (CRV/WETH, AAVE/WETH) tiene poca liquidez
// harvest swap obtiene mal precio o revierte

// Mitigación:
// - Pools de reward tokens son altamente líquidos en mainnet
// - Si swap revierte, fail-safe de StrategyManager continúa con otras estrategias
// - El profit no se pierde, solo se pospone al siguiente harvest
```

**Evaluación**: Mitigado (slippage protection + fail-safe)

---

### 2.7 Router Specific Risks

**Descripción**: Riesgos únicos del Router periférico multi-token.

**Vectores considerados:**

1. **Reentrancy via receive()**
```solidity
// Escenario: Atacante intenta reentrar durante zapWithdrawETH
// cuando el Router llama .call{value}(eth_out) al atacante

// Mitigación implementada:
// - ReentrancyGuard en TODAS las funciones públicas (zapDeposit*, zapWithdraw*)
// - receive() solo acepta ETH del WETH contract (revert si msg.sender != weth)
// - CEI pattern: balance checks al final
```

2. **Fondos atrapados en Router**
```solidity
// Escenario: Bug en código deja WETH/ERC20 en el Router

// Mitigación implementada:
// - Balance check al final de cada función:
//   if (IERC20(weth).balanceOf(address(this)) != 0) revert Router__FundsStuck();
// - Para zapWithdrawERC20:
//   if (IERC20(token_out).balanceOf(address(this)) != 0) revert Router__FundsStuck();
// - Si check falla, tx revierte completamente (no hay fondos atrapados)
```

3. **Sandwich attacks en swaps del Router**
```solidity
// Escenario: MEV bot detecta zapDepositERC20 grande
// Front-runs comprando WETH, usuario paga peor precio, back-runs vendiendo

// Mitigación parcial:
// - Usuario especifica min_weth_out (protección de slippage)
// - Si el sandwich excede slippage tolerance, tx revierte
// - Limitación: Usuario aún es vulnerable a sandwich dentro del slippage permitido
// - Recomendación: Frontends deben calcular min_weth_out conservador (0.5-1% del quote)
```

4. **WETH como intermediario (doble slippage)**
```solidity
// Escenario: Depositar USDC → WETH (slippage 0.1%) → Vault
//            Retirar Vault → WETH → DAI (slippage 0.1%)
// Total slippage: ~0.2% (dos swaps)

// Trade-off aceptado:
// - WETH como hub es estándar en DeFi (máxima liquidez)
// - Alternativa (swap directo USDC → DAI) tendría peor liquidez
// - Usuario explícitamente acepta slippage con min_weth_out / min_token_out
```

**Evaluación**: Mitigado (ReentrancyGuard, stateless checks, slippage protection)

### 2.8 Withdrawal Rounding

**Descripción**: Protocolos externos (Aave, Curve, Uniswap V3) redondean withdrawals a la baja, causando micro-diferencias entre assets solicitados y recibidos.

**Análisis técnico:**
```solidity
// Aave v3: aave_pool.withdraw() puede devolver assets - 1 wei
// Curve: remove_liquidity_one_coin puede devolver assets - 1 o -2 wei
// Uniswap V3: decreaseLiquidity puede tener rounding de 1 wei

// Pattern general en strategies:
uint256 balance_before = IERC20(asset).balanceOf(address(this));
// ... external call (Aave withdraw, Curve remove, Uniswap decreaseLiquidity)
uint256 balance_after = IERC20(asset).balanceOf(address(this));
uint256 actual_withdrawn = balance_after - balance_before;
// actual_withdrawn puede ser assets - 1 o assets - 2
```

**Tolerancia en Vault:**
```solidity
// Vault acepta hasta 20 wei de diferencia
if (to_transfer < assets) {
    require(assets - to_transfer < 20, "Excessive rounding");
}

// ¿Por qué 20 wei?
// - 4 estrategias en V2 × ~2 wei/operación = ~8 wei
// - Margen conservador para operaciones multi-strategy: ~20 wei
// - Costo para usuario: ~$0.00000000000005 con ETH a $2,500
```

**¿Puede un atacante explotar esto?**
```solidity
// NO: 20 wei es insignificante (~$0.00000000000005)
// NO: El rounding siempre beneficia al protocolo (redondeo a la baja)
// NO: No hay acumulación de rounding errors entre operaciones
// El rounding se resuelve por operación, no se propaga
```

**Evaluación**: Tolerado deliberadamente (costo trivial, estándar en DeFi)

---

## 3. Riesgos por Estrategia

### LidoStrategy

**Riesgo 1: Slashing de Validadores**
- Descripción: Si los validadores de Lido son penalizados (slashing), el saldo de stETH disminuye. El impacto típico histórico ha sido < 0.01% del supply.
- Mitigación en V2: Solo el tier Balanced usa LidoStrategy. El idle buffer (8 ETH mínimo) absorbe retiros pequeños sin tocar stETH.

**Riesgo 2: Depeg stETH/ETH**
- Descripción: stETH puede cotizar por debajo de ETH en mercado secundario. Históricamente < 1.5% en condiciones normales. En junio 2022, el depeg llegó al 6-7% por presión de venta de Celsius.
- Mitigación en V2: LidoStrategy usa Uniswap V3 para withdraw (swap wstETH→WETH). Si el slippage supera el límite configurado, el withdraw falla con revert. El protocolo NO fuerza swaps con slippage alto.

**Riesgo 3: Smart Contract Risk de Lido**
- Descripción: Un exploit en el contrato Lido afectaría todos los activos stakeados.
- Mitigación: Lido es el protocolo de liquid staking más auditado de Ethereum, con bug bounty activo y código verificado.

### AaveStrategy (wstETH)

**Riesgo 1: Riesgo Apilado (Stacking Risk)**
- Descripción: AaveStrategy combina dos fuentes de riesgo de protocolo: Lido (staking) + Aave v3 (lending). Un exploit en cualquiera de los dos afecta los fondos.
- Mitigación: Ambos protocolos son tier-1 con auditorías múltiples. La posición en Aave es solo supply (sin borrowing), eliminando riesgo de liquidación.

**Riesgo 2: Liquidación en Aave (no aplica en V2)**
- Nota: AaveStrategy solo hace supply de wstETH, sin borrowing. No existe deuda ni ratio de colateralización que liquidar. El único riesgo es si Aave congela el mercado wstETH (puede ocurrir por governance).

**Riesgo 3: Oracle Manipulation (Aave)**
- Descripción: Si el oracle de precio de wstETH en Aave es manipulado, podría afectar los cálculos de disponibilidad de fondos.
- Mitigación: Aave v3 usa Chainlink oracles con circuit breakers. El protocolo V2 no depende del valor en USD de wstETH para sus operaciones internas.

### CurveStrategy

**Riesgo 1: Impermanent Loss (bajo)**
- Descripción: El pool stETH/ETH tiene par altamente correlacionado. El IL teórico es muy bajo bajo condiciones normales (< 0.5% anual históricamente).
- Escenario de riesgo: Un depeg severo de stETH (>5%) materializa IL significativo para LPs.

**Riesgo 2: Exploit Histórico de Curve (julio 2023)**
- Descripción: En julio 2023, pools de Curve con Vyper <= 0.3.0 fueron vulnerables a reentrancy. El pool stETH/ETH NO fue afectado directamente, pero el evento causó panic selling y IL temporal.
- Estado en V2: El bug fue parchado en Vyper >= 0.3.1. CurveStrategy interactúa con el pool stETH/ETH que usa Vyper >= 0.3.1.

**Riesgo 3: Smart Contract Risk del Gauge**
- Descripción: Los fondos LP se stakean en el Curve gauge para recibir CRV. Un exploit en el gauge afectaría los fondos stakeados.
- Mitigación: Los gauges de Curve son auditados y el gaugeController requiere aprobación de governance para nuevos gauges.

### UniswapV3Strategy

**Riesgo 1: Impermanent Loss Concentrado**
- Descripción: La liquidez concentrada (±10% del precio actual) amplifica el IL comparado con Uniswap V2. Si el precio de WETH/USDC se mueve significativamente dentro del rango, el IL puede ser sustancial.
- Mitigación: El rango ±960 ticks (~±10%) es amplio para el par WETH/USDC. Las fees del 0.05% mitigan el IL en condiciones normales.

**Riesgo 2: Out-of-Range (Posición Sin Fees)**
- Descripción: Si el precio de WETH/USDC sale del rango ±10%, la posición deja de generar fees. Los activos permanecen en el pool pero no reciben ingresos hasta que el precio vuelva al rango.
- Comportamiento en V2: UniswapV3Strategy NO hace rebalancing automático de posición. Una posición out-of-range continúa contabilizada en totalAssets() pero sin generar APY.

**Riesgo 3: MEV en Swaps WETH↔USDC**
- Descripción: Cada deposit, withdraw y harvest implica un swap en Uniswap V3 (WETH→USDC en deposit, USDC→WETH en withdraw/harvest). Estos swaps son visibles en el mempool y pueden ser frontrunned.
- Mitigación: El pool WETH/USDC 0.05% tiene alta liquidez (~$500M TVL). El slippage por frontrunning en operaciones típicas del vault es marginal. UniswapV3Strategy NO usa slippage protection explícita en los swaps internos — este es un riesgo aceptado para simplificar el contrato.

**Riesgo 4: Posición como NFT (tokenId)**
- Descripción: La posición LP de UniswapV3Strategy está representada como un NFT (tokenId). Si el NFT se pierde o transfiere accidentalmente, los fondos quedan inaccesibles.
- Mitigación: El tokenId es almacenado en estado por UniswapV3Strategy. La transferencia del NFT solo puede hacerla el contrato mismo (es el owner). No hay función de transferencia de NFT expuesta.

---

## 4. Protecciones Implementadas

### 4.1 Control de Acceso

**Modificadores usados:**

```solidity
// Vault
modifier onlyOwner()        // Funciones admin (pause, setters, syncIdleBuffer)
modifier whenNotPaused()    // Deposits, mint, harvest, allocateIdle
//                          // withdraw y redeem NO tienen whenNotPaused:
//                          // los usuarios siempre pueden retirar sus fondos

// StrategyManager
modifier onlyOwner()        // Agregar/remover strategies, setters
modifier onlyVault()        // allocate(), withdrawTo(), harvest()

// Strategies
modifier onlyManager()      // deposit(), withdraw(), harvest()
```

**Jerarquía de permisos:**
```
Owner del Vault
  ↓
Vault (contrato)
  ↓ (solo vault puede llamar)
StrategyManager (contrato)
  ↓ (solo manager puede llamar)
Strategies (contratos)
  ↓
Protocolos externos (Lido/Aave/Curve/Uniswap V3)
```

---

### 4.2 Circuit Breakers

| Parámetro | Balanced | Aggressive |
|---|---|---|
| `max_tvl` | 1000 ETH | 1000 ETH |
| `idle_threshold` | 8 ETH | 12 ETH |
| `min_profit_for_harvest` | 0.08 ETH | 0.12 ETH |
| `rebalance_threshold` | 2% (200 bp) | 3% (300 bp) |

El `max_tvl` previene que el vault escale indefinidamente, limitando el riesgo sistémico en protocolos subyacentes. El `idle_threshold` garantiza que siempre haya liquidez inmediata para retiros sin necesidad de interactuar con protocolos externos.

**1. Max TVL (Vault)**
```solidity
uint256 public max_tvl = 1000 ether;

function deposit(uint256 assets, address receiver) public {
    if (totalAssets() + assets > max_tvl) {
        revert Vault__MaxTVLExceeded();
    }
    // ...
}
```

**Propósito:**
- Limita exposición total del protocolo
- Útil durante fase de testeo/auditoría
- Owner puede aumentar cuando sea seguro

---

**2. Min Deposit (Vault)**
```solidity
uint256 public min_deposit = 0.01 ether;

function deposit(uint256 assets, address receiver) public {
    if (assets < min_deposit) {
        revert Vault__DepositBelowMinimum();
    }
    // ...
}
```

**Propósitos:**
- **Anti-spam**: Previene muchos depósitos pequeños que acumulan gas
- **Anti-rounding attack**: Hace rounding attacks prohibitivamente caros

---

**3. Idle Threshold (por Tier)**
```solidity
// Tier Balanced: idle_threshold = 8 ETH
// Tier Aggressive: idle_threshold = 12 ETH
// Fondos por debajo del threshold permanecen en idle (sin invertir)
// Garantizan liquidez inmediata para retiros sin tocar protocolos externos
```

---

**4. Max Strategies (Manager)**
```solidity
uint256 public constant MAX_STRATEGIES = 10;  // Hard-coded
```

**Propósito:**
- Previene gas DoS en loops de allocate/withdrawTo/harvest/rebalance
- Con 10 estrategias, cada loop tiene coste predecible

---

**5. Min Profit for Harvest (por Tier)**
```solidity
// Tier Balanced: min_profit_for_harvest = 0.08 ETH
// Tier Aggressive: min_profit_for_harvest = 0.12 ETH
```

**Propósito:**
- Previene harvest no-rentables (gas > profit)
- Previene spam de harvest() por atacantes
- El threshold mayor del tier Aggressive refleja el mayor coste de sus operaciones (posiciones Uniswap V3)

---

### 4.3 Emergency Stop (Pausable)

```solidity
contract Vault is IVault, ERC4626, Ownable, Pausable {
    function deposit(...) public whenNotPaused { }
    function mint(...) public whenNotPaused { }
    function withdraw(...) public override { }              // SIN whenNotPaused
    function redeem(...) public override { }                // SIN whenNotPaused
    function harvest() external whenNotPaused { }
    function allocateIdle() external whenNotPaused { }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
```

**Cuándo usar:**
- Se detecta vulnerabilidad en vault o estrategias
- Hack en Lido/Aave/Curve/Uniswap afecta fondos
- Bug crítico en weighted allocation o harvest
- Mientras se investiga comportamiento anómalo
- **Primer paso de la secuencia de emergency exit** (ver sección 4.8)

**Qué pausa:**
- Nuevos deposits (deposit, mint)
- Harvest
- AllocateIdle
- No pausa rebalances (manager está separado)

**Qué NO pausa (por diseño):**
- **withdraw**: Los usuarios siempre pueden retirar sus fondos
- **redeem**: Los usuarios siempre pueden quemar shares y recuperar assets

**Principio DeFi**: La pausa bloquea inflows (depósitos) y operaciones del protocolo, pero **nunca bloquea outflows** (retiros). Un usuario siempre debe poder recuperar sus fondos independientemente del estado del vault.

**Nota:** Owner del manager debería remover estrategias comprometidas durante pausa.

---

### 4.4 Uso de SafeERC20

**Todas las operaciones con IERC20 usan SafeERC20:**
```solidity
using SafeERC20 for IERC20;

// En lugar de:
IERC20(asset).transfer(receiver, amount);           // No recomendado
IERC20(asset).transferFrom(user, vault, amount);    // No recomendado

// Usamos:
IERC20(asset).safeTransfer(receiver, amount);       // Correcto
IERC20(asset).safeTransferFrom(user, vault, amount);// Correcto
```

**Protecciones de SafeERC20:**
- Maneja tokens que no retornan bool en transfer (legacy tokens)
- Revierte si transfer falla silenciosamente
- Verifica return value correctamente

---

### 4.5 Harvest Fail-Safe

```solidity
// StrategyManager.harvest() usa try-catch
for (uint256 i = 0; i < strategies.length; i++) {
    try strategies[i].harvest() returns (uint256 profit) {
        total_profit += profit;
    } catch Error(string memory reason) {
        emit HarvestFailed(address(strategies[i]), reason);
        // Continúa con la siguiente estrategia
    }
}
```

**Propósito:**
- Si LidoStrategy.harvest() retorna 0 (yield via exchange rate, no rewards directos), el resto continúa
- Si CurveStrategy.harvest() falla (swap CRV→stETH con slippage alto), AaveStrategy continúa
- Si UniswapV3Strategy.harvest() falla (out-of-range, sin fees), las demás estrategias continúan
- Previene que un fallo bloquee todo el harvest
- Emite evento para monitoring

---

### 4.6 Router Stateless Design

**Todas las funciones del Router verifican balance 0 al final:**

```solidity
// En zapDepositETH, zapDepositERC20:
if (IERC20(weth).balanceOf(address(this)) != 0) revert Router__FundsStuck();

// En zapWithdrawERC20:
if (IERC20(token_out).balanceOf(address(this)) != 0) revert Router__FundsStuck();
```

**Propósito:**
- Garantiza que el Router NUNCA retiene fondos entre transacciones
- Si hay fondos atrapados (bug), la transacción revierte completamente
- Sin fondos custodiados = sin superficie de ataque para robo

**Nota**: `zapWithdrawETH` no verifica WETH balance porque el WETH se unwrappea a ETH inmediatamente. Solo verifica que el ETH se transfirió al usuario correctamente.

---

### 4.7 Slippage Protection en Swaps

```solidity
// En strategies de V2 (AaveStrategy, CurveStrategy)
uint256 public constant MAX_SLIPPAGE_BPS = 100;  // 1%

uint256 min_amount_out = (claimed * (BASIS_POINTS - MAX_SLIPPAGE_BPS)) / BASIS_POINTS;
// = claimed * 9900 / 10000 (mínimo 99% del valor esperado)

uniswap_router.exactInputSingle(
    // ...
    amountOutMinimum: min_amount_out,  // Revierte si output < 99%
    // ...
);
```

**Propósito:**
- Previene sandwich attacks (máximo 1% de impacto en strategies)
- Protege contra pools con baja liquidez
- Si el swap no puede conseguir 99%+, revierte (y fail-safe continúa)

**Nota sobre UniswapV3Strategy:**
- UniswapV3Strategy NO aplica slippage protection explícita en los swaps WETH↔USDC internos
- Este trade-off está documentado en la sección "Riesgos por Estrategia"
- El pool WETH/USDC 0.05% tiene suficiente liquidez para hacer el riesgo marginal

**En Router (configurable por usuario):**

```solidity
// zapDepositERC20: usuario especifica min_weth_out
uint256 weth_out = _swapToWETH(token_in, amount_in, pool_fee, min_weth_out);
if (weth_out < min_weth_out) revert Router__SlippageExceeded();

// zapWithdrawERC20: usuario especifica min_token_out
uint256 amount_out = _swapFromWETH(weth_in, token_out, pool_fee, min_token_out);
if (amount_out < min_token_out) revert Router__SlippageExceeded();
```

**Responsabilidad del frontend:**
- Calcular quote esperado de Uniswap Quoter
- Aplicar tolerancia (típicamente 0.5-1%)
- Pasar como `min_weth_out` / `min_token_out`

---

### 4.8 Emergency Exit Mechanism

El protocolo implementa un mecanismo de emergency exit que permite drenar todas las estrategias activas y devolver los fondos al vault en caso de bug crítico, exploit activo, o comportamiento anómalo en protocolos subyacentes.

**Secuencia de emergencia (3 transacciones independientes):**

```solidity
// PASO 1: Pausar el vault (bloquea nuevos depósitos, harvest, allocateIdle)
// Los retiros (withdraw/redeem) permanecen habilitados
vault.pause();

// PASO 2: Drenar todas las estrategias al vault
// Try-catch por estrategia: si una falla, continúa con las demás
manager.emergencyExit();

// PASO 3: Reconciliar idle_buffer con el balance real de WETH
// Necesario porque emergencyExit transfiere WETH al vault sin pasar por deposit()
vault.syncIdleBuffer();
```

**Características de seguridad:**

1. **Sin timelock**: En emergencias cada bloque expone fondos al exploit. La velocidad de respuesta prima sobre governance
2. **Fail-safe (try-catch)**: Si una estrategia falla durante el drenaje (bug, frozen, etc.), las demás continúan. La estrategia problemática emite `HarvestFailed` y el owner la gestiona por separado
3. **Retiros siempre habilitados**: Tras pausar, los usuarios pueden seguir retirando sus fondos. Nunca se bloquean los outflows
4. **Accounting correcto**: `syncIdleBuffer()` reconcilia `idle_buffer` con el balance real de WETH del contrato, asegurando que `totalAssets()` y el exchange rate shares/assets sean correctos tras el drenaje
5. **Eventos para indexers**: `EmergencyExit(timestamp, total_rescued, strategies_drained)` y `IdleBufferSynced(old_buffer, new_buffer)` permiten monitoreo on-chain

**¿Qué pasa si `emergencyExit()` revierte completamente?**
- El vault queda pausado (paso 1 ya ejecutado)
- Los fondos permanecen en las estrategias — ningún asset se pierde
- Los usuarios pueden seguir retirando (withdraw/redeem no están pausados)
- El owner diagnostica y reintenta

**¿Qué pasa si Vault y Manager tienen owners distintos?**
- Cada owner ejecuta su paso: owner del vault ejecuta `pause()` y `syncIdleBuffer()`, owner del manager ejecuta `emergencyExit()`
- La comunicación off-chain entre owners es crítica en este escenario

**Nota sobre dust/rounding:** Tras `emergencyExit()`, las estrategias pueden retener 1-2 wei de dust debido al rounding de conversiones (ej: wstETH/stETH). Esto es comportamiento esperado y no representa riesgo.

**Funciones involucradas:**
- `StrategyManager.emergencyExit()` — `onlyOwner`, drena estrategias
- `Vault.syncIdleBuffer()` — `onlyOwner`, reconcilia accounting
- `Vault.pause()` / `Vault.unpause()` — `onlyOwner`, emergency stop

---

## 5. Puntos de Centralización

El protocolo tiene puntos de centralización controlados por owners. En producción, estos deberían ser multisigs.

### 5.1 Owner del Vault

**Puede:**

1. **Pausar deposits/harvest/allocateIdle**
```solidity
vault.pause();
// Bloquea: deposit, mint, harvest, allocateIdle
// NO bloquea: withdraw, redeem (usuarios siempre pueden retirar)
```

2. **Cambiar parámetros del protocolo**
```solidity
vault.setPerformanceFee(5000);             // Aumenta fee a 50%
vault.setFeeSplit(5000, 5000);             // Cambia split 50/50
vault.setMinDeposit(1 ether);             // Sube depósito mínimo
vault.setIdleThreshold(100 ether);        // Cambia cuando invertir
vault.setMaxTVL(10000 ether);             // Aumenta circuit breaker
vault.setKeeperIncentive(500);            // Sube incentivo a 5%
vault.setMinProfitForHarvest(1 ether);    // Sube threshold harvest
```

3. **Cambiar direcciones críticas**
```solidity
vault.setTreasury(new_treasury);           // Cambia quién recibe fees
vault.setFounder(new_founder);             // Cambia founder address
vault.setStrategyManager(new_manager);     // Cambia strategy manager
vault.setOfficialKeeper(keeper, true);     // Marca keepers oficiales
```

4. **Reconciliar accounting tras emergency exit**
```solidity
vault.syncIdleBuffer();                    // Reconcilia idle_buffer con balance real de WETH
```

**NO puede:**
- Robar fondos directamente
- Transferir WETH del vault sin pasar por withdraw
- Mintear shares sin depositar assets
- Modificar balances de usuarios

**Mitigaciones recomendadas:**
- Usar multisig (Gnosis Safe) como owner
- Timelock para cambios de parámetros sensibles
- Eventos emitidos para transparencia

---

### 5.2 Router (Sin Privilegios)

**El Router NO tiene puntos de centralización:**

- **Sin owner**: El Router no tiene funciones `onlyOwner`
- **Sin privilegios en el Vault**: Es un usuario normal (llama funciones públicas: deposit/redeem)
- **Inmutable**: Todas las direcciones (weth, vault, swap_router) son `immutable`
- **Sin upgrades**: El Router no es upgradeable
- **Stateless**: No custodia fondos → sin riesgo de robo incluso si hay bug

**Si el Router tiene un bug:**
- Worst case: Un usuario pierde fondos en UNA transacción (la que ejecuta)
- El Vault y los fondos de otros usuarios NO se ven afectados
- Se puede desplegar un nuevo Router sin afectar al Vault

**Esto es intencional**: El Router es desechable y reemplazable. El Vault es el core crítico.

---

### 5.3 Owner del Manager

**Puede:**

1. **Agregar estrategias maliciosas**
```solidity
// RIESGO: Owner puede agregar estrategia fake
manager.addStrategy(address(malicious_strategy));

// malicious_strategy.deposit() podría:
// - No depositar en protocolo real
// - Transferir WETH a address del atacante
// - Reportar totalAssets() falso
// - harvest() podría robar fondos
```

2. **Remover estrategias**
```solidity
// Solo si balance = 0 (protección contra pérdida accidental)
manager.removeStrategy(index);
```

3. **Cambiar parámetros de allocation**
```solidity
manager.setMaxAllocationPerStrategy(10000); // Permite 100% en una estrategia
manager.setMinAllocationThreshold(0);       // Permite micro-allocations
manager.setRebalanceThreshold(0);           // Permite rebalances sin diferencia APY
```

4. **Emergency exit (drenar todas las estrategias)**
```solidity
manager.emergencyExit();                    // Drena todas las estrategias al vault
// Try-catch: si una estrategia falla, continúa con las demás
```

**NO puede:**
- Llamar allocate(), withdrawTo() o harvest() (solo vault puede)
- Robar WETH directamente del manager
- Depositar/retirar de estrategias directamente

**Mitigaciones recomendadas:**
- Multisig como owner
- Whitelist de estrategias permitidas (off-chain governance)
- Auditar estrategias antes de agregar
- Monitoring de parámetros críticos

---

### 5.4 Single Point of Failure

**Escenario crítico:**
```
Owner EOA pierde private key
  → No se puede pausar vault
  → No se puede remover estrategia comprometida
  → Fondos podrían estar en riesgo
```

**Soluciones recomendadas para producción:**

1. **Multisig Gnosis Safe (3/5 o 4/7)**
   - Requiere múltiples firmas para acciones críticas
   - Previene pérdida de key única

2. **Timelock**
   ```solidity
   // Cambios de parámetros tienen delay de 24-48h
   // Usuarios pueden retirar si no están de acuerdo
   ```

3. **Roles granulares (OpenZeppelin AccessControl)**
   ```solidity
   PAUSER_ROLE      → Puede pausar (keeper de confianza)
   STRATEGY_ROLE    → Puede agregar/remover strategies (DAO)
   PARAM_ROLE       → Puede ajustar parámetros (multisig)
   ```

---

## 6. Limitaciones Conocidas

El protocolo tiene limitaciones deliberadas y trade-offs conocidos:

### 6.1 Solo WETH

**Limitación:**
- Solo soporta WETH como asset de entrada/salida del vault
- Las strategies internamente convierten a stETH/wstETH/USDC según corresponda

**Razones:**
- Simplicidad del vault core
- Strategies LST tienen mejores rates para ETH/WETH
- Multi-asset requiere price oracles adicionales (mayor superficie de ataque)

---

### 6.2 Weighted Allocation Básico

**Limitación:**
- Algoritmo simple: allocation proporcional a APY
- No considera volatilidad, liquidez, historial

**Fórmula actual:**
```solidity
target[i] = (strategy_apy[i] * BASIS_POINTS) / total_apy
// Con caps: max 50%, min 10%
```

**Mejoras potenciales:**
- Sharpe ratio (reward/risk)
- Liquidez disponible en protocolos
- Historial de APY (no solo snapshot)
- Penalización por estrategias out-of-range (UniswapV3Strategy)

---

### 6.3 Idle Buffer No Genera Yield

**Limitación:**
- WETH en idle buffer no está invertido
- Durante acumulación (0-8 ETH en Balanced, 0-12 ETH en Aggressive), no hay yield

**Trade-off:**
```
Gas savings > yield perdido en idle

Ejemplo (Balanced, 5 ETH en idle durante 1 día):
- APY perdido: 6% anual (CurveStrategy referencia) = 0.0008 ETH/día
- Gas ahorrado: 0.015 ETH (por no hacer allocate solo)
- Beneficio neto: 0.015 - 0.0008 = 0.0142 ETH
```

**Alternativa considerada:**
- Auto-compound idle en Aave (añade complejidad y una external call extra)

---

### 6.4 Rebalancing Manual

**Limitación:**
- No hay rebalancing automático on-chain
- Requiere keepers externos o usuarios

**Razones:**
- Rebalancing en cada depósito sería carísimo
- Keepers pueden elegir momento óptimo (gas bajo)
- shouldRebalance() es view (keepers pueden simular off-chain)

**Mitigaciones:**
- Cualquiera puede ejecutar (permissionless)
- Threshold del 2% (Balanced) / 3% (Aggressive) previene ejecuciones innecesarias

---

### 6.5 Treasury Shares Ilíquidas

**Limitación:**
- Treasury recibe performance fees en shares (vxWETH)
- Shares no se pueden vender fácilmente sin diluir a holders

**Consecuencias:**
- Treasury acumula shares que auto-compound (buen yield a largo plazo)
- Pero no puede convertir fácilmente a liquid assets sin impactar precio de shares

**Trade-off:**
- Auto-compound > liquidez inmediata para treasury
- Founder recibe liquid (WETH) para costes operativos
- Si treasury necesita liquidez, puede redeem shares gradualmente

---

### 6.6 Harvest Depende de Liquidez Uniswap

**Limitación:**
- Si pools de reward tokens (CRV/WETH, AAVE/WETH) en Uniswap V3 no tienen liquidez, harvest falla
- Rewards se acumulan sin convertir a WETH

**Mitigaciones:**
- Pools de reward tokens son altamente líquidos en mainnet
- Fail-safe en StrategyManager permite que estrategias individuales fallen
- Rewards no se pierden, solo se acumulan para el siguiente harvest exitoso
- Slippage del 1% protege contra pools temporalmente ilíquidos

**Nota sobre LidoStrategy:**
- LidoStrategy.harvest() retorna 0 — no hay swap de rewards
- El yield se acumula via el exchange rate creciente de wstETH
- No depende de liquidez de Uniswap para su harvest

---

### 6.7 Router Depende de Liquidez Uniswap V3

**Limitación:**
- Router solo puede operar con tokens que tengan pool de Uniswap V3 con WETH
- Si un pool no existe o no tiene liquidez suficiente, zapDeposit/zapWithdraw falla

**Tokens soportados típicamente:**
- Stablecoins: USDC, USDT, DAI (pools 0.05% muy líquidos)
- Blue chips: WBTC, LINK, UNI (pools 0.3% líquidos)
- Otros ERC20 con pool WETH: depende de liquidez

**Mitigaciones:**
- Slippage protection: si no hay liquidez, swap revierte (usuario no pierde fondos)
- Pool fee configurable: frontend elige el pool más líquido (100, 500, 3000, 10000 bps)
- Fallback: usuarios siempre pueden comprar WETH manualmente y usar vault.deposit() directo

---

### 6.8 Max 10 Estrategias

**Limitación:**
- Máximo 10 estrategias activas simultáneamente (hard-coded)

**Razones:**
- Previene gas DoS en loops (allocate, withdrawTo, harvest, rebalance)
- Con 10 estrategias, gas cost es predecible y razonable
- Más de 10 estrategias probablemente no añaden diversificación significativa

---

### 6.9 UniswapV3Strategy: Posición Out-of-Range

**Limitación:**
- Si el precio de WETH/USDC sale del rango ±10%, la posición no genera fees
- No hay rebalancing automático de posición

**Impacto:**
- La posición sigue contabilizada en totalAssets()
- El APY efectivo del tier Aggressive cae cuando UniswapV3Strategy está out-of-range
- Los holders existentes se ven diluidos si nuevos depositantes entran durante este período

**Mitigaciones:**
- El rango ±960 ticks es suficientemente amplio para absorber volatilidad normal de WETH
- El tier Aggressive tiene un `rebalance_threshold` del 3%, permitiendo reasignar fondos a CurveStrategy si UniswapV3Strategy pierde competitividad

---

## 7. Recomendaciones para Auditoría

Si este protocolo fuera a mainnet, auditoría debería enfocarse en:

### 7.1 Matemáticas Críticas

**Áreas de enfoque:**

1. **Cálculo de performance fee y distribución**
```solidity
// ¿Overflow posible en (profit * keeper_incentive) / BASIS_POINTS?
// ¿Qué pasa si performance_fee = 10000 (100%)?
// ¿Qué pasa si treasury_split + founder_split != BASIS_POINTS?
```

2. **Weighted allocation en _computeTargets()**
```solidity
// ¿La normalización suma exactamente 10000?
// ¿Qué pasa si total_apy = 0?
// ¿Qué pasa si una strategy reporta APY = type(uint256).max?
```

3. **Conversión shares ↔ assets (ERC4626)**
```solidity
// ¿previewWithdraw y previewRedeem son consistentes?
// ¿Puede haber rounding que beneficie al atacante?
// ¿Mintear shares al treasury durante harvest afecta exchange rate?
```

---

### 7.2 Edge Cases

**Escenarios extremos a testear:**

1. **Primer depósito = min_deposit (0.01 ETH)**
   - ¿Shares calculados correctamente?
   - ¿Vulnerable a rounding attacks?

2. **Una estrategia con APY = 0**
   - ¿_computeTargets() maneja correctamente?
   - ¿Recibe allocation o se salta?

3. **Todas las estrategias con APY = 0**
   - ¿Distribución equitativa funciona?

4. **Strategy.withdraw() revierte (falta liquidez)**
   - ¿El usuario puede retirar o todo el withdraw falla?

5. **Harvest cuando idle_buffer = 0 y keeper necesita pago**
   - ¿Retira correctamente de estrategias para pagar keeper?

6. **Harvest retorna profit < min_profit_for_harvest**
   - ¿Se acumulan los rewards sin distribuir fees?

7. **Strategy.harvest() revierte**
   - ¿Fail-safe continúa con otras estrategias?

8. **UniswapV3Strategy out-of-range durante harvest**
   - ¿collect() devuelve 0 fees correctamente sin revertir?
   - ¿totalAssets() refleja el valor correcto de la posición?

9. **LidoStrategy harvest retorna 0**
   - ¿El protocolo no intenta distribuir 0 profit como performance fee?

---

### 7.3 Integración con Protocolos Externos

**Verificar:**

1. **Lido stETH/wstETH**
   - ¿Qué pasa si submit() de Lido revierte (por limite de stake)?
   - ¿El exchange rate de wstETH→stETH aumenta siempre monotónicamente?
   - ¿wrap/unwrap de wstETH pueden revertir?

2. **Aave v3 devuelve valores esperados**
   - ¿Qué pasa si `getReserveData()` revierte?
   - ¿`claimAllRewards()` puede devolver 0 sin revertir?
   - ¿Qué pasa si Aave congela el mercado wstETH?

3. **Curve pool y gauge**
   - ¿add_liquidity y remove_liquidity_one_coin pueden revertir por slippage?
   - ¿gauge.deposit/withdraw tienen restricciones inesperadas?
   - ¿CRV rewards se acumulan correctamente si no se hace claim por tiempo?

4. **Uniswap V3 swap y posición LP**
   - ¿Qué pasa si pool no existe?
   - ¿Qué pasa si deadline expira?
   - ¿Slippage protection funciona con cantidades muy pequeñas?
   - ¿mint(), increaseLiquidity(), decreaseLiquidity() y collect() son seguros en secuencia?
   - ¿Qué pasa si tokenId = 0 (posición no inicializada)?

---

### 7.4 Reentrancy

**Puntos de atención:**

1. **¿Todas las external calls siguen CEI?**
   - Especialmente en `_withdraw()`, `harvest()`, `_distributePerformanceFee()`

2. **¿SafeERC20 protege contra reentrancy via ERC777?**
   - WETH no es ERC777, pero buena práctica

3. **¿harvest() puede ser llamado recursivamente?**
   - A través de strategy.harvest() → callback → vault.harvest()

4. **¿Curve add_liquidity o gauge.deposit pueden hacer callbacks?**
   - Verificar que no hay hooks externos en el path de ejecución

---

### 7.5 Access Control

**Verificar:**

1. **¿Todos los setters son onlyOwner?**
2. **¿allocate/withdrawTo/harvest son realmente onlyVault?**
3. **¿deposit/withdraw/harvest de strategies son onlyManager?**
4. **¿rebalance puede ser llamado por cualquiera? (debe ser público)**
5. **¿initialize() solo se puede llamar una vez?**
6. **¿El tokenId del NFT de UniswapV3Strategy solo puede ser transferido por el contrato?**

---

## 8. Conclusión de Seguridad

### Fortalezas del Protocolo

**Arquitectura modular y clara**
- Separación de concerns (Vault, Manager, Strategies)
- Dos tiers con parámetros de riesgo diferenciados (Balanced / Aggressive)
- Fácil de auditar y razonar

**Uso de estándares de industria**
- ERC4626 (OpenZeppelin)
- SafeERC20 para todas las transferencias
- Pausable para emergency stop

**Protecciones económicas**
- Min deposit previene rounding attacks
- Min profit por tier previene harvest spam (0.08 ETH Balanced / 0.12 ETH Aggressive)
- Slippage protection en swaps de harvest (1%)

**Circuit breakers múltiples**
- Max TVL (1000 ETH), min deposit, idle threshold por tier, max strategies
- Pausa de emergencia (bloquea inflows, nunca outflows)
- Emergency exit: drenaje completo de estrategias con fail-safe y reconciliación de accounting

**Harvest fail-safe**
- Try-catch individual por estrategia
- Si una falla (incluyendo LidoStrategy que retorna 0), las demás continúan

**Sin permiso para operaciones críticas**
- Rebalance es público (cualquiera puede ejecutar si es rentable)
- Harvest es público (incentivizado para keepers externos)
- AllocateIdle es público (si idle >= threshold del tier)

### Debilidades Conocidas

**Centralización del ownership**
- Single point of failure si owner pierde key
- Mitigación: Usar multisig en producción

**Trust en estrategias agregadas**
- Owner puede agregar estrategia maliciosa
- Mitigación: Whitelist + auditorías

**Dependencia de protocolos externos**
- Si Lido/Aave/Curve/Uniswap tienen exploit, fondos en riesgo
- Mitigación: Allocation caps (max 50%), fail-safe harvest, tiers separados

**Treasury shares ilíquidas**
- Treasury acumula shares que no puede vender fácilmente
- Mitigación: Diseño deliberado (auto-compound > liquidez)

**Harvest depende de Uniswap (para CRV/AAVE rewards)**
- Si pools de reward tokens no tienen liquidez, harvest parcial falla
- Mitigación: Fail-safe, rewards se acumulan para siguiente intento

**UniswapV3Strategy sin rebalancing**
- Posición puede quedarse out-of-range indefinidamente
- Mitigación: Threshold de rebalance del tier Aggressive permite redistribuir a CurveStrategy

### Recomendaciones Finales

**Para lanzar a mainnet:**

1. **Auditoría profesional** (Trail of Bits, OpenZeppelin, Consensys)
2. **Testnet prolongado** (Sepolia → Mainnet)
3. **Bug bounty** (Immunefi, Code4rena)
4. **Multisig como owner** (mínimo 3/5)
5. **Monitoring on-chain** (Forta, Tenderly)
6. **Emergency playbook** documentado (ver sección 4.8 para la secuencia de emergency exit)
7. **TVL gradual** (empezar con max_tvl = 100 ETH, subir gradualmente)

**Para uso educacional:**
- Código es production-grade y seguro
- Arquitectura es sólida y extensible
- Buenas prácticas implementadas (CEI, SafeERC20, fail-safe, slippage protection)
- NO usar en mainnet sin auditoría formal

---

**Fin de la documentación de seguridad.**

Para más información, consulta:
- [ARCHITECTURE.md](ARCHITECTURE.md) - Decisiones de diseño
- [CONTRACTS.md](CONTRACTS.md) - Documentación de contratos
- [FLOWS.md](FLOWS.md) - Flujos de usuario
