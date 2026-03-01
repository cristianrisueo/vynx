# VynX Protocol v2

Protocolo de optimizacion de rendimiento (yield aggregator) construido con Solidity 0.8.33 y Foundry. Implementa un vault ERC4626 que distribuye WETH entre multiples estrategias DeFi (Lido, Aave wstETH, Curve y Uniswap V3) en dos tiers de riesgo independientes: **Balanced** y **Aggressive**. Incluye un Router periferico que permite depositar y retirar con cualquier token (ETH, USDC, DAI, WBTC...) swapeando automaticamente via Uniswap V3.

## Descripcion

VynX es un protocolo de gestion automatizada de activos que permite a los usuarios depositar WETH y beneficiarse de una diversificacion inteligente entre diferentes protocolos DeFi. El sistema calcula continuamente los mejores ratios de distribucion basandose en los APYs ofrecidos por cada estrategia y ejecuta rebalanceos cuando son rentables.

El protocolo se despliega en dos configuraciones independientes con diferente perfil de riesgo/rendimiento. Cada configuracion es un vault ERC4626 independiente con su propio StrategyManager y su propio conjunto de estrategias.

El vault implementa optimizaciones avanzadas como un idle buffer que acumula depositos para amortizar costes de gas, performance fees con split treasury/founder, cosecha automatica de rewards con swap a WETH via Uniswap V3, y circuit breakers para proteccion del protocolo.

En v2, el protocolo incorpora un **Router periferico** que actua como punto de entrada multi-token. Los usuarios pueden depositar ETH nativo, USDC, DAI, WBTC o cualquier token con pool de Uniswap V3/WETH, y el Router realiza automaticamente el swap a WETH y deposita en el Vault en una sola transaccion. El vault ERC4626 se mantiene puro (solo WETH) mientras el Router maneja toda la complejidad multi-token.

## Caracteristicas Principales

- **Vault ERC4626**: Estandar de industria con shares tokenizadas (vxWETH)
- **Dos Tiers de Riesgo**: Balanced (Lido + Aave wstETH + Curve) y Aggressive (Curve + Uniswap V3)
- **Weighted Allocation**: Distribucion inteligente basada en APY de cada estrategia
- **Idle Buffer**: Acumula depositos hasta threshold configurable para optimizar gas
- **Rebalancing Inteligente**: Solo ejecuta cuando la diferencia de APY supera el threshold configurado por tier
- **Harvest Automatizado**: Cosecha rewards de cada estrategia, swap via Uniswap V3, reinversion automatica
- **Performance Fees**: 20% sobre profits, split 80/20 entre treasury y founder
- **Keeper System**: Keepers oficiales (sin incentivo) y externos (con incentivo en WETH)
- **Limites de Allocation**: Configurables por tier (max 50-70%, min 10-20% por estrategia)
- **Circuit Breakers**: TVL maximo, deposito minimo
- **Pausable**: Emergency stop (bloquea inflows, retiros siempre habilitados)
- **Emergency Exit**: Drenaje completo de estrategias con fail-safe y reconciliacion de accounting
- **Integracion con Protocolos Battle-Tested**: Lido, Aave v3, Curve, Uniswap V3
- **Router Multi-Token**: Depositos y retiros con ETH, USDC, DAI, WBTC o cualquier token con pool Uniswap V3/WETH
- **Zap Deposit/Withdraw**: Swap + deposit o redeem + swap en una sola transaccion via Router
- **Router Stateless**: El Router nunca retiene fondos entre transacciones (balance check interno)
- **Slippage Protection**: Parametro `min_weth_out` / `min_token_out` en todas las funciones del Router

## Prerrequisitos

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (forge, cast, anvil)
- Solidity 0.8.33
- Git

## Instalacion

```bash
# Clonar el repositorio
git clone https://github.com/cristianrisueo/vynx.git
cd vynx

# Instalar dependencias
forge install

# Compilar contratos
forge build
```

## Deployment

VynX V2 está deployado y verificado en **Ethereum Mainnet**.

### Balanced Tier

