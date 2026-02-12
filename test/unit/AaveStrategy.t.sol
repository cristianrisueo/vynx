// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {AaveStrategy} from "../../src/strategies/AaveStrategy.sol";
import {StrategyManager} from "../../src/core/StrategyManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title AaveStrategyTest
 * @author cristianrisueo
 * @notice Tests unitarios para AaveStrategy con fork de Mainnet
 * @dev Fork test real contra Aave v3 - valida deposits, withdrawals y APY
 */
contract AaveStrategyTest is Test {
    //* Variables de estado

    /// @notice Instancia de la estrategia y manager
    AaveStrategy public strategy;
    StrategyManager public manager;

    /// @notice Direcciones de los contratos en Mainnet
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    /// @notice Usuario de prueba
    address public alice = makeAddr("alice");

    //* Setup del entorno de testing

    /**
     * @notice Configura el entorno de testing
     * @dev Fork de Mainnet para interactuar con Aave v3 real
     */
    function setUp() public {
        // Crea un fork de Mainnet usando el endpoint de Alchemy
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        // Inicializa manager (necesario para la estrategia)
        manager = new StrategyManager(WETH);

        // Inicializa la estrategia
        strategy = new AaveStrategy(address(manager), WETH, AAVE_POOL);
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
     * @notice Test de depósito básico en Aave
     * @dev Comprueba que el depósito se realice correctamente
     */
    function test_Deposit_Basic() public {
        // Deposita en Aave
        _deposit(10 ether);

        // Comprueba que totalAssets refleje el depósito
        assertApproxEqRel(strategy.totalAssets(), 10 ether, 0.001e18);

        // Comprueba que aTokenBalance coincida
        assertEq(strategy.totalAssets(), strategy.aTokenBalance());
    }

    /**
     * @notice Test de depósito solo desde manager
     * @dev Comprueba que solo el manager pueda depositar
     */
    function test_Deposit_RevertIfNotManager() public {
        deal(WETH, address(strategy), 10 ether);

        vm.prank(alice);
        vm.expectRevert(AaveStrategy.AaveStrategy__OnlyManager.selector);
        strategy.deposit(10 ether);
    }

    //* Testing de withdraw

    /**
     * @notice Test de retiro básico de Aave
     * @dev Comprueba que el retiro se realice correctamente
     */
    function test_Withdraw_Basic() public {
        // Deposita primero
        _deposit(10 ether);

        // Retira la mitad
        _withdraw(5 ether);

        // Comprueba que el manager recibió los fondos
        assertEq(IERC20(WETH).balanceOf(address(manager)), 5 ether);

        // Comprueba que queda aproximadamente la mitad
        assertApproxEqRel(strategy.totalAssets(), 5 ether, 0.001e18);
    }

    /**
     * @notice Test de retiro total de Aave
     * @dev Comprueba que se pueda retirar todo
     */
    function test_Withdraw_Full() public {
        // Deposita
        _deposit(10 ether);

        // Retira todo
        uint256 balance = strategy.totalAssets();
        _withdraw(balance);

        // Comprueba que el balance sea 0
        assertEq(strategy.totalAssets(), 0);
    }

    /**
     * @notice Test de retiro solo desde manager
     * @dev Comprueba que solo el manager pueda retirar
     */
    function test_Withdraw_RevertIfNotManager() public {
        _deposit(10 ether);

        vm.prank(alice);
        vm.expectRevert(AaveStrategy.AaveStrategy__OnlyManager.selector);
        strategy.withdraw(5 ether);
    }

    //* Testing de funciones de consulta

    /**
     * @notice Test de APY
     * @dev Comprueba que el APY sea un valor razonable
     */
    function test_Apy_ReturnsValidValue() public view {
        uint256 apy = strategy.apy();

        // El APY debería estar entre 0% y 50% (0 - 5000 bp)
        assertLt(apy, 5000);
    }

    /**
     * @notice Test de nombre de la estrategia
     * @dev Comprueba que devuelva el nombre correcto
     */
    function test_Name() public view {
        assertEq(strategy.name(), "Aave v3 WETH Strategy");
    }

    /**
     * @notice Test de asset
     * @dev Comprueba que devuelva la dirección de WETH
     */
    function test_Asset() public view {
        assertEq(strategy.asset(), WETH);
    }

    /**
     * @notice Test de liquidez disponible
     * @dev Comprueba que availableLiquidity devuelva un valor
     */
    function test_AvailableLiquidity() public view {
        uint256 liquidity = strategy.availableLiquidity();

        // Aave mainnet debería tener liquidez significativa
        assertGt(liquidity, 0);
    }

    /**
     * @notice Test de totalAssets sin depósitos
     * @dev Comprueba que devuelva 0 sin depósitos
     */
    function test_TotalAssets_ZeroWithoutDeposits() public view {
        assertEq(strategy.totalAssets(), 0);
    }
}
