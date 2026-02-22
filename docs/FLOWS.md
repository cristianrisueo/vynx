# Flujos de Usuario

Este documento describe los flujos de usuario paso a paso de VynX V2, con diagramas de secuencia y ejemplos numéricos concretos.

---

## 1. Flujo de Deposit

### Descripción General

El usuario deposita WETH en el vault y recibe shares (vxWETH). El WETH se acumula en el idle buffer hasta alcanzar el threshold configurable por tier (8 ETH Balanced / 12 ETH Aggressive), momento en el cual se auto-invierte en las estrategias del tier correspondiente.

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
     │                    │ 6. idle_buffer += 100│                       │                      │
     │                    │                      │                       │                      │
     │                    │ 7. _mint(shares)     │                       │                      │
     │<───────────────────┤                      │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 8. if idle >=        │                       │                      │
     │                    │    idle_threshold    │                       │                      │
     │                    │    (8-12 ETH)        │                       │                      │
     │                    │    _allocateIdle()   │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 9. transfer(manager) │                       │                      │
     │                    ├─────────────────────>│                       │                      │
     │                    │                      │                       │                      │
     │                    │ 10. allocate(100)    │                       │                      │
     │                    ├─────────────────────>│                       │                      │
     │                    │                      │                       │                      │
     │                    │                      │ 11. _computeTargets() │                      │
     │                    │                      │  [Balanced tier]      │                      │
     │                    │                      │  - Lido:   ~26.67%    │                      │
     │                    │                      │  - Aave:   ~33.33%    │                      │
     │                    │                      │  - Curve:  ~40.00%    │                      │
     │                    │                      │  [Aggressive tier]    │                      │
     │                    │                      │  - Curve:     50%     │                      │
     │                    │                      │  - UniswapV3: 50%     │                      │
     │                    │                      │                       │                      │
     │                    │                      │ 12. transfer(lido/    │                      │
     │                    │                      │     curve, amount)    │                      │
     │                    │                      ├──────────────────────>│                      │
     │                    │                      │                       │                      │
     │                    │                      │ 13. deposit(amount)   │                      │
     │                    │                      ├──────────────────────>│                      │
     │                    │                      │                       │ 14. unwrap/stake/    │
     │                    │                      │                       │     supply/mint      │
     │                    │                      │                       ├─────────────────────>│
     │                    │                      │                       │                      │
     │                    │                      │ 15. transfer(next     │                      │
     │                    │                      │     strategy, amount) │                      │
     │                    │                      ├──────────────────────>│                      │
     │                    │                      │                       │                      │
     │                    │                      │ 16. deposit(amount)   │                      │
     │                    │                      ├──────────────────────>│                      │
     │                    │                      │                       │ 17. unwrap/stake/    │
     │                    │                      │                       │     supply/mint      │
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
if (assets < min_deposit) revert Vault__DepositBelowMinimum();
// min_deposit = 0.01 ETH

// Verifica circuit breaker
if (totalAssets() + assets > max_tvl) revert Vault__MaxTVLExceeded();
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
idle_buffer += assets;  // Acumula en buffer sin invertir aún
```

**8-9. Auto-Allocate (Condicional)**
```solidity
if (idle_buffer >= idle_threshold) {  // threshold: 8 ETH (Balanced) / 12 ETH (Aggressive)
    _allocateIdle();
}
```

**11. Cálculo de Weighted Allocation (ejemplo Balanced tier)**
```solidity
// Supongamos APYs (Balanced tier):
// Lido: 4% (400 bp), Aave: 5% (500 bp), Curve: 6% (600 bp)
// total_apy = 1500 bp

// Target para Lido:  (400 * 10000) / 1500 = 2667 bp = 26.67%
// Target para Aave:  (500 * 10000) / 1500 = 3333 bp = 33.33%
// Target para Curve: (600 * 10000) / 1500 = 4000 bp = 40.00%

// Aplica caps (max 50%, min 20%):
// Lido:  26.67% (dentro de límites)
// Aave:  33.33% (dentro de límites)
// Curve: 40.00% (dentro de límites)
```

**12-17. Distribución a Estrategias**
```solidity
// Para cada estrategia:
uint256 amount_for_strategy = (assets * target) / 10000;

// Balanced tier (100 WETH):
// Lido:  (100 * 2667) / 10000 = 26.67 WETH → WETH → unwrap ETH → Lido stETH → wrap wstETH
// Aave:  (100 * 3333) / 10000 = 33.33 WETH → WETH → unwrap → Lido stETH → wstETH → Aave supply → aWstETH
// Curve: (100 * 4000) / 10000 = 40.00 WETH → WETH → unwrap → 50% a stETH → add_liquidity → gauge stake

IERC20(asset).safeTransfer(address(strategy), amount);
strategy.deposit(amount);
```

### Ejemplo Numérico Completo

**Escenario**: Alice deposita 4 ETH, Bob deposita 4 ETH (no alcanza threshold Balanced de 8 ETH aún), Carol deposita 4 ETH (se alcanza threshold).

**Estado inicial:**
- `idle_buffer = 0`
- `idle_threshold: 8 ETH (Balanced) / 12 ETH (Aggressive)`

**1. Alice deposita 4 ETH**
```
idle_buffer = 4 ETH
shares_alice = 4 ETH (primer depósito, 1:1)
totalSupply = 4 shares
totalAssets = 4 ETH (todo en idle)

NO auto-allocate (4 < 8)
```

**2. Bob deposita 4 ETH**
```
idle_buffer = 8 ETH
shares_bob = (4 * 4) / 4 = 4 shares
totalSupply = 8 shares
totalAssets = 8 ETH

AUTO-ALLOCATE (8 >= 8, Balanced threshold)
  → idle_buffer = 0
  → Manager recibe 8 ETH
  → Distribuye (Balanced): Lido 2.67 ETH, Aave 3.33 ETH, Curve 4 ETH (aprox. 26.67/33.33/40%)
  → totalAssets = 0 (idle) + 10 (estrategias) = 10 ETH
```

**3. Charlie deposita 5 ETH**
```
idle_buffer = 5 ETH
shares_charlie = (5 * 8) / 8 = 5 shares
totalSupply = 13 shares
totalAssets = 5 (idle) + 10 (estrategias) = 15 ETH

