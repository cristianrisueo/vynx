// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWETH} from "@aave/contracts/misc/interfaces/IWETH.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IStrategy} from "../interfaces/strategies/IStrategy.sol";
import {ILido} from "../interfaces/strategies/lido/ILido.sol";
import {ICurvePool} from "../interfaces/strategies/curve/ICurvePool.sol";
import {ICurveGauge} from "../interfaces/strategies/curve/ICurveGauge.sol";

/**
 * @title CurveStrategy
 * @author cristianrisueo
 * @notice Strategy that provides liquidity to the Curve stETH/ETH pool and stakes LP tokens in the gauge
 * @dev Implements IStrategy for integration with StrategyManager
 *
 * @dev Combines two yield sources:
 *      - Trading fees from the Curve stETH/ETH pool
 *      - CRV rewards from the gauge (reinvested via harvest)
 *
 * @dev Deposit flow: WETH → ETH (IWETH.withdraw) → stETH (Lido.submit) →
 *                       add_liquidity([0, stETH]) → LP tokens → gauge.deposit
 *
 * @dev Withdrawal flow:    gauge.withdraw → remove_liquidity_one_coin (index 0 = native ETH) →
 *                       WETH (IWETH.deposit) → manager
 *
 * @dev Harvest flow:   gauge.claim_rewards → CRV → Uniswap (CRV -> WETH) →
 *                       ETH → stETH (Lido) → add_liquidity → LP Tokens → gauge.deposit
 */
