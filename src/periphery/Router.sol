// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IRouter} from "../interfaces/periphery/IRouter.sol";

/**
 * @title Router
 * @author cristianrisueo
 * @notice Peripheral contract that allows depositing any token (ETH, USDC, DAI, etc.) into the VynX Vault
 * @dev Swaps tokens to WETH via Uniswap V3 and then deposits into the Vault
 * @dev Router design principles:
 *      - The Vault stays as a pure ERC4626 (WETH only)
 *      - The Router is a stateless peripheral (does not retain funds between transactions)
 *      - Users receive vault shares directly (the Router does not custody shares)
 *      - Pool with variable fee specified by the frontend
 * @dev Security features:
 *      - ReentrancyGuard on all public functions
 *      - Slippage protection via the min_weth_out parameter
 *      - Balance verification (stateless design compliance)
 *      - No special privileges in the Vault (the Router is a normal user)
 */
contract Router is IRouter, ReentrancyGuard {
    //* library attachments

    /**
     * @notice Uses SafeERC20 for all IERC20 operations safely
     * @dev Avoids common errors with legacy or poorly implemented tokens
     */
    using SafeERC20 for IERC20;

    //* Errors

    /**
     * @notice Error when a zero address is passed to the constructor
     */
    error Router__ZeroAddress();

    /**
     * @notice Error when trying to deposit a zero amount
     */
    error Router__ZeroAmount();

    /**
     * @notice Error when slippage protection is triggered (received less than the minimum)
     */
    error Router__SlippageExceeded();

    /**
     * @notice Error when the ETH wrap operation fails
     */
    error Router__ETHWrapFailed();

    /**
     * @notice Error when funds get stuck in the Router after the operation (stateless design violation)
     */
    error Router__FundsStuck();

    /**
     * @notice Error when the user tries to deposit WETH via Router instead of directly into the Vault
     */
    error Router__UseVaultForWETH();

    /**
     * @notice Error when ETH is received from an unauthorized address (only the WETH contract can send ETH)
     */
    error Router__UnauthorizedETHSender();

    /**
     * @notice Error when the WETH to ETH unwrap operation fails
     */
    error Router__ETHUnwrapFailed();

    //* Events: Inherited from the interface, no need to implement them

    //* State variables

    /// @notice Address of the WETH token
    address public immutable weth;

    /// @notice Address of the VynX Vault (ERC4626 compatible)
    address public immutable vault;

    /// @notice Address of the Uniswap V3 SwapRouter
    address public immutable swap_router;

    //* Constructor

    /**
     * @notice Router constructor
     * @dev Initializes the immutable addresses and approves WETH transfer to the Vault
     * @param _weth Address of the WETH token
     * @param _vault Address of the VynX Vault
     * @param _swap_router Address of the Uniswap V3 SwapRouter
     */
    constructor(address _weth, address _vault, address _swap_router) {
        // Checks that addresses are not address(0)
        if (_weth == address(0)) revert Router__ZeroAddress();
        if (_vault == address(0)) revert Router__ZeroAddress();
        if (_swap_router == address(0)) revert Router__ZeroAddress();

        // Sets the addresses
        weth = _weth;
        vault = _vault;
        swap_router = _swap_router;

        // Approves the vault to transfer all WETH from this contract
        IERC20(_weth).forceApprove(_vault, type(uint256).max);
    }

    //* Main functions - ETH and ERC20 deposits and withdrawals

    /**
     * @notice Deposits native ETH into the Vault (wraps to WETH first)
     * @dev Wraps ETH to WETH, deposits into the Vault and emits shares to msg.sender
     * @dev Flow:
     *      1. Receives ETH via msg.value
     *      2. Wraps ETH to WETH
     *      3. Deposits WETH into the Vault
     *      4. The Vault emits shares directly to the user
     * @return shares Amount of vault shares received by the user
     */
    function zapDepositETH() external payable nonReentrant returns (uint256 shares) {
        // Checks that msg.value is not zero
        if (msg.value == 0) revert Router__ZeroAmount();

        // Wraps ETH to WETH using an internal function (at this point the balance is already WETH 1:1)
        _wrapETH(msg.value);

        // Deposits WETH into the Vault (minting shares to the caller, not the router)
        shares = IERC4626(vault).deposit(msg.value, msg.sender);

        // Checks that the router has a WETH balance of 0 after the operation
        if (IERC20(weth).balanceOf(address(this)) != 0) revert Router__FundsStuck();

        // Emits ZapDeposit event
        emit ZapDeposit(msg.sender, address(0), msg.value, msg.value, shares);
    }

    /**
     * @notice Deposits ERC20 token into the Vault (swaps to WETH first)
     * @dev Swaps token_in -> WETH via Uniswap V3 using the specified pool, then deposits into the Vault
     * @dev Flow:
     *      1. Transfers token_in from user to Router
     *      2. Swaps token_in -> WETH (Uniswap V3, pool specified by pool_fee)
     *      3. Validates slippage protection
     *      4. Deposits WETH into the Vault
     *      5. The Vault mints shares directly to the user
     *      6. Checks that the Router remains stateless (balance = 0)
     * @dev Supported tokens: Any token with a WETH pair on Uniswap V3
     * @dev Common pools: USDC/DAI/USDT typically use 500 (0.05%), WBTC uses 3000 (0.3%)
     * @dev The frontend should calculate the optimal pool before calling, automatically choosing
     *      the most profitable one for the token pair
     * @param token_in Token to deposit
     * @param amount_in Amount of token_in to deposit
     * @param pool_fee Fee tier of the Uniswap V3 pool (100, 500, 3000, or 10000)
     * @param min_weth_out Minimum WETH to receive from the swap (slippage protection)
     * @return shares Amount of vault shares received
     */
    function zapDepositERC20(address token_in, uint256 amount_in, uint24 pool_fee, uint256 min_weth_out)
        external
        nonReentrant
        returns (uint256 shares)
    {
        // Checks that token_in is not address(0), if it is they sent ETH or are trolling us
        if (token_in == address(0)) revert Router__ZeroAddress();

        // Checks that token_in is not WETH (should use vault.deposit() directly for WETH)
        if (token_in == weth) revert Router__UseVaultForWETH();

        // Checks that amount_in is not zero
        if (amount_in == 0) revert Router__ZeroAmount();

        // Transfers the specified tokens from the user to the Router
        IERC20(token_in).safeTransferFrom(msg.sender, address(this), amount_in);

        // Swaps token_in -> WETH using an internal function (which calls Uniswap V3, the specified pool)
        uint256 weth_out = _swapToWETH(token_in, amount_in, pool_fee, min_weth_out);

        // Deposits WETH into the Vault (minting shares to the caller, not the router)
        shares = IERC4626(vault).deposit(weth_out, msg.sender);

        // Checks that the router has a WETH balance of 0 after the operation
        if (IERC20(weth).balanceOf(address(this)) != 0) revert Router__FundsStuck();

        // Emits ZapDeposit event
        emit ZapDeposit(msg.sender, token_in, amount_in, weth_out, shares);
    }

    /**
     * @notice Withdraws shares from the Vault and receives native ETH
     * @dev Redeems shares from the Vault for WETH, unwraps WETH to ETH, sends ETH to the user
     * @dev Flow:
     *      1. Transfers shares from user to Router (requires prior approval)
     *      2. Redeems shares in the Vault -> receives WETH
     *      3. Unwraps WETH -> ETH
     *      5. Transfers ETH to the user
     *      6. Checks that the Router remains stateless (balance = 0)
     * @param shares Amount of vault shares to burn
     * @return eth_out Amount of ETH received by the user
     */
    function zapWithdrawETH(uint256 shares) external nonReentrant returns (uint256 eth_out) {
        // Checks that shares to redeem is not zero
        if (shares == 0) revert Router__ZeroAmount();

        // Transfers shares from user to Router (requires prior approval)
        IERC20(vault).safeTransferFrom(msg.sender, address(this), shares);

        // Redeems shares from the Vault and obtains the corresponding WETH
        uint256 weth_redeemed = IERC4626(vault).redeem(shares, address(this), address(this));

        // Unwraps WETH to ETH using internal function (eth_out could be omitted, we have it for convenience)
        eth_out = _unwrapWETH(weth_redeemed);

        // Transfers ETH to the user
        (bool success,) = msg.sender.call{value: eth_out}("");
        if (!success) revert Router__ETHUnwrapFailed();

        // Checks that the router has a WETH balance of 0 after the operation
        if (IERC20(weth).balanceOf(address(this)) != 0) revert Router__FundsStuck();

        // Emits ZapWithdraw event
        emit ZapWithdraw(msg.sender, shares, weth_redeemed, address(0), eth_out);
    }

    /**
     * @notice Withdraws shares from the vault and receives ERC20 token (swaps from WETH)
     * @dev Redeems shares for WETH, swaps WETH -> token_out via Uniswap V3, sends token_out to the user
     * @dev Flow:
     *      1. Transfers shares from user to Router (requires prior approval)
     *      2. Router redeems shares in the Vault -> receives WETH
     *      3. Swaps WETH -> token_out (Uniswap V3, pool specified by pool_fee)
     *      4. Validates slippage protection
     *      5. Transfers token_out to the user
     *      6. Checks that the Router remains stateless after the operation (balances = 0)
     * @dev The frontend should calculate the optimal pool before calling
     * @param shares Amount of vault shares to burn
     * @param token_out Token to receive
     * @param pool_fee Fee tier of the Uniswap V3 pool (100, 500, 3000, or 10000)
     * @param min_token_out Minimum token_out to receive after the swap (slippage protection)
     * @return amount_out Amount of token_out received by the user
     */
    function zapWithdrawERC20(uint256 shares, address token_out, uint24 pool_fee, uint256 min_token_out)
        external
        nonReentrant
        returns (uint256 amount_out)
    {
        // Checks that token_out is not address(0)
        if (token_out == address(0)) revert Router__ZeroAddress();

        // Checks that token_out is not WETH (should use vault.redeem() directly for WETH)
        if (token_out == weth) revert Router__UseVaultForWETH();

        // Checks that shares to redeem are not zero
        if (shares == 0) revert Router__ZeroAmount();

        // Transfers shares from user to Router (requires prior approval)
        IERC20(vault).safeTransferFrom(msg.sender, address(this), shares);

        // Redeems shares in the vault and receives WETH
        uint256 weth_redeemed = IERC4626(vault).redeem(shares, address(this), address(this));

        // Swaps WETH -> token_out using internal function
        amount_out = _swapFromWETH(weth_redeemed, token_out, pool_fee, min_token_out);

        // Transfers token_out to the user
        IERC20(token_out).safeTransfer(msg.sender, amount_out);

        // Checks that the router has a token_out balance of 0 after the operation
        if (IERC20(token_out).balanceOf(address(this)) != 0) revert Router__FundsStuck();

        // Emits ZapWithdraw event
        emit ZapWithdraw(msg.sender, shares, weth_redeemed, token_out, amount_out);
    }

    //* Internal functions

    /**
     * @notice Wraps ETH to WETH
     * @dev Calls WETH.deposit() with the ETH value to receive WETH tokens at 1:1
     *      We don't need to return anything because the WETH will be in the contract's balance
     * @param amount Amount of ETH to wrap
     */
    function _wrapETH(uint256 amount) internal {
        // Calls WETH.deposit() with the ETH value and checks that the wrap was successful
        (bool success,) = weth.call{value: amount}(abi.encodeWithSignature("deposit()"));
        if (!success) revert Router__ETHWrapFailed();
    }

    /**
     * @notice Unwraps WETH to native ETH
     * @dev Calls WETH.withdraw() to convert WETH to ETH at a 1:1 ratio
     *      Here we do need to return the amount to use it in the ERC20 swap
     * @param amount Amount of WETH to unwrap
     * @return eth_out Amount of ETH received
     */
    function _unwrapWETH(uint256 amount) internal returns (uint256 eth_out) {
        // Calls WETH.withdraw() with the WETH amount and checks that the unwrap was successful
        (bool success,) = weth.call(abi.encodeWithSignature("withdraw(uint256)", amount));
        if (!success) revert Router__ETHUnwrapFailed();

        // Returns the unwrapped amount
        eth_out = amount;
    }

    /**
     * @notice Swaps ERC20 to WETH via Uniswap V3
     * @dev Builds Uniswap V3 ISwapRouter.ExactInputSingleParams and executes the swap
     * @param token_in Token to swap
     * @param amount_in Amount to swap
     * @param pool_fee Fee tier of the Uniswap V3 pool to use
     * @param min_weth_out Minimum WETH to receive (slippage protection)
     * @return weth_out Actual WETH received
     */
    function _swapToWETH(address token_in, uint256 amount_in, uint24 pool_fee, uint256 min_weth_out)
        internal
        returns (uint256 weth_out)
    {
        // Approves the Uniswap router to transferFrom token_in
        IERC20(token_in).forceApprove(swap_router, amount_in);

        // Builds the swap parameters for Uniswap V3
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: token_in, // Token 1
            tokenOut: weth, // Token 2
            fee: pool_fee, // Fee
            recipient: address(this), // Recipient (this contract)
            deadline: block.timestamp, // Execute at most in this block
            amountIn: amount_in, // Amount of token 1 provided
            amountOutMinimum: min_weth_out, // Expected amount of token 2
            sqrtPriceLimitX96: 0 // No price limit
        });

        // Executes the swap and obtains the amount of WETH received
        weth_out = ISwapRouter(swap_router).exactInputSingle(params);

        // Checks that the received amount is greater than expected (slippage protection)
        if (weth_out < min_weth_out) revert Router__SlippageExceeded();
    }

    /**
     * @notice Swaps WETH to ERC20 token via Uniswap V3
     * @dev Builds Uniswap V3 ISwapRouter.ExactInputSingleParams and executes the swap
     * @param weth_in Amount of WETH to swap
     * @param token_out Token to receive from the swap
     * @param pool_fee Fee tier of the Uniswap V3 pool to use
     * @param min_token_out Minimum token_out to receive (slippage protection)
     * @return amount_out Actual amount of token_out received from the swap
     */
    function _swapFromWETH(uint256 weth_in, address token_out, uint24 pool_fee, uint256 min_token_out)
        internal
        returns (uint256 amount_out)
    {
        // Approves the Uniswap router to transferFrom WETH
        IERC20(weth).forceApprove(swap_router, weth_in);

        // Builds the swap parameters for Uniswap V3
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: weth, // Token 1
            tokenOut: token_out, // Token 2
            fee: pool_fee, // Fee
            recipient: address(this), // Recipient (this contract)
            deadline: block.timestamp, // Execute at most in this block
            amountIn: weth_in, // Amount of token 1 provided
            amountOutMinimum: min_token_out, // Expected amount of token 2
            sqrtPriceLimitX96: 0 // No price limit
        });

        // Executes the swap and obtains the amount of token_out received
        amount_out = ISwapRouter(swap_router).exactInputSingle(params);

        // Checks that the received amount is greater than expected (slippage protection)
        if (amount_out < min_token_out) revert Router__SlippageExceeded();
    }

    /**
     * @notice Fallback to receive ETH (necessary for WETH unwrap)
     * @dev Only accepts ETH from the WETH contract to avoid accidental ETH sends
     *      If ETH is received from another address the operation reverts
     */
    receive() external payable {
        if (msg.sender != weth) revert Router__UnauthorizedETHSender();
    }
}
