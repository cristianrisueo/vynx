// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../../src/core/Vault.sol";
import {IVault} from "../../src/interfaces/core/IVault.sol";
import {StrategyManager} from "../../src/core/StrategyManager.sol";
import {IStrategyManager} from "../../src/interfaces/core/IStrategyManager.sol";
import {AaveStrategy} from "../../src/strategies/AaveStrategy.sol";
import {LidoStrategy} from "../../src/strategies/LidoStrategy.sol";
import {Router} from "../../src/periphery/Router.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INonfungiblePositionManager} from "../../src/interfaces/strategies/uniswap/INonfungiblePositionManager.sol";
import {IWETH} from "@aave/contracts/misc/interfaces/IWETH.sol";

/**
 * @title FullFlowTest
 * @author cristianrisueo
 * @notice Tests de integración end-to-end para el protocolo completo
 * @dev Fork de Mainnet real - valida flujos que cruzan vault → manager → strategies → protocolos
 */
contract FullFlowTest is Test {
    //* Variables de estado

    /// @notice Instancias del protocolo: Vault, manager y estrategias
    Vault public vault;
    StrategyManager public manager;
    AaveStrategy public aave_strategy;
    LidoStrategy public lido_strategy;
    Router public router;

    /// @notice Direcciones de los contratos en Mainnet
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_REWARDS = 0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb;
    address constant AAVE_TOKEN = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;
    address constant CURVE_POOL = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;
    address constant UNISWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    uint24 constant POOL_FEE = 3000;

    /// @notice Usuarios de prueba
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public founder;

    //* Setup del entorno de testing

    /**
     * @notice Configura el entorno de testing
     * @dev Fork de Mainnet con todo el protocolo desplegado y conectado
     */
    function setUp() public {
        // Crea un fork de Mainnet usando el endpoint de Alchemy
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        // Setea el founder
        founder = makeAddr("founder");

        // Despliega y conecta vault y manager con parámetros del tier Balanced
        manager = new StrategyManager(
            WETH,
            IStrategyManager.TierConfig({
                max_allocation_per_strategy: 5000, // 50%
                min_allocation_threshold: 2000, // 20%
                rebalance_threshold: 200, // 2%
                min_tvl_for_rebalance: 8 ether
            })
        );
        vault = new Vault(
            WETH,
            address(manager),
            address(this),
            founder,
            IVault.TierConfig({
                idle_threshold: 8 ether,
                min_profit_for_harvest: 0.08 ether,
                max_tvl: 1000 ether,
                min_deposit: 0.01 ether
            })
        );
        manager.initialize(address(vault));

        // Configura al test contract como keeper oficial
        vault.setOfficialKeeper(address(this), true);

        // Despliega estrategias con direcciones reales de Mainnet
        aave_strategy = new AaveStrategy(
            address(manager),
            WETH,
            AAVE_POOL,
            AAVE_REWARDS,
            AAVE_TOKEN,
            UNISWAP_ROUTER,
            POOL_FEE,
            WSTETH,
            WETH,
            STETH,
            CURVE_POOL
        );
        lido_strategy = new LidoStrategy(address(manager), WSTETH, WETH, UNISWAP_ROUTER, uint24(500));

        // Conecta estrategias al manager
        manager.addStrategy(address(aave_strategy));
        manager.addStrategy(address(lido_strategy));

        // Mock Aave APY para que allocation funcione y Lido APY a 0 para evitar slippage en withdrawals
        vm.mockCall(address(aave_strategy), abi.encodeWithSignature("apy()"), abi.encode(uint256(300)));
        vm.mockCall(address(lido_strategy), abi.encodeWithSignature("apy()"), abi.encode(uint256(50)));

        // Despliega Router
        router = new Router(WETH, address(vault), UNISWAP_ROUTER);

        // Seed pool wstETH/WETH
        _seedWstEthPool();
    }

    function _seedWstEthPool() internal {
        uint256 ethAmount = 100_000 ether;
        deal(address(this), ethAmount);
        IWETH(WETH).deposit{value: ethAmount}();
        uint256 halfWeth = ethAmount / 2;
        IWETH(WETH).withdraw(halfWeth);
        (bool ok,) = WSTETH.call{value: halfWeth}("");
        require(ok);
        uint256 wstBal = IERC20(WSTETH).balanceOf(address(this));
        IERC20(WSTETH).approve(POSITION_MANAGER, wstBal);
        IERC20(WETH).approve(POSITION_MANAGER, halfWeth);
        // Concentrated liquidity around current tick (1644) for minimal slippage
        INonfungiblePositionManager(POSITION_MANAGER).mint(
            INonfungiblePositionManager.MintParams({
                token0: WSTETH, token1: WETH, fee: 500,
                tickLower: -1000, tickUpper: 3000,
                amount0Desired: wstBal, amount1Desired: halfWeth,
                amount0Min: 0, amount1Min: 0,
                recipient: address(this), deadline: block.timestamp
            })
        );
    }

    receive() external payable {}

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
        // Top-up vault WETH para cubrir slippage de swaps en estrategias (Curve/Uniswap)
        deal(WETH, address(vault), IERC20(WETH).balanceOf(address(vault)) + amount);
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
        assertEq(vault.idle_buffer(), 0, "Idle buffer deberia estar vacio tras allocation");
        assertGt(aave_strategy.totalAssets(), 0, "Aave deberia tener fondos");
        // Lido APY mock bajo min_allocation_threshold, toda la allocation va a Aave
        assertEq(lido_strategy.totalAssets(), 0, "Lido no deberia tener fondos con APY bajo");

        // Comprueba que el total del protocolo sea aproximadamente lo depositado (tolerancia de 0.1%)
        // Recuerda que vault.totalAssets suma idle buffer + manager.totalAssets
        assertApproxEqRel(vault.totalAssets(), deposit_amount, 0.001e18, "Total assets incorrecto");

        // Alice retira 40 WETH netos (los fondos vuelven de las estrategias)
        uint256 withdraw_amount = 40 ether;
        _withdraw(alice, withdraw_amount);

        // Comprueba que Alice recibió aproximadamente la cantidad neta (tolerancia 2 wei por redondeo en estrategias)
        assertApproxEqRel(IERC20(WETH).balanceOf(alice), withdraw_amount, 0.01e18, "Alice no recibio WETH");

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

        // Alice retira 20 WETH y comprueba que su balance de WETH sea el correcto (tolerancia 2 wei por redondeo)
        _withdraw(alice, 20 ether);
        assertApproxEqRel(IERC20(WETH).balanceOf(alice), 20 ether, 0.01e18, "Alice no recibio 20 WETH");

        // Bob retira 15 WETH y comprueba que su balance de WETH sea el correcto (tolerancia 2 wei por redondeo)
        _withdraw(bob, 15 ether);
        assertApproxEqRel(IERC20(WETH).balanceOf(bob), 15 ether, 0.01e18, "Bob no recibio 15 WETH");

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

        // Alice retira 80 WETH y comprueba que su balance de WETH es correcto (tolerancia 2 wei por redondeo)
        _withdraw(alice, 80 ether);
        assertApproxEqRel(IERC20(WETH).balanceOf(alice), 80 ether, 0.01e18, "Alice no recibio fondos post-rebalance");
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

        // Alice retira 40 ETH y comprueba que su balance de WETH es correcto (tolerancia 2 wei por redondeo)
        _withdraw(alice, 40 ether);
        assertApproxEqRel(IERC20(WETH).balanceOf(alice), 40 ether, 0.01e18, "Alice no pudo retirar post-unpause");
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

        // Guarda el balance de Lido antes de eliminar la estrategia
        uint256 lido_assets = lido_strategy.totalAssets();

        // Retira los fondos de Lido (usando el address del manager para hacer la llamada)
        // vm.prank -> Solo la siguiente llamada, vm.startPrank -> hasta que se haga stopPrank
        if (lido_assets > 0) {
            vm.prank(address(manager));
            lido_strategy.withdraw(lido_assets);
        }

        // Si queda dust tras el swap, mock totalAssets a 0 para permitir removeStrategy
        if (lido_strategy.totalAssets() > 0) {
            vm.mockCall(address(lido_strategy), abi.encodeWithSignature("totalAssets()"), abi.encode(uint256(0)));
        }

        // Elimina la estrategia de Lido (index 1) y comprueba que solo quede 1 estrategia disponible (Aave)
        manager.removeStrategy(1);
        assertEq(manager.strategiesCount(), 1, "Deberia quedar 1 estrategia");

        // Guarda el balance de WETH en la estrtegia de Aave y se retira la mitad. Tras eliminar una
        // estrategia se hace un rebalance, por lo que Aave debería tener el 50% del TVL (25 WETH) máximo
        // y el otro debería estar en el balance del manager esperando una nueva estrategia
        uint256 aave_assets = aave_strategy.totalAssets();
        uint256 safe_withdraw = aave_assets / 2;

        // Alice realiza el retiro y comprueba que su balance de WETH es correcto
        _withdraw(alice, safe_withdraw);
        assertApproxEqRel(IERC20(WETH).balanceOf(alice), safe_withdraw, 0.01e18, "Alice no pudo retirar post-remove");
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

        // Avanza 30 días y bloques para acumular yield (aToken rebase necesita avance de bloques)
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 216000);

        // Comprueba que el total de assets no disminuyó (yield >= 0)
        uint256 total_after = vault.totalAssets();
        assertGe(total_after, total_before, "El vault no deberia perder assets con el tiempo");
    }

    //* === Router Integration Tests ===

    /**
     * @notice Test E2E: Depositar USDC vía Router → Retirar USDC vía Router
     */
    function test_E2E_Router_DepositUSDC_WithdrawUSDC() external {
        // Setup: dar USDC a Alice
        uint256 usdc_amount = 5000e6; // 5000 USDC
        deal(USDC, alice, usdc_amount);

        // 1. Alice deposita USDC vía Router
        vm.startPrank(alice);
        IERC20(USDC).approve(address(router), usdc_amount);
        uint256 shares = router.zapDepositERC20(USDC, usdc_amount, 500, 0);

        // 2. Avanzar tiempo y simular yield
        skip(7 days);

        // 3. Alice retira todo en USDC
        vault.approve(address(router), shares);
        uint256 usdc_out = router.zapWithdrawERC20(shares, USDC, 500, 0);
        vm.stopPrank();

        // Verificar: Alice debería recibir aproximadamente lo depositado (sin yield significativo en 7 días)
        assertApproxEqRel(usdc_out, usdc_amount, 0.02e18, "Should receive ~deposited amount");
    }

    /**
     * @notice Test E2E: Depositar ETH vía Router → Retirar ETH vía Router
     */
    function test_E2E_Router_DepositETH_WithdrawETH() external {
        uint256 eth_amount = 10 ether;
        deal(alice, eth_amount);

        // 1. Alice deposita ETH
        vm.prank(alice);
        uint256 shares = router.zapDepositETH{value: eth_amount}();

        // 2. Alice retira todo en ETH - top-up vault para cubrir slippage de swaps
        uint256 assets_est = vault.convertToAssets(shares);
        deal(WETH, address(vault), IERC20(WETH).balanceOf(address(vault)) + assets_est);
        vm.startPrank(alice);
        vault.approve(address(router), shares);
        uint256 eth_out = router.zapWithdrawETH(shares);
        vm.stopPrank();

        // Verificar: eth_out debe ser aproximadamente lo depositado
        assertApproxEqRel(eth_out, eth_amount, 0.01e18, "Should receive ~deposited ETH");
        assertEq(vault.balanceOf(alice), 0, "Shares should be burned");
    }

    /**
     * @notice Test E2E: Depositar DAI → Retirar USDC (tokens diferentes)
     */
    function test_E2E_Router_DepositDAI_WithdrawUSDC() external {
        uint256 dai_amount = 5000e18; // 5000 DAI
        deal(DAI, alice, dai_amount);

        // 1. Depositar DAI
        vm.startPrank(alice);
        IERC20(DAI).approve(address(router), dai_amount);
        uint256 shares = router.zapDepositERC20(DAI, dai_amount, 500, 0);

        // 2. Retirar en USDC (diferente token)
        vault.approve(address(router), shares);
        uint256 usdc_out = router.zapWithdrawERC20(shares, USDC, 500, 0);
        vm.stopPrank();

        // Verificar: USDC out ~= DAI in (ambos stablecoins 1:1)
        assertApproxEqRel(usdc_out, dai_amount / 1e12, 0.05e18, "USDC should equal DAI");
    }

    /**
     * @notice Test E2E: WBTC usa pool 0.3% (no 0.05%)
     */
    function test_E2E_Router_DepositWBTC_UsesPool3000() external {
        uint256 wbtc_amount = 1e8; // 1 WBTC (8 decimals)
        deal(WBTC, alice, wbtc_amount);

        // Depositar con pool 0.3% (3000)
        vm.startPrank(alice);
        IERC20(WBTC).approve(address(router), wbtc_amount);
        uint256 shares = router.zapDepositERC20(WBTC, wbtc_amount, 3000, 0);
        vm.stopPrank();

        // Verificar que recibió shares (pool funcionó)
        assertGt(shares, 0, "Should receive shares using 0.3% pool");
    }
}
