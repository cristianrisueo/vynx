// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IWETH} from "@aave/contracts/misc/interfaces/IWETH.sol";
import {IStrategy} from "../interfaces/strategies/IStrategy.sol";
import {IWstETH} from "../interfaces/strategies/lido/IWstETH.sol";

/**
 * @title LidoStrategy
 * @author cristianrisueo
 * @notice Strategy that deposits assets into Lido (liquid staking) and receives wstETH (wrapped staking ETH)
 * @dev Implements IStrategy for integration with StrategyManager
 *
 * @dev wstETH auto-increments yield via growing exchange rate, no manual harvest needed
 *      There are no rewards to claim or swap, harvest() from lido always returns 0
 *
 * @dev Deposit flow: WETH → ETH (IWETH.withdraw) → wstETH (wstETH.receive)
 * @dev Withdrawal flow: wstETH → WETH directly via swap on Uniswap V3 wstETH/WETH pool
 */
contract LidoStrategy is IStrategy {
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
    error LidoStrategy__OnlyManager();

    /**
     * @notice Error when attempting to deposit or withdraw with zero amount
     */
    error LidoStrategy__ZeroAmount();

    /**
     * @notice Error when sending ETH to the wstETH contract for staking fails
     */
    error LidoStrategy__WrapFailed();

    /**
     * @notice Error when the wstETH to WETH swap on Uniswap V3 fails
     */
    error LidoStrategy__UnwrapFailed();

    //* Constants

    /// @notice Base for basis points calculations (10000 = 100%)
    uint256 private constant BASIS_POINTS = 10000;

    /// @notice Maximum slippage allowed in swaps in bps (100 = 1%)
    uint256 private constant MAX_SLIPPAGE_BPS = 100;

    /**
     * @notice Lido historical APY in basis points (400 = 4%)
     * @dev Hardcoded since Lido does not expose an on-chain APY oracle in a simple way
     *      Lido historical APY: ~3.5-4.5%
     */
    uint256 private constant LIDO_APY = 400;

    //* State variables

    /// @notice Address of the authorized StrategyManager
    address public immutable manager;

    /**
     * @notice Instance of the Lido wstETH contract
     * @dev Its receive() accepts ETH and returns wstETH by staking internally with Lido
     */
    IWstETH private immutable wst_eth;

    /**
     * @notice Instance of the WETH contract for converting WETH ↔ ETH (wraps/unwraps)
     * @dev WETH.withdraw() converts WETH → ETH (ETH is received in this contract's receive())
     */
    IWETH private immutable weth;

    /// @notice Address of the underlying asset (WETH)
    address private immutable asset_address;

    /// @notice Instance of the Uniswap v3 router for swaps
    ISwapRouter private immutable uniswap_router;

    /**
     * @notice Fee tier of the wstETH/WETH pool on Uniswap V3
     * @dev The main wstETH/WETH pool on mainnet uses tier 500 (0.05%)
     */
    uint24 private immutable pool_fee;

    //* Modifiers

    /**
     * @notice Only allows calls from the StrategyManager
     */
    modifier onlyManager() {
        if (msg.sender != manager) revert LidoStrategy__OnlyManager();
        _;
    }

    //* Constructor

    /**
     * @notice Constructor of LidoStrategy
     * @dev Initializes the strategy with Lido and approves the Uniswap router for withdrawals
     * @param _manager Address of the StrategyManager
     * @param _wst_eth Address of the Lido wstETH contract
     * @param _weth Address of the WETH contract
     * @param _uniswap_router Address of the Uniswap V3 SwapRouter
     * @param _pool_fee Fee tier of the wstETH/WETH pool on Uniswap (e.g. 500 = 0.05%)
     */
    constructor(address _manager, address _wst_eth, address _weth, address _uniswap_router, uint24 _pool_fee) {
        // Assigns addresses, initializes contracts and sets the UV3 fee tier
        manager = _manager;
        asset_address = _weth;
        wst_eth = IWstETH(_wst_eth);
        weth = IWETH(_weth);
        uniswap_router = ISwapRouter(_uniswap_router);
        pool_fee = _pool_fee;

        // Approves the Uniswap router to move wstETH from this contract during withdrawals
        IERC20(_wst_eth).forceApprove(_uniswap_router, type(uint256).max);
    }

    //* Special functions

    /**
     * @notice Accepts ETH received from WETH.withdraw() before depositing it into Lido
     * @dev Lido receives ETH, but the protocol's underlying asset is WETH. Solution: Unwrap
     */
    receive() external payable {}

    //* Main functions

    /**
     * @notice Deposits assets into Lido and receives wstETH that auto-accumulates yield
     * @dev Can only be called by the StrategyManager
     * @dev Assumes assets have already been transferred to this contract from the StrategyManager
     * @param assets Amount of WETH to deposit
     * @return shares Exact amount of wstETH received (measured via balance diff)
     */
    function deposit(uint256 assets) external onlyManager returns (uint256 shares) {
        // Checks that the amount to deposit is not 0
        if (assets == 0) revert LidoStrategy__ZeroAmount();

        // Calculates the wstETH balance of the contract before the deposit to compute exact shares
        uint256 wsteth_before = IERC20(address(wst_eth)).balanceOf(address(this));

        // Converts WETH to ETH. The ETH is received in this contract's receive()
        weth.withdraw(assets);

        // Sends ETH to the wstETH contract. Its receive() stakes it in Lido and returns wstETH
        (bool ok,) = address(wst_eth).call{value: assets}("");
        if (!ok) revert LidoStrategy__WrapFailed();

        // Calculates the wstETH balance of the contract again after the deposit
        uint256 wsteth_after = IERC20(address(wst_eth)).balanceOf(address(this));

        // Calculates exact shares received from Lido as balance difference
        shares = wsteth_after - wsteth_before;

        // Emits deposit event and returns the calculated shares
        emit Deposited(msg.sender, assets, shares);
    }

    /**
     * @notice Withdraws assets from Lido by swapping wstETH to WETH via Uniswap V3
     * @dev Can only be called by the StrategyManager
     * @dev Flow: calculates equivalent wstETH → swap wstETH to WETH → transfers WETH to manager
     * @param assets Amount of WETH to withdraw
     * @return actual_withdrawn WETH actually received after the swap (may differ due to slippage)
     */
    function withdraw(uint256 assets) external onlyManager returns (uint256 actual_withdrawn) {
        // Checks that the amount to withdraw is not 0
        if (assets == 0) revert LidoStrategy__ZeroAmount();

        // Calculates how much wstETH is needed to obtain the amount of WETH. In practice
        // calculates wstETH for ETH, but ETH and WETH are equivalent
        uint256 wsteth_to_swap = wst_eth.getWstETHByStETH(assets);

        // Minimum WETH expected from the swap (calculates 1% slippage)
        uint256 min_weth_out = (assets * (BASIS_POINTS - MAX_SLIPPAGE_BPS)) / BASIS_POINTS;

        // Builds the exactInputSingle swap parameters for Uniswap V3
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(wst_eth), // Token A (wstETH)
            tokenOut: asset_address, // Token B (WETH)
            fee: pool_fee, // Fee tier
            recipient: address(this), // Address receiving the swap (this contract)
            deadline: block.timestamp, // To be executed in this block
            amountIn: wsteth_to_swap, // Amount of token A to swap
            amountOutMinimum: min_weth_out, // Minimum expected amount of Token B
            sqrtPriceLimitX96: 0 // No price limit
        });

        // Performs the wstETH to WETH swap and transfers the result to the StrategyManager, transfers the amount
        // to the manager, emits deposit event and returns the withdrawn WETH amount. Reverts on error
        try uniswap_router.exactInputSingle(params) returns (uint256 weth_out) {
            actual_withdrawn = weth_out;
            IERC20(asset_address).safeTransfer(msg.sender, actual_withdrawn);
            emit Withdrawn(msg.sender, actual_withdrawn, assets);
        } catch {
            revert LidoStrategy__UnwrapFailed();
        }
    }

    /**
     * @notice Does nothing but is required to implement the interface
     * @dev Can only be called by the StrategyManager
     * @dev Unlike other protocols, Lido does not emit reward tokens
     *      The yield is already embedded in the value of wstETH and is reflected in totalAssets()
     * @return profit Always 0
     */
    function harvest() external onlyManager returns (uint256 profit) {
        emit Harvested(msg.sender, 0);
        return 0;
    }

    //* Query functions

    /**
     * @notice Returns the total assets under management expressed in WETH equivalent
     * @dev Converts the wstETH balance to its stETH/ETH equivalent using the exchange rate
     *      stETH ≈ ETH in value (soft peg 1:1), so it is equivalent to the value in WETH
     *      The yield is reflected here: as the wstETH exchange rate rises, totalAssets() grows
     * @return total Total value in ETH (and therefore WETH) equivalent
     */
    function totalAssets() external view returns (uint256 total) {
        uint256 wsteth_balance = IERC20(address(wst_eth)).balanceOf(address(this));
        return wst_eth.getStETHByWstETH(wsteth_balance);
    }

    /**
     * @notice Returns the Lido historical APY (hardcoded)
     * @dev Lido does not expose an on-chain APY oracle directly. The real yield
     *      is reflected in totalAssets(), not in this value, but it serves as a reference
     * @return apy_basis_points APY in basis points (400 = 4%)
     */
    function apy() external pure returns (uint256 apy_basis_points) {
        return LIDO_APY;
    }

    /**
     * @notice Returns the strategy name
     * @return strategy_name Descriptive name of the strategy
     */
    function name() external pure returns (string memory strategy_name) {
        return "Lido wstETH Strategy";
    }

    /**
     * @notice Returns the address of the underlying asset
     * @return Address of WETH
     */
    function asset() external view returns (address) {
        return asset_address;
    }

    /**
     * @notice Returns the wstETH balance of the contract
     * @dev Useful for debugging and off-chain checks
     * @return balance Amount of staked wstETH
     */
    function wstEthBalance() external view returns (uint256 balance) {
        return IERC20(address(wst_eth)).balanceOf(address(this));
    }
}
