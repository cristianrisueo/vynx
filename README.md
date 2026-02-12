# Multi-Strategy Vault v1

Vault de agregación de rendimiento (yield aggregator) educacional construido con Solidity 0.8.33 y Foundry. Este proyecto implementa un vault ERC4626 que distribuye WETH entre múltiples estrategias DeFi (Aave v3 y Compound v3) para optimizar el rendimiento mediante weighted allocation basado en APY.

## Descripción

Multi-Strategy Vault es un protocolo de gestión automatizada de activos que permite a los usuarios depositar WETH y beneficiarse de una diversificación inteligente entre diferentes protocolos de lending. El sistema calcula continuamente los mejores ratios de distribución basándose en los APYs ofrecidos por cada protocolo y ejecuta rebalanceos cuando son rentables (cuando el beneficio supera 2x el coste de gas).

El vault implementa optimizaciones avanzadas como un idle buffer que acumula depósitos pequeños para amortizar costes de gas, withdrawal fees del 2% para incentivar la tenencia a largo plazo, y circuit breakers para protección del protocolo.

## Características Principales

- **Vault ERC4626**: Estándar de industria con shares tokenizadas (msvWETH)
- **Weighted Allocation**: Distribución inteligente basada en APY de cada estrategia
- **Idle Buffer**: Acumula depósitos hasta 10 ETH para optimizar gas
- **Rebalancing Inteligente**: Solo ejecuta cuando `profit_semanal > gas_cost × 2`
- **Límites de Allocation**: Máximo 50%, mínimo 10% por estrategia
- **Withdrawal Fee**: 2% sobre retiros (configurable)
- **Circuit Breakers**: TVL máximo (1000 ETH), depósito mínimo (0.01 ETH)
- **Pausable**: Emergency stop en caso de vulnerabilidades
- **Integración con Protocolos Battle-Tested**: Aave v3 y Compound v3

## Prerrequisitos

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (forge, cast, anvil)
- Solidity 0.8.33
- Git

## Instalación

```bash
# Clonar el repositorio
git clone <repo-url>
cd multi-strategy-vault

# Instalar dependencias
forge install

# Compilar contratos
forge build
```

## Uso Rápido

```solidity
// 1. Aprobar WETH al vault
IERC20(weth).approve(address(vault), amount);

// 2. Depositar WETH y recibir shares
uint256 shares = vault.deposit(amount, msg.sender);

// 3. Retirar WETH (quema shares, paga 2% fee)
uint256 assets = vault.withdraw(amount, msg.sender, msg.sender);
```

## Estructura del Proyecto

```
multi-strategy-vault/
├── src/
│   ├── core/
│   │   ├── StrategyVault.sol       # Vault ERC4626 con idle buffer
│   │   └── StrategyManager.sol     # Motor de allocation y rebalancing
│   ├── strategies/
│   │   ├── AaveStrategy.sol        # Integración Aave v3
│   │   └── CompoundStrategy.sol    # Integración Compound v3
│   └── interfaces/
│       ├── IStrategy.sol           # Interfaz estándar de estrategias
│       └── IComet.sol              # Interfaz custom Compound v3
├── test/
│   ├── unit/                       # Tests unitarios por contrato (61 tests)
│   ├── integration/                # Tests E2E del protocolo (6 tests)
│   ├── fuzz/                       # Fuzz tests stateless (5 tests)
│   └── invariant/                  # Invariant tests stateful (3 invariantes)
├── script/
│   ├── Deploy.s.sol                # Script de despliegue en Mainnet
│   └── run_invariants_offline.sh   # Script para ejecutar invariant tests vía Anvil
├── docs/                           # Documentación técnica detallada
├── lib/                            # Dependencias (OpenZeppelin, Aave)
├── foundry.toml                    # Configuración de Foundry
└── README.md                       # Este archivo
```

## Documentación Técnica

La documentación técnica completa está organizada en los siguientes archivos:

