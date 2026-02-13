# Flujos de Usuario

Este documento describe los flujos de usuario paso a paso del Multi-Strategy Vault, con diagramas de secuencia y ejemplos numéricos concretos.

---

## 1. Flujo de Deposit

### Descripción General

El usuario deposita WETH en el vault y recibe shares (msvWETH). El WETH se acumula en el idle buffer hasta alcanzar el threshold (10 ETH), momento en el cual se auto-invierte en las estrategias.

### Flujo Paso a Paso

```
┌─────────┐          ┌──────────┐          ┌────────────┐          ┌──────────┐          ┌───────────┐
│ Usuario │          │  Vault   │          │  Manager   │          │ Strategy │          │ Protocol  │
└────┬────┘          └────┬─────┘          └─────┬──────┘          └────┬─────┘          └─────┬─────┘
     │                    │                      │                       │                      │
     │ 1. approve(vault)  │                      │                       │                      │
     ├───────────────────>│                      │                       │                      │
     │                    │                      │                       │                      │
     │ 2. deposit(100)    │                      │                       │                      │
     ├───────────────────>│                      │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 3. Verifica:         │                       │                      │
     │                    │    - assets >= 0.01  │                       │                      │
     │                    │    - TVL + assets    │                       │                      │
     │                    │      <= max_tvl      │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 4. Calcula shares    │                       │                      │
     │                    │    previewDeposit()  │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 5. transferFrom      │                       │                      │
     │<───────────────────┤    (user, vault, 100)│                       │                      │
     │                    │                      │                       │                      │
     │                    │ 6. idle_weth += 100  │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 7. _mint(shares)     │                       │                      │
     │<───────────────────┤                      │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 8. if idle >= 10 ETH │                       │                      │
     │                    │    _allocateIdle()   │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 9. transfer(manager) │                       │                      │
     │                    ├─────────────────────>│                       │                      │
     │                    │                      │                       │                      │
     │                    │ 10. allocate(100)    │                       │                      │
     │                    ├─────────────────────>│                       │                      │
     │                    │                      │                       │                      │
     │                    │                      │ 11. _computeTargets() │                      │
     │                    │                      │     - Aave: 50%       │                      │
     │                    │                      │     - Compound: 50%   │                      │
     │                    │                      │                       │                      │
     │                    │                      │ 12. transfer(aave, 50)│                      │
     │                    │                      ├──────────────────────>│                      │
     │                    │                      │                       │                      │
     │                    │                      │ 13. deposit(50)       │                      │
     │                    │                      ├──────────────────────>│                      │
     │                    │                      │                       │ 14. supply(weth, 50) │
     │                    │                      │                       ├─────────────────────>│
     │                    │                      │                       │                      │
     │                    │                      │ 15. transfer(comp, 50)│                      │
     │                    │                      ├──────────────────────>│                      │
     │                    │                      │                       │                      │
     │                    │                      │ 16. deposit(50)       │                      │
     │                    │                      ├──────────────────────>│                      │
     │                    │                      │                       │ 17. supply(weth, 50) │
     │                    │                      │                       ├─────────────────────>│
     │                    │                      │                       │                      │
     │ 18. Deposited event│                      │                       │                      │
     │<───────────────────┤                      │                       │                      │
     │                    │                      │                       │                      │
```

### Detalle de Pasos

**1-2. Aprobación y Depósito**
```solidity
// Usuario aprueba WETH al vault
IERC20(weth).approve(address(vault), 100 ether);

// Usuario deposita 100 WETH
uint256 shares = vault.deposit(100 ether, msg.sender);
```

**3. Verificaciones de Seguridad**
```solidity
// Verifica depósito mínimo
if (assets < min_deposit) revert StrategyVault__BelowMinDeposit();
// min_deposit = 0.01 ETH

// Verifica circuit breaker
if (totalAssets() + assets > max_tvl) revert StrategyVault__MaxTVLExceeded();
// max_tvl = 1000 ETH
```

**4. Cálculo de Shares**
```solidity
// Si es primer depósito: shares = assets
// Si ya hay TVL: shares = (assets * totalSupply) / totalAssets()
shares = previewDeposit(assets);

// Ejemplo primer depósito:
// shares = 100 ether (1:1)

// Ejemplo segundo depósito (TVL ya existe):
// totalSupply = 1000 shares, totalAssets = 1050 WETH (yield acumulado)
// shares = (100 * 1000) / 1050 = 95.24 shares
// El segundo usuario paga el precio actual que refleja el yield
```

