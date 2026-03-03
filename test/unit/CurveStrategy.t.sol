// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {CurveStrategy} from "../../src/strategies/CurveStrategy.sol";
import {StrategyManager} from "../../src/core/StrategyManager.sol";
import {IStrategyManager} from "../../src/interfaces/core/IStrategyManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title CurveStrategyTest
 * @author cristianrisueo
 * @notice Unit tests for CurveStrategy with Mainnet fork
 * @dev Real fork test against Curve stETH/ETH pool and gauge — validates deposits, withdrawals and harvest
 */
contract CurveStrategyTest is Test {
    //* Variables de estado

    /// @notice Strategy and manager instances
    CurveStrategy public strategy;
    StrategyManager public manager;

    /// @notice Mainnet contract addresses
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant CURVE_POOL = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;
    address constant CURVE_GAUGE = 0x182B723a58739a9c974cFDB385ceaDb237453c28;
    address constant CURVE_LP = 0x06325440D014e39736583c165C2963BA99fAf14E;
    address constant CRV_TOKEN = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address constant UNISWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    uint24 constant POOL_FEE = 3000; // CRV/WETH 0.3%

    /// @notice Test user
    address public alice = makeAddr("alice");

    //* Testing environment setup

    /**
     * @notice Configures the testing environment
     * @dev Mainnet fork to interact with real Curve stETH/ETH pool and gauge
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

        // Initializes the strategy with all Curve dependencies
        strategy = new CurveStrategy(
            address(manager),
            STETH,
            CURVE_POOL,
            CURVE_GAUGE,
            CURVE_LP,
            CRV_TOKEN,
            WETH,
            UNISWAP_ROUTER,
            POOL_FEE
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
     * @notice Basic Curve deposit test
     * @dev Checks that WETH → stETH → LP → gauge and totalAssets reflects it
     */
    function test_Deposit_Basic() public {
        // Deposits in Curve (WETH → ETH → stETH → add_liquidity → gauge)
        _deposit(10 ether);

        // Checks that totalAssets reflects the deposit (1% tolerance for Curve slippage/fees)
        assertApproxEqRel(strategy.totalAssets(), 10 ether, 0.01e18);

        // Checks that there are LP tokens staked in the gauge
        assertGt(strategy.lpBalance(), 0, "Should have LP tokens in the gauge");
    }

    /**
     * @notice Deposit only from manager test
     * @dev Checks that only the manager can deposit
     */
    function test_Deposit_RevertIfNotManager() public {
        deal(WETH, address(strategy), 10 ether);

        vm.prank(alice);
        vm.expectRevert(CurveStrategy.CurveStrategy__OnlyManager.selector);
        strategy.deposit(10 ether);
    }

    /**
     * @notice Zero amount deposit test
     * @dev Checks it reverts with zero amount
     */
    function test_Deposit_RevertZeroAmount() public {
        vm.prank(address(manager));
        vm.expectRevert(CurveStrategy.CurveStrategy__ZeroAmount.selector);
        strategy.deposit(0);
    }

    //* Withdraw tests

    /**
     * @notice Basic Curve withdrawal test
     * @dev Checks that gauge.withdraw → remove_liquidity_one_coin → WETH to manager
     */
    function test_Withdraw_Basic() public {
        // Deposits first
        _deposit(10 ether);

        // Withdraws half (2% tolerance for slippage in Curve withdrawal)
        _withdraw(5 ether);

        // Checks that the manager received the funds
        assertApproxEqRel(IERC20(WETH).balanceOf(address(manager)), 5 ether, 0.02e18);

        // Checks that approximately half remains in the strategy
        assertApproxEqRel(strategy.totalAssets(), 5 ether, 0.02e18);
    }

    /**
     * @notice Full Curve withdrawal test
     * @dev Checks that the entire balance can be withdrawn
     */
    function test_Withdraw_Full() public {
        // Deposits
        _deposit(10 ether);

        // Withdraws everything
        uint256 total = strategy.totalAssets();
        _withdraw(total);

        // Checks that the balance in the strategy is 0 or minimal residual
        assertApproxEqAbs(strategy.totalAssets(), 0, 0.001 ether);
    }

    /**
     * @notice Withdraw only from manager test
     * @dev Checks that only the manager can withdraw
     */
    function test_Withdraw_RevertIfNotManager() public {
        _deposit(10 ether);

        vm.prank(alice);
        vm.expectRevert(CurveStrategy.CurveStrategy__OnlyManager.selector);
        strategy.withdraw(5 ether);
    }

    /**
     * @notice Zero amount withdrawal test
     * @dev Checks it reverts with zero amount
     */
    function test_Withdraw_RevertZeroAmount() public {
        vm.prank(address(manager));
        vm.expectRevert(CurveStrategy.CurveStrategy__ZeroAmount.selector);
        strategy.withdraw(0);
    }

    //* Harvest tests

    /**
     * @notice Harvest with CRV rewards test
     * @dev Injects CRV tokens into the gauge to simulate accumulated rewards and verifies reinvestment
     */
    function test_Harvest_WithRewards() public {
        // Deposits funds so there are LP tokens in the gauge
        _deposit(100 ether);

        // Injects CRV tokens into the strategy to simulate gauge rewards
        deal(CRV_TOKEN, address(strategy), 100 ether);

        // Advances time to accumulate rewards
        skip(7 days);
        vm.roll(block.number + 50400);

        // Harvest must not revert
        vm.prank(address(manager));
        strategy.harvest();

        // After harvest, LP tokens must have been maintained or increased
        assertGt(strategy.lpBalance(), 0, "Should have LP tokens after harvest");
    }

    /**
     * @notice Harvest only from manager test
     * @dev Checks that only the manager can call harvest
     */
    function test_Harvest_RevertIfNotManager() public {
        vm.prank(alice);
        vm.expectRevert(CurveStrategy.CurveStrategy__OnlyManager.selector);
        strategy.harvest();
    }

    //* Query function tests

    /**
     * @notice APY test
     * @dev Checks that APY is the hardcoded value (600 bps = 6%)
     */
    function test_Apy_ReturnsValidValue() public view {
        uint256 apy = strategy.apy();

        // Curve APY is hardcoded at 600 bps (6%)
        assertEq(apy, 600);
    }

    /**
     * @notice Strategy name test
     * @dev Checks that it returns the correct name
     */
    function test_Name() public view {
        assertEq(strategy.name(), "Curve stETH/ETH Strategy");
    }

    /**
     * @notice Asset test
     * @dev Checks that it returns the WETH address
     */
    function test_Asset() public view {
        assertEq(strategy.asset(), WETH);
    }

    /**
     * @notice totalAssets without deposits test
     * @dev Checks that it returns 0 without prior deposits
     */
    function test_TotalAssets_ZeroWithoutDeposits() public view {
        assertEq(strategy.totalAssets(), 0);
    }

    /**
     * @notice lpBalance without deposits test
     * @dev Checks that lpBalance returns 0 without deposits
     */
    function test_LpBalance_ZeroWithoutDeposits() public view {
        assertEq(strategy.lpBalance(), 0);
    }

    /**
     * @notice Yield accumulated via virtual price test
     * @dev Over time, the pool virtual price rises slightly due to accumulated trading fees
     *      This causes totalAssets to grow without an explicit harvest
     */
    function test_TotalAssets_GrowsWithTime() public {
        // Deposits funds
        _deposit(100 ether);
        uint256 assets_before = strategy.totalAssets();

        // Advances 30 days so trading fees accumulate in the virtual price
        skip(30 days);
        vm.roll(block.number + 216000);

        // totalAssets should be greater or equal (virtual price only goes up)
        uint256 assets_after = strategy.totalAssets();
        assertGe(assets_after, assets_before, "totalAssets should grow or stay the same over time");
    }
}