NO auto-allocate (5 < 8)
```

**Beneficio del Idle Buffer:**
- Alice y Bob compartieron gas de 1 allocate en lugar de pagar 2 separados
- Gas cost total: ~300k gas (en lugar de 600k si depositaran directamente)
- Ahorro: 50% de gas para ambos usuarios

---

## 2. Flujo de Withdraw

### Descripción General

El usuario retira WETH del vault quemando shares. Si hay suficiente WETH en el idle buffer, se retira de ahí (gas-efficient). Si no, el vault solicita fondos al manager, que retira proporcionalmente de todas las estrategias. El vault tolera hasta 20 wei de rounding por redondeo de protocolos externos.

> **Nota de seguridad**: `withdraw()` y `redeem()` funcionan **siempre**, incluso cuando el vault está pausado. En DeFi, la pausa bloquea entradas (deposit, mint) pero nunca las salidas: un usuario debe poder recuperar sus fondos independientemente del estado del vault.

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
     │                    │                      │                       │                      │
     │                    │ 3. Verifica allowance│                       │                      │
     │                    │    (si caller != own)│                       │                      │
     │                    │                      │                       │                      │
     │                    │ 4. _burn(shares)     │                       │                      │
     │                    │    [CEI pattern]     │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 5. from_idle = min   │                       │                      │
     │                    │    (idle_buffer, 100)│                       │                      │
     │                    │                      │                       │                      │
     │                    │ 6. if from_idle < 100│                       │                      │
     │                    │    withdrawTo(manag) │                       │                      │
     │                    ├─────────────────────>│                       │                      │
     │                    │                      │                       │                      │
     │                    │                      │ 7. for each strategy: │                      │
     │                    │                      │    proportional calc  │                      │
     │                    │                      │                       │                      │
     │                    │                      │ 8. withdraw(amount)   │                      │
     │                    │                      ├──────────────────────>│                      │
     │                    │                      │                       │ 9. withdraw(weth)    │
     │                    │                      │                       ├─────────────────────>│
     │                    │                      │                       │                      │
     │                    │                      │ 10. transfer(manager) │                      │
     │                    │                      │<──────────────────────┤                      │
     │                    │                      │                       │                      │
     │                    │ 11. transfer(vault)  │                       │                      │
     │                    │<─────────────────────┤                       │                      │
     │                    │                      │                       │                      │
     │                    │ 12. Verifica rounding│                       │                      │
     │                    │    (< 20 wei diff)   │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 13. transfer(user)   │                       │                      │
     │<───────────────────┤    amount = 100      │                       │                      │
     │                    │                      │                       │                      │
     │ 14. Withdrawn event│                      │                       │                      │
     │<───────────────────┤                      │                       │                      │
     │                    │                      │                       │                      │
```

### Detalle de Pasos

**1-2. Solicitud de Retiro y Cálculo de Shares**
```solidity
// Usuario retira 100 WETH
uint256 shares = vault.withdraw(100 ether, msg.sender, msg.sender);

// Calcula shares a quemar (ERC4626 standard, sin withdrawal fee)
shares = previewWithdraw(100 ether);
// shares = convertToShares(100) = (100 * totalSupply) / totalAssets()
```

**4. Quema de Shares (CEI Pattern)**
```solidity
// CRITICAL: Quema shares ANTES de transferir assets (previene reentrancy)
_burn(owner, shares);
```

**5-6. Retiro Estratégico (Idle primero, Estrategias después)**
```solidity
uint256 from_idle = assets.min(idle_buffer);
uint256 from_strategies = assets - from_idle;

if (from_idle > 0) {
    idle_buffer -= from_idle;
}

if (from_strategies > 0) {
    IStrategyManager(strategy_manager).withdrawTo(from_strategies, address(this));
}
```

**7-10. Retiro Proporcional de Estrategias**
```solidity
// Manager.withdrawTo() retira proporcionalmente para mantener ratios
// En V2 puede haber hasta 3 estrategias (Balanced) o 2 (Aggressive)
uint256 total_assets = totalAssets();

for (uint256 i = 0; i < strategies.length; i++) {
    uint256 strategy_balance = strategies[i].totalAssets();

    // Retiro proporcional
    uint256 to_withdraw = (assets * strategy_balance) / total_assets;

    // Captura monto real retirado (rounding de protocolos)
    uint256 actual_withdrawn = strategy.withdraw(to_withdraw);
    total_withdrawn += actual_withdrawn;
}

IERC20(asset).safeTransfer(receiver, total_withdrawn);
```

Cada estrategia convierte su posición a WETH antes de devolver fondos:
- **LidoStrategy**: wstETH → swap a WETH via Uniswap V3
- **AaveStrategy**: aWstETH → Aave withdraw → wstETH → swap a WETH via Uniswap V3
- **CurveStrategy**: unstake del gauge → remove_liquidity_one_coin → ETH → wrap a WETH
- **UniswapV3Strategy**: decrease liquidity → collect → swap USDC a WETH si necesario

**12. Verificación de Rounding Tolerance**
```solidity
uint256 to_transfer = assets.min(balance);

if (to_transfer < assets) {
    // Tolera hasta 20 wei de diferencia (rounding de Aave/Lido/Curve)
    require(assets - to_transfer < 20, "Excessive rounding");
}
```

**13. Transferencia al Usuario**
```solidity
IERC20(asset).safeTransfer(receiver, to_transfer);
```

### Ejemplo Numérico Completo

**Escenario**: Alice retira 100 WETH. Vault Balanced tiene 5 ETH idle, resto en estrategias.

**Estado inicial:**
```
idle_buffer = 5 ETH
LidoStrategy:  35 ETH
AaveStrategy:  35 ETH
CurveStrategy: 30 ETH
total_assets = 105 ETH
```

**1. Alice llama withdraw(100 ETH)**
```
Shares de Alice: calcula previewWithdraw(100)
```

**2. Cálculo de shares (ERC4626, sin fee)**
```
shares = convertToShares(100)
```

**3. Quema shares (CEI pattern)**

**4. Retiro desde idle buffer**
```
from_idle = min(5, 100) = 5 ETH
idle_buffer = 0
```

**5. Retiro desde manager**
```
from_strategies = 100 - 5 = 95 WETH

Total en estrategias = 35 + 35 + 30 = 100 WETH

De LidoStrategy:  (95 * 35) / 100 = 33.25 WETH (wstETH → Uniswap V3 → WETH)
De AaveStrategy:  (95 * 35) / 100 = 33.25 WETH (aWstETH → Aave withdraw → wstETH → Uniswap V3 → WETH)
De CurveStrategy: (95 * 30) / 100 = 28.50 WETH (gauge unstake → remove_liquidity_one_coin → ETH → wrap WETH)
```

**6. Verificación de rounding**
```
to_transfer = min(100, balance_actual)
Diferencia: 100 - 99.999999999999999997 = 3 wei
3 < 20 → Dentro de tolerancia
```

**7. Estado final**
```
idle_buffer = 0
LidoStrategy:  35 - 33.25 = 1.75 ETH
AaveStrategy:  35 - 33.25 = 1.75 ETH
CurveStrategy: 30 - 28.50 = 1.50 ETH
total_assets = 0 + 1.75 + 1.75 + 1.50 = 5 ETH

Alice recibe: ~100 WETH (menos ~3 wei por rounding)
```

**Beneficio del Retiro Proporcional:**
- No requiere recalcular target allocations (ahorro de gas)
- Mantiene ratios originales entre estrategias
- Si todas las estrategias tienen liquidez, el retiro siempre funciona

---

## 3. Flujo de Harvest

### Descripción General

El harvest cosecha rewards de todas las estrategias activas, los convierte a WETH y los reinvierte automáticamente en cada estrategia. Cada estrategia en V2 tiene un mecanismo de harvest diferente. LidoStrategy no genera rewards activos (el yield viene del exchange rate wstETH/stETH). AaveStrategy, CurveStrategy y UniswapV3Strategy sí generan rewards cosechables. Cualquiera puede ejecutar harvest — keepers externos reciben 1% del profit como incentivo, keepers oficiales no cobran.