contract CurveStrategy is IStrategy {
    //* library attachments

    /**
     * @notice Uses SafeERC20 for all IERC20 operations safely
     * @dev Avoids common errors with legacy or poorly implemented tokens
     */
    using SafeERC20 for IERC20;

    //* Errors

    /**
     * @notice Error when only the strategy manager can call
     */
    error CurveStrategy__OnlyManager();

    /**
     * @notice Error when attempting to deposit or withdraw with zero amount
     */
    error CurveStrategy__ZeroAmount();

    /**
     * @notice Error when the CRV to WETH swap on Uniswap V3 fails during harvest
     */
    error CurveStrategy__SwapFailed();

    //* Constants

    /// @notice Base for basis points calculations (10000 = 100%)
    uint256 private constant BASIS_POINTS = 10000;

    /// @notice Maximum slippage allowed in liquidity operations and swaps in bps (100 = 1%)
    uint256 private constant MAX_SLIPPAGE_BPS = 100;

    /**
     * @notice Historical Curve stETH/ETH APY in basis points (600 = 6%)
     * @dev Combines trading fees (~1-2%) + CRV gauge rewards (~4%)
     *      Hardcoded since the real APY varies with pool volume and CRV price
     */
    uint256 private constant CURVE_APY = 600;

    //* State variables

    /// @notice Address of the authorized StrategyManager
    address public immutable manager;

    /// @notice Address of the underlying asset (WETH)
    address private immutable asset_address;

    /**
     * @notice Instance of the Lido stETH contract
     * @dev submit() accepts ETH via msg.value and returns stETH
     */
    ILido private immutable lido;

    /**
     * @notice Instance of the Curve stETH/ETH pool
     * @dev Pool structure: index 0 = ETH (native), index 1 = stETH
     */
    ICurvePool private immutable curve_pool;

    /// @notice Instance of the Curve gauge for staking LP tokens and receiving CRV
    ICurveGauge private immutable gauge;

    /**
     * @notice LP token of the Curve stETH/ETH pool
     * @dev Address: 0x06325440D014e39736583c165C2963BA99fAf14E
     */
    IERC20 private immutable lp_token;

    /// @notice Curve CRV rewards token
    IERC20 private immutable crv_token;

    /// @notice Instance of the WETH contract for converting WETH ↔ ETH
    IWETH private immutable weth;

    /// @notice Uniswap V3 router for CRV → WETH swaps during harvest
    ISwapRouter private immutable uniswap_router;

    /// @notice Fee tier of the CRV/WETH pool on Uniswap V3
    uint24 private immutable pool_fee;

    //* Modifiers

    /**
     * @notice Only allows calls from the StrategyManager
     */
    modifier onlyManager() {
        if (msg.sender != manager) revert CurveStrategy__OnlyManager();
        _;
    }

    //* Constructor

    /**
     * @notice Constructor of CurveStrategy
     * @dev Initializes the strategy with the Lido and Curve contracts, and approves the required contracts
     * @param _manager Address of the StrategyManager
     * @param _lido Address of the Lido stETH contract
     * @param _curve_pool Address of the Curve stETH/ETH pool
     * @param _gauge Address of the Curve gauge
     * @param _lp_token Address of the Curve pool LP token
     * @param _crv_token Address of the CRV token
     * @param _weth Address of the WETH contract
     * @param _uniswap_router Address of the Uniswap V3 SwapRouter
     * @param _pool_fee Fee tier of the CRV/WETH pool on Uniswap V3
     */
    constructor(
        address _manager,
        address _lido,
        address _curve_pool,
        address _gauge,
        address _lp_token,
        address _crv_token,
        address _weth,
        address _uniswap_router,
        uint24 _pool_fee
    ) {
        // Assigns addresses and initializes contracts
        manager = _manager;
        asset_address = _weth;
        lido = ILido(_lido);
        curve_pool = ICurvePool(_curve_pool);
        gauge = ICurveGauge(_gauge);
        lp_token = IERC20(_lp_token);
        crv_token = IERC20(_crv_token);
        weth = IWETH(_weth);
        uniswap_router = ISwapRouter(_uniswap_router);
        pool_fee = _pool_fee;

        // Approves the Curve pool to move stETH during deposits and harvest
        IERC20(_lido).forceApprove(_curve_pool, type(uint256).max);

        // Approves the gauge to move LP tokens during deposits and harvest
        IERC20(_lp_token).forceApprove(_gauge, type(uint256).max);

        // Approves the Uniswap Router to move CRV during harvest
        IERC20(_crv_token).forceApprove(_uniswap_router, type(uint256).max);
    }

    //* Special functions

    /**
     * @notice Accepts ETH from WETH.withdraw() (deposit/harvest) and from the stETH to ETH swap (withdrawal)
     */
    receive() external payable {}

    //* Main functions

    /**
     * @notice Deposits assets into the Curve stETH/ETH pool and stakes LP tokens in the gauge
     * @dev Can only be called by the StrategyManager
     * @dev Assumes assets have already been transferred to this contract from the StrategyManager
     * @param assets Amount of WETH to deposit
     * @return shares Amount of LP tokens staked in the gauge (measured via balance diff)
     */
    function deposit(uint256 assets) external onlyManager returns (uint256 shares) {
        // Checks that the amount to deposit is not 0
        if (assets == 0) revert CurveStrategy__ZeroAmount();

        // Converts WETH to ETH. The ETH is received in this contract's receive()
        weth.withdraw(assets);

        // Snapshot of the stETH balance before staking in Lido
        uint256 steth_before = lido.balanceOf(address(this));

        // Stakes ETH in Lido. submit() accepts ETH via msg.value and returns stETH to the contract
        lido.submit{value: assets}(address(0));

        // Calculates the exact amount of stETH received (current balance - previous)
        uint256 steth_received = lido.balanceOf(address(this)) - steth_before;

        // Calculates minimum LP tokens expected using Curve's virtual price (slippage protection)
        uint256 virtual_price = curve_pool.get_virtual_price();
        uint256 min_lp = (steth_received * 1e18 / virtual_price) * (BASIS_POINTS - MAX_SLIPPAGE_BPS) / BASIS_POINTS;

        // Snapshot of LP token balance before add_liquidity
        uint256 lp_before = lp_token.balanceOf(address(this));

        // Adds liquidity to the pool with stETH only (index 1). We don't add ETH (amounts[0] = 0)
        // Specifies the minimum expected LP tokens
        uint256[2] memory amounts = [uint256(0), steth_received];
        curve_pool.add_liquidity(amounts, min_lp);

        // Calculates the exact amount of LP tokens received (current balance - previous)
        uint256 lp_received = lp_token.balanceOf(address(this)) - lp_before;

        // Stakes LP tokens in the gauge to start receiving CRV rewards
        gauge.deposit(lp_received);

        // Returns deposited assets and emits event
        shares = assets;
        emit Deposited(msg.sender, assets, shares);
    }

    /**
     * @notice Withdraws assets from the Curve pool by unstaking LP tokens and removing liquidity
     * @dev Can only be called by the StrategyManager
     * @dev Flow: gauge.withdraw → remove_liquidity_one_coin(index 0 = native ETH) → WETH
     * @param assets Amount of WETH to withdraw
     * @return actual_withdrawn WETH actually received after the process
     */
    function withdraw(uint256 assets) external onlyManager returns (uint256 actual_withdrawn) {
        // Checks that the amount to withdraw is not 0
        if (assets == 0) revert CurveStrategy__ZeroAmount();

        // Calculates the amount of LP tokens needed to obtain `assets` in WETH
        // Adds the slippage margin to ensure sufficient coverage
        uint256 virtual_price = curve_pool.get_virtual_price();
        uint256 lp_needed = (assets * 1e18 * (BASIS_POINTS + MAX_SLIPPAGE_BPS)) / (virtual_price * BASIS_POINTS);

        // Limits lp_needed to the actual staked balance in the gauge to not exceed available amount
        uint256 gauge_balance = gauge.balanceOf(address(this));
        if (lp_needed > gauge_balance) {
            lp_needed = gauge_balance;
        }

        // Unstakes LP tokens from the gauge: LP tokens return to this contract
        gauge.withdraw(lp_needed);

        // Calculates the minimum ETH to receive to prevent slippage
        uint256 min_eth = (assets * (BASIS_POINTS - MAX_SLIPPAGE_BPS)) / BASIS_POINTS;

        // Withdraws liquidity directly in native ETH. The received ETH is sent to this contract via receive()
        uint256 eth_received = curve_pool.remove_liquidity_one_coin(lp_needed, int128(0), min_eth);

        // Converts ETH to WETH to return to the StrategyManager
        weth.deposit{value: eth_received}();

        // Transfers WETH to the manager, emits withdrawal event and returns the withdrawn amount
        actual_withdrawn = eth_received;
        IERC20(asset_address).safeTransfer(msg.sender, actual_withdrawn);

        emit Withdrawn(msg.sender, actual_withdrawn, assets);
    }

    /**
     * @notice Harvests CRV rewards from the gauge, swaps them to WETH and reinvests in the pool
     * @dev Can only be called by the StrategyManager
     * @dev Claims CRV, swaps CRV → WETH via Uniswap, converts to stETH, adds liquidity and re-stakes
     * @return profit Amount of WETH equivalent obtained from the CRV swap (before reinvesting)
     */
    function harvest() external onlyManager returns (uint256 profit) {
        // Claims accumulated CRV rewards in the gauge for this contract
        gauge.claim_rewards(address(this));

        // Gets the CRV balance of the contract
        uint256 crv_balance = crv_token.balanceOf(address(this));

        // If there is no CRV to claim, emits event and returns 0
        if (crv_balance == 0) {
            emit Harvested(msg.sender, 0);
            return 0;
        }

        // Builds the CRV → WETH swap parameters for Uniswap V3
        // amountOutMinimum = 0: no price protection. CRV and WETH have different prices
        // and calculating the minimum without an oracle would yield a meaningless value that would always revert
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(crv_token), // Token A (CRV)
            tokenOut: asset_address, // Token B (WETH)
            fee: pool_fee, // Fee tier of the CRV/WETH pool
            recipient: address(this), // Address receiving the swap (this contract)
            deadline: block.timestamp, // To be executed in this block
            amountIn: crv_balance, // Amount of CRV to swap
            amountOutMinimum: 0, // No minimum: no oracle to calculate CRV/WETH price
            sqrtPriceLimitX96: 0 // No price limit
        });

        // Performs the CRV → WETH swap. Reverts on error
        uint256 weth_received;
        try uniswap_router.exactInputSingle(params) returns (uint256 weth_out) {
            weth_received = weth_out;
        } catch {
            revert CurveStrategy__SwapFailed();
        }

        // Records the profit before reinvesting (the WETH obtained from the swap)
        profit = weth_received;

        // Converts WETH to ETH to stake in Lido. The ETH is received in receive()
        weth.withdraw(weth_received);

        // Snapshot of stETH balance before staking to calculate the exact stETH received
        uint256 steth_before = lido.balanceOf(address(this));

        // Stakes ETH in Lido to obtain stETH
        lido.submit{value: weth_received}(address(0));

        // Calculates the exact stETH received via balance difference
        uint256 steth_received = lido.balanceOf(address(this)) - steth_before;

        // Calculates minimum LP expected from reinvest using virtual price
        uint256 virtual_price = curve_pool.get_virtual_price();
        uint256 min_lp = (steth_received * 1e18 / virtual_price) * (BASIS_POINTS - MAX_SLIPPAGE_BPS) / BASIS_POINTS;

        // Snapshot of LP token balance before add_liquidity
        uint256 lp_before = lp_token.balanceOf(address(this));

        // Adds stETH to the Curve pool as liquidity (index 1 = stETH)
        uint256[2] memory amounts = [uint256(0), steth_received];
        curve_pool.add_liquidity(amounts, min_lp);

        // Calculates new LP tokens received and stakes them in the gauge to keep accumulating rewards
        uint256 new_lp = lp_token.balanceOf(address(this)) - lp_before;
        gauge.deposit(new_lp);

        // Emits harvest event with the obtained profit and returns the obtained profit
        emit Harvested(msg.sender, profit);
    }

    //* Query functions

    /**
     * @notice Returns the total assets under management in WETH
     * @dev Calculates the value of LP tokens staked in the gauge using the virtual price
     *      The virtual price grows over time as the pool accumulates trading fees
     * @dev total = lp_balance * virtual_price / 1e18
     * @return total Total value in WETH equivalent
     */
    function totalAssets() external view returns (uint256 total) {
        uint256 lp_balance = gauge.balanceOf(address(this));
        uint256 virtual_price = curve_pool.get_virtual_price();

        return (lp_balance * virtual_price) / 1e18;
    }

    /**
     * @notice Returns the Curve stETH/ETH historical APY (hardcoded)
     * @dev Trading fees + CRV rewards. The real yield varies with volume and CRV price
     * @return apy_basis_points APY in basis points (600 = 6%)
     */
    function apy() external pure returns (uint256 apy_basis_points) {
        return CURVE_APY;
    }

    /**
     * @notice Returns the strategy name
     * @return strategy_name Descriptive name of the strategy
     */
    function name() external pure returns (string memory strategy_name) {
        return "Curve stETH/ETH Strategy";
    }

    /**
     * @notice Returns the address of the underlying asset
     * @return Address of WETH
     */
    function asset() external view returns (address) {
        return asset_address;
    }

    /**
     * @notice Returns the LP token balance staked in the gauge
     * @dev Useful for debugging and off-chain checks
     * @return balance Amount of LP tokens staked in the gauge
     */
    function lpBalance() external view returns (uint256 balance) {
        return gauge.balanceOf(address(this));
    }
}
