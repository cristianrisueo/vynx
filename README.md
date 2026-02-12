# VynX Protocol v1

Protocolo de optimizacion de rendimiento (yield aggregator) construido con Solidity 0.8.33 y Foundry. Implementa un vault ERC4626 que distribuye WETH entre multiples estrategias DeFi (Aave v3 y Compound v3) y cosecha rewards automaticamente via Uniswap V3 para maximizar yield compuesto.

## Descripcion

VynX es un protocolo de gestion automatizada de activos que permite a los usuarios depositar WETH y beneficiarse de una diversificacion inteligente entre diferentes protocolos de lending. El sistema calcula continuamente los mejores ratios de distribucion basandose en los APYs ofrecidos por cada protocolo y ejecuta rebalanceos cuando son rentables (cuando el beneficio supera 2x el coste de gas).

El vault implementa optimizaciones avanzadas como un idle buffer que acumula depositos pequenos para amortizar costes de gas, withdrawal fees para incentivar la tenencia a largo plazo, performance fees con split treasury/founder, cosecha automatica de rewards (AAVE, COMP) con swap a WETH via Uniswap V3, y circuit breakers para proteccion del protocolo.

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

```solidity
// 1. Aprobar WETH al vault
IERC20(weth).approve(address(vault), amount);

// 2. Depositar WETH y recibir shares
uint256 shares = vault.deposit(amount, msg.sender);

// 3. Retirar WETH (quema shares, paga withdrawal fee)
uint256 assets = vault.withdraw(amount, msg.sender, msg.sender);
```

## Estructura del Proyecto

```
vynx/
├── src/
│   ├── core/
│   │   ├── Vault.sol              # Vault ERC4626 con idle buffer y fees
│   │   └── StrategyManager.sol    # Motor de allocation y rebalancing
│   ├── strategies/
│   │   ├── AaveStrategy.sol       # Integracion Aave v3 + harvest via Uniswap V3
│   │   └── CompoundStrategy.sol   # Integracion Compound v3 + harvest via Uniswap V3
│   └── interfaces/
│       ├── core/
│       │   ├── IVault.sol         # Interfaz del vault
│       │   ├── IStrategyManager.sol # Interfaz del manager
│       │   └── IStrategy.sol      # Interfaz estandar de estrategias
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

93 tests ejecutados contra fork de Ethereum Mainnet real (sin mocks). Los tests cubren flujos unitarios, integracion end-to-end, fuzz testing stateless e invariant testing stateful.

```bash
# Configurar RPC
export MAINNET_RPC_URL="https://eth-mainnet.g.alchemy.com/v2/<API_KEY>"

# Ejecutar unit + integration + fuzz (93 tests)
forge test --no-match-path "test/invariant/*" -vv

# Ejecutar invariant tests via Anvil (3 invariantes)
# Los invariant tests generan un volumen alto de llamadas RPC.
# El script lanza Anvil como proxy local con rate limiting controlado
./script/run_invariants_offline.sh