El threshold mínimo de profit para que el harvest sea rentable es configurable por tier: `min_profit_for_harvest: 0.08 ETH (Balanced) / 0.12 ETH (Aggressive)`.

### Flujo Paso a Paso

```
┌─────────┐          ┌──────────┐          ┌────────────┐          ┌──────────┐          ┌───────────┐
│ Keeper  │          │  Vault   │          │  Manager   │          │ Strategy │          │ Protocol  │
└────┬────┘          └────┬─────┘          └─────┬──────┘          └────┬─────┘          └─────┬─────┘
     │                    │                      │                       │                      │
     │ 1. harvest()       │                      │                       │                      │
     ├───────────────────>│                      │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 2. manager.harvest() │                       │                      │
     │                    ├─────────────────────>│                       │                      │
     │                    │                      │                       │                      │
     │                    │                      │ 3. try lido.harvest() │                      │
     │                    │                      ├──────────────────────>│                      │
     │                    │                      │                       │ (yield via exchange  │
     │                    │                      │                       │  rate, no tx needed) │
     │                    │                      │ 4. return 0           │                      │
     │                    │                      │<──────────────────────┤                      │
     │                    │                      │                       │                      │
     │                    │                      │ 5. try aave.harvest() │                      │
     │                    │                      ├──────────────────────>│                      │
     │                    │                      │                       │ 6. claimAllRewards() │
     │                    │                      │                       ├─────────────────────>│
     │                    │                      │                       │<─ AAVE tokens ───────┤
     │                    │                      │                       │                      │
     │                    │                      │                       │ 7. swap AAVE → WETH  │
     │                    │                      │                       │   via Uniswap V3     │
     │                    │                      │                       │                      │
     │                    │                      │                       │ 8. WETH → wstETH     │
     │                    │                      │                       │   via Lido + wrap    │
     │                    │                      │                       │                      │
     │                    │                      │                       │ 9. supply(wstETH)    │
     │                    │                      │                       ├─────────────────────>│
     │                    │                      │                       │   [auto-compound]    │
     │                    │                      │                       │                      │
     │                    │                      │ 10. return profit_aave│                      │
     │                    │                      │<──────────────────────┤                      │
     │                    │                      │                       │                      │
     │                    │                      │11. try curve.harvest()│                      │
     │                    │                      ├──────────────────────>│                      │
     │                    │                      │                       │12. gauge.claim_rewards│
     │                    │                      │                       ├─────────────────────>│
     │                    │                      │                       │<─ CRV tokens ────────┤
     │                    │                      │                       │                      │
     │                    │                      │                       │13. swap CRV → WETH   │
     │                    │                      │                       │   via Uniswap V3     │
     │                    │                      │                       │                      │
     │                    │                      │                       │14. WETH → stETH →    │
     │                    │                      │                       │    add_liquidity →   │
     │                    │                      │                       │    stake en gauge    │
     │                    │                      │                       ├─────────────────────>│
     │                    │                      │                       │   [auto-compound]    │
     │                    │                      │                       │                      │
     │                    │                      │15. return profit_curve│                      │
     │                    │                      │<──────────────────────┤                      │
     │                    │                      │                       │                      │
     │                    │                      │16. try uni.harvest()  │                      │
     │                    │                      ├──────────────────────>│                      │
     │                    │                      │                       │17. collect(fees)     │
     │                    │                      │                       ├─────────────────────>│
     │                    │                      │                       │<─ WETH + USDC ───────┤
     │                    │                      │                       │                      │
     │                    │                      │                       │18. swap USDC → WETH  │
     │                    │                      │                       │   via Uniswap V3     │
     │                    │                      │                       │                      │
     │                    │                      │                       │19. reinvest: mint    │
     │                    │                      │                       │    new LP position   │
     │                    │                      │                       ├─────────────────────>│
     │                    │                      │                       │   [auto-compound]    │
     │                    │                      │                       │                      │
     │                    │                      │20. return profit_uni  │                      │
     │                    │                      │<──────────────────────┤                      │
     │                    │                      │                       │                      │
     │                    │ 21. total_profit     │                       │                      │
     │                    │<─────────────────────┤                       │                      │
     │                    │                      │                       │                      │
     │                    │ 22. if profit >=     │                       │                      │
     │                    │  min_profit_for_harv │                       │                      │
     │                    │  (0.08/0.12 ETH):    │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 23. Paga keeper      │                       │                      │
     │<───────────────────┤     incentive (1%)   │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 24. Calcula perf fee │                       │                      │
     │                    │     (20% net profit) │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 25. Mint shares      │                       │                      │
     │                    │     → treasury (80%) │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 26. Transfer WETH    │                       │                      │
     │                    │     → founder (20%)  │                       │                      │
     │                    │                      │                       │                      │
     │ 27. Harvested event│                      │                       │                      │
     │<───────────────────┤                      │                       │                      │
     │                    │                      │                       │                      │
```

### Detalle de Pasos

**1. Cualquiera Puede Ejecutar Harvest**
```solidity
// Keeper externo (recibe 1% incentivo)
vault.harvest();

// Keeper oficial (no recibe incentivo)
vault.harvest();

// No importa quién llame — la diferencia es solo si cobra incentivo
```

**2-20. Harvest Fail-Safe en StrategyManager**
```solidity
// Manager itera todas las estrategias con try-catch
uint256 total_profit = 0;

for (uint256 i = 0; i < strategies.length; i++) {
    try strategies[i].harvest() returns (uint256 profit) {
        total_profit += profit;
    } catch Error(string memory reason) {
        // Si una falla, las demás continúan
        emit HarvestFailed(address(strategies[i]), reason);
    }
}

return total_profit;
```

**3-4. LidoStrategy.harvest() — yield via exchange rate**
```solidity
// LidoStrategy no realiza ninguna acción activa en harvest.
// El yield se acumula automáticamente en el exchange rate de wstETH/stETH.
// El valor de wstETH en WETH sube con cada rebase de Lido.
// harvest() devuelve 0 siempre.
function harvest() external returns (uint256) {
    return 0;
}
```

**5-10. AaveStrategy.harvest() — AAVE rewards → wstETH → Aave**
```solidity
// 1. Claimea rewards AAVE del RewardsController de Aave v3
address[] memory assets_list = new address[](1);
assets_list[0] = address(a_wst_eth_token);
(, uint256[] memory amounts) = rewards_controller.claimAllRewards(assets_list, address(this));

// 2. Si no hay rewards → return 0
uint256 claimed_aave = amounts[0];
if (claimed_aave == 0) return 0;

// 3. Swap AAVE → WETH via Uniswap V3 (con slippage protection 1%)
uint256 weth_received = uniswap_router.exactInputSingle(
    ISwapRouter.ExactInputSingleParams({
        tokenIn: aave_token,
        tokenOut: weth,
        fee: 3000,          // 0.3%
        recipient: address(this),
        amountIn: claimed_aave,
        amountOutMinimum: (claimed_aave_value_in_weth * 9900) / 10000,
        sqrtPriceLimitX96: 0
    })
);

// 4. WETH → ETH → submit a Lido → stETH → wrap → wstETH
IWETH(weth).withdraw(weth_received);
uint256 st_eth = lido.submit{value: weth_received}(address(0));
uint256 wst_eth = IWstETH(wst_eth_token).wrap(st_eth);

// 5. Auto-compound: re-supply wstETH a Aave v3
aave_pool.supply(address(wst_eth_token), wst_eth, address(this), 0);

return weth_received;  // profit expresado en WETH
```

