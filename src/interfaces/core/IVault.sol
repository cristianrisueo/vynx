// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title IVault
 * @author cristianrisueo
 * @notice Interface of the protocol's vault
 * @dev The vault acts as the entry point for users and delegates capital management to the strategy manager
 * @dev Extends the ERC4626 standard (Tokenized Vaults) with specific functionalities for
 *      active yield management:
 *      - Idle buffer management (unallocated liquidity buffer)
 *      - Automatic harvest of rewards from all strategies and distribution of performance fees
 *        between treasury and founder
 */
interface IVault is IERC4626 {
    //* Events

    /**
     * @notice Emitted when a user deposits assets into the vault
     * @param user Address of the user making the deposit
     * @param assets Amount of assets deposited
     * @param shares Amount of shares (vault tokens) received by the user
     */
    event Deposited(address indexed user, uint256 assets, uint256 shares);

    /**
     * @notice Emitted when a user withdraws assets from the vault
     * @param user Address of the user making the withdrawal
     * @param assets Amount of assets withdrawn
     * @param shares Amount of shares (vault tokens) burned
     */
    event Withdrawn(address indexed user, uint256 assets, uint256 shares);

    /**
     * @notice Emitted when harvest is executed on the vault collecting profits from strategies
     * @param profit Total profit generated in assets before deducting performance fees
     * @param performance_fee Amount of performance fee charged on the profit
     * @param timestamp Timestamp of when the harvest was executed
     */
    event Harvested(uint256 profit, uint256 performance_fee, uint256 timestamp);

    /**
     * @notice Emitted when performance fees are distributed between treasury and founder
     * @param treasury_amount Amount of assets sent to the treasury address
     * @param founder_amount Amount of assets sent to the founder address
     */
    event PerformanceFeeDistributed(uint256 treasury_amount, uint256 founder_amount);

    /**
     * @notice Emitted when idle assets are allocated to strategies through the strategy manager
     * @param amount Amount of idle assets that were allocated to strategies
     */
    event IdleAllocated(uint256 amount);

    /**
     * @notice Emitted when the strategy manager address is updated
     * @param new_manager New address of the strategy manager that will manage the strategies
     */
    event StrategyManagerUpdated(address indexed new_manager);

    /**
     * @notice Emitted when the performance fee is updated
     * @param old_fee Previous performance fee in basis points
     * @param new_fee New performance fee in basis points
     */
    event PerformanceFeeUpdated(uint256 old_fee, uint256 new_fee);

    /**
     * @notice Emitted when the fee split between treasury and founder is updated
     * @param treasury_split New percentage for treasury in basis points
     * @param founder_split New percentage for founder in basis points
     */
    event FeeSplitUpdated(uint256 treasury_split, uint256 founder_split);

    /**
     * @notice Emitted when the minimum deposit is updated
     * @param old_min Previous minimum deposit
     * @param new_min New minimum deposit
     */
    event MinDepositUpdated(uint256 old_min, uint256 new_min);

    /**
     * @notice Emitted when the idle threshold is updated
     * @param old_threshold Previous threshold
     * @param new_threshold New threshold
     */
    event IdleThresholdUpdated(uint256 old_threshold, uint256 new_threshold);

    /**
     * @notice Emitted when the maximum TVL is updated
     * @param old_max Previous maximum TVL
     * @param new_max New maximum TVL
     */
    event MaxTVLUpdated(uint256 old_max, uint256 new_max);

    /**
     * @notice Emitted when the treasury address is updated
     * @param old_treasury Previous treasury address
     * @param new_treasury New treasury address
     */
    event TreasuryUpdated(address indexed old_treasury, address indexed new_treasury);

    /**
     * @notice Emitted when the founder address is updated
     * @param old_founder Previous founder address
     * @param new_founder New founder address
     */
    event FounderUpdated(address indexed old_founder, address indexed new_founder);

    /**
     * @notice Emitted when an official keeper is added or removed
     * @param keeper Address of the keeper
     * @param status True if added, false if removed
     */
    event OfficialKeeperUpdated(address indexed keeper, bool status);

    /**
     * @notice Emitted when the minimum profit for harvest is updated
     * @param old_min Previous minimum profit
     * @param new_min New minimum profit
     */
    event MinProfitForHarvestUpdated(uint256 old_min, uint256 new_min);

    /**
     * @notice Emitted when the incentive for external keepers is updated
     * @param old_incentive Previous incentive in basis points
     * @param new_incentive New incentive in basis points
     */
    event KeeperIncentiveUpdated(uint256 old_incentive, uint256 new_incentive);

