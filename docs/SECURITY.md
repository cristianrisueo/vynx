# Consideraciones de Seguridad

Este documento analiza la postura de seguridad de VynX V1, incluyendo trust assumptions, vectores de ataque considerados, protecciones implementadas, puntos de centralización y limitaciones conocidas.

---

## 1. Trust Assumptions (En Qué Confiamos)

El protocolo VynX V1 **confía explícitamente** en los siguientes componentes externos:

### Aave v3

**Nivel de confianza**: Alto

**Razones:**
- Auditado múltiples veces por Trail of Bits, OpenZeppelin, Consensys Diligence, etc.
- Battle-tested con >$5B TVL en mainnet durante años
- Historial de seguridad robusto (sin hacks mayores)
- Código open-source revisado por comunidad

**Riesgos aceptados:**
- Si Aave sufre un exploit, podríamos perder fondos depositados en AaveStrategy
- Mitigación: Weighted allocation limita exposición al 50% máximo

### Compound v3

**Nivel de confianza**: Alto

**Razones:**
- Auditado por OpenZeppelin, ChainSecurity, etc.
- Battle-tested con >$3B TVL en mainnet
- Compound v2 tiene historial de años sin hacks críticos
- V3 es reescritura más segura y gas-efficient

**Riesgos aceptados:**
- Si Compound sufre un exploit, podríamos perder fondos depositados en CompoundStrategy
- Mitigación: Weighted allocation limita exposición al 50% máximo

### Uniswap V3

**Nivel de confianza**: Alto

**Razones:**
- DEX más establecido de Ethereum
- Auditado extensivamente
- Usado por miles de protocolos para swaps programáticos

**Riesgos aceptados:**
- Si Uniswap tiene un bug, los swaps de rewards durante harvest podrían fallar o devolver menos WETH
- Si no hay liquidez suficiente en pools AAVE/WETH o COMP/WETH, harvest falla
- Mitigación: Slippage max del 1%, fail-safe en StrategyManager (si harvest falla, continúa con otras estrategias)

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
- Solo interactúa con contratos conocidos (strategies, WETH, Uniswap)

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
   - El vault no usa precios externos
   - APY de estrategias viene de protocolos (Aave/Compound)
   - No se puede manipular APY con flash loans

2. **No hay weighted voting por shares**
   - Shares solo determinan proporción de assets
   - No hay governance atacable con flash loans

3. **Sin arbitraje instantáneo**
   - No hay withdrawal fee pero tampoco hay forma de extraer valor en una transacción
   - Flash loan → deposit → withdraw retorna lo mismo (menos rounding wei)

**Escenarios considerados:**
```solidity
// NO POSIBLE: Manipular APY
// APY viene de Aave/Compound directamente
// Flash loan no puede cambiar liquidity rate de Aave

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

// Protección: min_profit_for_harvest = 0.1 ETH
// Si profit < 0.1 ETH, harvest no ejecuta distribución
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

**Descripción**: Riesgos asociados al swap de reward tokens a WETH via Uniswap V3.

**Vectores considerados:**

1. **Sandwich attack en swaps**
```solidity
// Escenario:
// 1. Bot detecta harvest() con swap grande en mempool
// 2. Front-runs: compra WETH con el reward token
// 3. harvest() ejecuta swap (peor precio por impacto)
// 4. Back-runs: vende WETH

// Mitigación: MAX_SLIPPAGE_BPS = 100 (1% max)
// Si el sandwich causa > 1% slippage, la tx revierte
// Con pool_fee de 0.3%, el margen para sandwich es muy limitado
uint256 min_amount_out = (claimed * 9900) / 10000;
```

2. **Pool con baja liquidez**
```solidity
// Escenario: Pool AAVE/WETH o COMP/WETH tiene poca liquidez
// harvest swap obtiene mal precio o revierte

// Mitigación:
// - Pools AAVE/WETH y COMP/WETH son altamente líquidos en mainnet
// - Si swap revierte, fail-safe de StrategyManager continúa con otras estrategias
// - El profit no se pierde, solo se pospone al siguiente harvest
```

3. **Reward token depegs o pierde valor**
```solidity
// Escenario: AAVE o COMP pierde valor significativo
// Swap devuelve menos WETH del esperado