**11-15. CurveStrategy.harvest() — CRV rewards → LP tokens → gauge**
```solidity
// 1. Claimea rewards CRV del gauge de Curve
curve_gauge.claim_rewards(address(this));
uint256 crv_balance = IERC20(crv_token).balanceOf(address(this));

if (crv_balance == 0) return 0;

// 2. Swap CRV → WETH via Uniswap V3 (con slippage protection 1%)
uint256 weth_received = uniswap_router.exactInputSingle(
    ISwapRouter.ExactInputSingleParams({
        tokenIn: crv_token,
        tokenOut: weth,
        fee: 3000,          // 0.3%
        recipient: address(this),
        amountIn: crv_balance,
        amountOutMinimum: (crv_value_in_weth * 9900) / 10000,
        sqrtPriceLimitX96: 0
    })
);

// 3. WETH → ETH → 50% a stETH via Lido
IWETH(weth).withdraw(weth_received);
uint256 half = weth_received / 2;
uint256 st_eth = lido.submit{value: half}(address(0));

// 4. add_liquidity al pool stETH/ETH de Curve → LP tokens
uint256[2] memory amounts = [weth_received - half, st_eth];
uint256 lp_received = curve_pool.add_liquidity{value: weth_received - half}(amounts, 0);

// 5. Auto-compound: stake LP tokens en el gauge
curve_gauge.deposit(lp_received);

return weth_received;  // profit expresado en WETH
```

**16-20. UniswapV3Strategy.harvest() — fees WETH+USDC → nueva posición LP**
```solidity
// 1. Collect fees acumulados de la posición NFT
(uint256 weth_fees, uint256 usdc_fees) = nonfungible_position_manager.collect(
    INonfungiblePositionManager.CollectParams({
        tokenId: position_token_id,
        recipient: address(this),
        amount0Max: type(uint128).max,
        amount1Max: type(uint128).max
    })
);

if (weth_fees == 0 && usdc_fees == 0) return 0;

// 2. Swap USDC → WETH via Uniswap V3
uint256 weth_from_usdc = 0;
if (usdc_fees > 0) {
    weth_from_usdc = uniswap_router.exactInputSingle(
        ISwapRouter.ExactInputSingleParams({
            tokenIn: usdc,
            tokenOut: weth,
            fee: 500,           // 0.05%
            recipient: address(this),
            amountIn: usdc_fees,
            amountOutMinimum: (usdc_fees_value_in_weth * 9900) / 10000,
            sqrtPriceLimitX96: 0
        })
    );
}

uint256 total_weth = weth_fees + weth_from_usdc;

// 3. Reinvierte: 50% swap a USDC → mint nueva posición LP (o incrementa la existente)
uint256 half_weth = total_weth / 2;
uint256 usdc_for_lp = uniswap_router.exactInputSingle(...);  // WETH → USDC

nonfungible_position_manager.mint(
    INonfungiblePositionManager.MintParams({
        token0: weth,
        token1: usdc,
        fee: 500,
        tickLower: current_tick - 960,
        tickUpper: current_tick + 960,
        amount0Desired: half_weth,
        amount1Desired: usdc_for_lp,
        amount0Min: 0,
        amount1Min: 0,
        recipient: address(this),
        deadline: block.timestamp
    })
);

return total_weth;  // profit expresado en WETH
```

**22-26. Distribución de Fees en Vault**
```solidity
// Verifica profit mínimo (configurable por tier)
if (profit < min_profit_for_harvest) return 0;
// Balanced: 0.08 ETH | Aggressive: 0.12 ETH

// Paga keeper externo (solo si no es oficial)
uint256 keeper_reward = 0;
if (!is_official_keeper[msg.sender]) {
    keeper_reward = (profit * keeper_incentive) / BASIS_POINTS;  // 1%
    IERC20(asset).safeTransfer(msg.sender, keeper_reward);
}

// Calcula performance fee sobre net profit
uint256 net_profit = profit - keeper_reward;
uint256 perf_fee = (net_profit * performance_fee) / BASIS_POINTS;  // 20%

// Distribuye:
// Treasury (80% perf fee) → mintea shares (auto-compound)
uint256 treasury_amount = (perf_fee * treasury_split) / BASIS_POINTS;
uint256 treasury_shares = convertToShares(treasury_amount);
_mint(treasury_address, treasury_shares);

// Founder (20% perf fee) → transfiere WETH (liquid)
uint256 founder_amount = (perf_fee * founder_split) / BASIS_POINTS;
IERC20(asset).safeTransfer(founder_address, founder_amount);
```

### Ejemplo Numérico Completo

**Escenario**: Keeper externo ejecuta harvest en Balanced tier después de 1 mes de acumulación.

**Estado inicial:**
```
TVL = 500 WETH (Balanced tier)
LidoStrategy:  167 WETH en wstETH (APY 4% vía exchange rate)
AaveStrategy:  167 WETH en aWstETH + rewards AAVE acumulados
CurveStrategy: 166 WETH en gauge LP tokens + rewards CRV acumulados
idle_buffer = 2 ETH
```

**1. StrategyManager.harvest() (fail-safe)**
```
LidoStrategy.harvest():
  - Sin acción activa (yield en exchange rate wstETH/stETH)
  - profit_lido = 0 (el TVL ya refleja el yield vía totalAssets())

AaveStrategy.harvest():
  - Claimea: 30 AAVE tokens
  - Swap: 30 AAVE → 1.5 WETH (Uniswap V3, 0.3% fee)
  - WETH → ETH → Lido stETH → wrap wstETH
  - Re-supply: wstETH → Aave Pool
  - profit_aave = 1.5 WETH

CurveStrategy.harvest():
  - Claimea: 200 CRV tokens
  - Swap: 200 CRV → 2.0 WETH (Uniswap V3, 0.3% fee)
  - WETH → ETH → 50% a stETH via Lido → add_liquidity → stake en gauge
  - profit_curve = 2.0 WETH

total_profit = 0 + 1.5 + 2.0 = 3.5 WETH
```

**2. Verificación de threshold**
```
3.5 WETH >= 0.08 ETH (min_profit_for_harvest, Balanced tier)
Continua con distribución
```

**3. Pago a keeper externo**
```
keeper_reward = 3.5 * 100 / 10000 = 0.035 WETH
→ Paga desde idle_buffer (2 ETH disponible)
→ idle_buffer = 2 - 0.035 = 1.965 ETH
→ Transfiere 0.035 WETH al keeper
```

**4. Performance fee**
```
net_profit = 3.5 - 0.035 = 3.465 WETH
perf_fee = 3.465 * 2000 / 10000 = 0.693 WETH
```

