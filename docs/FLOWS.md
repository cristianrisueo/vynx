# Flujos de Usuario

Este documento describe los flujos de usuario paso a paso de VynX V1, con diagramas de secuencia y ejemplos numéricos concretos.

---

## 1. Flujo de Deposit

### Descripción General

El usuario deposita WETH en el vault y recibe shares (vxWETH). El WETH se acumula en el idle buffer hasta alcanzar el threshold (10 ETH), momento en el cual se auto-invierte en las estrategias.

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
if (idle_buffer >= idle_threshold) {  // threshold = 10 ETH
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
- `idle_buffer = 0`
- `idle_threshold = 10 ETH`

**1. Alice deposita 5 ETH**
```
idle_buffer = 5 ETH
shares_alice = 5 ETH (primer depósito, 1:1)
totalSupply = 5 shares
totalAssets = 5 ETH (todo en idle)

❌ NO auto-allocate (5 < 10)
```

**2. Bob deposita 5 ETH**
```
idle_buffer = 10 ETH
shares_bob = (5 * 5) / 5 = 5 shares
totalSupply = 10 shares
totalAssets = 10 ETH

✅ AUTO-ALLOCATE (10 >= 10)
  → idle_buffer = 0
  → Manager recibe 10 ETH
  → Distribuye: Aave 5 ETH, Compound 5 ETH
  → totalAssets = 0 (idle) + 10 (estrategias) = 10 ETH
```

**3. Charlie deposita 5 ETH**
```
idle_buffer = 5 ETH
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

El usuario retira WETH del vault quemando shares. Si hay suficiente WETH en el idle buffer, se retira de ahí (gas-efficient). Si no, el vault solicita fondos al manager, que retira proporcionalmente de todas las estrategias. El vault tolera hasta 20 wei de rounding por redondeo de protocolos externos.

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

**12. Verificación de Rounding Tolerance**
```solidity
uint256 to_transfer = assets.min(balance);

if (to_transfer < assets) {
    // Tolera hasta 20 wei de diferencia (rounding de Aave/Compound)
    require(assets - to_transfer < 20, "Excessive rounding");
}
```

**13. Transferencia al Usuario**
```solidity
IERC20(asset).safeTransfer(receiver, to_transfer);
```

### Ejemplo Numérico Completo

**Escenario**: Alice retira 100 WETH. Vault tiene 5 ETH idle, resto en estrategias.

**Estado inicial:**
```
idle_buffer = 5 ETH
Aave: 70 ETH
Compound: 30 ETH
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

Total en estrategias = 70 + 30 = 100 WETH

De Aave: (95 * 70) / 100 = 66.5 WETH (real: ~66.499999999999999998 por rounding)
De Compound: (95 * 30) / 100 = 28.5 WETH (real: ~28.499999999999999999 por rounding)
```

**6. Verificación de rounding**
```
to_transfer = min(100, balance_actual)
Diferencia: 100 - 99.999999999999999997 = 3 wei
3 < 20 → ✅ Dentro de tolerancia
```

**7. Estado final**
```
idle_buffer = 0
Aave: 70 - 66.5 = 3.5 ETH
Compound: 30 - 28.5 = 1.5 ETH
total_assets = 0 + 3.5 + 1.5 = 5 ETH

Alice recibe: ~100 WETH (menos ~3 wei por rounding)
```

**Beneficio del Retiro Proporcional:**
- No requiere recalcular target allocations (ahorro de gas)
- Mantiene ratios originales entre estrategias
- Si todas las estrategias tienen liquidez, el retiro siempre funciona

---

## 3. Flujo de Harvest

### Descripción General

El harvest cosecha rewards (AAVE/COMP tokens) de todas las estrategias, los convierte a WETH via Uniswap V3, los reinvierte automáticamente, y distribuye performance fees. Cualquiera puede ejecutar harvest — keepers externos reciben 1% del profit como incentivo, keepers oficiales no cobran.

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
     │                    │                      │ 3. try aave.harvest() │                      │
     │                    │                      ├──────────────────────>│                      │
     │                    │                      │                       │ 4. claimAllRewards() │
     │                    │                      │                       ├─────────────────────>│
     │                    │                      │                       │<─ AAVE tokens ───────┤
     │                    │                      │                       │                      │
     │                    │                      │                       │ 5. swap AAVE → WETH  │
     │                    │                      │                       │   via Uniswap V3     │
     │                    │                      │                       │   (0.3% fee, 1% slip)│
     │                    │                      │                       │                      │
     │                    │                      │                       │ 6. supply(weth)      │
     │                    │                      │                       ├─────────────────────>│
     │                    │                      │                       │   [auto-compound]    │
     │                    │                      │                       │                      │
     │                    │                      │ 7. return profit_aave │                      │
     │                    │                      │<──────────────────────┤                      │
     │                    │                      │                       │                      │
     │                    │                      │ 8. try comp.harvest() │                      │
     │                    │                      ├──────────────────────>│                      │
     │                    │                      │                       │ 9. claim(comet)      │
     │                    │                      │                       ├─────────────────────>│
     │                    │                      │                       │<─ COMP tokens ───────┤
     │                    │                      │                       │                      │
     │                    │                      │                       │ 10. swap COMP → WETH │
     │                    │                      │                       │   via Uniswap V3     │
     │                    │                      │                       │                      │
     │                    │                      │                       │ 11. supply(weth)     │
     │                    │                      │                       ├─────────────────────>│
     │                    │                      │                       │   [auto-compound]    │
     │                    │                      │                       │                      │
     │                    │                      │ 12. return profit_comp│                      │
     │                    │                      │<──────────────────────┤                      │
     │                    │                      │                       │                      │
     │                    │ 13. total_profit     │                       │                      │
     │                    │<─────────────────────┤                       │                      │
     │                    │                      │                       │                      │
     │                    │ 14. if profit >=     │                       │                      │
     │                    │     0.1 ETH:         │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 15. Paga keeper      │                       │                      │
     │<───────────────────┤     incentive (1%)   │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 16. Calcula perf fee │                       │                      │
     │                    │     (20% net profit) │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 17. Mint shares      │                       │                      │
     │                    │     → treasury (80%) │                       │                      │
     │                    │                      │                       │                      │
     │                    │ 18. Transfer WETH    │                       │                      │
     │                    │     → founder (20%)  │                       │                      │
     │                    │                      │                       │                      │
     │ 19. Harvested event│                      │                       │                      │
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

**2-12. Harvest Fail-Safe en StrategyManager**
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

**3-6. AaveStrategy.harvest() (dentro del try)**
```solidity
// 1. Claimea rewards AAVE
address[] memory assets = new address[](1);
assets[0] = address(a_token);
(, uint256[] memory amounts) = rewards_controller.claimAllRewards(assets, address(this));

// 2. Si no hay rewards → return 0
uint256 claimed = amounts[0];
if (claimed == 0) return 0;

// 3. Calcula slippage protection
uint256 min_amount_out = (claimed * 9900) / 10000;  // 1% max slippage

// 4. Swap AAVE → WETH via Uniswap V3
uint256 amount_out = uniswap_router.exactInputSingle(
    ISwapRouter.ExactInputSingleParams({
        tokenIn: reward_token,        // AAVE
        tokenOut: asset_address,      // WETH
        fee: pool_fee,                // 3000 (0.3%)
        recipient: address(this),
        amountIn: claimed,
        amountOutMinimum: min_amount_out,
        sqrtPriceLimitX96: 0
    })
);

// 5. Auto-compound: re-supply WETH a Aave
aave_pool.supply(asset_address, amount_out, address(this), 0);

return amount_out;  // profit
```

**14-18. Distribución de Fees en Vault**
```solidity
// Verifica profit mínimo
if (profit < min_profit_for_harvest) return 0;  // 0.1 ETH

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

**Escenario**: Keeper externo ejecuta harvest después de 1 mes de acumulación.

**Estado inicial:**
```
TVL = 500 WETH
Aave: 250 WETH + rewards AAVE acumulados
Compound: 250 WETH + rewards COMP acumulados
idle_buffer = 2 ETH
```

**1. StrategyManager.harvest() (fail-safe)**
```
AaveStrategy.harvest():
  - Claimea: 50 AAVE tokens
  - Swap: 50 AAVE → 2.5 WETH (Uniswap V3, 0.3% fee)
  - Min amount out: 50 * 9900 / 10000 = 49.5 AAVE equiv (1% slippage)
  - Re-supply: 2.5 WETH → Aave Pool
  - profit_aave = 2.5 WETH

CompoundStrategy.harvest():
  - Claimea: 100 COMP tokens
  - Swap: 100 COMP → 3.0 WETH (Uniswap V3, 0.3% fee)
  - Re-supply: 3.0 WETH → Compound Comet
  - profit_compound = 3.0 WETH

total_profit = 2.5 + 3.0 = 5.5 WETH
```

**2. Verificación de threshold**
```
5.5 WETH >= 0.1 ETH (min_profit_for_harvest)
✅ Continúa con distribución
```

**3. Pago a keeper externo**
```
keeper_reward = 5.5 * 100 / 10000 = 0.055 WETH
→ Paga desde idle_buffer (2 ETH disponible, solo necesita 0.055)
→ idle_buffer = 2 - 0.055 = 1.945 ETH
→ Transfiere 0.055 WETH al keeper
```

**4. Performance fee**
```
net_profit = 5.5 - 0.055 = 5.445 WETH
perf_fee = 5.445 * 2000 / 10000 = 1.089 WETH
```

**5. Distribución de performance fee**
```
treasury_amount = 1.089 * 8000 / 10000 = 0.8712 WETH
→ Mintea shares equivalentes a 0.8712 WETH al treasury_address
→ Shares auto-compound (suben de valor con cada harvest futuro)

founder_amount = 1.089 * 2000 / 10000 = 0.2178 WETH
→ Retira de idle_buffer: 1.945 - 0.2178 = 1.7272 ETH restante
→ Transfiere 0.2178 WETH al founder_address
```

**6. Estado final**
```
TVL = 500 + 5.5 (rewards reinvertidos) = 505.5 WETH
idle_buffer = 1.7272 ETH
Aave: 252.5 WETH
Compound: 253.0 WETH

Keeper recibió: 0.055 WETH
Treasury recibió: shares por 0.8712 WETH
Founder recibió: 0.2178 WETH
Usuarios se benefician: yield compuesto en estrategias
```

**Si el caller fuera keeper oficial:**
```
keeper_reward = 0 (oficial, no cobra)
net_profit = 5.5 WETH (sin descuento)
perf_fee = 5.5 * 2000 / 10000 = 1.1 WETH
treasury_amount = 0.88 WETH (más para el protocolo)
founder_amount = 0.22 WETH (más para el founder)
```

---

## 4. Flujo de Rebalance

### Descripción General

Cuando los APYs cambian, la distribución óptima cambia. Un keeper (bot o usuario) puede ejecutar rebalance() para mover fondos entre estrategias. El rebalance solo se ejecuta si la diferencia de APY entre la mejor y peor estrategia supera el threshold del 2%.

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
     │                     │    - >= 2 strategies   │                      │
     │                     │    - TVL >= 10 ETH    │                      │
     │                     │    - max_apy - min_apy│                      │
     │                     │      >= 200 bp (2%)   │                      │
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
     │                     │                       │ 12. supply(weth)     │
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

// Requiere TVL mínimo
if (totalAssets() < min_tvl_for_rebalance) return false;  // 10 ETH

// Calcula diferencia de APY
uint256 max_apy = 0;
uint256 min_apy = type(uint256).max;

for (uint256 i = 0; i < strategies.length; i++) {
    uint256 apy = strategies[i].apy();
    if (apy > max_apy) max_apy = apy;
    if (apy < min_apy) min_apy = apy;
}

// Rebalance si diferencia >= 2% (200 bp)
return (max_apy - min_apy) >= rebalance_threshold;
```

### Ejemplo Numérico Completo

**Escenario**: APY de Compound sube de 5% a 8%, rebalance se vuelve rentable.

**Estado inicial (targets 50/50):**
```
Aave: 50 WETH (5% APY = 500 bp)
Compound: 50 WETH (5% APY = 500 bp)
total_tvl = 100 WETH
```

**Cambio de mercado:**
```
Aave: 5% APY (sin cambios, 500 bp)
Compound: 8% APY (subió 3%, 800 bp)
```

**1. Keeper llama shouldRebalance()**
```
max_apy = 800 bp (Compound)
min_apy = 500 bp (Aave)
diferencia = 800 - 500 = 300 bp

300 >= 200 (rebalance_threshold)
✅ shouldRebalance = true
```

**2. Keeper ejecuta rebalance()**
```
Recalcula targets:
- total_apy = 500 + 800 = 1300 bp
- Aave: (500 * 10000) / 1300 = 3846 bp = 38.46%
- Compound: (800 * 10000) / 1300 = 6154 bp = 61.54%

Target balances:
- Aave: 100 * 38.46% = 38.46 WETH
- Compound: 100 * 61.54% = 61.54 WETH

Deltas:
- Aave: 50 - 38.46 = +11.54 WETH (exceso)
- Compound: 50 - 61.54 = -11.54 WETH (necesita)
```

**3. Ejecución del rebalance**
```
Movimiento:
1. Retira 11.54 WETH de Aave (aave_pool.withdraw)
2. Transfiere 11.54 WETH a CompoundStrategy
3. Deposita 11.54 WETH en Compound (compound_comet.supply)

Estado final:
- Aave: 38.46 WETH (38.46%)
- Compound: 61.54 WETH (61.54%)
- Los fondos ahora generan más yield al estar mejor distribuidos
```

**Escenario donde no se rebalancea:**
```
Aave: 4% APY (400 bp)
Compound: 5% APY (500 bp)
diferencia = 500 - 400 = 100 bp

100 < 200 (rebalance_threshold)
❌ shouldRebalance = false → No vale la pena mover fondos
```

---

## 5. Flujo de Idle Buffer Allocation

### Descripción General

El idle buffer acumula depósitos pequeños para ahorrar gas. Múltiples usuarios comparten el coste de un solo allocate.

### Ejemplo de 3 Usuarios

**Configuración:**
- `idle_threshold = 10 ETH`
- `idle_buffer = 0` inicial

**Usuario 1: Alice deposita 5 ETH**
```
Estado antes:
  idle_buffer = 0

Alice.deposit(5 ETH)
  → idle_buffer = 5 ETH
  → shares_alice = 5
  → totalAssets = 5 ETH (todo en idle)

Check: idle_buffer (5) < threshold (10)
❌ NO auto-allocate

Estado después:
  idle_buffer = 5 ETH (acumulando)
  totalAssets = 5 ETH
```

**Usuario 2: Bob deposita 5 ETH**
```
Estado antes:
  idle_buffer = 5 ETH

Bob.deposit(5 ETH)
  → idle_buffer = 10 ETH
  → shares_bob = (5 * 5) / 5 = 5
  → totalAssets = 10 ETH

Check: idle_buffer (10) >= threshold (10)
✅ AUTO-ALLOCATE!

_allocateIdle():
  1. to_allocate = 10 ETH
  2. idle_buffer = 0
  3. Transfer 10 ETH al manager
  4. manager.allocate(10 ETH)
     → Aave recibe 5 ETH
     → Compound recibe 5 ETH

Estado después:
  idle_buffer = 0
  Aave: 5 ETH
  Compound: 5 ETH
  totalAssets = 0 + 5 + 5 = 10 ETH
```

**Usuario 3: Charlie deposita 5 ETH**
```
Estado antes:
  idle_buffer = 0
  Aave: 5 ETH
  Compound: 5 ETH

Charlie.deposit(5 ETH)
  → idle_buffer = 5 ETH
  → shares_charlie = (5 * 10) / 10 = 5
  → totalAssets = 5 + 5 + 5 = 15 ETH

Check: idle_buffer (5) < threshold (10)
❌ NO auto-allocate (ciclo se repite)

Estado después:
  idle_buffer = 5 ETH (acumulando de nuevo)
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
// Keeper ve que idle_buffer = 10 ETH
vault.allocateIdle();

// Vault ejecuta:
if (idle_buffer < idle_threshold) revert Vault__InsufficientIdleBuffer();
_allocateIdle();
```

---

## Resumen de Flujos

| Flujo | Trigger | Auto/Manual | Gas Optimization | Fee |
|-------|---------|-------------|------------------|-----|
| **Deposit** | Usuario deposita | Auto si idle >= 10 ETH | Idle buffer (ahorro 50-66%) | Ninguna |
| **Withdraw** | Usuario retira | Manual (usuario llama) | Retira de idle primero | Ninguna (solo rounding ~wei) |
| **Harvest** | Keeper/Cualquiera | Manual (incentivizado) | Fail-safe, auto-compound | 20% perf fee + 1% keeper |
| **Rebalance** | APY cambia > 2% | Manual (keeper/cualquiera) | Solo si APY diff >= threshold | Ninguna |
| **Idle Allocate** | idle >= threshold | Auto en deposit, o manual | Amortiza gas entre usuarios | Ninguna |

---

**Siguiente lectura**: [SECURITY.md](SECURITY.md) - Consideraciones de seguridad y protecciones implementadas