**6. Acumulación en Idle Buffer**
```solidity
idle_weth += assets;  // Acumula en buffer sin invertir aún
```

**8-9. Auto-Allocate (Condicional)**
```solidity
if (idle_weth >= idle_threshold) {  // threshold = 10 ETH
    _allocateIdle();
}
```

**11. Cálculo de Weighted Allocation**
```solidity
// Supongamos APYs:
// Aave: 5% (500 bp), Compound: 5% (500 bp)
// total_apy = 1000 bp

// Target para Aave: (500 * 10000) / 1000 = 5000 bp = 50%
// Target para Compound: (500 * 10000) / 1000 = 5000 bp = 50%

// Aplica caps (max 50%, min 10%):
// Aave: 50% (dentro de límites)
// Compound: 50% (dentro de límites)
```

**12-17. Distribución a Estrategias**
```solidity
// Para cada estrategia:
uint256 amount_for_strategy = (assets * target) / 10000;

// Aave: (100 * 5000) / 10000 = 50 WETH
// Compound: (100 * 5000) / 10000 = 50 WETH

IERC20(asset).safeTransfer(address(strategy), amount);
strategy.deposit(amount);
```

### Ejemplo Numérico Completo

**Escenario**: Alice deposita 5 ETH, Bob deposita 5 ETH (alcanza threshold), Charlie deposita 5 ETH.

**Estado inicial:**
- `idle_weth = 0`
- `idle_threshold = 10 ETH`

**1. Alice deposita 5 ETH**
```
idle_weth = 5 ETH
shares_alice = 5 ETH (primer depósito, 1:1)
totalSupply = 5 shares
totalAssets = 5 ETH (todo en idle)

❌ NO auto-allocate (5 < 10)
```

**2. Bob deposita 5 ETH**
```
idle_weth = 10 ETH
shares_bob = (5 * 5) / 5 = 5 shares
totalSupply = 10 shares
totalAssets = 10 ETH

✅ AUTO-ALLOCATE (10 >= 10)
  → idle_weth = 0
  → Manager recibe 10 ETH
  → Distribuye: Aave 5 ETH, Compound 5 ETH
  → totalAssets = 0 (idle) + 10 (estrategias) = 10 ETH
```

**3. Charlie deposita 5 ETH**
```
idle_weth = 5 ETH
shares_charlie = (5 * 10) / 10 = 5 shares
totalSupply = 15 shares
totalAssets = 5 (idle) + 10 (estrategias) = 15 ETH

❌ NO auto-allocate (5 < 10)
```

**Beneficio del Idle Buffer:**
- Alice y Bob compartieron gas de 1 allocate en lugar de pagar 2 separados
- Gas cost total: ~300k gas (en lugar de 600k si depositaran directamente)
- Ahorro: 50% de gas para ambos usuarios

---

## 2. Flujo de Withdraw

### Descripción General

El usuario retira WETH del vault quemando shares. El vault cobra un 2% fee sobre el retiro. Si hay suficiente WETH en el idle buffer, se retira de ahí (gas-efficient). Si no, el vault solicita fondos al manager, que retira proporcionalmente de todas las estrategias.

### Flujo Paso a Paso

```
┌─────────┐          ┌──────────┐          ┌────────────┐          ┌──────────┐          ┌───────────┐
│ Usuario │          │  Vault   │          │  Manager   │          │ Strategy │          │ Protocol  │
└────┬────┘          └────┬─────┘          └─────┬──────┘          └────┬─────┘          └─────┬─────┘
     │                    │                      │                       │                      │
     │ 1. withdraw(100)   │                      │                       │                      │
     ├───────────────────>│                      │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 2. Calcula shares    │                       │                      │
     │                    │    previewWithdraw() │                       │                      │
     │                    │    shares = f(100)   │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 3. Verifica allowance│                       │                      │
     │                    │    (si caller != own)│                       │                      │
     │                    │                      │                       │                      │
     │                    │ 4. _burn(shares)     │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 5. Calcula fee:      │                       │                      │
     │                    │    fee = 2.04 WETH   │                       │                      │
     │                    │    gross = 102.04    │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 6. from_idle = min   │                       │                      │
     │                    │    (idle, gross)     │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 7. if from_idle < gr │                       │                      │
     │                    │    withdrawTo(manag) │                       │                      │
     │                    ├─────────────────────>│                       │                      │
     │                    │                      │                       │                      │
     │                    │                      │ 8. for each strategy: │                      │
     │                    │                      │    calculate propor.  │                      │
     │                    │                      │                       │                      │
     │                    │                      │ 9. withdraw(amount)   │                      │
     │                    │                      ├──────────────────────>│                      │
     │                    │                      │                       │ 10. withdraw(weth)   │
     │                    │                      │                       ├─────────────────────>│
     │                    │                      │                       │                      │
     │                    │                      │ 11. transfer(manager) │                      │
     │                    │                      │<──────────────────────┤                      │
     │                    │                      │                       │                      │
     │                    │ 12. transfer(vault)  │                       │                      │
     │                    │<─────────────────────┤                       │                      │
     │                    │                      │                       │                      │
     │                    │ 13. transfer(fee_rx) │                       │                      │
     │                    │    amount = 2.04     │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 14. transfer(user)   │                       │                      │
     │<───────────────────┤    amount = 100      │                       │                      │
     │                    │                      │                       │                      │
     │ 15. events         │                      │                       │                      │
     │<───────────────────┤                      │                       │                      │
     │                    │                      │                       │                      │
```