**5. Distribución de performance fee**
```
treasury_amount = 0.693 * 8000 / 10000 = 0.5544 WETH
→ Mintea shares equivalentes a 0.5544 WETH al treasury_address
→ Shares auto-compound (suben de valor con cada harvest futuro)

founder_amount = 0.693 * 2000 / 10000 = 0.1386 WETH
→ Retira de idle_buffer: 1.965 - 0.1386 = 1.826 ETH restante
→ Transfiere 0.1386 WETH al founder_address
```

**6. Estado final**
```
TVL = 500 + 3.5 (rewards reinvertidos) = 503.5 WETH
idle_buffer = 1.826 ETH
LidoStrategy:  167 WETH (yield implícito en exchange rate)
AaveStrategy:  168.5 WETH (incluye 1.5 WETH reinvertido como wstETH)
CurveStrategy: 168.0 WETH (incluye 2.0 WETH reinvertido como LP gauge)

Keeper recibió: 0.035 WETH
Treasury recibió: shares por 0.5544 WETH
Founder recibió: 0.1386 WETH
Usuarios se benefician: yield compuesto en estrategias
```

**Si el caller fuera keeper oficial:**
```
keeper_reward = 0 (oficial, no cobra)
net_profit = 3.5 WETH (sin descuento)
perf_fee = 3.5 * 2000 / 10000 = 0.7 WETH
treasury_amount = 0.56 WETH (más para el protocolo)
founder_amount = 0.14 WETH (más para el founder)
```

---

## 4. Flujo de Rebalance

### Descripción General

Cuando los APYs cambian, la distribución óptima cambia. Un keeper (bot o usuario) puede ejecutar rebalance() para mover fondos entre estrategias dentro de un tier. El rebalance solo se ejecuta si la diferencia de APY entre la mejor y peor estrategia supera el threshold del tier: 200 bp (2%) para Balanced o 300 bp (3%) para Aggressive. El TVL mínimo para que el rebalance sea válido es: 8 ETH (Balanced) / 12 ETH (Aggressive).

### Flujo Paso a Paso

```
┌─────────┐          ┌────────────┐          ┌──────────┐          ┌───────────┐
│ Keeper  │          │  Manager   │          │ Strategy │          │ Protocol  │
└────┬────┘          └─────┬──────┘          └────┬─────┘          └─────┬─────┘
     │                     │                       │                      │
     │ 1. shouldRebalance()│                       │                      │
     ├────────────────────>│                       │                      │
     │                     │                       │                      │
     │                     │ 2. Verifica:          │                      │
     │                     │    - >= 2 strategies  │                      │
     │                     │    - TVL >= 8 ETH     │                      │
     │                     │      (Balanced) /     │                      │
     │                     │      12 ETH (Aggress) │                      │
     │                     │    - max_apy - min_apy│                      │
     │                     │      >= 200 bp (Bal.) │                      │
     │                     │      >= 300 bp (Agg.) │                      │
     │                     │                       │                      │
     │<────────────────────┤ 3. return true/false  │                      │
     │                     │                       │                      │
     │ 4. rebalance()      │                       │                      │
     ├────────────────────>│                       │                      │
     │                     │                       │                      │
     │                     │ 5. shouldRebalance()  │                      │
     │                     │    [revierte si false]│                      │
     │                     │                       │                      │
     │                     │ 6. Recalcula targets  │                      │
     │                     │    _calculateTargets()│                      │
     │                     │                       │                      │
     │                     │ 7. for excess strats: │                      │
     │                     │     withdraw(excess)  │                      │
     │                     ├──────────────────────>│                      │
     │                     │                       │ 8. withdraw(weth)    │
     │                     │                       ├─────────────────────>│
     │                     │                       │                      │
     │                     │ 9. transfer(manager)  │                      │
     │                     │<──────────────────────┤                      │
     │                     │                       │                      │
     │                     │ 10. for needed strats:│                      │
     │                     │     transfer(strategy)│                      │
     │                     ├──────────────────────>│                      │
     │                     │                       │                      │
     │                     │ 11. deposit(amount)   │                      │
     │                     ├──────────────────────>│                      │
     │                     │                       │ 12. supply/stake/    │
     │                     │                       │     mint position    │
     │                     │                       ├─────────────────────>│
     │                     │                       │                      │
     │ 13. Rebalanced event│                       │                      │
     │<────────────────────┤                       │                      │
     │                     │                       │                      │
```

### Detalle de Pasos

**1. Verificación de Rentabilidad**
```solidity
// Keeper llama view function primero (off-chain check)
bool should = manager.shouldRebalance();

if (should) {
    manager.rebalance();
}
```

**2. Lógica de shouldRebalance()**
```solidity
// Requiere >= 2 estrategias
if (strategies.length < 2) return false;

// Requiere TVL mínimo (configurable por tier)
if (totalAssets() < min_tvl_for_rebalance) return false;
// Balanced: 8 ETH | Aggressive: 12 ETH

// Calcula diferencia de APY
uint256 max_apy = 0;
uint256 min_apy = type(uint256).max;

for (uint256 i = 0; i < strategies.length; i++) {
    uint256 apy = strategies[i].apy();
    if (apy > max_apy) max_apy = apy;
    if (apy < min_apy) min_apy = apy;
}

// Rebalance si diferencia >= rebalance_threshold del tier
// Balanced: 200 bp (2%) | Aggressive: 300 bp (3%)
return (max_apy - min_apy) >= rebalance_threshold;
```

### Ejemplo Numérico Completo

**Escenario (Balanced tier)**: El APY de AaveStrategy baja de 5% a 3% (reducción de liquidez disponible), lo que hace que el rebalance sea rentable.

**Estado inicial (targets según APYs previos: Lido 4%, Aave 5%, Curve 6%):**
```
LidoStrategy:  20 WETH (20% — target mínimo 20% aplicado)
AaveStrategy:  33 WETH (33% — target proporcional)
CurveStrategy: 47 WETH (47% — mayor peso por mayor APY)
total_tvl = 100 WETH
```

**Cambio de mercado:**
```
LidoStrategy:  4% APY (sin cambios, 400 bp)
AaveStrategy:  3% APY (bajó 2%, 300 bp) — liquidez en Aave disminuye
CurveStrategy: 6% APY (sin cambios, 600 bp)
```

**1. Keeper llama shouldRebalance()**
```
max_apy = 600 bp (CurveStrategy)
min_apy = 300 bp (AaveStrategy)
diferencia = 600 - 300 = 300 bp

Balanced rebalance_threshold = 200 bp
300 >= 200 → shouldRebalance = true
```

