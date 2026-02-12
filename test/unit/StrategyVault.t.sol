// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {StrategyVault} from "../../src/core/StrategyVault.sol";
import {StrategyManager} from "../../src/core/StrategyManager.sol";
import {AaveStrategy} from "../../src/strategies/AaveStrategy.sol";
import {CompoundStrategy} from "../../src/strategies/CompoundStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title StrategyVaultTest
 * @author cristianrisueo
 * @notice Tests unitarios para StrategyVault con fork de Mainnet
 * @dev Fork test de mainnet, aquí no hay mierdas
 */
contract StrategyVaultTest is Test {
    //* Variables de estado

    /// @notice Instancia del vault, manager y estrategias
    StrategyVault public vault;
    StrategyManager public manager;
    AaveStrategy public aave_strategy;
    CompoundStrategy public compound_strategy;

    /// @notice Direcciones de los contratos en Mainnet
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant COMPOUND_COMET = 0xA17581A9E3356d9A858b789D68B4d866e593aE94;

    /// @notice Usuarios de prueba
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public fee_receiver;

    /// @notice Parámetros del vault
    uint256 constant MAX_TVL = 1000 ether;
    uint256 constant WITHDRAWAL_FEE = 200;

    //* Setup del entorno de testing

    /**
     * @notice Configura el entorno de testing
     * @dev Para un comportamiento real hacemos fork de Mainnet. No recomiendo testear en
     *      testnets, los contratos desplegados SON UNA MIERDA, no es comportamiento real
     */
    function setUp() public {
        // Crea un fork de Mainnet usando mi endpoint de Alchemy en env.var
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        // Setea el fee receiver
        fee_receiver = makeAddr("feeReceiver");

        // Inicializa el manager, vault y setea el address del vault en el manager
        manager = new StrategyManager(WETH);
        vault = new StrategyVault(WETH, address(manager), fee_receiver);
        manager.initializeVault(address(vault));

        // Inicializa las estrategias con las direcciones reales de mainnet
        aave_strategy = new AaveStrategy(address(manager), WETH, AAVE_POOL);
        compound_strategy = new CompoundStrategy(address(manager), WETH, COMPOUND_COMET);

        // Añade las estrategias
        manager.addStrategy(address(aave_strategy));
        manager.addStrategy(address(compound_strategy));
    }

    //* Funciones internas helpers

    /**
     * @notice Helper de depósito utilizado en la mayoría de tests
     * @dev Los helpers solo se usan para happy paths, no casos donde se espera revert
     * @param user Usuario utilizado en la interacción
     * @param amount Cantidad entregada al usuario
     * @return shares Cantidad de shares minteadas al usuario tras el depósito
     */
    function _deposit(address user, uint256 amount) internal returns (uint256 shares) {
        // Entrega la cantidad de WETH al usuario y usa su address
        deal(WETH, user, amount);
        vm.startPrank(user);

        // Aprueba al vault la transferencia de WETH y deposita la cantidad en el vault
        IERC20(WETH).approve(address(vault), amount);
        shares = vault.deposit(amount, user);

        vm.stopPrank();
    }

    /**
     * @notice Helper de retiro utilizado en la mayoría de tests
     * @dev Los helpers solo se usan para happy paths, no casos donde se espera revert
     * @param user Usuario utilizado en la interacción
     * @param amount Cantidad entregada al usuario
     * @return shares Cantidad de shares del usuario quemadas tras el retiro
     */
    function _withdraw(address user, uint256 amount) internal returns (uint256 shares) {
        // Utiliza el address del usuario. retira la cantidad y devuelve las shares quemadas
        vm.prank(user);
        shares = vault.withdraw(amount, user, user);
    }

    //* Test unitarios de lógica principal: Depósitos

    /**
     * @notice Test de depósito básico
     * @dev Comprueba que un usuario pueda depositar y recibir shares correctamente
     */
    function test_Deposit_Basic() public {
        // Usa a Alice para depositar 1 WETH
        uint256 amount = 1 ether;
        uint256 shares = _deposit(alice, amount);

        // Comprueba shares recibidas por Alice, assets en el vault y assets en el buffer idle
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.totalAssets(), amount);
        assertEq(vault.idle_weth(), amount);
    }

    /**
     * @notice Test de depósito igual a IDLE threshold
     * @dev Realiza depósito superior al threshold para comprobar que el vault hace allocation
     */
    function test_Deposit_TriggersAllocation() public {
        // Usa a alice para depositar cantidad límite
        _deposit(alice, vault.idle_threshold());

        // Comprueba que tanto el vault cómo el buffer IDLE no tiene WETH
        assertEq(vault.idle_weth(), 0);
        assertGt(manager.totalAssets(), 0);
    }

    /**
     * @notice Test de depósito de cantidad cero
     * @dev Realiza depósito con cantidad cero y comprueba que se revierte con error esperado
     */
    function test_Deposit_RevertZero() public {
        // Usa a Alice para depositar cantidad cero
        vm.prank(alice);

        // Espera el error y deposita
        vm.expectRevert(StrategyVault.StrategyVault__ZeroAmount.selector);
        vault.deposit(0, alice);
    }

    /**
     * @notice Test de depósito de cantidad por debajo de la mínima
     * @dev Realiza depósito con cantidad ínfima y comprueba que se reviera con error esperado
     */
    function test_Deposit_RevertBelowMin() public {
        // Entrega a Alice 0.005 WETH y usa su address
        deal(WETH, alice, 0.005 ether);
        vm.startPrank(alice);

        // Aprueba al vault la transferencia
        IERC20(WETH).approve(address(vault), 0.005 ether);

        // Espera el error y deposita
        vm.expectRevert(StrategyVault.StrategyVault__BelowMinDeposit.selector);
        vault.deposit(0.005 ether, alice);

        vm.stopPrank();
    }

    /**
     * @notice Test de depósito de cantidad por encima de máximo TVL
     * @dev Realiza depósito con cantidad superior y comprueba que se reviera con error esperado
     */
    function test_Deposit_RevertExceedsMaxTVL() public {
        // Entrega a Alice cantidad superior al máximo permitido TVL y usa su address
        deal(WETH, alice, MAX_TVL + 1);
        vm.startPrank(alice);

        // Aprueba al vault la transferencia
        IERC20(WETH).approve(address(vault), MAX_TVL + 1);

        // Espera el error y deposita
        vm.expectRevert(StrategyVault.StrategyVault__MaxTVLExceeded.selector);
        vault.deposit(MAX_TVL + 1, alice);

        vm.stopPrank();
    }

    /**
     * @notice Test de depósito cuando el vault está pausado
     * @dev Realiza depósito con cantidad normal y comprueba que se reviera con error esperado
     */
    function test_Deposit_RevertWhenPaused() public {
        // Pausa el vault
        vault.pause();

        // Entrega 1 WETH a Alice y usa su address
        deal(WETH, alice, 1 ether);
        vm.startPrank(alice);

        // Aprueba al vault la transferencia
        IERC20(WETH).approve(address(vault), 1 ether);

        // Espera el error y deposita
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.deposit(1 ether, alice);

        vm.stopPrank();
    }

    //* Testing de mint

    /**
     * @notice Test de mint básico
     * @dev Comprueba que un usuario pueda hacer mint y recibir shares correctamente
     */
    function test_Mint_Basic() public {
        // Entrega 10 WETH a Alice y usa su address
        deal(WETH, alice, 10 ether);
        vm.startPrank(alice);

        // Aprueba al vault la transferencia
        IERC20(WETH).approve(address(vault), 10 ether);

        // Realiza el mint de 5 WETH
        vault.mint(5 ether, alice);
        vm.stopPrank();

        // Comprueba que el balance de shares de Alice corresponda con 5 WETH (ratio 1:1)
        assertEq(vault.balanceOf(alice), 5 ether);
    }

    /**
     * @notice Test de mint de cantidad cero
     * @dev Realiza mint con cantidad cero y comprueba que se revierte con error esperado
     */
    function test_Mint_RevertZero() public {
        // Utiliza el address de Alice
        vm.prank(alice);

        // Espera el error y mintea 0 shares
        vm.expectRevert(StrategyVault.StrategyVault__ZeroAmount.selector);
        vault.mint(0, alice);
    }

    //* Testing de withdraw

    /**
     * @notice Test de retiro desde buffer idle
     * @dev Comprueba que se retire correctamente del idle sin tocar el manager
     */
    function test_Withdraw_FromIdle() public {
        // Deposita 5 WETH (se queda en idle)
        _deposit(alice, 5 ether);

        // Retira 2 WETH
        _withdraw(alice, 2 ether);

        // Comprueba balance de Alice y que el manager siga vacío
        assertEq(IERC20(WETH).balanceOf(alice), 2 ether);
        assertEq(manager.totalAssets(), 0);
    }

    /**
     * @notice Test de retiro desde estrategias
     * @dev Comprueba que se retire del manager cuando el idle no es suficiente
     */
    function test_Withdraw_FromStrategies() public {
        // Deposita 20 WETH (supera threshold, va al manager)
        _deposit(alice, 20 ether);

        // Retira 15 WETH
        _withdraw(alice, 15 ether);

        // Comprueba balance final de Alice
        assertEq(IERC20(WETH).balanceOf(alice), 15 ether);
    }

    /**
     * @notice Test de cálculo de fee de retiro
     * @dev Comprueba que el fee se descuente correctamente del balance del fee receiver
     */
    function test_Withdraw_FeeCalculation() public {
        // Deposita 100 WETH para tener margen
        _deposit(alice, 100 ether);

        // Guarda el balance previo del fee receiver
        uint256 fee_before = IERC20(WETH).balanceOf(fee_receiver);

        // Retira 50 WETH
        _withdraw(alice, 50 ether);

        // Calcula el fee esperado basado en la constante
        uint256 expected_fee = (50 ether * WITHDRAWAL_FEE) / (10000 - WITHDRAWAL_FEE);

        // Comprueba que el fee real coincida con el esperado
        uint256 actual_fee = IERC20(WETH).balanceOf(fee_receiver) - fee_before;
        assertEq(actual_fee, expected_fee);
    }

    /**
     * @notice Test de retiro de cantidad cero
     * @dev Comprueba que se revierta con el error esperado al retirar 0
     */
    function test_Withdraw_RevertZero() public {
        // Utiliza el address de Alice
        vm.prank(alice);

        // Espera el error y retira 0
        vm.expectRevert(StrategyVault.StrategyVault__ZeroAmount.selector);
        vault.withdraw(0, alice, alice);
    }

    /**
     * @notice Test de retiro cuando el vault está pausado
     * @dev Comprueba que se revierta al intentar retirar estando pausado
     */
    function test_Withdraw_RevertWhenPaused() public {
        // Deposita fondos primero
        _deposit(alice, 5 ether);

        // Pausa el vault
        vault.pause();

        // Espera el error de pausa al intentar retirar
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        _withdraw(alice, 1 ether);
    }

    //* Testing de redeem

    /**
     * @notice Test de redeem básico
     * @dev Comprueba que un usuario pueda redimir shares por assets
     */
    function test_Redeem_Basic() public {
        // Deposita y obtiene shares
        uint256 shares = _deposit(alice, 5 ether);

        // Usa a Alice para redimir sus shares
        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);

        // Comprueba que se quemaron las shares y se recibieron assets (menos fee)
        assertEq(vault.balanceOf(alice), 0);
        assertGt(assets, 0);
        assertLt(assets, 5 ether);
    }

    /**
     * @notice Test de redeem de cantidad cero
     * @dev Comprueba que se revierta al intentar redimir 0 shares
     */
    function test_Redeem_RevertZero() public {
        // Utiliza el address de Alice
        vm.prank(alice);

        // Espera el error y redime 0 shares
        vm.expectRevert(StrategyVault.StrategyVault__ZeroAmount.selector);
        vault.redeem(0, alice, alice);
    }

    //* Testing de allocation

    /**
     * @notice Test de allocate idle por debajo del threshold
     * @dev Comprueba que falle allocation manual si no hay suficiente idle
     */
    function test_AllocateIdle_RevertBelowThreshold() public {
        // Deposita cantidad pequeña (bajo threshold)
        _deposit(alice, 1 ether);

        // Espera error al intentar allocation manual sin llegar al mínimo
        vm.expectRevert(StrategyVault.StrategyVault__IdleBelowThreshold.selector);
        vault.allocateIdle();
    }

    //* Testing de funciones de accounting

    /**
     * @notice Test de total assets sumando idle y manager
     * @dev Comprueba que el total de assets sume correctamente ambas partes
     */
    function test_TotalAssets_IdlePlusManager() public {
        // Deposita con Alice (se queda en idle)
        _deposit(alice, 5 ether);

        // Deposita con Bob (supera threshold, ejecuta allocation)
        _deposit(bob, 10 ether);

        // Comprueba que el total sea la suma aproximada (por posibles fees/slippage)
        uint256 expected = 15 ether;
        assertApproxEqRel(vault.totalAssets(), expected, 0.001e18);
    }

    /**
     * @notice Test de max deposit respetando TVL
     * @dev Comprueba que la función devuelva el MAX_TVL
     */
    function test_MaxDeposit_RespectsMaxTVL() public view {
        // Comprueba que el máximo depósito permitido sea el TVL configurado
        assertEq(vault.maxDeposit(alice), MAX_TVL);
    }

    /**
     * @notice Test de max mint respetando TVL
     * @dev Comprueba que la función devuelva el MAX_TVL (en shares)
     */
    function test_MaxMint_RespectsMaxTVL() public view {
        // Comprueba que el máximo mint permitido sea el TVL configurado
        assertEq(vault.maxMint(alice), MAX_TVL);
    }

    //* Testing de funcionalidad only owner

    /**
     * @notice Test de permisos de administrador
     * @dev Comprueba que solo el owner pueda cambiar parámetros y otros fallen
     */
    function test_Admin_OnlyOwnerCanSetParams() public {
        // Intenta ejecutar setters como Alice (no owner)
        vm.startPrank(alice);

        // Espera reverts en todas las llamadas administrativas
        vm.expectRevert();
        vault.setIdleThreshold(20 ether);
        vm.expectRevert();
        vault.setMaxTVL(2000 ether);
        vm.expectRevert();
        vault.setMinDeposit(0.1 ether);
        vm.expectRevert();
        vault.setWithdrawalFee(300);
        vm.expectRevert();
        vault.setWithdrawalFeeReceiver(alice);
        vm.expectRevert();
        vault.pause();
        vm.stopPrank();

        // Ejecuta setters como Owner (deberían funcionar)
        vault.setIdleThreshold(20 ether);
        vault.setMaxTVL(2000 ether);
        vault.setMinDeposit(0.1 ether);
        vault.setWithdrawalFee(300);
        vault.setWithdrawalFeeReceiver(alice);
        vault.pause();
        vault.unpause();

        // Comprueba que los valores se hayan actualizado correctamente
        assertEq(vault.idle_threshold(), 20 ether);
        assertEq(vault.max_tvl(), 2000 ether);
        assertEq(vault.min_deposit(), 0.1 ether);
        assertEq(vault.withdrawal_fee(), 300);
        assertEq(vault.fee_receiver(), alice);
    }

    //* Testing de funciones preview

    /**
     * @notice Test de preview withdraw incluye fee
     * @dev Comprueba que se necesiten más shares que assets por el fee
     */
    function test_Preview_WithdrawIncludesFee() public {
        // Setup inicial
        _deposit(alice, 100 ether);

        // Comprueba que shares requeridas sean mayores a assets retirados
        uint256 shares_needed = vault.previewWithdraw(50 ether);
        assertGt(shares_needed, 50 ether);
    }

    /**
     * @notice Test de preview redeem deduce fee
     * @dev Comprueba que se reciban menos assets que shares por el fee
     */
    function test_Preview_RedeemDeductsFee() public {
        // Setup inicial y obtención de shares
        uint256 shares = _deposit(alice, 100 ether);

        // Comprueba que assets recibidos sean menores a shares quemadas
        uint256 assets_received = vault.previewRedeem(shares);
        assertLt(assets_received, 100 ether);
    }
}
