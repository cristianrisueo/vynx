// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPool} from "@aave/contracts/interfaces/IPool.sol";
import {IAToken} from "@aave/contracts/interfaces/IAToken.sol";
import {IRewardsController} from "@aave/periphery/contracts/rewards/interfaces/IRewardsController.sol";
import {DataTypes} from "@aave/contracts/protocol/libraries/types/DataTypes.sol";
import {IWETH} from "@aave/contracts/misc/interfaces/IWETH.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IStrategy} from "../interfaces/strategies/IStrategy.sol";
import {IWstETH} from "../interfaces/strategies/lido/IWstETH.sol";
import {ICurvePool} from "../interfaces/strategies/curve/ICurvePool.sol";

/**
 * @title AaveStrategy
 * @author cristianrisueo
 * @notice Strategy that deposits wstETH into Aave v3 to generate double yield (Lido + Aave)
 * @dev Implements IStrategy for integration with StrategyManager
 *
 * @dev The vault asset is WETH. The WETH <-> wstETH conversion is handled internally:
 *      - Deposit:  WETH → ETH (IWETH) → wstETH (Lido) → Aave
 *      - Withdraw: wstETH (Aave) → stETH (IWstETH) → ETH (Curve swap) → WETH (IWETH)
 *
 * @dev When you send ETH directly to the wstETH contract, it directly stakes in Lido,
 *      receives stETH, wraps it, and returns wstETH to this contract
 *
 * @dev This strategy is called Aave for simplicity and because that's where the liquidity ends up
 *      but it combines two calls to external protocols:
 *      - Lido staking yield (~4%): captured via the growing wstETH exchange rate
 *      - Aave lending yield (~3.5%): captured via aWstETH accumulating interest
 */
