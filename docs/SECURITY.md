# Consideraciones de Seguridad

Este documento analiza la postura de seguridad del Multi-Strategy Vault, incluyendo trust assumptions, vectores de ataque considerados, protecciones implementadas, puntos de centralización y limitaciones conocidas.

---

## 1. Trust Assumptions (En Qué Confiamos)

El protocolo Multi-Strategy Vault **confía explícitamente** en los siguientes componentes externos:

### Aave v3

**Nivel de confianza**: Alto ✅

**Razones:**
- Auditado múltiples veces por Trail of Bits, OpenZeppelin, Consensys Diligence, etc.
- Battle-tested con >$5B TVL en mainnet durante años
- Historial de seguridad robusto (sin hacks mayores)
- Código open-source revisado por comunidad

**Riesgos aceptados:**
- Si Aave sufre un exploit, podríamos perder fondos depositados en AaveStrategy
- Mitigación: Weighted allocation limita exposición al 50% máximo

### Compound v3

**Nivel de confianza**: Alto ✅

**Razones:**
- Auditado por OpenZeppelin, ChainSecurity, etc.
- Battle-tested con >$3B TVL en mainnet
- Compound v2 tiene historial de años sin hacks críticos
- V3 es reescritura más segura y gas-efficient

**Riesgos aceptados:**
- Si Compound sufre un exploit, podríamos perder fondos depositados en CompoundStrategy
- Mitigación: Weighted allocation limita exposición al 50% máximo

### OpenZeppelin Contracts

**Nivel de confianza**: Muy Alto ✅✅

**Razones:**
- Estándar de industria (ERC4626, ERC20, Ownable, Pausable)
- Auditados exhaustivamente
- Usados por miles de protocolos DeFi

**Componentes usados:**
- `ERC4626`: Estándar de vault tokenizado
- `SafeERC20`: Transferencias seguras de tokens
- `Ownable`: Control de acceso admin
- `Pausable`: Emergency stop

### WETH (Wrapped Ether)

