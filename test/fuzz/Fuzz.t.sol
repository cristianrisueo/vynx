// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {StrategyVault} from "../../src/core/StrategyVault.sol";
import {StrategyManager} from "../../src/core/StrategyManager.sol";
import {AaveStrategy} from "../../src/strategies/AaveStrategy.sol";
import {CompoundStrategy} from "../../src/strategies/CompoundStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title FuzzTest
 * @author cristianrisueo
 * @notice Fuzz tests stateless para el protocolo
 * @dev Cada test recibe inputs aleatorios acotados a rangos realistas
 *      Son stateless: cada ejecución empieza de cero tras setUp()
 */
contract FuzzTest is Test {
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
    address public fee_receiver;

    /// @notice Parámetros del vault
    uint256 constant MAX_TVL = 1000 ether;
    uint256 constant MIN_DEPOSIT = 0.01 ether;
    uint256 constant WITHDRAWAL_FEE = 200;

    //* Setup del entorno de testing

    /**
     * @notice Configura el entorno de testing
     * @dev Fork de Mainnet con protocolo completo desplegado
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
     * @notice Helper de depósito
     * @param user Usuario que deposita
     * @param amount Cantidad a depositar
     * @return shares Shares minteadas
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

    //* Fuzz tests stateless

    /**
     * @notice Fuzz: Para cualquier amount válido, deposit genera shares > 0 y totalAssets crece
     * @dev Acota amount entre MIN_DEPOSIT y MAX_TVL para evitar reverts por validación
     * @param amount Cantidad aleatoria generada por el fuzzer
     */
    function testFuzz_Deposit_GeneratesShares(uint256 amount) public {
        // Acota el input al rango válido del vault
        amount = bound(amount, MIN_DEPOSIT, MAX_TVL);

        // Guarda totalAssets antes del depósito
        uint256 total_before = vault.totalAssets();

        // Deposita y comprueba que se generaron shares
        uint256 shares = _deposit(alice, amount);
        assertGt(shares, 0, "Deposit deberia generar shares > 0");

        // Comprueba que totalAssets creció (tolerancia 0.1% por fees de protocolos)
        assertApproxEqRel(vault.totalAssets(), total_before + amount, 0.001e18, "TotalAssets no crecio");
    }

    /**
     * @notice Fuzz: Para cualquier withdraw, el usuario no extrae más de lo depositado
     * @dev Deposita amount, luego retira un porcentaje aleatorio, siempre <= depositado
     * @param amount Cantidad aleatoria depositada
     * @param withdraw_pct Porcentaje aleatorio a retirar (1-90%) de lo depositado
     */
    function testFuzz_Withdraw_NeverExceedsDeposit(uint256 amount, uint256 withdraw_pct) public {
        // Acota inputs: amount válido, withdraw entre 1% y 90% del depósito
        amount = bound(amount, MIN_DEPOSIT, MAX_TVL);
        withdraw_pct = bound(withdraw_pct, 1, 90);

        // Deposita
        _deposit(alice, amount);

        // Calcula la cantidad neta a retirar (porcentaje del depósito)
        uint256 withdraw_amount = (amount * withdraw_pct) / 100;
        if (withdraw_amount == 0) return;

        // Retira
        vm.prank(alice);
        vault.withdraw(withdraw_amount, alice, alice);

        // Comprueba que lo recibido no exceda lo depositado
        // Este test me parece un poco trucado (un 90% máximo deja un buffer muy alto, y si recibe un 91%?)
        assertLe(IERC20(WETH).balanceOf(alice), amount, "Usuario recibio mas de lo depositado");
    }

    /**
     * @notice Fuzz: Para cualquier withdraw > 0, el fee receiver siempre cobra
     * @dev El fee es el 2% del valor bruto. Para cualquier retiro válido, fee > 0
     * @param amount Cantidad aleatoria depositada
     */
    function testFuzz_Withdraw_FeeAlwaysCollected(uint256 amount) public {
        // Acota al rango válido. Necesitamos suficiente para que el fee no sea 0 por redondeo
        amount = bound(amount, 1 ether, MAX_TVL);

        // Deposita
        _deposit(alice, amount);

        // Guarda balance del fee receiver antes del retiro (0)
        uint256 fee_before = IERC20(WETH).balanceOf(fee_receiver);

        // Retira el 50% del depósito (suficiente para generar fee medible)
        uint256 withdraw_amount = amount / 2;
        vm.prank(alice);
        vault.withdraw(withdraw_amount, alice, alice);

        // Comprueba que el fee receiver cobró algo
        uint256 fee_after = IERC20(WETH).balanceOf(fee_receiver);
        assertGt(fee_after, fee_before, "Fee receiver deberia haber cobrado");
    }

    /**
     * @notice Fuzz: Redeem quema exactamente las shares indicadas
     * @dev Para cualquier cantidad de shares redimidas, el balance de shares decrece exactamente esa cantidad
     * @param amount Cantidad aleatoria depositada
     * @param redeem_pct Porcentaje aleatorio de shares a redimir
     */
    function testFuzz_Redeem_BurnsExactShares(uint256 amount, uint256 redeem_pct) public {
        // Acota inputs
        amount = bound(amount, MIN_DEPOSIT, MAX_TVL);
        redeem_pct = bound(redeem_pct, 1, 100);

        // Deposita y obtiene shares
        uint256 shares = _deposit(alice, amount);

        // Calcula shares a redimir (entre un 1% y un 100%)
        uint256 shares_to_redeem = (shares * redeem_pct) / 100;
        if (shares_to_redeem == 0) return;

        // Guarda balance de shares antes
        uint256 shares_before = vault.balanceOf(alice);

        // Redime las shares calculadas
        vm.prank(alice);
        vault.redeem(shares_to_redeem, alice, alice);

        // Comprueba que se quemaron exactamente las shares indicadas
        uint256 shares_after = vault.balanceOf(alice);
        assertEq(shares_before - shares_after, shares_to_redeem, "No se quemaron las shares exactas");
    }

    /**
     * @notice Fuzz: Deposit → Redeem inmediato nunca genera profit
     * @dev Un usuario no puede ganar depositando y retirando inmediatamente (el fee lo impide)
     *      Para cualquier amount, assets_out < amount
     * @param amount Cantidad aleatoria depositada
     */
    function testFuzz_DepositRedeem_NeverProfitable(uint256 amount) public {
        // Acota al rango válido del protocolo
        amount = bound(amount, MIN_DEPOSIT, MAX_TVL);

        // Deposita y redime todo inmediatamente
        uint256 shares = _deposit(alice, amount);

        vm.prank(alice);
        uint256 assets_out = vault.redeem(shares, alice, alice);

        // Lo recibido siempre es menor que lo depositado (porque cobramos la fee del 2%)
        assertLt(assets_out, amount, "Deposit-redeem no deberia ser profitable");
    }
}
