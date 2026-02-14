// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICometMarket} from "../interfaces/compound/ICometMarket.sol";
import {ICometRewards} from "../interfaces/compound/ICometRewards.sol";
import {IStrategy} from "../interfaces/core/IStrategy.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

/**
 * @title CompoundStrategy
 * @author cristianrisueo
 * @notice Strategy that deposits assets into Compound v3 to generate yield
 * @dev Implements IStrategy for integration with StrategyManager
 */
contract CompoundStrategy is IStrategy {
    //* library attachments

    /**
     * @notice Uses SafeERC20 for all IERC20 operations safely
     * @dev Avoids common errors with legacy or poorly implemented tokens
     */
    using SafeERC20 for IERC20;

    //* Errors

    /**
     * @notice Error when the deposit into Compound fails
     */
    error CompoundStrategy__DepositFailed();

    /**
     * @notice Error when the withdrawal from Compound fails
     */
    error CompoundStrategy__WithdrawFailed();

    /**
     * @notice Error when only the strategy manager can call
     */
    error CompoundStrategy__OnlyManager();

    /**
     * @notice Error when the harvest fails to claim rewards
     */
    error CompoundStrategy__HarvestFailed();

    /**
     * @notice Error when the swap from rewards to assets fails
     */
    error CompoundStrategy__SwapFailed();

    //* Constants

    /// @notice Base for basis points calculations (10000 = 100%)
    uint256 private constant BASIS_POINTS = 10000;

    /// @notice Maximum allowed slippage on swaps in bps (100 = 1%)
    uint256 private constant MAX_SLIPPAGE_BPS = 100;

    //* State variables

    /// @notice Address of the authorized StrategyManager
    address public immutable manager;

    /// @notice Instance of the Compound v3 Comet market
    ICometMarket private immutable compound_comet;

    /// @notice Instance of the Compound v3 rewards controller
    ICometRewards private immutable compound_rewards;

    /// @notice Address of the underlying asset
    address private immutable asset_address;

    /// @notice Address of the reward token (COMP)
    address private immutable reward_token;

    /// @notice Uniswap v3 router for swaps
    ISwapRouter private immutable uniswap_router;

    /// @notice Uniswap v3 fee tier for the reward/asset pool (3000 = 0.3%)
    /// @dev Remember that a V3 pool is defined by the token pair and the fee tier?
    uint24 private immutable pool_fee;

    //* Modifiers

    /**
     * @notice Only allows calls from the StrategyManager
     */
    modifier onlyManager() {
        if (msg.sender != manager) revert CompoundStrategy__OnlyManager();
        _;
    }

    //* Constructor

    /**
     * @notice CompoundStrategy constructor
     * @dev Initializes the strategy with Compound v3 and approves the necessary contracts
     * @param _manager Address of the StrategyManager
     * @param _compound_comet Address of the Compound v3 Comet market
     * @param _compound_rewards Address of the Compound v3 CometRewards
     * @param _asset Address of the underlying asset
     * @param _reward_token Address of the reward token (COMP)
     * @param _uniswap_router Address of the Uniswap v3 SwapRouter
     * @param _pool_fee Fee tier of the Uniswap pool (3000 = 0.3%)
     */
    constructor(
        address _manager,
        address _compound_comet,
        address _compound_rewards,
        address _asset,
        address _reward_token,
        address _uniswap_router,
        uint24 _pool_fee
    ) {
        // Assigns addresses, initializes contracts and sets the UV3 fee tier
        manager = _manager;
        compound_comet = ICometMarket(_compound_comet);
        compound_rewards = ICometRewards(_compound_rewards);
        asset_address = _asset;
        reward_token = _reward_token;
        uniswap_router = ISwapRouter(_uniswap_router);
        pool_fee = _pool_fee;

        // Approves Compound Comet to move all assets from this contract
        IERC20(_asset).forceApprove(_compound_comet, type(uint256).max);

        // Approves Uniswap Router to move all reward tokens from this contract
        IERC20(_reward_token).forceApprove(_uniswap_router, type(uint256).max);
    }

    //* Main functions

    /**
     * @notice Deposits assets into Compound v3
     * @dev Can only be called by the StrategyManager
     * @dev Assumes the assets were already transferred to this contract from StrategyManager
     * @param assets Amount of assets to deposit into Compound
     * @return shares Returns amount deposited (Compound doesn't use cToken-like tokens in v3)
     */
    function deposit(uint256 assets) external onlyManager returns (uint256 shares) {
        // Performs the deposit into Compound and emits event. In case of error it reverts
        try compound_comet.supply(asset_address, assets) {
            shares = assets;
            emit Deposited(msg.sender, assets, shares);
        } catch {
            revert CompoundStrategy__DepositFailed();
        }
    }

    /**
     * @notice Withdraws assets from Compound v3
     * @dev Can only be called by the StrategyManager
     * @dev Transfers the withdrawn assets directly to StrategyManager
     * @param assets Amount of assets to withdraw from Compound
     * @return actual_withdrawn Assets actually withdrawn (includes yield)
     */
    function withdraw(uint256 assets) external onlyManager returns (uint256 actual_withdrawn) {
        // Asset balance of the contract before the withdraw = 0 (everything is in compound)
        uint256 balance_before = IERC20(asset_address).balanceOf(address(this));

        // Performs withdraw from Compound, transfers to StrategyManager and emits event. In case of error it reverts
        try compound_comet.withdraw(asset_address, assets) {
            // Subtracts the current asset balance (what was actually withdrawn from compound) - assets before withdrawal (0)
            // to calculate what was actually obtained from compound (assets could be 100, but 1 wei might be lost)
            actual_withdrawn = IERC20(asset_address).balanceOf(address(this)) - balance_before;

            IERC20(asset_address).safeTransfer(msg.sender, actual_withdrawn);
            emit Withdrawn(msg.sender, actual_withdrawn, assets);
        } catch {
            revert CompoundStrategy__WithdrawFailed();
        }
    }

    /**
     * @notice Harvests rewards from Compound, swaps them to assets and reinvests into Compound again
     * @dev Can only be called by the StrategyManager
     * @dev Claims rewards from Compound, swaps them for assets via Uniswap v3 and deposits them
     *      back into Compound to maximize compound yield
     * @return profit Amount of assets obtained after swap and reinvestment of rewards
     */
    function harvest() external onlyManager returns (uint256 profit) {
        // Claims the accumulated rewards from the Comet market in Compound. In case of error it reverts
        try compound_rewards.claim(address(compound_comet), address(this), true) {
            // Gets the reward token balance of the contract
            uint256 reward_amount = IERC20(reward_token).balanceOf(address(this));

            // If there are no rewards to claim, return 0
            if (reward_amount == 0) {
                return 0;
            }

            // In case there are rewards to claim, calculates the min expected amount in the swap.
            // We do this to prevent slippage (there shouldn't be any anyway, but better safe than sorry)
            uint256 min_amount_out = (reward_amount * (BASIS_POINTS - MAX_SLIPPAGE_BPS)) / BASIS_POINTS;

            // Creates the parameters for the Uniswap V3 pool call to perform the swap
            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                tokenIn: reward_token, // Token A
                tokenOut: asset_address, // Token B
                fee: pool_fee, // Fee tier (with these 3 we've already decided the pool)
                recipient: address(this), // Address that receives the swap (this contract)
                deadline: block.timestamp, // To be executed in this block
                amountIn: reward_amount, // Amount of token A to swap
                amountOutMinimum: min_amount_out, // Minimum expected amount of Token B
                sqrtPriceLimitX96: 0 // No fucking clue
            });

            // Performs the call. If everything goes well it reinvests the assets obtained after the swap, returns
            // the amount of assets obtained and emits an event. In case of error it reverts
            try uniswap_router.exactInputSingle(params) returns (uint256 amount_out) {
                compound_comet.supply(asset_address, amount_out);
                profit = amount_out;
                emit Harvested(msg.sender, profit);
            } catch {
                revert CompoundStrategy__SwapFailed();
            }
        } catch {
            revert CompoundStrategy__HarvestFailed();
        }
    }

    //* Query functions

    /**
     * @notice Returns the total assets under management in Compound
     * @dev Compound v3 uses internal accounting, queries the user's balance in the Comet
     *      so no extra calculations are needed
     * @return total Amount of deposited assets + accumulated yield
     */
    function totalAssets() external view returns (uint256 total) {
        return compound_comet.balanceOf(address(this));
    }

    /**
     * @notice Returns the current APY from Compound
     * @dev Calculates APY from the supply rate that Compound returns
     * @dev Supply rate is per second (1e18 base), we convert to annual basis points
     * @return apy_basis_points APY in basis points (350 = 3.5%)
     */
    function apy() external view returns (uint256 apy_basis_points) {
        // Gets the current pool utilization
        uint256 utilization = compound_comet.getUtilization();

        // Gets supply rate based on utilization (Compound V3 returns uint64)
        uint64 supply_rate_per_second = compound_comet.getSupplyRate(utilization);

        // Converts rate per second to annual APY in basis points
        // Cast to uint256 to avoid overflow in multiplication
        // supply_rate * seconds_per_year / 1e18 * 10000 = basis points
        // Simplified: (rate * 31536000 * 10000) / 1e18
        apy_basis_points = (uint256(supply_rate_per_second) * 315360000000) / 1e18;
    }

    /**
     * @notice Returns the name of the strategy
     * @return strategy_name Descriptive name of the strategy
     */
    function name() external pure returns (string memory strategy_name) {
        return "Compound v3 Strategy";
    }

    /**
     * @notice Returns the address of the asset
     * @return asset_address Address of the underlying asset
     */
    function asset() external view returns (address) {
        return asset_address;
    }

    /**
     * @notice Returns the current supply rate from Compound
     * @dev Useful for debugging and APY verification
     * @return supply_rate Supply rate per second (base 1e18) converted to uint256
     */
    function getSupplyRate() external view returns (uint256 supply_rate) {
        return uint256(compound_comet.getSupplyRate(compound_comet.getUtilization()));
    }

    /**
     * @notice Returns the current utilization of the Compound pool
     * @dev Utilization = borrowed / supplied
     * @return utilization Utilization percentage (base 1e18, e.g.: 0.5e18 = 50%)
     */
    function getUtilization() external view returns (uint256 utilization) {
        return compound_comet.getUtilization();
    }

    /**
     * @notice Returns the pending rewards to claim
     * @dev Useful for estimating harvest profit before executing it
     * @return pending Amount of pending rewards (COMP)
     */
    function pendingRewards() external view returns (uint256 pending) {
        // Performs the call to Compound to get the reward balance of this contract
        return compound_rewards.getRewardOwed(address(compound_comet), address(this)).owed;
    }
}
