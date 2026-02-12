// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {StrategyVault} from "../../src/core/StrategyVault.sol";
import {StrategyManager} from "../../src/core/StrategyManager.sol";
import {AaveStrategy} from "../../src/strategies/AaveStrategy.sol";
import {CompoundStrategy} from "../../src/strategies/CompoundStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title FullFlowTest
 * @author cristianrisueo
 * @notice Tests de integración end-to-end para el protocolo completo
 * @dev Fork de Mainnet real - valida flujos que cruzan vault → manager → strategies → protocolos
 */
contract FullFlowTest is Test {
    //* Variables de estado

    /// @notice Instancias del protocolo: Vault, manager y estrategias
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
    uint256 constant WITHDRAWAL_FEE = 200;

    //* Setup del entorno de testing

    /**
     * @notice Configura el entorno de testing
     * @dev Fork de Mainnet con todo el protocolo desplegado y conectado
     */
    function setUp() public {
        // Crea un fork de Mainnet usando el endpoint de Alchemy
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        // Setea el fee receiver
        fee_receiver = makeAddr("feeReceiver");

        // Despliega y conecta vault y manager
        manager = new StrategyManager(WETH);
        vault = new StrategyVault(WETH, address(manager), fee_receiver);
        manager.initializeVault(address(vault));

        // Despliega estrategias con direcciones reales de Mainnet
        aave_strategy = new AaveStrategy(address(manager), WETH, AAVE_POOL);
        compound_strategy = new CompoundStrategy(address(manager), WETH, COMPOUND_COMET);

        // Conecta estrategias al manager
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
     * @param amount Cantidad a retirar
     * @return shares Cantidad de shares del usuario quemadas tras el retiro
     */
    function _withdraw(address user, uint256 amount) internal returns (uint256 shares) {
        // Utiliza el address del usuario, retira la cantidad y devuelve las shares quemadas
        vm.prank(user);
        shares = vault.withdraw(amount, user, user);
    }

    //* Tests de integración: Flujos E2E

    /**
     * @notice Test E2E: Deposit → Allocation → Withdraw
     * @dev El happy path completo de un usuario interactuando con el protocolo
     *      Valida que los fondos fluyan correctamente: usuario → vault → manager → strategias → protocolos
     *      y de vuelta al usuario al retirar
     */
    function test_E2E_DepositAllocateWithdraw() public {
        // Alice deposita 50 WETH (supera threshold, se envía directamente a las estrategias)
        uint256 deposit_amount = 50 ether;
        _deposit(alice, deposit_amount);

        // Comprueba que: Idle buffer del vault vacío, assets en las estrategias mayores que 0
        assertEq(vault.idle_weth(), 0, "Idle buffer deberia estar vacio tras allocation");
        assertGt(aave_strategy.totalAssets(), 0, "Aave deberia tener fondos");
        assertGt(compound_strategy.totalAssets(), 0, "Compound deberia tener fondos");

        // Comprueba que el total del protocolo sea aproximadamente lo depositado (tolerancia de 0.1%)
        // Recuerda que vault.totalAssets suma idle buffer + manager.totalAssets
        assertApproxEqRel(vault.totalAssets(), deposit_amount, 0.001e18, "Total assets incorrecto");

        // Alice retira 40 WETH netos (los fondos vuelven de las estrategias)
        uint256 withdraw_amount = 40 ether;
        _withdraw(alice, withdraw_amount);

        // Comprueba que Alice recibió la cantidad neta a retirar
        assertEq(IERC20(WETH).balanceOf(alice), withdraw_amount, "Alice no recibio WETH");

        // Comprueba que el fee receiver recibió algo (su balance mayor que 0)
        assertGt(IERC20(WETH).balanceOf(fee_receiver), 0, "Fee receiver deberia haber cobrado");

        // Comprueba que Alice aún tiene shares por el resto no retirado
        assertGt(vault.balanceOf(alice), 0, "Alice deberia tener shares restantes");
    }

    /**
     * @notice Test E2E: Múltiples usuarios depositando y retirando concurrentemente
     * @dev Valida que las shares y assets se calculen correctamente cuando hay varios usuarios
     *      en el vault simultáneamente. Es crucial para verificar que no hay comportamientos
     *      extraños al entrar varios usuarios
     */
    function test_E2E_MultipleUsersConcurrent() public {
        // Alice deposita 30 WETH y Bob deposita 20 WETH (total 50, supera threshold)
        uint256 alice_deposit = 30 ether;
        uint256 bob_deposit = 20 ether;

        uint256 alice_shares = _deposit(alice, alice_deposit);
        uint256 bob_shares = _deposit(bob, bob_deposit);

        // Comprueba que ambos tienen shares proporcionales a su depósito (Alice > Bob)
        assertGt(alice_shares, bob_shares, "Alice deberia tener mas shares que Bob");

        // Comprueba que el TVL del protocolo sea igual a los depósitos (tolerancia de 0.1%)
        uint256 total_deposited = alice_deposit + bob_deposit;
        assertApproxEqRel(vault.totalAssets(), total_deposited, 0.001e18, "Total incorrecto");

        // Alice retira 20 WETH y comprueba que su balance de WETH sea el correcto
        _withdraw(alice, 20 ether);
        assertEq(IERC20(WETH).balanceOf(alice), 20 ether, "Alice no recibio 20 WETH");

        // Bob retira 15 WETH y comprueba que su balance de WETH sea el correcto
        _withdraw(bob, 15 ether);
        assertEq(IERC20(WETH).balanceOf(bob), 15 ether, "Bob no recibio 15 WETH");

        // Comprueba que ambos tengan shares restantes por lo que les queda depositado
        assertGt(vault.balanceOf(alice), 0, "Alice deberia tener shares");
        assertGt(vault.balanceOf(bob), 0, "Bob deberia tener shares");
    }

    /**
     * @notice Test E2E: Deposit → Allocation → Rebalance → Withdraw
     * @dev Valida el flujo completo incluyendo rebalanceo entre estrategias
     *      Cambia el max allocation para forzar desbalance y comprobar que el rebalance
     *      mueva fondos correctamente sin perder assets
     */
    function test_E2E_DepositRebalanceWithdraw() public {
        // Alice deposita 100 WETH (supera threshold, se envía a estrategias)
        _deposit(alice, 100 ether);

        // Guarda el total antes del rebalance (100 WETH)
        uint256 total_before = vault.totalAssets();

        // Cambia el max allocation (pasa 50% al 40%) para forzar un desbalance
        manager.setMaxAllocationPerStrategy(4000);

        // Si shouldRebalance es true, ejecuta rebalance
        if (manager.shouldRebalance()) {
            manager.rebalance();
        }

        // Comprueba que tras el rebalance de assets entre estrategias no se perdieron fondos en el vault
        // de nuevo, con un margen de tolerancia de 0.1%
        assertApproxEqRel(vault.totalAssets(), total_before, 0.01e18, "Se perdieron fondos en rebalance");

        // Alice retira 80 WETH y comprueba que su balance de WETH es correcto
        _withdraw(alice, 80 ether);
        assertEq(IERC20(WETH).balanceOf(alice), 80 ether, "Alice no recibio fondos post-rebalance");
    }

    /**
     * @notice Test E2E: Deposit → Pause → Unpause → Withdraw
     * @dev Valida que el vault sigue operando correctamente tras una pausa
     *      Los fondos deben estar funcionando correctamente en las estrategias
     *      durante la pausa y ser retirables normalmente tras despausar
     */
    function test_E2E_PauseUnpauseRecovery() public {
        // Alice deposita 50 WETH (supera threshold, se envía a estrategias)
        _deposit(alice, 50 ether);

        // Guarda el total antes del rebalance (50 WETH)
        uint256 total_before_pause = vault.totalAssets();

        // Owner pausa el vault
        vault.pause();

        // Intenta depositar con Bob. Espera error, comprobando que no se puede por estar pausado
        deal(WETH, bob, 10 ether);
        vm.startPrank(bob);

        IERC20(WETH).approve(address(vault), 10 ether);

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.deposit(10 ether, bob);

        vm.stopPrank();

        // Comprueba que el vault sigue teniendo los fondos depositados por Alice en las estrategias
        assertApproxEqRel(vault.totalAssets(), total_before_pause, 0.001e18, "Fondos perdidos durante pausa");

        // Owner despausa el vault
        vault.unpause();

        // Alice retira 40 ETH y comprueba que su balance de WETH es correcto
        _withdraw(alice, 40 ether);
        assertEq(IERC20(WETH).balanceOf(alice), 40 ether, "Alice no pudo retirar post-unpause");
    }

    /**
     * @notice Test E2E: Deposit → Remove Strategy → Withdraw
     * @dev Simula migración: se elimina una estrategia y los usuarios pueden seguir retirando
     *      Este test es muy importante para comprobar que la eliminación de una estrategia no
     *      deja fondos bloqueados
     */
    function test_E2E_RemoveStrategyAndWithdraw() public {
        // Alice deposita 50 WETH (se envía directamente a las estrategias)
        _deposit(alice, 50 ether);

        // Guarda el balance de Compound antes de eliminar la estrategia
        uint256 compound_assets = compound_strategy.totalAssets();

        // Retira los fondos de Compound (usando el address del manager para hacer la llamada)
        // vm.prank -> Solo la siguiente llamada, vm.startPrank -> hasta que se haga stopPrank
        if (compound_assets > 0) {
            vm.prank(address(manager));
            compound_strategy.withdraw(compound_assets);
        }

        // Elimina la estrategia de Compound y comprueba que solo quede 1 estrategia disponible (Aave)
        manager.removeStrategy(address(compound_strategy));
        assertEq(manager.strategiesCount(), 1, "Deberia quedar 1 estrategia");

        // Guarda el balance de WETH en la estrtegia de Aave y se retira la mitad. Tras eliminar una
        // estrategia se hace un rebalance, por lo que Aave debería tener el 50% del TVL (25 WETH) máximo
        // y el otro debería estar en el balance del manager esperando una nueva estrategia
        uint256 aave_assets = aave_strategy.totalAssets();
        uint256 safe_withdraw = aave_assets / 2;

        // Alice realiza el retiro y comprueba que su balance de WETH es correcto
        _withdraw(alice, safe_withdraw);
        assertEq(IERC20(WETH).balanceOf(alice), safe_withdraw, "Alice no pudo retirar post-remove");
    }

    /**
     * @notice Test E2E: Yield accrual con paso del tiempo
     * @dev Avanza el tiempo 30 días para comprobar que los aTokens y cTokens acumulan yield real.
     *      Este test valida que el protocolo se beneficia del yield de Aave y Compound
     */
    function test_E2E_YieldAccrual() public {
        // Alice deposita 100 WETH
        _deposit(alice, 100 ether);

        // Guarda el total de assets del protocolo antes de avanzar el tiempo
        uint256 total_before = vault.totalAssets();

        // Avanza 30 días para acumular yield
        vm.warp(block.timestamp + 30 days);

        // Comprueba que el total de assets creció (yield acumulado)
        uint256 total_after = vault.totalAssets();
        assertGt(total_after, total_before, "El vault deberia haber acumulado yield");

        // Calcula el yield generado
        uint256 yield_earned = total_after - total_before;

        // Comprueba que el yield sea razonable (entre 0.01% y 5% en 30 días) si no algo raro hay
        assertGt(yield_earned, total_before / 10000, "Yield demasiado bajo");
        assertLt(yield_earned, (total_before * 5) / 100, "Yield sospechosamente alto");
    }
}
