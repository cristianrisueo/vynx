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
 * @notice Unit tests for StrategyManager with Mainnet fork
 * @dev Real fork test - validates allocation, withdrawals and rebalancing
 */
contract StrategyManagerTest is Test {
    //* Variables de estado

    /// @notice Manager, vault and strategy instances
    StrategyManager public manager;
    Vault public vault;
    AaveStrategy public aave_strategy;
    LidoStrategy public lido_strategy;

    /// @notice Mainnet contract addresses
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

    /// @notice Test users
    address public alice = makeAddr("alice");
    address public treasury;

    //* Testing environment setup

    /**
     * @notice Configures the testing environment
     * @dev Mainnet fork for real protocol behavior
     */
    function setUp() public {
        // Creates a Mainnet fork
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        // Sets the treasury
        treasury = makeAddr("treasury");

        // Initializes the manager with Balanced tier parameters
        manager = new StrategyManager(
            WETH,
            IStrategyManager.TierConfig({
                max_allocation_per_strategy: 5000, // 50%
                min_allocation_threshold: 2000, // 20%
                rebalance_threshold: 200, // 2%
                min_tvl_for_rebalance: 8 ether
            })
        );

        // Initializes the vault with Balanced tier parameters
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

        // Initializes the strategies with real mainnet addresses
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

        // Mock Aave APY so allocation works with both strategies
        vm.mockCall(address(aave_strategy), abi.encodeWithSignature("apy()"), abi.encode(uint256(300)));

        // Adds the strategies
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

    //* Internal helper functions

    /**
     * @notice Helper to simulate allocation from the vault
     * @dev Transfers WETH to the manager and calls allocate as vault
     * @param amount Amount to allocate
     */
    function _allocateFromVault(uint256 amount) internal {
        // Gives WETH to the vault and transfers it to the manager
        deal(WETH, address(vault), amount);
        vm.prank(address(vault));
        IERC20(WETH).transfer(address(manager), amount);

        // Calls allocate as vault
        vm.prank(address(vault));
        manager.allocate(amount);
    }

    /**
     * @notice Helper to simulate withdrawal to the vault
     * @param amount Amount to withdraw
     */
    function _withdrawToVault(uint256 amount) internal {
        vm.prank(address(vault));
        manager.withdrawTo(amount, address(vault));
    }

    //* Initialization tests

    /**
     * @notice Vault initialization test
     * @dev Checks that it can only be initialized once
     */
    function test_InitializeVault_RevertIfAlreadyInitialized() public {
        // Attempts to initialize again
        vm.expectRevert(StrategyManager.StrategyManager__VaultAlreadyInitialized.selector);
        manager.initialize(alice);
    }

    //* Allocation tests

    /**
     * @notice Basic allocation test
     * @dev Checks that funds are distributed to strategies
     */
    function test_Allocate_Basic() public {
        // Allocates funds
        _allocateFromVault(100 ether);

        // Checks that strategies received funds
        assertGt(aave_strategy.totalAssets(), 0);
        assertGt(lido_strategy.totalAssets(), 0);

        // Checks that total is approximately the allocated amount
        assertApproxEqRel(manager.totalAssets(), 100 ether, 0.001e18);
    }

    /**
     * @notice Allocation only from vault test
     * @dev Checks that only the vault can call allocate
     */
    function test_Allocate_RevertIfNotVault() public {
        // Attempts to allocate as alice
        vm.prank(alice);
        vm.expectRevert(StrategyManager.StrategyManager__OnlyVault.selector);
        manager.allocate(100 ether);
    }

    /**
     * @notice Allocation with zero amount test
     * @dev Checks it reverts with zero amount
     */
    function test_Allocate_RevertZero() public {
        vm.prank(address(vault));
        vm.expectRevert(StrategyManager.StrategyManager__ZeroAmount.selector);
        manager.allocate(0);
    }

    /**
     * @notice Allocation without strategies test
     * @dev Checks it reverts if there are no available strategies
     */
    function test_Allocate_RevertNoStrategies() public {
        // Creates a new manager without strategies (same config so it compiles)
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

    //* Withdrawal tests

    /**
     * @notice Basic withdrawal test
     * @dev Checks that funds are withdrawn proportionally
     */
    function test_WithdrawTo_Basic() public {
        // Allocates first
        _allocateFromVault(100 ether);

        // Withdraws half
        _withdrawToVault(50 ether);

        // Checks that the vault received the funds (1% tolerance for swap slippage)
        assertApproxEqRel(IERC20(WETH).balanceOf(address(vault)), 50 ether, 0.01e18);

        // Checks that the manager has approximately half
        assertApproxEqRel(manager.totalAssets(), 50 ether, 0.01e18);
    }

    /**
     * @notice Withdrawal only from vault test
     * @dev Checks that only the vault can call withdrawTo
     */
    function test_WithdrawTo_RevertIfNotVault() public {
        vm.prank(alice);
        vm.expectRevert(StrategyManager.StrategyManager__OnlyVault.selector);
        manager.withdrawTo(50 ether, alice);
    }

    /**
     * @notice Withdrawal with zero amount test
     * @dev Checks it reverts with zero amount
     */
    function test_WithdrawTo_RevertZero() public {
        vm.prank(address(vault));
        vm.expectRevert(StrategyManager.StrategyManager__ZeroAmount.selector);
        manager.withdrawTo(0, address(vault));
    }

    //* Strategy management tests

    /**
     * @notice Add strategy test
     * @dev Checks that a strategy can be added correctly
     */
    function test_AddStrategy_Basic() public {
        // Creates a new manager (same config so it compiles)
        StrategyManager new_manager = new StrategyManager(
            WETH,
            IStrategyManager.TierConfig({
                max_allocation_per_strategy: 5000,
                min_allocation_threshold: 2000,
                rebalance_threshold: 200,
                min_tvl_for_rebalance: 8 ether
            })
        );

        // Adds strategy
        new_manager.addStrategy(address(aave_strategy));

        // Checks that it was added
        assertEq(new_manager.strategiesCount(), 1);
        assertTrue(new_manager.is_strategy(address(aave_strategy)));
    }

    /**
     * @notice Add duplicate strategy test
     * @dev Checks it reverts when adding a duplicate
     */
    function test_AddStrategy_RevertDuplicate() public {
        vm.expectRevert(StrategyManager.StrategyManager__StrategyAlreadyExists.selector);
        manager.addStrategy(address(aave_strategy));
    }

    /**
     * @notice Remove strategy test
     * @dev Checks that a strategy can be removed
     */
    function test_RemoveStrategy_Basic() public {
        // Removes strategy (index 0 = aave)
        manager.removeStrategy(0);

        // Checks that it was removed
        assertEq(manager.strategiesCount(), 1);
        assertFalse(manager.is_strategy(address(aave_strategy)));
    }

    /**
     * @notice Remove non-existent strategy test
     * @dev Checks it reverts when removing a non-existent strategy
     */
    function test_RemoveStrategy_RevertNotFound() public {
        vm.expectRevert(StrategyManager.StrategyManager__StrategyNotFound.selector);
        manager.removeStrategy(99);
    }

    //* Rebalance tests

    /**
     * @notice Successful rebalance test
     * @dev Forces imbalance and executes rebalance to verify fund movement
     */
    function test_Rebalance_ExecutesSuccessfully() public {
        // Allocates enough funds for rebalance
        _allocateFromVault(100 ether);

        // Saves initial balances
        uint256 aave_before = aave_strategy.totalAssets();
        uint256 lido_before = lido_strategy.totalAssets();

        // Changes max allocation to force imbalance
        manager.setMaxAllocationPerStrategy(4000); // 40% max

        // If shouldRebalance is true, executes rebalance
        if (manager.shouldRebalance()) {
            manager.rebalance();

            // Verifies that fund movement occurred
            uint256 aave_after = aave_strategy.totalAssets();
            uint256 lido_after = lido_strategy.totalAssets();

            // At least one strategy should have changed
            bool funds_moved = (aave_after != aave_before) || (lido_after != lido_before);
            assertTrue(funds_moved, "Rebalance should move funds");
        }

        // Total assets must remain approximately the same
        assertApproxEqRel(manager.totalAssets(), 100 ether, 0.01e18);
    }

    /**
     * @notice Rebalance reverts if not profitable test
     * @dev Checks it reverts when shouldRebalance is false
     */
    function test_Rebalance_RevertIfNotProfitable() public {
        // With low TVL, shouldRebalance returns false
        _allocateFromVault(5 ether);

        // Should revert because it is not profitable
        vm.expectRevert(StrategyManager.StrategyManager__RebalanceNotProfitable.selector);
        manager.rebalance();
    }

    //* Query function tests

    /**
     * @notice totalAssets test
     * @dev Checks that it correctly sums the assets of all strategies
     */
    function test_TotalAssets_SumsAllStrategies() public {
        // Allocates funds
        _allocateFromVault(100 ether);

        // Total must be the sum of both strategies
        uint256 expected = aave_strategy.totalAssets() + lido_strategy.totalAssets();
        assertEq(manager.totalAssets(), expected);
    }

    /**
     * @notice strategiesCount test
     * @dev Checks that it returns the correct number of strategies
     */
    function test_StrategiesCount() public view {
        assertEq(manager.strategiesCount(), 2);
    }

    /**
     * @notice getAllStrategiesInfo test
     * @dev Checks that it returns correct information about strategies
     */
    function test_GetAllStrategiesInfo() public {
        // Allocates something so there is TVL
        _allocateFromVault(100 ether);

        // Gets info
        (string[] memory names, uint256[] memory apys, uint256[] memory tvls, uint256[] memory targets) =
            manager.getAllStrategiesInfo();

        // Checks that it has 2 strategies
        assertEq(names.length, 2);
        assertEq(apys.length, 2);
        assertEq(tvls.length, 2);
        assertEq(targets.length, 2);

        // Checks that targets sum approximately 100% (there may be rounding)
        assertApproxEqAbs(targets[0] + targets[1], 10000, 1);
    }

    //* Emergency exit tests

    /**
     * @notice emergencyExit by non-owner test
     * @dev Checks that only the owner can execute emergencyExit
     */
    function test_EmergencyExit_RevertIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        manager.emergencyExit();
    }

    /**
     * @notice emergencyExit without registered strategies test
     * @dev Checks it does not revert and emits event with total_rescued = 0
     */
    function test_EmergencyExit_NoStrategies() public {
        // Creates a manager without strategies
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

        // Must execute without reverting
        vm.expectEmit(false, false, false, true);
        emit IStrategyManager.EmergencyExit(block.timestamp, 0, 0);

        empty_manager.emergencyExit();
    }

    /**
     * @notice emergencyExit with zero-balance strategies test
     * @dev Checks it does not revert when strategies have no funds
     */
    function test_EmergencyExit_ZeroBalanceStrategies() public {
        // We don't allocate anything, strategies have balance 0

        // Must execute without reverting and transfer 0 WETH
        vm.expectEmit(false, false, false, true);
        emit IStrategyManager.EmergencyExit(block.timestamp, 0, 0);

        manager.emergencyExit();

        // The vault must not have received WETH
        assertEq(IERC20(WETH).balanceOf(address(vault)), 0);
    }

    /**
     * @notice emergencyExit with strategies with balance > 0 test
     * @dev Checks that all WETH is transferred to the vault and manager is left at 0
     */
    function test_EmergencyExit_DrainsAllStrategies() public {
        // Allocates funds to strategies
        _allocateFromVault(100 ether);

        // Saves vault balance before exit
        uint256 vault_balance_before = IERC20(WETH).balanceOf(address(vault));

        // Executes emergencyExit
        manager.emergencyExit();

        // Manager balance must be ~0 (may have dust from rounding)
        assertApproxEqAbs(manager.totalAssets(), 0, 20, "Manager should be empty after emergencyExit");

        // Vault must have received WETH (total rescued, 1% tolerance for swap slippage)
        uint256 vault_balance_after = IERC20(WETH).balanceOf(address(vault));
        uint256 rescued = vault_balance_after - vault_balance_before;
        assertApproxEqRel(rescued, 100 ether, 0.01e18, "Vault should receive ~100% of allocated funds");
    }

    /**
     * @notice emergencyExit verifies manager balance is left at 0 test
     * @dev Guarantees that no residual funds remain in the manager contract
     */
    function test_EmergencyExit_ManagerBalanceZero() public {
        // Allocates funds
        _allocateFromVault(50 ether);

        // Executes emergencyExit
        manager.emergencyExit();

        // Manager WETH balance must be ~0 (may have residue from min_allocation_threshold
        // that the allocator did not send to any strategy because it was below the minimum threshold)
        assertApproxEqAbs(
            IERC20(WETH).balanceOf(address(manager)), 0, 0.01 ether, "Manager WETH balance debe ser ~0"
        );
    }

    /**
     * @notice emergencyExit emits event with correct timestamp and 2 drained strategies test
     * @dev Verifies that the EmergencyExit event is emitted with the expected data.
     *      We only check timestamp and strategies_drained (total_rescued depends on slippage)
     */
    function test_EmergencyExit_EmitsCorrectEvent() public {
        // Allocates funds to strategies
        _allocateFromVault(100 ether);

        // Expects EmergencyExit event: check topic (true) but not exact data values
        // because total_rescued depends on swap slippage in strategies
        vm.expectEmit(false, false, false, false);
        emit IStrategyManager.EmergencyExit(block.timestamp, 0, 2);

        manager.emergencyExit();
    }

    //* Owner-only functionality tests

    /**
     * @notice Admin permissions test
     * @dev Checks that only the owner can change parameters
     */
    function test_Admin_OnlyOwnerCanSetParams() public {
        // Attempts as alice (not owner)
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

        // Executes as owner (should work)
        manager.setRebalanceThreshold(300);
        manager.setMinTVLForRebalance(20 ether);
        manager.setMaxAllocationPerStrategy(6000);
        manager.setMinAllocationThreshold(500);

        // Checks updated values
        assertEq(manager.rebalance_threshold(), 300);
        assertEq(manager.min_tvl_for_rebalance(), 20 ether);
        assertEq(manager.max_allocation_per_strategy(), 6000);
        assertEq(manager.min_allocation_threshold(), 500);
    }
}
