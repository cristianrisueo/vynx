// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../../src/core/Vault.sol";
import {StrategyManager} from "../../src/core/StrategyManager.sol";
import {AaveStrategy} from "../../src/strategies/AaveStrategy.sol";
import {CompoundStrategy} from "../../src/strategies/CompoundStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
    CompoundStrategy public compound_strategy;

    /// @notice Direcciones de los contratos en Mainnet
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant COMPOUND_COMET = 0xA17581A9E3356d9A858b789D68B4d866e593aE94;
    address constant AAVE_REWARDS = 0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb;
    address constant COMPOUND_REWARDS = 0x1B0e765F6224C21223AeA2af16c1C46E38885a40;
    address constant AAVE_TOKEN = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;
    address constant COMP_TOKEN = 0xc00e94Cb662C3520282E6f5717214004A7f26888;
    address constant UNISWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
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

        // Inicializa el manager, vault y setea el address del vault en el manager
        manager = new StrategyManager(WETH);
        vault = new Vault(WETH, address(manager), address(this), founder);
        manager.initialize(address(vault));

        // Inicializa las estrategias con las direcciones reales de mainnet
        aave_strategy = new AaveStrategy(address(manager), AAVE_POOL, AAVE_REWARDS, WETH, AAVE_TOKEN, UNISWAP_ROUTER, POOL_FEE);
        compound_strategy = new CompoundStrategy(address(manager), COMPOUND_COMET, COMPOUND_REWARDS, WETH, COMP_TOKEN, UNISWAP_ROUTER, POOL_FEE);

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

        // Comprueba balance final de Alice
        assertEq(IERC20(WETH).balanceOf(alice), 15 ether);
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
        assertApproxEqAbs(vault.maxDeposit(alice), MAX_TVL - 100 ether, 10);
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
        assertTrue(vault.isOfficialKeeper(alice));
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
        new Vault(WETH, address(0), address(this), founder);
    }

    /**
     * @notice Test constructor con treasury address(0)
     */
    function test_Constructor_RevertInvalidTreasury() public {
        vm.expectRevert(Vault.Vault__InvalidTreasuryAddress.selector);
        new Vault(WETH, address(manager), address(0), founder);
    }

    /**
     * @notice Test constructor con founder address(0)
     */
    function test_Constructor_RevertInvalidFounder() public {
        vm.expectRevert(Vault.Vault__InvalidFounderAddress.selector);
        new Vault(WETH, address(manager), address(this), address(0));
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
        assertEq(vault.idleThreshold(), 10 ether);
        assertEq(vault.maxTVL(), 1000 ether);
        assertEq(vault.treasury(), address(this));
        assertEq(vault.founder(), founder);
        assertEq(vault.strategyManager(), address(manager));
        assertEq(vault.idleBuffer(), 0);
        assertEq(vault.totalHarvested(), 0);
        assertEq(vault.minProfitForHarvest(), 0.1 ether);
        assertEq(vault.keeperIncentive(), 100);
        assertGt(vault.lastHarvest(), 0);
    }

    //* Testing de redeem cuando el vault está pausado

    /**
     * @notice Test de redeem cuando el vault está pausado
     * @dev Comprueba que se revierte
     */
    function test_Redeem_RevertWhenPaused() public {
        uint256 shares = _deposit(alice, 5 ether);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.redeem(shares, alice, alice);
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

        assertLe(vault.maxDeposit(alice), 10, "maxDeposit debe ser ~0 al capacity");
        assertLe(vault.maxMint(alice), 10, "maxMint debe ser ~0 al capacity");
    }
}
