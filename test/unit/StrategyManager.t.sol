// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {StrategyManager} from "../../src/core/StrategyManager.sol";
import {IStrategyManager} from "../../src/interfaces/core/IStrategyManager.sol";
import {Vault} from "../../src/core/Vault.sol";
import {IVault} from "../../src/interfaces/core/IVault.sol";
import {AaveStrategy} from "../../src/strategies/AaveStrategy.sol";
import {LidoStrategy} from "../../src/strategies/LidoStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INonfungiblePositionManager} from "../../src/interfaces/strategies/uniswap/INonfungiblePositionManager.sol";
import {IWETH} from "@aave/contracts/misc/interfaces/IWETH.sol";

/**
 * @title StrategyManagerTest
 * @author cristianrisueo
 * @notice Tests unitarios para StrategyManager con fork de Mainnet
 * @dev Fork test real - valida allocation, withdrawals y rebalancing
 */
contract StrategyManagerTest is Test {
    //* Variables de estado

    /// @notice Instancia del manager, vault y estrategias
    StrategyManager public manager;
    Vault public vault;
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
    address public treasury;

    //* Setup del entorno de testing

    /**
     * @notice Configura el entorno de testing
     * @dev Fork de Mainnet para comportamiento real de protocolos
     */
    function setUp() public {
        // Crea un fork de Mainnet
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        // Setea el treasury
        treasury = makeAddr("treasury");

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
            treasury,
            makeAddr("founder"),
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

        // Mock Aave APY para que allocation funcione con ambas estrategias
        vm.mockCall(address(aave_strategy), abi.encodeWithSignature("apy()"), abi.encode(uint256(300)));

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
     * @notice Helper para simular allocation desde el vault
     * @dev Transfiere WETH al manager y llama allocate como vault
     * @param amount Cantidad a allocar
     */
    function _allocateFromVault(uint256 amount) internal {
        // Da WETH al vault y lo transfiere al manager
        deal(WETH, address(vault), amount);
        vm.prank(address(vault));
        IERC20(WETH).transfer(address(manager), amount);

        // Llama allocate como vault
        vm.prank(address(vault));
        manager.allocate(amount);
    }

    /**
     * @notice Helper para simular withdrawal hacia el vault
     * @param amount Cantidad a retirar
     */
    function _withdrawToVault(uint256 amount) internal {
        vm.prank(address(vault));
        manager.withdrawTo(amount, address(vault));
    }

    //* Testing de inicialización

    /**
     * @notice Test de inicialización del vault
     * @dev Comprueba que solo se pueda inicializar una vez
     */
    function test_InitializeVault_RevertIfAlreadyInitialized() public {
        // Intenta inicializar de nuevo
        vm.expectRevert(StrategyManager.StrategyManager__VaultAlreadyInitialized.selector);
        manager.initialize(alice);
    }

    //* Testing de allocation

    /**
     * @notice Test de allocation básico
     * @dev Comprueba que los fondos se distribuyan a las estrategias
     */
    function test_Allocate_Basic() public {
        // Alloca fondos
        _allocateFromVault(100 ether);

        // Comprueba que las estrategias recibieron fondos
        assertGt(aave_strategy.totalAssets(), 0);
        assertGt(lido_strategy.totalAssets(), 0);

        // Comprueba que el total sea aproximadamente el allocado
        assertApproxEqRel(manager.totalAssets(), 100 ether, 0.001e18);
    }

    /**
     * @notice Test de allocation solo desde vault
     * @dev Comprueba que solo el vault pueda llamar allocate
     */
    function test_Allocate_RevertIfNotVault() public {
        // Intenta allocar como alice
        vm.prank(alice);
        vm.expectRevert(StrategyManager.StrategyManager__OnlyVault.selector);
        manager.allocate(100 ether);
    }

    /**
     * @notice Test de allocation con cantidad cero
     * @dev Comprueba que revierta con cantidad cero
     */
    function test_Allocate_RevertZero() public {
        vm.prank(address(vault));
        vm.expectRevert(StrategyManager.StrategyManager__ZeroAmount.selector);
        manager.allocate(0);
    }

    /**
     * @notice Test de allocation sin estrategias
     * @dev Comprueba que revierta si no hay estrategias disponibles
     */
    function test_Allocate_RevertNoStrategies() public {
        // Crea un nuevo manager sin estrategias (misma config para que compile)
        StrategyManager empty_manager = new StrategyManager(
            WETH,
            IStrategyManager.TierConfig({
                max_allocation_per_strategy: 5000,
                min_allocation_threshold: 2000,
                rebalance_threshold: 200,
                min_tvl_for_rebalance: 8 ether
            })
        );
        empty_manager.initialize(address(vault));

        vm.prank(address(vault));
        vm.expectRevert(StrategyManager.StrategyManager__NoStrategiesAvailable.selector);
        empty_manager.allocate(100 ether);
    }

    //* Testing de withdrawals

    /**
     * @notice Test de withdrawal básico
     * @dev Comprueba que se retiren fondos proporcionalmente
     */
    function test_WithdrawTo_Basic() public {
        // Alloca primero
        _allocateFromVault(100 ether);

        // Retira la mitad
        _withdrawToVault(50 ether);

        // Comprueba que el vault recibió los fondos (tolerancia 1% por slippage en swaps)
        assertApproxEqRel(IERC20(WETH).balanceOf(address(vault)), 50 ether, 0.01e18);

        // Comprueba que el manager tiene aproximadamente la mitad
        assertApproxEqRel(manager.totalAssets(), 50 ether, 0.01e18);
    }

    /**
     * @notice Test de withdrawal solo desde vault
     * @dev Comprueba que solo el vault pueda llamar withdrawTo
     */
    function test_WithdrawTo_RevertIfNotVault() public {
        vm.prank(alice);
        vm.expectRevert(StrategyManager.StrategyManager__OnlyVault.selector);
        manager.withdrawTo(50 ether, alice);
    }

    /**
     * @notice Test de withdrawal con cantidad cero
     * @dev Comprueba que revierta con cantidad cero
     */
    function test_WithdrawTo_RevertZero() public {
        vm.prank(address(vault));
        vm.expectRevert(StrategyManager.StrategyManager__ZeroAmount.selector);
        manager.withdrawTo(0, address(vault));
    }

    //* Testing de gestión de estrategias

    /**
     * @notice Test de añadir estrategia
     * @dev Comprueba que se pueda añadir una estrategia correctamente
     */
    function test_AddStrategy_Basic() public {
        // Crea un nuevo manager (misma config para que compile)
        StrategyManager new_manager = new StrategyManager(
            WETH,
            IStrategyManager.TierConfig({
                max_allocation_per_strategy: 5000,
                min_allocation_threshold: 2000,
                rebalance_threshold: 200,
                min_tvl_for_rebalance: 8 ether
            })
        );

        // Añade estrategia
        new_manager.addStrategy(address(aave_strategy));

        // Comprueba que se añadió
        assertEq(new_manager.strategiesCount(), 1);
        assertTrue(new_manager.is_strategy(address(aave_strategy)));
    }

    /**
     * @notice Test de añadir estrategia duplicada
     * @dev Comprueba que revierta al añadir duplicada
     */
    function test_AddStrategy_RevertDuplicate() public {
        vm.expectRevert(StrategyManager.StrategyManager__StrategyAlreadyExists.selector);
        manager.addStrategy(address(aave_strategy));
    }

    /**
     * @notice Test de remover estrategia
     * @dev Comprueba que se pueda remover una estrategia
     */
    function test_RemoveStrategy_Basic() public {
        // Remueve estrategia (index 0 = aave)
        manager.removeStrategy(0);

        // Comprueba que se removió
        assertEq(manager.strategiesCount(), 1);
        assertFalse(manager.is_strategy(address(aave_strategy)));
    }

    /**
     * @notice Test de remover estrategia inexistente
     * @dev Comprueba que revierta al remover inexistente
     */
    function test_RemoveStrategy_RevertNotFound() public {
        vm.expectRevert(StrategyManager.StrategyManager__StrategyNotFound.selector);
        manager.removeStrategy(99);
    }

    //* Testing de rebalance

    /**
     * @notice Test de rebalance exitoso
     * @dev Fuerza desbalance y ejecuta rebalance para verificar movimiento de fondos
     */
    function test_Rebalance_ExecutesSuccessfully() public {
        // Alloca fondos suficientes para rebalance
        _allocateFromVault(100 ether);

        // Guarda balances iniciales
        uint256 aave_before = aave_strategy.totalAssets();
        uint256 lido_before = lido_strategy.totalAssets();

        // Cambia el max allocation para forzar desbalance
        manager.setMaxAllocationPerStrategy(4000); // 40% max

        // Si shouldRebalance es true, ejecuta rebalance
        if (manager.shouldRebalance()) {
            manager.rebalance();

            // Verifica que hubo movimiento de fondos
            uint256 aave_after = aave_strategy.totalAssets();
            uint256 lido_after = lido_strategy.totalAssets();

            // Al menos una estrategia debería haber cambiado
            bool funds_moved = (aave_after != aave_before) || (lido_after != lido_before);
            assertTrue(funds_moved, "Rebalance deberia mover fondos");
        }

        // El total de assets debe mantenerse aproximadamente igual
        assertApproxEqRel(manager.totalAssets(), 100 ether, 0.01e18);
    }

    /**
     * @notice Test de rebalance revierte si no es rentable
     * @dev Comprueba que revierta cuando shouldRebalance es false
     */
    function test_Rebalance_RevertIfNotProfitable() public {
        // Con TVL bajo, shouldRebalance retorna false
        _allocateFromVault(5 ether);

        // Debería revertir porque no es rentable
        vm.expectRevert(StrategyManager.StrategyManager__RebalanceNotProfitable.selector);
        manager.rebalance();
    }

    //* Testing de funciones de consulta

    /**
     * @notice Test de totalAssets
     * @dev Comprueba que sume correctamente los assets de todas las estrategias
     */
    function test_TotalAssets_SumsAllStrategies() public {
        // Alloca fondos
        _allocateFromVault(100 ether);

        // El total debe ser la suma de ambas estrategias
        uint256 expected = aave_strategy.totalAssets() + lido_strategy.totalAssets();
        assertEq(manager.totalAssets(), expected);
    }

    /**
     * @notice Test de strategiesCount
     * @dev Comprueba que devuelva el número correcto de estrategias
     */
    function test_StrategiesCount() public view {
        assertEq(manager.strategiesCount(), 2);
    }

    /**
     * @notice Test de getAllStrategiesInfo
     * @dev Comprueba que devuelva información correcta de las estrategias
     */
    function test_GetAllStrategiesInfo() public {
        // Alloca algo para que haya TVL
        _allocateFromVault(100 ether);

        // Obtiene info
        (string[] memory names, uint256[] memory apys, uint256[] memory tvls, uint256[] memory targets) =
            manager.getAllStrategiesInfo();

        // Comprueba que tenga 2 estrategias
        assertEq(names.length, 2);
        assertEq(apys.length, 2);
        assertEq(tvls.length, 2);
        assertEq(targets.length, 2);

        // Comprueba que los targets sumen aproximadamente 100% (puede haber redondeo)
        assertApproxEqAbs(targets[0] + targets[1], 10000, 1);
    }

    //* Testing de funcionalidad only owner

    /**
     * @notice Test de permisos de administrador
     * @dev Comprueba que solo el owner pueda cambiar parámetros
     */
    function test_Admin_OnlyOwnerCanSetParams() public {
        // Intenta como alice (no owner)
        vm.startPrank(alice);
        vm.expectRevert();
        manager.setRebalanceThreshold(300);
        vm.expectRevert();
        manager.setMinTVLForRebalance(20 ether);
        vm.expectRevert();
        manager.setMaxAllocationPerStrategy(6000);
        vm.expectRevert();
        manager.setMinAllocationThreshold(500);
        vm.expectRevert();
        manager.addStrategy(alice);
        vm.stopPrank();

        // Ejecuta como owner (debería funcionar)
        manager.setRebalanceThreshold(300);
        manager.setMinTVLForRebalance(20 ether);
        manager.setMaxAllocationPerStrategy(6000);
        manager.setMinAllocationThreshold(500);

        // Comprueba valores actualizados
        assertEq(manager.rebalance_threshold(), 300);
        assertEq(manager.min_tvl_for_rebalance(), 20 ether);
        assertEq(manager.max_allocation_per_strategy(), 6000);
        assertEq(manager.min_allocation_threshold(), 500);
    }
}
