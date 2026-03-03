// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IStrategy} from "../strategies/IStrategy.sol";

/**
 * @title IStrategyManager
 * @author cristianrisueo
 * @notice Interface of the protocol strategy manager
 * @dev Coordinates asset allocation between multiple strategies (Aave, Compound, etc.),
 *      manages automatic rebalancing based on APY and executes reward harvests
 * @dev Just to clarify, I think it's worth mentioning: assets = underlying asset of the vault, you'll see
 *      it a lot in comments, in case it confuses you
 */
interface IStrategyManager {
    //* Structs

    /**
     * @notice Manager configuration parameters specific to the risk tier, passed in the constructor
     * @param max_allocation_per_strategy Maximum allocation per strategy in basis points
     * @param min_allocation_threshold Minimum allocation per strategy in basis points
     * @param rebalance_threshold Minimum APY difference to consider rebalancing
     * @param min_tvl_for_rebalance Minimum TVL to execute rebalance
     */
    struct TierConfig {
        uint256 max_allocation_per_strategy;
        uint256 min_allocation_threshold;
        uint256 rebalance_threshold;
        uint256 min_tvl_for_rebalance;
    }

    //* Events

    /**
     * @notice Emitted when assets are allocated to a specific strategy
     * @param strategy Address of the strategy receiving the assets
     * @param assets Amount of assets allocated to this strategy
     */
    event Allocated(address indexed strategy, uint256 assets);

    /**
     * @notice Emitted when capital is rebalanced between two strategies
     * @param from_strategy Source strategy from which assets are withdrawn
     * @param to_strategy Destination strategy to which assets are moved
     * @param assets Amount of assets rebalanced between strategies
     */
    event Rebalanced(address indexed from_strategy, address indexed to_strategy, uint256 assets);

    /**
     * @notice Emitted when harvest is executed on all active strategies
     * @param total_profit Total profit generated in assets summing all strategies
     */
    event Harvested(uint256 total_profit);

    /**
     * @notice Emitted when a new strategy is added to the pool of available strategies
     * @param strategy Address of the added strategy
     */
    event StrategyAdded(address indexed strategy);

    /**
     * @notice Emitted when a strategy is removed from the pool of active strategies
     * @param strategy Address of the removed strategy
     */
    event StrategyRemoved(address indexed strategy);

    /**
     * @notice Emitted when the asset allocation of strategies is updated
     * @dev This occurs when target percentages for each strategy are recalculated
     * @dev Normally this precedes a rebalance, so it would not be unusual to find the
     *      Rebalanced event after this one
     */
    event TargetAllocationUpdated();

    /**
     * @notice Emitted when a strategy fails during harvest
     * @param strategy Address of the strategy that failed
     * @param reason Reason for failure if available
     */
    event HarvestFailed(address indexed strategy, string reason);

    /**
     * @notice Emitted when the vault is initialized
     * @param vault Address of the authorized vault
     */
    event Initialized(address indexed vault);

    /**
     * @notice Emitted when an emergency exit is executed, withdrawing TVL from strategies to the vault
     * @param timestamp Timestamp of the block in which the emergency exit was executed
     * @param total_rescued Total assets rescued and transferred to the vault
     * @param strategies_drained Number of successfully drained strategies
     */
    event EmergencyExit(uint256 timestamp, uint256 total_rescued, uint256 strategies_drained);

    //* Main functions

    /**
     * @notice Allocates assets to strategies based on their current APY
     * @dev First receives assets from the vault, then distributes them among active strategies
     *      prioritizing those with higher APY. Distribution follows the target allocation calculated
     *      dynamically based on each strategy's APY at that moment
     * @param amount Amount of assets (WETH) to allocate among strategies
     */
    function allocate(uint256 amount) external;

    /**
     * @notice Withdraws assets from strategies proportionally to their current balance
     * @dev Iterates over all active strategies and withdraws proportionally according to the amount
     *      requested. Withdrawn assets are transferred directly to the specified receiver
     * @param amount Amount of assets (WETH) to withdraw from the total strategy pool
     * @param receiver Address that will receive the withdrawn assets (generally the vault)
     */
    function withdrawTo(uint256 amount, address receiver) external;

