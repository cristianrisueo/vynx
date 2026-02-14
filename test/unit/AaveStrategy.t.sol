// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {AaveStrategy} from "../../src/strategies/AaveStrategy.sol";
import {StrategyManager} from "../../src/core/StrategyManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title AaveStrategyTest
 * @author cristianrisueo
 * @notice Unit tests for AaveStrategy with Mainnet fork
 * @dev Real fork test against Aave v3 - validates deposits, withdrawals and APY
 */
contract AaveStrategyTest is Test {
    //* State variables

    /// @notice Instance of the strategy and manager
    AaveStrategy public strategy;
    StrategyManager public manager;

    /// @notice Contract addresses on Mainnet
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_REWARDS = 0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb;
    address constant AAVE_TOKEN = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;
    address constant UNISWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    uint24 constant POOL_FEE = 3000;

    /// @notice Test user
    address public alice = makeAddr("alice");

    //* Testing environment setup

    /**
     * @notice Configures the testing environment
     * @dev Mainnet fork to interact with real Aave v3
     */
    function setUp() public {
        // Create a Mainnet fork using the Alchemy endpoint
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        // Initialize manager (needed for the strategy)
        manager = new StrategyManager(WETH);

        // Initialize the strategy
        strategy = new AaveStrategy(address(manager), AAVE_POOL, AAVE_REWARDS, WETH, AAVE_TOKEN, UNISWAP_ROUTER, POOL_FEE);
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
     * @notice Basic deposit into Aave test
     * @dev Checks that the deposit is executed correctly
     */
    function test_Deposit_Basic() public {
        // Deposit into Aave
        _deposit(10 ether);

        // Check that totalAssets reflects the deposit
        assertApproxEqRel(strategy.totalAssets(), 10 ether, 0.001e18);

        // Check that aTokenBalance matches
        assertEq(strategy.totalAssets(), strategy.aTokenBalance());
    }

    /**
     * @notice Deposit only from manager test
     * @dev Checks that only the manager can deposit
     */
    function test_Deposit_RevertIfNotManager() public {
        deal(WETH, address(strategy), 10 ether);

        vm.prank(alice);
        vm.expectRevert(AaveStrategy.AaveStrategy__OnlyManager.selector);
        strategy.deposit(10 ether);
    }

    //* Withdraw testing

    /**
     * @notice Basic withdrawal from Aave test
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
     * @notice Full withdrawal from Aave test
     * @dev Checks that everything can be withdrawn
     */
    function test_Withdraw_Full() public {
        // Deposit
        _deposit(10 ether);

        // Withdraw everything
        uint256 balance = strategy.totalAssets();
        _withdraw(balance);

        // Check that the balance is 0
        assertEq(strategy.totalAssets(), 0);
    }

    /**
     * @notice Withdrawal only from manager test
     * @dev Checks that only the manager can withdraw
     */
    function test_Withdraw_RevertIfNotManager() public {
        _deposit(10 ether);

        vm.prank(alice);
        vm.expectRevert(AaveStrategy.AaveStrategy__OnlyManager.selector);
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
        assertEq(strategy.name(), "Aave v3 Strategy");
    }

    /**
     * @notice Asset test
     * @dev Checks that it returns the WETH address
     */
    function test_Asset() public view {
        assertEq(strategy.asset(), WETH);
    }

    /**
     * @notice Available liquidity test
     * @dev Checks that availableLiquidity returns a value
     */
    function test_AvailableLiquidity() public view {
        uint256 liquidity = strategy.availableLiquidity();

        // Aave mainnet should have significant liquidity
        assertGt(liquidity, 0);
    }

    /**
     * @notice totalAssets without deposits test
     * @dev Checks that it returns 0 without deposits
     */
    function test_TotalAssets_ZeroWithoutDeposits() public view {
        assertEq(strategy.totalAssets(), 0);
    }
}