### Detalle de Pasos

**1-2. Solicitud de Retiro y Cálculo de Shares**
```solidity
// Usuario retira 100 WETH netos
uint256 shares = vault.withdraw(100 ether, msg.sender, msg.sender);

// Calcula shares a quemar (incluye fee)
shares = previewWithdraw(100 ether);

// Fórmula:
// assets_with_fee = (assets * 10000) / (10000 - withdrawal_fee)
// assets_with_fee = (100 * 10000) / (10000 - 200) = 102.04 WETH
// shares = convertToShares(102.04)
```

**4. Quema de Shares (CEI Pattern)**
```solidity
// CRITICAL: Quema shares ANTES de transferir assets (previene reentrancy)
_burn(owner, shares);
```

**5. Cálculo de Fee**
```solidity
// Usuario quiere 100 WETH netos
// Fee del 2%: fee = (100 * 200) / (10000 - 200) = 2.04 WETH
// Gross: 100 + 2.04 = 102.04 WETH a retirar del protocolo
uint256 fee = (assets * withdrawal_fee) / (10000 - withdrawal_fee);
uint256 gross_amount = assets + fee;
```

**6-7. Retiro Estratégico (Idle primero, Manager después)**
```solidity
uint256 from_idle = idle_weth > gross_amount ? gross_amount : idle_weth;
idle_weth -= from_idle;

uint256 from_manager = gross_amount - from_idle;
if (from_manager > 0) {
    manager.withdrawTo(from_manager, address(this));
}
```

**8-11. Retiro Proporcional de Estrategias**
```solidity
// Manager.withdrawTo() retira proporcionalmente para mantener ratios
uint256 total_assets = totalAssets();

for (uint256 i = 0; i < strategies.length; i++) {
    uint256 strategy_balance = strategies[i].totalAssets();

    // Retiro proporcional
    uint256 to_withdraw = (assets * strategy_balance) / total_assets;

    // Ejemplo:
    // Total: 100 WETH, quiere retirar: 50 WETH
    // Aave: 70 WETH → retira (50 * 70)/100 = 35 WETH
    // Compound: 30 WETH → retira (50 * 30)/100 = 15 WETH
    // Resultado: Aave 35, Compound 15 (mantiene ratio 70/30)

    strategy.withdraw(to_withdraw);
}

IERC20(asset).safeTransfer(receiver, assets);
```

**13-14. Distribución de Assets**
```solidity
// Fee al protocolo
IERC20(asset).safeTransfer(fee_receiver, fee);  // 2.04 WETH

// Assets netos al usuario
IERC20(asset).safeTransfer(receiver, assets);   // 100 WETH
```

### Ejemplo Numérico Completo

**Escenario**: Alice retira 100 WETH. Vault tiene 5 ETH idle, resto en estrategias.

**Estado inicial:**
```
idle_weth = 5 ETH
Aave: 70 ETH
Compound: 30 ETH
total_assets = 105 ETH
```

**1. Alice llama withdraw(100 ETH)**
```
Shares de Alice: 100 shares
```

**2. Cálculo de gross amount**
```
fee = (100 * 200) / 9800 = 2.04 WETH
gross_amount = 102.04 WETH
```

**3. Retiro desde idle buffer**
```
from_idle = min(5, 102.04) = 5 ETH
idle_weth = 0
```

**4. Retiro desde manager**
```
from_manager = 102.04 - 5 = 97.04 WETH

Total en estrategias = 70 + 30 = 100 WETH

De Aave: (97.04 * 70) / 100 = 67.93 WETH
De Compound: (97.04 * 30) / 100 = 29.11 WETH
```

