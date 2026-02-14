// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IStrategy} from "./IStrategy.sol";

/**
 * @title IStrategyManager
 * @author cristianrisueo
 * @notice Interface of the protocol's strategy manager
 * @dev Coordinates the allocation of assets between multiple strategies (Aave, Compound, etc.),
 *      manages automatic rebalancing based on APY and executes harvest of rewards
 * @dev Just to clarify, I think it's worth mentioning: assets = underlying asset of the vault, you'll see
 *      it a lot in comments, in case it confuses you
 */
interface IStrategyManager {
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
     * @dev This happens when the target percentages of each strategy are recalculated
     * @dev Normally this precedes a rebalance, so it wouldn't be unusual to find the
     *      Rebalanced event after this one
     */
    event TargetAllocationUpdated();

    /**
     * @notice Emitted when a strategy fails during harvest
     * @param strategy Address of the strategy that failed
     * @param reason Reason for the failure if available
     */
    event HarvestFailed(address indexed strategy, string reason);

    /**
     * @notice Emitted when the vault is initialized
     * @param vault Address of the authorized vault
     */
    event Initialized(address indexed vault);

    //* Main functions

    /**
     * @notice Allocates assets to strategies according to their current APY
     * @dev First receives the assets from the vault, then distributes them among active strategies
     *      prioritizing those with the highest APY. The distribution follows the target allocation calculated
     *      dynamically based on the APYs of each strategy at that moment
     * @param amount Amount of assets (WETH) to allocate among the strategies
     */
    function allocate(uint256 amount) external;

    /**
     * @notice Withdraws assets from strategies proportionally to their current balance
     * @dev Iterates over all active strategies and withdraws proportionally according to the requested
     *      amount. The withdrawn assets are transferred directly to the specified receiver
     * @param amount Amount of assets (WETH) to withdraw from the total strategy pool
     * @param receiver Address that will receive the withdrawn assets (generally the vault)
     */
    function withdrawTo(uint256 amount, address receiver) external;

    /**
     * @notice Rebalances capital between strategies if the operation is profitable
     * @dev Analyzes the current APYs of all strategies and moves capital from the lowest
     *      APY ones to the highest APY ones. Only executes if the expected profit is greater than 2x the gas
     *      cost, ensuring that the rebalance is economically beneficial
     * @dev The 2x gas threshold prevents losses from frequent rebalances with marginal gains
     */
    function rebalance() external;

    /**
     * @notice Executes harvest on all active strategies of the protocol
     * @dev Iterates over each strategy calling its harvest() function, collects all rewards,
     *      converts them to base asset and automatically reinvests to maximize compound APY
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

    //* Query functions

    /**
     * @notice Checks if a rebalance would be profitable at the current moment
     * @dev Calculates the APY difference between strategies and estimates whether moving capital would generate
     *      a profit greater than X the gas cost. Used before calling rebalance() to
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
     *      Useful for iterating over all strategies or querying a specific one
     * @param index Index of the strategy in the array (0-indexed)
     * @return strategy Instance of the strategy at that index
     */
    function strategies(uint256 index) external view returns (IStrategy strategy);

    /**
     * @notice Returns the asset allocation percentage for a specific strategy
     * @dev The target allocation is calculated dynamically based on the APY of each strategy.
     *      Strategies with higher APY receive a higher percentage of the total capital
     * @param strategy Address of the strategy to query
     * @return allocation_bps Target allocation in basis points (100 = 1%, 1000 = 10%, 10000 = 100%)
     */
    function target_allocation(IStrategy strategy) external view returns (uint256 allocation_bps);

    /**
     * @notice Returns the address of the protocol's main vault
     * @dev The vault is the contract that directly interacts with users (until the router arrives)
     *      and delegates asset management to the strategy manager. It is the entry point for deposits/withdrawals
     * @return vault_address Address of the vault contract
     */
    function vault() external view returns (address vault_address);

    /**
     * @notice Returns the address of the underlying asset managed by the protocol
     * @dev All strategies must use this same asset
     * @return asset_address Address of the token used as underlying asset
     */
    function asset() external view returns (address asset_address);
}
