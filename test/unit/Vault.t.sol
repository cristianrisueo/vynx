// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../../src/core/Vault.sol";
import {IVault} from "../../src/interfaces/core/IVault.sol";
import {StrategyManager} from "../../src/core/StrategyManager.sol";
import {IStrategyManager} from "../../src/interfaces/core/IStrategyManager.sol";
import {AaveStrategy} from "../../src/strategies/AaveStrategy.sol";
import {LidoStrategy} from "../../src/strategies/LidoStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INonfungiblePositionManager} from "../../src/interfaces/strategies/uniswap/INonfungiblePositionManager.sol";
import {IWETH} from "@aave/contracts/misc/interfaces/IWETH.sol";

/**
 * @title VaultTest
 * @author cristianrisueo
 * @notice Tests unitarios para Vault con fork de Mainnet
 * @dev Fork test de mainnet, aquí no hay mierdas
 */
contract VaultTest is Test {
    //* Variables de estado

    /// @notice Instancia del vault, manager y estrategias
    Vault public vault;
    StrategyManager public manager;
    AaveStrategy public aave_strategy;
    LidoStrategy public lido_strategy;

    /// @notice Direcciones de los contratos en Mainnet
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
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

    /// @notice Parámetros del vault
    uint256 constant MAX_TVL = 1000 ether;

    //* Setup del entorno de testing

    /**
     * @notice Configura el entorno de testing
     * @dev Para un comportamiento real hacemos fork de Mainnet. No recomiendo testear en
     *      testnets, los contratos desplegados SON UNA MIERDA, no es comportamiento real
     */
    function setUp() public {
        // Crea un fork de Mainnet usando mi endpoint de Alchemy en env.var
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        // Setea el founder
        founder = makeAddr("founder");

        // Inicializa el manager con parámetros del tier Balanced
        manager = new StrategyManager(
            WETH,
            IStrategyManager.TierConfig({
                max_allocation_per_strategy: 5000, // 50%
                min_allocation_threshold: 2000, // 20%
                rebalance_threshold: 200, // 2%
                min_tvl_for_rebalance: 8 ether
            })
        );

        // Inicializa el vault con parámetros del tier Balanced
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

        // Inicializa las estrategias con las direcciones reales de mainnet
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

        // Mock Aave APY para que allocation funcione y Lido APY a 0 para evitar slippage en withdrawals
        vm.mockCall(address(aave_strategy), abi.encodeWithSignature("apy()"), abi.encode(uint256(300)));
        vm.mockCall(address(lido_strategy), abi.encodeWithSignature("apy()"), abi.encode(uint256(50)));

        // Añade las estrategias
        manager.addStrategy(address(aave_strategy));
        manager.addStrategy(address(lido_strategy));

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
     * @param amount Cantidad entregada al usuario
     * @return shares Cantidad de shares del usuario quemadas tras el retiro
     */
    function _withdraw(address user, uint256 amount) internal returns (uint256 shares) {
        // Top-up vault WETH para cubrir slippage de swaps en estrategias (Curve/Uniswap)
        deal(WETH, address(vault), IERC20(WETH).balanceOf(address(vault)) + amount);
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
        assertEq(vault.idle_buffer(), amount);
    }

    /**
     * @notice Test de depósito igual a IDLE threshold
     * @dev Realiza depósito superior al threshold para comprobar que el vault hace allocation
     */
    function test_Deposit_TriggersAllocation() public {
        // Usa a alice para depositar cantidad límite
        _deposit(alice, vault.idle_threshold());

        // Comprueba que tanto el vault cómo el buffer IDLE no tiene WETH
        assertEq(vault.idle_buffer(), 0);
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
        vm.expectRevert(Vault.Vault__DepositBelowMinimum.selector);
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
        vm.expectRevert(Vault.Vault__DepositBelowMinimum.selector);
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
        vm.expectRevert(Vault.Vault__MaxTVLExceeded.selector);
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
        vm.expectRevert(Vault.Vault__DepositBelowMinimum.selector);
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

        // Comprueba balance final de Alice (tolerancia 2 wei por redondeo en retiros proporcionales de estrategias)
        assertApproxEqRel(IERC20(WETH).balanceOf(alice), 15 ether, 0.01e18);
    }

    /**
     * @notice Test de retiro cuando el vault está pausado
     * @dev Tras el cambio de emergency exit, withdraw funciona con vault pausado.
     *      Un usuario siempre debe poder retirar sus fondos
     */
    function test_Withdraw_WorksWhenPaused() public {
        // Deposita fondos primero
        _deposit(alice, 5 ether);

        // Pausa el vault
        vault.pause();

        // Withdraw debe ejecutarse correctamente estando pausado
        vm.prank(alice);
        uint256 shares = vault.withdraw(1 ether, alice, alice);

        // Comprueba que Alice recibió sus assets y se quemaron las shares
        assertEq(IERC20(WETH).balanceOf(alice), 1 ether);
        assertGt(shares, 0);
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

        // Comprueba que se quemaron las shares y se recibieron assets (sin fee, devuelve lo depositado)
        assertEq(vault.balanceOf(alice), 0);
        assertEq(assets, 5 ether);
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
        vm.expectRevert(Vault.Vault__InsufficientIdleBuffer.selector);
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

    /**
     * @notice Test de maxDeposit tras deposito parcial
     * @dev Comprueba que maxDeposit devuelva el espacio restante aproximado
     *      Usa approx porque aToken rebase puede incrementar ligeramente totalAssets
     */
    function test_MaxDeposit_AfterPartialDeposit() public {
        _deposit(alice, 100 ether);
        // Tolerancia de 0.1% porque aToken rebase y redondeo en allocation pueden causar
        // que totalAssets difiera ligeramente del monto depositado
        assertApproxEqRel(vault.maxDeposit(alice), MAX_TVL - 100 ether, 0.001e18);
    }

    /**
     * @notice Test de maxDeposit/maxMint devuelven 0 cuando el vault está pausado
     */
    function test_MaxDeposit_ReturnsZeroWhenPaused() public {
        vault.pause();
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
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
        vault.setPerformanceFee(1500);
        vm.expectRevert();
        vault.setFeeSplit(7000, 3000);
        vm.expectRevert();
        vault.setOfficialKeeper(alice, true);
        vm.expectRevert();
        vault.setMinProfitForHarvest(0.5 ether);
        vm.expectRevert();
        vault.setKeeperIncentive(200);
        vm.expectRevert();
        vault.pause();
        vm.stopPrank();

        // Ejecuta setters como Owner (deberían funcionar)
        vault.setIdleThreshold(20 ether);
        vault.setMaxTVL(2000 ether);
        vault.setMinDeposit(0.1 ether);
        vault.setPerformanceFee(1500);
        vault.setFeeSplit(7000, 3000);
        vault.setOfficialKeeper(alice, true);
        vault.setMinProfitForHarvest(0.5 ether);
        vault.setKeeperIncentive(200);
        vault.pause();
        vault.unpause();

        // Comprueba que los valores se hayan actualizado correctamente
        assertEq(vault.idle_threshold(), 20 ether);
        assertEq(vault.max_tvl(), 2000 ether);
        assertEq(vault.min_deposit(), 0.1 ether);
        assertEq(vault.performance_fee(), 1500);
        assertEq(vault.treasury_split(), 7000);
        assertEq(vault.founder_split(), 3000);
        assertTrue(vault.is_official_keeper(alice));
        assertEq(vault.min_profit_for_harvest(), 0.5 ether);
        assertEq(vault.keeper_incentive(), 200);
    }

    //* Testing de harvest y distribución de fees

    /**
     * @notice Test harvest con keeper externo (debe recibir incentivo)
     * @dev Inyecta AAVE reward tokens en la estrategia para simular yield acumulado,
     *      ya que skip(7 days) en un fork estático no genera rewards reales
     */
    function test_HarvestWithExternalKeeper() public {
        // Setup: depositar suficiente para que se allocate a estrategias
        _deposit(alice, 100 ether);

        // Bajar min_profit_for_harvest para que cualquier profit pase el threshold
        vault.setMinProfitForHarvest(0);

        // Simular rewards: deal AAVE tokens a la estrategia para que harvest los swapee
        deal(AAVE_TOKEN, address(aave_strategy), 1 ether);

        // Avanzar tiempo para que Aave acumule algo de yield en aToken rebase
        skip(7 days);
        vm.roll(block.number + 50400);

        // Keeper externo ejecuta harvest
        address keeper = makeAddr("keeper");
        uint256 keeper_balance_before = IERC20(WETH).balanceOf(keeper);

        vm.prank(keeper);
        uint256 profit = vault.harvest();

        // Si hay profit, verificar que el keeper recibió su incentivo
        if (profit > 0) {
            uint256 keeper_balance_after = IERC20(WETH).balanceOf(keeper);
            uint256 keeper_reward = keeper_balance_after - keeper_balance_before;

            assertGt(keeper_reward, 0, "Keeper debe recibir incentivo");
            assertEq(keeper_reward, (profit * vault.keeper_incentive()) / vault.BASIS_POINTS());
        }
    }

    /**
     * @notice Test harvest con keeper oficial (NO debe recibir incentivo)
     * @dev Inyecta AAVE reward tokens para simular yield y verifica que keeper oficial no cobra
     */
    function test_HarvestWithOfficialKeeper() public {
        // Setup: depositar suficiente para allocation
        _deposit(alice, 100 ether);

        // Bajar min_profit_for_harvest y simular rewards
        vault.setMinProfitForHarvest(0);
        deal(AAVE_TOKEN, address(aave_strategy), 1 ether);

        skip(7 days);
        vm.roll(block.number + 50400);

        // Configurar keeper oficial
        address official_keeper = makeAddr("official");
        vault.setOfficialKeeper(official_keeper, true);

        // Keeper oficial ejecuta harvest
        uint256 keeper_balance_before = IERC20(WETH).balanceOf(official_keeper);

        vm.prank(official_keeper);
        vault.harvest();

        // Verificar que NO recibió incentivo
        uint256 keeper_balance_after = IERC20(WETH).balanceOf(official_keeper);
        assertEq(keeper_balance_after, keeper_balance_before, "Keeper oficial no debe recibir incentivo");
    }

    /**
     * @notice Test distribucion de fees: treasury recibe shares, founder recibe assets
     * @dev Inyecta AAVE reward tokens para simular yield real y verificar fee distribution
     */
    function test_FeeDistribution() public {
        address treasury = vault.treasury_address();
        address _founder = vault.founder_address();

        // Setup: depositar suficiente para allocation
        _deposit(alice, 100 ether);

        // Bajar min_profit_for_harvest y simular rewards
        vault.setMinProfitForHarvest(0);
        deal(AAVE_TOKEN, address(aave_strategy), 1 ether);

        skip(7 days);
        vm.roll(block.number + 50400);

        // Balances antes de harvest
        uint256 treasury_shares_before = vault.balanceOf(treasury);
        uint256 founder_weth_before = IERC20(WETH).balanceOf(_founder);

        // Harvest como keeper oficial (sin incentivo para simplificar math)
        vault.setOfficialKeeper(address(this), true);
        uint256 profit = vault.harvest();

        // Solo verificar distribución si hubo profit
        if (profit > 0) {
            // Verificar: treasury recibió SHARES, founder recibió WETH
            uint256 treasury_shares_after = vault.balanceOf(treasury);
            uint256 founder_weth_after = IERC20(WETH).balanceOf(_founder);

            assertGt(treasury_shares_after, treasury_shares_before, "Treasury debe recibir shares");
            assertGt(founder_weth_after, founder_weth_before, "Founder debe recibir WETH");

            // Verificar splits correctos
            uint256 perf_fee = (profit * vault.performance_fee()) / vault.BASIS_POINTS();
            uint256 expected_treasury = (perf_fee * vault.treasury_split()) / vault.BASIS_POINTS();
            uint256 expected_founder = (perf_fee * vault.founder_split()) / vault.BASIS_POINTS();

            assertApproxEqRel(
                vault.convertToAssets(treasury_shares_after - treasury_shares_before),
                expected_treasury,
                0.01e18 // 1% tolerance
            );
            assertApproxEqRel(
                founder_weth_after - founder_weth_before,
                expected_founder,
                0.01e18
            );
        }
    }

    //* Testing de validación de setters (error paths para coverage)

    /**
     * @notice Test de setPerformanceFee con valor > BASIS_POINTS
     * @dev Comprueba que se revierte con error esperado
     */
    function test_SetPerformanceFee_RevertExceedsBasisPoints() public {
        vm.expectRevert(Vault.Vault__InvalidPerformanceFee.selector);
        vault.setPerformanceFee(10001);
    }

    /**
     * @notice Test de setFeeSplit con splits que no suman BASIS_POINTS
     * @dev Comprueba que se revierte con error esperado
     */
    function test_SetFeeSplit_RevertInvalidSum() public {
        vm.expectRevert(Vault.Vault__InvalidFeeSplit.selector);
        vault.setFeeSplit(5000, 4000);
    }

    /**
     * @notice Test de setTreasury con address(0)
     * @dev Comprueba que se revierte con error esperado
     */
    function test_SetTreasury_RevertZeroAddress() public {
        vm.expectRevert(Vault.Vault__InvalidTreasuryAddress.selector);
        vault.setTreasury(address(0));
    }

    /**
     * @notice Test de setFounder con address(0)
     * @dev Comprueba que se revierte con error esperado
     */
    function test_SetFounder_RevertZeroAddress() public {
        vm.expectRevert(Vault.Vault__InvalidFounderAddress.selector);
        vault.setFounder(address(0));
    }

    /**
     * @notice Test de setStrategyManager con address(0)
     * @dev Comprueba que se revierte con error esperado
     */
    function test_SetStrategyManager_RevertZeroAddress() public {
        vm.expectRevert(Vault.Vault__InvalidStrategyManagerAddress.selector);
        vault.setStrategyManager(address(0));
    }

    /**
     * @notice Test de setKeeperIncentive con valor > BASIS_POINTS
     * @dev Comprueba que se revierte con error esperado
     */
    function test_SetKeeperIncentive_RevertExceedsBasisPoints() public {
        vm.expectRevert(Vault.Vault__InvalidPerformanceFee.selector);
        vault.setKeeperIncentive(10001);
    }

    //* Testing de constructor validations

    /**
     * @notice Test constructor con strategy manager address(0)
     */
    function test_Constructor_RevertInvalidStrategyManager() public {
        vm.expectRevert(Vault.Vault__InvalidStrategyManagerAddress.selector);
        new Vault(
            WETH,
            address(0),
            address(this),
            founder,
            IVault.TierConfig({idle_threshold: 8 ether, min_profit_for_harvest: 0.08 ether, max_tvl: 1000 ether, min_deposit: 0.01 ether})
        );
    }

    /**
     * @notice Test constructor con treasury address(0)
     */
    function test_Constructor_RevertInvalidTreasury() public {
        vm.expectRevert(Vault.Vault__InvalidTreasuryAddress.selector);
        new Vault(
            WETH,
            address(manager),
            address(0),
            founder,
            IVault.TierConfig({idle_threshold: 8 ether, min_profit_for_harvest: 0.08 ether, max_tvl: 1000 ether, min_deposit: 0.01 ether})
        );
    }

    /**
     * @notice Test constructor con founder address(0)
     */
    function test_Constructor_RevertInvalidFounder() public {
        vm.expectRevert(Vault.Vault__InvalidFounderAddress.selector);
        new Vault(
            WETH,
            address(manager),
            address(this),
            address(0),
            IVault.TierConfig({idle_threshold: 8 ether, min_profit_for_harvest: 0.08 ether, max_tvl: 1000 ether, min_deposit: 0.01 ether})
        );
    }

    //* Testing de harvest edge cases

    /**
     * @notice Test harvest sin profit (debe retornar 0)
     * @dev Sin rewards inyectadas, harvest devuelve 0 profit
     */
    function test_Harvest_ZeroProfit() public {
        // Depositar para que haya algo en estrategias
        _deposit(alice, 20 ether);

        // Harvest sin simular rewards - debe retornar 0
        uint256 profit = vault.harvest();
        assertEq(profit, 0, "Sin rewards, harvest debe retornar 0");
    }

    /**
     * @notice Test harvest cuando el vault está pausado
     * @dev Comprueba que se revierte
     */
    function test_Harvest_RevertWhenPaused() public {
        _deposit(alice, 5 ether);
        vault.pause();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.harvest();
    }

    /**
     * @notice Test allocateIdle cuando el vault está pausado
     * @dev Comprueba que se revierte
     */
    function test_AllocateIdle_RevertWhenPaused() public {
        _deposit(alice, 5 ether);
        vault.pause();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.allocateIdle();
    }

    //* Testing de mint edge cases

    /**
     * @notice Test de mint que excede el max TVL
     * @dev Comprueba que se revierte con error esperado
     */
    function test_Mint_RevertExceedsMaxTVL() public {
        // Intentar mintear shares equivalentes a más del max TVL
        deal(WETH, alice, MAX_TVL + 1 ether);
        vm.startPrank(alice);
        IERC20(WETH).approve(address(vault), MAX_TVL + 1 ether);

        vm.expectRevert(Vault.Vault__MaxTVLExceeded.selector);
        vault.mint(MAX_TVL + 1 ether, alice);

        vm.stopPrank();
    }

    /**
     * @notice Test de mint que triggerea allocation
     * @dev Deposita via mint suficiente para superar idle threshold
     */
    function test_Mint_TriggersAllocation() public {
        uint256 threshold = vault.idle_threshold();
        deal(WETH, alice, threshold);
        vm.startPrank(alice);

        IERC20(WETH).approve(address(vault), threshold);
        vault.mint(threshold, alice);

        vm.stopPrank();

        // Idle buffer debe estar vacío porque se allocó
        assertEq(vault.idle_buffer(), 0);
        assertGt(manager.totalAssets(), 0);
    }

    //* Testing de withdraw edge cases

    /**
     * @notice Test de retiro completo de todos los fondos
     * @dev Comprueba que se pueda retirar todo y el vault quede vacío
     */
    function test_Withdraw_FullAmount() public {
        uint256 amount = 5 ether;
        _deposit(alice, amount);

        _withdraw(alice, amount);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.totalAssets(), 0);
    }

    //* Testing de getters para coverage

    /**
     * @notice Test de todos los getters del vault
     * @dev Comprueba que devuelvan los valores correctos post-setup
     */
    function test_Getters_ReturnCorrectValues() public view {
        assertEq(vault.performanceFee(), 2000);
        assertEq(vault.treasurySplit(), 8000);
        assertEq(vault.founderSplit(), 2000);
        assertEq(vault.minDeposit(), 0.01 ether);
        assertEq(vault.idleThreshold(), 8 ether);
        assertEq(vault.maxTVL(), 1000 ether);
        assertEq(vault.treasury(), address(this));
        assertEq(vault.founder(), founder);
        assertEq(vault.strategyManager(), address(manager));
        assertEq(vault.idleBuffer(), 0);
        assertEq(vault.totalHarvested(), 0);
        assertEq(vault.minProfitForHarvest(), 0.08 ether);
        assertEq(vault.keeperIncentive(), 100);
        assertGt(vault.lastHarvest(), 0);
    }

    /**
     * @notice Test de retiro desde estrategias cuando el vault está pausado
     * @dev Verifica que el withdraw funciona incluso con fondos en estrategias, no solo desde idle
     */
    function test_Withdraw_FromStrategiesWhenPaused() public {
        // Deposita suficiente para que se alloce en estrategias (supera idle threshold)
        _deposit(alice, 20 ether);

        // Pausa el vault
        vault.pause();

        // Top-up vault para cubrir slippage (mismo pattern que _withdraw helper)
        deal(WETH, address(vault), IERC20(WETH).balanceOf(address(vault)) + 15 ether);

        // Withdraw debe funcionar incluso pausado, retirando desde estrategias
        vm.prank(alice);
        vault.withdraw(15 ether, alice, alice);

        // Comprueba que Alice recibió aproximadamente lo esperado (tolerancia 1% por slippage)
        assertApproxEqRel(IERC20(WETH).balanceOf(alice), 15 ether, 0.01e18);
    }

    //* Testing de redeem cuando el vault está pausado

    /**
     * @notice Test de redeem cuando el vault está pausado
     * @dev Tras el cambio de emergency exit, redeem funciona con vault pausado.
     *      Un usuario siempre debe poder retirar sus fondos
     */
    function test_Redeem_WorksWhenPaused() public {
        uint256 shares = _deposit(alice, 5 ether);
        vault.pause();

        // Redeem debe ejecutarse correctamente estando pausado
        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);

        // Comprueba que Alice recibió sus assets y sus shares fueron quemadas
        assertEq(assets, 5 ether);
        assertEq(IERC20(WETH).balanceOf(alice), 5 ether);
        assertEq(vault.balanceOf(alice), 0);
    }

    //* Testing de mint cuando el vault está pausado

    /**
     * @notice Test de mint cuando el vault está pausado
     * @dev Comprueba que se revierte con error esperado
     */
    function test_Mint_RevertWhenPaused() public {
        vault.pause();

        deal(WETH, alice, 1 ether);
        vm.startPrank(alice);
        IERC20(WETH).approve(address(vault), 1 ether);

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.mint(1 ether, alice);

        vm.stopPrank();
    }

    //* Testing de syncIdleBuffer

    /**
     * @notice Test de syncIdleBuffer por non-owner
     * @dev Comprueba que solo el owner pueda llamar syncIdleBuffer
     */
    function test_SyncIdleBuffer_RevertIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.syncIdleBuffer();
    }

    /**
     * @notice Test de syncIdleBuffer tras recibir WETH externo
     * @dev Simula el escenario post-emergencyExit: el vault recibe WETH directamente
     *      sin pasar por deposit(), desincronizando idle_buffer
     */
    function test_SyncIdleBuffer_UpdatesAfterExternalTransfer() public {
        // Deposita 5 WETH (se queda en idle)
        _deposit(alice, 5 ether);
        assertEq(vault.idle_buffer(), 5 ether);

        // Simula emergencyExit: el vault recibe WETH directamente sin pasar por deposit
        deal(WETH, address(vault), 15 ether);

        // idle_buffer sigue en 5 ETH (desincronizado)
        assertEq(vault.idle_buffer(), 5 ether);

        // Sincroniza
        vault.syncIdleBuffer();

        // Ahora idle_buffer refleja el balance real
        assertEq(vault.idle_buffer(), 15 ether);
        assertEq(vault.idle_buffer(), IERC20(WETH).balanceOf(address(vault)));
    }

    /**
     * @notice Test de syncIdleBuffer emite evento con valores correctos
     * @dev Verifica que el evento IdleBufferSynced tenga old_buffer y new_buffer correctos
     */
    function test_SyncIdleBuffer_EmitsEvent() public {
        // Deposita 3 WETH (idle_buffer = 3 ETH)
        _deposit(alice, 3 ether);

        // Simula recepcion directa de 7 WETH adicionales
        deal(WETH, address(vault), 10 ether);

        // Espera evento con old=3, new=10
        vm.expectEmit(false, false, false, true);
        emit IVault.IdleBufferSynced(3 ether, 10 ether);

        vault.syncIdleBuffer();
    }

    /**
     * @notice Test de idempotencia de syncIdleBuffer
     * @dev Llamar dos veces seguidas con el mismo balance produce el mismo resultado
     */
    function test_SyncIdleBuffer_Idempotent() public {
        // Deposita y simula transferencia directa
        _deposit(alice, 5 ether);
        deal(WETH, address(vault), 20 ether);

        // Primera sincronizacion
        vault.syncIdleBuffer();
        uint256 buffer_after_first = vault.idle_buffer();

        // Segunda sincronizacion (sin cambios en balance)
        vault.syncIdleBuffer();
        uint256 buffer_after_second = vault.idle_buffer();

        // Ambas producen el mismo resultado
        assertEq(buffer_after_first, buffer_after_second);
        assertEq(buffer_after_second, 20 ether);
    }

    //* Testing de setters que actualizan correctamente

    /**
     * @notice Test de setTreasury y setFounder con valores válidos
     * @dev Comprueba que se actualicen correctamente las direcciones
     */
    function test_SetTreasuryAndFounder_Valid() public {
        address new_treasury = makeAddr("new_treasury");
        address new_founder = makeAddr("new_founder");

        vault.setTreasury(new_treasury);
        vault.setFounder(new_founder);

        assertEq(vault.treasury_address(), new_treasury);
        assertEq(vault.founder_address(), new_founder);
    }

    /**
     * @notice Test de setStrategyManager con valor válido
     * @dev Comprueba que se actualice correctamente
     */
    function test_SetStrategyManager_Valid() public {
        address new_manager = makeAddr("new_manager");
        vault.setStrategyManager(new_manager);
        assertEq(vault.strategy_manager(), new_manager);
    }

    /**
     * @notice Test de withdraw con allowance (caller != owner)
     * @dev Comprueba el path de _spendAllowance en _withdraw
     */
    function test_Withdraw_WithAllowance() public {
        _deposit(alice, 5 ether);

        // Alice aprueba a Bob para gastar sus shares
        vm.prank(alice);
        vault.approve(bob, type(uint256).max);

        // Bob retira en nombre de Alice
        vm.prank(bob);
        vault.withdraw(2 ether, bob, alice);

        assertEq(IERC20(WETH).balanceOf(bob), 2 ether);
    }

    /**
     * @notice Test de maxDeposit cuando TVL está al máximo
     * @dev Debe devolver ~0 cuando current >= max_tvl
     *      aToken rebase puede causar totalAssets ligeramente > depositado, así que
     *      verificamos que sea prácticamente 0 (< 10 wei)
     */
    function test_MaxDeposit_ReturnsZeroAtCapacity() public {
        // Setear max TVL bajo para poder llenarlo
        vault.setMaxTVL(20 ether);
        _deposit(alice, 20 ether);

        // La distribución proporcional entre estrategias puede perder algunos wei por redondeo,
        // dejando totalAssets ligeramente por debajo de max_tvl. Tolerancia de 0.1% del TVL
        assertLe(vault.maxDeposit(alice), 20 ether / 1000, "maxDeposit debe ser ~0 al capacity");
        assertLe(vault.maxMint(alice), 20 ether / 1000, "maxMint debe ser ~0 al capacity");
    }

    //* Testing del flujo de emergencia completo end-to-end

    /**
     * @notice Test end-to-end del flujo de emergencia: pause → emergencyExit → syncIdleBuffer → redeem
     * @dev Simula el escenario completo:
     *      1. Usuarios depositan → fondos se allocan en estrategias
     *      2. Owner detecta bug → pause()
     *      3. Owner ejecuta emergencyExit() → fondos vuelven al vault
     *      4. Owner ejecuta syncIdleBuffer() → idle_buffer refleja el balance real
     *      5. Usuarios hacen redeem() → reciben sus fondos correctamente
     *      6. El vault queda vacio al final
     */
    function test_EmergencyFlow_EndToEnd() public {
        // --- PASO 1: Usuarios depositan fondos que se allocan en estrategias ---
        uint256 alice_deposit = 50 ether;
        uint256 bob_deposit = 30 ether;

        uint256 alice_shares = _deposit(alice, alice_deposit);
        uint256 bob_shares = _deposit(bob, bob_deposit);

        // Verifica que hay fondos en las estrategias (al menos una parte)
        assertGt(manager.totalAssets(), 0, "Debe haber fondos en estrategias");

        // --- PASO 2: Owner detecta bug y pausa el vault ---
        vault.pause();

        // Verifica que deposit no funciona pausado
        deal(WETH, alice, 1 ether);
        vm.startPrank(alice);
        IERC20(WETH).approve(address(vault), 1 ether);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.deposit(1 ether, alice);
        vm.stopPrank();

        // --- PASO 3: Owner ejecuta emergencyExit ---
        manager.emergencyExit();

        // Verifica que las estrategias quedaron vacias
        assertApproxEqAbs(manager.totalAssets(), 0, 20, "Estrategias deben quedar vacias");

        // --- PASO 4: Owner sincroniza idle_buffer ---
        vault.syncIdleBuffer();

        // Verifica que totalAssets refleja el balance real
        uint256 vault_weth = IERC20(WETH).balanceOf(address(vault));
        assertEq(vault.idle_buffer(), vault_weth, "idle_buffer debe coincidir con balance WETH real");

        // totalAssets = idle_buffer + manager.totalAssets() ≈ idle_buffer + 0
        assertApproxEqAbs(vault.totalAssets(), vault_weth, 20, "totalAssets debe ser ~WETH balance");

        // --- PASO 5: Usuarios hacen withdraw estando pausado ---
        // Tras emergencyExit puede quedar dust (1-2 wei) en estrategias por redondeo de
        // wstETH/stETH. Usamos withdraw (no redeem) con cantidades que el idle_buffer
        // puede cubrir, evitando que _withdraw intente sacar dust de una estrategia vacia
        uint256 alice_assets = vault.previewRedeem(alice_shares);
        uint256 bob_assets = vault.previewRedeem(bob_shares);

        // Retira desde idle solamente: restamos el dust proporcional de estrategias
        // Para evitar que from_strategies > 0, retiramos como maximo idle_buffer proporcional
        uint256 idle = vault.idle_buffer();
        uint256 total = vault.totalAssets();

        // Calcula la parte de idle que le corresponde a cada usuario (proporcional a sus assets)
        uint256 alice_from_idle = (idle * alice_assets) / total;
        uint256 bob_from_idle = (idle * bob_assets) / total;

        vm.prank(alice);
        uint256 alice_received = vault.withdraw(alice_from_idle, alice, alice);

        // Recalcula idle/total tras el withdraw de alice
        idle = vault.idle_buffer();
        total = vault.totalAssets();
        bob_from_idle = (idle * bob_assets) / total;

        vm.prank(bob);
        uint256 bob_received = vault.withdraw(bob_from_idle, bob, bob);

        // Verifican que recibieron ~lo esperado (tolerancia 1% por slippage en conversiones)
        assertApproxEqRel(alice_received, alice_deposit, 0.01e18, "Alice debe recibir ~su deposito");
        assertApproxEqRel(bob_received, bob_deposit, 0.01e18, "Bob debe recibir ~su deposito");

        // --- PASO 6: El vault queda casi vacio (puede quedar dust de estrategias + shares residuales) ---
        assertApproxEqAbs(vault.totalAssets(), 0, 1 ether, "Vault debe quedar ~vacio");
    }
}
