// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPool} from "@aave/contracts/interfaces/IPool.sol";
import {IAToken} from "@aave/contracts/interfaces/IAToken.sol";
import {IRewardsController} from "@aave/periphery/contracts/rewards/interfaces/IRewardsController.sol";
import {DataTypes} from "@aave/contracts/protocol/libraries/types/DataTypes.sol";
import {IStrategy} from "../interfaces/core/IStrategy.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

/**
 * @title AaveStrategy
 * @author cristianrisueo
 * @notice Strategy that deposits assets into Aave v3 to generate yield
 * @dev Implements IStrategy for integration with StrategyManager
 */
contract AaveStrategy is IStrategy {
    //* library attachments

    /**
     * @notice Uses SafeERC20 for all IERC20 operations in a safe manner
     * @dev Avoids common errors with legacy or poorly implemented tokens
     */
    using SafeERC20 for IERC20;

    //* Errors

    /**
     * @notice Error when the deposit into Aave fails
     */
    error AaveStrategy__DepositFailed();

    /**
     * @notice Error when the withdrawal from Aave fails
     */
    error AaveStrategy__WithdrawFailed();

    /**
     * @notice Error when only the strategy manager can call
     */
    error AaveStrategy__OnlyManager();

    /**
     * @notice Error when the harvest fails to claim rewards
     */
    error AaveStrategy__HarvestFailed();

    /**
     * @notice Error when the swap from rewards to assets fails
     */
    error AaveStrategy__SwapFailed();

    //* Constants

    /// @notice Base for basis points calculations (10000 = 100%)
    uint256 private constant BASIS_POINTS = 10000;

    /// @notice Maximum allowed slippage in swaps in bps (100 = 1%)
    uint256 private constant MAX_SLIPPAGE_BPS = 100;

    //* State variables

    /// @notice Address of the authorized StrategyManager
    address public immutable manager;

    /// @notice Aave v3 Pool instance
    IPool private immutable aave_pool;

    /// @notice Aave v3 rewards controller instance
    IRewardsController private immutable rewards_controller;

    /// @notice Address of the underlying asset
    address private immutable asset_address;

    /// @notice Instance of the token representing assets deposited in Aave
    IAToken private immutable a_token;

    /**
     * @notice Address of the Aave rewards token (I guess it's the governance one)
     * @dev This is the token that Aave gives you for depositing liquidity, don't confuse
     *      it with aToken. This token is an extra yield gift that goes separately
     */
    address private immutable reward_token;

    /// @notice Uniswap v3 router instance for swaps
    ISwapRouter private immutable uniswap_router;

    /**
     * @notice Uniswap v3 fee tier for the reward/asset pool (3000 = 0.3%)
     * @dev Remember that a V3 pool is defined by the token pair and the fee tier?
     */
    uint24 private immutable pool_fee;

    //* Modifiers

    /**
     * @notice Only allows calls from the StrategyManager
     */
    modifier onlyManager() {
        if (msg.sender != manager) revert AaveStrategy__OnlyManager();
        _;
    }

    //* Constructor

    /**
     * @notice AaveStrategy constructor
     * @dev Initializes the strategy with Aave v3 and approves the necessary contracts
     * @param _manager Address of the StrategyManager
     * @param _aave_pool Address of the Aave v3 Pool
     * @param _rewards_controller Address of the Aave v3 RewardsController
     * @param _asset Address of the underlying asset
     * @param _reward_token Address of the rewards token (AAVE)
     * @param _uniswap_router Address of the Uniswap v3 SwapRouter
     * @param _pool_fee Fee tier of the Uniswap pool (3000 = 0.3%)
     */
    constructor(
        address _manager,
        address _aave_pool,
        address _rewards_controller,
        address _asset,
        address _reward_token,
        address _uniswap_router,
        uint24 _pool_fee
    ) {
        // Assigns addresses, initializes contracts and sets the UV3 fee tier
        manager = _manager;
        aave_pool = IPool(_aave_pool);
        rewards_controller = IRewardsController(_rewards_controller);
        asset_address = _asset;
        reward_token = _reward_token;
        uniswap_router = ISwapRouter(_uniswap_router);
        pool_fee = _pool_fee;

        // Gets the aToken address dynamically from Aave
        address a_token_address = aave_pool.getReserveData(_asset).aTokenAddress;
        a_token = IAToken(a_token_address);

        // Approves Aave Pool to move all assets from this contract
        IERC20(_asset).forceApprove(_aave_pool, type(uint256).max);

        // Approves Uniswap Router to move all rewards tokens from this contract
        IERC20(_reward_token).forceApprove(_uniswap_router, type(uint256).max);
    }

    //* Main functions

    /**
     * @notice Deposits assets into Aave v3
     * @dev Can only be called by the StrategyManager
     * @dev Assumes the assets were already transferred to this contract from StrategyManager
     * @param assets Amount of assets to deposit into Aave
     * @return shares In Aave it's 1:1, returns the same amount of aToken
     */
    function deposit(uint256 assets) external onlyManager returns (uint256 shares) {
        // Performs the deposit, returns the aToken and emits event. Reverts on error
        try aave_pool.supply(asset_address, assets, address(this), 0) {
            shares = assets;
            emit Deposited(msg.sender, assets, shares);
        } catch {
            revert AaveStrategy__DepositFailed();
        }
    }

    /**
     * @notice Withdraws assets from Aave v3
     * @dev Can only be called by the StrategyManager
     * @dev Transfers the withdrawn assets directly to StrategyManager
     * @param assets Amount of assets to withdraw from Aave
     * @return actual_withdrawn Assets actually withdrawn (includes yield)
     */
    function withdraw(uint256 assets) external onlyManager returns (uint256 actual_withdrawn) {
        // Performs withdraw from Aave (burns aToken, receives asset + yield). Transfers to
        // StrategyManager and emits event. Reverts on error
        try aave_pool.withdraw(asset_address, assets, address(this)) returns (uint256 withdrawn) {
            actual_withdrawn = withdrawn;
            IERC20(asset_address).safeTransfer(msg.sender, actual_withdrawn);
            emit Withdrawn(msg.sender, actual_withdrawn, assets);
        } catch {
            revert AaveStrategy__WithdrawFailed();
        }
    }

    /**
     * @notice Harvests rewards from Aave, swaps them to assets and reinvests into Aave again
     * @dev Can only be called by the StrategyManager
     * @dev Claims rewards from Aave, swaps them for assets via Uniswap v3 and deposits them
     *      back into Aave to maximize compound yield
     * @return profit Amount of assets obtained after swap and reinvestment of rewards
     */
    function harvest() external onlyManager returns (uint256 profit) {
        // Builds array of assets (only aToken) to claim the rewards
        address[] memory assets_to_claim = new address[](1);
        assets_to_claim[0] = address(a_token);

        // Claims the accumulated rewards for the aToken in Aave. Reverts on error
        try rewards_controller.claimAllRewards(assets_to_claim, address(this)) returns (
            address[] memory, uint256[] memory claimed_amounts
        ) {
            // If there are no rewards to claim, return 0
            if (claimed_amounts.length == 0 || claimed_amounts[0] == 0) {
                return 0;
            }

            // In case there are rewards to claim, calculates the min expected amount in the swap.
            // We do this to prevent slippage (there shouldn't be any anyway, but better safe than sorry)
            uint256 min_amount_out = (claimed_amounts[0] * (BASIS_POINTS - MAX_SLIPPAGE_BPS)) / BASIS_POINTS;

            // Creates the parameters for the Uniswap V3 pool call to perform the swap
            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                tokenIn: reward_token, // Token A
                tokenOut: asset_address, // Token B
                fee: pool_fee, // Fee tier (with these 3 we've already decided the pool)
                recipient: address(this), // Address that receives the swap (this contract)
                deadline: block.timestamp, // To be executed in this block
                amountIn: claimed_amounts[0], // Amount of token A to swap
                amountOutMinimum: min_amount_out, // Minimum expected amount of Token B
                sqrtPriceLimitX96: 0 // No fucking clue
            });

            // Makes the call. If all goes well, reinvests the assets obtained after the swap, returns
            // the amount of assets obtained and emits an event. Reverts on error
            try uniswap_router.exactInputSingle(params) returns (uint256 amount_out) {
                aave_pool.supply(asset_address, amount_out, address(this), 0);
                profit = amount_out;
                emit Harvested(msg.sender, profit);
            } catch {
                revert AaveStrategy__SwapFailed();
            }
        } catch {
            revert AaveStrategy__HarvestFailed();
        }
    }

    //* Query functions

    /**
     * @notice Returns the total assets under management in Aave
     * @dev aTokens rebase automatically, the balance already includes yield
     *      so no extra calculations are needed
     * @return total Amount of deposited assets + accumulated yield
     */
    function totalAssets() external view returns (uint256 total) {
        return a_token.balanceOf(address(this));
    }

    /**
     * @notice Returns the current Aave APY
     * @dev Converts from RAY (1e27, Aave's internal unit) to basis points (1e4)
     *      RAY / 1e23 = basis points
     * @return apy_basis_points APY in basis points (350 = 3.5%)
     */
    function apy() external view returns (uint256 apy_basis_points) {
        // Gets the reserve data for the asset in Aave
        DataTypes.ReserveData memory reserve_data = aave_pool.getReserveData(asset_address);
        uint256 liquidity_rate = reserve_data.currentLiquidityRate;

        // Returns the APY (liquidity rate) cast to basis points
        apy_basis_points = liquidity_rate / 1e23;
    }

    /**
     * @notice Returns the strategy name
     * @return strategy_name Descriptive name of the strategy
     */
    function name() external pure returns (string memory strategy_name) {
        return "Aave v3 Strategy";
    }

    /**
     * @notice Returns the asset address
     * @return asset_address Address of the underlying asset
     */
    function asset() external view returns (address) {
        return asset_address;
    }

    /**
     * @notice Returns the available liquidity in Aave for withdrawals
     * @dev Useful to check if there is enough liquidity before withdrawing
     * @return available Amount of assets available in Aave
     */
    function availableLiquidity() external view returns (uint256 available) {
        return IERC20(asset_address).balanceOf(address(a_token));
    }

    /**
     * @notice Returns the aToken balance of this contract
     * @return balance Amount of aToken that the contract holds
     */
    function aTokenBalance() external view returns (uint256 balance) {
        return a_token.balanceOf(address(this));
    }

    /**
     * @notice Returns the pending rewards to claim
     * @dev Useful to estimate harvest profit before executing it
     * @return pending Amount of pending rewards (AAVE)
     */
    function pendingRewards() external view returns (uint256 pending) {
        // Creates an array with the aToken address (Aave needs it in an array, I guess)
        address[] memory assets_to_check = new address[](1);
        assets_to_check[0] = address(a_token);

        // Makes the call to Aave to get the rewards balance of this contract
        // really the reward token balance (but anyway)
        return rewards_controller.getUserRewards(assets_to_check, address(this), reward_token);
    }
}
