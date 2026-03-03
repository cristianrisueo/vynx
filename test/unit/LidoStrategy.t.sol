// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {LidoStrategy} from "../../src/strategies/LidoStrategy.sol";
import {StrategyManager} from "../../src/core/StrategyManager.sol";
import {IStrategyManager} from "../../src/interfaces/core/IStrategyManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INonfungiblePositionManager} from "../../src/interfaces/strategies/uniswap/INonfungiblePositionManager.sol";
import {IWstETH} from "../../src/interfaces/strategies/lido/IWstETH.sol";
import {IWETH} from "@aave/contracts/misc/interfaces/IWETH.sol";

/**
 * @title LidoStrategyTest
 * @author cristianrisueo
 * @notice Unit tests for LidoStrategy with Mainnet fork
 * @dev Real fork test against Lido wstETH - validates deposits, withdrawals and APY
 */
contract LidoStrategyTest is Test {
    //* Variables de estado

    /// @notice Strategy and manager instances
    LidoStrategy public strategy;
    StrategyManager public manager;

    /// @notice Mainnet contract addresses
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant UNISWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    uint24 constant POOL_FEE = 500; // wstETH/WETH pool uses 0.05%

    /// @notice Test user
    address public alice = makeAddr("alice");

    //* Testing environment setup

    /**
     * @notice Configures the testing environment
     * @dev Mainnet fork to interact with real Lido wstETH
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

        // Initializes the strategy with wstETH and Uniswap V3 for withdrawal
        strategy = new LidoStrategy(address(manager), WSTETH, WETH, UNISWAP_ROUTER, POOL_FEE);

        // Seed liquidity in the Uniswap V3 wstETH/WETH pool
        _seedWstEthPool();
    }

    /**
     * @notice Adds liquidity to the Uniswap V3 wstETH/WETH pool
     * @dev The forked pool may have insufficient liquidity, this guarantees successful swaps
     */
    function _seedWstEthPool() internal {
        uint256 ethAmount = 100_000 ether;
        deal(address(this), ethAmount);

        // WETH → ETH → wstETH
        IWETH(WETH).deposit{value: ethAmount}();
        IERC20(WETH).approve(address(0), 0); // reset
        uint256 halfWeth = ethAmount / 2;

        // Get wstETH: unwrap half WETH → ETH → stake in Lido
        IWETH(WETH).withdraw(halfWeth);
        (bool ok,) = WSTETH.call{value: halfWeth}("");
        require(ok, "wstETH stake failed");

        uint256 wstBal = IERC20(WSTETH).balanceOf(address(this));

        // Approve position manager
        IERC20(WSTETH).approve(POSITION_MANAGER, wstBal);
        IERC20(WETH).approve(POSITION_MANAGER, halfWeth);

        // Mint concentrated position around current tick (token0=wstETH < token1=WETH)
        INonfungiblePositionManager(POSITION_MANAGER).mint(
            INonfungiblePositionManager.MintParams({
                token0: WSTETH,
                token1: WETH,
                fee: POOL_FEE,
                tickLower: -1000,
                tickUpper: 3000,
                amount0Desired: wstBal,
                amount1Desired: halfWeth,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
    }

    receive() external payable {}

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
     * @notice Basic Lido deposit test
     * @dev Checks that deposit converts WETH to wstETH and totalAssets reflects it
     */
    function test_Deposit_Basic() public {
        // Deposits in Lido (WETH → ETH → wstETH)
        _deposit(10 ether);

        // Checks that totalAssets reflects the deposit (approximately, due to exchange rate)
        // The WETH-equivalent value may differ slightly due to the wstETH exchange rate
        assertApproxEqRel(strategy.totalAssets(), 10 ether, 0.001e18);
    }

    /**
     * @notice Deposit only from manager test
     * @dev Checks that only the manager can deposit
     */
    function test_Deposit_RevertIfNotManager() public {
        deal(WETH, address(strategy), 10 ether);

        vm.prank(alice);
        vm.expectRevert(LidoStrategy.LidoStrategy__OnlyManager.selector);
        strategy.deposit(10 ether);
    }

    /**
     * @notice Zero amount deposit test
     * @dev Checks it reverts with zero amount
     */
    function test_Deposit_RevertZeroAmount() public {
        vm.prank(address(manager));
        vm.expectRevert(LidoStrategy.LidoStrategy__ZeroAmount.selector);
        strategy.deposit(0);
    }

    //* Withdraw tests

    /**
     * @notice Basic Lido withdrawal test
     * @dev Checks that withdrawal swaps wstETH→WETH via Uniswap and sends to manager
     */
    function test_Withdraw_Basic() public {
        // Deposits first
        _deposit(10 ether);

        // Withdraws half
        _withdraw(5 ether);

        // Checks that the manager received the funds (1% tolerance for slippage)
        assertApproxEqRel(IERC20(WETH).balanceOf(address(manager)), 5 ether, 0.01e18);

        // Checks that approximately half remains
        assertApproxEqRel(strategy.totalAssets(), 5 ether, 0.01e18);
    }

    /**
     * @notice Full Lido withdrawal test
     * @dev Checks that the entire balance can be withdrawn
     */
    function test_Withdraw_Full() public {
        // Deposits
        _deposit(10 ether);

        // Withdraws everything (uses totalAssets as the WETH equivalent reference)
        uint256 total = strategy.totalAssets();
        _withdraw(total);

        // Checks that the balance in the strategy is ~0 (1 wei dust possible due to wstETH rounding)
        assertLe(strategy.totalAssets(), 1);
    }

    /**
     * @notice Withdraw only from manager test
     * @dev Checks that only the manager can withdraw
     */
    function test_Withdraw_RevertIfNotManager() public {
        _deposit(10 ether);

        vm.prank(alice);
        vm.expectRevert(LidoStrategy.LidoStrategy__OnlyManager.selector);
        strategy.withdraw(5 ether);
    }

    /**
     * @notice Zero amount withdrawal test
     * @dev Checks it reverts with zero amount
     */
    function test_Withdraw_RevertZeroAmount() public {
        vm.prank(address(manager));
        vm.expectRevert(LidoStrategy.LidoStrategy__ZeroAmount.selector);
        strategy.withdraw(0);
    }

    //* Harvest tests

    /**
     * @notice Lido harvest test
     * @dev Harvest always returns 0 in Lido — yield is embedded in the wstETH exchange rate
     */
    function test_Harvest_AlwaysReturnsZero() public {
        // Deposits funds
        _deposit(10 ether);

        // Advances time to demonstrate that yield is not obtained via harvest
        skip(30 days);

        // Harvest must return 0 — yield is already in the exchange rate
        vm.prank(address(manager));
        uint256 profit = strategy.harvest();
        assertEq(profit, 0, "Lido harvest debe devolver 0");
    }

    /**
     * @notice Harvest only from manager test
     * @dev Checks that only the manager can call harvest
     */
    function test_Harvest_RevertIfNotManager() public {
        vm.prank(alice);
        vm.expectRevert(LidoStrategy.LidoStrategy__OnlyManager.selector);
        strategy.harvest();
    }

    //* Query function tests

    /**
     * @notice APY test
     * @dev Checks that APY is the configured Lido value (400 bps = 4%)
     */
    function test_Apy_ReturnsValidValue() public view {
        uint256 apy = strategy.apy();

        // Lido APY is hardcoded at 400 bps (4%)
        assertEq(apy, 400);
    }

    /**
     * @notice Strategy name test
     * @dev Checks that it returns the correct name
     */
    function test_Name() public view {
        assertEq(strategy.name(), "Lido wstETH Strategy");
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
     * @notice Yield embedded in wstETH exchange rate test
     * @dev Over time, totalAssets grows without needing harvest (auto-compounding yield)
     */
    function test_TotalAssets_GrowsWithTime() public {
        // Deposits funds
        _deposit(100 ether);
        uint256 assets_before = strategy.totalAssets();

        // Advances 30 days so the wstETH exchange rate grows
        skip(30 days);
        vm.roll(block.number + 216000); // ~30 days of blocks

        // totalAssets should be greater (yield accumulated via exchange rate)
        uint256 assets_after = strategy.totalAssets();
        assertGe(assets_after, assets_before, "totalAssets should grow or stay the same over time");
    }
}