**5. Estado final**
```
idle_weth = 0
Aave: 70 - 67.93 = 2.07 ETH
Compound: 30 - 29.11 = 0.89 ETH
total_assets = 0 + 2.07 + 0.89 = 2.96 ETH

Alice recibe: 100 WETH
Protocolo recibe: 2.04 WETH
```

**Beneficio del Retiro Proporcional:**
- No requiere recalcular target allocations (ahorro de gas)
- Mantiene ratios originales entre estrategias
- Si todas las estrategias tienen liquidez, el retiro siempre funciona

---

## 3. Flujo de Rebalance

### Descripción General

Cuando los APYs cambian, la distribución óptima cambia. Un keeper (bot o usuario) puede ejecutar rebalance() para mover fondos entre estrategias. El rebalance solo se ejecuta si el profit semanal esperado supera 2x el coste de gas estimado.

### Flujo Paso a Paso

```
┌─────────┐          ┌────────────┐          ┌──────────┐          ┌───────────┐
│ Keeper  │          │  Manager   │          │ Strategy │          │ Protocol  │
└────┬────┘          └─────┬──────┘          └────┬─────┘          └─────┬─────┘
     │                     │                       │                      │
     │ 1. shouldRebalance()│                       │                      │
     ├────────────────────>│                       │                      │
     │                     │                       │                      │
     │                     │ 2. _computeTargets()  │                      │
     │                     │    - Calcula nuevos   │                      │
     │                     │      APY-based targets│                      │
     │                     │                       │                      │
     │                     │ 3. Calcula deltas:    │                      │
     │                     │    for each strategy: │                      │
     │                     │      delta = current  │                      │
     │                     │              - target │                      │
     │                     │                       │                      │
     │                     │ 4. Estima profit:     │                      │
     │                     │    annual = sum(delta │                      │
     │                     │             * apy)    │                      │
     │                     │    weekly = annual/52 │                      │
     │                     │                       │                      │
     │                     │ 5. Estima gas:        │                      │
     │                     │    cost = moves * 300k│                      │
     │                     │           * gasprice  │                      │
     │                     │                       │                      │
     │                     │ 6. return profit >    │                      │
     │<────────────────────┤        gas * 2        │                      │
     │                     │                       │                      │
     │ 7. rebalance()      │                       │                      │
     ├────────────────────>│                       │                      │
     │                     │                       │                      │
     │                     │ 8. Verifica rentabilid│                      │
     │                     │    shouldRebalance()  │                      │
     │                     │                       │                      │
     │                     │ 9. Recalcula targets  │                      │
     │                     │    _calculateTargets()│                      │
     │                     │                       │                      │
     │                     │ 10. for excess strats:│                      │
     │                     │     withdraw(excess)  │                      │
     │                     ├──────────────────────>│                      │
     │                     │                       │ 11. withdraw(weth)   │
     │                     │                       ├─────────────────────>│
     │                     │                       │                      │
     │                     │ 12. transfer(manager) │                      │
     │                     │<──────────────────────┤                      │
     │                     │                       │                      │
     │                     │ 13. for needed strats:│                      │
     │                     │     transfer(strategy)│                      │
     │                     ├──────────────────────>│                      │
     │                     │                       │                      │
     │                     │ 14. deposit(amount)   │                      │
     │                     ├──────────────────────>│                      │
     │                     │                       │ 15. supply(weth)     │
     │                     │                       ├─────────────────────>│
     │                     │                       │                      │
     │ 16. Rebalanced event│                       │                      │
     │<────────────────────┤                       │                      │
     │                     │                       │                      │
```

### Detalle de Pasos

**1. Verificación de Rentabilidad**
```solidity
// Keeper llama view function primero (off-chain check)
bool should = manager.shouldRebalance();

if (should) {
    // Ejecuta rebalance on-chain
    manager.rebalance();
}
```

**2-3. Cálculo de Targets y Deltas**
```solidity
// APYs actuales:
// Aave: 4% (400 bp)
// Compound: 6% (600 bp)
// total_apy = 1000 bp

// Nuevos targets:
// Aave: (400 * 10000) / 1000 = 4000 bp = 40%
// Compound: (600 * 10000) / 1000 = 6000 bp = 60%

// Estado actual:
// Aave: 70 WETH (actual)
// Compound: 30 WETH (actual)
// total_tvl = 100 WETH

// Target balances:
// Aave: 100 * 40% = 40 WETH (target)
// Compound: 100 * 60% = 60 WETH (target)

// Deltas:
// Aave: 70 - 40 = +30 WETH (exceso)
// Compound: 30 - 60 = -30 WETH (necesita)
```