| Contrato | Address |
|---|---|
| StrategyManager | [`0xA0d462b84C2431463bDACDC2C5bc3172FC927B0B`](https://etherscan.io/address/0xa0d462b84c2431463bdacdc2c5bc3172fc927b0b) |
| Vault (vxWETH) | [`0x9D002dF2A5B632C0D8022a4738C1fa7465d88444`](https://etherscan.io/address/0x9d002df2a5b632c0d8022a4738c1fa7465d88444) |
| LidoStrategy | [`0xf8d1E54A07A47BB03833493EAEB7FE7432B53FCB`](https://etherscan.io/address/0xf8d1e54a07a47bb03833493eaeb7fe7432b53fcb) |
| AaveStrategy | [`0x8135Ed49ffFeEF4a1Bb5909c5bA96EEe9D4ed32A`](https://etherscan.io/address/0x8135ed49fffeef4a1bb5909c5ba96eee9d4ed32a) |
| CurveStrategy | [`0xF0C57C9c1974a14602074D85cfB1Bc251B67Dc00`](https://etherscan.io/address/0xf0c57c9c1974a14602074d85cfb1bc251b67dc00) |
| Router | [`0x3286c0cB7Bbc7DD4cC7C8752E3D65e275E1B1044`](https://etherscan.io/address/0x3286c0cb7bbc7dd4cc7c8752e3d65e275e1b1044) |

### Aggressive Tier

| Contrato | Address |
|---|---|
| StrategyManager | [`0xcCa54463BD2aEDF1773E9c3f45c6a954Aa9D9706`](https://etherscan.io/address/0xcca54463bd2aedf1773e9c3f45c6a954aa9d9706) |
| Vault (vxWETH) | [`0xA8cA9d84e35ac8F5af6F1D91fe4bE1C0BAf44296`](https://etherscan.io/address/0xa8ca9d84e35ac8f5af6f1d91fe4be1c0baf44296) |
| CurveStrategy | [`0x312510B911fA47D55c9f1a055B1987D51853A7DE`](https://etherscan.io/address/0x312510b911fa47d55c9f1a055b1987d51853a7de) |
| UniswapV3Strategy | [`0x653D9C2dF3A32B872aEa4E3b4e7436577C5eEB62`](https://etherscan.io/address/0x653d9c2df3a32b872aea4e3b4e7436577c5eeb62) |
| Router | [`0xE898661760299f88e2B271a088987dacB8Fb3dE6`](https://etherscan.io/address/0xe898661760299f88e2b271a088987dacb8fb3de6) |

## Uso Rapido

### Deposito directo (WETH)

```solidity
// 1. Aprobar WETH al vault
IERC20(weth).approve(address(vault), amount);

// 2. Depositar WETH y recibir shares
uint256 shares = vault.deposit(amount, msg.sender);

// 3. Retirar WETH (quema shares)
uint256 assets = vault.withdraw(amount, msg.sender, msg.sender);
```

### Via Router (ETH, USDC, DAI, WBTC...)

```solidity
// Depositar ETH nativo → recibir shares
uint256 shares = router.zapDepositETH{value: msg.value}();

// Depositar USDC → swap a WETH → recibir shares
IERC20(usdc).approve(address(router), amount);
uint256 shares = router.zapDepositERC20(usdc, amount, 500, min_weth_out);

// Retirar shares → recibir ETH nativo
IERC20(vault).approve(address(router), shares);
uint256 eth_out = router.zapWithdrawETH(shares);

// Retirar shares → recibir USDC
IERC20(vault).approve(address(router), shares);
uint256 usdc_out = router.zapWithdrawERC20(shares, usdc, 500, min_usdc_out);
```

## Estructura del Proyecto

```
vynx/
├── src/
│   ├── core/
│   │   ├── Vault.sol              # Vault ERC4626 con idle buffer y fees
│   │   └── StrategyManager.sol    # Motor de allocation y rebalancing
│   ├── periphery/
│   │   └── Router.sol             # Router multi-token (ETH/ERC20 → WETH → Vault)
│   ├── strategies/
│   │   ├── LidoStrategy.sol       # Lido staking: WETH → wstETH (yield auto-compuesto)
│   │   ├── AaveStrategy.sol       # Aave wstETH: WETH → wstETH → Aave (doble yield)
│   │   ├── CurveStrategy.sol      # Curve stETH/ETH LP + gauge CRV rewards
│   │   └── UniswapV3Strategy.sol  # Uniswap V3 WETH/USDC liquidez concentrada ±10%
│   ├── libraries/
│   │   ├── TickMath.sol           # Calculo de sqrtPrice a partir de ticks
│   │   ├── FullMath.sol           # Multiplicaciones con precision de 512 bits
│   │   ├── LiquidityAmounts.sol   # Conversion liquidez ↔ cantidades de tokens
│   │   └── FixedPoint96.sol       # Constante Q96 para precios Uniswap V3
│   └── interfaces/
│       ├── core/
│       │   ├── IVault.sol         # Interfaz del vault
│       │   └── IStrategyManager.sol # Interfaz del manager
│       ├── strategies/
│       │   ├── IStrategy.sol      # Interfaz estandar de estrategias
│       │   ├── lido/
│       │   │   ├── ILido.sol      # Interfaz Lido stETH
│       │   │   └── IWstETH.sol    # Interfaz wstETH (wrap/unwrap)
│       │   ├── curve/
│       │   │   ├── ICurvePool.sol # Interfaz Curve stETH/ETH pool
│       │   │   └── ICurveGauge.sol # Interfaz Curve gauge
│       │   └── uniswap/
│       │       └── INonfungiblePositionManager.sol # Interfaz Uniswap V3 NFT positions
│       └── periphery/
│           └── IRouter.sol        # Interfaz del Router
├── test/
│   ├── unit/                      # Tests unitarios por contrato
│   ├── integration/               # Tests E2E del protocolo
│   ├── fuzz/                      # Fuzz tests stateless
│   └── invariant/                 # Invariant tests stateful
├── script/
│   ├── DeployBalanced.s.sol       # Deploy tier Balanced (Lido + Aave + Curve)
│   ├── DeployAggressive.s.sol     # Deploy tier Aggressive (Curve + Uniswap V3)
│   ├── DeployRouters.s.sol        # Deploy Routers periféricos (uno por vault)
│   └── run_invariants_offline.sh  # Script para ejecutar invariant tests via Anvil
├── lib/                           # Dependencias (OpenZeppelin, Aave, Uniswap, Forge)
├── foundry.toml                   # Configuracion de Foundry
└── README.md                      # Este archivo
```

## Testing

149 tests ejecutados contra fork de Ethereum Mainnet real (sin mocks). Los tests cubren flujos unitarios, integracion end-to-end, fuzz testing stateless e invariant testing stateful.

```bash
# Configurar RPC
export MAINNET_RPC_URL="https://eth-mainnet.g.alchemy.com/v2/<API_KEY>"

# Ejecutar unit + integration + fuzz (149 tests)
forge test --no-match-path "test/invariant/*" -vv

# Ejecutar invariant tests via Anvil (4 invariantes)
# Los invariant tests generan un volumen alto de llamadas RPC.
# El script lanza Anvil como proxy local con rate limiting controlado
./script/run_invariants_offline.sh

# Coverage (excluyendo invariantes)
forge coverage --no-match-path "test/invariant/*" --ir-minimum
```

| Capa        | Tests                  | Ficheros                                                                                                                                                                                                 |
| ----------- | ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Unit        | 145                    | `test/unit/Vault.t.sol`, `test/unit/StrategyManager.t.sol`, `test/unit/LidoStrategy.t.sol`, `test/unit/AaveStrategy.t.sol`, `test/unit/CurveStrategy.t.sol`, `test/unit/UniswapV3Strategy.t.sol`, `test/unit/Router.t.sol` |
| Integration | 10                     | `test/integration/FullFlow.t.sol`                                                                                                                                                                        |
| Fuzz        | 6 (256 runs c/u)       | `test/fuzz/Fuzz.t.sol`                                                                                                                                                                                   |
| Invariant   | 4 (32 runs x 15 depth) | `test/invariant/Invariants.t.sol`                                                                                                                                                                        |

### Resultados de Invariant Tests

Los invariant tests ejecutan 32 runs con depth 15 (480 llamadas totales) para verificar propiedades criticas del protocolo bajo operaciones aleatorias. Todos los invariantes **PASARON** correctamente:

#### `invariant_AccountingIsConsistent()` - Contabilidad Consistente

Verifica que la suma de assets en estrategias + idle buffer == total reported.

#### `invariant_SupplyIsCoherent()` - Supply Coherente

Verifica que totalSupply de shares >= suma de balances de usuarios conocidos.

#### `invariant_VaultIsSolvent()` - Solvencia del Vault

Verifica que el vault siempre puede cubrir todos los retiros (solvencia total, con tolerancia del 1% por fees).

#### `invariant_RouterAlwaysStateless()` - Router Stateless

Verifica que el Router nunca retiene WETH ni ETH entre transacciones.

**Resultado**: `4 tests passed, 0 failed, 0 skipped`

### Coverage

| Contrato              | Lines      | Statements | Branches   | Functions  |
| --------------------- | ---------- | ---------- | ---------- | ---------- |
| Vault.sol             | 92.51%     | 88.02%     | 55.26%     | 100.00%    |
| StrategyManager.sol   | 81.46%     | 81.27%     | 52.08%     | 100.00%    |
| AaveStrategy.sol      | 71.95%     | 69.89%     | 41.67%     | 91.67%     |
| CurveStrategy.sol     | 95.12%     | 97.09%     | 71.43%     | 100.00%    |
| LidoStrategy.sol      | 90.91%     | 91.30%     | 66.67%     | 90.00%     |
| UniswapV3Strategy.sol | 75.21%     | 75.51%     | 50.00%     | 100.00%    |
| Router.sol            | 98.36%     | 80.95%     | 28.57%     | 100.00%    |
| **Total**             | **85.42%** | **82.83%** | **50.00%** | **98.23%** |

## Variables de Entorno

Crea un fichero `.env` en la raiz del proyecto con las siguientes variables:

| Variable            | Descripcion                                                        |
| ------------------- | ------------------------------------------------------------------ |
| `MAINNET_RPC_URL`   | RPC de Ethereum Mainnet (Alchemy, Infura, etc.)                    |
| `PRIVATE_KEY`       | Clave privada del deployer (sin el prefijo `0x`) para `--broadcast`|
| `ETHERSCAN_API_KEY` | API key de Etherscan para verificacion de contratos                |
| `TREASURY_ADDRESS`  | Address que recibe el 80% de las performance fees                  |
| `FOUNDER_ADDRESS`   | Address que recibe el 20% de las performance fees                  |

> **IMPORTANTE**: `TREASURY_ADDRESS` y `FOUNDER_ADDRESS` deben setearse antes de cualquier
> broadcast a mainnet. Los scripts de deploy revertiran con un mensaje claro si alguna de
> las dos variables no esta presente o es `address(0)`.
> `PRIVATE_KEY` solo es necesaria para el paso de broadcast (`--broadcast`); el dry-run
> no la requiere.

## Deployment

El protocolo se despliega en dos configuraciones independientes segun el perfil de riesgo deseado.
Sigue siempre el proceso de dos pasos: primero un dry-run para verificar la simulacion,
luego el broadcast real solo si el dry-run fue exitoso.

### Tier Balanced: Lido + Aave wstETH + Curve

```bash
# Paso 1: dry run — verifica que todo compila y simula correctamente
forge script script/DeployBalanced.s.sol \
  --rpc-url $MAINNET_RPC_URL

# Paso 2: broadcast real solo si el dry run fue exitoso
forge script script/DeployBalanced.s.sol \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

### Tier Aggressive: Curve + Uniswap V3

```bash
# Paso 1: dry run — verifica que todo compila y simula correctamente
forge script script/DeployAggressive.s.sol \
  --rpc-url $MAINNET_RPC_URL

# Paso 2: broadcast real solo si el dry run fue exitoso
forge script script/DeployAggressive.s.sol \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

## Guia de Seleccion de Tier

| Criterio                   | Balanced                          | Aggressive                        |
| -------------------------- | --------------------------------- | --------------------------------- |
| **Estrategias**            | Lido + Aave wstETH + Curve        | Curve + Uniswap V3                |
| **APY estimado**           | 4–7% (conservador)                | 6–14% (variable)                  |
| **Riesgo principal**       | Depeg stETH, smart contract risk  | IL concentrado, out-of-range risk |
| **Perfil de usuario**      | Largo plazo, menor volatilidad    | Mayor tolerancia al riesgo        |

## Parametros del Protocolo

### Tier Balanced

| Parametro                     | Valor     | Descripcion                                        |
| ----------------------------- | --------- | -------------------------------------------------- |
| `idle_threshold`              | 8 ETH     | Acumulacion minima para auto-allocate              |
| `max_tvl`                     | 1000 ETH  | TVL maximo permitido (circuit breaker)             |
| `min_profit_for_harvest`      | 0.08 ETH  | Beneficio minimo para ejecutar harvest             |
| `performance_fee`             | 20%       | Fee sobre profits (80% treasury, 20% founder)      |
| `max_allocation_per_strategy` | 50%       | Allocation maximo por estrategia                   |
| `min_allocation_threshold`    | 20%       | Allocation minimo por estrategia                   |
| `rebalance_threshold`         | 2%        | Diferencia de APY para ejecutar rebalanceo         |
| `min_tvl_for_rebalance`       | 8 ETH     | TVL minimo necesario para rebalancear              |

### Tier Aggressive

| Parametro                     | Valor     | Descripcion                                        |
| ----------------------------- | --------- | -------------------------------------------------- |
| `idle_threshold`              | 12 ETH    | Acumulacion minima para auto-allocate              |
| `max_tvl`                     | 1000 ETH  | TVL maximo permitido (circuit breaker)             |
| `min_profit_for_harvest`      | 0.12 ETH  | Beneficio minimo para ejecutar harvest             |
| `performance_fee`             | 20%       | Fee sobre profits (80% treasury, 20% founder)      |
| `max_allocation_per_strategy` | 70%       | Allocation maximo por estrategia                   |
| `min_allocation_threshold`    | 10%       | Allocation minimo por estrategia                   |
| `rebalance_threshold`         | 3%        | Diferencia de APY para ejecutar rebalanceo         |
| `min_tvl_for_rebalance`       | 12 ETH    | TVL minimo necesario para rebalancear              |

## Documentacion

- **[ARCHITECTURE.md](docs/ARCHITECTURE.md)** - Diseno del sistema, diagramas y flujos de datos
- **[CONTRACTS.md](docs/CONTRACTS.md)** - Especificaciones de contratos, funciones y parametros
- **[FLOWS.md](docs/FLOWS.md)** - Flujos operativos detallados (deposit, withdraw, harvest, rebalance, router)
- **[SECURITY.md](docs/SECURITY.md)** - Consideraciones de seguridad, supuestos de confianza y limitaciones
- **[TESTS.md](docs/TESTS.md)** - Suite de tests, coverage y convenciones

## Security & Emergency Procedures

### Retiros Siempre Habilitados

Los retiros (`withdraw`, `redeem`) **nunca se bloquean**, ni siquiera cuando el vault esta pausado. La pausa solo bloquea nuevos depositos (`deposit`, `mint`), `harvest` y `allocateIdle`. Un usuario siempre puede recuperar sus fondos.

### Emergency Exit

Si se detecta un exploit activo o bug critico, el protocolo permite drenar todas las estrategias y devolver los fondos al vault:

```solidity
// 1. Pausar el vault (bloquea nuevos depositos, retiros siguen habilitados)
vault.pause();

// 2. Drenar todas las estrategias al vault (try-catch por estrategia)
manager.emergencyExit();

// 3. Reconciliar accounting del vault
vault.syncIdleBuffer();
```

Tras esta secuencia, todos los fondos estan en el idle buffer del vault y los usuarios pueden retirar normalmente via `withdraw()` o `redeem()`.

**Fail-safe**: Si una estrategia falla durante el drenaje, las demas continuan. La estrategia problematica se gestiona por separado.

Para documentacion detallada de seguridad, ver [SECURITY.md](docs/SECURITY.md).

## Consideraciones Educacionales

Este proyecto es **educacional** y esta construido con:

- Codigo production-grade (CEI pattern, SafeERC20, etc.)
- Comentarios en espanol (intencional)
- Variables en snake_case (estilo educativo)
- Arquitectura modular y extensible
- **NO auditado** - No usar en mainnet con fondos reales

## Arquitectura de Confianza

El protocolo confia en:

- **Lido**: Protocolo de liquid staking auditado y battle-tested
- **Aave v3**: Protocolo de lending auditado y battle-tested
- **Curve Finance**: DEX especializado en stablecoins/assets correlados; pool stETH/ETH con exploit historico en gauge (Vyper, julio 2023) parcheado
- **Uniswap V3**: DEX para liquidez concentrada y swap de rewards a WETH
- **OpenZeppelin**: Contratos estandar de industria (ERC4626, Ownable, Pausable, ReentrancyGuard)
- **WETH**: Contrato canonico de Ethereum para wrap/unwrap ETH

## Licencia

MIT License - Ver [LICENSE](LICENSE) para mas detalles

## Documentacion Interactiva

```bash
forge doc --serve --port 4000
```

Genera y sirve la documentacion NatSpec del proyecto en `http://localhost:4000`.

---

**Autor**: @cristianrisueo
**Version**: 2.0.0
**Target Network**: Ethereum Mainnet
**Solidity**: 0.8.33
**Framework**: Foundry