    //* Main functions

    /**
     * @notice Harvests rewards from all active strategies and distributes performance fees
     * @dev Calls strategyManager.harvest() to collect profits from all strategies,
     *      calculates the performance fee on the total profit, distributes fees between treasury
     *      and founder according to the configured splits, and updates the lastHarvest timestamp
     * @dev Public function with no restrictions: any address can execute harvest for
     *      the benefit of the protocol (incentivizing frequent execution via keeper bots)
     * @return profit Total profit harvested in assets before deducting performance fees
     */
    function harvest() external returns (uint256 profit);

    /**
     * @notice Allocates idle buffer assets from the vault to strategies through the strategy manager
     * @dev Only executes if idleBuffer >= idleThreshold, avoiding unnecessary gas on small
     *      allocations. Idle assets accumulate mainly from new user deposits
     *      that have not yet been allocated to productive strategies
     * @dev Public function with no restrictions: any address can call it when the
     *      threshold is reached, incentivizing efficient allocation of idle capital
     */
    function allocateIdle() external;

    //* Administrative functions - Protocol parameter setters

    /**
     * @notice Updates the performance fee charged on profits
     * @dev Can only be called by the vault owner
     * @param new_fee New performance fee in basis points (must be <= BASIS_POINTS)
     */
    function setPerformanceFee(uint256 new_fee) external;

    /**
     * @notice Updates the performance fee split between treasury and founder
     * @dev Can only be called by the vault owner
     * @param new_treasury New percentage for treasury in basis points
     * @param new_founder New percentage for founder in basis points
     * @dev The sum of both must be exactly BASIS_POINTS (10000)
     */
    function setFeeSplit(uint256 new_treasury, uint256 new_founder) external;

    /**
     * @notice Updates the minimum allowed deposit
     * @dev Can only be called by the vault owner
     * @param new_min New minimum deposit in assets
     */
    function setMinDeposit(uint256 new_min) external;

    /**
     * @notice Updates the idle asset threshold for executing allocation
     * @dev Can only be called by the vault owner
     * @param new_threshold New threshold in assets
     */
    function setIdleThreshold(uint256 new_threshold) external;

    /**
     * @notice Updates the maximum allowed TVL in the vault
     * @dev Can only be called by the vault owner
     * @param new_max New maximum TVL in assets
     */
    function setMaxTVL(uint256 new_max) external;

    /**
     * @notice Updates the treasury address
     * @dev Can only be called by the vault owner
     * @param new_treasury New treasury address (cannot be address(0))
     */
    function setTreasury(address new_treasury) external;

    /**
     * @notice Updates the founder address
     * @dev Can only be called by the vault owner
     * @param new_founder New founder address (cannot be address(0))
     */
    function setFounder(address new_founder) external;

    /**
     * @notice Updates the strategy manager address
     * @dev Can only be called by the vault owner
     * @param new_manager New strategy manager address (cannot be address(0))
     */
    function setStrategyManager(address new_manager) external;

    /**
     * @notice Updates the minimum profit required to execute harvest
     * @dev Can only be called by the vault owner
     * @param new_min New minimum profit in assets
     */
    function setMinProfitForHarvest(uint256 new_min) external;

    /**
     * @notice Updates the incentive for external keepers that execute harvest
     * @dev Can only be called by the vault owner
     * @param new_incentive New incentive in basis points (must be <= BASIS_POINTS)
     */
    function setKeeperIncentive(uint256 new_incentive) external;

    //* Query functions - Protocol parameter and treasury getters

    /**
     * @notice Returns the performance fee percentage charged on generated profits (yield)
     * @dev In basis points: 100 = 1%, 1000 = 10%. This fee is charged on the profit generated
     *      by the strategies on each harvest and is distributed between treasury and founder
     * @return fee_bps Performance fee in basis points
     */
    function performance_fee() external view returns (uint256 fee_bps);

    /**
     * @notice Percentage of the performance fee allocated to the treasury
     * @dev In basis points over the total performance fee (not over the total profit).
     * @return split_bps Treasury split in basis points (must add up to BASIS_POINTS with founder_split)
     */
    function treasury_split() external view returns (uint256 split_bps);

    /**
     * @notice Returns the percentage of the performance fee allocated to the founder
     * @dev In basis points over the total performance fee (not over the total profit).
     * @return split_bps Founder split in basis points (must add up to BASIS_POINTS with treasury_split)
     */
    function founder_split() external view returns (uint256 split_bps);

