#!/usr/bin/env bash

set -e

#######################################################################################
# Script: run_invariants_offline.sh
# Purpose: Run invariant tests without rate limits through intelligent
#          rate limiting configuration in Anvil
#
# Strategy:
#   1. Anvil with --compute-units-per-second limited (avoids 429)
#   2. Cache warmup with integration test
#   3. Fuzzing with configurable runs
#   4. Automatic cleanup of processes and temporary files
#
# Usage:
#   ./script/run_invariants_offline.sh [options]
#
# Options:
#   -r, --runs <N>       Number of fuzzer runs (default: 32)
#   -b, --block <N>      Fork block (default: 21792000)
#   -h, --help           Show help
#
# Examples:
#   ./script/run_invariants_offline.sh                    # 32 runs, default block
#   ./script/run_invariants_offline.sh -r 64              # 64 runs
#   ./script/run_invariants_offline.sh -b 21800000        # Custom block
#   ./script/run_invariants_offline.sh -r 16 -b 21800000  # Both custom
#######################################################################################

# Navigate to the project root directory (where foundry.toml is)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Default configuration
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

# Parse arguments
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
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  -r, --runs <N>    Number of runs (default: 32)"
            echo "  -b, --block <N>   Fork block (default: 10164266)"
            echo "  -h, --help        Show this help"
            echo ""
            echo "Examples:"
            echo "  $0 -r 64          # 64 runs"
            echo "  $0 -b 10200000    # Custom block"
            exit 0
            ;;
        *)
            echo -e "${RED}Error: Unknown argument '$1'${NC}"
            echo "Use -h or --help to see options"
            exit 1
            ;;
    esac
done

TOTAL_CALLS=$((INVARIANT_RUNS * INVARIANT_DEPTH))

# Output functions
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_step() { echo -e "${CYAN}▶${NC} $1"; }

# Automatic cleanup
cleanup() {
    print_info "Cleaning up..."

    # Kill Anvil
    if [ ! -z "$ANVIL_PID" ] && kill -0 "$ANVIL_PID" 2>/dev/null; then
        kill "$ANVIL_PID" 2>/dev/null || true
        sleep 1
    fi
    pkill -f "anvil.*$ANVIL_PORT" 2>/dev/null || true

    # Free port
    if lsof -Pi :${ANVIL_PORT} -sTCP:LISTEN -t >/dev/null 2>&1; then
        lsof -ti:${ANVIL_PORT} | xargs kill -9 2>/dev/null || true
    fi

    # Remove temporary files
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

# Verify dependencies
if ! command -v anvil &> /dev/null || ! command -v forge &> /dev/null; then
    print_error "Foundry not found. Install: curl -L https://foundry.paradigm.xyz | bash"
    exit 1
fi
print_success "Foundry available"

# Show configuration
echo ""
print_step "Configuration"
echo "  Fork: Mainnet block $FORK_BLOCK"
echo "  Fuzzing: $INVARIANT_RUNS runs × $INVARIANT_DEPTH depth = $TOTAL_CALLS calls"
echo "  Rate limit: $COMPUTE_UNITS_PER_SECOND CU/s"
echo ""

# Previous cleanup
cleanup

# PHASE 1: Start Anvil
print_step "Starting Anvil with rate limiting..."
anvil \
    --fork-url "$ALCHEMY_URL" \
    --fork-block-number "$FORK_BLOCK" \
    --port "$ANVIL_PORT" \
    --compute-units-per-second "$COMPUTE_UNITS_PER_SECOND" \
    --timeout "$REQUEST_TIMEOUT" \
    --silent \
    > /tmp/anvil_offline.log 2>&1 &

ANVIL_PID=$!

# Wait for Anvil
for i in {1..30}; do
    if curl -s -X POST "$ANVIL_RPC" -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        >/dev/null 2>&1; then
        break
    fi
    if [ $i -eq 30 ]; then
        print_error "Timeout waiting for Anvil"
        cat /tmp/anvil_offline.log
        exit 1
    fi
    sleep 1
done

print_success "Anvil ready (PID: $ANVIL_PID)"

# PHASE 2: Warmup
print_step "Warming up cache..."
forge test \
    --match-path test/integration/FullFlow.t.sol \
    --match-test "test_E2E_DepositAllocateWithdraw" \
    --fork-url "$ANVIL_RPC" \
    --silent \
    > /tmp/warmup.log 2>&1 || true

print_success "Cache ready"

# PHASE 3: Invariant tests
echo ""
print_step "Running invariant tests ($INVARIANT_RUNS runs)..."
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

# PHASE 4: Report
echo ""
if [ $TEST_EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}              ${GREEN}✓ TESTS PASSED ✓${NC}                    ${GREEN}║${NC}"
    echo -e "${GREEN}╠════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  • Solvency: OK                                ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  • Integrity: OK                               ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  • Total: $INVARIANT_RUNS runs × $INVARIANT_DEPTH depth = $TOTAL_CALLS calls        ${GREEN}║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}"
else
    echo -e "${RED}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║${NC}              ${RED}✗ TESTS FAILED ✗${NC}                    ${RED}║${NC}"
    echo -e "${RED}╠════════════════════════════════════════════════════╣${NC}"
    echo -e "${RED}║${NC}  Check the logs above for details                ${RED}║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════╝${NC}"
fi

echo ""
exit $TEST_EXIT_CODE