// Mitigación:
// - Slippage del 1% protege contra pérdidas extremas
// - Si el swap falla, fail-safe continúa
// - Los rewards perdidos son una fracción del yield total (la mayoría viene del lending)
```

**Evaluación**: Mitigado (slippage protection + fail-safe)

---

### 2.7 Withdrawal Rounding

**Descripción**: Protocolos externos (Aave, Compound) redondean withdrawals a la baja, causando micro-diferencias entre assets solicitados y recibidos.

**Análisis técnico:**
```solidity
// Aave v3: aave_pool.withdraw() puede devolver assets - 1 wei
// Compound v3: compound_comet.withdraw() puede devolver assets - 1 o -2 wei

// Pattern en CompoundStrategy:
uint256 balance_before = IERC20(asset).balanceOf(address(this));
compound_comet.withdraw(asset, assets);
uint256 balance_after = IERC20(asset).balanceOf(address(this));
uint256 actualWithdrawn = balance_after - balance_before;
// actualWithdrawn puede ser assets - 1 o assets - 2
```

**Tolerancia en Vault:**
```solidity
// Vault acepta hasta 20 wei de diferencia
if (to_transfer < assets) {
    require(assets - to_transfer < 20, "Excessive rounding");
}

// ¿Por qué 20 wei?
// - 2 estrategias actuales × ~2 wei/operación = ~4 wei
// - Plan futuro: ~10 estrategias × ~2 wei = ~20 wei (margen conservador)
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

## 3. Protecciones Implementadas

### 3.1 Control de Acceso

**Modificadores usados:**

```solidity
// Vault
modifier onlyOwner()        // Funciones admin (pause, setters)
modifier whenNotPaused()    // Deposits, withdraws, harvest

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
Protocolos externos (Aave/Compound/Uniswap)
```

---

### 3.2 Circuit Breakers

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

**3. Allocation Caps (Manager)**
```solidity
uint256 public max_allocation_per_strategy = 5000;  // 50%
uint256 public min_allocation_threshold = 1000;     // 10%
```

**Propósito:**
- **Max cap (50%)**: Limita exposición a una sola estrategia/protocolo
- **Min threshold (10%)**: Evita asignar cantidades insignificantes (gas waste)

---

**4. Max Strategies (Manager)**
```solidity
uint256 public constant MAX_STRATEGIES = 10;  // Hard-coded
```

**Propósito:**
- Previene gas DoS en loops de allocate/withdrawTo/harvest/rebalance
- Con 10 estrategias, cada loop tiene coste predecible

---

**5. Min Profit for Harvest (Vault)**
```solidity
uint256 public min_profit_for_harvest = 0.1 ether;
```

**Propósito:**
- Previene harvest no-rentables (gas > profit)
- Previene spam de harvest() por atacantes

---

### 3.3 Emergency Stop (Pausable)

```solidity
contract Vault is IVault, ERC4626, Ownable, Pausable {
    function deposit(...) public whenNotPaused { }
    function mint(...) public whenNotPaused { }
    function withdraw(...) public whenNotPaused { }
    function redeem(...) public whenNotPaused { }
    function harvest() external whenNotPaused { }
    function allocateIdle() external whenNotPaused { }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
```

**Cuándo usar:**
- Se detecta vulnerabilidad en vault o estrategias
- Hack en Aave/Compound/Uniswap afecta fondos
- Bug crítico en weighted allocation o harvest
- Mientras se investiga comportamiento anómalo

**Qué pausa:**
- Nuevos deposits
- Nuevos withdraws
- Harvest
- AllocateIdle
- No pausa rebalances (manager está separado)

**Nota:** Owner del manager debería remover estrategias comprometidas durante pausa.

---

### 3.4 Uso de SafeERC20

**Todas las operaciones con IERC20 usan SafeERC20:**
```solidity
using SafeERC20 for IERC20;

// En lugar de:
IERC20(asset).transfer(receiver, amount);           // ❌
IERC20(asset).transferFrom(user, vault, amount);    // ❌

// Usamos:
IERC20(asset).safeTransfer(receiver, amount);       // ✅
IERC20(asset).safeTransferFrom(user, vault, amount);// ✅
```

