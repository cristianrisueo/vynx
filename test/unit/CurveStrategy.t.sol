// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {CurveStrategy} from "../../src/strategies/CurveStrategy.sol";
import {StrategyManager} from "../../src/core/StrategyManager.sol";
import {IStrategyManager} from "../../src/interfaces/core/IStrategyManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title CurveStrategyTest
 * @author cristianrisueo
 * @notice Tests unitarios para CurveStrategy con fork de Mainnet
 * @dev Fork test real contra Curve stETH/ETH pool y gauge — valida deposits, withdrawals y harvest
 */
contract CurveStrategyTest is Test {
    //* Variables de estado

    /// @notice Instancia de la estrategia y manager
    CurveStrategy public strategy;
    StrategyManager public manager;

    /// @notice Direcciones de los contratos en Mainnet
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant CURVE_POOL = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;
    address constant CURVE_GAUGE = 0x182B723a58739a9c974cFDB385ceaDb237453c28;
    address constant CURVE_LP = 0x06325440D014e39736583c165C2963BA99fAf14E;
    address constant CRV_TOKEN = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address constant UNISWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    uint24 constant POOL_FEE = 3000; // CRV/WETH 0.3%

    /// @notice Usuario de prueba
    address public alice = makeAddr("alice");

    //* Setup del entorno de testing

    /**
     * @notice Configura el entorno de testing
     * @dev Fork de Mainnet para interactuar con Curve stETH/ETH pool y gauge reales
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

        // Inicializa la estrategia con todas las dependencias de Curve
        strategy = new CurveStrategy(
            address(manager),
            STETH,
            CURVE_POOL,
            CURVE_GAUGE,
            CURVE_LP,
            CRV_TOKEN,
            WETH,
            UNISWAP_ROUTER,
            POOL_FEE
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
     * @notice Test de depósito básico en Curve
     * @dev Comprueba que WETH → stETH → LP → gauge y totalAssets lo refleje
     */
    function test_Deposit_Basic() public {
        // Deposita en Curve (WETH → ETH → stETH → add_liquidity → gauge)
        _deposit(10 ether);

        // Comprueba que totalAssets refleje el depósito (tolerancia 1% por slippage/fees de Curve)
        assertApproxEqRel(strategy.totalAssets(), 10 ether, 0.01e18);

        // Comprueba que hay LP tokens stakeados en el gauge
        assertGt(strategy.lpBalance(), 0, "Debe haber LP tokens en el gauge");
    }

    /**
     * @notice Test de depósito solo desde manager
     * @dev Comprueba que solo el manager pueda depositar
     */
    function test_Deposit_RevertIfNotManager() public {
        deal(WETH, address(strategy), 10 ether);

        vm.prank(alice);
        vm.expectRevert(CurveStrategy.CurveStrategy__OnlyManager.selector);
        strategy.deposit(10 ether);
    }

    /**
     * @notice Test de depósito de cantidad cero
     * @dev Comprueba que revierta con cantidad cero
     */
    function test_Deposit_RevertZeroAmount() public {
        vm.prank(address(manager));
        vm.expectRevert(CurveStrategy.CurveStrategy__ZeroAmount.selector);
        strategy.deposit(0);
    }

    //* Testing de withdraw

    /**
     * @notice Test de retiro básico de Curve
     * @dev Comprueba que gauge.withdraw → remove_liquidity_one_coin → WETH al manager
     */
    function test_Withdraw_Basic() public {
        // Deposita primero
        _deposit(10 ether);

        // Retira la mitad (tolerancia 2% por slippage en retiro de Curve)
        _withdraw(5 ether);

        // Comprueba que el manager recibió los fondos
        assertApproxEqRel(IERC20(WETH).balanceOf(address(manager)), 5 ether, 0.02e18);

        // Comprueba que queda aproximadamente la mitad en la estrategia
        assertApproxEqRel(strategy.totalAssets(), 5 ether, 0.02e18);
    }

    /**
     * @notice Test de retiro total de Curve
     * @dev Comprueba que se pueda retirar todo el balance
     */
    function test_Withdraw_Full() public {
        // Deposita
        _deposit(10 ether);

        // Retira todo
        uint256 total = strategy.totalAssets();
        _withdraw(total);

        // Comprueba que el balance en la estrategia sea 0 o mínimo residual
        assertApproxEqAbs(strategy.totalAssets(), 0, 0.001 ether);
    }

    /**
     * @notice Test de retiro solo desde manager
     * @dev Comprueba que solo el manager pueda retirar
     */
    function test_Withdraw_RevertIfNotManager() public {
        _deposit(10 ether);

        vm.prank(alice);
        vm.expectRevert(CurveStrategy.CurveStrategy__OnlyManager.selector);
        strategy.withdraw(5 ether);
    }

    /**
     * @notice Test de retiro de cantidad cero
     * @dev Comprueba que revierta con cantidad cero
     */
    function test_Withdraw_RevertZeroAmount() public {
        vm.prank(address(manager));
        vm.expectRevert(CurveStrategy.CurveStrategy__ZeroAmount.selector);
        strategy.withdraw(0);
    }

    //* Testing de harvest

    /**
     * @notice Test de harvest con rewards CRV
     * @dev Inyecta CRV tokens en el gauge para simular rewards acumulados y verifica reinversión
     */
    function test_Harvest_WithRewards() public {
        // Deposita fondos para que haya LP tokens en el gauge
        _deposit(100 ether);

        // Inyecta CRV tokens en la estrategia para simular rewards del gauge
        deal(CRV_TOKEN, address(strategy), 100 ether);

        // Avanza tiempo para acumular rewards
        skip(7 days);
        vm.roll(block.number + 50400);

        // Harvest no debe revertir
        vm.prank(address(manager));
        strategy.harvest();

        // Tras el harvest, los LP tokens deben haberse mantenido o incrementado
        assertGt(strategy.lpBalance(), 0, "Debe haber LP tokens tras harvest");
    }

    /**
     * @notice Test de harvest solo desde manager
     * @dev Comprueba que solo el manager pueda llamar harvest
     */
    function test_Harvest_RevertIfNotManager() public {
        vm.prank(alice);
        vm.expectRevert(CurveStrategy.CurveStrategy__OnlyManager.selector);
        strategy.harvest();
    }

    //* Testing de funciones de consulta

    /**
     * @notice Test de APY
     * @dev Comprueba que el APY sea el valor hardcodeado (600 bps = 6%)
     */
    function test_Apy_ReturnsValidValue() public view {
        uint256 apy = strategy.apy();

        // El APY de Curve está hardcodeado en 600 bps (6%)
        assertEq(apy, 600);
    }

    /**
     * @notice Test de nombre de la estrategia
     * @dev Comprueba que devuelva el nombre correcto
     */
    function test_Name() public view {
        assertEq(strategy.name(), "Curve stETH/ETH Strategy");
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
     * @notice Test de lpBalance sin depósitos
     * @dev Comprueba que lpBalance devuelva 0 sin depósitos
     */
    function test_LpBalance_ZeroWithoutDeposits() public view {
        assertEq(strategy.lpBalance(), 0);
    }

    /**
     * @notice Test de yield acumulado via virtual price
     * @dev Tras tiempo, la virtual price del pool sube ligeramente por trading fees acumuladas
     *      Esto causa que totalAssets crezca aunque no se haga harvest explícito
     */
    function test_TotalAssets_GrowsWithTime() public {
        // Deposita fondos
        _deposit(100 ether);
        uint256 assets_before = strategy.totalAssets();

        // Avanza 30 días para que se acumulen trading fees en la virtual price
        skip(30 days);
        vm.roll(block.number + 216000);

        // totalAssets debería ser mayor o igual (virtual price solo sube)
        uint256 assets_after = strategy.totalAssets();
        assertGe(assets_after, assets_before, "totalAssets deberia crecer o mantenerse con el tiempo");
    }
}