    /**
     * @notice Returns the minimum allowed deposit in the vault
     * @dev Prevents extremely small deposits that are not economically efficient
     *      due to gas cost. Deposits smaller than this threshold will be reverted
     * @return min_amount Minimum amount of assets for a valid deposit
     */
    function minDeposit() external view returns (uint256 min_amount);

    /**
     * @notice Returns the asset limit in the idle buffer required to execute allocateIdle()
     * @dev Prevents uneconomical allocations. Only when idleBuffer >= idleThreshold is
     *      the gas cost of allocating capital to strategies justified. Below this
     *      threshold, allocateIdle() will not execute anything
     * @return threshold Minimum limit of idle assets to perform allocation
     */
    function idleThreshold() external view returns (uint256 threshold);

    /**
     * @notice Returns the maximum allowed TVL in the vault (circuit breaker)
     * @dev Safety limit to prevent excessive risk in the early phase. Deposits that
     *      exceed this limit will be reverted, protecting the protocol while its
     *      robustness is being demonstrated. Can be progressively increased as the protocol matures
     * @return max_tvl Maximum allowed TVL in assets
     */
    function maxTVL() external view returns (uint256 max_tvl);

    /**
     * @notice Returns the protocol's treasury address
     * @dev The treasury receives its percentage (treasury_split) of the generated performance fees.
     *      These funds are typically used for development, security and protocol growth
     * @return treasury_address Address of the treasury that receives performance fees
     */
    function treasury() external view returns (address treasury_address);

    /**
     * @notice Returns the address of the protocol's founder or team
     * @dev The founder receives their percentage (founder_split) of the generated performance fees.
     *      It is the reward for the development and maintenance of the protocol
     * @return founder_address Address of the founder that receives performance fees
     */
    function founder() external view returns (address founder_address);

    /**
     * @notice Returns the address of the strategy manager that manages the strategies
     * @dev The strategy manager is the contract responsible for allocation, rebalancing and harvest
     *      of all strategies. The vault delegates all capital management to this contract
     * @return manager_address Address of the strategy manager contract
     */
    function strategyManager() external view returns (address manager_address);

    /**
     * @notice Returns the balance of idle assets not yet allocated to strategies
     * @dev The idle buffer represents available liquidity in the vault that is not generating yield.
     *      It accumulates from user deposits and is reduced via allocateIdle() when it reaches
     *      the idleThreshold. Maintaining a buffer allows fast withdrawals without pulling from strategies
     *      and saves a lot of gas by not immediately depositing user funds into the protocols
     * @return idle_balance Current balance of idle buffer assets in the vault
     */
    function idleBuffer() external view returns (uint256 idle_balance);

    /**
     * @notice Returns the timestamp of the last executed harvest
     * @dev Used to calculate intervals between harvests and determine when it is optimal to execute
     *      the next harvest based on the accumulation of rewards in the strategies
     * @return timestamp Unix timestamp of the last harvest (seconds since epoch)
     */
    function lastHarvest() external view returns (uint256 timestamp);

    /**
     * @notice Returns the total accumulated profit since the vault's inception
     * @dev Sum of all profits harvested throughout the vault's lifetime, without deducting fees.
     *      Represents the gross yield generated by all strategies before performance fees
     * @return total_profit Total accumulated profit in assets since the vault's deploy
     */
    function totalHarvested() external view returns (uint256 total_profit);

    /**
     * @notice Returns whether an address is an official keeper of the protocol
     * @dev Official keepers do not receive incentive when executing harvest
     * @param keeper Address to check
     * @return is_official True if official keeper, false otherwise
     */
    function is_official_keeper(address keeper) external view returns (bool is_official);

    /**
     * @notice Returns the minimum profit required to execute harvest
     * @dev Prevents unprofitable harvests where the gas cost exceeds the generated profit.
     *      Harvest will only execute if the total profit is greater than or equal to this threshold
     * @return min_profit Minimum profit in assets to execute harvest
     */
    function minProfitForHarvest() external view returns (uint256 min_profit);

    /**
     * @notice Returns the incentive percentage for external keepers
     * @dev In basis points over the total profit. External keepers that execute harvest
     *      receive this percentage as a reward. Official keepers do not receive incentive
     * @return incentive_bps Incentive for keepers in basis points
     */
    function keeperIncentive() external view returns (uint256 incentive_bps);
}
