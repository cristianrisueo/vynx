// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/**
 * @title ICurvePool
 * @author cristianrisueo
 * @notice Interface for the Curve stETH/ETH liquidity pool
 *
 * @dev The real Curve contracts are written in Vyper.
 *      This Solidity interface is derived from the ABI of the deployed contract.
 *      It only contains the functions needed for CurveStrategy.
 *
 * @dev Signatures verified against the mainnet contract:
 *      https://etherscan.io/address/0xDC24316b9AE028F1497c275EB9192a3Ea0f67022
 */
interface ICurvePool {
    /**
     * @notice Adds liquidity to the pool and receives LP tokens
     * @dev The stETH/ETH pool has 2 tokens: index 0 = ETH, index 1 = stETH.
     *      To deposit ETH, send msg.value and set _amounts[0] = msg.value
     * @param _amounts Array of amounts to deposit [ETH, stETH]
     * @param _min_mint_amount Minimum LP tokens to receive (slippage protection)
     * @return Amount of LP tokens minted
     */
    function add_liquidity(uint256[2] calldata _amounts, uint256 _min_mint_amount) external payable returns (uint256);

    /**
     * @notice Withdraws liquidity in a single token by burning LP tokens
     * @dev Allows withdrawing the entire position in a single pool token
     * @param _token_amount Amount of LP tokens to burn
     * @param _i Index of the token to receive (0 = ETH, 1 = stETH)
     * @param _min_amount Minimum amount to receive (slippage protection)
     * @return Amount of the selected token received
     */
    function remove_liquidity_one_coin(uint256 _token_amount, int128 _i, uint256 _min_amount) external returns (uint256);

    /**
     * @notice Returns the virtual price of the LP token (initial contribution + generated fees)
     * @dev The virtual price is always increasing and reflects the accumulated value of the pool. It is
     *      useful for calculating the value of LP tokens without needing to simulate a withdraw.
     *      Normalized to 1e18 (fucking perfect, no custom units)
     * @return Virtual price of the LP token (base 1e18)
     */
    function get_virtual_price() external view returns (uint256);

    /**
     * @notice Calculates how much you would receive by burning LP tokens for a single token
     * @dev View function — does not execute, only simulates
     * @param _token_amount Amount of LP tokens to burn
     * @param _i Index of the token to receive (0 = ETH, 1 = stETH)
     * @return Amount of the token you would receive
     */
    function calc_withdraw_one_coin(uint256 _token_amount, int128 _i) external view returns (uint256);

    /**
     * @notice Returns the address of the token at the given index
     * @dev In the stETH/ETH pool: coins(0) = ETH, coins(1) = stETH
     * @param _i Token index (0 or 1)
     * @return Token address
     */
    function coins(uint256 _i) external view returns (address);

    /**
     * @notice Swaps stETH for ETH (or vice versa) within the pool
     * @dev The function is payable because it also supports ETH as input token (i=0).
     *      For stETH → ETH: i=1, j=0, ETH is sent to the caller.
     *      For ETH → stETH: i=0, j=1, ETH is sent as msg.value.
     * @param i Input token index (0=ETH, 1=stETH)
     * @param j Output token index (0=ETH, 1=stETH)
     * @param dx Amount of input token
     * @param min_dy Minimum amount of output token (slippage protection)
     * @return Amount of output token received
     */
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external payable returns (uint256);
}
