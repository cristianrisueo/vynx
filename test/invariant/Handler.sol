// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../../src/core/Vault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Handler
 * @author cristianrisueo
 * @notice Intermediary contract that bounds calls to the vault for invariant testing
 * @dev Without a handler, Foundry would call functions with invalid inputs and waste
 *      99% of the time on useless reverts. The handler ensures that calls
 *      make sense, allowing the fuzzer to find real bugs
 */
contract Handler is Test {
    //* State variables

    /// @notice Instance of the vault being tested
    Vault public vault;

    /// @notice WETH contract address on Mainnet
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @notice List of simulated users
    address[] public actors;

    /// @notice Ghost variables: total deposited and total withdrawn (for solvency verification)
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;

    //* Constructor

    /**
     * @notice Initializes the handler with the vault and available actors
     * @param _vault Instance of the vault to test
     * @param _actors List of addresses that can interact
     */
    constructor(Vault _vault, address[] memory _actors) {
        vault = _vault;
        actors = _actors;
    }

    //* Bounded actions that the fuzzer can execute

    /**
     * @notice Action: Deposit into the vault with bounded inputs
     * @dev The fuzzer picks a random actor and a valid amount,
     *      bounds amount between min_deposit and what's left of TVL
     * @param actor_seed Seed to pick a random actor
     * @param amount Random amount to deposit
     */
    function deposit(uint256 actor_seed, uint256 amount) external {
        // Pick a random actor from the array
        address actor = actors[actor_seed % actors.length];

        // Get the maximum allowed TVL and current TVL
        uint256 max_tvl = vault.max_tvl();
        uint256 current_total = vault.totalAssets();

        // If the maximum allowed TVL has already been exceeded, do nothing
        if (current_total >= max_tvl) return;

        // Calculate the available space in the vault (max_tvl - current_tvl)
        uint256 available = max_tvl - current_total;

        // Get the minimum deposit (0.001 WETH if I remember correctly)
        uint256 min = vault.min_deposit();

        // If there's not enough space for the minimum deposit, do nothing
        if (available < min) return;

        // Bound amount to the valid range
        amount = bound(amount, min, available);

        // Execute the deposit as the chosen actor
        deal(WETH, actor, amount);
        vm.startPrank(actor);

        IERC20(WETH).approve(address(vault), amount);
        vault.deposit(amount, actor);

        vm.stopPrank();

        // Update ghost variable for tracking
        ghost_totalDeposited += amount;
    }

    /**
     * @notice Action: Withdraw from the vault with bounded inputs
     * @dev Only withdraws if the actor has shares. Bounds the withdrawal to the maximum possible
     * @param actor_seed Seed to pick a random actor
     * @param amount Random amount to withdraw
     */
    function withdraw(uint256 actor_seed, uint256 amount) external {
        // Pick a random actor
        address actor = actors[actor_seed % actors.length];

        // Check that the actor has shares
        uint256 actor_shares = vault.balanceOf(actor);
        if (actor_shares == 0) return;

        // Calculate the maximum they can withdraw (net, after fees)
        // previewRedeem returns net assets they would receive for their shares
        uint256 max_withdraw = vault.previewRedeem(actor_shares);
        if (max_withdraw == 0) return;

        // Bound amount to the possible range (minimum 1 wei to avoid ZeroAmount)
        amount = bound(amount, 1, max_withdraw);

        // Execute the withdrawal
        vm.prank(actor);
        vault.withdraw(amount, actor, actor);

        // Update ghost variable
        ghost_totalWithdrawn += amount;
    }

    /**
     * @notice Action: Execute harvest (collects rewards from strategies)
     * @dev Random action 3: keeper executes harvest if there's minimum profit
     */
    function harvest() external {
        // Skip time to accumulate yield
        skip(bound(block.timestamp, 1 days, 7 days));

        // Only harvest if there's enough profit
        if (vault.totalAssets() > vault.min_profit_for_harvest()) {
            vault.harvest();
        }
    }
}
