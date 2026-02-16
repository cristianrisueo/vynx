# VynX Protocol v2

Protocolo de optimizacion de rendimiento (yield aggregator) construido con Solidity 0.8.33 y Foundry. Implementa un vault ERC4626 que distribuye WETH entre multiples estrategias DeFi (Aave v3 y Compound v3) y cosecha rewards automaticamente via Uniswap V3 para maximizar yield compuesto. Incluye un Router periferico que permite depositar y retirar con cualquier token (ETH, USDC, DAI, WBTC...) swapeando automaticamente via Uniswap V3.

## Descripcion

VynX es un protocolo de gestion automatizada de activos que permite a los usuarios depositar WETH y beneficiarse de una diversificacion inteligente entre diferentes protocolos de lending. El sistema calcula continuamente los mejores ratios de distribucion basandose en los APYs ofrecidos por cada protocolo y ejecuta rebalanceos cuando son rentables (cuando el beneficio supera 2x el coste de gas).

El vault implementa optimizaciones avanzadas como un idle buffer que acumula depositos pequenos para amortizar costes de gas, withdrawal fees para incentivar la tenencia a largo plazo, performance fees con split treasury/founder, cosecha automatica de rewards (AAVE, COMP) con swap a WETH via Uniswap V3, y circuit breakers para proteccion del protocolo.

En v2, el protocolo incorpora un **Router periferico** que actua como punto de entrada multi-token. Los usuarios pueden depositar ETH nativo, USDC, DAI, WBTC o cualquier token con pool de Uniswap V3/WETH, y el Router realiza automaticamente el swap a WETH y deposita en el Vault en una sola transaccion. El vault ERC4626 se mantiene puro (solo WETH) mientras el Router maneja toda la complejidad multi-token.

## Caracteristicas Principales

- **Vault ERC4626**: Estandar de industria con shares tokenizadas (vynxWETH)
- **Weighted Allocation**: Distribucion inteligente basada en APY de cada estrategia
- **Idle Buffer**: Acumula depositos hasta threshold configurable para optimizar gas
- **Rebalancing Inteligente**: Solo ejecuta cuando `profit_semanal > gas_cost x 2`
- **Harvest Automatizado**: Cosecha rewards de Aave/Compound, swap via Uniswap V3, reinversion automatica
- **Performance Fees**: 20% sobre profits, split 80/20 entre treasury y founder
- **Keeper System**: Keepers oficiales (sin incentivo) y externos (con incentivo en WETH)
- **Limites de Allocation**: Maximo 50%, minimo 10% por estrategia
- **Withdrawal Fee**: Configurable sobre retiros
- **Circuit Breakers**: TVL maximo, deposito minimo
- **Pausable**: Emergency stop en caso de vulnerabilidades
- **Integracion con Protocolos Battle-Tested**: Aave v3, Compound v3, Uniswap V3
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

## Uso Rapido

### Deposito directo (WETH)

```solidity
// 1. Aprobar WETH al vault
IERC20(weth).approve(address(vault), amount);

// 2. Depositar WETH y recibir shares
uint256 shares = vault.deposit(amount, msg.sender);

// 3. Retirar WETH (quema shares, paga withdrawal fee)
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
│   │   ├── AaveStrategy.sol       # Integracion Aave v3 + harvest via Uniswap V3
│   │   └── CompoundStrategy.sol   # Integracion Compound v3 + harvest via Uniswap V3
│   └── interfaces/
│       ├── core/
│       │   ├── IVault.sol         # Interfaz del vault
│       │   ├── IStrategyManager.sol # Interfaz del manager
│       │   └── IStrategy.sol      # Interfaz estandar de estrategias
│       ├── periphery/
│       │   └── IRouter.sol        # Interfaz del Router
│       └── compound/
│           ├── ICometMarket.sol   # Interfaz Compound v3 Comet
│           └── ICometRewards.sol  # Interfaz Compound v3 Rewards
├── test/
│   ├── unit/                      # Tests unitarios por contrato
│   ├── integration/               # Tests E2E del protocolo
│   ├── fuzz/                      # Fuzz tests stateless
│   └── invariant/                 # Invariant tests stateful
├── script/
│   ├── Deploy.s.sol               # Script de despliegue en Mainnet
│   └── run_invariants_offline.sh  # Script para ejecutar invariant tests via Anvil
├── lib/                           # Dependencias (OpenZeppelin, Aave, Uniswap, Forge)
├── foundry.toml                   # Configuracion de Foundry
└── README.md                      # Este archivo
```

## Testing

96 tests ejecutados contra fork de Ethereum Mainnet real (sin mocks). Los tests cubren flujos unitarios, integracion end-to-end, fuzz testing stateless e invariant testing stateful.

```bash
# Configurar RPC
export MAINNET_RPC_URL="https://eth-mainnet.g.alchemy.com/v2/<API_KEY>"

# Ejecutar unit + integration + fuzz (92 tests)
forge test --no-match-path "test/invariant/*" -vv

# Ejecutar invariant tests via Anvil (4 invariantes)
# Los invariant tests generan un volumen alto de llamadas RPC.
# El script lanza Anvil como proxy local con rate limiting controlado
./script/run_invariants_offline.sh

# Coverage (excluyendo invariantes)
forge coverage --no-match-path "test/invariant/*"
```