**4-5. Estimación de Profit vs Gas Cost**
```solidity
// Profit esperado:
// Movemos 30 WETH de Aave (4%) → Compound (6%)
// Diferencia: 6% - 4% = 2% anual
// Profit anual: 30 * 2% = 0.6 WETH
// Profit semanal: 0.6 * 7/365 = 0.0115 WETH

// Gas cost:
// 2 movimientos (withdraw Aave + deposit Compound)
// Estimado: 2 * 300k = 600k gas
// Gas price: 50 gwei
// Cost: 600k * 50 gwei = 0.03 ETH
// Con multiplier 2x: 0.06 ETH

// Decisión:
// profit_weekly (0.0115) < gas_cost * 2x (0.06)
// ❌ NO rebalancear (no rentable)
```

**Escenario rentable:**
```solidity
// Si diferencia APY fuera 10% (Aave 2%, Compound 12%):
// Profit anual: 30 * 10% = 3 WETH
// Profit semanal: 3 * 7/365 = 0.058 WETH
// Gas: 0.03 ETH
// Con multiplier: 0.06 ETH

// Decisión:
// 0.058 < 0.06 → Aún NO
// Pero si gas baja a 30 gwei:
// 0.058 > 0.036 → ✅ SÍ rebalancear
```

**10-15. Ejecución del Rebalance**
```solidity
// 1. Retira excesos
strategies_with_excess[0].withdraw(30 WETH);  // Aave

// 2. Deposita en estrategias con necesidad
IERC20(weth).transfer(address(compound_strategy), 30 WETH);
compound_strategy.deposit(30 WETH);

// Resultado:
// Aave: 40 WETH (target alcanzado)
// Compound: 60 WETH (target alcanzado)
```

### Ejemplo Numérico Completo

**Escenario**: APY de Compound sube de 5% a 8%, rebalance se vuelve rentable.

**Estado inicial (targets 50/50):**
```
Aave: 50 WETH (5% APY)
Compound: 50 WETH (5% APY)
total_tvl = 100 WETH
```

**Cambio de mercado:**
```
Aave: 5% APY (sin cambios)
Compound: 8% APY (subió 3%)
```

**1. Keeper llama shouldRebalance()**
```
Nuevos targets:
- total_apy = 500 + 800 = 1300 bp
- Aave: (500 * 10000) / 1300 = 3846 bp = 38.46%
- Compound: (800 * 10000) / 1300 = 6154 bp = 61.54%

Target balances:
- Aave: 100 * 38.46% = 38.46 WETH
- Compound: 100 * 61.54% = 61.54 WETH

Deltas:
- Aave: 50 - 38.46 = +11.54 WETH (exceso)
- Compound: 50 - 61.54 = -11.54 WETH (necesita)

Profit esperado:
- Movemos 11.54 WETH a Compound (8% APY)
- Profit anual: 11.54 * 8% = 0.92 WETH
- Profit semanal: 0.92 * 7/365 = 0.0177 WETH

Gas cost (50 gwei):
- 2 movimientos * 300k = 600k gas
- Cost: 600k * 50 * 1e-9 = 0.03 ETH
- Con 2x multiplier: 0.06 ETH

Decisión: 0.0177 < 0.06 → ❌ NO rentable todavía
```

**2. Gas price baja a 20 gwei**
```
Gas cost: 600k * 20 * 1e-9 = 0.012 ETH
Con 2x: 0.024 ETH

Decisión: 0.0177 < 0.024 → ❌ Aún no (por poco)
```

**3. TVL crece a 500 WETH**
```
Deltas:
- Aave: 250 - 192.3 = +57.7 WETH (exceso)
- Compound: 250 - 307.7 = -57.7 WETH (necesita)

Profit semanal: (57.7 * 8% * 7) / 365 = 0.088 WETH
Gas cost: 0.024 ETH

Decisión: 0.088 > 0.024 → ✅ RENTABLE!
```

**4. Keeper ejecuta rebalance()**
```
Movimiento:
- Retira 57.7 WETH de Aave
- Deposita 57.7 WETH en Compound

Estado final:
- Aave: 192.3 WETH (38.46%)
- Compound: 307.7 WETH (61.54%)

Keeper gana: MEV potencial (si hay) o simplemente ayuda al protocolo
```