- **[ARCHITECTURE.md](docs/ARCHITECTURE.md)**: Arquitectura de alto nivel, jerarquía de contratos, flujo de ownership y decisiones de diseño
- **[CONTRACTS.md](docs/CONTRACTS.md)**: Documentación detallada de cada contrato, variables de estado, funciones y eventos
- **[FLOWS.md](docs/FLOWS.md)**: Flujos de usuario paso a paso (deposit, withdraw, rebalance, idle allocation)
- **[SECURITY.md](docs/SECURITY.md)**: Consideraciones de seguridad, vectores de ataque, protecciones implementadas y limitaciones conocidas
- **[TESTS.md](docs/TESTS.md)**: Suite de tests completa, coverage por contrato, estructura de ficheros y particularidades de ejecución

## Testing

75 tests ejecutados contra fork de Ethereum Mainnet real (sin mocks). Ver **[TESTS.md](docs/TESTS.md)** para documentación detallada.

```bash
# Configurar RPC
export MAINNET_RPC_URL="https://eth-mainnet.g.alchemy.com/v2/<API_KEY>"

# Ejecutar unit + integration + fuzz (72 tests)
forge test -vv

# Ejecutar invariant tests vía Anvil (3 invariantes)
./script/run_invariants_offline.sh

# Coverage
forge coverage
```

| Capa | Tests | Ficheros |
|------|-------|----------|
| Unit | 61 | `test/unit/*.t.sol` |
| Integration | 6 | `test/integration/FullFlow.t.sol` |
| Fuzz | 5 | `test/fuzz/Fuzz.t.sol` |
| Invariant | 3 | `test/invariant/Invariants.t.sol` |

## Deployment

El protocolo se despliega en Ethereum Mainnet. El script detecta automáticamente las direcciones de WETH, Aave v3 Pool y Compound v3 Comet.

```bash
# Configurar private key del deployer
export PRIVATE_KEY="0x..."
export MAINNET_RPC_URL="https://eth-mainnet.g.alchemy.com/v2/<API_KEY>"

# Dry-run (simula sin ejecutar)
forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL -vvv

# Deploy real
forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL --broadcast --verify
```

El deployer queda como owner y fee_receiver. Coste estimado: ~0.008 ETH.

## Parámetros del Protocolo

| Parámetro | Valor Inicial | Descripción |
|-----------|--------------|-------------|
| `idle_threshold` | 10 ETH | Acumulación mínima para auto-allocate |
| `max_tvl` | 1000 ETH | TVL máximo permitido (circuit breaker) |
| `min_deposit` | 0.01 ETH | Depósito mínimo (anti-spam) |
| `withdrawal_fee` | 2% (200 bp) | Fee sobre retiros |
| `max_allocation_per_strategy` | 50% (5000 bp) | Allocation máximo por estrategia |
| `min_allocation_threshold` | 10% (1000 bp) | Allocation mínimo por estrategia |
| `gas_cost_multiplier` | 2x (200) | Margen de seguridad para rebalanceo |

## Consideraciones Educacionales

Este proyecto es **educacional** y está construido con:

- ✅ Código production-grade (CEI pattern, SafeERC20, etc.)
- ✅ Comentarios en español (intencional)
- ✅ Variables en snake_case (estilo educativo)
- ✅ Arquitectura modular y extensible
- ❌ **NO auditado** - No usar en mainnet con fondos reales

## Arquitectura de Confianza

El protocolo confía en:
- **Aave v3**: Protocolos auditados y battle-tested
- **Compound v3**: Protocolos auditados y battle-tested
- **OpenZeppelin**: Contratos estándar de industria (ERC4626, Ownable, Pausable)

## Licencia

MIT License - Ver [LICENSE](LICENSE) para más detalles

---

**Autor**: @cristianrisueo
**Versión**: 1.0.0
**Target Network**: Ethereum Mainnet
**Solidity**: 0.8.33
**Framework**: Foundry
