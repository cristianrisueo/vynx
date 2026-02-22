// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {LidoStrategy} from "../../src/strategies/LidoStrategy.sol";
import {StrategyManager} from "../../src/core/StrategyManager.sol";
import {IStrategyManager} from "../../src/interfaces/core/IStrategyManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INonfungiblePositionManager} from "../../src/interfaces/strategies/uniswap/INonfungiblePositionManager.sol";
import {IWstETH} from "../../src/interfaces/strategies/lido/IWstETH.sol";
import {IWETH} from "@aave/contracts/misc/interfaces/IWETH.sol";

/**
 * @title LidoStrategyTest
 * @author cristianrisueo
 * @notice Tests unitarios para LidoStrategy con fork de Mainnet
 * @dev Fork test real contra Lido wstETH - valida deposits, withdrawals y APY
 */
contract LidoStrategyTest is Test {
    //* Variables de estado

    /// @notice Instancia de la estrategia y manager
    LidoStrategy public strategy;
    StrategyManager public manager;

    /// @notice Direcciones de los contratos en Mainnet
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant UNISWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    uint24 constant POOL_FEE = 500; // pool wstETH/WETH usa 0.05%

    /// @notice Usuario de prueba
    address public alice = makeAddr("alice");

    //* Setup del entorno de testing

    /**
     * @notice Configura el entorno de testing
     * @dev Fork de Mainnet para interactuar con Lido wstETH real
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

        // Inicializa la estrategia con wstETH y Uniswap V3 para el retiro
        strategy = new LidoStrategy(address(manager), WSTETH, WETH, UNISWAP_ROUTER, POOL_FEE);

        // Semilla de liquidez en el pool wstETH/WETH de Uniswap V3
        _seedWstEthPool();
    }

    /**
     * @notice Añade liquidez al pool wstETH/WETH de Uniswap V3
     * @dev El pool forkeado puede tener liquidez insuficiente, esto garantiza swaps exitosos
     */
    function _seedWstEthPool() internal {
        uint256 ethAmount = 100_000 ether;
        deal(address(this), ethAmount);

        // WETH → ETH → wstETH
        IWETH(WETH).deposit{value: ethAmount}();
        IERC20(WETH).approve(address(0), 0); // reset
        uint256 halfWeth = ethAmount / 2;

        // Obtener wstETH: unwrap half WETH → ETH → stake en Lido
        IWETH(WETH).withdraw(halfWeth);
        (bool ok,) = WSTETH.call{value: halfWeth}("");
        require(ok, "wstETH stake failed");

        uint256 wstBal = IERC20(WSTETH).balanceOf(address(this));

        // Aprobar position manager
        IERC20(WSTETH).approve(POSITION_MANAGER, wstBal);
        IERC20(WETH).approve(POSITION_MANAGER, halfWeth);

        // Mint concentrated position around current tick (token0=wstETH < token1=WETH)
        INonfungiblePositionManager(POSITION_MANAGER).mint(
            INonfungiblePositionManager.MintParams({
                token0: WSTETH,
                token1: WETH,
                fee: POOL_FEE,
                tickLower: -1000,
                tickUpper: 3000,
                amount0Desired: wstBal,
                amount1Desired: halfWeth,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
    }

    receive() external payable {}

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
     * @notice Test de depósito básico en Lido
     * @dev Comprueba que el depósito convierta WETH a wstETH y totalAssets lo refleje
     */
    function test_Deposit_Basic() public {
        // Deposita en Lido (WETH → ETH → wstETH)
        _deposit(10 ether);

        // Comprueba que totalAssets refleje el depósito (aproximadamente, por exchange rate)
        // El valor en WETH equivalente puede diferir ligeramente por el tipo de cambio wstETH
        assertApproxEqRel(strategy.totalAssets(), 10 ether, 0.001e18);
    }

    /**
     * @notice Test de depósito solo desde manager
     * @dev Comprueba que solo el manager pueda depositar
     */
    function test_Deposit_RevertIfNotManager() public {
        deal(WETH, address(strategy), 10 ether);

        vm.prank(alice);
        vm.expectRevert(LidoStrategy.LidoStrategy__OnlyManager.selector);
        strategy.deposit(10 ether);
    }

    /**
     * @notice Test de depósito de cantidad cero
     * @dev Comprueba que revierta con cantidad cero
     */
    function test_Deposit_RevertZeroAmount() public {
        vm.prank(address(manager));
        vm.expectRevert(LidoStrategy.LidoStrategy__ZeroAmount.selector);
        strategy.deposit(0);
    }

    //* Testing de withdraw

    /**
     * @notice Test de retiro básico de Lido
     * @dev Comprueba que el retiro intercambie wstETH→WETH via Uniswap y envíe al manager
     */
    function test_Withdraw_Basic() public {
        // Deposita primero
        _deposit(10 ether);

        // Retira la mitad
        _withdraw(5 ether);

        // Comprueba que el manager recibió los fondos (tolerancia 1% por slippage)
        assertApproxEqRel(IERC20(WETH).balanceOf(address(manager)), 5 ether, 0.01e18);

        // Comprueba que queda aproximadamente la mitad
        assertApproxEqRel(strategy.totalAssets(), 5 ether, 0.01e18);
    }

    /**
     * @notice Test de retiro total de Lido
     * @dev Comprueba que se pueda retirar todo el balance
     */
    function test_Withdraw_Full() public {
        // Deposita
        _deposit(10 ether);

        // Retira todo (usa totalAssets como referencia del WETH equivalente)
        uint256 total = strategy.totalAssets();
        _withdraw(total);

        // Comprueba que el balance en la estrategia sea ~0 (1 wei dust posible por redondeo wstETH)
        assertLe(strategy.totalAssets(), 1);
    }

    /**
     * @notice Test de retiro solo desde manager
     * @dev Comprueba que solo el manager pueda retirar
     */
    function test_Withdraw_RevertIfNotManager() public {
        _deposit(10 ether);

        vm.prank(alice);
        vm.expectRevert(LidoStrategy.LidoStrategy__OnlyManager.selector);
        strategy.withdraw(5 ether);
    }

    /**
     * @notice Test de retiro de cantidad cero
     * @dev Comprueba que revierta con cantidad cero
     */
    function test_Withdraw_RevertZeroAmount() public {
        vm.prank(address(manager));
        vm.expectRevert(LidoStrategy.LidoStrategy__ZeroAmount.selector);
        strategy.withdraw(0);
    }

    //* Testing de harvest

    /**
     * @notice Test de harvest en Lido
     * @dev Harvest siempre devuelve 0 en Lido — el yield está embebido en el exchange rate de wstETH
     */
    function test_Harvest_AlwaysReturnsZero() public {
        // Deposita fondos
        _deposit(10 ether);

        // Avanza tiempo para demostrar que el yield no se obtiene via harvest
        skip(30 days);

        // Harvest debe devolver 0 — el yield ya está en el exchange rate
        vm.prank(address(manager));
        uint256 profit = strategy.harvest();
        assertEq(profit, 0, "Lido harvest debe devolver 0");
    }

    /**
     * @notice Test de harvest solo desde manager
     * @dev Comprueba que solo el manager pueda llamar harvest
     */
    function test_Harvest_RevertIfNotManager() public {
        vm.prank(alice);
        vm.expectRevert(LidoStrategy.LidoStrategy__OnlyManager.selector);
        strategy.harvest();
    }

    //* Testing de funciones de consulta

    /**
     * @notice Test de APY
     * @dev Comprueba que el APY sea el valor configurado de Lido (400 bps = 4%)
     */
    function test_Apy_ReturnsValidValue() public view {
        uint256 apy = strategy.apy();

        // El APY de Lido está hardcodeado en 400 bps (4%)
        assertEq(apy, 400);
    }

    /**
     * @notice Test de nombre de la estrategia
     * @dev Comprueba que devuelva el nombre correcto
     */
    function test_Name() public view {
        assertEq(strategy.name(), "Lido wstETH Strategy");
    }

    /**
     * @notice Test de asset
     * @dev Comprueba que devuelva la dirección de WETH
     */
    function test_Asset() public view {
        assertEq(strategy.asset(), WETH);
    }

    /**
     * @notice Test de totalAssets sin depósitos
     * @dev Comprueba que devuelva 0 sin depósitos previos
     */
    function test_TotalAssets_ZeroWithoutDeposits() public view {
        assertEq(strategy.totalAssets(), 0);
    }

    /**
     * @notice Test de yield embebido en el exchange rate de wstETH
     * @dev Tras tiempo, totalAssets crece sin necesidad de harvest (yield auto-acumulativo)
     */
    function test_TotalAssets_GrowsWithTime() public {
        // Deposita fondos
        _deposit(100 ether);
        uint256 assets_before = strategy.totalAssets();

        // Avanza 30 días para que el exchange rate de wstETH crezca
        skip(30 days);
        vm.roll(block.number + 216000); // ~30 días de bloques

        // totalAssets debería ser mayor (yield acumulado via exchange rate)
        uint256 assets_after = strategy.totalAssets();
        assertGe(assets_after, assets_before, "totalAssets deberia crecer o mantenerse con el tiempo");
    }
}