contract AaveStrategy is IStrategy {
    //* library attachments

    /**
     * @notice Uses SafeERC20 for all IERC20 operations safely
     * @dev Avoids common errors with legacy or poorly implemented tokens
     */
    using SafeERC20 for IERC20;

    //* Errors

    /**
     * @notice Error when the Aave deposit fails
     */
    error AaveStrategy__DepositFailed();

    /**
     * @notice Error when the Aave withdrawal fails
     */
    error AaveStrategy__WithdrawFailed();

    /**
     * @notice Error when only the strategy manager can call
     */
    error AaveStrategy__OnlyManager();

    /**
     * @notice Error when harvest fails while claiming rewards
     */
    error AaveStrategy__HarvestFailed();

    /**
     * @notice Error when the rewards to assets swap fails
     */
    error AaveStrategy__SwapFailed();

    //* Constants

    /// @notice Base for basis points calculations (10000 = 100%)
    uint256 private constant BASIS_POINTS = 10000;

    /// @notice Maximum slippage allowed in swaps in bps (100 = 1%)
    uint256 private constant MAX_SLIPPAGE_BPS = 100;

    //* State variables

    /// @notice Address of the authorized StrategyManager
    address public immutable manager;

    /// @notice Address of the vault's underlying asset (WETH)
    address private immutable asset_address;

    /// @notice Instance of the Aave v3 Pool
    IPool private immutable aave_pool;

    /// @notice Instance of the Aave v3 rewards controller
    IRewardsController private immutable rewards_controller;

    /// @notice Instance of the aToken representing assets deposited in Aave (aWstETH)
    IAToken private immutable a_token;

    /// @notice Address of the Aave rewards token (governance token)
    address private immutable reward_token;

    /// @notice Instance of the Uniswap v3 router for rewards swaps
    ISwapRouter private immutable uniswap_router;

    /// @notice Uniswap v3 fee tier for the reward/asset pool (3000 = 0.3%)
    uint24 private immutable pool_fee;

    /// @notice Instance of the Lido wstETH contract to convert wstETH <-> stETH
    IWstETH private immutable wst_eth;

    /// @notice Instance of the WETH contract for converting WETH ↔ ETH
    IWETH private immutable weth;

    /**
     * @notice stETH as ERC20, needed to pre-approve the Curve pool
     * @dev stETH is received when calling unwrap() on wstETH. Curve needs allowance to
     *      execute the stETH→ETH swap during withdrawal
     */
    IERC20 private immutable st_eth;

    /// @notice Instance of the Curve stETH/ETH pool for the withdrawal swap
    ICurvePool private immutable curve_pool;

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
     * @notice Constructor of AaveStrategy
     * @dev Initializes the strategy with Aave v3, Lido and Curve. Approves the required contracts
     * @param _manager Address of the StrategyManager
     * @param _asset Address of the vault's underlying asset (WETH)
     * @param _aave_pool Address of the Aave v3 Pool
     * @param _rewards_controller Address of the Aave v3 RewardsController
     * @param _reward_token Address of the rewards token (AAVE)
     * @param _uniswap_router Address of the Uniswap v3 SwapRouter
     * @param _pool_fee Fee tier of the Uniswap pool for reward/WETH (3000 = 0.3%)
     * @param _wst_eth Address of the Lido wstETH contract
     * @param _weth Address of the WETH contract
     * @param _st_eth Address of the stETH contract
     * @param _curve_pool Address of the Curve stETH/ETH pool
     */
    constructor(
        address _manager,
        address _asset,
        address _aave_pool,
        address _rewards_controller,
        address _reward_token,
        address _uniswap_router,
        uint24 _pool_fee,
        address _wst_eth,
        address _weth,
        address _st_eth,
        address _curve_pool
    ) {
        // Assigns addresses, initializes contracts and sets the UV3 fee tier
        manager = _manager;
        asset_address = _asset;
        aave_pool = IPool(_aave_pool);
        rewards_controller = IRewardsController(_rewards_controller);
        reward_token = _reward_token;
        uniswap_router = ISwapRouter(_uniswap_router);
        pool_fee = _pool_fee;
        wst_eth = IWstETH(_wst_eth);
        weth = IWETH(_weth);
        st_eth = IERC20(_st_eth);
        curve_pool = ICurvePool(_curve_pool);

        // Gets the aToken address for wstETH dynamically from Aave
        address a_token_address = aave_pool.getReserveData(_wst_eth).aTokenAddress;
        a_token = IAToken(a_token_address);

        // Approves the Aave Pool to move all wstETH from this contract (for supply)
        IERC20(_wst_eth).forceApprove(_aave_pool, type(uint256).max);

        // Approves the Uniswap Router to move all Aave reward tokens from this contract (for harvest, swap WETH)
        IERC20(_reward_token).forceApprove(_uniswap_router, type(uint256).max);

        // Approves the Curve pool to move all stETH (for withdrawal, swap for ETH). We don't use
        // Uniswap for this swap because Curve has much more liquidity for the stETH/ETH pair
        IERC20(_st_eth).forceApprove(_curve_pool, type(uint256).max);
    }

    //* Special functions

    /**
     * @notice Accepts ETH from WETH.withdraw() (deposit path) and from the Curve swap (withdraw path)
     * @dev WETH.withdraw() sends ETH to the caller (this contract). The Curve pool also
     *      sends ETH to the caller when doing exchange(stETH -> ETH). Both use this receive()
     */
    receive() external payable {}

    //* Main functions

    /**
     * @notice Deposits WETH into Lido, receives wstETH and deposits it into Aave v3
     * @dev Can only be called by the StrategyManager
     * @dev Assumes assets (WETH) have already been transferred to this contract by the manager
     * @param assets Amount of WETH to deposit
     * @return shares Amount of WETH deposited
     */
    function deposit(uint256 assets) external onlyManager returns (uint256 shares) {
        // Calculates the wstETH balance of the contract before the operation (should be 0)
        uint256 wsteth_before = IERC20(address(wst_eth)).balanceOf(address(this));

        // Converts WETH to ETH. The ETH is received in this contract's receive()
        weth.withdraw(assets);

        // Sends ETH to the wstETH contract. Its receive() stakes it in Lido and returns wstETH
        (bool ok,) = address(wst_eth).call{value: assets}("");
        if (!ok) revert AaveStrategy__DepositFailed();

        // Calculates exactly how much wstETH we received from Lido (current balance - 0)
        uint256 wsteth_received = IERC20(address(wst_eth)).balanceOf(address(this)) - wsteth_before;

        // Deposits the received wstETH into Aave, returns shares (not used, but required to
        // comply with the interface) and emits event. Reverts on error
        try aave_pool.supply(address(wst_eth), wsteth_received, address(this), 0) {
            shares = assets;
            emit Deposited(msg.sender, assets, shares);
        } catch {
            revert AaveStrategy__DepositFailed();
        }
    }

    /**
     * @notice Withdraws assets from Aave v3 and returns them in WETH to the StrategyManager
     * @dev Can only be called by the StrategyManager
     * @param assets Amount of WETH to withdraw
     * @return actual_withdrawn WETH actually received (may differ due to slippage)
     */
    function withdraw(uint256 assets) external onlyManager returns (uint256 actual_withdrawn) {
        // Converts the requested WETH amount to its wstETH equivalent. stETH ≈ WETH (soft peg 1:1)
        uint256 wsteth_amount = wst_eth.getWstETHByStETH(assets);

        // Withdraws wstETH from Aave. Reverts on error
        try aave_pool.withdraw(address(wst_eth), wsteth_amount, address(this)) {
            // Unwraps wstETH to stETH
            uint256 steth_amount = wst_eth.unwrap(wsteth_amount);

            // Calculates minimum ETH expected from the Curve swap (1% max slippage)
            uint256 min_eth = (assets * (BASIS_POINTS - MAX_SLIPPAGE_BPS)) / BASIS_POINTS;

            // Swaps stETH (index 1) for ETH (index 0) via Curve pool. The received ETH arrives at receive()
            uint256 eth_received = curve_pool.exchange(1, 0, steth_amount, min_eth);

            // Converts ETH to WETH
            weth.deposit{value: eth_received}();

            // Sends the contract's WETH (received from Aave on withdrawal) to the manager
            actual_withdrawn = eth_received;
            IERC20(asset_address).safeTransfer(msg.sender, actual_withdrawn);

            // Emits event and returns the actual withdrawn amount (should differ by 1% max)
            emit Withdrawn(msg.sender, actual_withdrawn, assets);
        } catch {
            revert AaveStrategy__WithdrawFailed();
        }
    }

    /**
     * @notice Harvests Aave rewards, swaps them to WETH and reinvests as wstETH in Aave
     * @dev Can only be called by the StrategyManager
     * @dev Flow: claim AAVE reward tokens → swap to WETH via Uniswap → ETH → wstETH → Aave
     * @return profit Amount of WETH equivalent obtained after swap and reinvestment of rewards
     */
    function harvest() external onlyManager returns (uint256 profit) {
        // Builds array of aTokens (aWstETH) to claim Aave rewards
        address[] memory assets_to_claim = new address[](1);
        assets_to_claim[0] = address(a_token);

        // Claims accumulated rewards for the aToken in Aave. Reverts on error
        try rewards_controller.claimAllRewards(assets_to_claim, address(this)) returns (
            address[] memory, uint256[] memory claimed_amounts
        ) {
            // If there are no rewards to claim, return 0
            if (claimed_amounts.length == 0 || claimed_amounts[0] == 0) {
                return 0;
            }

            // If there are rewards to claim, calculates the minimum expected amount in the swap
            uint256 min_amount_out = (claimed_amounts[0] * (BASIS_POINTS - MAX_SLIPPAGE_BPS)) / BASIS_POINTS;

            // Creates the Uniswap V3 pool call parameters to swap reward -> WETH
            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                tokenIn: reward_token, // Token A (reward token)
                tokenOut: asset_address, // Token B (WETH)
                fee: pool_fee, // Fee tier
                recipient: address(this), // Address receiving the swap (this contract)
                deadline: block.timestamp, // To be executed in this block
                amountIn: claimed_amounts[0], // Amount of token A to swap
                amountOutMinimum: min_amount_out, // Minimum expected amount of Token B
                sqrtPriceLimitX96: 0 // No price limit
            });

            // Performs the aToken → WETH swap. If successful, reinvests as wstETH in Aave. Reverts on error
            try uniswap_router.exactInputSingle(params) returns (uint256 weth_out) {
                // Calculates wstETH balance before wrap (should be 0)
                uint256 wsteth_before = IERC20(address(wst_eth)).balanceOf(address(this));

                // Converts WETH → ETH → wstETH (same flow as in deposit)
                weth.withdraw(weth_out);

                (bool ok,) = address(wst_eth).call{value: weth_out}("");
                if (!ok) revert AaveStrategy__SwapFailed();

                // Reinvests the received wstETH in Aave
                uint256 wsteth_received = IERC20(address(wst_eth)).balanceOf(address(this)) - wsteth_before;
                aave_pool.supply(address(wst_eth), wsteth_received, address(this), 0);

                // Returns the profit in WETH equivalent (lucky that all tokens are ETH derivatives,
                // otherwise accounting would be a fucking nightmare) and emits the event
                profit = weth_out;
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
     * @notice Returns the total assets under management in WETH equivalent
     * @dev The aWstETH balance is 1:1 with wstETH. Converted to WETH equivalent
     *      using getStETHByWstETH() which applies the current Lido exchange rate.
     *      stETH ≈ ETH ≈ WETH in value, so this return is the value in WETH.
     *      The double yield (Lido + Aave) is reflected here as both rates grow.
     * @return total Total value in WETH equivalent
     */
    function totalAssets() external view returns (uint256 total) {
        uint256 awsteth_balance = a_token.balanceOf(address(this));
        return wst_eth.getStETHByWstETH(awsteth_balance);
    }

    /**
     * @notice Returns the current Aave APY for wstETH
     *
     * @dev Converts from RAY (1e27, Aave's internal unit) to basis points (1e4)
     *      RAY / 1e23 = basis points
     *
     * @dev Note: this APY reflects only the Aave lending yield (~3.5%).
     *      The Lido staking yield (~4%) is embedded in the growing wstETH exchange rate
     *      and is reflected in totalAssets(), not in this value.
     *
     * @return apy_basis_points Aave lending APY in basis points (350 = 3.5%)
     */
    function apy() external view returns (uint256 apy_basis_points) {
        // Gets the reserve data for wstETH in Aave (not WETH)
        DataTypes.ReserveData memory reserve_data = aave_pool.getReserveData(address(wst_eth));
        uint256 liquidity_rate = reserve_data.currentLiquidityRate;

        // Returns the APY (liquidity rate) cast to basis points
        apy_basis_points = liquidity_rate / 1e23;
    }

    /**
     * @notice Returns the strategy name
     * @return strategy_name Descriptive name of the strategy
     */
    function name() external pure returns (string memory strategy_name) {
        return "Aave v3 wstETH Strategy";
    }

    /**
     * @notice Returns the vault asset address (WETH)
     * @return asset_address Address of the underlying asset (WETH)
     */
    function asset() external view returns (address) {
        return asset_address;
    }

    /**
     * @notice Returns the available wstETH liquidity in Aave for withdrawals
     * @dev Useful for checking if there is enough liquidity before withdrawing
     * @return available Amount of wstETH available in Aave
     */
    function availableLiquidity() external view returns (uint256 available) {
        return IERC20(address(wst_eth)).balanceOf(address(a_token));
    }

    /**
     * @notice Returns the aToken (aWstETH) balance of this contract
     * @return balance Amount of aWstETH held by the contract
     */
    function aTokenBalance() external view returns (uint256 balance) {
        return a_token.balanceOf(address(this));
    }

    /**
     * @notice Returns pending rewards to claim in Aave
     * @dev Useful for estimating harvest profit before executing it
     * @return pending Amount of pending rewards (AAVE)
     */
    function pendingRewards() external view returns (uint256 pending) {
        // Creates an array with the aToken address (Aave requires it in an array)
        address[] memory assets_to_check = new address[](1);
        assets_to_check[0] = address(a_token);

        // Makes the Aave call to get the rewards balance for this contract
        return rewards_controller.getUserRewards(assets_to_check, address(this), reward_token);
    }
}