**2. Keeper ejecuta rebalance()**
```
Recalcula targets con nuevos APYs:
- total_apy = 400 + 300 + 600 = 1300 bp
- Lido:  (400 * 10000) / 1300 = 3077 bp = 30.77%
- Aave:  (300 * 10000) / 1300 = 2308 bp = 23.08%
- Curve: (600 * 10000) / 1300 = 4615 bp = 46.15%

Aplica caps (max 50%, min 20% para Balanced):
- Lido:  30.77% (dentro de límites)
- Aave:  23.08% (dentro de límites, > 20%)
- Curve: 46.15% (dentro de límites, < 50%)

Target balances:
- Lido:  100 * 30.77% = 30.77 WETH
- Aave:  100 * 23.08% = 23.08 WETH
- Curve: 100 * 46.15% = 46.15 WETH

Deltas (actual vs target):
- Lido:  20 - 30.77 = -10.77 WETH (necesita más fondos)
- Aave:  33 - 23.08 = +9.92 WETH (exceso, APY bajó)
- Curve: 47 - 46.15 = +0.85 WETH (exceso mínimo)
```

**3. Ejecución del rebalance**
```
1. Retira 9.92 WETH de AaveStrategy:
   aWstETH → Aave withdraw → wstETH → Uniswap V3 → WETH

2. Retira 0.85 WETH de CurveStrategy:
   gauge unstake → remove_liquidity_one_coin → ETH → wrap WETH

3. Transfiere 10.77 WETH a LidoStrategy:
   WETH → unwrap ETH → Lido stETH → wrap wstETH

Estado final:
- LidoStrategy:  30.77 WETH (30.77%)
- AaveStrategy:  23.08 WETH (23.08%)
- CurveStrategy: 46.15 WETH (46.15%)
- Los fondos ahora generan más yield al estar mejor distribuidos
```

**Escenario donde no se rebalancea (Balanced tier):**
```
LidoStrategy:  4% APY (400 bp)
AaveStrategy:  5% APY (500 bp)
CurveStrategy: 6% APY (600 bp)
diferencia = 600 - 400 = 200 bp

200 >= 200 (rebalance_threshold Balanced) → shouldRebalance = true (justo en el límite)

Si la diferencia fuera 199 bp:
199 < 200 → shouldRebalance = false → No vale la pena mover fondos
```

**Escenario donde no se rebalancea (Aggressive tier):**
```
CurveStrategy:     6% APY (600 bp)
UniswapV3Strategy: 8% APY (800 bp)
diferencia = 800 - 600 = 200 bp

Aggressive rebalance_threshold = 300 bp
200 < 300 → shouldRebalance = false → La diferencia no justifica el gas de rebalance
```

---

## 5. Flujo de Idle Buffer Allocation

### Descripción General

El idle buffer acumula depósitos pequeños para ahorrar gas. Múltiples usuarios comparten el coste de un solo allocate. El threshold es configurable por tier: 8 ETH para Balanced y 12 ETH para Aggressive.

### Ejemplo de 3 Usuarios (Balanced tier, idle_threshold = 8 ETH)

**Configuración:**
- `idle_threshold: 8 ETH (Balanced) / 12 ETH (Aggressive)`
- `idle_buffer = 0` inicial

**Usuario 1: Alice deposita 4 ETH**
```
Estado antes:
  idle_buffer = 0

Alice.deposit(4 ETH)
  → idle_buffer = 4 ETH
  → shares_alice = 4
  → totalAssets = 4 ETH (todo en idle)

Check: idle_buffer (4) < threshold (8)
NO auto-allocate

Estado después:
  idle_buffer = 4 ETH (acumulando)
  totalAssets = 4 ETH
```

**Usuario 2: Bob deposita 4 ETH**
```
Estado antes:
  idle_buffer = 4 ETH

Bob.deposit(4 ETH)
  → idle_buffer = 8 ETH
  → shares_bob = (4 * 4) / 4 = 4
  → totalAssets = 8 ETH

Check: idle_buffer (8) >= threshold (8)
AUTO-ALLOCATE!

_allocateIdle():
  1. to_allocate = 8 ETH
  2. idle_buffer = 0
  3. Transfer 8 ETH al manager
  4. manager.allocate(8 ETH) — Balanced tier
     → LidoStrategy  recibe 2.13 ETH (26.67%)
        WETH → unwrap ETH → Lido stETH → wrap wstETH
     → AaveStrategy  recibe 2.67 ETH (33.33%)
        WETH → unwrap → Lido stETH → wstETH → Aave supply → aWstETH
     → CurveStrategy recibe 3.20 ETH (40.00%)
        WETH → unwrap → 50% a stETH → add_liquidity → gauge stake

Estado después:
  idle_buffer = 0
  LidoStrategy:  2.13 ETH
  AaveStrategy:  2.67 ETH
  CurveStrategy: 3.20 ETH
  totalAssets = 0 + 2.13 + 2.67 + 3.20 = 8 ETH
```

**Usuario 3: Charlie deposita 4 ETH**
```
Estado antes:
  idle_buffer = 0
  LidoStrategy:  2.13 ETH
  AaveStrategy:  2.67 ETH
  CurveStrategy: 3.20 ETH

Charlie.deposit(4 ETH)
  → idle_buffer = 4 ETH
  → shares_charlie = (4 * 8) / 8 = 4
  → totalAssets = 4 + 2.13 + 2.67 + 3.20 = 12 ETH

Check: idle_buffer (4) < threshold (8)
NO auto-allocate (ciclo se repite)

Estado después:
  idle_buffer = 4 ETH (acumulando de nuevo)
  LidoStrategy:  2.13 ETH
  AaveStrategy:  2.67 ETH
  CurveStrategy: 3.20 ETH
  totalAssets = 12 ETH
```

### Análisis de Gas

**Sin idle buffer (3 allocates separados, 3 estrategias):**
```
Alice:   350k gas * 50 gwei = 0.0175 ETH
Bob:     350k gas * 50 gwei = 0.0175 ETH
Charlie: 350k gas * 50 gwei = 0.0175 ETH

Total gas: 1050k
Total cost: 0.0525 ETH
```

**Con idle buffer (1 allocate compartido para Alice + Bob):**
```
Alice:   0 ETH (no allocate)
Bob:     350k gas * 50 gwei = 0.0175 ETH (trigger allocate por Alice + Bob)
Charlie: 0 ETH (no allocate aún)

Total gas: 350k
Total cost: 0.0175 ETH

Ahorro: 0.0525 - 0.0175 = 0.035 ETH (66% ahorro)
Cost por usuario: 0.0175 / 2 = 0.00875 ETH
```

### Flujo Manual de Allocate

**Cualquiera puede llamar allocateIdle() si idle >= threshold:**
```solidity
// Keeper ve que idle_buffer = 8 ETH (Balanced) o 12 ETH (Aggressive)
vault.allocateIdle();

// Vault ejecuta:
if (idle_buffer < idle_threshold) revert Vault__InsufficientIdleBuffer();
_allocateIdle();
```

---

## 6. Flujos del Router (Multi-Token)

### Descripción General

El Router permite depositar y retirar usando ETH nativo o cualquier ERC20 con pool de Uniswap V3, sin necesidad de tener WETH previamente. El Router swapea el token a WETH, deposita en el Vault, y el usuario recibe shares directamente.

### Flujo: Depositar USDC vía Router

**Escenario**: Alice tiene 5000 USDC y quiere depositar en VynX sin tener que comprar WETH manualmente.

