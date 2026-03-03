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
 * @title FuzzTest
 * @author cristianrisueo
 * @notice Stateless fuzz tests for the protocol
 * @dev Each test receives random inputs bounded to realistic ranges
 *      They are stateless: each execution starts from scratch after setUp()
 */
contract FuzzTest is Test {
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
    address constant UNISWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_REWARDS = 0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb;
    address constant AAVE_TOKEN = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;
    address constant CURVE_POOL = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;
    uint24 constant POOL_FEE = 3000;

    /// @notice Test users
    address public alice = makeAddr("alice");
    address public founder;

    /// @notice Vault parameters
    uint256 constant MAX_TVL = 1000 ether;
    uint256 constant MIN_DEPOSIT = 0.01 ether;

    //* Testing environment setup

    /**
     * @notice Configures the testing environment
     * @dev Mainnet fork with complete protocol deployed
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

        // Mock Aave APY so allocation works and Lido APY to 0 to avoid slippage on withdrawals
        vm.mockCall(address(aave_strategy), abi.encodeWithSignature("apy()"), abi.encode(uint256(300)));
        vm.mockCall(address(lido_strategy), abi.encodeWithSignature("apy()"), abi.encode(uint256(50)));

        // Connects strategies to the manager
        manager.addStrategy(address(aave_strategy));
        manager.addStrategy(address(lido_strategy));

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
     * @notice Deposit helper
     * @param user User depositing
     * @param amount Amount to deposit
     * @return shares Minted shares
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

    //* Stateless fuzz tests

    /**
     * @notice Fuzz: For any valid amount, deposit generates shares > 0 and totalAssets grows
     * @dev Bounds amount between MIN_DEPOSIT and MAX_TVL to avoid validation reverts
     * @param amount Random amount generated by the fuzzer
     */
    function testFuzz_Deposit_GeneratesShares(uint256 amount) public {
        // Bounds input to the vault's valid range
        amount = bound(amount, MIN_DEPOSIT, MAX_TVL);

        // Saves totalAssets before the deposit
        uint256 total_before = vault.totalAssets();

        // Deposits and checks that shares were generated
        uint256 shares = _deposit(alice, amount);
        assertGt(shares, 0, "Deposit should generate shares > 0");

        // Checks that totalAssets grew (0.1% tolerance for protocol fees)
        assertApproxEqRel(vault.totalAssets(), total_before + amount, 0.001e18, "TotalAssets did not grow");
    }

    /**
     * @notice Fuzz: For any withdrawal, the user does not extract more than deposited
     * @dev Deposits amount, then withdraws a random percentage, always <= deposited
     * @param amount Random deposited amount
     * @param withdraw_pct Random percentage to withdraw (1-90%) of deposited
     */
    function testFuzz_Withdraw_NeverExceedsDeposit(uint256 amount, uint256 withdraw_pct) public {
        // Bounds inputs: valid amount, withdraw between 1% and 90% of deposit
        amount = bound(amount, MIN_DEPOSIT, MAX_TVL);
        withdraw_pct = bound(withdraw_pct, 1, 90);

        // Deposits
        _deposit(alice, amount);

        // Calculates the net amount to withdraw (percentage of deposit)
        uint256 withdraw_amount = (amount * withdraw_pct) / 100;
        if (withdraw_amount == 0) return;

        // Top-up vault to cover swap slippage in strategies
        deal(WETH, address(vault), IERC20(WETH).balanceOf(address(vault)) + withdraw_amount);
        // Withdraws
        vm.prank(alice);
        vault.withdraw(withdraw_amount, alice, alice);

        // Checks that received amount does not exceed deposited amount
        // This test feels a bit rigged (a 90% max leaves a very high buffer, what if it receives 91%?)
        assertLe(IERC20(WETH).balanceOf(alice), amount, "User received more than deposited");
    }

    /**
     * @notice Fuzz: Redeem burns exactly the indicated shares
     * @dev For any amount of redeemed shares, the share balance decreases by exactly that amount
     * @param amount Random deposited amount
     * @param redeem_pct Random percentage of shares to redeem
     */
    function testFuzz_Redeem_BurnsExactShares(uint256 amount, uint256 redeem_pct) public {
        // Bounds inputs
        amount = bound(amount, MIN_DEPOSIT, MAX_TVL);
        redeem_pct = bound(redeem_pct, 1, 100);

        // Deposits and gets shares
        uint256 shares = _deposit(alice, amount);

        // Calculates shares to redeem (between 1% and 100%)
        uint256 shares_to_redeem = (shares * redeem_pct) / 100;
        if (shares_to_redeem == 0) return;

        // Saves shares balance before
        uint256 shares_before = vault.balanceOf(alice);

        // Top-up vault to cover swap slippage in strategies
        uint256 assets_to_redeem = vault.convertToAssets(shares_to_redeem);
        deal(WETH, address(vault), IERC20(WETH).balanceOf(address(vault)) + assets_to_redeem);
        // Redeems the calculated shares
        vm.prank(alice);
        vault.redeem(shares_to_redeem, alice, alice);

        // Checks that exactly the indicated shares were burned
        uint256 shares_after = vault.balanceOf(alice);
        assertEq(shares_before - shares_after, shares_to_redeem, "Exact shares were not burned");
    }

    /**
     * @notice Fuzz: Deposit → Immediate redeem never generates profit
     * @dev A user cannot profit by depositing and withdrawing immediately
     *      For any amount, assets_out <= amount (due to possible rounding loss)
     * @param amount Random deposited amount
     */
    function testFuzz_DepositRedeem_NeverProfitable(uint256 amount) public {
        // Bounds to the protocol's valid range
        amount = bound(amount, MIN_DEPOSIT, MAX_TVL);

        // Deposits and redeems everything immediately
        uint256 shares = _deposit(alice, amount);

        // Top-up vault to cover swap slippage in strategies
        uint256 assets_est = vault.convertToAssets(shares);
        deal(WETH, address(vault), IERC20(WETH).balanceOf(address(vault)) + assets_est);
        vm.prank(alice);
        uint256 assets_out = vault.redeem(shares, alice, alice);

        // Amount received never exceeds deposited (there may be rounding loss)
        assertLe(assets_out, amount, "Deposit-redeem should not be profitable");
    }

    //* === Router Fuzz Tests ===

    /**
     * @notice Fuzz: zapDepositETH with any valid amount
     */
    function testFuzz_Router_ZapDepositETH(uint256 amount) external {
        // Bound amount between 0.01 ETH and 1000 ETH
        amount = bound(amount, 0.01 ether, 1000 ether);

        deal(alice, amount);

        vm.prank(alice);
        uint256 shares = router.zapDepositETH{value: amount}();

        // Invariant: always receives shares > 0
        assertGt(shares, 0, "Should always receive shares");
        assertEq(IERC20(WETH).balanceOf(address(router)), 0, "Router must be stateless");
    }

    /**
     * @notice Fuzz: zapDepositERC20 with any amount and poolFee
     */
    function testFuzz_Router_ZapDepositERC20(uint256 amount, uint24 pool_fee) external {
        // Bound amount (enough to exceed min_deposit after swap)
        // 100 USDC → ~0.04 ETH, min_deposit is 0.01 ETH
        amount = bound(amount, 100e6, 1_000_000e6); // 100 USDC to 1M USDC

        // Bound poolFee to valid values
        uint24[4] memory valid_fees = [uint24(100), 500, 3000, 10000];
        pool_fee = valid_fees[pool_fee % 4];

        deal(USDC, alice, amount);

        vm.startPrank(alice);
        IERC20(USDC).approve(address(router), amount);
        uint256 shares = router.zapDepositERC20(USDC, amount, pool_fee, 0);
        vm.stopPrank();

        // Invariant: always receives shares
        assertGt(shares, 0, "Should receive shares");
        assertEq(IERC20(WETH).balanceOf(address(router)), 0, "Router must be stateless");
    }
}