---

## 4. Flujo de Idle Buffer Allocation

### Descripción General

El idle buffer acumula depósitos pequeños para ahorrar gas. Múltiples usuarios comparten el coste de un solo allocate.

### Ejemplo de 3 Usuarios

**Configuración:**
- `idle_threshold = 10 ETH`
- `idle_weth = 0` inicial

**Usuario 1: Alice deposita 5 ETH**
```
Estado antes:
  idle_weth = 0

Alice.deposit(5 ETH)
  → idle_weth = 5 ETH
  → shares_alice = 5
  → totalAssets = 5 ETH (todo en idle)

Check: idle_weth (5) < threshold (10)
❌ NO auto-allocate

Estado después:
  idle_weth = 5 ETH (acumulando)
  totalAssets = 5 ETH
```

**Usuario 2: Bob deposita 5 ETH**
```
Estado antes:
  idle_weth = 5 ETH

Bob.deposit(5 ETH)
  → idle_weth = 10 ETH
  → shares_bob = (5 * 5) / 5 = 5
  → totalAssets = 10 ETH

Check: idle_weth (10) >= threshold (10)
✅ AUTO-ALLOCATE!

_allocateIdle():
  1. amount = 10 ETH
  2. idle_weth = 0
  3. Transfer 10 ETH al manager
  4. manager.allocate(10 ETH)
     → Aave recibe 5 ETH
     → Compound recibe 5 ETH

Estado después:
  idle_weth = 0
  Aave: 5 ETH
  Compound: 5 ETH
  totalAssets = 0 + 5 + 5 = 10 ETH
```

**Usuario 3: Charlie deposita 5 ETH**
```
Estado antes:
  idle_weth = 0
  Aave: 5 ETH
  Compound: 5 ETH

Charlie.deposit(5 ETH)
  → idle_weth = 5 ETH
  → shares_charlie = (5 * 10) / 10 = 5
  → totalAssets = 5 + 5 + 5 = 15 ETH

Check: idle_weth (5) < threshold (10)
❌ NO auto-allocate (ciclo se repite)

Estado después:
  idle_weth = 5 ETH (acumulando de nuevo)
  Aave: 5 ETH
  Compound: 5 ETH
  totalAssets = 15 ETH
```

### Análisis de Gas

**Sin idle buffer (3 allocates separados):**
```
Alice: 300k gas * 50 gwei = 0.015 ETH
Bob: 300k gas * 50 gwei = 0.015 ETH
Charlie: 300k gas * 50 gwei = 0.015 ETH

Total gas: 900k
Total cost: 0.045 ETH
```

**Con idle buffer (1 allocate compartido para Alice + Bob):**
```
Alice: 0 ETH (no allocate)
Bob: 300k gas * 50 gwei = 0.015 ETH (trigger allocate por Alice + Bob)
Charlie: 0 ETH (no allocate aún)

Total gas: 300k
Total cost: 0.015 ETH

Ahorro: 0.045 - 0.015 = 0.03 ETH (66% ahorro)
Cost por usuario: 0.015 / 2 = 0.0075 ETH
```

### Flujo Manual de Allocate

**Cualquiera puede llamar allocateIdle() si idle >= threshold:**
```solidity
// Keeper ve que idle_weth = 10 ETH
vault.allocateIdle();

// Vault ejecuta:
if (idle_weth < idle_threshold) revert();  // Protección
_allocateIdle();
```

**Owner puede forzar allocate sin check:**
```solidity
// Owner ve que idle_weth = 5 ETH (bajo threshold)
// Pero quiere invertir igual (ej: fin de día)
vault.forceAllocateIdle();

// Vault ejecuta:
if (idle_weth == 0) revert();  // Solo verifica no-cero
_allocateIdle();
```

---

## Resumen de Flujos

| Flujo | Trigger | Auto/Manual | Gas Optimization |
|-------|---------|-------------|------------------|
| **Deposit** | Usuario deposita | Auto si idle >= 10 ETH | Idle buffer (ahorro 50-66%) |
| **Withdraw** | Usuario retira | Manual (usuario llama) | Retira de idle primero (si hay) |
| **Rebalance** | APY cambia | Manual (keeper/cualquiera) | Solo si profit > gas × 2 |
| **Idle Allocate** | idle >= threshold | Auto en deposit, o manual | Amortiza gas entre usuarios |

---

**Siguiente lectura**: [SECURITY.md](SECURITY.md) - Consideraciones de seguridad y protecciones implementadas
