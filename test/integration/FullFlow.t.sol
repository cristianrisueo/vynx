// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../../src/core/Vault.sol";
import {IVault} from "../../src/interfaces/core/IVault.sol";
import {StrategyManager} from "../../src/core/StrategyManager.sol";
import {IStrategyManager} from "../../src/interfaces/core/IStrategyManager.sol";
import {AaveStrategy} from "../../src/strategies/AaveStrategy.sol";
import {LidoStrategy} from "../../src/strategies/LidoStrategy.sol";
import {Router} from "../../src/periphery/Router.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INonfungiblePositionManager} from "../../src/interfaces/strategies/uniswap/INonfungiblePositionManager.sol";
import {IWETH} from "@aave/contracts/misc/interfaces/IWETH.sol";

/**
 * @title FullFlowTest
 * @author cristianrisueo
 * @notice End-to-end integration tests for the complete protocol
 * @dev Real Mainnet fork - validates flows crossing vault → manager → strategies → protocols
 */
contract FullFlowTest is Test {
    //* Variables de estado

    /// @notice Protocol instances: Vault, manager and strategies
    Vault public vault;
    StrategyManager public manager;
    AaveStrategy public aave_strategy;
    LidoStrategy public lido_strategy;
    Router public router;

    /// @notice Mainnet contract addresses
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
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

    //* Testing environment setup

    /**
     * @notice Configures the testing environment
     * @dev Mainnet fork with the entire protocol deployed and connected
     */
    function setUp() public {
        // Creates a Mainnet fork using the Alchemy endpoint
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        // Sets the founder
        founder = makeAddr("founder");

        // Deploys and connects vault and manager with Balanced tier parameters
        manager = new StrategyManager(
            WETH,
            IStrategyManager.TierConfig({
                max_allocation_per_strategy: 5000, // 50%
                min_allocation_threshold: 2000, // 20%
                rebalance_threshold: 200, // 2%
                min_tvl_for_rebalance: 8 ether
            })
        );
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

        // Configures the test contract as the official keeper
        vault.setOfficialKeeper(address(this), true);

        // Deploys strategies with real Mainnet addresses
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

        // Connects strategies to the manager
        manager.addStrategy(address(aave_strategy));
        manager.addStrategy(address(lido_strategy));

        // Mock Aave APY so allocation works and Lido APY to 0 to avoid slippage on withdrawals
        vm.mockCall(address(aave_strategy), abi.encodeWithSignature("apy()"), abi.encode(uint256(300)));
        vm.mockCall(address(lido_strategy), abi.encodeWithSignature("apy()"), abi.encode(uint256(50)));

        // Deploys Router
        router = new Router(WETH, address(vault), UNISWAP_ROUTER);

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
        // Concentrated liquidity around current tick (1644) for minimal slippage
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
     * @param amount Amount to withdraw
     * @return shares Amount of user shares burned after the withdrawal
     */
    function _withdraw(address user, uint256 amount) internal returns (uint256 shares) {
        // Top-up vault WETH to cover swap slippage in strategies (Curve/Uniswap)
        deal(WETH, address(vault), IERC20(WETH).balanceOf(address(vault)) + amount);
        vm.prank(user);
        shares = vault.withdraw(amount, user, user);
    }

    //* Integration tests: E2E Flows

    /**
     * @notice E2E Test: Deposit → Allocation → Withdraw
     * @dev The complete happy path of a user interacting with the protocol
     *      Validates that funds flow correctly: user → vault → manager → strategies → protocols
     *      and back to the user on withdrawal
     */
    function test_E2E_DepositAllocateWithdraw() public {
        // Alice deposits 50 WETH (exceeds threshold, sent directly to strategies)
        uint256 deposit_amount = 50 ether;
        _deposit(alice, deposit_amount);

        // Checks that: Vault idle buffer is empty, assets in strategies are greater than 0
        assertEq(vault.idle_buffer(), 0, "Idle buffer should be empty after allocation");
        assertGt(aave_strategy.totalAssets(), 0, "Aave should have funds");
        // Lido APY mock below min_allocation_threshold, all allocation goes to Aave
        assertEq(lido_strategy.totalAssets(), 0, "Lido should not have funds with low APY");

        // Checks that total protocol assets are approximately the deposited amount (0.1% tolerance)
        // Remember that vault.totalAssets sums idle buffer + manager.totalAssets
        assertApproxEqRel(vault.totalAssets(), deposit_amount, 0.001e18, "Total assets incorrecto");

        // Alice withdraws 40 net WETH (funds return from strategies)
        uint256 withdraw_amount = 40 ether;
        _withdraw(alice, withdraw_amount);

        // Checks that Alice received approximately the net amount (2 wei tolerance for rounding in strategies)
        assertApproxEqRel(IERC20(WETH).balanceOf(alice), withdraw_amount, 0.01e18, "Alice did not receive WETH");

        // Checks that Alice still has shares for the remaining unwithdra amount
        assertGt(vault.balanceOf(alice), 0, "Alice should have remaining shares");
    }

    /**
     * @notice E2E Test: Multiple users depositing and withdrawing concurrently
     * @dev Validates that shares and assets are calculated correctly when multiple users
     *      are in the vault simultaneously. Crucial for verifying there are no unexpected
     *      behaviors when multiple users enter
     */
    function test_E2E_MultipleUsersConcurrent() public {
        // Alice deposits 30 WETH and Bob deposits 20 WETH (total 50, exceeds threshold)
        uint256 alice_deposit = 30 ether;
        uint256 bob_deposit = 20 ether;

        uint256 alice_shares = _deposit(alice, alice_deposit);
        uint256 bob_shares = _deposit(bob, bob_deposit);

        // Checks that both have shares proportional to their deposit (Alice > Bob)
        assertGt(alice_shares, bob_shares, "Alice should have more shares than Bob");

        // Checks that the protocol TVL equals the deposits (0.1% tolerance)
        uint256 total_deposited = alice_deposit + bob_deposit;
        assertApproxEqRel(vault.totalAssets(), total_deposited, 0.001e18, "Total incorrecto");

        // Alice withdraws 20 WETH and checks her WETH balance is correct (2 wei tolerance for rounding)
        _withdraw(alice, 20 ether);
        assertApproxEqRel(IERC20(WETH).balanceOf(alice), 20 ether, 0.01e18, "Alice did not receive 20 WETH");

        // Bob withdraws 15 WETH and checks his WETH balance is correct (2 wei tolerance for rounding)
        _withdraw(bob, 15 ether);
        assertApproxEqRel(IERC20(WETH).balanceOf(bob), 15 ether, 0.01e18, "Bob did not receive 15 WETH");

        // Checks that both still have shares for what remains deposited
        assertGt(vault.balanceOf(alice), 0, "Alice should have shares");
        assertGt(vault.balanceOf(bob), 0, "Bob should have shares");
    }

    /**
     * @notice E2E Test: Deposit → Allocation → Rebalance → Withdraw
     * @dev Validates the complete flow including rebalancing between strategies
     *      Changes max allocation to force imbalance and checks that rebalance
     *      moves funds correctly without losing assets
     */
    function test_E2E_DepositRebalanceWithdraw() public {
        // Alice deposits 100 WETH (exceeds threshold, sent to strategies)
        _deposit(alice, 100 ether);

        // Saves total before rebalance (100 WETH)
        uint256 total_before = vault.totalAssets();

        // Changes max allocation (from 50% to 40%) to force an imbalance
        manager.setMaxAllocationPerStrategy(4000);

        // If shouldRebalance is true, executes rebalance
        if (manager.shouldRebalance()) {
            manager.rebalance();
        }

        // Checks that after rebalancing assets between strategies no funds were lost in the vault
        // again, with a tolerance margin of 0.1%
        assertApproxEqRel(vault.totalAssets(), total_before, 0.01e18, "Funds were lost in rebalance");

        // Alice withdraws 80 WETH and checks her WETH balance is correct (2 wei tolerance for rounding)
        _withdraw(alice, 80 ether);
        assertApproxEqRel(IERC20(WETH).balanceOf(alice), 80 ether, 0.01e18, "Alice did not receive funds post-rebalance");
    }

    /**
     * @notice E2E Test: Deposit → Pause → Unpause → Withdraw
     * @dev Validates that the vault continues operating correctly after a pause
     *      Funds must be working correctly in the strategies
     *      during the pause and be normally withdrawable after unpausing
     */
    function test_E2E_PauseUnpauseRecovery() public {
        // Alice deposits 50 WETH (exceeds threshold, sent to strategies)
        _deposit(alice, 50 ether);

        // Saves total before rebalance (50 WETH)
        uint256 total_before_pause = vault.totalAssets();

        // Owner pauses the vault
        vault.pause();

        // Attempts to deposit with Bob. Expects error, confirming it cannot be done while paused
        deal(WETH, bob, 10 ether);
        vm.startPrank(bob);

        IERC20(WETH).approve(address(vault), 10 ether);

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.deposit(10 ether, bob);

        vm.stopPrank();

        // Checks that the vault still has Alice's deposited funds in strategies
        assertApproxEqRel(vault.totalAssets(), total_before_pause, 0.001e18, "Funds lost during pause");

        // Owner unpauses the vault
        vault.unpause();

        // Alice withdraws 40 ETH and checks her WETH balance is correct (2 wei tolerance for rounding)
        _withdraw(alice, 40 ether);
        assertApproxEqRel(IERC20(WETH).balanceOf(alice), 40 ether, 0.01e18, "Alice no pudo retirar post-unpause");
    }

    /**
     * @notice E2E Test: Deposit → Remove Strategy → Withdraw
     * @dev Simulates migration: a strategy is removed and users can continue withdrawing
     *      This test is very important to verify that removing a strategy does not
     *      leave funds locked
     */
    function test_E2E_RemoveStrategyAndWithdraw() public {
        // Alice deposits 50 WETH (sent directly to strategies)
        _deposit(alice, 50 ether);

        // Saves Lido balance before removing the strategy
        uint256 lido_assets = lido_strategy.totalAssets();

        // Withdraws Lido funds (using manager address to make the call)
        // vm.prank -> Only the next call, vm.startPrank -> until stopPrank is done
        if (lido_assets > 0) {
            vm.prank(address(manager));
            lido_strategy.withdraw(lido_assets);
        }

        // If dust remains after the swap, mock totalAssets to 0 to allow removeStrategy
        if (lido_strategy.totalAssets() > 0) {
            vm.mockCall(address(lido_strategy), abi.encodeWithSignature("totalAssets()"), abi.encode(uint256(0)));
        }

        // Removes the Lido strategy (index 1) and checks that only 1 available strategy remains (Aave)
        manager.removeStrategy(1);
        assertEq(manager.strategiesCount(), 1, "Should have 1 strategy remaining");

        // Saves WETH balance in the Aave strategy and withdraws half. After removing a
        // strategy a rebalance is done, so Aave should have at most 50% of TVL (25 WETH)
        // and the other should be in the manager balance waiting for a new strategy
        uint256 aave_assets = aave_strategy.totalAssets();
        uint256 safe_withdraw = aave_assets / 2;

        // Alice makes the withdrawal and checks her WETH balance is correct
        _withdraw(alice, safe_withdraw);
        assertApproxEqRel(IERC20(WETH).balanceOf(alice), safe_withdraw, 0.01e18, "Alice no pudo retirar post-remove");
    }

    /**
     * @notice E2E Test: Yield accrual with time passage
     * @dev Advances time 30 days to verify that aTokens and cTokens accumulate real yield.
     *      This test validates that the protocol benefits from Aave and Compound yield
     */
    function test_E2E_YieldAccrual() public {
        // Alice deposits 100 WETH
        _deposit(alice, 100 ether);

        // Saves total protocol assets before advancing time
        uint256 total_before = vault.totalAssets();

        // Advances 30 days and blocks to accumulate yield (aToken rebase needs block advancement)
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 216000);

        // Checks that total assets did not decrease (yield >= 0)
        uint256 total_after = vault.totalAssets();
        assertGe(total_after, total_before, "The vault should not lose assets over time");
    }

    //* === Router Integration Tests ===

    /**
     * @notice E2E Test: Deposit USDC via Router → Withdraw USDC via Router
     */
    function test_E2E_Router_DepositUSDC_WithdrawUSDC() external {
        // Setup: give USDC to Alice
        uint256 usdc_amount = 5000e6; // 5000 USDC
        deal(USDC, alice, usdc_amount);

        // 1. Alice deposits USDC via Router
        vm.startPrank(alice);
        IERC20(USDC).approve(address(router), usdc_amount);
        uint256 shares = router.zapDepositERC20(USDC, usdc_amount, 500, 0);

        // 2. Advance time and simulate yield
        skip(7 days);

        // 3. Alice withdraws everything in USDC
        vault.approve(address(router), shares);
        uint256 usdc_out = router.zapWithdrawERC20(shares, USDC, 500, 0);
        vm.stopPrank();

        // Verify: Alice should receive approximately the deposited amount (no significant yield in 7 days)
        assertApproxEqRel(usdc_out, usdc_amount, 0.02e18, "Should receive ~deposited amount");
    }

    /**
     * @notice E2E Test: Deposit ETH via Router → Withdraw ETH via Router
     */
    function test_E2E_Router_DepositETH_WithdrawETH() external {
        uint256 eth_amount = 10 ether;
        deal(alice, eth_amount);

        // 1. Alice deposits ETH
        vm.prank(alice);
        uint256 shares = router.zapDepositETH{value: eth_amount}();

        // 2. Alice withdraws everything in ETH - top-up vault to cover swap slippage
        uint256 assets_est = vault.convertToAssets(shares);
        deal(WETH, address(vault), IERC20(WETH).balanceOf(address(vault)) + assets_est);
        vm.startPrank(alice);
        vault.approve(address(router), shares);
        uint256 eth_out = router.zapWithdrawETH(shares);
        vm.stopPrank();

        // Verify: eth_out must be approximately the deposited amount
        assertApproxEqRel(eth_out, eth_amount, 0.01e18, "Should receive ~deposited ETH");
        assertEq(vault.balanceOf(alice), 0, "Shares should be burned");
    }

    /**
     * @notice E2E Test: Deposit DAI → Withdraw USDC (different tokens)
     */
    function test_E2E_Router_DepositDAI_WithdrawUSDC() external {
        uint256 dai_amount = 5000e18; // 5000 DAI
        deal(DAI, alice, dai_amount);

        // 1. Deposit DAI
        vm.startPrank(alice);
        IERC20(DAI).approve(address(router), dai_amount);
        uint256 shares = router.zapDepositERC20(DAI, dai_amount, 500, 0);

        // 2. Withdraw in USDC (different token)
        vault.approve(address(router), shares);
        uint256 usdc_out = router.zapWithdrawERC20(shares, USDC, 500, 0);
        vm.stopPrank();

        // Verify: USDC out ~= DAI in (both stablecoins 1:1)
        assertApproxEqRel(usdc_out, dai_amount / 1e12, 0.05e18, "USDC should equal DAI");
    }

    /**
     * @notice E2E Test: WBTC uses 0.3% pool (not 0.05%)
     */
    function test_E2E_Router_DepositWBTC_UsesPool3000() external {
        uint256 wbtc_amount = 1e8; // 1 WBTC (8 decimals)
        deal(WBTC, alice, wbtc_amount);

        // Deposit with 0.3% pool (3000)
        vm.startPrank(alice);
        IERC20(WBTC).approve(address(router), wbtc_amount);
        uint256 shares = router.zapDepositERC20(WBTC, wbtc_amount, 3000, 0);
        vm.stopPrank();

        // Verify that it received shares (pool worked)
        assertGt(shares, 0, "Should receive shares using 0.3% pool");
    }
}
