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
 * @notice ERC4626 Vault of the VynX protocol that acts as the entry point for users
 * @dev Manages user deposits/withdrawals, maintains an idle buffer to optimize gas,
 *      coordinates strategy harvests and distributes performance fees between treasury and founder
 * @dev Extends ERC4626 (Tokenized Vault Standard) with additional functionalities:
 *      - Idle buffer management (accumulates deposits until threshold before allocating)
 *      - Performance fees (20% on profits, split 80/20 treasury/founder)
 *      - Circuit breakers (minDeposit, maxTVL, pausable)
 */
contract Vault is IVault, ERC4626, Ownable, Pausable {
    //* library attachments

    /**
     * @notice Uses SafeERC20 for all IERC20 operations in a safe manner
     * @dev Avoids common errors with legacy or poorly implemented tokens
     */
    using SafeERC20 for IERC20;

    /**
     * @notice Uses OpenZeppelin's Math for safe mathematical operations
     * @dev Includes min, max, average and other utilities
     */
    using Math for uint256;

    //* Errors

    /**
     * @notice Error when attempting to deposit less than the established minimum
     */
    error Vault__DepositBelowMinimum();

    /**
     * @notice Error when the deposit exceeds the maximum allowed TVL
     */
    error Vault__MaxTVLExceeded();

    /**
     * @notice Error when attempting to invest but the idle buffer is insufficient
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

    //* Events: Inherited from the interface, no need to implement them

    //* Constants

    /// @notice Base for basis points calculations (100% = 10000 basis points)
    uint256 public constant BASIS_POINTS = 10000;

    //* State variables

    /// @notice Address of the strategy manager that manages the strategies
    address public strategy_manager;

    /// @notice Mapping of official protocol keepers (they don't receive incentives)
    mapping(address => bool) public is_official_keeper;

    /// @notice Address of the treasury that receives its share of performance fees
    address public treasury_address;

    /// @notice Address of the founder that receives its share of performance fees
    address public founder_address;

    /// @notice Balance of idle assets (not allocated to strategies)
    uint256 public idle_buffer;

    /// @notice Timestamp of the last executed harvest
    uint256 public last_harvest;

    /// @notice Total (gross) profit accumulated since the vault's inception
    uint256 public total_harvested;

    //? Why define it here and not in the constructor? It's a good practice, we keep the
    //? constructor as simple as possible so there are no potential failures during deployment

    /// @notice Minimum profit required to execute harvest (avoids unprofitable harvests due to gas)
    uint256 public min_profit_for_harvest = 0.1 ether;

    /// @notice Percentage of generated profits that go to the external keeper who executes the harvest
    uint256 public keeper_incentive = 100;

    /// @notice Performance fee charged on generated profits, in basis points (2000 = 20%)
    uint256 public performance_fee = 2000;

    /// @notice Percentage of the performance fee that goes to treasury (8000 = 80%)
    uint256 public treasury_split = 8000;

    /// @notice Percentage of the performance fee that goes to the founder (2000 = 20%)
    uint256 public founder_split = 2000;

    /// @notice Minimum allowed deposit (0.01 ETH in wei)
    uint256 public min_deposit = 0.01 ether;

    /// @notice Idle buffer threshold to execute allocateIdle (10 ETH)
    uint256 public idle_threshold = 10 ether;

    /// @notice Maximum allowed TVL as a circuit breaker (1000 ETH)
    uint256 public max_tvl = 1000 ether;

    //* Constructor

    /**
     * @notice Vault constructor
     * @dev Initializes the ERC4626 vault with the base asset and sets critical addresses
     * @param _asset Address of the underlying asset
     * @param _strategyManager Address of the strategy manager
     * @param _treasury Address of the treasury
     * @param _founder Address of the founder
     */
    constructor(address _asset, address _strategyManager, address _treasury, address _founder)
        ERC4626(IERC20(_asset))
        ERC20(string.concat("VynX ", ERC20(_asset).symbol(), " Vault"), string.concat("vx", ERC20(_asset).symbol()))
        Ownable(msg.sender)
    {
        // Check that critical addresses are not address(0)
        if (_strategyManager == address(0)) revert Vault__InvalidStrategyManagerAddress();
        if (_treasury == address(0)) revert Vault__InvalidTreasuryAddress();
        if (_founder == address(0)) revert Vault__InvalidFounderAddress();

        // Set the protocol's critical addresses
        strategy_manager = _strategyManager;
        treasury_address = _treasury;
        founder_address = _founder;

        // Initialize the last harvest timestamp
        last_harvest = block.timestamp;
    }

    //* ERC4626 overrides: deposit, mint, withdraw, redeem and totalAssets with custom logic

    /**
     * @notice Deposits assets into the vault and receives shares in return
     * @dev Override of ERC4626.deposit with additional checks and idle buffer management
     * @dev Assets accumulate in idle_buffer until reaching idle_threshold, at which point
     *      they are invested into the strategies
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
        // Check that the deposit is greater than the minimum and doesn't exceed the max allowed TVL
        if (assets < min_deposit) revert Vault__DepositBelowMinimum();
        if (totalAssets() + assets > max_tvl) revert Vault__MaxTVLExceeded();

        // Calculate shares to mint (ERC4626 standard)
        shares = previewDeposit(assets);

        // Execute the deposit: transferFrom user -> vault, mint shares
        _deposit(_msgSender(), receiver, assets, shares);

        // Increment the idle buffer with the deposited assets
        idle_buffer += assets;

        // If the idle buffer reaches the threshold, invest into the strategies
        if (idle_buffer >= idle_threshold) {
            _allocateIdle();
        }

        // Emit deposit event
        emit Deposited(receiver, assets, shares);
    }

    /**
     * @notice Mints exact shares by depositing the necessary amount of assets
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
        // Calculate assets needed to mint those shares (ERC4626 standard)
        assets = previewMint(shares);

        // Check that the required assets exceed the minimum deposit and don't exceed the allowed TVL
        if (assets < min_deposit) revert Vault__DepositBelowMinimum();
        if (totalAssets() + assets > max_tvl) revert Vault__MaxTVLExceeded();

        // Execute the mint: transferFrom user -> vault, mint shares
        _deposit(_msgSender(), receiver, assets, shares);

        // Increment the idle buffer with the deposited assets
        idle_buffer += assets;

        // If the idle buffer reaches the threshold, invest into the strategies
        if (idle_buffer >= idle_threshold) {
            _allocateIdle();
        }

        // Emit deposit event
        emit Deposited(receiver, assets, shares);
    }

    /**
     * @notice Withdraws assets from the vault by burning shares
     * @dev Override of ERC4626.withdraw with withdrawal logic from idle buffer or strategies
     * @dev Prioritizes withdrawing from idle buffer (gas efficient). If there isn't enough idle,
     *      withdraws proportionally from strategies via strategy manager
     * @param assets Amount of assets to withdraw
     * @param receiver Address that will receive the assets
     * @param owner Address of the owner of the shares to burn
     * @return shares Amount of shares burned
     */
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override(ERC4626, IERC4626)
        whenNotPaused
        returns (uint256 shares)
    {
        // Calculate shares to burn to withdraw those assets (ERC4626 standard)
        shares = previewWithdraw(assets);

        // Execute the withdraw: burn shares and withdraw assets prioritizing from idle buffer
        _withdraw(_msgSender(), receiver, owner, assets, shares);

        // Emit withdrawal event and return the burned shares
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
        whenNotPaused
        returns (uint256 assets)
    {
        // Calculate assets to withdraw for those shares (ERC4626 standard)
        assets = previewRedeem(shares);

        // Execute the redeem: burn shares and withdraw assets prioritizing from idle buffer
        _withdraw(_msgSender(), receiver, owner, assets, shares);

        // Emit withdrawal event and return the assets sent
        emit Withdrawn(receiver, assets, shares);
    }

    /**
     * @notice Returns the total assets under management of the vault
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
     * @dev Official keepers don't receive incentives. External ones do (keeper_incentive)
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
        // Call the strategy manager to harvest profits from all strategies
        profit = IStrategyManager(strategy_manager).harvest();

        // If there's no profit or it doesn't reach the minimum, don't execute
        if (profit < min_profit_for_harvest) return 0;

        // Calculate and pay incentive only if the caller is not an official keeper
        uint256 keeper_reward = 0;
        if (!is_official_keeper[msg.sender]) {
            // Calculate the keeper reward
            keeper_reward = (profit * keeper_incentive) / BASIS_POINTS;

            // Unless keeper_incentive = 0 this always enters, but defensive programming
            // Tries to pay first from the idle buffer, if there's not enough the remainder
            // is pulled from the strategies
            if (keeper_reward > 0) {
                if (keeper_reward > idle_buffer) {
                    uint256 to_withdraw = keeper_reward - idle_buffer;
                    IStrategyManager(strategy_manager).withdrawTo(to_withdraw, address(this));
                } else {
                    idle_buffer -= keeper_reward;
                }

                // Transfer the keeper their fee for making the call
                IERC20(asset()).safeTransfer(msg.sender, keeper_reward);
            }
        }

        // Calculate performance fee on the net profit (after keeper reward)
        uint256 net_profit = profit - keeper_reward;
        uint256 perf_fee = (net_profit * performance_fee) / BASIS_POINTS;

        // Distribute fees between treasury and founder
        _distributePerformanceFee(perf_fee);

        // Update counters
        last_harvest = block.timestamp;
        total_harvested += profit;

        // Emit profit harvested event
        emit Harvested(profit, perf_fee, block.timestamp);
    }

    /**
     * @notice Allocates idle assets to strategies when the threshold is reached
     * @dev Public function: anyone can call it when idle >= threshold
     * @dev Only executes if there's enough idle buffer, avoiding gas waste on small allocations
     */
    function allocateIdle() external whenNotPaused {
        if (idle_buffer < idle_threshold) revert Vault__InsufficientIdleBuffer();
        _allocateIdle();
    }

    //* Administrative functions: Protocol parameter setters (onlyOwner)

    //? Anti-pattern to emit the event before setting the variables but we save ourselves a temporary
    //? variable = less gas. You'll see this in almost all of them

    /**
     * @notice Updates the performance fee
     * @param new_fee New performance fee in basis points
     */
    function setPerformanceFee(uint256 new_fee) external onlyOwner {
        // Check that the fee doesn't exceed 100% (max = BASIS_POINTS)
        if (new_fee > BASIS_POINTS) revert Vault__InvalidPerformanceFee();

        // Emit change event with previous and new fee
        emit PerformanceFeeUpdated(performance_fee, new_fee);

        // Update the performance fee
        performance_fee = new_fee;
    }

    /**
     * @notice Updates the fee split between treasury and founder
     * @param new_treasury New percentage for treasury in basis points
     * @param new_founder New percentage for founder in basis points
     */
    function setFeeSplit(uint256 new_treasury, uint256 new_founder) external onlyOwner {
        // Check that the sum is exactly 100% (BASIS_POINTS)
        if (new_treasury + new_founder != BASIS_POINTS) revert Vault__InvalidFeeSplit();

        // Update the splits
        treasury_split = new_treasury;
        founder_split = new_founder;

        // Emit event with new splits
        emit FeeSplitUpdated(new_treasury, new_founder);
    }

    /**
     * @notice Updates the minimum deposit
     * @param new_min New minimum deposit in assets
     */
    function setMinDeposit(uint256 new_min) external onlyOwner {
        // Emit event with previous and new minimum
        emit MinDepositUpdated(min_deposit, new_min);

        // Update the minimum
        min_deposit = new_min;
    }

    /**
     * @notice Updates the idle threshold
     * @param new_threshold New threshold in assets
     */
    function setIdleThreshold(uint256 new_threshold) external onlyOwner {
        // Emit event with previous and new threshold
        emit IdleThresholdUpdated(idle_threshold, new_threshold);

        // Update the threshold
        idle_threshold = new_threshold;
    }

    /**
     * @notice Updates the maximum TVL
     * @param new_max New maximum TVL in assets
     */
    function setMaxTVL(uint256 new_max) external onlyOwner {
        // Emit event with previous and new maximum
        emit MaxTVLUpdated(max_tvl, new_max);

        // Update the maximum
        max_tvl = new_max;
    }

    /**
     * @notice Updates the treasury address
     * @param new_treasury New treasury address
     */
    function setTreasury(address new_treasury) external onlyOwner {
        // Check that the new address is not address(0)
        if (new_treasury == address(0)) revert Vault__InvalidTreasuryAddress();

        // Emit event with previous and new address
        emit TreasuryUpdated(treasury_address, new_treasury);

        // Update the address
        treasury_address = new_treasury;
    }

    /**
     * @notice Updates the founder address
     * @param new_founder New founder address
     */
    function setFounder(address new_founder) external onlyOwner {
        // Check that the new address is not address(0)
        if (new_founder == address(0)) revert Vault__InvalidFounderAddress();

        // Emit event with previous and new address
        emit FounderUpdated(founder_address, new_founder);

        // Update the address
        founder_address = new_founder;
    }

    /**
     * @notice Updates the strategy manager address
     * @param new_manager New strategy manager address
     */
    function setStrategyManager(address new_manager) external onlyOwner {
        // Check that the new address is not address(0)
        if (new_manager == address(0)) revert Vault__InvalidStrategyManagerAddress();

        // Emit event with new address
        emit StrategyManagerUpdated(new_manager);

        // Update the address
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
        // Emit event with previous and new minimum
        emit MinProfitForHarvestUpdated(min_profit_for_harvest, new_min);

        // Update the minimum profit
        min_profit_for_harvest = new_min;
    }

    /**
     * @notice Updates the incentive for external keepers
     * @param new_incentive New incentive in basis points
     */
    function setKeeperIncentive(uint256 new_incentive) external onlyOwner {
        // Check that the incentive doesn't exceed 100% (max = BASIS_POINTS)
        if (new_incentive > BASIS_POINTS) revert Vault__InvalidPerformanceFee();

        // Emit event with previous and new incentive
        emit KeeperIncentiveUpdated(keeper_incentive, new_incentive);

        // Update the incentive
        keeper_incentive = new_incentive;
    }

    //* Administrative functions: Emergency stop and resume of the protocol (onlyOwner)

    /**
     * @notice Pauses the vault (emergency stop)
     * @dev Only the owner can pause. Blocks deposits/withdrawals/harvest/allocate
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
     * @return treasury_address Treasury address
     */
    function treasury() external view returns (address) {
        return treasury_address;
    }

    /**
     * @notice Returns the founder address
     * @return founder_address Founder address
     */
    function founder() external view returns (address) {
        return founder_address;
    }

    /**
     * @notice Returns the strategy manager address
     * @return manager_address Strategy manager address
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
     * @dev Prioritizes withdrawing from idle buffer. If there isn't enough, withdraws from strategies
     * @param caller Address calling the function (msg.sender)
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

        // Burn the owner's shares
        _burn(owner, shares);

        // Determine where to withdraw from: idle buffer first (gas efficient)
        uint256 from_idle = assets.min(idle_buffer);
        uint256 from_strategies = assets - from_idle;

        // Withdraw from idle buffer if available
        if (from_idle > 0) {
            idle_buffer -= from_idle;
        }

        // If there isn't enough in the idle buffer, withdraw proportionally from strategies
        if (from_strategies > 0) {
            IStrategyManager(strategy_manager).withdrawTo(from_strategies, address(this));
        }

        // Get the vault's balance which already has the entire idle buffer + what was pulled from
        // the strategies if it was necessary
        uint256 balance = IERC20(asset()).balanceOf(address(this));

        // Calculate the amount to transfer to the user, the minimum between the vault's balance and
        // the amount to withdraw for the user. To ensure the vault is not insolvent
        uint256 to_transfer = assets.min(balance);

        /**
         * Check that the amount to transfer is less than 20 wei below the expected amount
         *
         * External protocols (Aave, Compound...) round down losing ~1-2 wei per
         * operation. Currently we have 2 strategies, but the plan is to keep increasing them
         * We tolerate up to 20 wei (2 wei x ~10 future strategies = conservative margin)
         *
         * If the difference exceeds 20 wei, we have a serious accounting problem: the vault
         * doesn't have enough assets to redeem the issued shares (insolvency = prison bars)
         *
         * Cost to the user: $0.00000000000005 with ETH at $2,500 (jack shit)
         */
        if (to_transfer < assets) {
            require(assets - to_transfer < 20, "Excessive rounding");
        }

        // Transfer the assets to the receiver
        IERC20(asset()).safeTransfer(receiver, to_transfer);
    }

    /**
     * @notice Allocates idle assets to strategies via strategy manager
     * @dev Internal function called by deposit/mint when idle >= threshold or by allocateIdle()
     */
    function _allocateIdle() internal {
        // Save the amount to deposit into strategies and reset the idle buffer
        uint256 to_allocate = idle_buffer;
        idle_buffer = 0;

        // Transfer idle assets to the strategy manager
        IERC20(asset()).safeTransfer(strategy_manager, to_allocate);

        // Call the strategy manager to distribute among strategies
        IStrategyManager(strategy_manager).allocate(to_allocate);

        // Emit idle assets allocation event
        emit IdleAllocated(to_allocate);
    }

    /**
     * @notice Distributes performance fees between treasury and founder
     * @dev Treasury receives shares (auto-compound), founder receives assets (liquid)
     * @param perf_fee Total amount of performance fee to distribute
     */
    function _distributePerformanceFee(uint256 perf_fee) internal {
        // Calculate the amounts for treasury and founder
        uint256 treasury_amount = (perf_fee * treasury_split) / BASIS_POINTS;
        uint256 founder_amount = (perf_fee * founder_split) / BASIS_POINTS;

        // Treasury receives shares (auto-compound, improves protocol growth)
        // Convert assets to shares and mint them to the treasury address
        uint256 treasury_shares = convertToShares(treasury_amount);
        _mint(treasury_address, treasury_shares);

        // Founder receives the underlying asset directly (you gotta make a living somehow)
        // Tries to withdraw first from the idle buffer and if there's not enough, the remainder from the strategies
        if (founder_amount > idle_buffer) {
            uint256 to_withdraw = founder_amount - idle_buffer;
            IStrategyManager(strategy_manager).withdrawTo(to_withdraw, address(this));
        } else {
            idle_buffer -= founder_amount;
        }

        // Transfer assets to the founder
        IERC20(asset()).safeTransfer(founder_address, founder_amount);

        // Emit fee distribution event
        emit PerformanceFeeDistributed(treasury_amount, founder_amount);
    }
}
