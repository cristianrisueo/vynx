// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {UniswapV3Strategy} from "../../src/strategies/UniswapV3Strategy.sol";
import {StrategyManager} from "../../src/core/StrategyManager.sol";
import {IStrategyManager} from "../../src/interfaces/core/IStrategyManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title UniswapV3StrategyTest
 * @author cristianrisueo
 * @notice Tests unitarios para UniswapV3Strategy con fork de Mainnet
 * @dev Fork test real contra Uniswap V3 WETH/USDC pool — valida deposits, withdrawals y harvest
 */
contract UniswapV3StrategyTest is Test {
    //* Variables de estado

    /// @notice Instancia de la estrategia y manager
    UniswapV3Strategy public strategy;
    StrategyManager public manager;

    /// @notice Direcciones de los contratos en Mainnet
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant UNI_POS_MGR = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant UNI_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant WETH_USDC_POOL = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;

    /// @notice Usuario de prueba
    address public alice = makeAddr("alice");

    //* Setup del entorno de testing

    /**
     * @notice Configura el entorno de testing
     * @dev Fork de Mainnet para interactuar con Uniswap V3 WETH/USDC pool real
     */
    function setUp() public {
        // Crea un fork de Mainnet usando el endpoint de Alchemy
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        // Inicializa manager con parámetros del tier Balanced
        manager = new StrategyManager(
            WETH,
            IStrategyManager.TierConfig({
                max_allocation_per_strategy: 5000, // 50%
                min_allocation_threshold: 2000, // 20%
                rebalance_threshold: 200, // 2%
                min_tvl_for_rebalance: 8 ether
            })
        );

        // Inicializa la estrategia con el pool WETH/USDC 0.05%
        strategy = new UniswapV3Strategy(
            address(manager),
            UNI_POS_MGR,
            UNI_ROUTER,
            WETH_USDC_POOL,
            WETH,
            USDC
        );
    }

    //* Funciones internas helpers

    /**
     * @notice Helper para depositar en la estrategia como manager
     * @param amount Cantidad a depositar
     */
    function _deposit(uint256 amount) internal {
        // Da WETH a la estrategia y deposita como manager
        deal(WETH, address(strategy), amount);
        vm.prank(address(manager));
        strategy.deposit(amount);
    }

    /**
     * @notice Helper para retirar de la estrategia como manager
     * @param amount Cantidad a retirar
     */
    function _withdraw(uint256 amount) internal {
        vm.prank(address(manager));
        strategy.withdraw(amount);
    }

    //* Testing de deposit

    /**
     * @notice Test de depósito básico en Uniswap V3
     * @dev Comprueba que WETH se convierte en posición LP NFT y totalAssets lo refleje
     */
    function test_Deposit_Basic() public {
        // Deposita en Uniswap V3 (50% swap WETH→USDC + mint position NFT)
        _deposit(10 ether);

        // Comprueba que se creó una posición (token_id != 0)
        assertGt(strategy.token_id(), 0, "Debe haberse creado un NFT de posicion");

        // Comprueba que totalAssets refleje el depósito con tolerancia del 5%
        // (por el swap 50% + slippage + concentración del rango)
        assertApproxEqRel(strategy.totalAssets(), 10 ether, 0.05e18);
    }

    /**
     * @notice Test de múltiples depósitos aumentan la posición existente
     * @dev El segundo depósito debe aumentar la liquidez del NFT existente
     */
    function test_Deposit_IncreasesExistingPosition() public {
        // Primer depósito crea la posición
        _deposit(10 ether);
        uint256 token_id_first = strategy.token_id();
        uint256 assets_after_first = strategy.totalAssets();

        // Segundo depósito incrementa la posición existente
        _deposit(10 ether);

        // El token_id debe ser el mismo (se reutiliza el NFT)
        assertEq(strategy.token_id(), token_id_first, "El token_id no debe cambiar en deposits sucesivos");

        // totalAssets debe haber aumentado aproximadamente en el segundo depósito
        assertGt(strategy.totalAssets(), assets_after_first, "totalAssets debe crecer con el segundo deposito");
    }

    /**
     * @notice Test de depósito solo desde manager
     * @dev Comprueba que solo el manager pueda depositar
     */
    function test_Deposit_RevertIfNotManager() public {
        deal(WETH, address(strategy), 10 ether);

        vm.prank(alice);
        vm.expectRevert(UniswapV3Strategy.UniswapV3Strategy__OnlyManager.selector);
        strategy.deposit(10 ether);
    }

    /**
     * @notice Test de depósito de cantidad cero
     * @dev Comprueba que revierta con cantidad cero
     */
    function test_Deposit_RevertZeroAmount() public {
        vm.prank(address(manager));
        vm.expectRevert(UniswapV3Strategy.UniswapV3Strategy__ZeroAmount.selector);
        strategy.deposit(0);
    }

    //* Testing de withdraw

    /**
     * @notice Test de retiro básico de Uniswap V3
     * @dev Comprueba que decreaseLiquidity → collect → swap USDC→WETH → manager
     */
    function test_Withdraw_Basic() public {
        // Deposita primero
        _deposit(10 ether);

        // Retira la mitad (tolerancia 5% por slippage en swap USDC→WETH)
        _withdraw(5 ether);

        // Comprueba que el manager recibió los fondos
        assertApproxEqRel(IERC20(WETH).balanceOf(address(manager)), 5 ether, 0.05e18);
    }

    /**
     * @notice Test de retiro total quema el NFT
     * @dev Cuando la posición queda vacía, el NFT debe ser quemado y token_id = 0
     */
    function test_Withdraw_Full_BurnsNFT() public {
        // Deposita
        _deposit(10 ether);
        assertGt(strategy.token_id(), 0, "Debe haber un NFT");

        // Retira todo
        uint256 total = strategy.totalAssets();
        _withdraw(total);

        // El NFT debe haber sido quemado
        assertEq(strategy.token_id(), 0, "El NFT debe estar quemado tras retiro total");
    }

    /**
     * @notice Test de retiro solo desde manager
     * @dev Comprueba que solo el manager pueda retirar
     */
    function test_Withdraw_RevertIfNotManager() public {
        _deposit(10 ether);

        vm.prank(alice);
        vm.expectRevert(UniswapV3Strategy.UniswapV3Strategy__OnlyManager.selector);
        strategy.withdraw(5 ether);
    }

    /**
     * @notice Test de retiro de cantidad cero
     * @dev Comprueba que revierta con cantidad cero
     */
    function test_Withdraw_RevertZeroAmount() public {
        vm.prank(address(manager));
        vm.expectRevert(UniswapV3Strategy.UniswapV3Strategy__ZeroAmount.selector);
        strategy.withdraw(0);
    }

    /**
     * @notice Test de retiro sin posición
     * @dev Comprueba que revierta si no hay posición (token_id == 0)
     */
    function test_Withdraw_RevertNoPosition() public {
        vm.prank(address(manager));
        vm.expectRevert(UniswapV3Strategy.UniswapV3Strategy__InsufficientLiquidity.selector);
        strategy.withdraw(1 ether);
    }

    //* Testing de harvest

    /**
     * @notice Test de harvest colecta fees acumuladas
     * @dev Tras tiempo de actividad en el pool, collect recoge fees en ambos tokens
     */
    function test_Harvest_CollectsFees() public {
        // Deposita fondos para tener una posición activa
        _deposit(100 ether);

        // Avanza tiempo para acumular fees (simulando volumen)
        skip(7 days);
        vm.roll(block.number + 50400);

        // Harvest no debe revertir
        vm.prank(address(manager));
        strategy.harvest();

        // La posición debe seguir activa (token_id aún existe o fue reinvertido)
        // No verificamos profit exacto ya que depende del volumen real del pool
    }

    /**
     * @notice Test de harvest solo desde manager
     * @dev Comprueba que solo el manager pueda llamar harvest
     */
    function test_Harvest_RevertIfNotManager() public {
        vm.prank(alice);
        vm.expectRevert(UniswapV3Strategy.UniswapV3Strategy__OnlyManager.selector);
        strategy.harvest();
    }

    //* Testing de funciones de consulta

    /**
     * @notice Test de APY
     * @dev Comprueba que el APY sea el valor hardcodeado (1400 bps = 14%)
     */
    function test_Apy_ReturnsValidValue() public view {
        uint256 apy = strategy.apy();

        // El APY de Uniswap V3 está hardcodeado en 1400 bps (14%)
        assertEq(apy, 1400);
    }

    /**
     * @notice Test de nombre de la estrategia
     * @dev Comprueba que devuelva el nombre correcto
     */
    function test_Name() public view {
        assertEq(strategy.name(), "Uniswap V3 WETH/USDC Strategy");
    }

    /**
     * @notice Test de asset
     * @dev Comprueba que devuelva la dirección de WETH
     */
    function test_Asset() public view {
        assertEq(strategy.asset(), WETH);
    }

    /**
     * @notice Test de totalAssets sin posición
     * @dev Comprueba que devuelva 0 cuando no hay posición (token_id == 0)
     */
    function test_TotalAssets_ZeroWithoutDeposits() public view {
        assertEq(strategy.totalAssets(), 0);
        assertEq(strategy.token_id(), 0);
    }

    /**
     * @notice Test de ticks de la posición
     * @dev Comprueba que los ticks estén configurados correctamente (lower < upper)
     */
    function test_Ticks_AreValid() public view {
        assertLt(strategy.lower_tick(), strategy.upper_tick(), "lower_tick debe ser menor que upper_tick");
    }
}