```
┌─────────┐          ┌──────────┐          ┌────────────┐          ┌──────────┐
│ Alice   │          │  Router  │          │ Uniswap V3 │          │  Vault   │
└────┬────┘          └────┬─────┘          └─────┬──────┘          └────┬─────┘
     │                    │                      │                       │
     │ 1. approve(router) │                      │                       │
     │ ───────────────────>                      │                       │
     │                    │                      │                       │
     │ 2. zapDepositERC20 │                      │                       │
     │    (USDC, 5000e6)  │                      │                       │
     │ ───────────────────>                      │                       │
     │                    │                      │                       │
     │                    │ 3. transferFrom      │                       │
     │                    │    (alice → router)  │                       │
     │<────────────────────                      │                       │
     │                    │                      │                       │
     │                    │ 4. approve(uniswap)  │                       │
     │                    │ ────────────────────>│                       │
     │                    │                      │                       │
     │                    │ 5. exactInputSingle  │                       │
     │                    │    USDC → WETH       │                       │
     │                    │ ────────────────────>│                       │
     │                    │<─ 2.1 WETH ──────────│                       │
     │                    │                      │                       │
     │                    │ 6. vault.deposit(2.1 WETH, alice)             │
     │                    │ ─────────────────────────────────────────────>│
     │<─ shares ──────────────────────────────────────────────────────────│
     │                    │                      │                       │
     │                    │ 7. balance check     │                       │
     │                    │    (must be 0)       │                       │
     │                    │                      │                       │
```

**Estado final:**
- Alice gastó: 5000 USDC
- Alice recibió: ~2.1 shares del vault (equivalente a ~2.1 WETH depositado)
- Router balance: 0 (stateless verificado)

### Flujo: Retirar a ETH nativo vía Router

**Escenario**: Alice tiene shares y quiere retirar en ETH nativo (no WETH).

```
┌─────────┐          ┌──────────┐          ┌──────────┐
│ Alice   │          │  Router  │          │  Vault   │
└────┬────┘          └────┬─────┘          └────┬─────┘
     │                    │                      │
     │ 1. vault.approve   │                      │
     │    (router, shares)│                      │
     │ ───────────────────>                      │
     │                    │                      │
     │ 2. zapWithdrawETH  │                      │
     │    (shares)        │                      │
     │ ───────────────────>                      │
     │                    │                      │
     │                    │ 3. transferFrom      │
     │                    │    (alice → router)  │
     │<────────────────────                      │
     │                    │                      │
     │                    │ 4. vault.redeem      │
     │                    │    (shares, router)  │
     │                    │ ────────────────────>│
     │                    │<─ WETH ──────────────│
     │                    │                      │
     │                    │ 5. WETH.withdraw()   │
     │                    │    (unwrap)          │
     │                    │                      │
     │                    │ 6. transfer ETH      │
     │<─ ETH ──────────────                      │
     │                    │                      │
     │                    │ 7. balance check     │
     │                    │    (must be 0)       │
     │                    │                      │
```

**Estado final:**
- Alice quemó: shares
- Alice recibió: ETH nativo (no WETH)
- Router balance: 0 WETH, 0 ETH (stateless verificado)

### Ejemplo Numérico: Depósito Multi-Token Round-Trip

**Setup:** Alice deposita 5000 USDC → retira en DAI (tokens diferentes).

**1. Depósito (USDC → WETH → shares)**
```
Alice tiene: 5000 USDC
Pool USDC/WETH (Uniswap V3, fee 0.05%): 1 USDC ≈ 0.00042 WETH

zapDepositERC20(USDC, 5000e6, 500, min_weth_out):
  - Swap: 5000 USDC → 2.1 WETH (slippage + fee ≈ 0.1%)
  - Deposit: 2.1 WETH → 2.1 shares (ratio 1:1 primer depósito)

Alice recibe: 2.1 shares
Router balance: 0 (stateless)
```

**2. Retiro (shares → WETH → DAI)**
```
Alice tiene: 2.1 shares
Pool WETH/DAI (Uniswap V3, fee 0.05%): 1 WETH ≈ 2380 DAI

zapWithdrawERC20(2.1 shares, DAI, 500, min_dai_out):
  - Redeem: 2.1 shares → 2.1 WETH
  - Swap: 2.1 WETH → 4998 DAI (slippage + fee ≈ 0.1%)

Alice recibe: 4998 DAI
Alice gastó neto: 2 USDC (slippage + fees de dos swaps)
Router balance: 0 WETH, 0 DAI (stateless)
```

---

## 7. Flujo de Emergency Exit

### Descripción General

Emergency Exit es el mecanismo de último recurso para drenar todas las estrategias cuando se detecta un bug crítico o exploit activo. Transfiere todos los assets al vault para que los usuarios puedan retirar. La secuencia son 3 transacciones independientes (no atómicas) ejecutadas por los owners del vault y del manager.

> **Importante**: Si Vault y Manager tienen owners distintos, cada owner ejecuta su paso. Si `emergencyExit()` revierte, el vault queda pausado pero los fondos permanecen seguros en las estrategias — ningún asset se pierde.

### Flujo Paso a Paso

```
┌──────────────┐          ┌──────────┐          ┌────────────┐          ┌──────────┐
│ Owner(s)     │          │  Vault   │          │  Manager   │          │ Strategy │
└──────┬───────┘          └────┬─────┘          └─────┬──────┘          └────┬─────┘
       │                       │                      │                       │
       │ 1. vault.pause()      │                      │                       │
       ├──────────────────────>│                      │                       │
       │                       │ Bloquea deposit,     │                       │
       │                       │ mint, harvest,       │                       │
       │                       │ allocateIdle         │                       │
       │                       │                      │                       │
       │                       │ withdraw/redeem      │                       │
       │                       │ siguen habilitados   │                       │
       │                       │                      │                       │
       │ 2. manager.emergencyExit()                   │                       │
       ├─────────────────────────────────────────────>│                       │
       │                       │                      │                       │
       │                       │                      │ 3. for each strategy: │
       │                       │                      │    balance = totalAssets()
       │                       │                      │    if balance == 0:   │
       │                       │                      │      skip             │
       │                       │                      │                       │
       │                       │                      │ 4. try withdraw(bal)  │
       │                       │                      ├──────────────────────>│
       │                       │                      │                       │
       │                       │                      │ 5. actual_withdrawn   │
       │                       │                      │<──────────────────────┤
       │                       │                      │                       │
       │                       │                      │ (si falla: emit       │
       │                       │                      │  HarvestFailed,       │
       │                       │                      │  continua con la      │
       │                       │                      │  siguiente estrategia)│
       │                       │                      │                       │
       │                       │ 6. safeTransfer(     │                       │
       │                       │    vault, total)     │                       │
       │                       │<─────────────────────┤                       │
       │                       │                      │                       │
       │                       │                      │ 7. emit EmergencyExit │
       │                       │                      │    (timestamp, total, │
       │                       │                      │     strategies_drained)│
       │                       │                      │                       │
       │ 8. vault.syncIdleBuffer()                    │                       │
       ├──────────────────────>│                      │                       │
       │                       │ 9. idle_buffer =     │                       │
       │                       │    WETH.balanceOf(    │                       │
       │                       │      address(this))  │                       │
       │                       │                      │                       │
       │                       │ 10. emit             │                       │
       │                       │   IdleBufferSynced   │                       │
       │                       │   (old, new)         │                       │
       │                       │                      │                       │
```

