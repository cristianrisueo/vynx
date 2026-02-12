#!/usr/bin/env bash

set -e

#######################################################################################
# Script: run_invariants_offline.sh
# Propósito: Ejecutar tests de invariantes sin rate limits mediante configuración
#            de rate limiting inteligente en Anvil
#
# Estrategia:
#   1. Anvil con --compute-units-per-second limitado (evita 429)
#   2. Warmup del cache con test de integración
#   3. Fuzzing con runs configurables
#   4. Cleanup automático de procesos y archivos temporales
#
# Uso:
#   ./script/run_invariants_offline.sh [options]
#
# Opciones:
#   -r, --runs <N>       Número de runs del fuzzer (default: 32)
#   -b, --block <N>      Bloque de fork (default: 21792000)
#   -h, --help           Muestra ayuda
#
# Ejemplos:
#   ./script/run_invariants_offline.sh                    # 32 runs, bloque default
#   ./script/run_invariants_offline.sh -r 64              # 64 runs
#   ./script/run_invariants_offline.sh -b 21800000        # Bloque custom
#   ./script/run_invariants_offline.sh -r 16 -b 21800000  # Ambos custom
#######################################################################################

# Navega al directorio raíz del proyecto (donde está foundry.toml)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuración default
ALCHEMY_URL="https://eth-mainnet.g.alchemy.com/v2/YfrbfXNhnCGQkJeTMXPPi"
FORK_BLOCK="21792000"
ANVIL_PORT="8545"
ANVIL_RPC="http://127.0.0.1:${ANVIL_PORT}"
ANVIL_PID=""
INVARIANT_RUNS=32
INVARIANT_DEPTH=15
COMPUTE_UNITS_PER_SECOND=10
REQUEST_TIMEOUT=120000
STATE_FILE="./anvil_state_temp.json"

# Parse argumentos
while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--runs)
            INVARIANT_RUNS="$2"
            shift 2
            ;;
        -b|--block)
            FORK_BLOCK="$2"
            shift 2
            ;;
        -h|--help)
            echo "Uso: $0 [options]"
            echo ""
            echo "Opciones:"
            echo "  -r, --runs <N>    Número de runs (default: 32)"
            echo "  -b, --block <N>   Bloque de fork (default: 10164266)"
            echo "  -h, --help        Muestra esta ayuda"
            echo ""
            echo "Ejemplos:"
            echo "  $0 -r 64          # 64 runs"
            echo "  $0 -b 10200000    # Bloque custom"
            exit 0
            ;;
        *)
            echo -e "${RED}Error: Argumento desconocido '$1'${NC}"
            echo "Usa -h o --help para ver opciones"
            exit 1
            ;;
    esac
done

TOTAL_CALLS=$((INVARIANT_RUNS * INVARIANT_DEPTH))

# Funciones de output
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_step() { echo -e "${CYAN}▶${NC} $1"; }

# Cleanup automático
cleanup() {
    print_info "Limpiando..."

    # Mata Anvil
    if [ ! -z "$ANVIL_PID" ] && kill -0 "$ANVIL_PID" 2>/dev/null; then
        kill "$ANVIL_PID" 2>/dev/null || true
        sleep 1
    fi
    pkill -f "anvil.*$ANVIL_PORT" 2>/dev/null || true

    # Libera puerto
    if lsof -Pi :${ANVIL_PORT} -sTCP:LISTEN -t >/dev/null 2>&1; then
        lsof -ti:${ANVIL_PORT} | xargs kill -9 2>/dev/null || true
    fi

    # Elimina archivos temporales
    rm -f "$STATE_FILE" 2>/dev/null || true
    rm -f /tmp/anvil_offline.log /tmp/warmup.log 2>/dev/null || true
}

trap cleanup EXIT INT TERM

# Banner
echo ""
echo -e "${CYAN}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}  ${GREEN}AaveVault Invariant Testing${NC} - Anti-Rate-Limit  ${CYAN}║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════╝${NC}"
echo ""

# Verificar dependencias
if ! command -v anvil &> /dev/null || ! command -v forge &> /dev/null; then
    print_error "Foundry no encontrado. Instala: curl -L https://foundry.paradigm.xyz | bash"
    exit 1
fi
print_success "Foundry disponible"

# Mostrar configuración
echo ""
print_step "Configuración"
echo "  Fork: Mainnet bloque $FORK_BLOCK"
echo "  Fuzzing: $INVARIANT_RUNS runs × $INVARIANT_DEPTH depth = $TOTAL_CALLS calls"
echo "  Rate limit: $COMPUTE_UNITS_PER_SECOND CU/s"
echo ""

# Cleanup previo
cleanup

# FASE 1: Inicio de Anvil
print_step "Iniciando Anvil con rate limiting..."
anvil \
    --fork-url "$ALCHEMY_URL" \
    --fork-block-number "$FORK_BLOCK" \
    --port "$ANVIL_PORT" \
    --compute-units-per-second "$COMPUTE_UNITS_PER_SECOND" \
    --timeout "$REQUEST_TIMEOUT" \
    --silent \
    > /tmp/anvil_offline.log 2>&1 &

ANVIL_PID=$!

# Espera a Anvil
for i in {1..30}; do
    if curl -s -X POST "$ANVIL_RPC" -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        >/dev/null 2>&1; then
        break
    fi
    if [ $i -eq 30 ]; then
        print_error "Timeout esperando Anvil"
        cat /tmp/anvil_offline.log
        exit 1
    fi
    sleep 1
done

print_success "Anvil listo (PID: $ANVIL_PID)"

# FASE 2: Warmup
print_step "Calentando cache..."
forge test \
    --match-path test/integration/FullFlow.t.sol \
    --match-test "test_E2E_DepositAllocateWithdraw" \
    --fork-url "$ANVIL_RPC" \
    --silent \
    > /tmp/warmup.log 2>&1 || true

print_success "Cache listo"

# FASE 3: Tests de invariantes
echo ""
print_step "Ejecutando tests de invariantes ($INVARIANT_RUNS runs)..."
echo ""

export FOUNDRY_INVARIANT_RUNS=$INVARIANT_RUNS
export FOUNDRY_INVARIANT_DEPTH=$INVARIANT_DEPTH

if MAINNET_RPC_URL="$ANVIL_RPC" forge test \
    --match-path test/invariant/Invariants.t.sol \
    --fork-url "$ANVIL_RPC" \
    -vvv; then
    TEST_EXIT_CODE=0
else
    TEST_EXIT_CODE=$?
fi

# FASE 4: Reporte
echo ""
if [ $TEST_EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}              ${GREEN}✓ TESTS PASADOS ✓${NC}                    ${GREEN}║${NC}"
    echo -e "${GREEN}╠════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  • Solvencia: OK                                ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  • Integridad: OK                               ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  • Total: $INVARIANT_RUNS runs × $INVARIANT_DEPTH depth = $TOTAL_CALLS calls        ${GREEN}║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}"
else
    echo -e "${RED}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║${NC}              ${RED}✗ TESTS FALLARON ✗${NC}                    ${RED}║${NC}"
    echo -e "${RED}╠════════════════════════════════════════════════════╣${NC}"
    echo -e "${RED}║${NC}  Revisa los logs arriba para detalles            ${RED}║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════╝${NC}"
fi

echo ""
exit $TEST_EXIT_CODE
