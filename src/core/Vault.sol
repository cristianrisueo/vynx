// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IVault} from "../interfaces/core/IVault.sol";
import {IStrategyManager} from "../interfaces/core/IStrategyManager.sol";

/**
 * @title Vault
 * @author cristianrisueo
 * @notice ERC4626 vault serving as the main entry point for users in the VynX protocol
 * @dev Manages user deposits/withdrawals, maintains idle buffer to optimize gas,
 *      coordinates strategy harvest and distributes performance fees between treasury and founder
 * @dev Extends ERC4626 (Tokenized Vault Standard) with additional functionality:
 *      - Idle buffer management (accumulates deposits until threshold before allocating)
 *      - Performance fees (20% on profits, split 80/20 treasury/founder)
 *      - Circuit breakers (minDeposit, maxTVL, pausable)
 */
contract Vault is IVault, ERC4626, Ownable, Pausable {
    //* library attachments

    /**
     * @notice Uses SafeERC20 for all IERC20 operations safely
     * @dev Avoids common errors with legacy or poorly implemented tokens
     */
    using SafeERC20 for IERC20;

    /**
     * @notice Uses OpenZeppelin Math for safe mathematical operations
     * @dev Includes min, max, average and other utilities
     */
    using Math for uint256;

    //* Errors

    /**
     * @notice Error when trying to deposit less than the established minimum
     */
    error Vault__DepositBelowMinimum();

    /**
     * @notice Error when the deposit exceeds the maximum allowed TVL
     */
    error Vault__MaxTVLExceeded();

    /**
     * @notice Error when trying to invest but the idle buffer is insufficient
     */
    error Vault__InsufficientIdleBuffer();

    /**
     * @notice Error when the performance fee exceeds 100%
     */
    error Vault__InvalidPerformanceFee();

    /**
     * @notice Error when the sum of splits (treasury + founder) is not exactly 100%
     */
    error Vault__InvalidFeeSplit();

    /**
     * @notice Error when address(0) is passed as treasury
     */
    error Vault__InvalidTreasuryAddress();

    /**
     * @notice Error when address(0) is passed as founder
     */
    error Vault__InvalidFounderAddress();

    /**
     * @notice Error when address(0) is passed as strategy manager
     */
    error Vault__InvalidStrategyManagerAddress();

    /**
     * @notice Error when a constructor parameter has an invalid value
     */
    error Vault__InvalidParam();

    //* Structs and events: Inherited from the interface, no need to implement them

    //* Constants

    /// @notice Base for basis points calculations (100% = 10000 basis points)
    uint256 public constant BASIS_POINTS = 10000;

    //* State variables

    /// @notice Address of the strategy manager that manages the strategies
    address public strategy_manager;

    /// @notice Mapping of official protocol keepers (do not receive incentive)
    mapping(address => bool) public is_official_keeper;

    /// @notice Address of the treasury that receives its share of performance fees
    address public treasury_address;

    /// @notice Address of the founder that receives their share of performance fees
    address public founder_address;

    /// @notice Balance of idle assets (not assigned to strategies)
    uint256 public idle_buffer;

    /// @notice Timestamp of the last executed harvest
    uint256 public last_harvest;

    /// @notice Total (gross) profit accumulated since vault inception
    uint256 public total_harvested;

    /// @notice Minimum deposit allowed, configured in the constructor according to the protocol risk tier
    uint256 public min_deposit;

    /// @notice Idle buffer threshold to execute allocateIdle, configured in the constructor according to the risk tier
    uint256 public idle_threshold;

    /// @notice Maximum TVL allowed as a circuit breaker, configured in the constructor according to the risk tier
    uint256 public max_tvl;

    /// @notice Minimum profit required to execute harvest (avoids unprofitable harvests due to gas)
    uint256 public min_profit_for_harvest;

    /// @notice Percentage of generated profits that go to the external keeper who executes the harvest
    uint256 public keeper_incentive = 100;

    /// @notice Performance fee charged on generated profits, in basis points (2000 = 20%)
    uint256 public performance_fee = 2000;

    /// @notice Percentage of the performance fee that goes to the treasury (8000 = 80%)
    uint256 public treasury_split = 8000;

    /// @notice Percentage of the performance fee that goes to the founder (2000 = 20%)
    uint256 public founder_split = 2000;

    //* Constructor

    /**
     * @notice Vault constructor
     * @dev Initializes the ERC4626 vault with the base asset and sets critical addresses
     * @param _asset Address of the underlying asset
     * @param _strategyManager Address of the strategy manager
     * @param _treasury Address of the treasury
     * @param _founder Address of the founder
     * @param params Operational vault parameters configurable by tier
     */
    constructor(address _asset, address _strategyManager, address _treasury, address _founder, TierConfig memory params)
        ERC4626(IERC20(_asset))
        ERC20(string.concat("VynX ", ERC20(_asset).symbol(), " Vault"), string.concat("vx", ERC20(_asset).symbol()))
        Ownable(msg.sender)
    {
        // Checks that critical addresses are not address(0)
        if (_strategyManager == address(0)) revert Vault__InvalidStrategyManagerAddress();
        if (_treasury == address(0)) revert Vault__InvalidTreasuryAddress();
        if (_founder == address(0)) revert Vault__InvalidFounderAddress();

        // Validates vault parameters specific to the risk tier configuration
        if (params.idle_threshold == 0) revert Vault__InvalidParam();
        if (params.min_profit_for_harvest == 0) revert Vault__InvalidParam();
        if (params.max_tvl == 0) revert Vault__InvalidParam();
        if (params.min_deposit == 0) revert Vault__InvalidParam();
        if (params.max_tvl <= params.idle_threshold) revert Vault__InvalidParam();

        // Sets the critical protocol addresses
        strategy_manager = _strategyManager;
        treasury_address = _treasury;
        founder_address = _founder;

        // Assigns the tier parameters
        idle_threshold = params.idle_threshold;
        min_profit_for_harvest = params.min_profit_for_harvest;
        max_tvl = params.max_tvl;
        min_deposit = params.min_deposit;

        // Initializes the timestamp of the last harvest
        last_harvest = block.timestamp;
    }

    //* ERC4626 overrides: deposit, mint, withdraw, redeem and totalAssets with custom logic

    /**
     * @notice Deposits assets into the vault and receives shares in return
     * @dev Override of ERC4626.deposit with additional checks and idle buffer management
     * @dev Assets accumulate in idle_buffer until reaching idle_threshold, at which
     *      point they are invested in the strategies
     * @param assets Amount of assets to deposit
     * @param receiver Address that will receive the shares
     * @return shares Amount of shares minted for the receiver
     */
    function deposit(uint256 assets, address receiver)
        public
        override(ERC4626, IERC4626)
        whenNotPaused
        returns (uint256 shares)
    {
        // Checks that the deposit is greater than the minimum and does not exceed the max allowed TVL
        if (assets < min_deposit) revert Vault__DepositBelowMinimum();
        if (totalAssets() + assets > max_tvl) revert Vault__MaxTVLExceeded();

        // Calculates shares to mint (ERC4626 standard)
        shares = previewDeposit(assets);

        // Executes the deposit: transferFrom user -> vault, mint shares
        _deposit(_msgSender(), receiver, assets, shares);

        // Increments the idle buffer with the deposited assets
        idle_buffer += assets;

        // If the idle buffer reaches the threshold, invests in the strategies
        if (idle_buffer >= idle_threshold) {
            _allocateIdle();
        }

        // Emits deposit event
        emit Deposited(receiver, assets, shares);
    }

    /**
     * @notice Mints exact shares by depositing the required amount of assets
     * @dev Override of ERC4626.mint with additional checks
     * @param shares Amount of shares to mint
     * @param receiver Address that will receive the shares
     * @return assets Amount of assets deposited to mint those shares
     */
    function mint(uint256 shares, address receiver)
        public
        override(ERC4626, IERC4626)
        whenNotPaused
        returns (uint256 assets)
    {
        // Calculates assets needed to mint those shares (ERC4626 standard)
        assets = previewMint(shares);

        // Checks that the required assets exceed the minimum deposit and do not exceed the allowed TVL
        if (assets < min_deposit) revert Vault__DepositBelowMinimum();
        if (totalAssets() + assets > max_tvl) revert Vault__MaxTVLExceeded();

        // Executes the mint: transferFrom user -> vault, mint shares
        _deposit(_msgSender(), receiver, assets, shares);

        // Increments the idle buffer with the deposited assets
        idle_buffer += assets;

        // If the idle buffer reaches the threshold, invests in the strategies
        if (idle_buffer >= idle_threshold) {
            _allocateIdle();
        }

        // Emits deposit event
        emit Deposited(receiver, assets, shares);
    }

    /**
     * @notice Withdraws assets from the vault by burning shares
     * @dev Override of ERC4626.withdraw with withdrawal logic from idle buffer or strategies
     * @dev Prioritizes withdrawing from the idle buffer (gas efficient). If there is not enough idle,
     *      withdraws proportionally from strategies via strategy manager
     * @param assets Amount of assets to withdraw
     * @param receiver Address that will receive the assets
     * @param owner Address of the owner of the shares to burn
     * @return shares Amount of shares burned
     */
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override(ERC4626, IERC4626)
        returns (uint256 shares)
    {
        // Calculates shares to burn to withdraw those assets (ERC4626 standard)
        shares = previewWithdraw(assets);

        // Executes the withdrawal: burns shares and withdraws assets prioritizing from idle buffer
        _withdraw(_msgSender(), receiver, owner, assets, shares);

        // Emits withdrawal event and returns the burned shares
        emit Withdrawn(receiver, assets, shares);
    }

    /**
     * @notice Burns exact shares withdrawing the corresponding amount of assets
     * @dev Override of ERC4626.redeem with withdrawal logic from idle buffer or strategies
     * @param shares Amount of shares to burn
     * @param receiver Address that will receive the assets
     * @param owner Address of the owner of the shares
     * @return assets Amount of assets withdrawn
     */
    function redeem(uint256 shares, address receiver, address owner)
        public
        override(ERC4626, IERC4626)
        returns (uint256 assets)
    {
        // Calculates assets to withdraw for those shares (ERC4626 standard)
        assets = previewRedeem(shares);

        // Executes the redeem: burns shares and withdraws assets prioritizing from idle buffer
        _withdraw(_msgSender(), receiver, owner, assets, shares);

        // Emits withdrawal event and returns the sent assets
        emit Withdrawn(receiver, assets, shares);
    }

    /**
     * @notice Returns the total assets under management by the vault
     * @dev Override of ERC4626.totalAssets
     * @dev Sum: idle buffer + assets in strategies via strategy manager
     * @return total Total assets managed by the vault
     */
    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256 total) {
        total = idle_buffer + IStrategyManager(strategy_manager).totalAssets();
    }

    /**
     * @notice Returns the maximum assets a user can deposit
     * @dev Override of ERC4626.maxDeposit to respect the maxTVL circuit breaker
     * @return maxAssets Maximum depositable assets before reaching maxTVL
     */
    function maxDeposit(address) public view override(ERC4626, IERC4626) returns (uint256 maxAssets) {
        if (paused()) return 0;

        uint256 current = totalAssets();
        if (current >= max_tvl) return 0;

        return max_tvl - current;
    }

    /**
     * @notice Returns the maximum shares a user can mint
     * @dev Override of ERC4626.maxMint to respect the maxTVL circuit breaker
     * @return maxShares Maximum mintable shares before reaching maxTVL
     */
    function maxMint(address) public view override(ERC4626, IERC4626) returns (uint256 maxShares) {
        if (paused()) return 0;

        uint256 current = totalAssets();
        if (current >= max_tvl) return 0;

        return convertToShares(max_tvl - current);
    }

    //* Main functions: harvest and allocateIdle (public, unrestricted)

    /**
     * @notice Harvests rewards from all strategies and distributes performance fees
     * @dev Public function: anyone can call it (keepers, bots, users)
     * @dev Official keepers do not receive incentive. External ones do (keeper_incentive)
     * @dev Only executes if profit >= min_profit_for_harvest (avoids unprofitable harvests)
     * @dev Flow:
     *      - strategyManager.harvest() ->
     *      - validates minimum profit ->
     *      - pays incentive to external keeper ->
     *      - calculates performance fee ->
     *      - distributes fees ->
     *      - updates counters (last_harvest, total_harvested)
     * @return profit Total profit harvested before deducting fees and incentives
     */
    function harvest() external whenNotPaused returns (uint256 profit) {
        // Calls the strategy manager to harvest profits from all strategies
        profit = IStrategyManager(strategy_manager).harvest();

        // If there is no profit or it does not reach the minimum, do not execute
        if (profit < min_profit_for_harvest) return 0;

        // Calculates and pays incentive only if the caller is not an official keeper
        uint256 keeper_reward = 0;
        if (!is_official_keeper[msg.sender]) {
            // Calculates the keeper reward
            keeper_reward = (profit * keeper_incentive) / BASIS_POINTS;

            // Unless keeper_incentive = 0 this always enters, but defensive programming
            // Tries to pay from the idle buffer first, if not enough the remainder is
            // taken from the strategies
            if (keeper_reward > 0) {
                if (keeper_reward > idle_buffer) {
                    uint256 to_withdraw = keeper_reward - idle_buffer;
                    IStrategyManager(strategy_manager).withdrawTo(to_withdraw, address(this));
                } else {
                    idle_buffer -= keeper_reward;
                }

                // Transfers to the keeper their fee for making the call
                IERC20(asset()).safeTransfer(msg.sender, keeper_reward);
            }
        }

        // Calculates performance fee on net profit (after keeper reward)
        uint256 net_profit = profit - keeper_reward;
        uint256 perf_fee = (net_profit * performance_fee) / BASIS_POINTS;

        // Distributes fees between treasury and founder
        _distributePerformanceFee(perf_fee);

        // Updates counters
        last_harvest = block.timestamp;
        total_harvested += profit;

        // Emits profit harvest event
        emit Harvested(profit, perf_fee, block.timestamp);
    }

    /**
     * @notice Assigns idle assets to strategies when the threshold is reached
     * @dev Public function: anyone can call it when idle >= threshold
     * @dev Only executes if there is enough idle buffer, avoiding gas waste on small allocations
     */
    function allocateIdle() external whenNotPaused {
        if (idle_buffer < idle_threshold) revert Vault__InsufficientIdleBuffer();
        _allocateIdle();
    }

    //* Administrative functions: Protocol parameter setters (onlyOwner)

    //? Antipattern to emit the event before setting the variables but we save a temporary
    //? variable = less gas. You'll see this in almost all of them

    /**
     * @notice Updates the performance fee
     * @param new_fee New performance fee in basis points
     */
    function setPerformanceFee(uint256 new_fee) external onlyOwner {
        // Checks that the fee does not exceed 100% (max = BASIS_POINTS)
        if (new_fee > BASIS_POINTS) revert Vault__InvalidPerformanceFee();

        // Emits event with previous and new fee
        emit PerformanceFeeUpdated(performance_fee, new_fee);

        // Updates the performance fee
        performance_fee = new_fee;
    }

    /**
     * @notice Updates the fee split between treasury and founder
     * @param new_treasury New percentage for treasury in basis points
     * @param new_founder New percentage for founder in basis points
     */
    function setFeeSplit(uint256 new_treasury, uint256 new_founder) external onlyOwner {
        // Checks that the sum is exactly 100% (BASIS_POINTS)
        if (new_treasury + new_founder != BASIS_POINTS) revert Vault__InvalidFeeSplit();

        // Updates the splits
        treasury_split = new_treasury;
        founder_split = new_founder;

        // Emits event with new splits
        emit FeeSplitUpdated(new_treasury, new_founder);
    }

    /**
     * @notice Updates the minimum deposit
     * @param new_min New minimum deposit in assets
     */
    function setMinDeposit(uint256 new_min) external onlyOwner {
        // Emits event with previous and new minimum
        emit MinDepositUpdated(min_deposit, new_min);

        // Updates the minimum
        min_deposit = new_min;
    }

    /**
     * @notice Updates the idle threshold
     * @param new_threshold New threshold in assets
     */
    function setIdleThreshold(uint256 new_threshold) external onlyOwner {
        // Emits event with previous and new threshold
        emit IdleThresholdUpdated(idle_threshold, new_threshold);

        // Updates the threshold
        idle_threshold = new_threshold;
    }

    /**
     * @notice Updates the maximum TVL
     * @param new_max New maximum TVL in assets
     */
    function setMaxTVL(uint256 new_max) external onlyOwner {
        // Emits event with previous and new maximum
        emit MaxTVLUpdated(max_tvl, new_max);

        // Updates the maximum
        max_tvl = new_max;
    }

    /**
     * @notice Updates the treasury address
     * @param new_treasury New treasury address
     */
    function setTreasury(address new_treasury) external onlyOwner {
        // Checks that the new address is not address(0)
        if (new_treasury == address(0)) revert Vault__InvalidTreasuryAddress();

        // Emits event with previous and new address
        emit TreasuryUpdated(treasury_address, new_treasury);

        // Updates the address
        treasury_address = new_treasury;
    }

    /**
     * @notice Updates the founder address
     * @param new_founder New founder address
     */
    function setFounder(address new_founder) external onlyOwner {
        // Checks that the new address is not address(0)
        if (new_founder == address(0)) revert Vault__InvalidFounderAddress();

        // Emits event with previous and new address
        emit FounderUpdated(founder_address, new_founder);

        // Updates the address
        founder_address = new_founder;
    }

    /**
     * @notice Updates the strategy manager address
     * @param new_manager New strategy manager address
     */
    function setStrategyManager(address new_manager) external onlyOwner {
        // Checks that the new address is not address(0)
        if (new_manager == address(0)) revert Vault__InvalidStrategyManagerAddress();

        // Emits event with new address
        emit StrategyManagerUpdated(new_manager);

        // Updates the address
        strategy_manager = new_manager;
    }

    /**
     * @notice Adds or removes an official keeper
     * @param keeper Address of the keeper
     * @param status True to add, false to remove
     */
    function setOfficialKeeper(address keeper, bool status) external onlyOwner {
        is_official_keeper[keeper] = status;
        emit OfficialKeeperUpdated(keeper, status);
    }

    /**
     * @notice Updates the minimum profit required to execute harvest
     * @param new_min New minimum profit in assets
     */
    function setMinProfitForHarvest(uint256 new_min) external onlyOwner {
        // Emits event with previous and new minimum
        emit MinProfitForHarvestUpdated(min_profit_for_harvest, new_min);

        // Updates the minimum profit
        min_profit_for_harvest = new_min;
    }

    /**
     * @notice Updates the incentive for external keepers
     * @param new_incentive New incentive in basis points
     */
    function setKeeperIncentive(uint256 new_incentive) external onlyOwner {
        // Checks that the incentive does not exceed 100% (max = BASIS_POINTS)
        if (new_incentive > BASIS_POINTS) revert Vault__InvalidPerformanceFee();

        // Emits event with previous and new incentive
        emit KeeperIncentiveUpdated(keeper_incentive, new_incentive);

        // Updates the incentive
        keeper_incentive = new_incentive;
    }

    //* Emergency functions: Stops and idle buffer reconciliation after emergency exit (onlyOwner)

    /**
     * @notice Pauses the vault (emergency stop)
     * @dev Only the owner can pause. Blocks new deposits (deposit, mint), harvest
     *      and allocateIdle. Withdrawals (withdraw, redeem) remain enabled: a user
     *      must always be able to recover their funds, regardless of the vault state
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpauses the vault
     * @dev Only the owner can unpause
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Reconciles idle_buffer with the actual WETH balance of the contract
     *
     * @dev onlyOwner. Necessary after emergencyExit() from the manager, which transfers WETH
     *      to the vault directly without going through deposit() or _allocateIdle(), desynchronizing
     *      idle_buffer and making totalAssets() incorrect until reconciliation
     *      If we don't sync, after an emergencyExit totalAssets will not be correct and withdrawals
     *      will fail at some point due to treasury desynchronization.
     */
    function syncIdleBuffer() external onlyOwner {
        // Captures the previous value for the event
        uint256 old_buffer = idle_buffer;

        // Gets the contract's WETH balance
        uint256 real_balance = IERC20(asset()).balanceOf(address(this));

        // Updates idle_buffer with the actual balance (total assets = idle + strategies - 0 after exit)
        idle_buffer = real_balance;

        // Emits event with previous and new value for traceability
        emit IdleBufferSynced(old_buffer, real_balance);
    }

    //* Query functions: Getters for protocol parameters and state

    /**
     * @notice Returns the current performance fee
     * @return fee_bps Performance fee in basis points
     */
    function performanceFee() external view returns (uint256 fee_bps) {
        return performance_fee;
    }

    /**
     * @notice Returns the current treasury split
     * @return split_bps Treasury split in basis points
     */
    function treasurySplit() external view returns (uint256 split_bps) {
        return treasury_split;
    }

    /**
     * @notice Returns the current founder split
     * @return split_bps Founder split in basis points
     */
    function founderSplit() external view returns (uint256 split_bps) {
        return founder_split;
    }

    /**
     * @notice Returns the current minimum deposit
     * @return min_amount Minimum deposit in assets
     */
    function minDeposit() external view returns (uint256 min_amount) {
        return min_deposit;
    }

    /**
     * @notice Returns the current idle threshold
     * @return threshold Idle threshold in assets
     */
    function idleThreshold() external view returns (uint256 threshold) {
        return idle_threshold;
    }

    /**
     * @notice Returns the current maximum TVL
     * @return max_tvl Maximum TVL in assets
     */
    function maxTVL() external view returns (uint256) {
        return max_tvl;
    }

    /**
     * @notice Returns the treasury address
     * @return treasury_address Address of the treasury
     */
    function treasury() external view returns (address) {
        return treasury_address;
    }

    /**
     * @notice Returns the founder address
     * @return founder_address Address of the founder
     */
    function founder() external view returns (address) {
        return founder_address;
    }

    /**
     * @notice Returns the strategy manager address
     * @return manager_address Address of the strategy manager
     */
    function strategyManager() external view returns (address) {
        return strategy_manager;
    }

    /**
     * @notice Returns the current idle buffer balance
     * @return idle_balance Balance of idle assets
     */
    function idleBuffer() external view returns (uint256) {
        return idle_buffer;
    }

    /**
     * @notice Returns the timestamp of the last harvest
     * @return timestamp Timestamp of the last harvest
     */
    function lastHarvest() external view returns (uint256 timestamp) {
        return last_harvest;
    }

    /**
     * @notice Returns the total accumulated profit
     * @return total_profit Total profit since inception
     */
    function totalHarvested() external view returns (uint256 total_profit) {
        return total_harvested;
    }

    /**
     * @notice Returns the minimum profit required to execute harvest
     * @return min_profit Minimum profit in assets
     */
    function minProfitForHarvest() external view returns (uint256 min_profit) {
        return min_profit_for_harvest;
    }

    /**
     * @notice Returns the incentive for external keepers
     * @return incentive_bps Incentive in basis points
     */
    function keeperIncentive() external view returns (uint256 incentive_bps) {
        return keeper_incentive;
    }

    //* Internal functions: Helpers for deposit/withdraw and fee distribution

    /**
     * @notice Withdraws assets from the vault from idle buffer or strategies
     * @dev Override of ERC4626._withdraw to implement custom withdrawal logic
     * @dev Prioritizes withdrawing from idle buffer. If insufficient, withdraws from strategies
     * @param caller Address that calls the function (msg.sender)
     * @param receiver Address that will receive the assets
     * @param owner Address of the owner of the shares
     * @param assets Amount of assets to withdraw
     * @param shares Amount of shares to burn
     */
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        // If caller != owner, reduce allowance (ERC4626 standard)
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        // Burns the owner's shares
        _burn(owner, shares);

        // Determines where to withdraw from: idle buffer first (gas efficient)
        uint256 from_idle = assets.min(idle_buffer);
        uint256 from_strategies = assets - from_idle;

        // Withdraws from idle buffer if available
        if (from_idle > 0) {
            idle_buffer -= from_idle;
        }

        // If there is not enough in the idle buffer, withdraws proportionally from strategies
        if (from_strategies > 0) {
            IStrategyManager(strategy_manager).withdrawTo(from_strategies, address(this));
        }

        // Gets the vault balance which already has all the idle buffer + what was extracted from
        // strategies if necessary
        uint256 balance = IERC20(asset()).balanceOf(address(this));

        // Calculates the amount to transfer to the user, the minimum between the vault balance and
        // the amount the user wants to withdraw. To ensure the vault is not insolvent
        uint256 to_transfer = assets.min(balance);

        /**
         * Checks that the amount to transfer is less than 20 wei below what was expected
         *
         * External protocols (Aave, Compound...) round down losing ~1-2 wei per
         * operation. We currently have 2 strategies, but the plan is to keep adding more
         * We tolerate up to 20 wei (2 wei × ~10 future strategies = conservative margin)
         *
         * If the difference exceeds 20 wei, we have a serious accounting problem: the vault
         * does not have enough assets to redeem the issued shares (insolvency = prison bars)
         *
         * Cost to the user: $0.00000000000005 with ETH at $2,500 (a shit amount)
         */
        if (to_transfer < assets) {
            require(assets - to_transfer < 20, "Excessive rounding");
        }

        // Transfers the assets to the receiver
        IERC20(asset()).safeTransfer(receiver, to_transfer);
    }

    /**
     * @notice Assigns idle assets to strategies via strategy manager
     * @dev Internal function called by deposit/mint when idle >= threshold or by allocateIdle()
     */
    function _allocateIdle() internal {
        // Saves the amount to deposit into strategies and resets the idle buffer
        uint256 to_allocate = idle_buffer;
        idle_buffer = 0;

        // Transfers idle assets to the strategy manager
        IERC20(asset()).safeTransfer(strategy_manager, to_allocate);

        // Calls the strategy manager to distribute among strategies
        IStrategyManager(strategy_manager).allocate(to_allocate);

        // Emits event for idle asset allocation performed
        emit IdleAllocated(to_allocate);
    }

    /**
     * @notice Distributes performance fees between treasury and founder
     * @dev Treasury receives shares (auto-compound), founder receives assets (liquid)
     * @param perf_fee Total amount of performance fee to distribute
     */
    function _distributePerformanceFee(uint256 perf_fee) internal {
        // Calculates the amounts for treasury and founder
        uint256 treasury_amount = (perf_fee * treasury_split) / BASIS_POINTS;
        uint256 founder_amount = (perf_fee * founder_split) / BASIS_POINTS;

        // Treasury receives shares (auto-compound, improves protocol growth)
        // Converts assets to shares and mints them to the treasury address
        uint256 treasury_shares = convertToShares(treasury_amount);
        _mint(treasury_address, treasury_shares);

        // Founder receives the underlying asset directly (gotta eat somehow)
        // Tries to withdraw from idle buffer first, if not enough, the remainder from strategies
        if (founder_amount > idle_buffer) {
            uint256 to_withdraw = founder_amount - idle_buffer;
            IStrategyManager(strategy_manager).withdrawTo(to_withdraw, address(this));
        } else {
            idle_buffer -= founder_amount;
        }

        // Transfers assets to the founder
        IERC20(asset()).safeTransfer(founder_address, founder_amount);

        // Emits fee distribution event
        emit PerformanceFeeDistributed(treasury_amount, founder_amount);
    }
}