| Capa        | Tests                  | Ficheros                                                                                                                                                 |
| ----------- | ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Unit        | 76                     | `test/unit/Vault.t.sol`, `test/unit/StrategyManager.t.sol`, `test/unit/AaveStrategy.t.sol`, `test/unit/CompoundStrategy.t.sol`, `test/unit/Router.t.sol` |
| Integration | 10                     | `test/integration/FullFlow.t.sol`                                                                                                                        |
| Fuzz        | 6 (256 runs c/u)       | `test/fuzz/Fuzz.t.sol`                                                                                                                                   |
| Invariant   | 4 (32 runs x 15 depth) | `test/invariant/Invariants.t.sol`                                                                                                                        |

### Resultados de Invariant Tests

Los invariant tests ejecutan 32 runs con depth 15 (480 llamadas totales) para verificar propiedades criticas del protocolo bajo operaciones aleatorias. Todos los invariantes **PASARON** correctamente:

#### `invariant_AccountingIsConsistent()` - Contabilidad Consistente

Verifica que la suma de assets en estrategias + idle buffer == total reported.

#### `invariant_SupplyIsCoherent()` - Supply Coherente

Verifica que totalSupply de shares == suma de balances de usuarios.

#### `invariant_VaultIsSolvent()` - Solvencia del Vault

Verifica que el vault siempre puede cubrir todos los retiros (solvencia total).

#### `invariant_RouterAlwaysStateless()` - Router Stateless

Verifica que el Router nunca retiene WETH ni ETH entre transacciones.

**Resultado**: `4 tests passed, 0 failed, 0 skipped`

### Coverage

| Contrato             | Lines      | Statements | Branches   | Functions  |
| -------------------- | ---------- | ---------- | ---------- | ---------- |
| Vault.sol            | 95.32%     | 92.98%     | 76.67%     | 100.00%    |
| StrategyManager.sol  | 75.57%     | 69.53%     | 56.41%     | 100.00%    |
| AaveStrategy.sol     | 70.49%     | 70.18%     | 50.00%     | 91.67%     |
| CompoundStrategy.sol | 80.70%     | 86.00%     | 70.00%     | 91.67%     |
| Router.sol           | 94.29%     | 94.44%     | 78.57%     | 100.00%    |
| **Total**            | **84.52%** | **81.23%** | **66.18%** | **97.83%** |

## Deployment

El protocolo se despliega en Ethereum Mainnet. El script detecta automaticamente las direcciones de WETH, Aave v3 Pool, Compound v3 Comet, Uniswap V3 Router y despliega el Router periferico.

```bash
# Configurar private key del deployer
export PRIVATE_KEY="0x..."
export MAINNET_RPC_URL="https://eth-mainnet.g.alchemy.com/v2/<API_KEY>"

# Dry-run (simula sin ejecutar)
forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL -vvv

# Deploy real
forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL --broadcast --verify
```

El deployer queda como owner y fee_receiver. El Router se despliega como contrato 5 en la secuencia. Coste estimado: ~0.015 ETH.

## Documentacion

- **[ARCHITECTURE.md](docs/ARCHITECTURE.md)** - Diseno del sistema, diagramas y flujos de datos
- **[CONTRACTS.md](docs/CONTRACTS.md)** - Especificaciones de contratos, funciones y parametros
- **[FLOWS.md](docs/FLOWS.md)** - Flujos operativos detallados (deposit, withdraw, harvest, rebalance, router)
- **[SECURITY.md](docs/SECURITY.md)** - Consideraciones de seguridad, supuestos de confianza y limitaciones
- **[TESTS.md](docs/TESTS.md)** - Suite de tests, coverage y convenciones

## Parametros del Protocolo

| Parametro                     | Valor Inicial | Descripcion                                   |
| ----------------------------- | ------------- | --------------------------------------------- |
| `idle_threshold`              | 10 ETH        | Acumulacion minima para auto-allocate         |
| `max_tvl`                     | 1000 ETH      | TVL maximo permitido (circuit breaker)        |
| `min_deposit`                 | 0.01 ETH      | Deposito minimo (anti-spam)                   |
| `withdrawal_fee`              | 2% (200 bp)   | Fee sobre retiros                             |
| `performance_fee`             | 20% (2000 bp) | Fee sobre profits (80% treasury, 20% founder) |
| `max_allocation_per_strategy` | 50% (5000 bp) | Allocation maximo por estrategia              |
| `min_allocation_threshold`    | 10% (1000 bp) | Allocation minimo por estrategia              |
| `gas_cost_multiplier`         | 2x (200)      | Margen de seguridad para rebalanceo           |

## Consideraciones Educacionales

Este proyecto es **educacional** y esta construido con:

- Codigo production-grade (CEI pattern, SafeERC20, etc.)
- Comentarios en espanol (intencional)
- Variables en snake_case (estilo educativo)
- Arquitectura modular y extensible
- **NO auditado** - No usar en mainnet con fondos reales

## Arquitectura de Confianza

El protocolo confia en:

- **Aave v3**: Protocolo auditado y battle-tested
- **Compound v3**: Protocolo auditado y battle-tested
- **Uniswap V3**: DEX para swap de rewards a WETH y swaps multi-token del Router
- **OpenZeppelin**: Contratos estandar de industria (ERC4626, Ownable, Pausable, ReentrancyGuard)
- **WETH**: Contrato canonico de Ethereum para wrap/unwrap ETH

## Licencia

MIT License - Ver [LICENSE](LICENSE) para mas detalles

---

**Autor**: @cristianrisueo
**Version**: 2.0.0
**Target Network**: Ethereum Mainnet
**Solidity**: 0.8.33
**Framework**: Foundry