# Coverage (excluyendo invariantes)
forge coverage --no-match-path "test/invariant/*"
```

| Capa | Tests | Ficheros |
|------|-------|----------|
| Unit | 73 | `test/unit/Vault.t.sol`, `test/unit/StrategyManager.t.sol`, `test/unit/AaveStrategy.t.sol`, `test/unit/CompoundStrategy.t.sol` |
| Integration | 6 | `test/integration/FullFlow.t.sol` |
| Fuzz | 4 (256 runs c/u) | `test/fuzz/Fuzz.t.sol` |
| Invariant | 3 (32 runs x 15 depth) | `test/invariant/Invariants.t.sol` |

### Resultados de Invariant Tests

Los invariant tests ejecutan 32 runs con depth 15 (480 llamadas totales) para verificar propiedades criticas del protocolo bajo operaciones aleatorias. Todos los invariantes **PASARON** correctamente:

#### `invariant_AccountingIsConsistent()` - Contabilidad Consistente
Verifica que la suma de assets en estrategias + idle buffer == total reported.

```
✓ PASADO (runs: 32, calls: 480, reverts: 0)
┌──────────┬──────────┬───────┬─────────┬──────────┐
│ Contract │ Selector │ Calls │ Reverts │ Discards │
├──────────┼──────────┼───────┼─────────┼──────────┤
│ Handler  │ deposit  │ 161   │ 0       │ 0        │
│ Handler  │ harvest  │ 157   │ 0       │ 0        │
│ Handler  │ withdraw │ 162   │ 0       │ 0        │
└──────────┴──────────┴───────┴─────────┴──────────┘
```

#### `invariant_SupplyIsCoherent()` - Supply Coherente
Verifica que totalSupply de shares == suma de balances de usuarios.

```
✓ PASADO (runs: 32, calls: 480, reverts: 0)
┌──────────┬──────────┬───────┬─────────┬──────────┐
│ Contract │ Selector │ Calls │ Reverts │ Discards │
├──────────┼──────────┼───────┼─────────┼──────────┤
│ Handler  │ deposit  │ 155   │ 0       │ 0        │
│ Handler  │ harvest  │ 141   │ 0       │ 0        │
│ Handler  │ withdraw │ 184   │ 0       │ 0        │
└──────────┴──────────┴───────┴─────────┴──────────┘
```

#### `invariant_VaultIsSolvent()` - Solvencia del Vault
Verifica que el vault siempre puede cubrir todos los retiros (solvencia total).

```
✓ PASADO (runs: 32, calls: 480, reverts: 0)
┌──────────┬──────────┬───────┬─────────┬──────────┐
│ Contract │ Selector │ Calls │ Reverts │ Discards │
├──────────┼──────────┼───────┼─────────┼──────────┤
│ Handler  │ deposit  │ 144   │ 0       │ 0        │
│ Handler  │ harvest  │ 177   │ 0       │ 0        │
│ Handler  │ withdraw │ 159   │ 0       │ 0        │
└──────────┴──────────┴───────┴─────────┴──────────┘
```

**Resultado**: `3 tests passed, 0 failed, 0 skipped` en 86.03s (246.29s CPU time)

### Coverage

| Contrato | Lines | Statements | Branches | Functions |
|----------|-------|------------|----------|-----------|
| Vault.sol | 95.32% | 92.98% | 76.67% | 100.00% |
| StrategyManager.sol | 75.57% | 69.53% | 56.41% | 100.00% |
| AaveStrategy.sol | 70.49% | 70.18% | 50.00% | 91.67% |
| CompoundStrategy.sol | 80.70% | 86.00% | 70.00% | 91.67% |
| **Total** | **82.80%** | **79.06%** | **64.04%** | **97.59%** |

## Deployment

El protocolo se despliega en Ethereum Mainnet. El script detecta automaticamente las direcciones de WETH, Aave v3 Pool, Compound v3 Comet y Uniswap V3 Router.

```bash
# Configurar private key del deployer
export PRIVATE_KEY="0x..."
export MAINNET_RPC_URL="https://eth-mainnet.g.alchemy.com/v2/<API_KEY>"

# Dry-run (simula sin ejecutar)
forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL -vvv

# Deploy real
forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL --broadcast --verify
```

El deployer queda como owner y fee_receiver. Coste estimado: ~0.012 ETH.

## Parametros del Protocolo

| Parametro | Valor Inicial | Descripcion |
|-----------|--------------|-------------|
| `idle_threshold` | 10 ETH | Acumulacion minima para auto-allocate |
| `max_tvl` | 1000 ETH | TVL maximo permitido (circuit breaker) |
| `min_deposit` | 0.01 ETH | Deposito minimo (anti-spam) |
| `withdrawal_fee` | 2% (200 bp) | Fee sobre retiros |
| `performance_fee` | 20% (2000 bp) | Fee sobre profits (80% treasury, 20% founder) |
| `max_allocation_per_strategy` | 50% (5000 bp) | Allocation maximo por estrategia |
| `min_allocation_threshold` | 10% (1000 bp) | Allocation minimo por estrategia |
| `gas_cost_multiplier` | 2x (200) | Margen de seguridad para rebalanceo |

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
- **Uniswap V3**: DEX para swap de rewards a WETH
- **OpenZeppelin**: Contratos estandar de industria (ERC4626, Ownable, Pausable)

## Licencia

MIT License - Ver [LICENSE](LICENSE) para mas detalles

---

**Autor**: @cristianrisueo
**Version**: 1.0.0
**Target Network**: Ethereum Mainnet
**Solidity**: 0.8.33
**Framework**: Foundry
