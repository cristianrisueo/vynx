// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {INonfungiblePositionManager} from "../interfaces/strategies/uniswap/INonfungiblePositionManager.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "../libraries/TickMath.sol";
import {FullMath} from "../libraries/FullMath.sol";
import {LiquidityAmounts} from "../libraries/LiquidityAmounts.sol";
import {IStrategy} from "../interfaces/strategies/IStrategy.sol";

/**
 * @title UniswapV3Strategy
 * @author cristianrisueo
 * @notice Strategy that provides concentrated liquidity to the Uniswap V3 WETH/USDC pool to earn trading fees
 * @dev Implements IStrategy for integration with StrategyManager
 *
 * @dev Each LP position in Uniswap V3 is a unique NFT (tokenId). This strategy maintains ONE position
 *      that is increased or decreased according to the StrategyManager's deposits/withdrawals
 *
 * @dev The tick range is calculated in the constructor from the pool's current tick (±TICK_RANGE ≈ ±10%)
 *      A wide range minimizes out-of-range risk but sacrifices APY vs a narrow range
 *
 * @dev Deposit flow:   WETH → swap 50% WETH to USDC → mint/increaseLiquidity (WETH+USDC → NFT)
 * @dev Withdrawal flow:     decreaseLiquidity (NFT → WETH+USDC) → collect → swap USDC→WETH → manager
 * @dev Harvest flow:    collect fees (WETH+USDC) → swap USDC→WETH → swap 50% WETH→USDC → increaseLiquidity
 *
 * @dev Main WETH/USDC pool on mainnet (0.05% fee): 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640
 *      Token ordering: USDC (0xA0...) < WETH (0xC0...) → token0=USDC, token1=WETH
 */