    /**
     * @notice Rebalances capital between strategies if the operation is profitable
     * @dev Analyzes the current APYs of all strategies and moves capital from lower
     *      APY ones to higher APY ones. Only executes if the expected profit is greater than 2x the
     *      gas cost, ensuring the rebalance is economically beneficial
     * @dev The 2x gas threshold avoids losses from frequent rebalancing with marginal gains
     */
    function rebalance() external;

    /**
     * @notice Executes harvest on all active protocol strategies
     * @dev Iterates over each strategy calling its harvest() function, collects all rewards,
     *      converts them to the base asset and automatically reinvests to maximize compound APY
     * @return total_profit Total profit generated in assets (WETH) summing all strategies
     */
    function harvest() external returns (uint256 total_profit);

    //* Strategy management functions (onlyOwner)

    /**
     * @notice Adds a new strategy to the pool of available strategies
     * @dev Can only be called by the owner. The strategy must implement IStrategy and use
     *      the same base asset as the rest of the protocol. Once added, the strategy will be
     *      available to receive allocations in future capital distributions
     * @param strategy Address of the strategy contract to add
     */
    function addStrategy(address strategy) external;

    /**
     * @notice Removes a strategy from the pool of active strategies
     * @dev Can only be called by the owner. IMPORTANT: Before removing a strategy,
     *      all its capital must have been withdrawn via withdraw, leaving its balance at 0.
     *      This prevents loss of funds when removing strategies with active capital
     * @param index Index of the strategy in the active strategies array
     */
    function removeStrategy(uint256 index) external;

    /**
     * @notice Drains all active strategies by transferring assets to the vault in case of emergency
     * @dev Can only be called by the owner. No timelock: in emergencies every second counts
     * @dev Uses try-catch: if a strategy fails, continues with the rest and emits HarvestFailed
     *      After executing, call vault.syncIdleBuffer() to reconcile the accounting
     * @dev REQUIRED sequence: vault.pause() → manager.emergencyExit() → vault.syncIdleBuffer()
     */
    function emergencyExit() external;

    //* Query functions

    /**
     * @notice Checks if a rebalance would be profitable at the current moment
     * @dev Calculates the APY difference between strategies and estimates whether moving capital would generate
     *      a profit greater than X times the gas cost. Used before calling rebalance() to
     *      avoid transactions that would result in a net loss
     * @return profitable True if the rebalance would be profitable, false otherwise
     */
    function shouldRebalance() external view returns (bool profitable);

    /**
     * @notice Returns the total value of assets under management across all strategies
     * @dev Sums the totalAssets() of each active strategy. Represents the TVL (Total Value Locked)
     *      of the strategy manager, including initial capital + accumulated yields from all strategies
     * @return total Total value in assets managed by the strategy manager
     */
    function totalAssets() external view returns (uint256 total);

    /**
     * @notice Returns the number of active strategies in the protocol
     * @dev Used to iterate over the strategies array or check how many strategies
     *      are currently operational and receiving allocations
     * @return count Number of active strategies
     */
    function strategiesCount() external view returns (uint256 count);

    /**
     * @notice Returns the strategy located at the specified index
     * @dev Allows direct access to any strategy in the active strategies array.
     *      Useful for iterating over all strategies or consulting a specific one
     * @param index Index of the strategy in the array (0-indexed)
     * @return strategy Instance of the strategy at that index
     */
    function strategies(uint256 index) external view returns (IStrategy strategy);

    /**
     * @notice Returns the asset allocation percentage for a specific strategy
     * @dev The target allocation is calculated dynamically based on each strategy's APY.
     *      Strategies with higher APY receive a greater percentage of total capital
     * @param strategy Address of the strategy to query
     * @return allocation_bps Target allocation in basis points (100 = 1%, 1000 = 10%, 10000 = 100%)
     */
    function target_allocation(IStrategy strategy) external view returns (uint256 allocation_bps);

    /**
     * @notice Returns the address of the protocol's main vault
     * @dev The vault is the contract that interacts directly with users (until the router arrives)
     *      and delegates asset management to the strategy manager. It is the entry point for deposits/withdrawals
     * @return vault_address Address of the vault contract
     */
    function vault() external view returns (address vault_address);

    /**
     * @notice Returns the address of the underlying asset managed by the protocol
     * @dev All strategies must use this same asset
     * @return asset_address Address of the token used as the underlying asset
     */
    function asset() external view returns (address asset_address);
}