### Detalle de Pasos

**Paso 1: Pausar el Vault**
```solidity
// Owner del Vault ejecuta:
vault.pause();

// Efecto: bloquea deposit(), mint(), harvest(), allocateIdle()
// withdraw() y redeem() siguen funcionando (usuarios pueden salir)
```

**Paso 2: Drenar Estrategias**
```solidity
// Owner del Manager ejecuta:
manager.emergencyExit();

// Itera todas las estrategias con try-catch (fail-safe)
// Si una estrategia falla, emite HarvestFailed y continúa con las demás
// Transfiere todo el WETH rescatado al vault en una sola transferencia
```

**Paso 3: Reconciliar Accounting**
```solidity
// Owner del Vault ejecuta:
vault.syncIdleBuffer();

// idle_buffer = IERC20(asset()).balanceOf(address(this))
// Necesario porque emergencyExit() transfiere WETH directamente al vault
// sin pasar por deposit() ni _allocateIdle(), desincronizando idle_buffer
```

### Ejemplo Numérico Completo

**Escenario**: Se detecta un bug en CurveStrategy. El owner ejecuta la secuencia de emergencia para rescatar todos los fondos del Balanced tier.

**Estado inicial:**
```
idle_buffer = 3 ETH
LidoStrategy:  30 ETH en wstETH
AaveStrategy:  35 ETH en aWstETH
CurveStrategy: 32 ETH en gauge LP (estrategia con bug)
totalAssets = 3 + 30 + 35 + 32 = 100 ETH
```

**1. vault.pause()**
```
Estado: vault pausado
- deposit() → revierte
- mint() → revierte
- harvest() → revierte
- allocateIdle() → revierte
- withdraw() → funciona ✓
- redeem() → funciona ✓
```

**2. manager.emergencyExit()**
```
Itera estrategias:

LidoStrategy (30 ETH):
  try withdraw(30 ETH):
    wstETH → unwrap → stETH → swap → WETH
    actual_withdrawn = 29.999999999999999998 ETH (2 wei dust por conversión wstETH/stETH)
  ✓ éxito

AaveStrategy (35 ETH):
  try withdraw(35 ETH):
    aWstETH → Aave withdraw → wstETH → swap → WETH
    actual_withdrawn = 34.999999999999999999 ETH (1 wei dust)
  ✓ éxito

CurveStrategy (32 ETH):
  try withdraw(32 ETH):
    gauge unstake → remove_liquidity → ¡BUG! → revierte
  ✗ catch → emit HarvestFailed(curveStrategy, "bug error message")
  Continúa con las demás estrategias

total_rescued = 29.999...998 + 34.999...999 = 64.999...997 ETH
strategies_drained = 2

safeTransfer(vault, 64.999...997 ETH)
emit EmergencyExit(block.timestamp, 64.999...997, 2)
```

**3. vault.syncIdleBuffer()**
```
old_buffer = 3 ETH (valor anterior, desactualizado)
real_balance = WETH.balanceOf(vault) = 3 + 64.999...997 = 67.999...997 ETH
idle_buffer = 67.999...997 ETH (sincronizado con balance real)

emit IdleBufferSynced(3 ETH, 67.999...997 ETH)
```

**Estado final:**
```
idle_buffer = 67.999...997 ETH (sincronizado)
LidoStrategy:  ~0 ETH (drenada, posible 1-2 wei dust)
AaveStrategy:  ~0 ETH (drenada, posible 1 wei dust)
CurveStrategy: 32 ETH (no se pudo drenar — requiere acción manual)
totalAssets = 67.999...997 + 0 + 0 + 32 = 99.999...997 ETH

Usuarios pueden hacer withdraw() / redeem() para recuperar fondos del idle_buffer.
El owner debe gestionar CurveStrategy por separado (removeStrategy, parche, etc.).
```

### Edge Cases

| Caso | Comportamiento |
|------|---------------|
| Todas las estrategias con balance 0 | `emergencyExit()` completa sin error, `total_rescued = 0` |
| Una estrategia revierte | try-catch captura el error, emite `HarvestFailed`, continúa con las demás |
| Todas las estrategias revierten | `total_rescued = 0`, no se transfiere nada, pero el evento `EmergencyExit` se emite igualmente |
| Dust residual (1-2 wei) | Normal en conversiones wstETH/stETH. No afecta la operación |
| `syncIdleBuffer` sin `emergencyExit` previo | Funciona correctamente — simplemente sincroniza `idle_buffer` con el balance real |
| Owner del Vault ≠ Owner del Manager | Cada owner ejecuta su paso. No requiere coordinación atómica |

---

## Resumen de Flujos

| Flujo | Trigger | Auto/Manual | Gas Optimization | Fee |
|-------|---------|-------------|------------------|-----|
| **Deposit** | Usuario deposita | Auto si idle >= idle_threshold (8-12 ETH por tier) | Idle buffer (ahorro 50-66%) | Ninguna |
| **Withdraw** | Usuario retira | Manual (usuario llama) | Retira de idle primero | Ninguna (solo rounding ~wei) |
| **Harvest** | Keeper/Cualquiera | Manual (incentivizado) | Fail-safe, auto-compound por estrategia | 20% perf fee + 1% keeper |
| **Rebalance** | APY cambia > threshold | Manual (keeper/cualquiera) | Solo si APY diff >= 200 bp (Bal.) / 300 bp (Agg.) | Ninguna |
| **Idle Allocate** | idle >= threshold | Auto en deposit, o manual | Amortiza gas entre usuarios | Ninguna |
| **Router Deposit** | Usuario con ERC20/ETH | Manual (usuario llama) | Swap + deposit en 1 tx | Slippage Uniswap (0.05-1%) |
| **Router Withdraw** | Usuario quiere ERC20/ETH | Manual (usuario llama) | Redeem + swap en 1 tx | Slippage Uniswap (0.05-1%) |
| **Emergency Exit** | Bug crítico / exploit | Manual (owner, 3 txs) | try-catch fail-safe por estrategia | Ninguna |

### Referencia rápida de parámetros por tier

| Parámetro | Balanced (Lido + Aave + Curve) | Aggressive (Curve + UniswapV3) |
|-----------|-------------------------------|-------------------------------|
| `idle_threshold` | 8 ETH | 12 ETH |
| `min_tvl_for_rebalance` | 8 ETH | 12 ETH |
| `rebalance_threshold` | 200 bp (2%) | 300 bp (3%) |
| `min_profit_for_harvest` | 0.08 ETH | 0.12 ETH |
| `max_allocation_per_strategy` | 5000 bp (50%) | 7000 bp (70%) |
| `min_allocation_threshold` | 2000 bp (20%) | 1000 bp (10%) |
| `max_tvl` | 1000 ETH | 1000 ETH |

---

**Siguiente lectura**: [SECURITY.md](SECURITY.md) - Consideraciones de seguridad y protecciones implementadas
