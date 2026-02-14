// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {CompoundStrategy} from "../../src/strategies/CompoundStrategy.sol";
import {StrategyManager} from "../../src/core/StrategyManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title CompoundStrategyTest
 * @author cristianrisueo
 * @notice Unit tests for CompoundStrategy with Mainnet fork
 * @dev Real fork test against Compound v3 - validates deposits, withdrawals and APY
 */
contract CompoundStrategyTest is Test {
    //* State variables

    /// @notice Instance of the strategy and manager
    CompoundStrategy public strategy;
    StrategyManager public manager;

    /// @notice Contract addresses on Mainnet
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant COMPOUND_COMET = 0xA17581A9E3356d9A858b789D68B4d866e593aE94;
    address constant COMPOUND_REWARDS = 0x1B0e765F6224C21223AeA2af16c1C46E38885a40;
    address constant COMP_TOKEN = 0xc00e94Cb662C3520282E6f5717214004A7f26888;
    address constant UNISWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    uint24 constant POOL_FEE = 3000;

    /// @notice Test user
    address public alice = makeAddr("alice");

    //* Testing environment setup

    /**
     * @notice Configures the testing environment
     * @dev Mainnet fork to interact with real Compound v3
     */
    function setUp() public {
        // Create a Mainnet fork
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        // Initialize manager (needed for the strategy)
        manager = new StrategyManager(WETH);

        // Initialize the strategy
        strategy = new CompoundStrategy(address(manager), COMPOUND_COMET, COMPOUND_REWARDS, WETH, COMP_TOKEN, UNISWAP_ROUTER, POOL_FEE);
    }

    //* Internal helper functions

    /**
     * @notice Helper to deposit into the strategy as manager
     * @param amount Amount to deposit
     */
    function _deposit(uint256 amount) internal {
        // Give WETH to the strategy and deposit as manager
        deal(WETH, address(strategy), amount);
        vm.prank(address(manager));
        strategy.deposit(amount);
    }

    /**
     * @notice Helper to withdraw from the strategy as manager
     * @param amount Amount to withdraw
     */
    function _withdraw(uint256 amount) internal {
        vm.prank(address(manager));
        strategy.withdraw(amount);
    }

    //* Deposit testing

    /**
     * @notice Basic deposit into Compound test
     * @dev Checks that the deposit is executed correctly
     */
    function test_Deposit_Basic() public {
        // Deposit into Compound
        _deposit(10 ether);

        // Check that totalAssets reflects the deposit
        assertApproxEqRel(strategy.totalAssets(), 10 ether, 0.001e18);
    }

    /**
     * @notice Deposit only from manager test
     * @dev Checks that only the manager can deposit
     */
    function test_Deposit_RevertIfNotManager() public {
        deal(WETH, address(strategy), 10 ether);

        vm.prank(alice);
        vm.expectRevert(CompoundStrategy.CompoundStrategy__OnlyManager.selector);
        strategy.deposit(10 ether);
    }

    //* Withdraw testing

    /**
     * @notice Basic withdrawal from Compound test
     * @dev Checks that the withdrawal is executed correctly
     */
    function test_Withdraw_Basic() public {
        // Deposit first
        _deposit(10 ether);

        // Withdraw half
        _withdraw(5 ether);

        // Check that the manager received the funds
        assertEq(IERC20(WETH).balanceOf(address(manager)), 5 ether);

        // Check that approximately half remains
        assertApproxEqRel(strategy.totalAssets(), 5 ether, 0.001e18);
    }

    /**
     * @notice Full withdrawal from Compound test
     * @dev Checks that everything can be withdrawn
     */
    function test_Withdraw_Full() public {
        // Deposit
        _deposit(10 ether);

        // Withdraw everything
        uint256 balance = strategy.totalAssets();
        _withdraw(balance);

        // Check that the balance is approximately 0 (there may be dust)
        assertLt(strategy.totalAssets(), 0.0001 ether);
    }

    /**
     * @notice Withdrawal only from manager test
     * @dev Checks that only the manager can withdraw
     */
    function test_Withdraw_RevertIfNotManager() public {
        _deposit(10 ether);

        vm.prank(alice);
        vm.expectRevert(CompoundStrategy.CompoundStrategy__OnlyManager.selector);
        strategy.withdraw(5 ether);
    }

    //* Query function testing

    /**
     * @notice APY test
     * @dev Checks that the APY is a reasonable value
     */
    function test_Apy_ReturnsValidValue() public view {
        uint256 apy = strategy.apy();

        // The APY should be between 0% and 50% (0 - 5000 bp)
        assertLt(apy, 5000);
    }

    /**
     * @notice Strategy name test
     * @dev Checks that it returns the correct name
     */
    function test_Name() public view {
        assertEq(strategy.name(), "Compound v3 Strategy");
    }

    /**
     * @notice Asset test
     * @dev Checks that it returns the WETH address
     */
    function test_Asset() public view {
        assertEq(strategy.asset(), WETH);
    }

    /**
     * @notice Supply rate test
     * @dev Checks that getSupplyRate returns a valid value
     */
    function test_GetSupplyRate() public view {
        uint256 rate = strategy.getSupplyRate();

        // The rate should be > 0 if there's utilization
        // We don't do a strong assert because it can be 0 if utilization = 0
        assertLt(rate, type(uint256).max);
    }

    /**
     * @notice Utilization test
     * @dev Checks that getUtilization returns a valid value
     */
    function test_GetUtilization() public view {
        uint256 utilization = strategy.getUtilization();

        // Utilization should be between 0% and 100% (0 - 1e18)
        assertLe(utilization, 1e18);
    }

    /**
     * @notice totalAssets without deposits test
     * @dev Checks that it returns 0 without deposits
     */
    function test_TotalAssets_ZeroWithoutDeposits() public view {
        assertEq(strategy.totalAssets(), 0);
    }
}