contract UniswapV3Strategy is IStrategy {
    //* library attachments

    /**
     * @notice Uses SafeERC20 for all IERC20 operations safely
     */
    using SafeERC20 for IERC20;

    //* Errors

    /// @notice Error when only the strategy manager can call
    error UniswapV3Strategy__OnlyManager();

    /// @notice Error when attempting to deposit or withdraw with zero amount
    error UniswapV3Strategy__ZeroAmount();

    /// @notice Error when the LP position mint fails
    error UniswapV3Strategy__MintFailed();

    /// @notice Error when a WETH ↔ USDC swap on the router fails
    error UniswapV3Strategy__SwapFailed();

    /// @notice Error when attempting to withdraw without an active position or with insufficient liquidity
    error UniswapV3Strategy__InsufficientLiquidity();

    //* Constants

    /// @notice Base for basis points calculations (10000 = 100%)
    uint256 private constant BASIS_POINTS = 10000;

    /// @notice Fee tier of the WETH/USDC pool on Uniswap V3 (500 = 0.05%)
    uint24 private constant POOL_FEE = 500;

    /// @notice Tick spacing of the 0.05% fee pool (each fee tier has its own spacing)
    int24 private constant TICK_SPACING = 10;

    /**
     * @notice Tick range on each side of the current tick to define the position range
     * @dev 960 ticks ≈ ±10% of price (log(1.10) / log(1.0001) ≈ 953, rounded to multiple of 10)
     *      A wider range = fewer fees but less risk of going out of range
     */
    int24 private constant TICK_RANGE = 960;

    /**
     * @notice Historical Uniswap V3 WETH/USDC APY in basis points (1400 = 14%)
     * @dev Highly variable depending on trading volume. This value is a historical estimate.
     */
    uint256 private constant UNISWAP_V3_APY = 1400;

    /// @notice 2^96 used for price calculations with sqrtPriceX96
    uint256 private constant Q96 = 2 ** 96;

    //* State variables

    /// @notice Address of the authorized StrategyManager
    address public immutable manager;

    /// @notice Address of the underlying asset (WETH)
    address private immutable asset_address;

    /// @notice Uniswap V3 NonfungiblePositionManager: manages LP positions as NFTs
    INonfungiblePositionManager private immutable position_manager;

    /// @notice Uniswap V3 SwapRouter for WETH ↔ USDC exchanges
    ISwapRouter private immutable swap_router;

    /**
     * @notice Instance of the Uniswap V3 WETH/USDC pool
     * @dev Used to read the current price (slot0.sqrtPriceX96) in totalAssets()
     */
    IUniswapV3Pool private immutable pool;

    /// @notice Address of the WETH contract
    address private immutable weth;

    /// @notice Address of the USDC contract
    address private immutable usdc;

    /**
     * @notice Token ordered at position 0 of the pool (lower address between WETH and USDC)
     * @dev Uniswap V3 requires token0 < token1 by address. For WETH/USDC: token0 = USDC
     */
    address private immutable token0;

    /// @notice Token ordered at position 1 of the pool (higher address between WETH and USDC)
    address private immutable token1;

    /**
     * @notice Indicates whether WETH is token0 in the pool
     * @dev In the WETH/USDC pool: USDC (0xA0...) < WETH (0xC0...), so weth_is_token0 = false
     *      This flag determines how to map amount0/amount1 to WETH/USDC throughout the contract
     */
    bool private immutable weth_is_token0;

    /**
     * @notice Lower tick of the LP position range (calculated in constructor)
     * @dev Lowest tick of the price range in which the position accumulates fees
     */
    int24 public immutable lower_tick;

    /**
     * @notice Upper tick of the LP position range (calculated in constructor)
     * @dev Highest tick of the price range in which the position accumulates fees
     */
    int24 public immutable upper_tick;

    /**
     * @notice ID of the NFT representing this contract's LP position
     * @dev 0 = no active position. Assigned on the first deposit and reset to 0 when the NFT is burned
     */
    uint256 public token_id;

    //* Modifiers

    /// @notice Only allows calls from the StrategyManager
    modifier onlyManager() {
        if (msg.sender != manager) revert UniswapV3Strategy__OnlyManager();
        _;
    }

    //* Constructor

    /**
     * @notice Constructor of UniswapV3Strategy
     * @dev Reads the current pool tick to calculate the immutable position range (±TICK_RANGE ≈ ±10%)
     * @dev Approves the position manager and swap router to move WETH and USDC
     * @param _manager Address of the StrategyManager
     * @param _position_manager Uniswap V3 NonfungiblePositionManager (0xC36442b4a4522E871399CD717aBDD847Ab11FE88)
     * @param _swap_router Uniswap V3 SwapRouter (0xE592427A0AEce92De3Edee1F18E0157C05861564)
     * @param _pool Uniswap V3 WETH/USDC 0.05% pool (0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640)
     * @param _weth Address of the WETH contract (0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2)
     * @param _usdc Address of the USDC contract (0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48)
     */
    constructor(
        address _manager,
        address _position_manager,
        address _swap_router,
        address _pool,
        address _weth,
        address _usdc
    ) {
        manager = _manager;
        asset_address = _weth;
        position_manager = INonfungiblePositionManager(_position_manager);
        swap_router = ISwapRouter(_swap_router);
        pool = IUniswapV3Pool(_pool);
        weth = _weth;
        usdc = _usdc;

        // Determines token order: Uniswap V3 requires token0 < token1 by address
        // For WETH/USDC: USDC (0xA0...) < WETH (0xC0...) → token0=USDC, token1=WETH
        weth_is_token0 = _weth < _usdc;
        token0 = _weth < _usdc ? _weth : _usdc;
        token1 = _weth < _usdc ? _usdc : _weth;

        // Reads the current pool tick and calculates the position range (±TICK_RANGE ticks ≈ ±10% price)
        // The current tick is rounded down to the nearest multiple of TICK_SPACING
        (, int24 current_tick,,,,,) = IUniswapV3Pool(_pool).slot0();
        int24 rounded = (current_tick / TICK_SPACING) * TICK_SPACING;
        lower_tick = rounded - TICK_RANGE;
        upper_tick = rounded + TICK_RANGE;

        // Approves the position manager to move WETH and USDC in mint/increaseLiquidity
        IERC20(_weth).forceApprove(_position_manager, type(uint256).max);
        IERC20(_usdc).forceApprove(_position_manager, type(uint256).max);

        // Approves the swap router for WETH ↔ USDC exchanges in deposit, withdraw and harvest
        IERC20(_weth).forceApprove(_swap_router, type(uint256).max);
        IERC20(_usdc).forceApprove(_swap_router, type(uint256).max);
    }

    //* Main functions

    /**
     * @notice Deposits WETH into the LP position of the Uniswap V3 WETH/USDC pool
     * @dev Can only be called by the StrategyManager
     * @dev Assumes assets have already been transferred to this contract from the StrategyManager
     * @dev Process: swap 50% WETH→USDC → mint (if first time) or increaseLiquidity
     * @param assets Amount of WETH to deposit
     * @return shares Assets deposited (consistent with other strategies)
     */
    function deposit(uint256 assets) external onlyManager returns (uint256 shares) {
        if (assets == 0) revert UniswapV3Strategy__ZeroAmount();

        // Swaps half of WETH to USDC to build the LP position pair
        // The WETH/USDC position requires both tokens in proportion to the current price
        uint256 weth_to_swap = assets / 2;
        uint256 weth_to_keep = assets - weth_to_swap;

        // Swaps WETH → USDC with no minimum: the WETH/USDC ratio cannot be calculated without an oracle
        // The keeper calling deposit is responsible for reasonable market conditions
        uint256 usdc_received;
        try swap_router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: weth,
                tokenOut: usdc,
                fee: POOL_FEE,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: weth_to_swap,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        ) returns (uint256 amount_out) {
            usdc_received = amount_out;
        } catch {
            revert UniswapV3Strategy__SwapFailed();
        }

        // Maps WETH and USDC to amount0/amount1 according to the pool's token order
        uint256 amount0_desired = weth_is_token0 ? weth_to_keep : usdc_received;
        uint256 amount1_desired = weth_is_token0 ? usdc_received : weth_to_keep;

        if (token_id == 0) {
            // First time: mints a new LP position and saves the tokenId
            try position_manager.mint(
                INonfungiblePositionManager.MintParams({
                    token0: token0,
                    token1: token1,
                    fee: POOL_FEE,
                    tickLower: lower_tick,
                    tickUpper: upper_tick,
                    amount0Desired: amount0_desired,
                    amount1Desired: amount1_desired,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: address(this),
                    deadline: block.timestamp
                })
            ) returns (uint256 new_token_id, uint128, uint256, uint256) {
                token_id = new_token_id;
            } catch {
                revert UniswapV3Strategy__MintFailed();
            }
        } else {
            // Existing position: increases liquidity without changing the tick range
            position_manager.increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams({
                    tokenId: token_id,
                    amount0Desired: amount0_desired,
                    amount1Desired: amount1_desired,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            );
        }

        shares = assets;
        emit Deposited(msg.sender, assets, shares);
    }

    /**
     * @notice Withdraws assets from the LP position by decreasing liquidity and converting to WETH
     * @dev Can only be called by the StrategyManager
     * @dev Process: decreaseLiquidity → collect → swap USDC→WETH → transfer manager
     * @dev If liquidity reaches 0, burns the NFT and resets token_id = 0
     * @param assets Amount of WETH to withdraw
     * @return actual_withdrawn WETH actually received (may differ due to price and slippage)
     */
    function withdraw(uint256 assets) external onlyManager returns (uint256 actual_withdrawn) {
        if (assets == 0) revert UniswapV3Strategy__ZeroAmount();
        if (token_id == 0) revert UniswapV3Strategy__InsufficientLiquidity();

        // Gets the current total liquidity of the position
        (,,,,,,, uint128 total_liquidity,,,,) = position_manager.positions(token_id);
        if (total_liquidity == 0) revert UniswapV3Strategy__InsufficientLiquidity();

        // Calculates the proportion of liquidity to withdraw: assets / totalAssets
        // If more than available is requested, withdraws the entire position
        uint256 total = _totalAssets();
        uint128 liquidity_to_remove;
        if (total == 0 || assets >= total) {
            liquidity_to_remove = total_liquidity;
        } else {
            liquidity_to_remove = uint128(FullMath.mulDiv(total_liquidity, assets, total));
        }

        // Decreases liquidity: tokens move to "owed" state (pending collect)
        position_manager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: token_id,
                liquidity: liquidity_to_remove,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );

        // Collects all pending tokens (withdrawn liquidity + accumulated fees)
        (uint256 collected0, uint256 collected1) = position_manager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: token_id,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        // If the position has no liquidity left, burns the NFT and resets the token_id
        (,,,,,,, uint128 remaining_liquidity,,,,) = position_manager.positions(token_id);
        if (remaining_liquidity == 0) {
            position_manager.burn(token_id);
            token_id = 0;
        }

        // Separates WETH and USDC according to the pool's token order
        uint256 weth_collected = weth_is_token0 ? collected0 : collected1;
        uint256 usdc_collected = weth_is_token0 ? collected1 : collected0;

        // Swaps USDC → WETH to return everything in WETH to the StrategyManager
        if (usdc_collected > 0) {
            try swap_router.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: usdc,
                    tokenOut: weth,
                    fee: POOL_FEE,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: usdc_collected,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            ) returns (uint256 weth_from_usdc) {
                weth_collected += weth_from_usdc;
            } catch {
                revert UniswapV3Strategy__SwapFailed();
            }
        }

        // Transfers all WETH to the manager and emits event
        actual_withdrawn = weth_collected;
        IERC20(asset_address).safeTransfer(msg.sender, actual_withdrawn);
        emit Withdrawn(msg.sender, actual_withdrawn, assets);
    }

    /**
     * @notice Harvests accumulated fees from the LP position and reinvests them as liquidity
     * @dev Can only be called by the StrategyManager
     * @dev Collect does not touch the principal liquidity, only collects fees. The fees are reinvested
     *      by converting 50% of WETH to USDC and increasing the existing LP position
     * @return profit Amount of WETH equivalent obtained in fees before reinvesting
     */
    function harvest() external onlyManager returns (uint256 profit) {
        // No active position, no fees to claim
        if (token_id == 0) {
            emit Harvested(msg.sender, 0);
            return 0;
        }

        // Collects accumulated fees without affecting the principal liquidity
        (uint256 collected0, uint256 collected1) = position_manager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: token_id,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        // No fees to process
        if (collected0 == 0 && collected1 == 0) {
            emit Harvested(msg.sender, 0);
            return 0;
        }

        // Separates WETH and USDC according to the pool's token order
        uint256 weth_fees = weth_is_token0 ? collected0 : collected1;
        uint256 usdc_fees = weth_is_token0 ? collected1 : collected0;

        // Converts USDC fees to WETH to have everything as a profit calculation base
        if (usdc_fees > 0) {
            try swap_router.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: usdc,
                    tokenOut: weth,
                    fee: POOL_FEE,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: usdc_fees,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            ) returns (uint256 weth_from_usdc) {
                weth_fees += weth_from_usdc;
            } catch {
                revert UniswapV3Strategy__SwapFailed();
            }
        }

        // Records total profit in WETH before reinvesting
        profit = weth_fees;

        // Reinvests fees: swap 50% WETH → USDC, then increases the LP position
        uint256 weth_to_swap = weth_fees / 2;
        uint256 weth_to_keep = weth_fees - weth_to_swap;

        uint256 usdc_for_reinvest;
        if (weth_to_swap > 0) {
            try swap_router.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: weth,
                    tokenOut: usdc,
                    fee: POOL_FEE,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: weth_to_swap,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            ) returns (uint256 usdc_out) {
                usdc_for_reinvest = usdc_out;
            } catch {
                revert UniswapV3Strategy__SwapFailed();
            }
        }

        // Increases the existing position's liquidity with the reinvested fees
        uint256 amount0 = weth_is_token0 ? weth_to_keep : usdc_for_reinvest;
        uint256 amount1 = weth_is_token0 ? usdc_for_reinvest : weth_to_keep;

        position_manager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: token_id,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );

        emit Harvested(msg.sender, profit);
    }

    //* Query functions

    /**
     * @notice Returns the total assets under management expressed in WETH equivalent
     * @dev Calculates the value of the LP position using the current pool price:
     *      1. Gets the position liquidity and pending fees
     *      2. Uses LiquidityAmounts to convert liquidity to token0/token1 amounts
     *      3. Converts token0/token1 to WETH using the pool's sqrtPriceX96
     * @return total Total value in WETH equivalent
     */
    function totalAssets() external view returns (uint256 total) {
        return _totalAssets();
    }

    /**
     * @notice Returns the Uniswap V3 WETH/USDC historical APY (hardcoded)
     * @dev Highly variable depending on volume. This value is a historical estimate
     * @return apy_basis_points APY in basis points (1400 = 14%)
     */
    function apy() external pure returns (uint256 apy_basis_points) {
        return UNISWAP_V3_APY;
    }

    /**
     * @notice Returns the strategy name
     * @return strategy_name Descriptive name of the strategy
     */
    function name() external pure returns (string memory strategy_name) {
        return "Uniswap V3 WETH/USDC Strategy";
    }

    /**
     * @notice Returns the address of the underlying asset
     * @return Address of WETH
     */
    function asset() external view returns (address) {
        return asset_address;
    }

    //* Internal functions

    /**
     * @notice Internal totalAssets logic for reuse in withdraw
     * @dev Separated from totalAssets() to avoid an external call inside withdraw
     */
    function _totalAssets() internal view returns (uint256) {
        if (token_id == 0) return 0;

        // Gets liquidity and pending fees from the position
        (,,,,,,, uint128 liquidity,,, uint128 tokens_owed0, uint128 tokens_owed1) =
            position_manager.positions(token_id);

        if (liquidity == 0 && tokens_owed0 == 0 && tokens_owed1 == 0) return 0;

        // Reads the current pool price (sqrtPriceX96 = sqrt(token1/token0) * 2^96)
        (uint160 sqrt_price_x96,,,,,,) = pool.slot0();

        // Calculates sqrtPrices at the range boundaries for use with LiquidityAmounts
        uint160 sqrt_price_lower = TickMath.getSqrtRatioAtTick(lower_tick);
        uint160 sqrt_price_upper = TickMath.getSqrtRatioAtTick(upper_tick);

        // Calculates the amounts of token0 and token1 corresponding to the current liquidity
        // Takes into account whether the price is inside, below or above the range
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrt_price_x96, sqrt_price_lower, sqrt_price_upper, liquidity
        );

        // Adds pending fees to collect (also in token0/token1)
        amount0 += tokens_owed0;
        amount1 += tokens_owed1;

        // Maps amount0/amount1 to WETH/USDC according to the pool's token order
        uint256 weth_amount = weth_is_token0 ? amount0 : amount1;
        uint256 usdc_amount = weth_is_token0 ? amount1 : amount0;

        // Converts USDC to WETH using the current pool price
        // price = sqrtPriceX96^2 / Q96^2 = token1_raw / token0_raw
        //
        // Case weth_is_token0 = false (our pool: token0=USDC, token1=WETH):
        //   price = WETH_raw / USDC_raw
        //   weth_from_usdc = usdc * price = usdc * sqrtPriceX96^2 / Q96^2
        //
        // Case weth_is_token0 = true (hypothetical pool: token0=WETH, token1=USDC):
        //   price = USDC_raw / WETH_raw (inverse of the price in WETH terms)
        //   weth_from_usdc = usdc / price = usdc * Q96^2 / sqrtPriceX96^2
        uint256 weth_from_usdc;
        if (usdc_amount > 0) {
            if (weth_is_token0) {
                // price = USDC/WETH → invert to get WETH/USDC
                weth_from_usdc = FullMath.mulDiv(
                    FullMath.mulDiv(usdc_amount, Q96, uint256(sqrt_price_x96)),
                    Q96,
                    uint256(sqrt_price_x96)
                );
            } else {
                // price = WETH/USDC → multiply directly
                weth_from_usdc = FullMath.mulDiv(
                    FullMath.mulDiv(usdc_amount, uint256(sqrt_price_x96), Q96),
                    uint256(sqrt_price_x96),
                    Q96
                );
            }
        }

        return weth_amount + weth_from_usdc;
    }
}
