// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../../src/core/Vault.sol";
import {StrategyManager} from "../../src/core/StrategyManager.sol";
import {AaveStrategy} from "../../src/strategies/AaveStrategy.sol";
import {CompoundStrategy} from "../../src/strategies/CompoundStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title FullFlowTest
 * @author cristianrisueo
 * @notice End-to-end integration tests for the complete protocol
 * @dev Real Mainnet fork - validates flows that cross vault -> manager -> strategies -> protocols
 */
contract FullFlowTest is Test {
    //* State variables

    /// @notice Protocol instances: Vault, manager and strategies
    Vault public vault;
    StrategyManager public manager;
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
    address public bob = makeAddr("bob");
    address public founder;

    //* Testing environment setup

    /**
     * @notice Configures the testing environment
     * @dev Mainnet fork with the entire protocol deployed and connected
     */
    function setUp() public {
        // Create a Mainnet fork using the Alchemy endpoint
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        // Set the founder
        founder = makeAddr("founder");

        // Deploy and connect vault and manager
        manager = new StrategyManager(WETH);
        vault = new Vault(WETH, address(manager), address(this), founder);
        manager.initialize(address(vault));

        // Configure the test contract as official keeper
        vault.setOfficialKeeper(address(this), true);

        // Deploy strategies with real Mainnet addresses
        aave_strategy = new AaveStrategy(address(manager), AAVE_POOL, AAVE_REWARDS, WETH, AAVE_TOKEN, UNISWAP_ROUTER, POOL_FEE);
        compound_strategy = new CompoundStrategy(address(manager), COMPOUND_COMET, COMPOUND_REWARDS, WETH, COMP_TOKEN, UNISWAP_ROUTER, POOL_FEE);

        // Connect strategies to the manager
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
        // Give the amount of WETH to the user and use their address
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
     * @param amount Amount to withdraw
     * @return shares Amount of user shares burned after the withdrawal
     */
    function _withdraw(address user, uint256 amount) internal returns (uint256 shares) {
        // Use the user's address, withdraw the amount and return the burned shares
        vm.prank(user);
        shares = vault.withdraw(amount, user, user);
    }

    //* Integration tests: E2E Flows

    /**
     * @notice E2E Test: Deposit -> Allocation -> Withdraw
     * @dev The complete happy path of a user interacting with the protocol
     *      Validates that funds flow correctly: user -> vault -> manager -> strategies -> protocols
     *      and back to the user when withdrawing
     */
    function test_E2E_DepositAllocateWithdraw() public {
        // Alice deposits 50 WETH (exceeds threshold, sent directly to the strategies)
        uint256 deposit_amount = 50 ether;
        _deposit(alice, deposit_amount);

        // Check that: Vault's idle buffer is empty, assets in the strategies are greater than 0
        assertEq(vault.idle_buffer(), 0, "Idle buffer should be empty after allocation");
        assertGt(aave_strategy.totalAssets(), 0, "Aave should have funds");
        assertGt(compound_strategy.totalAssets(), 0, "Compound should have funds");

        // Check that the protocol total is approximately the deposited amount (0.1% tolerance)
        // Remember that vault.totalAssets sums idle buffer + manager.totalAssets
        assertApproxEqRel(vault.totalAssets(), deposit_amount, 0.001e18, "Incorrect total assets");

        // Alice withdraws 40 net WETH (funds come back from the strategies)
        uint256 withdraw_amount = 40 ether;
        _withdraw(alice, withdraw_amount);

        // Check that Alice received approximately the net amount (tolerance of 2 wei due to rounding in strategies)
        assertApproxEqAbs(IERC20(WETH).balanceOf(alice), withdraw_amount, 2, "Alice did not receive WETH");

        // Check that Alice still has shares for the remaining non-withdrawn portion
        assertGt(vault.balanceOf(alice), 0, "Alice should have remaining shares");
    }

    /**
     * @notice E2E Test: Multiple users depositing and withdrawing concurrently
     * @dev Validates that shares and assets are calculated correctly when there are multiple users
     *      in the vault simultaneously. This is crucial to verify that there are no weird
     *      behaviors when multiple users enter
     */
    function test_E2E_MultipleUsersConcurrent() public {
        // Alice deposits 30 WETH and Bob deposits 20 WETH (total 50, exceeds threshold)
        uint256 alice_deposit = 30 ether;
        uint256 bob_deposit = 20 ether;

        uint256 alice_shares = _deposit(alice, alice_deposit);
        uint256 bob_shares = _deposit(bob, bob_deposit);

        // Check that both have shares proportional to their deposit (Alice > Bob)
        assertGt(alice_shares, bob_shares, "Alice should have more shares than Bob");

        // Check that the protocol TVL equals the deposits (0.1% tolerance)
        uint256 total_deposited = alice_deposit + bob_deposit;
        assertApproxEqRel(vault.totalAssets(), total_deposited, 0.001e18, "Incorrect total");

        // Alice withdraws 20 WETH and checks that her WETH balance is correct (tolerance of 2 wei due to rounding)
        _withdraw(alice, 20 ether);
        assertApproxEqAbs(IERC20(WETH).balanceOf(alice), 20 ether, 2, "Alice did not receive 20 WETH");

        // Bob withdraws 15 WETH and checks that his WETH balance is correct (tolerance of 2 wei due to rounding)
        _withdraw(bob, 15 ether);
        assertApproxEqAbs(IERC20(WETH).balanceOf(bob), 15 ether, 2, "Bob did not receive 15 WETH");

        // Check that both have remaining shares for what they still have deposited
        assertGt(vault.balanceOf(alice), 0, "Alice should have shares");
        assertGt(vault.balanceOf(bob), 0, "Bob should have shares");
    }

    /**
     * @notice E2E Test: Deposit -> Allocation -> Rebalance -> Withdraw
     * @dev Validates the complete flow including rebalancing between strategies
     *      Changes max allocation to force imbalance and verify that the rebalance
     *      moves funds correctly without losing assets
     */
    function test_E2E_DepositRebalanceWithdraw() public {
        // Alice deposits 100 WETH (exceeds threshold, sent to strategies)
        _deposit(alice, 100 ether);

        // Save the total before the rebalance (100 WETH)
        uint256 total_before = vault.totalAssets();

        // Change max allocation (from 50% to 40%) to force an imbalance
        manager.setMaxAllocationPerStrategy(4000);

        // If shouldRebalance is true, execute rebalance
        if (manager.shouldRebalance()) {
            manager.rebalance();
        }

        // Check that after the rebalance of assets between strategies no funds were lost in the vault
        // again, with a tolerance margin of 0.1%
        assertApproxEqRel(vault.totalAssets(), total_before, 0.01e18, "Funds were lost in rebalance");

        // Alice withdraws 80 WETH and checks that her WETH balance is correct (tolerance of 2 wei due to rounding)
        _withdraw(alice, 80 ether);
        assertApproxEqAbs(IERC20(WETH).balanceOf(alice), 80 ether, 2, "Alice did not receive funds post-rebalance");
    }

    /**
     * @notice E2E Test: Deposit -> Pause -> Unpause -> Withdraw
     * @dev Validates that the vault continues operating correctly after a pause
     *      The funds should be working correctly in the strategies
     *      during the pause and be withdrawable normally after unpausing
     */
    function test_E2E_PauseUnpauseRecovery() public {
        // Alice deposits 50 WETH (exceeds threshold, sent to strategies)
        _deposit(alice, 50 ether);

        // Save the total before the pause (50 WETH)
        uint256 total_before_pause = vault.totalAssets();

        // Owner pauses the vault
        vault.pause();

        // Try to deposit with Bob. Expect an error, checking that it can't be done because it's paused
        deal(WETH, bob, 10 ether);
        vm.startPrank(bob);

        IERC20(WETH).approve(address(vault), 10 ether);

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.deposit(10 ether, bob);

        vm.stopPrank();

        // Check that the vault still has the funds deposited by Alice in the strategies
        assertApproxEqRel(vault.totalAssets(), total_before_pause, 0.001e18, "Funds lost during pause");

        // Owner unpauses the vault
        vault.unpause();

        // Alice withdraws 40 ETH and checks that her WETH balance is correct (tolerance of 2 wei due to rounding)
        _withdraw(alice, 40 ether);
        assertApproxEqAbs(IERC20(WETH).balanceOf(alice), 40 ether, 2, "Alice could not withdraw post-unpause");
    }

    /**
     * @notice E2E Test: Deposit -> Remove Strategy -> Withdraw
     * @dev Simulates migration: a strategy is removed and users can still withdraw
     *      This test is very important to verify that removing a strategy does not
     *      leave funds locked
     */
    function test_E2E_RemoveStrategyAndWithdraw() public {
        // Alice deposits 50 WETH (sent directly to the strategies)
        _deposit(alice, 50 ether);

        // Save the Compound balance before removing the strategy
        uint256 compound_assets = compound_strategy.totalAssets();

        // Withdraw the funds from Compound (using the manager's address to make the call)
        // vm.prank -> Only the next call, vm.startPrank -> until stopPrank is called
        if (compound_assets > 0) {
            vm.prank(address(manager));
            compound_strategy.withdraw(compound_assets);
        }

        // Remove the Compound strategy (index 1) and check that only 1 strategy remains available (Aave)
        manager.removeStrategy(1);
        assertEq(manager.strategiesCount(), 1, "There should be 1 strategy remaining");

        // Save the WETH balance in the Aave strategy and withdraw half. After removing a
        // strategy a rebalance is done, so Aave should have at most 50% of TVL (25 WETH)
        // and the rest should be in the manager's balance waiting for a new strategy
        uint256 aave_assets = aave_strategy.totalAssets();
        uint256 safe_withdraw = aave_assets / 2;

        // Alice performs the withdrawal and checks that her WETH balance is correct
        _withdraw(alice, safe_withdraw);
        assertEq(IERC20(WETH).balanceOf(alice), safe_withdraw, "Alice could not withdraw post-remove");
    }

    /**
     * @notice E2E Test: Yield accrual with time passing
     * @dev Advances time 30 days to verify that aTokens and cTokens accumulate real yield.
     *      This test validates that the protocol benefits from Aave and Compound yield
     */
    function test_E2E_YieldAccrual() public {
        // Alice deposits 100 WETH
        _deposit(alice, 100 ether);

        // Save the protocol's total assets before advancing time
        uint256 total_before = vault.totalAssets();

        // Advance 30 days to accumulate yield
        vm.warp(block.timestamp + 30 days);

        // Check that total assets grew (yield accumulated)
        uint256 total_after = vault.totalAssets();
        assertGt(total_after, total_before, "The vault should have accumulated yield");

        // Calculate the generated yield
        uint256 yield_earned = total_after - total_before;

        // Check that the yield is reasonable (between 0.01% and 5% in 30 days), if not something is off
        assertGt(yield_earned, total_before / 10000, "Yield too low");
        assertLt(yield_earned, (total_before * 5) / 100, "Yield suspiciously high");
    }
}