**Protecciones de SafeERC20:**
- Maneja tokens que no retornan bool en transfer (legacy tokens)
- Revierte si transfer falla silenciosamente
- Verifica return value correctamente

---

### 3.5 Harvest Fail-Safe

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
- Si AaveStrategy.harvest() falla (no hay rewards, Uniswap revierte, etc.), CompoundStrategy.harvest() continúa
- Previene que un fallo bloquee todo el harvest
- Emite evento para monitoring

---

### 3.6 Slippage Protection en Swaps

```solidity
// En AaveStrategy y CompoundStrategy
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
- Previene sandwich attacks (máximo 1% de impacto)
- Protege contra pools con baja liquidez
- Si el swap no puede conseguir 99%+, revierte (y fail-safe continúa)

---

## 4. Puntos de Centralización

El protocolo tiene puntos de centralización controlados por owners. En producción, estos deberían ser multisigs.

### 4.1 Owner del Vault

**Puede:**

1. **Pausar deposits/withdrawals/harvest**
```solidity
vault.pause();
// Todos los deposits, withdraws y harvest se bloquean
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

### 4.2 Owner del Manager

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

### 4.3 Single Point of Failure

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

## 5. Limitaciones Conocidas

El protocolo tiene limitaciones deliberadas (v1) y trade-offs conocidos:

### 5.1 Solo WETH

**Limitación:**
- Solo soporta WETH como asset
- No hay multi-asset vault

**Razones:**
- Simplicidad de v1
- Aave y Compound tienen mejores rates para ETH/WETH
- Multi-asset requiere price oracles (mayor superficie de ataque)

**Roadmap:**
- v2: Multi-asset con Chainlink price feeds

---

### 5.2 Weighted Allocation Básico

**Limitación:**
- Algoritmo simple: allocation proporcional a APY
- No considera volatilidad, liquidez, historial

**Fórmula actual:**
```solidity
target[i] = (strategy_apy[i] * BASIS_POINTS) / total_apy
// Con caps: max 50%, min 10%
```

**Mejoras potenciales (v2+):**
- Sharpe ratio (reward/risk)
- Liquidez disponible en protocolos
- Historial de APY (no solo snapshot)
- Machine learning para predecir APYs

---

### 5.3 Idle Buffer No Genera Yield

**Limitación:**
- WETH en idle buffer no está invertido
- Durante acumulación (0-10 ETH), no hay yield

**Trade-off:**
```
Gas savings > yield perdido en idle

Ejemplo:
- 5 ETH en idle durante 1 día
- APY perdido: 5% anual = 0.0007 ETH/día
- Gas ahorrado: 0.015 ETH (por no hacer allocate solo)
- Beneficio neto: 0.015 - 0.0007 = 0.0143 ETH
```

**Alternativa considerada:**
- Auto-compound idle en Aave (añade complejidad)

---

### 5.4 Rebalancing Manual

**Limitación:**
- No hay rebalancing automático on-chain
- Requiere keepers externos o usuarios

**Razones:**
- Rebalancing en cada depósito sería carísimo
- Keepers pueden elegir momento óptimo (gas bajo)
- shouldRebalance() es view (keepers pueden simular off-chain)

**Mitigaciones:**
- Cualquiera puede ejecutar (permissionless)
- Threshold del 2% previene ejecuciones innecesarias

---

### 5.5 Treasury Shares Ilíquidas

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

### 5.6 Harvest Depende de Liquidez Uniswap

**Limitación:**
- Si pools AAVE/WETH o COMP/WETH en Uniswap V3 no tienen liquidez, harvest falla
- Rewards se acumulan sin convertir a WETH

**Mitigaciones:**
- Pools AAVE/WETH y COMP/WETH son altamente líquidos en mainnet
- Fail-safe en StrategyManager permite que estrategias individuales fallen
- Rewards no se pierden, solo se acumulan para el siguiente harvest exitoso
- Slippage del 1% protege contra pools temporalmente ilíquidos

---

### 5.7 Max 10 Estrategias

**Limitación:**
- Máximo 10 estrategias activas simultáneamente (hard-coded)

**Razones:**
- Previene gas DoS en loops (allocate, withdrawTo, harvest, rebalance)
- Con 10 estrategias, gas cost es predecible y razonable
- Más de 10 estrategias probablemente no añaden diversificación significativa

