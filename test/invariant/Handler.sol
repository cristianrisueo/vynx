// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../../src/core/Vault.sol";
import {Router} from "../../src/periphery/Router.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Handler
 * @author cristianrisueo
 * @notice Intermediary contract that bounds vault calls for invariant testing
 * @dev Without a handler, Foundry would call functions with invalid inputs and waste
 *      99% of the time on useless reverts. The handler guarantees that calls
 *      make sense, allowing the fuzzer to find real bugs
 */
contract Handler is Test {
    //* Variables de estado

    /// @notice Vault instance under test
    Vault public vault;

    /// @notice Router instance
    Router public router;

    /// @notice WETH contract address on Mainnet
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @notice USDC contract address on Mainnet
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @notice List of simulated users
    address[] public actors;

    /// @notice Ghost variables: total deposited and total withdrawn (for solvency verification)
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;

    //* Constructor

    /**
     * @notice Initializes the handler with the vault, router and available actors
     * @param _vault Vault instance under test
     * @param _router Router instance under test
     * @param _actors List of addresses that can interact
     */
    constructor(Vault _vault, Router _router, address[] memory _actors) {
        vault = _vault;
        router = _router;
        actors = _actors;
    }

    //* Bounded actions the fuzzer can execute

    /**
     * @notice Action: Deposit into the vault with bounded inputs
     * @dev The fuzzer picks a random actor and a valid amount,
     *      bounds amount between min_deposit and remaining TVL
     * @param actor_seed Seed to pick a random actor
     * @param amount Random amount to deposit
     */
    function deposit(uint256 actor_seed, uint256 amount) external {
        // Picks a random actor from the array
        address actor = actors[actor_seed % actors.length];

        // Gets maximum allowed TVL and current TVL
        uint256 max_tvl = vault.max_tvl();
        uint256 current_total = vault.totalAssets();

        // If maximum allowed TVL has been exceeded, does nothing
        if (current_total >= max_tvl) return;

        // Calculates available space in the vault (max_tvl - current_tvl)
        uint256 available = max_tvl - current_total;

        // Gets minimum deposit (0.001 WETH I think)
        uint256 min = vault.min_deposit();

        // If there is not enough space for the minimum deposit, does nothing
        if (available < min) return;

        // Bounds amount to the valid range
        amount = bound(amount, min, available);

        // Executes the deposit as the chosen actor
        deal(WETH, actor, amount);
        vm.startPrank(actor);

        IERC20(WETH).approve(address(vault), amount);
        vault.deposit(amount, actor);

        vm.stopPrank();

        // Updates ghost variable for tracking
        ghost_totalDeposited += amount;
    }

    /**
     * @notice Action: Withdraw from the vault with bounded inputs
     * @dev Only withdraws if the actor has shares. Bounds withdrawal to maximum possible
     * @param actor_seed Seed to pick a random actor
     * @param amount Random amount to withdraw
     */
    function withdraw(uint256 actor_seed, uint256 amount) external {
        // Picks a random actor
        address actor = actors[actor_seed % actors.length];

        // Checks that the actor has shares
        uint256 actor_shares = vault.balanceOf(actor);
        if (actor_shares == 0) return;

        // Calculates the maximum they can withdraw (net, after fees)
        // previewRedeem returns the net assets they would receive for their shares
        uint256 max_withdraw = vault.previewRedeem(actor_shares);
        if (max_withdraw == 0) return;

        // Bounds amount to the possible range (minimum 1 wei to avoid ZeroAmount)
        amount = bound(amount, 1, max_withdraw);

        // Executes the withdrawal
        vm.prank(actor);
        vault.withdraw(amount, actor, actor);

        // Updates ghost variable
        ghost_totalWithdrawn += amount;
    }

    /**
     * @notice Action: Executes harvest (collects strategy rewards)
     * @dev Random action 3: keeper executes harvest if minimum profit is present
     */
    function harvest() external {
        // Skips time to accumulate yield
        skip(bound(block.timestamp, 1 days, 7 days));

        // Only harvest if there is enough profit
        if (vault.totalAssets() > vault.min_profit_for_harvest()) {
            vault.harvest();
        }
    }

    //* === Router Actions ===

    /**
     * @notice Action: Deposit ETH via Router
     */
    function routerZapDepositETH(uint256 actor_seed, uint256 amount) external {
        address actor = actors[actor_seed % actors.length];

        uint256 max_tvl = vault.max_tvl();
        uint256 current_total = vault.totalAssets();

        if (current_total >= max_tvl) return;

        uint256 available = max_tvl - current_total;
        uint256 min = vault.min_deposit();

        if (available < min) return;

        amount = bound(amount, min, available);

        deal(actor, amount);

        vm.prank(actor);
        router.zapDepositETH{value: amount}();

        ghost_totalDeposited += amount;
    }

    /**
     * @notice Action: Deposit USDC via Router
     */
    function routerZapDepositUSDC(uint256 actor_seed, uint256 amount) external {
        address actor = actors[actor_seed % actors.length];

        uint256 max_tvl = vault.max_tvl();
        uint256 current_total = vault.totalAssets();

        if (current_total >= max_tvl) return;

        uint256 available = max_tvl - current_total;
        uint256 min = vault.min_deposit();

        if (available < min) return;

        // USDC has 6 decimals, WETH has 18
        // 1 USDC ~= 0.0004 WETH (assuming ETH price ~$2500)
        // Bound amount in USDC
        amount = bound(amount, min * 2500 / 1e12, available * 2500 / 1e12); // rough WETH → USDC conversion

        deal(USDC, actor, amount);

        vm.startPrank(actor);
        IERC20(USDC).approve(address(router), amount);
        router.zapDepositERC20(USDC, amount, 500, 0);
        vm.stopPrank();

        // Approximate deposited amount in WETH
        ghost_totalDeposited += amount * 1e12 / 2500;
    }

    /**
     * @notice Action: Withdraw via Router to ETH
     */
    function routerZapWithdrawETH(uint256 actor_seed, uint256 shares) external {
        address actor = actors[actor_seed % actors.length];

        uint256 actor_shares = vault.balanceOf(actor);
        if (actor_shares == 0) return;

        shares = bound(shares, 1, actor_shares);

        uint256 assets_to_withdraw = vault.previewRedeem(shares);

        vm.startPrank(actor);
        vault.approve(address(router), shares);
        router.zapWithdrawETH(shares);
        vm.stopPrank();

        ghost_totalWithdrawn += assets_to_withdraw;
    }
}
