// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IStrategy} from "../interfaces/strategies/IStrategy.sol";
import {IStrategyManager} from "../interfaces/core/IStrategyManager.sol";

/**
 * @title StrategyManager
 * @author cristianrisueo
 * @notice Brain of the VynX protocol that decides allocation and executes rebalancing
 * @dev Uses weighted allocation based on APY to diversify across DeFi strategies
 *      Coordinates harvest with fail-safe, optimal allocation and profitable rebalancing
 */
contract StrategyManager is IStrategyManager, Ownable {
    //* library attachments

    /**
     * @notice Uses SafeERC20 for all IERC20 operations safely
     * @dev Avoids common errors with legacy or poorly implemented tokens
     */
    using SafeERC20 for IERC20;

    //* Errors

    /**
     * @notice Error when there are no strategies available
     */
    error StrategyManager__NoStrategiesAvailable();

    /**
     * @notice Error when trying to add a duplicate strategy
     */
    error StrategyManager__StrategyAlreadyExists();

    /**
     * @notice Error when trying to remove a strategy that does not exist
     */
    error StrategyManager__StrategyNotFound();

    /**
     * @notice Error when the strategy has assets and cannot be removed
     */
    error StrategyManager__StrategyHasAssets();

    /**
     * @notice Error when the rebalance is not profitable
     */
    error StrategyManager__RebalanceNotProfitable();

    /**
     * @notice Error when trying to operate with a zero amount
     */
    error StrategyManager__ZeroAmount();

    /**
     * @notice Error when only the vault can call
     */
    error StrategyManager__OnlyVault();

    /**
     * @notice Error when trying to initialize an already initialized vault
     */
    error StrategyManager__VaultAlreadyInitialized();

    /**
     * @notice Error when the strategy asset does not match
     */
    error StrategyManager__AssetMismatch();

    /**
     * @notice Error when address(0) is passed as vault
     */
    error StrategyManager__InvalidVaultAddress();

    /**
     * @notice Error when a constructor parameter has an invalid value
     */
    error StrategyManager__InvalidParam();

    //* Structs and events: Inherited from the interface, no need to implement them

    //* Constants

    /// @notice Base for basis points calculations (100% = 10000 basis points)
    uint256 public constant BASIS_POINTS = 10000;

    /// @notice Maximum number of strategies allowed to prevent gas DoS in loops
    uint256 public constant MAX_STRATEGIES = 10;

    //* State variables

    /// @notice Address of the vault authorized to call allocate/withdraw/harvest
    address public vault;

    /// @notice Array of available strategies
    IStrategy[] public strategies;

    /// @notice Mapping to quickly verify if a strategy exists
    mapping(address => bool) public is_strategy;

    /// @notice Target allocation for strategies, in basis points (10000 = 100%)
    mapping(IStrategy => uint256) public target_allocation;

    /// @notice Address of the protocol's underlying asset
    address public immutable asset;

    /// @notice Minimum APY difference threshold to consider a rebalance, configured in the constructor according to the tier
    uint256 public rebalance_threshold;

    /// @notice Minimum TVL to execute a rebalance, configured in the constructor according to the tier
    uint256 public min_tvl_for_rebalance;

    /// @notice Maximum allocation per strategy in basis points, configured in the constructor according to the tier
    uint256 public max_allocation_per_strategy;

    /// @notice Minimum allocation per strategy in basis points, configured in the constructor according to the tier
    uint256 public min_allocation_threshold;

    //* Modifiers

    /**
     * @notice Only allows calls from the vault
     */
    modifier onlyVault() {
        if (msg.sender != vault) revert StrategyManager__OnlyVault();
        _;
    }

    //* Constructor and initialization function (chicken-egg problem, more info in comment)

    /**
     * @notice StrategyManager constructor
     * @dev Initializes with the address of the asset to manage and parameters specific to the risk tier
     * @param _asset Address of the underlying asset
     * @param params Operational manager parameters configurable by tier
     */
    constructor(address _asset, TierConfig memory params) Ownable(msg.sender) {
        // Checks that the asset is not address(0) and sets the asset
        if (_asset == address(0)) revert StrategyManager__AssetMismatch();
        asset = _asset;

        // Validates manager parameters specific to the risk tier configuration
        if (params.max_allocation_per_strategy == 0 || params.max_allocation_per_strategy > 10000) {
            revert StrategyManager__InvalidParam();
        }
        if (
            params.min_allocation_threshold == 0
                || params.min_allocation_threshold >= params.max_allocation_per_strategy
        ) {
            revert StrategyManager__InvalidParam();
        }
        if (params.rebalance_threshold == 0) revert StrategyManager__InvalidParam();
        if (params.min_tvl_for_rebalance == 0) revert StrategyManager__InvalidParam();

        // Assigns the tier parameters
        max_allocation_per_strategy = params.max_allocation_per_strategy;
        min_allocation_threshold = params.min_allocation_threshold;
        rebalance_threshold = params.rebalance_threshold;
        min_tvl_for_rebalance = params.min_tvl_for_rebalance;
    }

    /**
     * @notice Initializes the vault (only if not yet initialized)
     * @dev Resolves the circular dependency problem in deployment and testing
     *      Vault needs manager address and manager needs vault address
     *      In the manager constructor we no longer set the vault address, and once we have
     *      both contracts deployed we update the manager with the vault address
     * @dev Can only be called once, when vault == address(0)
     * @param _vault Address of the Vault
     */
    function initialize(address _vault) external onlyOwner {
        // Checks that the vault is not previously initialized and the received address != 0
        if (vault != address(0)) revert StrategyManager__VaultAlreadyInitialized();
        if (_vault == address(0)) revert StrategyManager__InvalidVaultAddress();

        // Sets the vault and emits event
        vault = _vault;
        emit Initialized(_vault);
    }

    //* Core business logic: Allocation, withdrawals and harvest (only vault)

    /**
     * @notice Deposits assets distributing them among strategies according to target allocation
     * @dev Can only be called by the vault
     * @dev The vault must transfer assets to this contract before calling
     * @param assets Amount of assets to invest in the strategies
     */
    function allocate(uint256 assets) external onlyVault {
        // Checks that the amount to transfer is not 0 and that strategies are available
        if (assets == 0) revert StrategyManager__ZeroAmount();
        if (strategies.length == 0) revert StrategyManager__NoStrategiesAvailable();

        // Calculates new target allocations based on current APYs (this one does change state)
        _calculateTargetAllocation();

        // Iterates over available strategies to distribute assets according to their new target allocation
        for (uint256 i = 0; i < strategies.length; i++) {
            // Gets the strategy and its target allocation
            IStrategy strategy = strategies[i];
            uint256 target = target_allocation[strategy];

            // If the strategy has allocation > 0, deposits proportionally
            if (target > 0) {
                // Calculates how much this strategy should receive (% of total)
                // The formula is: (amount * target) / BASIS_POINTS
                uint256 amount_for_strategy = (assets * target) / BASIS_POINTS;

                // Transfers the corresponding amount (a % of the total) to the strategy,
                // invokes that strategy's deposit method and emits event
                if (amount_for_strategy > 0) {
                    IERC20(asset).safeTransfer(address(strategy), amount_for_strategy);
                    strategy.deposit(amount_for_strategy);
                    emit Allocated(address(strategy), amount_for_strategy);
                }
            }
        }
    }

    /**
     * @notice Withdraws assets from the manager to the vault
     * @dev Can only be called by the vault
     * @dev Withdraws proportionally from each strategy to maintain their percentages equal,
     *      thanks to proportional withdrawal we don't need to call _calculateTargetAllocation
     *      saving a fucking ton of gas, because allocations remain in the same proportion
     * @param assets Amount of assets to withdraw
     * @param receiver Address that will receive the assets (must be the vault)
     */
    function withdrawTo(uint256 assets, address receiver) external onlyVault {
        // Checks that the amount to withdraw is not 0
        if (assets == 0) revert StrategyManager__ZeroAmount();

        // Gets the total assets of the manager. If it has no assets returns without doing anything
        uint256 total_assets = totalAssets();
        if (total_assets == 0) return;

        // Accumulator of what was actually withdrawn from each strategy (external protocols round down -1w)
        uint256 total_withdrawn = 0;

        // Iterates over each strategy to withdraw proportionally
        for (uint256 i = 0; i < strategies.length; i++) {
            // Gets the strategy and its current balance
            IStrategy strategy = strategies[i];
            uint256 strategy_balance = strategy.totalAssets();

            // If its balance is 0 skip this iteration
            if (strategy_balance == 0) continue;

            // Calculates how much to withdraw from this strategy (proportional to its balance)
            uint256 to_withdraw = (assets * strategy_balance) / total_assets;

            // If we need to withdraw from this strategy we use the accumulator to track what was actually withdrawn
            // normally it's ~1 wei, but could be 2
            if (to_withdraw > 0) {
                uint256 actual = strategy.withdraw(to_withdraw);
                total_withdrawn += actual;
            }
        }

        // Transfers to the vault what was actually withdrawn (99% sure it will be less than requested)
        if (total_withdrawn > 0) {
            IERC20(asset).safeTransfer(receiver, total_withdrawn);
        }
    }

    /**
     * @notice Executes harvest on all active strategies and sums the profits
     * @dev Can only be called by the vault (users call Vault.harvest, not Manager.harvest)
     * @dev Uses try-catch for fail-safe: if a strategy fails due to external issues
     *      it continues with the rest and emits an error event. This approach prevents a broken
     *      strategy from blocking the harvest of all the others
     * @return total_profit Sum of profits from all strategies converted to assets
     */
    function harvest() external onlyVault returns (uint256 total_profit) {
        // Profit accumulator (in asset managed by the protocol) from all strategies
        total_profit = 0;

        // Iterates over strategies and executes their harvest with try-catch for safety
        for (uint256 i = 0; i < strategies.length; i++) {
            IStrategy strategy = strategies[i];

            // If the harvest was successful, accumulates the profit from this strategy
            // If it fails with or without an error message, emits event but continues
            try strategy.harvest() returns (uint256 strategy_profit) {
                total_profit += strategy_profit;
            } catch Error(string memory reason) {
                emit HarvestFailed(address(strategy), reason);
            } catch {
                emit HarvestFailed(address(strategy), "Unknown error");
            }
        }

        // Emits harvest event and returns the accumulator
        emit Harvested(total_profit);
    }

    //* Primary business logic: Rebalance (external so anyone can execute the rebalancing)
    //* This avoids centralizing strategy rebalancing and economically incentivizes participation

    /**
     * @notice Rebalances capital between strategies if the operation is profitable
     * @dev Moves capital from low APY strategies towards high APY strategies
     * @dev Anyone can call this function if shouldRebalance()
     */
    function rebalance() external {
        // Checks if rebalancing is profitable. If not, reverts
        bool should_rebalance = shouldRebalance();
        if (!should_rebalance) revert StrategyManager__RebalanceNotProfitable();

        // Recalculates target allocations and gets the protocol TVL
        // These two lines get what percentage to distribute and how much we have to distribute
        _calculateTargetAllocation();
        uint256 total_tvl = totalAssets();

        // Empty arrays for tracking: Strategies with excess funds and how much excess they have
        IStrategy[] memory strategies_with_excess = new IStrategy[](strategies.length);
        uint256[] memory excess_amounts = new uint256[](strategies.length);

        // Empty arrays for tracking: Strategies needing funds and how much they need
        IStrategy[] memory strategies_needing_funds = new IStrategy[](strategies.length);
        uint256[] memory needed_amounts = new uint256[](strategies.length);

        // Tracking variables: Counters for strategies with excess and those needing funds
        uint256 excess_count = 0;
        uint256 needed_count = 0;

        // Iterates over strategies to find those with excess or needing funds
        for (uint256 i = 0; i < strategies.length; i++) {
            // Gets strategy i
            IStrategy strategy = strategies[i];

            // Gets its current balance and its target balance (what it should have) based on allocation
            uint256 current_balance = strategy.totalAssets();
            uint256 target_balance = (total_tvl * target_allocation[strategy]) / BASIS_POINTS;

            // If it has excess funds: Adds strategy and excess to tracking arrays and increments count
            if (current_balance > target_balance) {
                strategies_with_excess[excess_count] = strategy;
                excess_amounts[excess_count] = current_balance - target_balance;
                excess_count++;
            }
            // If it needs funds: Does the same with its corresponding arrays and count
            else if (target_balance > current_balance) {
                strategies_needing_funds[needed_count] = strategy;
                needed_amounts[needed_count] = target_balance - current_balance;
                needed_count++;
            }
        }

        // Iterates over the counter of strategies with excess to move funds from excess strat -> needing strat
        for (uint256 i = 0; i < excess_count; i++) {
            // Gets the excess strategy i, and its excess amount
            IStrategy from_strategy = strategies_with_excess[i];
            uint256 available = excess_amounts[i];

            // Withdraws the excess amount from strategy i. At this point the surplus is already in the manager
            from_strategy.withdraw(available);

            // Iterates over the counter of strategies needing funds while excess is still available
            for (uint256 j = 0; j < needed_count && available > 0; j++) {
                // Gets the needing strategy j, and its needed amount
                IStrategy to_strategy = strategies_needing_funds[j];
                uint256 needed = needed_amounts[j];

                // If it needs funds (or still needs them after receiving all the excess from the first strategy)
                if (needed > 0) {
                    // Gets the minimum amount between what i has excess and what j needs
                    uint256 to_transfer = available > needed ? needed : available;

                    // Transfers the minimum amount to the strategy that needs it, deposits it and emits event
                    IERC20(asset).safeTransfer(address(to_strategy), to_transfer);
                    to_strategy.deposit(to_transfer);
                    emit Rebalanced(address(from_strategy), address(to_strategy), to_transfer);

                    // Updates counters: Subtracts the transferred amount from available excess and from needed
                    available -= to_transfer;
                    needed_amounts[j] -= to_transfer;
                }
            }
        }

        // Emits target allocation update event
        emit TargetAllocationUpdated();
    }

    //* Strategy management functions (onlyOwner)

    /**
     * @notice Adds a new strategy to the pool of available strategies
     * @dev Can only be called by the owner
     * @dev Validates that the strategy does not already exist and uses the same asset
     * @param strategy Address of the strategy contract to add
     */
    function addStrategy(address strategy) external onlyOwner {
        // Quickly checks if the strategy was already added. If so, reverts
        if (is_strategy[strategy]) revert StrategyManager__StrategyAlreadyExists();

        // Checks that the maximum number of allowed strategies is not exceeded
        if (strategies.length >= MAX_STRATEGIES) revert StrategyManager__NoStrategiesAvailable();

        // Checks that the strategy uses the same asset as the manager
        IStrategy strategy_interface = IStrategy(strategy);
        if (strategy_interface.asset() != asset) revert StrategyManager__AssetMismatch();

        // Adds the strategy to the array and its address to the quick verification mapping
        strategies.push(strategy_interface);
        is_strategy[strategy] = true;

        // Recalculates allocations for all strategies. Since we have added
        // this strategy, we need to recalculate percentages again
        _calculateTargetAllocation();

        // Emits strategy added event
        emit StrategyAdded(strategy);
    }

    /**
     * @notice Removes a strategy from the manager
     * @dev Only the owner can remove strategies
     * @dev The strategy must have zero balance before being removed (use withdraw first)
     * @param index Index of the strategy in the array
     */
    function removeStrategy(uint256 index) external onlyOwner {
        // Checks that the index is valid
        if (index >= strategies.length) revert StrategyManager__StrategyNotFound();

        // Gets the strategy at that index, and from the strategy its address
        IStrategy strategy = strategies[index];
        address strategy_address = address(strategy);

        // Checks that the strategy has no assets under management (prevents loss of funds)
        if (strategy.totalAssets() > 0) revert StrategyManager__StrategyHasAssets();

        // Deletes the allocation (% of TVL) of this strategy before removing it
        delete target_allocation[strategy];

        // Removes the strategy from the array and its address from the quick verification mapping
        // Uses the swap&pop strategy because it saves gas (I think that's what it's called)
        strategies[index] = strategies[strategies.length - 1];
        strategies.pop();
        is_strategy[strategy_address] = false;

        // Recalculates allocations for the remaining strategies. Since we have removed
        // this strategy, its allocation (% TVL) is available for the others
        if (strategies.length > 0) {
            _calculateTargetAllocation();
        }

        // Emits strategy removed event
        emit StrategyRemoved(strategy_address);
    }

    //* Parameter setters

    /**
     * @notice Updates the minimum threshold for rebalancing
     * @dev Percentage of APY improvement in the new strategy to consider rebalancing
     * @param new_threshold New threshold in basis points
     */
    function setRebalanceThreshold(uint256 new_threshold) external onlyOwner {
        rebalance_threshold = new_threshold;
    }

    /**
     * @notice Updates the minimum TVL for rebalancing
     * @dev How many assets the idle buffer must accumulate to consider rebalancing
     * @param new_min_tvl New minimum TVL in wei
     */
    function setMinTVLForRebalance(uint256 new_min_tvl) external onlyOwner {
        min_tvl_for_rebalance = new_min_tvl;
    }

    /**
     * @notice Updates the maximum allocation % per strategy
     * @dev After updating the maximum, recalculates allocations again
     * @param new_max New maximum in basis points
     */
    function setMaxAllocationPerStrategy(uint256 new_max) external onlyOwner {
        max_allocation_per_strategy = new_max;
        _calculateTargetAllocation();
    }

    /**
     * @notice Updates the minimum allocation threshold
     * @dev After updating the minimum, recalculates allocations again
     * @param new_min New minimum in basis points
     */
    function setMinAllocationThreshold(uint256 new_min) external onlyOwner {
        min_allocation_threshold = new_min;
        _calculateTargetAllocation();
    }

    //* Emergency function: Full drain of strategies in case of critical bug (onlyOwner)

    /**
     * @notice Withdraws TVL from all strategies to the vault so users can withdraw
     * @dev onlyOwner and without timelock. In case of a bug every second counts
     *
     * @dev Uses try-catch to prevent a buggy strategy from blocking the rescue of the rest
     *      If a strategy fails, emits HarvestFailed and continues with the others
     *      The owner/team must handle the problematic strategy manually and separately (what a pain)
     *
     * @dev MANDATORY EMERGENCY SEQUENCE (3 separate, non-atomic transactions):
     *      1. vault.pause()            - Stops new deposits (withdraw remains enabled)
     *      2. manager.emergencyExit()  - Drains strategies and transfers WETH to the vault
     *      3. vault.syncIdleBuffer()   - Reconciles idle_buffer with the actual vault balance
     *
     * @dev WARNING: If Vault and Manager have different owners, each owner executes their step
     *      If emergencyExit() reverts completely, the vault remains paused but funds
     *      stay in strategies — no asset is lost. Must diagnose, withdraw manually
     *      and return to users via some mechanism (god help me if I ever have to call this function)
     *
     * @dev The goal is for funds to move from strategies to the vault and for users to withdraw, while
     *      the owner/team creates a new version and redeploys for deposits. Priority = Don't lose funds
     */
    function emergencyExit() external onlyOwner {
        // Accumulators: total rescued and successfully drained strategies
        uint256 total_rescued = 0;
        uint256 strategies_drained = 0;

        // Iterates all active strategies and withdraws all of their assets
        for (uint256 i = 0; i < strategies.length; i++) {
            // Gets the balance of strategy i
            IStrategy strategy = strategies[i];
            uint256 strategy_balance = strategy.totalAssets();

            // If the strategy has no funds, skip this iteration
            if (strategy_balance == 0) continue;

            // Tries to withdraw all assets from the strategy. If there are errors, emits them and continues
            try strategy.withdraw(strategy_balance) returns (uint256 actual_withdrawn) {
                total_rescued += actual_withdrawn;
                strategies_drained++;
            } catch Error(string memory reason) {
                emit HarvestFailed(address(strategy), reason);
            } catch {
                emit HarvestFailed(address(strategy), "EmergencyExit: unknown error");
            }
        }

        // Transfers everything rescued to the vault in a single transfer
        if (total_rescued > 0) {
            IERC20(asset).safeTransfer(vault, total_rescued);
        }

        // Emits event with withdrawal information: Timestamp, totalAssets, strategies
        emit EmergencyExit(block.timestamp, total_rescued, strategies_drained);
    }

    //* Query functions: Rebalance check, protocol TVL, stats and strategy count

    /**
     * @notice Checks if a rebalance would be beneficial at the current moment
     * @dev Validates: enough strategies, minimum TVL and significant APY difference
     * @dev Keepers calculate profitability vs gas cost off-chain before executing
     * @return profitable True if conditions for rebalancing are met
     */
    function shouldRebalance() public view returns (bool profitable) {
        // If there are not enough strategies, there is nothing to rebalance
        if (strategies.length < 2) return false;

        // If TVL is below the established minimum, it is not worth rebalancing
        if (totalAssets() < min_tvl_for_rebalance) return false;

        // Variables for tracking APY differences
        uint256 max_apy = 0;
        uint256 min_apy = type(uint256).max;

        // Iterates over strategies to find the one with the highest and lowest APY
        for (uint256 i = 0; i < strategies.length; i++) {
            uint256 strategy_apy = strategies[i].apy();

            if (strategy_apy > max_apy) max_apy = strategy_apy;
            if (strategy_apy < min_apy) min_apy = strategy_apy;
        }

        // Rebalance is beneficial if the APY difference exceeds the rebalance threshold
        return (max_apy - min_apy) >= rebalance_threshold;
    }

    /**
     * @notice Returns the total assets under management by the manager in the strategies
     * @dev Sum of assets from all strategies, they will have xToken, the sum will come
     *      converted to assets
     * @return total Sum of assets in all strategies
     */
    function totalAssets() public view returns (uint256 total) {
        for (uint256 i = 0; i < strategies.length; i++) {
            total += strategies[i].totalAssets();
        }
    }

    /**
     * @notice Returns the number of available strategies
     * @return count Number of strategies
     */
    function strategiesCount() external view returns (uint256 count) {
        return strategies.length;
    }

    /**
     * @notice Returns information about all strategies
     * @dev WARNING: Gas intensive (+1M approx), only use for off-chain queries
     *      or frontend. If you call it from another contract, on your own head be it buddy
     * @return names Names of the strategies
     * @return apys APYs of each strategy
     * @return tvls TVL of each strategy
     * @return targets Target allocation of each strategy
     */
    function getAllStrategiesInfo()
        external
        view
        returns (string[] memory names, uint256[] memory apys, uint256[] memory tvls, uint256[] memory targets)
    {
        // Gets the size of the strategies array
        uint256 length = strategies.length;

        // Creates the info arrays with the set strategies size
        names = new string[](length);
        apys = new uint256[](length);
        tvls = new uint256[](length);
        targets = new uint256[](length);

        // Iterates the strategies array and sets values in the new arrays
        for (uint256 i = 0; i < length; i++) {
            names[i] = strategies[i].name();
            apys[i] = strategies[i].apy();
            tvls[i] = strategies[i].totalAssets();
            targets[i] = target_allocation[strategies[i]];
        }
    }

    //* Internal functions used by the rest of the contract methods

    /**
     * @notice Calculates allocation targets for each strategy based on APY
     *         Reminder: Target allocation = % of TVL that goes to each strategy
     * @dev Internal helper used by shouldRebalance and _calculateTargetAllocation
     * @dev Applies caps (max 50%, min 10%) and normalizes so they sum to 100%
     * @return targets Array with allocation in basis points per strategy
     */
    function _computeTargets() internal view returns (uint256[] memory targets) {
        // If there are no strategies returns empty array
        if (strategies.length == 0) {
            return new uint256[](0);
        }

        // If there are strategies creates array for the calculated targets sized to number of strategies
        targets = new uint256[](strategies.length);

        // Sums the APYs of all active strategies
        uint256 total_apy = 0;

        for (uint256 i = 0; i < strategies.length; i++) {
            total_apy += strategies[i].apy();
        }

        // If there is no APY (imagine all at 0%), distributes TVL equally and returns
        if (total_apy == 0) {
            uint256 equal_share = BASIS_POINTS / strategies.length;

            for (uint256 i = 0; i < strategies.length; i++) {
                targets[i] = equal_share;
            }

            return targets;
        }

        // This is the normal scenario. Calculates targets based on APY and applies caps
        for (uint256 i = 0; i < strategies.length; i++) {
            // Gets the strategy's APY, and calculates its uncapped target
            uint256 strategy_apy = strategies[i].apy();
            uint256 uncapped_target = (strategy_apy * BASIS_POINTS) / total_apy;

            // If it exceeds the maximum, its target allocation is the maximum
            if (uncapped_target > max_allocation_per_strategy) {
                targets[i] = max_allocation_per_strategy;
            }
            // If it does not reach the minimum, its target allocation is 0
            else if (uncapped_target < min_allocation_threshold) {
                targets[i] = 0;
            }
            // If it is between the maximum and minimum, it keeps the calculated value
            else {
                targets[i] = uncapped_target;
            }
        }

        // Normalizes targets so they sum to exactly BASIS_POINTS (100%)
        uint256 total_targets = 0;
        for (uint256 i = 0; i < strategies.length; i++) {
            total_targets += targets[i];
        }

        // If they don't sum to BASIS_POINTS, redistributes proportionally
        if (total_targets > 0 && total_targets != BASIS_POINTS) {
            for (uint256 i = 0; i < strategies.length; i++) {
                targets[i] = (targets[i] * BASIS_POINTS) / total_targets;
            }
        }

        // Returns array of calculated targets
        return targets;
    }

    /**
     * @notice Calculates the target allocation for each strategy based on APY
     *         Reminder: Target allocation = % of TVL that goes to each strategy
     * @dev Uses weighted allocation to distribute TVL -> higher APY = higher percentage
     *      This is the function used by the rest of the contract's main logic methods
     * @dev Applies limits, max 50%, min 10% (in case you hear limits = caps)
     */
    function _calculateTargetAllocation() internal {
        // If there are no strategies returns
        if (strategies.length == 0) return;

        // Calculates targets using internal function
        uint256[] memory computed_allocations = _computeTargets();

        // Writes the calculated targets to storage (the mapping)
        for (uint256 i = 0; i < strategies.length; i++) {
            target_allocation[strategies[i]] = computed_allocations[i];
        }

        // Emits target allocations updated event
        emit TargetAllocationUpdated();
    }
}
