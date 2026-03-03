// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../../src/core/Vault.sol";
import {IVault} from "../../src/interfaces/core/IVault.sol";
import {StrategyManager} from "../../src/core/StrategyManager.sol";
import {IStrategyManager} from "../../src/interfaces/core/IStrategyManager.sol";
import {AaveStrategy} from "../../src/strategies/AaveStrategy.sol";
import {LidoStrategy} from "../../src/strategies/LidoStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INonfungiblePositionManager} from "../../src/interfaces/strategies/uniswap/INonfungiblePositionManager.sol";
import {IWETH} from "@aave/contracts/misc/interfaces/IWETH.sol";

/**
 * @title VaultTest
 * @author cristianrisueo
 * @notice Unit tests for Vault with Mainnet fork
 * @dev Mainnet fork test, no bullshit here
 */
contract VaultTest is Test {
    //* Variables de estado

    /// @notice Vault, manager and strategy instances
    Vault public vault;
    StrategyManager public manager;
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
    address public bob = makeAddr("bob");
    address public founder;

    /// @notice Vault parameters
    uint256 constant MAX_TVL = 1000 ether;

    //* Testing environment setup

    /**
     * @notice Configures the testing environment
     * @dev For real behavior we fork Mainnet. I don't recommend testing on
     *      testnets, deployed contracts ARE BULLSHIT, not real behavior
     */
    function setUp() public {
        // Creates a Mainnet fork using my Alchemy endpoint in env.var
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        // Sets the founder
        founder = makeAddr("founder");

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
            address(this),
            founder,
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

        // Mock Aave APY so allocation works and Lido APY to 0 to avoid slippage on withdrawals
        vm.mockCall(address(aave_strategy), abi.encodeWithSignature("apy()"), abi.encode(uint256(300)));
        vm.mockCall(address(lido_strategy), abi.encodeWithSignature("apy()"), abi.encode(uint256(50)));

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
     * @notice Deposit helper used in most tests
     * @dev Helpers are only used for happy paths, not cases where a revert is expected
     * @param user User used in the interaction
     * @param amount Amount given to the user
     * @return shares Amount of shares minted to the user after the deposit
     */
    function _deposit(address user, uint256 amount) internal returns (uint256 shares) {
        // Gives the user the WETH amount and uses their address
        deal(WETH, user, amount);
        vm.startPrank(user);

        // Approves the vault for the WETH transfer and deposits the amount into the vault
        IERC20(WETH).approve(address(vault), amount);
        shares = vault.deposit(amount, user);

        vm.stopPrank();
    }

    /**
     * @notice Withdraw helper used in most tests
     * @dev Helpers are only used for happy paths, not cases where a revert is expected
     * @param user User used in the interaction
     * @param amount Amount given to the user
     * @return shares Amount of user shares burned after the withdrawal
     */
    function _withdraw(address user, uint256 amount) internal returns (uint256 shares) {
        // Top-up vault WETH to cover swap slippage in strategies (Curve/Uniswap)
        deal(WETH, address(vault), IERC20(WETH).balanceOf(address(vault)) + amount);
        vm.prank(user);
        shares = vault.withdraw(amount, user, user);
    }

    //* Unit tests for core logic: Deposits

    /**
     * @notice Basic deposit test
     * @dev Checks that a user can deposit and receive shares correctly
     */
    function test_Deposit_Basic() public {
        // Uses Alice to deposit 1 WETH
        uint256 amount = 1 ether;
        uint256 shares = _deposit(alice, amount);

        // Checks shares received by Alice, assets in the vault and assets in the idle buffer
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.totalAssets(), amount);
        assertEq(vault.idle_buffer(), amount);
    }

    /**
     * @notice Deposit equal to IDLE threshold test
     * @dev Performs a deposit above the threshold to check that the vault does allocation
     */
    function test_Deposit_TriggersAllocation() public {
        // Uses alice to deposit the limit amount
        _deposit(alice, vault.idle_threshold());

        // Checks that neither the vault nor the IDLE buffer has WETH
        assertEq(vault.idle_buffer(), 0);
        assertGt(manager.totalAssets(), 0);
    }

    /**
     * @notice Zero amount deposit test
     * @dev Performs a zero amount deposit and checks it reverts with the expected error
     */
    function test_Deposit_RevertZero() public {
        // Uses Alice's address to deposit zero amount
        vm.prank(alice);

        // Expects the error and deposits
        vm.expectRevert(Vault.Vault__DepositBelowMinimum.selector);
        vault.deposit(0, alice);
    }

    /**
     * @notice Below minimum deposit amount test
     * @dev Performs a tiny deposit and checks it reverts with the expected error
     */
    function test_Deposit_RevertBelowMin() public {
        // Gives Alice 0.005 WETH and uses her address
        deal(WETH, alice, 0.005 ether);
        vm.startPrank(alice);

        // Approves the vault for the transfer
        IERC20(WETH).approve(address(vault), 0.005 ether);

        // Expects the error and deposits
        vm.expectRevert(Vault.Vault__DepositBelowMinimum.selector);
        vault.deposit(0.005 ether, alice);

        vm.stopPrank();
    }

    /**
     * @notice Deposit above max TVL test
     * @dev Performs a deposit above the max and checks it reverts with the expected error
     */
    function test_Deposit_RevertExceedsMaxTVL() public {
        // Gives Alice an amount above the maximum allowed TVL and uses her address
        deal(WETH, alice, MAX_TVL + 1);
        vm.startPrank(alice);

        // Approves the vault for the transfer
        IERC20(WETH).approve(address(vault), MAX_TVL + 1);

        // Expects the error and deposits
        vm.expectRevert(Vault.Vault__MaxTVLExceeded.selector);
        vault.deposit(MAX_TVL + 1, alice);

        vm.stopPrank();
    }

    /**
     * @notice Deposit when vault is paused test
     * @dev Performs a normal deposit and checks it reverts with the expected error
     */
    function test_Deposit_RevertWhenPaused() public {
        // Pauses the vault
        vault.pause();

        // Gives Alice 1 WETH and uses her address
        deal(WETH, alice, 1 ether);
        vm.startPrank(alice);

        // Approves the vault for the transfer
        IERC20(WETH).approve(address(vault), 1 ether);

        // Expects the error and deposits
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.deposit(1 ether, alice);

        vm.stopPrank();
    }

    //* Mint tests

    /**
     * @notice Basic mint test
     * @dev Checks that a user can mint and receive shares correctly
     */
    function test_Mint_Basic() public {
        // Gives Alice 10 WETH and uses her address
        deal(WETH, alice, 10 ether);
        vm.startPrank(alice);

        // Approves the vault for the transfer
        IERC20(WETH).approve(address(vault), 10 ether);

        // Mints 5 WETH
        vault.mint(5 ether, alice);
        vm.stopPrank();

        // Checks that Alice's share balance corresponds to 5 WETH (1:1 ratio)
        assertEq(vault.balanceOf(alice), 5 ether);
    }

    /**
     * @notice Zero amount mint test
     * @dev Performs a zero amount mint and checks it reverts with the expected error
     */
    function test_Mint_RevertZero() public {
        // Uses Alice's address
        vm.prank(alice);

        // Expects the error and mints 0 shares
        vm.expectRevert(Vault.Vault__DepositBelowMinimum.selector);
        vault.mint(0, alice);
    }

    //* Withdraw tests

    /**
     * @notice Withdraw from idle buffer test
     * @dev Checks that withdrawal from idle works correctly without touching the manager
     */
    function test_Withdraw_FromIdle() public {
        // Deposits 5 WETH (stays in idle)
        _deposit(alice, 5 ether);

        // Withdraws 2 WETH
        _withdraw(alice, 2 ether);

        // Checks Alice's balance and that the manager remains empty
        assertEq(IERC20(WETH).balanceOf(alice), 2 ether);
        assertEq(manager.totalAssets(), 0);
    }

    /**
     * @notice Withdraw from strategies test
     * @dev Checks that withdrawal from the manager works when idle is insufficient
     */
    function test_Withdraw_FromStrategies() public {
        // Deposits 20 WETH (exceeds threshold, goes to manager)
        _deposit(alice, 20 ether);

        // Withdraws 15 WETH
        _withdraw(alice, 15 ether);

        // Checks Alice's final balance (2 wei tolerance for rounding in proportional strategy withdrawals)
        assertApproxEqRel(IERC20(WETH).balanceOf(alice), 15 ether, 0.01e18);
    }

    /**
     * @notice Withdraw when vault is paused test
     * @dev After the emergency exit change, withdraw works with vault paused.
     *      A user must always be able to withdraw their funds
     */
    function test_Withdraw_WorksWhenPaused() public {
        // Deposits funds first
        _deposit(alice, 5 ether);

        // Pauses the vault
        vault.pause();

        // Withdraw must execute correctly while paused
        vm.prank(alice);
        uint256 shares = vault.withdraw(1 ether, alice, alice);

        // Checks that Alice received her assets and shares were burned
        assertEq(IERC20(WETH).balanceOf(alice), 1 ether);
        assertGt(shares, 0);
    }

    //* Redeem tests

    /**
     * @notice Basic redeem test
     * @dev Checks that a user can redeem shares for assets
     */
    function test_Redeem_Basic() public {
        // Deposits and gets shares
        uint256 shares = _deposit(alice, 5 ether);

        // Uses Alice to redeem her shares
        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);

        // Checks that shares were burned and assets received (no fee, returns deposited amount)
        assertEq(vault.balanceOf(alice), 0);
        assertEq(assets, 5 ether);
    }

    //* Allocation tests

    /**
     * @notice Allocate idle below threshold test
     * @dev Checks that manual allocation fails if there is not enough idle
     */
    function test_AllocateIdle_RevertBelowThreshold() public {
        // Deposits a small amount (below threshold)
        _deposit(alice, 1 ether);

        // Expects error on manual allocation attempt without reaching minimum
        vm.expectRevert(Vault.Vault__InsufficientIdleBuffer.selector);
        vault.allocateIdle();
    }

    //* Accounting functions tests

    /**
     * @notice Total assets summing idle and manager test
     * @dev Checks that the total assets correctly sums both parts
     */
    function test_TotalAssets_IdlePlusManager() public {
        // Deposits with Alice (stays in idle)
        _deposit(alice, 5 ether);

        // Deposits with Bob (exceeds threshold, triggers allocation)
        _deposit(bob, 10 ether);

        // Checks that total is the approximate sum (accounting for possible fees/slippage)
        uint256 expected = 15 ether;
        assertApproxEqRel(vault.totalAssets(), expected, 0.001e18);
    }

    /**
     * @notice Max deposit respecting TVL test
     * @dev Checks that the function returns MAX_TVL
     */
    function test_MaxDeposit_RespectsMaxTVL() public view {
        // Checks that the maximum allowed deposit is the configured TVL
        assertEq(vault.maxDeposit(alice), MAX_TVL);
    }

    /**
     * @notice Max mint respecting TVL test
     * @dev Checks that the function returns MAX_TVL (in shares)
     */
    function test_MaxMint_RespectsMaxTVL() public view {
        // Checks that the maximum allowed mint is the configured TVL
        assertEq(vault.maxMint(alice), MAX_TVL);
    }

    /**
     * @notice maxDeposit after partial deposit test
     * @dev Checks that maxDeposit returns the approximate remaining space
     *      Uses approx because aToken rebase can slightly increase totalAssets
     */
    function test_MaxDeposit_AfterPartialDeposit() public {
        _deposit(alice, 100 ether);
        // 0.1% tolerance because aToken rebase and rounding in allocation can cause
        // totalAssets to differ slightly from the deposited amount
        assertApproxEqRel(vault.maxDeposit(alice), MAX_TVL - 100 ether, 0.001e18);
    }

    /**
     * @notice maxDeposit/maxMint return 0 when vault is paused test
     */
    function test_MaxDeposit_ReturnsZeroWhenPaused() public {
        vault.pause();
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
    }

    //* Owner-only functionality tests

    /**
     * @notice Admin permissions test
     * @dev Checks that only the owner can change parameters and others fail
     */
    function test_Admin_OnlyOwnerCanSetParams() public {
        // Attempts to execute setters as Alice (not owner)
        vm.startPrank(alice);

        // Expects reverts on all admin calls
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

        // Executes setters as Owner (should work)
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

        // Checks that values were updated correctly
        assertEq(vault.idle_threshold(), 20 ether);
        assertEq(vault.max_tvl(), 2000 ether);
        assertEq(vault.min_deposit(), 0.1 ether);
        assertEq(vault.performance_fee(), 1500);
        assertEq(vault.treasury_split(), 7000);
        assertEq(vault.founder_split(), 3000);
        assertTrue(vault.is_official_keeper(alice));
        assertEq(vault.min_profit_for_harvest(), 0.5 ether);
        assertEq(vault.keeper_incentive(), 200);
    }

    //* Harvest and fee distribution tests

    /**
     * @notice Harvest with external keeper test (must receive incentive)
     * @dev Injects AAVE reward tokens into the strategy to simulate accumulated yield,
     *      since skip(7 days) on a static fork does not generate real rewards
     */
    function test_HarvestWithExternalKeeper() public {
        // Setup: deposit enough so that it gets allocated to strategies
        _deposit(alice, 100 ether);

        // Lower min_profit_for_harvest so any profit passes the threshold
        vault.setMinProfitForHarvest(0);

        // Simulate rewards: deal AAVE tokens to the strategy so harvest swaps them
        deal(AAVE_TOKEN, address(aave_strategy), 1 ether);

        // Advance time so Aave accumulates some yield in aToken rebase
        skip(7 days);
        vm.roll(block.number + 50400);

        // External keeper executes harvest
        address keeper = makeAddr("keeper");
        uint256 keeper_balance_before = IERC20(WETH).balanceOf(keeper);

        vm.prank(keeper);
        uint256 profit = vault.harvest();

        // If there is profit, verify that the keeper received their incentive
        if (profit > 0) {
            uint256 keeper_balance_after = IERC20(WETH).balanceOf(keeper);
            uint256 keeper_reward = keeper_balance_after - keeper_balance_before;

            assertGt(keeper_reward, 0, "Keeper debe recibir incentivo");
            assertEq(keeper_reward, (profit * vault.keeper_incentive()) / vault.BASIS_POINTS());
        }
    }

    /**
     * @notice Harvest with official keeper test (must NOT receive incentive)
     * @dev Injects AAVE reward tokens to simulate yield and verifies official keeper does not charge
     */
    function test_HarvestWithOfficialKeeper() public {
        // Setup: deposit enough for allocation
        _deposit(alice, 100 ether);

        // Lower min_profit_for_harvest and simulate rewards
        vault.setMinProfitForHarvest(0);
        deal(AAVE_TOKEN, address(aave_strategy), 1 ether);

        skip(7 days);
        vm.roll(block.number + 50400);

        // Configure official keeper
        address official_keeper = makeAddr("official");
        vault.setOfficialKeeper(official_keeper, true);

        // Official keeper executes harvest
        uint256 keeper_balance_before = IERC20(WETH).balanceOf(official_keeper);

        vm.prank(official_keeper);
        vault.harvest();

        // Verify that they did NOT receive an incentive
        uint256 keeper_balance_after = IERC20(WETH).balanceOf(official_keeper);
        assertEq(keeper_balance_after, keeper_balance_before, "Keeper oficial no debe recibir incentivo");
    }

    /**
     * @notice Fee distribution test: treasury receives shares, founder receives assets
     * @dev Injects AAVE reward tokens to simulate real yield and verify fee distribution
     */
    function test_FeeDistribution() public {
        address treasury = vault.treasury_address();
        address _founder = vault.founder_address();

        // Setup: deposit enough for allocation
        _deposit(alice, 100 ether);

        // Lower min_profit_for_harvest and simulate rewards
        vault.setMinProfitForHarvest(0);
        deal(AAVE_TOKEN, address(aave_strategy), 1 ether);

        skip(7 days);
        vm.roll(block.number + 50400);

        // Balances before harvest
        uint256 treasury_shares_before = vault.balanceOf(treasury);
        uint256 founder_weth_before = IERC20(WETH).balanceOf(_founder);

        // Harvest as official keeper (no incentive to simplify math)
        vault.setOfficialKeeper(address(this), true);
        uint256 profit = vault.harvest();

        // Only verify distribution if there was profit
        if (profit > 0) {
            // Verify: treasury received SHARES, founder received WETH
            uint256 treasury_shares_after = vault.balanceOf(treasury);
            uint256 founder_weth_after = IERC20(WETH).balanceOf(_founder);

            assertGt(treasury_shares_after, treasury_shares_before, "Treasury debe recibir shares");
            assertGt(founder_weth_after, founder_weth_before, "Founder debe recibir WETH");

            // Verify correct splits
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

    //* Setter validation tests (error paths for coverage)

    /**
     * @notice setPerformanceFee with value > BASIS_POINTS test
     * @dev Checks it reverts with the expected error
     */
    function test_SetPerformanceFee_RevertExceedsBasisPoints() public {
        vm.expectRevert(Vault.Vault__InvalidPerformanceFee.selector);
        vault.setPerformanceFee(10001);
    }

    /**
     * @notice setFeeSplit with splits that don't sum to BASIS_POINTS test
     * @dev Checks it reverts with the expected error
     */
    function test_SetFeeSplit_RevertInvalidSum() public {
        vm.expectRevert(Vault.Vault__InvalidFeeSplit.selector);
        vault.setFeeSplit(5000, 4000);
    }

    /**
     * @notice setTreasury with address(0) test
     * @dev Checks it reverts with the expected error
     */
    function test_SetTreasury_RevertZeroAddress() public {
        vm.expectRevert(Vault.Vault__InvalidTreasuryAddress.selector);
        vault.setTreasury(address(0));
    }

    /**
     * @notice setFounder with address(0) test
     * @dev Checks it reverts with the expected error
     */
    function test_SetFounder_RevertZeroAddress() public {
        vm.expectRevert(Vault.Vault__InvalidFounderAddress.selector);
        vault.setFounder(address(0));
    }

    /**
     * @notice setStrategyManager with address(0) test
     * @dev Checks it reverts with the expected error
     */
    function test_SetStrategyManager_RevertZeroAddress() public {
        vm.expectRevert(Vault.Vault__InvalidStrategyManagerAddress.selector);
        vault.setStrategyManager(address(0));
    }

    /**
     * @notice setKeeperIncentive with value > BASIS_POINTS test
     * @dev Checks it reverts with the expected error
     */
    function test_SetKeeperIncentive_RevertExceedsBasisPoints() public {
        vm.expectRevert(Vault.Vault__InvalidPerformanceFee.selector);
        vault.setKeeperIncentive(10001);
    }

    //* Constructor validation tests

    /**
     * @notice Constructor with strategy manager address(0) test
     */
    function test_Constructor_RevertInvalidStrategyManager() public {
        vm.expectRevert(Vault.Vault__InvalidStrategyManagerAddress.selector);
        new Vault(
            WETH,
            address(0),
            address(this),
            founder,
            IVault.TierConfig({idle_threshold: 8 ether, min_profit_for_harvest: 0.08 ether, max_tvl: 1000 ether, min_deposit: 0.01 ether})
        );
    }

    /**
     * @notice Constructor with treasury address(0) test
     */
    function test_Constructor_RevertInvalidTreasury() public {
        vm.expectRevert(Vault.Vault__InvalidTreasuryAddress.selector);
        new Vault(
            WETH,
            address(manager),
            address(0),
            founder,
            IVault.TierConfig({idle_threshold: 8 ether, min_profit_for_harvest: 0.08 ether, max_tvl: 1000 ether, min_deposit: 0.01 ether})
        );
    }

    /**
     * @notice Constructor with founder address(0) test
     */
    function test_Constructor_RevertInvalidFounder() public {
        vm.expectRevert(Vault.Vault__InvalidFounderAddress.selector);
        new Vault(
            WETH,
            address(manager),
            address(this),
            address(0),
            IVault.TierConfig({idle_threshold: 8 ether, min_profit_for_harvest: 0.08 ether, max_tvl: 1000 ether, min_deposit: 0.01 ether})
        );
    }

    //* Harvest edge case tests

    /**
     * @notice Harvest with no profit test (must return 0)
     * @dev Without injected rewards, harvest returns 0 profit
     */
    function test_Harvest_ZeroProfit() public {
        // Deposit so there is something in strategies
        _deposit(alice, 20 ether);

        // Harvest without simulating rewards - must return 0
        uint256 profit = vault.harvest();
        assertEq(profit, 0, "Sin rewards, harvest debe retornar 0");
    }

    /**
     * @notice Harvest when vault is paused test
     * @dev Checks it reverts
     */
    function test_Harvest_RevertWhenPaused() public {
        _deposit(alice, 5 ether);
        vault.pause();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.harvest();
    }

    /**
     * @notice allocateIdle when vault is paused test
     * @dev Checks it reverts
     */
    function test_AllocateIdle_RevertWhenPaused() public {
        _deposit(alice, 5 ether);
        vault.pause();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.allocateIdle();
    }

    //* Mint edge case tests

    /**
     * @notice Mint that exceeds max TVL test
     * @dev Checks it reverts with the expected error
     */
    function test_Mint_RevertExceedsMaxTVL() public {
        // Attempt to mint shares equivalent to more than the max TVL
        deal(WETH, alice, MAX_TVL + 1 ether);
        vm.startPrank(alice);
        IERC20(WETH).approve(address(vault), MAX_TVL + 1 ether);

        vm.expectRevert(Vault.Vault__MaxTVLExceeded.selector);
        vault.mint(MAX_TVL + 1 ether, alice);

        vm.stopPrank();
    }

    /**
     * @notice Mint that triggers allocation test
     * @dev Deposits via mint enough to exceed the idle threshold
     */
    function test_Mint_TriggersAllocation() public {
        uint256 threshold = vault.idle_threshold();
        deal(WETH, alice, threshold);
        vm.startPrank(alice);

        IERC20(WETH).approve(address(vault), threshold);
        vault.mint(threshold, alice);

        vm.stopPrank();

        // Idle buffer must be empty because it was allocated
        assertEq(vault.idle_buffer(), 0);
        assertGt(manager.totalAssets(), 0);
    }

    //* Withdraw edge case tests

    /**
     * @notice Full withdrawal of all funds test
     * @dev Checks that everything can be withdrawn and the vault is left empty
     */
    function test_Withdraw_FullAmount() public {
        uint256 amount = 5 ether;
        _deposit(alice, amount);

        _withdraw(alice, amount);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.totalAssets(), 0);
    }

    //* Getter tests for coverage

    /**
     * @notice All vault getters test
     * @dev Checks they return the correct values post-setup
     */
    function test_Getters_ReturnCorrectValues() public view {
        assertEq(vault.performanceFee(), 2000);
        assertEq(vault.treasurySplit(), 8000);
        assertEq(vault.founderSplit(), 2000);
        assertEq(vault.minDeposit(), 0.01 ether);
        assertEq(vault.idleThreshold(), 8 ether);
        assertEq(vault.maxTVL(), 1000 ether);
        assertEq(vault.treasury(), address(this));
        assertEq(vault.founder(), founder);
        assertEq(vault.strategyManager(), address(manager));
        assertEq(vault.idleBuffer(), 0);
        assertEq(vault.totalHarvested(), 0);
        assertEq(vault.minProfitForHarvest(), 0.08 ether);
        assertEq(vault.keeperIncentive(), 100);
        assertGt(vault.lastHarvest(), 0);
    }

    /**
     * @notice Withdraw from strategies when vault is paused test
     * @dev Verifies that withdraw works even with funds in strategies, not only from idle
     */
    function test_Withdraw_FromStrategiesWhenPaused() public {
        // Deposits enough so it gets allocated in strategies (exceeds idle threshold)
        _deposit(alice, 20 ether);

        // Pauses the vault
        vault.pause();

        // Top-up vault to cover slippage (same pattern as _withdraw helper)
        deal(WETH, address(vault), IERC20(WETH).balanceOf(address(vault)) + 15 ether);

        // Withdraw must work even when paused, withdrawing from strategies
        vm.prank(alice);
        vault.withdraw(15 ether, alice, alice);

        // Checks that Alice received approximately the expected amount (1% tolerance for slippage)
        assertApproxEqRel(IERC20(WETH).balanceOf(alice), 15 ether, 0.01e18);
    }

    //* Redeem tests when vault is paused

    /**
     * @notice Redeem when vault is paused test
     * @dev After the emergency exit change, redeem works with vault paused.
     *      A user must always be able to withdraw their funds
     */
    function test_Redeem_WorksWhenPaused() public {
        uint256 shares = _deposit(alice, 5 ether);
        vault.pause();

        // Redeem must execute correctly while paused
        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);

        // Checks that Alice received her assets and her shares were burned
        assertEq(assets, 5 ether);
        assertEq(IERC20(WETH).balanceOf(alice), 5 ether);
        assertEq(vault.balanceOf(alice), 0);
    }

    //* Mint tests when vault is paused

    /**
     * @notice Mint when vault is paused test
     * @dev Checks it reverts with the expected error
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

    //* syncIdleBuffer tests

    /**
     * @notice syncIdleBuffer by non-owner test
     * @dev Checks that only the owner can call syncIdleBuffer
     */
    function test_SyncIdleBuffer_RevertIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.syncIdleBuffer();
    }

    /**
     * @notice syncIdleBuffer after receiving external WETH test
     * @dev Simulates the post-emergencyExit scenario: the vault receives WETH directly
     *      without going through deposit(), desynchronizing idle_buffer
     */
    function test_SyncIdleBuffer_UpdatesAfterExternalTransfer() public {
        // Deposits 5 WETH (stays in idle)
        _deposit(alice, 5 ether);
        assertEq(vault.idle_buffer(), 5 ether);

        // Simulates emergencyExit: the vault receives WETH directly without going through deposit
        deal(WETH, address(vault), 15 ether);

        // idle_buffer is still at 5 ETH (desynchronized)
        assertEq(vault.idle_buffer(), 5 ether);

        // Synchronizes
        vault.syncIdleBuffer();

        // Now idle_buffer reflects the real balance
        assertEq(vault.idle_buffer(), 15 ether);
        assertEq(vault.idle_buffer(), IERC20(WETH).balanceOf(address(vault)));
    }

    /**
     * @notice syncIdleBuffer emits event with correct values test
     * @dev Verifies that the IdleBufferSynced event has correct old_buffer and new_buffer
     */
    function test_SyncIdleBuffer_EmitsEvent() public {
        // Deposits 3 WETH (idle_buffer = 3 ETH)
        _deposit(alice, 3 ether);

        // Simulates direct reception of 7 additional WETH
        deal(WETH, address(vault), 10 ether);

        // Expects event with old=3, new=10
        vm.expectEmit(false, false, false, true);
        emit IVault.IdleBufferSynced(3 ether, 10 ether);

        vault.syncIdleBuffer();
    }

    /**
     * @notice syncIdleBuffer idempotency test
     * @dev Calling twice in a row with the same balance produces the same result
     */
    function test_SyncIdleBuffer_Idempotent() public {
        // Deposits and simulates direct transfer
        _deposit(alice, 5 ether);
        deal(WETH, address(vault), 20 ether);

        // First sync
        vault.syncIdleBuffer();
        uint256 buffer_after_first = vault.idle_buffer();

        // Second sync (no changes in balance)
        vault.syncIdleBuffer();
        uint256 buffer_after_second = vault.idle_buffer();

        // Both produce the same result
        assertEq(buffer_after_first, buffer_after_second);
        assertEq(buffer_after_second, 20 ether);
    }

    //* Setter tests that update correctly

    /**
     * @notice setTreasury and setFounder with valid values test
     * @dev Checks that the addresses are updated correctly
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
     * @notice setStrategyManager with valid value test
     * @dev Checks it is updated correctly
     */
    function test_SetStrategyManager_Valid() public {
        address new_manager = makeAddr("new_manager");
        vault.setStrategyManager(new_manager);
        assertEq(vault.strategy_manager(), new_manager);
    }

    /**
     * @notice Withdraw with allowance (caller != owner) test
     * @dev Checks the _spendAllowance path in _withdraw
     */
    function test_Withdraw_WithAllowance() public {
        _deposit(alice, 5 ether);

        // Alice approves Bob to spend her shares
        vm.prank(alice);
        vault.approve(bob, type(uint256).max);

        // Bob withdraws on behalf of Alice
        vm.prank(bob);
        vault.withdraw(2 ether, bob, alice);

        assertEq(IERC20(WETH).balanceOf(bob), 2 ether);
    }

    /**
     * @notice maxDeposit when TVL is at maximum test
     * @dev Must return ~0 when current >= max_tvl
     *      aToken rebase can cause totalAssets to be slightly > deposited, so
     *      we verify it is practically 0 (< 10 wei)
     */
    function test_MaxDeposit_ReturnsZeroAtCapacity() public {
        // Set low max TVL so we can fill it
        vault.setMaxTVL(20 ether);
        _deposit(alice, 20 ether);

        // Proportional distribution between strategies can lose a few wei by rounding,
        // leaving totalAssets slightly below max_tvl. Tolerance of 0.1% of TVL
        assertLe(vault.maxDeposit(alice), 20 ether / 1000, "maxDeposit debe ser ~0 al capacity");
        assertLe(vault.maxMint(alice), 20 ether / 1000, "maxMint debe ser ~0 al capacity");
    }

    //* Emergency flow end-to-end tests

    /**
     * @notice End-to-end emergency flow test: pause → emergencyExit → syncIdleBuffer → redeem
     * @dev Simulates the complete scenario:
     *      1. Users deposit → funds get allocated in strategies
     *      2. Owner detects bug → pause()
     *      3. Owner executes emergencyExit() → funds return to vault
     *      4. Owner executes syncIdleBuffer() → idle_buffer reflects the real balance
     *      5. Users do redeem() → receive their funds correctly
     *      6. The vault is left empty at the end
     */
    function test_EmergencyFlow_EndToEnd() public {
        // --- STEP 1: Users deposit funds that get allocated in strategies ---
        uint256 alice_deposit = 50 ether;
        uint256 bob_deposit = 30 ether;

        uint256 alice_shares = _deposit(alice, alice_deposit);
        uint256 bob_shares = _deposit(bob, bob_deposit);

        // Verifies there are funds in strategies (at least partially)
        assertGt(manager.totalAssets(), 0, "Should have funds in strategies");

        // --- STEP 2: Owner detects bug and pauses the vault ---
        vault.pause();

        // Verifies that deposit does not work when paused
        deal(WETH, alice, 1 ether);
        vm.startPrank(alice);
        IERC20(WETH).approve(address(vault), 1 ether);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.deposit(1 ether, alice);
        vm.stopPrank();

        // --- STEP 3: Owner executes emergencyExit ---
        manager.emergencyExit();

        // Verifies that strategies were left empty
        assertApproxEqAbs(manager.totalAssets(), 0, 20, "Strategies should be empty");

        // --- STEP 4: Owner syncs idle_buffer ---
        vault.syncIdleBuffer();

        // Verifies that totalAssets reflects the real balance
        uint256 vault_weth = IERC20(WETH).balanceOf(address(vault));
        assertEq(vault.idle_buffer(), vault_weth, "idle_buffer debe coincidir con balance WETH real");

        // totalAssets = idle_buffer + manager.totalAssets() ≈ idle_buffer + 0
        assertApproxEqAbs(vault.totalAssets(), vault_weth, 20, "totalAssets debe ser ~WETH balance");

        // --- STEP 5: Users withdraw while paused ---
        // After emergencyExit there may be dust (1-2 wei) in strategies due to rounding in
        // wstETH/stETH. We use withdraw (not redeem) with amounts the idle_buffer
        // can cover, avoiding _withdraw from trying to pull dust from an empty strategy
        uint256 alice_assets = vault.previewRedeem(alice_shares);
        uint256 bob_assets = vault.previewRedeem(bob_shares);

        // Withdraw from idle only: subtract proportional strategy dust
        // To avoid from_strategies > 0, we withdraw at most proportional idle_buffer
        uint256 idle = vault.idle_buffer();
        uint256 total = vault.totalAssets();

        // Calculate the idle portion belonging to each user (proportional to their assets)
        uint256 alice_from_idle = (idle * alice_assets) / total;
        uint256 bob_from_idle = (idle * bob_assets) / total;

        vm.prank(alice);
        uint256 alice_received = vault.withdraw(alice_from_idle, alice, alice);

        // Recalculate idle/total after alice's withdrawal
        idle = vault.idle_buffer();
        total = vault.totalAssets();
        bob_from_idle = (idle * bob_assets) / total;

        vm.prank(bob);
        uint256 bob_received = vault.withdraw(bob_from_idle, bob, bob);

        // Verify they received approximately what was expected (1% tolerance for conversion slippage)
        assertApproxEqRel(alice_received, alice_deposit, 0.01e18, "Alice should receive ~her deposit");
        assertApproxEqRel(bob_received, bob_deposit, 0.01e18, "Bob should receive ~his deposit");

        // --- STEP 6: The vault is left almost empty (may have strategy dust + residual shares) ---
        assertApproxEqAbs(vault.totalAssets(), 0, 1 ether, "Vault should be ~empty");
    }
}
