// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {AaveStrategy} from "../../src/strategies/AaveStrategy.sol";
import {StrategyManager} from "../../src/core/StrategyManager.sol";
import {IStrategyManager} from "../../src/interfaces/core/IStrategyManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title AaveStrategyTest
 * @author cristianrisueo
 * @notice Unit tests for AaveStrategy with Mainnet fork
 * @dev Real fork test against Aave v3 - validates deposits, withdrawals and APY
 */
contract AaveStrategyTest is Test {
    //* Variables de estado

    /// @notice Strategy and manager instances
    AaveStrategy public strategy;
    StrategyManager public manager;

    /// @notice Mainnet contract addresses
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_REWARDS = 0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb;
    address constant AAVE_TOKEN = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;
    address constant CURVE_POOL = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;
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
        // Creates a Mainnet fork using the Alchemy endpoint
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        // Initializes manager with Balanced tier parameters
        manager = new StrategyManager(
            WETH,
            IStrategyManager.TierConfig({
                max_allocation_per_strategy: 5000, // 50%
                min_allocation_threshold: 2000, // 20%
                rebalance_threshold: 200, // 2%
                min_tvl_for_rebalance: 8 ether
            })
        );

        // Initializes the strategy with all V1 dependencies
        strategy = new AaveStrategy(
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
    }

    //* Internal helper functions

    /**
     * @notice Helper to deposit into the strategy as manager
     * @param amount Amount to deposit
     */
    function _deposit(uint256 amount) internal {
        // Gives WETH to the strategy and deposits as manager
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

    //* Deposit tests

    /**
     * @notice Basic Aave deposit test
     * @dev Checks that the deposit is performed correctly
     */
    function test_Deposit_Basic() public {
        // Deposits in Aave
        _deposit(10 ether);

        // Checks that totalAssets reflects the deposit
        assertApproxEqRel(strategy.totalAssets(), 10 ether, 0.001e18);

        // Checks that aTokenBalance matches
        assertGt(strategy.totalAssets(), strategy.aTokenBalance());
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

    //* Withdraw tests

    /**
     * @notice Basic Aave withdrawal test
     * @dev Checks that the withdrawal is performed correctly
     */
    function test_Withdraw_Basic() public {
        // Deposits first
        _deposit(10 ether);

        // Withdraws half
        _withdraw(5 ether);

        // Checks that the manager received the funds
        assertApproxEqRel(IERC20(WETH).balanceOf(address(manager)), 5 ether, 0.01e18);

        // Checks that approximately half remains
        assertApproxEqRel(strategy.totalAssets(), 5 ether, 0.001e18);
    }

    /**
     * @notice Full Aave withdrawal test
     * @dev Checks that everything can be withdrawn
     */
    function test_Withdraw_Full() public {
        // Deposits
        _deposit(10 ether);

        // Withdraws everything
        uint256 balance = strategy.totalAssets();
        _withdraw(balance);

        // Checks that the balance is ~0 (1 wei dust possible due to rounding in Curve swap)
        assertLe(strategy.totalAssets(), 1);
    }

    /**
     * @notice Withdraw only from manager test
     * @dev Checks that only the manager can withdraw
     */
    function test_Withdraw_RevertIfNotManager() public {
        _deposit(10 ether);

        vm.prank(alice);
        vm.expectRevert(AaveStrategy.AaveStrategy__OnlyManager.selector);
        strategy.withdraw(5 ether);
    }

    //* Query function tests

    /**
     * @notice APY test
     * @dev Checks that the APY is a reasonable value
     */
    function test_Apy_ReturnsValidValue() public view {
        uint256 apy = strategy.apy();

        // APY should be between 0% and 50% (0 - 5000 bp)
        assertLt(apy, 5000);
    }

    /**
     * @notice Strategy name test
     * @dev Checks that it returns the correct name
     */
    function test_Name() public view {
        assertEq(strategy.name(), "Aave v3 wstETH Strategy");
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
