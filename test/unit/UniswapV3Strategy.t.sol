// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {UniswapV3Strategy} from "../../src/strategies/UniswapV3Strategy.sol";
import {StrategyManager} from "../../src/core/StrategyManager.sol";
import {IStrategyManager} from "../../src/interfaces/core/IStrategyManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title UniswapV3StrategyTest
 * @author cristianrisueo
 * @notice Unit tests for UniswapV3Strategy with Mainnet fork
 * @dev Real fork test against Uniswap V3 WETH/USDC pool — validates deposits, withdrawals and harvest
 */
contract UniswapV3StrategyTest is Test {
    //* Variables de estado

    /// @notice Strategy and manager instances
    UniswapV3Strategy public strategy;
    StrategyManager public manager;

    /// @notice Mainnet contract addresses
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant UNI_POS_MGR = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant UNI_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant WETH_USDC_POOL = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;

    /// @notice Test user
    address public alice = makeAddr("alice");

    //* Testing environment setup

    /**
     * @notice Configures the testing environment
     * @dev Mainnet fork to interact with real Uniswap V3 WETH/USDC pool
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

        // Initializes the strategy with the WETH/USDC 0.05% pool
        strategy = new UniswapV3Strategy(
            address(manager),
            UNI_POS_MGR,
            UNI_ROUTER,
            WETH_USDC_POOL,
            WETH,
            USDC
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
     * @notice Basic Uniswap V3 deposit test
     * @dev Checks that WETH is converted into an LP NFT position and totalAssets reflects it
     */
    function test_Deposit_Basic() public {
        // Deposits in Uniswap V3 (50% swap WETH→USDC + mint position NFT)
        _deposit(10 ether);

        // Checks that a position was created (token_id != 0)
        assertGt(strategy.token_id(), 0, "An NFT position should have been created");

        // Checks that totalAssets reflects the deposit with 5% tolerance
        // (for the 50% swap + slippage + range concentration)
        assertApproxEqRel(strategy.totalAssets(), 10 ether, 0.05e18);
    }

    /**
     * @notice Multiple deposits increase the existing position test
     * @dev The second deposit must increase the liquidity of the existing NFT
     */
    function test_Deposit_IncreasesExistingPosition() public {
        // First deposit creates the position
        _deposit(10 ether);
        uint256 token_id_first = strategy.token_id();
        uint256 assets_after_first = strategy.totalAssets();

        // Second deposit increases the existing position
        _deposit(10 ether);

        // token_id must be the same (NFT is reused)
        assertEq(strategy.token_id(), token_id_first, "The token_id must not change on successive deposits");

        // totalAssets must have increased approximately by the second deposit
        assertGt(strategy.totalAssets(), assets_after_first, "totalAssets should grow with the second deposit");
    }

    /**
     * @notice Deposit only from manager test
     * @dev Checks that only the manager can deposit
     */
    function test_Deposit_RevertIfNotManager() public {
        deal(WETH, address(strategy), 10 ether);

        vm.prank(alice);
        vm.expectRevert(UniswapV3Strategy.UniswapV3Strategy__OnlyManager.selector);
        strategy.deposit(10 ether);
    }

    /**
     * @notice Zero amount deposit test
     * @dev Checks it reverts with zero amount
     */
    function test_Deposit_RevertZeroAmount() public {
        vm.prank(address(manager));
        vm.expectRevert(UniswapV3Strategy.UniswapV3Strategy__ZeroAmount.selector);
        strategy.deposit(0);
    }

    //* Withdraw tests

    /**
     * @notice Basic Uniswap V3 withdrawal test
     * @dev Checks that decreaseLiquidity → collect → swap USDC→WETH → manager
     */
    function test_Withdraw_Basic() public {
        // Deposits first
        _deposit(10 ether);

        // Withdraws half (5% tolerance for slippage in USDC→WETH swap)
        _withdraw(5 ether);

        // Checks that the manager received the funds
        assertApproxEqRel(IERC20(WETH).balanceOf(address(manager)), 5 ether, 0.05e18);
    }

    /**
     * @notice Full withdrawal burns the NFT test
     * @dev When the position is left empty, the NFT must be burned and token_id = 0
     */
    function test_Withdraw_Full_BurnsNFT() public {
        // Deposits
        _deposit(10 ether);
        assertGt(strategy.token_id(), 0, "Should have an NFT");

        // Withdraws everything
        uint256 total = strategy.totalAssets();
        _withdraw(total);

        // The NFT must have been burned
        assertEq(strategy.token_id(), 0, "The NFT must be burned after full withdrawal");
    }

    /**
     * @notice Withdraw only from manager test
     * @dev Checks that only the manager can withdraw
     */
    function test_Withdraw_RevertIfNotManager() public {
        _deposit(10 ether);

        vm.prank(alice);
        vm.expectRevert(UniswapV3Strategy.UniswapV3Strategy__OnlyManager.selector);
        strategy.withdraw(5 ether);
    }

    /**
     * @notice Zero amount withdrawal test
     * @dev Checks it reverts with zero amount
     */
    function test_Withdraw_RevertZeroAmount() public {
        vm.prank(address(manager));
        vm.expectRevert(UniswapV3Strategy.UniswapV3Strategy__ZeroAmount.selector);
        strategy.withdraw(0);
    }

    /**
     * @notice Withdraw without position test
     * @dev Checks it reverts if there is no position (token_id == 0)
     */
    function test_Withdraw_RevertNoPosition() public {
        vm.prank(address(manager));
        vm.expectRevert(UniswapV3Strategy.UniswapV3Strategy__InsufficientLiquidity.selector);
        strategy.withdraw(1 ether);
    }

    //* Harvest tests

    /**
     * @notice Harvest collects accumulated fees test
     * @dev After pool activity time, collect gathers fees in both tokens
     */
    function test_Harvest_CollectsFees() public {
        // Deposits funds to have an active position
        _deposit(100 ether);

        // Advances time to accumulate fees (simulating volume)
        skip(7 days);
        vm.roll(block.number + 50400);

        // Harvest must not revert
        vm.prank(address(manager));
        strategy.harvest();

        // The position must still be active (token_id still exists or was reinvested)
        // We don't verify exact profit since it depends on real pool volume
    }

    /**
     * @notice Harvest only from manager test
     * @dev Checks that only the manager can call harvest
     */
    function test_Harvest_RevertIfNotManager() public {
        vm.prank(alice);
        vm.expectRevert(UniswapV3Strategy.UniswapV3Strategy__OnlyManager.selector);
        strategy.harvest();
    }

    //* Query function tests

    /**
     * @notice APY test
     * @dev Checks that APY is the hardcoded value (1400 bps = 14%)
     */
    function test_Apy_ReturnsValidValue() public view {
        uint256 apy = strategy.apy();

        // Uniswap V3 APY is hardcoded at 1400 bps (14%)
        assertEq(apy, 1400);
    }

    /**
     * @notice Strategy name test
     * @dev Checks that it returns the correct name
     */
    function test_Name() public view {
        assertEq(strategy.name(), "Uniswap V3 WETH/USDC Strategy");
    }

    /**
     * @notice Asset test
     * @dev Checks that it returns the WETH address
     */
    function test_Asset() public view {
        assertEq(strategy.asset(), WETH);
    }

    /**
     * @notice totalAssets without position test
     * @dev Checks that it returns 0 when there is no position (token_id == 0)
     */
    function test_TotalAssets_ZeroWithoutDeposits() public view {
        assertEq(strategy.totalAssets(), 0);
        assertEq(strategy.token_id(), 0);
    }

    /**
     * @notice Position ticks test
     * @dev Checks that ticks are configured correctly (lower < upper)
     */
    function test_Ticks_AreValid() public view {
        assertLt(strategy.lower_tick(), strategy.upper_tick(), "lower_tick debe ser menor que upper_tick");
    }
}
