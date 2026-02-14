// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {StrategyManager} from "../../src/core/StrategyManager.sol";
import {Vault} from "../../src/core/Vault.sol";
import {AaveStrategy} from "../../src/strategies/AaveStrategy.sol";
import {CompoundStrategy} from "../../src/strategies/CompoundStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title StrategyManagerTest
 * @author cristianrisueo
 * @notice Unit tests for StrategyManager with Mainnet fork
 * @dev Real fork test - validates allocation, withdrawals and rebalancing
 */
contract StrategyManagerTest is Test {
    //* State variables

    /// @notice Instance of the manager, vault and strategies
    StrategyManager public manager;
    Vault public vault;
    AaveStrategy public aave_strategy;
    CompoundStrategy public compound_strategy;

    /// @notice Contract addresses on Mainnet
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant COMPOUND_COMET = 0xA17581A9E3356d9A858b789D68B4d866e593aE94;
    address constant AAVE_REWARDS = 0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb;
    address constant COMPOUND_REWARDS = 0x1B0e765F6224C21223AeA2af16c1C46E38885a40;
    address constant AAVE_TOKEN = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;
    address constant COMP_TOKEN = 0xc00e94Cb662C3520282E6f5717214004A7f26888;
    address constant UNISWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
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
        // Create a Mainnet fork
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        // Set the treasury
        treasury = makeAddr("treasury");

        // Initialize the manager and vault
        manager = new StrategyManager(WETH);
        vault = new Vault(WETH, address(manager), treasury, makeAddr("founder"));
        manager.initialize(address(vault));

        // Initialize the strategies
        aave_strategy = new AaveStrategy(address(manager), AAVE_POOL, AAVE_REWARDS, WETH, AAVE_TOKEN, UNISWAP_ROUTER, POOL_FEE);
        compound_strategy = new CompoundStrategy(address(manager), COMPOUND_COMET, COMPOUND_REWARDS, WETH, COMP_TOKEN, UNISWAP_ROUTER, POOL_FEE);

        // Add the strategies
        manager.addStrategy(address(aave_strategy));
        manager.addStrategy(address(compound_strategy));
    }

    //* Internal helper functions

    /**
     * @notice Helper to simulate allocation from the vault
     * @dev Transfers WETH to the manager and calls allocate as vault
     * @param amount Amount to allocate
     */
    function _allocateFromVault(uint256 amount) internal {
        // Give WETH to the vault and transfer it to the manager
        deal(WETH, address(vault), amount);
        vm.prank(address(vault));
        IERC20(WETH).transfer(address(manager), amount);

        // Call allocate as vault
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

    //* Initialization testing

    /**
     * @notice Vault initialization test
     * @dev Checks that it can only be initialized once
     */
    function test_InitializeVault_RevertIfAlreadyInitialized() public {
        // Try to initialize again
        vm.expectRevert(StrategyManager.StrategyManager__VaultAlreadyInitialized.selector);
        manager.initialize(alice);
    }

    //* Allocation testing

    /**
     * @notice Basic allocation test
     * @dev Checks that funds are distributed to the strategies
     */
    function test_Allocate_Basic() public {
        // Allocate funds
        _allocateFromVault(100 ether);

        // Check that the strategies received funds
        assertGt(aave_strategy.totalAssets(), 0);
        assertGt(compound_strategy.totalAssets(), 0);

        // Check that the total is approximately the allocated amount
        assertApproxEqRel(manager.totalAssets(), 100 ether, 0.001e18);
    }

    /**
     * @notice Allocation only from vault test
     * @dev Checks that only the vault can call allocate
     */
    function test_Allocate_RevertIfNotVault() public {
        // Try to allocate as alice
        vm.prank(alice);
        vm.expectRevert(StrategyManager.StrategyManager__OnlyVault.selector);
        manager.allocate(100 ether);
    }

    /**
     * @notice Allocation with zero amount test
     * @dev Checks that it reverts with zero amount
     */
    function test_Allocate_RevertZero() public {
        vm.prank(address(vault));
        vm.expectRevert(StrategyManager.StrategyManager__ZeroAmount.selector);
        manager.allocate(0);
    }

    /**
     * @notice Allocation without strategies test
     * @dev Checks that it reverts if no strategies are available
     */
    function test_Allocate_RevertNoStrategies() public {
        // Create a new manager without strategies
        StrategyManager empty_manager = new StrategyManager(WETH);
        empty_manager.initialize(address(vault));

        vm.prank(address(vault));
        vm.expectRevert(StrategyManager.StrategyManager__NoStrategiesAvailable.selector);
        empty_manager.allocate(100 ether);
    }

    //* Withdrawal testing

    /**
     * @notice Basic withdrawal test
     * @dev Checks that funds are withdrawn proportionally
     */
    function test_WithdrawTo_Basic() public {
        // Allocate first
        _allocateFromVault(100 ether);

        // Withdraw half
        _withdrawToVault(50 ether);

        // Check that the vault received the funds (tolerance of 2 wei due to proportional rounding)
        assertApproxEqAbs(IERC20(WETH).balanceOf(address(vault)), 50 ether, 2);

        // Check that the manager has approximately half
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
     * @dev Checks that it reverts with zero amount
     */
    function test_WithdrawTo_RevertZero() public {
        vm.prank(address(vault));
        vm.expectRevert(StrategyManager.StrategyManager__ZeroAmount.selector);
        manager.withdrawTo(0, address(vault));
    }

    //* Strategy management testing

    /**
     * @notice Add strategy test
     * @dev Checks that a strategy can be added correctly
     */
    function test_AddStrategy_Basic() public {
        // Create a new manager
        StrategyManager new_manager = new StrategyManager(WETH);

        // Add strategy
        new_manager.addStrategy(address(aave_strategy));

        // Check that it was added
        assertEq(new_manager.strategiesCount(), 1);
        assertTrue(new_manager.is_strategy(address(aave_strategy)));
    }

    /**
     * @notice Add duplicate strategy test
     * @dev Checks that it reverts when adding a duplicate
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
        // Remove strategy (index 0 = aave)
        manager.removeStrategy(0);

        // Check that it was removed
        assertEq(manager.strategiesCount(), 1);
        assertFalse(manager.is_strategy(address(aave_strategy)));
    }

    /**
     * @notice Remove nonexistent strategy test
     * @dev Checks that it reverts when removing a nonexistent one
     */
    function test_RemoveStrategy_RevertNotFound() public {
        vm.expectRevert(StrategyManager.StrategyManager__StrategyNotFound.selector);
        manager.removeStrategy(99);
    }

    //* Rebalance testing

    /**
     * @notice Successful rebalance test
     * @dev Forces imbalance and executes rebalance to verify fund movement
     */
    function test_Rebalance_ExecutesSuccessfully() public {
        // Allocate enough funds for rebalance
        _allocateFromVault(100 ether);

        // Save initial balances
        uint256 aave_before = aave_strategy.totalAssets();
        uint256 compound_before = compound_strategy.totalAssets();

        // Change max allocation to force imbalance
        manager.setMaxAllocationPerStrategy(4000); // 40% max

        // If shouldRebalance is true, execute rebalance
        if (manager.shouldRebalance()) {
            manager.rebalance();

            // Verify that there was fund movement
            uint256 aave_after = aave_strategy.totalAssets();
            uint256 compound_after = compound_strategy.totalAssets();

            // At least one strategy should have changed
            bool funds_moved = (aave_after != aave_before) || (compound_after != compound_before);
            assertTrue(funds_moved, "Rebalance should move funds");
        }

        // The total assets must remain approximately the same
        assertApproxEqRel(manager.totalAssets(), 100 ether, 0.01e18);
    }

    /**
     * @notice Rebalance reverts if not profitable test
     * @dev Checks that it reverts when shouldRebalance is false
     */
    function test_Rebalance_RevertIfNotProfitable() public {
        // With low TVL, shouldRebalance returns false
        _allocateFromVault(5 ether);

        // Should revert because it's not profitable
        vm.expectRevert(StrategyManager.StrategyManager__RebalanceNotProfitable.selector);
        manager.rebalance();
    }

    //* Query function testing

    /**
     * @notice totalAssets test
     * @dev Checks that it correctly sums the assets of all strategies
     */
    function test_TotalAssets_SumsAllStrategies() public {
        // Allocate funds
        _allocateFromVault(100 ether);

        // The total must be the sum of both strategies
        uint256 expected = aave_strategy.totalAssets() + compound_strategy.totalAssets();
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
     * @dev Checks that it returns correct strategy information
     */
    function test_GetAllStrategiesInfo() public {
        // Allocate something so there's TVL
        _allocateFromVault(100 ether);

        // Get info
        (string[] memory names, uint256[] memory apys, uint256[] memory tvls, uint256[] memory targets) =
            manager.getAllStrategiesInfo();

        // Check that it has 2 strategies
        assertEq(names.length, 2);
        assertEq(apys.length, 2);
        assertEq(tvls.length, 2);
        assertEq(targets.length, 2);

        // Check that the targets sum to approximately 100% (rounding may occur)
        assertApproxEqAbs(targets[0] + targets[1], 10000, 1);
    }

    //* Only owner functionality testing

    /**
     * @notice Admin permissions test
     * @dev Checks that only the owner can change parameters
     */
    function test_Admin_OnlyOwnerCanSetParams() public {
        // Try as alice (not owner)
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

        // Execute as owner (should work)
        manager.setRebalanceThreshold(300);
        manager.setMinTVLForRebalance(20 ether);
        manager.setMaxAllocationPerStrategy(6000);
        manager.setMinAllocationThreshold(500);

        // Check updated values
        assertEq(manager.rebalance_threshold(), 300);
        assertEq(manager.min_tvl_for_rebalance(), 20 ether);
        assertEq(manager.max_allocation_per_strategy(), 6000);
        assertEq(manager.min_allocation_threshold(), 500);
    }
}