---

## 6. Recomendaciones para Auditoría

Si este protocolo fuera a mainnet, auditoría debería enfocarse en:

### 6.1 Matemáticas Críticas

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

### 6.2 Edge Cases

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

---

### 6.3 Integración con Protocolos Externos

**Verificar:**

1. **Aave v3 devuelve valores esperados**
   - ¿Qué pasa si `getReserveData()` revierte?
   - ¿`claimAllRewards()` puede devolver 0 sin revertir?

2. **Compound v3 devuelve uint64 en getSupplyRate()**
   - ¿Conversión a uint256 es segura?
   - ¿Overflow al multiplicar por 315360000000?
   - ¿`claim()` puede devolver 0 sin revertir?

3. **Uniswap V3 swap edge cases**
   - ¿Qué pasa si pool no existe?
   - ¿Qué pasa si deadline expira?
   - ¿Slippage protection funciona con cantidades muy pequeñas?

4. **aTokens (Aave) hacen rebase correctamente**
   - ¿`balanceOf()` incluye yield acumulado siempre?

---

### 6.4 Reentrancy

**Puntos de atención:**

1. **¿Todas las external calls siguen CEI?**
   - Especialmente en `_withdraw()`, `harvest()`, `_distributePerformanceFee()`

2. **¿SafeERC20 protege contra reentrancy via ERC777?**
   - WETH no es ERC777, pero buena práctica

3. **¿harvest() puede ser llamado recursivamente?**
   - A través de strategy.harvest() → callback → vault.harvest()

---

### 6.5 Access Control

**Verificar:**

1. **¿Todos los setters son onlyOwner?**
2. **¿allocate/withdrawTo/harvest son realmente onlyVault?**
3. **¿deposit/withdraw/harvest de strategies son onlyManager?**
4. **¿rebalance puede ser llamado por cualquiera? (debe ser público)**
5. **¿initialize() solo se puede llamar una vez?**

---

## 7. Conclusión de Seguridad

### Fortalezas del Protocolo

**Arquitectura modular y clara**
- Separación de concerns (Vault, Manager, Strategies)
- Fácil de auditar y razonar

**Uso de estándares de industria**
- ERC4626 (OpenZeppelin)
- SafeERC20 para todas las transferencias
- Pausable para emergency stop

**Protecciones económicas**
- Min deposit previene rounding attacks
- Min profit previene harvest spam
- Slippage protection en swaps (1%)

**Circuit breakers múltiples**
- Max TVL, min deposit, allocation caps, max strategies
- Pausa de emergencia

**Harvest fail-safe**
- Try-catch individual por estrategia
- Si una falla, las demás continúan

**Sin permiso para operaciones críticas**
- Rebalance es público (cualquiera puede ejecutar si es rentable)
- Harvest es público (incentivizado para keepers externos)
- AllocateIdle es público (si idle >= threshold)

### Debilidades Conocidas

**Centralización del ownership**
- Single point of failure si owner pierde key
- Mitigación: Usar multisig en producción

**Trust en estrategias agregadas**
- Owner puede agregar estrategia maliciosa
- Mitigación: Whitelist + auditorías

**Dependencia de protocolos externos**
- Si Aave/Compound/Uniswap tienen exploit, fondos en riesgo
- Mitigación: Allocation caps (max 50%), fail-safe harvest

**Treasury shares ilíquidas**
- Treasury acumula shares que no puede vender fácilmente
- Mitigación: Diseño deliberado (auto-compound > liquidez)

**Harvest depende de Uniswap**
- Si pools de reward tokens no tienen liquidez, harvest falla
- Mitigación: Fail-safe, rewards se acumulan para siguiente intento

### Recomendaciones Finales

**Para lanzar a mainnet:**

1. **Auditoría profesional** (Trail of Bits, OpenZeppelin, Consensys)
2. **Testnet prolongado** (Sepolia → Mainnet)
3. **Bug bounty** (Immunefi, Code4rena)
4. **Multisig como owner** (mínimo 3/5)
5. **Monitoring on-chain** (Forta, Tenderly)
6. **Emergency playbook** documentado
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