**Nivel de confianza**: Muy Alto ✅✅

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
function withdraw(uint256 assets, address receiver, address owner) public {
    shares = previewWithdraw(assets);
    _burn(owner, shares);                    // Effect (modifica estado)
    _withdrawAssets(gross_amount, receiver); // Interaction (external call)
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
- Solo interactúa con contratos conocidos (strategies, WETH)

**Evaluación**: ✅ Protegido

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

2. **Withdrawal fee del 2%**
   - Penaliza retiros inmediatos
   - Atacante pagaría 2% fee, haciendo ataque no-rentable

3. **Yield acumula con tiempo**
   - Beneficio del rebalance se materializa durante semanas
   - Atacante no puede "flash-rebalance-withdraw"

**Evaluación**: ✅ Mitigado (económicamente no-rentable)

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
uint256 public min_deposit = 0.01 ether; // 0.01 ETH

function deposit(uint256 assets, address receiver) public {
    if (assets < min_deposit) revert StrategyVault__BelowMinDeposit();
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

**Evaluación**: ✅ Protegido (coste de ataque prohibitivo)

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

3. **Withdrawal fee previene arbitraje**
   - Flash loan → deposit → withdraw costaría 2% fee
   - No hay forma de extraer valor en una transacción

**Escenarios considerados:**
```solidity
// ❌ NO POSIBLE: Manipular APY
// APY viene de Aave/Compound directamente
// Flash loan no puede cambiar liquidity rate de Aave

// ❌ NO POSIBLE: Arbitrar precio share/asset
// Withdrawal fee del 2% hace arbitraje no-rentable

// ❌ NO POSIBLE: Votación con shares prestadas
// No existe sistema de governance
```

**Evaluación**: ✅ No aplicable (sin vectores de ataque viables)

---

### 2.5 Withdrawal Fee Bypass

**Descripción**: Atacante intenta evitar pagar el 2% fee durante retiros.

**Vectores considerados:**

1. **¿Puede transferir shares y que el receptor retire?**
```solidity
// Atacante: transfer(victim, shares)
// Victim: withdraw() → paga fee igual

// NO FUNCIONA: El fee se calcula en withdraw/redeem
// No importa quién transfirió las shares
```

2. **¿Puede explotar diferencia entre withdraw() y redeem()?**
```solidity
// withdraw(100 WETH):
//   fee = (100 * 200) / 9800 = 2.04 WETH
//   quema shares equivalentes a 102.04 WETH

// redeem(X shares):
//   gross_value = super.previewRedeem(shares)
//   fee = (gross_value * 200) / 10000
//   assets_net = gross_value - fee

// NO FUNCIONA: Ambas funciones aplican fee correctamente
```

3. **¿Puede explotar previewWithdraw vs previewRedeem?**
```solidity
function previewWithdraw(uint256 assets) public view {
    uint256 assets_with_fee = (assets * 10000) / (10000 - 200);
    return super.previewWithdraw(assets_with_fee);
}

function previewRedeem(uint256 shares) public view {
    uint256 assets = super.previewRedeem(shares);
    uint256 fee = (assets * 200) / 10000;
    return assets - fee;
}

// NO FUNCIONA: Matemática es consistente
// previewWithdraw incluye fee en shares a quemar
// previewRedeem descuenta fee de assets recibidos
```

**Evaluación**: ✅ Protegido (fee es inevitable)

---

## 3. Protecciones Implementadas

### 3.1 Control de Acceso

**Modificadores usados:**

```solidity
// StrategyVault
modifier onlyOwner()        // Funciones admin (pause, setters)
modifier whenNotPaused()    // Deposits y withdraws

// StrategyManager
modifier onlyOwner()        // Agregar/remover strategies, setters
modifier onlyVault()        // allocate(), withdrawTo()

// Strategies
modifier onlyManager()      // deposit(), withdraw()
```

**Jerarquía de permisos:**
```
Owner del Vault
  ↓
StrategyVault (contrato)
  ↓ (solo vault puede llamar)
StrategyManager (contrato)
  ↓ (solo manager puede llamar)
Strategies (contratos)
  ↓
Protocolos externos (Aave/Compound)
```

---

### 3.2 Circuit Breakers

**1. Max TVL (Vault)**
```solidity
uint256 public max_tvl = 1000 ether;

function deposit(uint256 assets, address receiver) public {
    if (totalAssets() + assets > max_tvl) {
        revert StrategyVault__MaxTVLExceeded();
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
        revert StrategyVault__BelowMinDeposit();
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

**Ejemplo:**
```solidity
// Si Aave tiene 90% del total_apy:
// Sin cap: Aave recibiría 90% del TVL
// Con cap: Aave recibe máximo 50%

// Si una estrategia tiene 5% del total_apy:
// Sin threshold: Recibiría 5% del TVL
// Con threshold: Recibe 0% (no vale la pena el gas)
```

---

### 3.3 Emergency Stop (Pausable)

```solidity
contract StrategyVault is ERC4626, Ownable, Pausable {
    function deposit(...) public whenNotPaused { }
    function mint(...) public whenNotPaused { }
    function withdraw(...) public whenNotPaused { }
    function redeem(...) public whenNotPaused { }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
```

**Cuándo usar:**
- Se detecta vulnerabilidad en vault o estrategias
- Hack en Aave/Compound afecta fondos
- Bug crítico en weighted allocation
- Mientras se investiga comportamiento anómalo

**Qué pausa:**
- ✅ Nuevos deposits
- ✅ Nuevos withdraws
- ❌ No pausa rebalances (manager está separado)

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

### 3.5 Rebalancing Solo Si Es Rentable

```solidity
function rebalance() external {
    bool should = shouldRebalance();
    if (!should) revert StrategyManager__RebalanceNotProfitable();
    // ...
}

function shouldRebalance() public view returns (bool) {
    // Calcula profit semanal esperado
    uint256 weekly_profit = ...;

    // Estima gas cost
    uint256 gas_cost = (num_moves * 300000) * tx.gasprice;

    // Solo permite rebalance si profit > gas × 2
    return weekly_profit > (gas_cost * gas_cost_multiplier / 100);
}
```

**Propósito:**
- Previene rebalances que destruyen valor
- Margen de 2x protege contra volatilidad de gas price
- Permite ajustar multiplicador si es necesario

---

## 4. Puntos de Centralización

El protocolo tiene puntos de centralización controlados por owners. En producción, estos deberían ser multisigs.

### 4.1 Owner del Vault

**Puede:**

1. **Pausar deposits/withdrawals**
```solidity
vault.pause();
// Todos los deposits y withdraws se bloquean
```

2. **Cambiar parámetros del protocolo**
```solidity
vault.setIdleThreshold(20 ether);        // Ajusta cuando invertir
vault.setMaxTVL(10000 ether);            // Aumenta circuit breaker
vault.setMinDeposit(0.1 ether);          // Sube depósito mínimo
vault.setWithdrawalFee(500);             // Aumenta fee a 5%
vault.setWithdrawalFeeReceiver(new_rx);  // Cambia quien recibe fees
```

**NO puede:**
- ❌ Robar fondos directamente
- ❌ Transferir WETH del vault sin pasar por withdraw
- ❌ Mintear shares sin depositar assets
- ❌ Modificar balances de usuarios

**Mitigaciones recomendadas:**
- Usar multisig (Gnosis Safe) como owner
- Timelock para cambios de parámetros sensibles
- Eventos emitidos para transparencia

---

### 4.2 Owner del Manager

**Puede:**

1. **Agregar estrategias maliciosas**
```solidity
// ⚠️ RIESGO: Owner puede agregar estrategia fake
manager.addStrategy(address(malicious_strategy));

// malicious_strategy.deposit() podría:
// - No depositar en protocolo real
// - Transferir WETH a address del atacante
// - Reportar totalAssets() falso
```

2. **Remover estrategias (con fondos)**
```solidity
// Owner debe retirar fondos primero
// Pero podría olvidar/ignorar y remover igual
manager.removeStrategy(address(aave_strategy));
```

3. **Cambiar parámetros de allocation**
```solidity
manager.setMaxAllocationPerStrategy(10000); // Permite 100% en una estrategia
manager.setMinAllocationThreshold(0);       // Permite micro-allocations
manager.setGasCostMultiplier(0);            // Permite rebalances no-rentables
```

**NO puede:**
- ❌ Llamar allocate() o withdrawTo() (solo vault puede)
- ❌ Robar WETH directamente del manager
- ❌ Depositar/retirar de estrategias directamente

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
target[i] = (strategy_apy[i] * 10000) / total_apy
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
- Gas cost varía demasiado (imposible predecir on-chain)
- Keepers pueden elegir momento óptimo

**Mitigaciones:**
- `shouldRebalance()` es view (keepers pueden simular off-chain)
- Cualquiera puede ejecutar (permissionless)
- Profit check previene ejecuciones no-rentables

---

### 5.5 Sin High Water Mark

**Limitación:**
- No hay tracking de entry price por usuario
- Withdrawal fee es flat 2%, no performance fee

**Consecuencias:**
- Usuario que entra en loss general paga fee igual
- No hay incentivo para managers (protocolo no cobra performance fee)

**Trade-off:**
- Flat fee es mucho más simple (gas-efficient)
- Performance fee requiere accounting complejo por usuario
- v1 prioriza simplicidad

---

## 6. Recomendaciones para Auditoría

Si este protocolo fuera a mainnet, auditoría debería enfocarse en:

### 6.1 Matemáticas Críticas

**Áreas de enfoque:**

1. **Cálculo de withdrawal fee**
```solidity
// ¿Es correcto que fee = (assets * 200) / (10000 - 200)?
// ¿Podría causar overflow/underflow?
// ¿Qué pasa si withdrawal_fee = 10000 (100%)?
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
   - ¿Usuario puede retirar desde otras strategies?
   - ¿O todo el withdraw falla?

5. **Rebalance con gas price extremadamente alto**
   - ¿Cálculo de profitability protege correctamente?

---

### 6.3 Integración con Protocolos Externos

**Verificar:**

1. **Aave v3 devuelve valores esperados**
   - ¿Qué pasa si `getReserveData()` revierte?
   - ¿Liquidity rate puede ser negativo? (No en Aave, pero verificar)

2. **Compound v3 devuelve uint64 en getSupplyRate()**
   - ¿Conversión a uint256 es segura?
   - ¿Overflow al multiplicar por 315360000000?

3. **aTokens (Aave) hacen rebase correctamente**
   - ¿`balanceOf()` incluye yield acumulado siempre?

---

### 6.4 Reentrancy

**Puntos de atención:**

1. **¿Todas las external calls siguen CEI?**
   - Especialmente en `_withdrawAssets()`

2. **¿SafeERC20 protege contra reentrancy via ERC777?**
   - WETH no es ERC777, pero buena práctica

---

### 6.5 Access Control

**Verificar:**

1. **¿Todos los setters son onlyOwner?**
2. **¿allocate/withdrawTo son realmente onlyVault?**
3. **¿deposit/withdraw de strategies son onlyManager?**
4. **¿rebalance puede ser llamado por cualquiera? (debe ser público)**

---

## 7. Conclusión de Seguridad

### Fortalezas del Protocolo

✅ **Arquitectura modular y clara**
- Separación de concerns (Vault, Manager, Strategies)
- Fácil de auditar y razonar

✅ **Uso de estándares de industria**
- ERC4626 (OpenZeppelin)
- SafeERC20 para todas las transferencias
- Pausable para emergency stop

✅ **Protecciones económicas**
- Withdrawal fee previene ataques de arbitraje
- Min deposit previene rounding attacks
- Rebalancing solo si es rentable

✅ **Circuit breakers múltiples**
- Max TVL, min deposit, allocation caps
- Pausa de emergencia

✅ **Sin permiso para operaciones críticas**
- Rebalance es público (cualquiera puede ejecutar si es rentable)
- allocateIdle es público (si idle >= threshold)

### Debilidades Conocidas

⚠️ **Centralización del ownership**
- Single point of failure si owner pierde key
- Mitigación: Usar multisig en producción

⚠️ **Trust en estrategias agregadas**
- Owner puede agregar estrategia maliciosa
- Mitigación: Whitelist + auditorías

⚠️ **Dependencia de protocolos externos**
- Si Aave/Compound tienen exploit, fondos en riesgo
- Mitigación: Allocation caps (max 50%)

⚠️ **Sin tracking de performance por usuario**
- Flat withdrawal fee puede ser injusto
- Mitigación: Diseño deliberado (simplicidad > fairness perfecta)

### Recomendaciones Finales

**Para lanzar a mainnet:**

1. **Auditoría profesional** (Trail of Bits, OpenZeppelin, Consensys)
2. **Testnet prolongado** (Sepolia → Goerli → Mainnet)
3. **Bug bounty** (Immunefi, Code4rena)
4. **Multisig como owner** (mínimo 3/5)
5. **Monitoring on-chain** (Forta, Tenderly)
6. **Emergency playbook** documentado
7. **TVL gradual** (empezar con max_tvl = 100 ETH, subir gradualmente)

**Para uso educacional:**
- ✅ Código es production-grade y seguro
- ✅ Arquitectura es sólida y extensible
- ✅ Buenas prácticas implementadas (CEI, SafeERC20, etc.)
- ⚠️ NO usar en mainnet sin auditoría formal

---

**Fin de la documentación de seguridad.**

Para más información, consulta:
- [ARCHITECTURE.md](ARCHITECTURE.md) - Decisiones de diseño
- [CONTRACTS.md](CONTRACTS.md) - Documentación de contratos
- [FLOWS.md](FLOWS.md) - Flujos de usuario
