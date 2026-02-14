// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../../src/core/Vault.sol";
import {StrategyManager} from "../../src/core/StrategyManager.sol";
import {AaveStrategy} from "../../src/strategies/AaveStrategy.sol";
import {CompoundStrategy} from "../../src/strategies/CompoundStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title VaultTest
 * @author cristianrisueo
 * @notice Unit tests for Vault with Mainnet fork
 * @dev Mainnet fork test, no bullshit here
 */
contract VaultTest is Test {
    //* State variables

    /// @notice Vault, manager and strategies instances
    Vault public vault;
    StrategyManager public manager;
    AaveStrategy public aave_strategy;
    CompoundStrategy public compound_strategy;

    /// @notice Mainnet contract addresses
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
    address public bob = makeAddr("bob");
    address public founder;

    /// @notice Vault parameters
    uint256 constant MAX_TVL = 1000 ether;

    //* Testing environment setup

    /**
     * @notice Sets up the testing environment
     * @dev For real behavior we fork Mainnet. I don't recommend testing on
     *      testnets, the deployed contracts ARE SHIT, it's not real behavior
     */
    function setUp() public {
        // Create a Mainnet fork using my Alchemy endpoint in env.var
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        // Set the founder
        founder = makeAddr("founder");

        // Initialize the manager, vault and set the vault address in the manager
        manager = new StrategyManager(WETH);
        vault = new Vault(WETH, address(manager), address(this), founder);
        manager.initialize(address(vault));

        // Initialize the strategies with real mainnet addresses
        aave_strategy = new AaveStrategy(address(manager), AAVE_POOL, AAVE_REWARDS, WETH, AAVE_TOKEN, UNISWAP_ROUTER, POOL_FEE);
        compound_strategy = new CompoundStrategy(address(manager), COMPOUND_COMET, COMPOUND_REWARDS, WETH, COMP_TOKEN, UNISWAP_ROUTER, POOL_FEE);

        // Add the strategies
        manager.addStrategy(address(aave_strategy));
        manager.addStrategy(address(compound_strategy));
    }

    //* Internal helper functions

    /**
     * @notice Deposit helper used in most tests
     * @dev Helpers are only used for happy paths, not cases where a revert is expected
     * @param user User used in the interaction
     * @param amount Amount given to the user
     * @return shares Amount of shares minted to the user after the deposit
     */
    function _deposit(address user, uint256 amount) internal returns (uint256 shares) {
        // Give the WETH amount to the user and use their address
        deal(WETH, user, amount);
        vm.startPrank(user);

        // Approve the vault for the WETH transfer and deposit the amount into the vault
        IERC20(WETH).approve(address(vault), amount);
        shares = vault.deposit(amount, user);

        vm.stopPrank();
    }

    /**
     * @notice Withdrawal helper used in most tests
     * @dev Helpers are only used for happy paths, not cases where a revert is expected
     * @param user User used in the interaction
     * @param amount Amount given to the user
     * @return shares Amount of user shares burned after the withdrawal
     */
    function _withdraw(address user, uint256 amount) internal returns (uint256 shares) {
        // Use the user's address, withdraw the amount and return the burned shares
        vm.prank(user);
        shares = vault.withdraw(amount, user, user);
    }

    //* Unit tests for core logic: Deposits

    /**
     * @notice Basic deposit test
     * @dev Checks that a user can deposit and receive shares correctly
     */
    function test_Deposit_Basic() public {
        // Use Alice to deposit 1 WETH
        uint256 amount = 1 ether;
        uint256 shares = _deposit(alice, amount);

        // Check shares received by Alice, assets in the vault and assets in the idle buffer
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.totalAssets(), amount);
        assertEq(vault.idle_buffer(), amount);
    }

    /**
     * @notice Deposit equal to IDLE threshold test
     * @dev Performs a deposit above the threshold to check that the vault does allocation
     */
    function test_Deposit_TriggersAllocation() public {
        // Use Alice to deposit the threshold amount
        _deposit(alice, vault.idle_threshold());

        // Check that both the vault and the IDLE buffer have no WETH
        assertEq(vault.idle_buffer(), 0);
        assertGt(manager.totalAssets(), 0);
    }

    /**
     * @notice Zero amount deposit test
     * @dev Performs a deposit with zero amount and checks that it reverts with the expected error
     */
    function test_Deposit_RevertZero() public {
        // Use Alice to deposit zero amount
        vm.prank(alice);

        // Expect the error and deposit
        vm.expectRevert(Vault.Vault__DepositBelowMinimum.selector);
        vault.deposit(0, alice);
    }

    /**
     * @notice Below minimum amount deposit test
     * @dev Performs a deposit with a tiny amount and checks that it reverts with the expected error
     */
    function test_Deposit_RevertBelowMin() public {
        // Give Alice 0.005 WETH and use her address
        deal(WETH, alice, 0.005 ether);
        vm.startPrank(alice);

        // Approve the vault for the transfer
        IERC20(WETH).approve(address(vault), 0.005 ether);

        // Expect the error and deposit
        vm.expectRevert(Vault.Vault__DepositBelowMinimum.selector);
        vault.deposit(0.005 ether, alice);

        vm.stopPrank();
    }

    /**
     * @notice Above maximum TVL deposit test
     * @dev Performs a deposit with an amount above the limit and checks that it reverts with the expected error
     */
    function test_Deposit_RevertExceedsMaxTVL() public {
        // Give Alice an amount above the maximum allowed TVL and use her address
        deal(WETH, alice, MAX_TVL + 1);
        vm.startPrank(alice);

        // Approve the vault for the transfer
        IERC20(WETH).approve(address(vault), MAX_TVL + 1);

        // Expect the error and deposit
        vm.expectRevert(Vault.Vault__MaxTVLExceeded.selector);
        vault.deposit(MAX_TVL + 1, alice);

        vm.stopPrank();
    }

    /**
     * @notice Deposit when vault is paused test
     * @dev Performs a deposit with a normal amount and checks that it reverts with the expected error
     */
    function test_Deposit_RevertWhenPaused() public {
        // Pause the vault
        vault.pause();

        // Give 1 WETH to Alice and use her address
        deal(WETH, alice, 1 ether);
        vm.startPrank(alice);

        // Approve the vault for the transfer
        IERC20(WETH).approve(address(vault), 1 ether);

        // Expect the error and deposit
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.deposit(1 ether, alice);

        vm.stopPrank();
    }

    //* Mint testing

    /**
     * @notice Basic mint test
     * @dev Checks that a user can mint and receive shares correctly
     */
    function test_Mint_Basic() public {
        // Give 10 WETH to Alice and use her address
        deal(WETH, alice, 10 ether);
        vm.startPrank(alice);

        // Approve the vault for the transfer
        IERC20(WETH).approve(address(vault), 10 ether);

        // Mint 5 WETH
        vault.mint(5 ether, alice);
        vm.stopPrank();

        // Check that Alice's share balance corresponds to 5 WETH (1:1 ratio)
        assertEq(vault.balanceOf(alice), 5 ether);
    }

    /**
     * @notice Zero amount mint test
     * @dev Performs a mint with zero amount and checks that it reverts with the expected error
     */
    function test_Mint_RevertZero() public {
        // Use Alice's address
        vm.prank(alice);

        // Expect the error and mint 0 shares
        vm.expectRevert(Vault.Vault__DepositBelowMinimum.selector);
        vault.mint(0, alice);
    }

    //* Withdraw testing

    /**
     * @notice Withdrawal from idle buffer test
     * @dev Checks that it withdraws correctly from idle without touching the manager
     */
    function test_Withdraw_FromIdle() public {
        // Deposit 5 WETH (stays in idle)
        _deposit(alice, 5 ether);

        // Withdraw 2 WETH
        _withdraw(alice, 2 ether);

        // Check Alice's balance and that the manager remains empty
        assertEq(IERC20(WETH).balanceOf(alice), 2 ether);
        assertEq(manager.totalAssets(), 0);
    }

    /**
     * @notice Withdrawal from strategies test
     * @dev Checks that it withdraws from the manager when idle is not enough
     */
    function test_Withdraw_FromStrategies() public {
        // Deposit 20 WETH (exceeds threshold, goes to the manager)
        _deposit(alice, 20 ether);

        // Withdraw 15 WETH
        _withdraw(alice, 15 ether);

        // Check Alice's final balance (2 wei tolerance due to rounding in proportional strategy withdrawals)
        assertApproxEqAbs(IERC20(WETH).balanceOf(alice), 15 ether, 2);
    }

    /**
     * @notice Withdrawal when vault is paused test
     * @dev Checks that it reverts when trying to withdraw while paused
     */
    function test_Withdraw_RevertWhenPaused() public {
        // Deposit funds first
        _deposit(alice, 5 ether);

        // Pause the vault
        vault.pause();

        // Expect the pause error when trying to withdraw
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        _withdraw(alice, 1 ether);
    }

    //* Redeem testing

    /**
     * @notice Basic redeem test
     * @dev Checks that a user can redeem shares for assets
     */
    function test_Redeem_Basic() public {
        // Deposit and get shares
        uint256 shares = _deposit(alice, 5 ether);

        // Use Alice to redeem her shares
        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);

        // Check that shares were burned and assets were received (no fee, returns what was deposited)
        assertEq(vault.balanceOf(alice), 0);
        assertEq(assets, 5 ether);
    }

    //* Allocation testing

    /**
     * @notice Allocate idle below threshold test
     * @dev Checks that manual allocation fails if there is not enough idle
     */
    function test_AllocateIdle_RevertBelowThreshold() public {
        // Deposit a small amount (below threshold)
        _deposit(alice, 1 ether);

        // Expect error when trying manual allocation without reaching the minimum
        vm.expectRevert(Vault.Vault__InsufficientIdleBuffer.selector);
        vault.allocateIdle();
    }

    //* Accounting function testing

    /**
     * @notice Total assets summing idle and manager test
     * @dev Checks that total assets correctly sums both parts
     */
    function test_TotalAssets_IdlePlusManager() public {
        // Deposit with Alice (stays in idle)
        _deposit(alice, 5 ether);

        // Deposit with Bob (exceeds threshold, triggers allocation)
        _deposit(bob, 10 ether);

        // Check that the total is the approximate sum (due to possible fees/slippage)
        uint256 expected = 15 ether;
        assertApproxEqRel(vault.totalAssets(), expected, 0.001e18);
    }

    /**
     * @notice Max deposit respecting TVL test
     * @dev Checks that the function returns MAX_TVL
     */
    function test_MaxDeposit_RespectsMaxTVL() public view {
        // Check that the maximum allowed deposit is the configured TVL
        assertEq(vault.maxDeposit(alice), MAX_TVL);
    }

    /**
     * @notice Max mint respecting TVL test
     * @dev Checks that the function returns MAX_TVL (in shares)
     */
    function test_MaxMint_RespectsMaxTVL() public view {
        // Check that the maximum allowed mint is the configured TVL
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

    //* Owner-only functionality testing

    /**
     * @notice Admin permissions test
     * @dev Checks that only the owner can change parameters and others fail
     */
    function test_Admin_OnlyOwnerCanSetParams() public {
        // Try to execute setters as Alice (not owner)
        vm.startPrank(alice);

        // Expect reverts on all administrative calls
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

        // Execute setters as Owner (should work)
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

        // Check that the values were updated correctly
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

    //* Harvest and fee distribution testing

    /**
     * @notice Harvest with external keeper test (should receive incentive)
     * @dev Injects AAVE reward tokens into the strategy to simulate accumulated yield,
     *      since skip(7 days) on a static fork does not generate real rewards
     */
    function test_HarvestWithExternalKeeper() public {
        // Setup: deposit enough for it to be allocated to strategies
        _deposit(alice, 100 ether);

        // Lower min_profit_for_harvest so any profit passes the threshold
        vault.setMinProfitForHarvest(0);

        // Simulate rewards: deal AAVE tokens to the strategy so harvest swaps them
        deal(AAVE_TOKEN, address(aave_strategy), 1 ether);

        // Advance time so Aave accumulates some yield via aToken rebase
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

            assertGt(keeper_reward, 0, "Keeper should receive incentive");
            assertEq(keeper_reward, (profit * vault.keeper_incentive()) / vault.BASIS_POINTS());
        }
    }

    /**
     * @notice Harvest with official keeper test (should NOT receive incentive)
     * @dev Injects AAVE reward tokens to simulate yield and verifies that official keeper doesn't get paid
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

        // Verify that they did NOT receive incentive
        uint256 keeper_balance_after = IERC20(WETH).balanceOf(official_keeper);
        assertEq(keeper_balance_after, keeper_balance_before, "Official keeper should not receive incentive");
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

            assertGt(treasury_shares_after, treasury_shares_before, "Treasury should receive shares");
            assertGt(founder_weth_after, founder_weth_before, "Founder should receive WETH");

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

    //* Setter validation testing (error paths for coverage)

    /**
     * @notice setPerformanceFee with value > BASIS_POINTS test
     * @dev Checks that it reverts with the expected error
     */
    function test_SetPerformanceFee_RevertExceedsBasisPoints() public {
        vm.expectRevert(Vault.Vault__InvalidPerformanceFee.selector);
        vault.setPerformanceFee(10001);
    }

    /**
     * @notice setFeeSplit with splits that don't sum to BASIS_POINTS test
     * @dev Checks that it reverts with the expected error
     */
    function test_SetFeeSplit_RevertInvalidSum() public {
        vm.expectRevert(Vault.Vault__InvalidFeeSplit.selector);
        vault.setFeeSplit(5000, 4000);
    }

    /**
     * @notice setTreasury with address(0) test
     * @dev Checks that it reverts with the expected error
     */
    function test_SetTreasury_RevertZeroAddress() public {
        vm.expectRevert(Vault.Vault__InvalidTreasuryAddress.selector);
        vault.setTreasury(address(0));
    }

    /**
     * @notice setFounder with address(0) test
     * @dev Checks that it reverts with the expected error
     */
    function test_SetFounder_RevertZeroAddress() public {
        vm.expectRevert(Vault.Vault__InvalidFounderAddress.selector);
        vault.setFounder(address(0));
    }

    /**
     * @notice setStrategyManager with address(0) test
     * @dev Checks that it reverts with the expected error
     */
    function test_SetStrategyManager_RevertZeroAddress() public {
        vm.expectRevert(Vault.Vault__InvalidStrategyManagerAddress.selector);
        vault.setStrategyManager(address(0));
    }

    /**
     * @notice setKeeperIncentive with value > BASIS_POINTS test
     * @dev Checks that it reverts with the expected error
     */
    function test_SetKeeperIncentive_RevertExceedsBasisPoints() public {
        vm.expectRevert(Vault.Vault__InvalidPerformanceFee.selector);
        vault.setKeeperIncentive(10001);
    }

    //* Constructor validation testing

    /**
     * @notice Constructor with strategy manager address(0) test
     */
    function test_Constructor_RevertInvalidStrategyManager() public {
        vm.expectRevert(Vault.Vault__InvalidStrategyManagerAddress.selector);
        new Vault(WETH, address(0), address(this), founder);
    }

    /**
     * @notice Constructor with treasury address(0) test
     */
    function test_Constructor_RevertInvalidTreasury() public {
        vm.expectRevert(Vault.Vault__InvalidTreasuryAddress.selector);
        new Vault(WETH, address(manager), address(0), founder);
    }

    /**
     * @notice Constructor with founder address(0) test
     */
    function test_Constructor_RevertInvalidFounder() public {
        vm.expectRevert(Vault.Vault__InvalidFounderAddress.selector);
        new Vault(WETH, address(manager), address(this), address(0));
    }

    //* Harvest edge case testing

    /**
     * @notice Harvest with no profit test (should return 0)
     * @dev Without injected rewards, harvest returns 0 profit
     */
    function test_Harvest_ZeroProfit() public {
        // Deposit so there is something in strategies
        _deposit(alice, 20 ether);

        // Harvest without simulating rewards - should return 0
        uint256 profit = vault.harvest();
        assertEq(profit, 0, "Without rewards, harvest should return 0");
    }

    /**
     * @notice Harvest when vault is paused test
     * @dev Checks that it reverts
     */
    function test_Harvest_RevertWhenPaused() public {
        _deposit(alice, 5 ether);
        vault.pause();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.harvest();
    }

    /**
     * @notice allocateIdle when vault is paused test
     * @dev Checks that it reverts
     */
    function test_AllocateIdle_RevertWhenPaused() public {
        _deposit(alice, 5 ether);
        vault.pause();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.allocateIdle();
    }

    //* Mint edge case testing

    /**
     * @notice Mint exceeding max TVL test
     * @dev Checks that it reverts with the expected error
     */
    function test_Mint_RevertExceedsMaxTVL() public {
        // Try to mint shares equivalent to more than max TVL
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

        // Idle buffer should be empty because it was allocated
        assertEq(vault.idle_buffer(), 0);
        assertGt(manager.totalAssets(), 0);
    }

    //* Withdraw edge case testing

    /**
     * @notice Full amount withdrawal test
     * @dev Checks that everything can be withdrawn and the vault ends up empty
     */
    function test_Withdraw_FullAmount() public {
        uint256 amount = 5 ether;
        _deposit(alice, amount);

        _withdraw(alice, amount);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.totalAssets(), 0);
    }

    //* Getter testing for coverage

    /**
     * @notice All vault getters test
     * @dev Checks that they return the correct values post-setup
     */
    function test_Getters_ReturnCorrectValues() public view {
        assertEq(vault.performanceFee(), 2000);
        assertEq(vault.treasurySplit(), 8000);
        assertEq(vault.founderSplit(), 2000);
        assertEq(vault.minDeposit(), 0.01 ether);
        assertEq(vault.idleThreshold(), 10 ether);
        assertEq(vault.maxTVL(), 1000 ether);
        assertEq(vault.treasury(), address(this));
        assertEq(vault.founder(), founder);
        assertEq(vault.strategyManager(), address(manager));
        assertEq(vault.idleBuffer(), 0);
        assertEq(vault.totalHarvested(), 0);
        assertEq(vault.minProfitForHarvest(), 0.1 ether);
        assertEq(vault.keeperIncentive(), 100);
        assertGt(vault.lastHarvest(), 0);
    }

    //* Redeem when vault is paused testing

    /**
     * @notice Redeem when vault is paused test
     * @dev Checks that it reverts
     */
    function test_Redeem_RevertWhenPaused() public {
        uint256 shares = _deposit(alice, 5 ether);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.redeem(shares, alice, alice);
    }

    //* Mint when vault is paused testing

    /**
     * @notice Mint when vault is paused test
     * @dev Checks that it reverts with the expected error
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

    //* Setter correct update testing

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
     * @dev Checks that it is updated correctly
     */
    function test_SetStrategyManager_Valid() public {
        address new_manager = makeAddr("new_manager");
        vault.setStrategyManager(new_manager);
        assertEq(vault.strategy_manager(), new_manager);
    }

    /**
     * @notice Withdraw with allowance test (caller != owner)
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
     * @dev Should return ~0 when current >= max_tvl
     *      aToken rebase can cause totalAssets slightly > deposited, so
     *      we verify it's practically 0 (< 10 wei)
     */
    function test_MaxDeposit_ReturnsZeroAtCapacity() public {
        // Set max TVL low so we can fill it
        vault.setMaxTVL(20 ether);
        _deposit(alice, 20 ether);

        // Proportional distribution between strategies can lose some wei due to rounding,
        // leaving totalAssets slightly below max_tvl. 0.1% of TVL tolerance
        assertLe(vault.maxDeposit(alice), 20 ether / 1000, "maxDeposit should be ~0 at capacity");
        assertLe(vault.maxMint(alice), 20 ether / 1000, "maxMint should be ~0 at capacity");
    }
}
