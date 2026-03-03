// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/**
 * @title IWstETH
 * @author cristianrisueo
 * @notice Interface for the Lido wstETH (Wrapped Staked ETH) contract
 *
 * @dev stETH is a rebase token (balance grows automatically), which breaks integration
 *      with some protocols. wstETH is non-rebasing: fixed balance, growing exchange rate.
 *      Works the same way, but enables composability. VynX uses wstETH for simple accounting and
 *      full compatibility with Aave, Curve and Uniswap V3
 *
 * @dev We don't import lidofinance/core because:
 *      - 1. It mixes Solidity 0.4/0.6/0.8 with broken legacy dependencies
 *      - 2. We only need 4 functions
 *
 * @dev wstETH is also ERC20 (transfer, balanceOf, approve covered by OpenZeppelin's IERC20)
 *
 * @dev Signatures verified against the contract deployed on mainnet:
 *      https://etherscan.io/address/0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0
 */
interface IWstETH {
    /**
     * @notice Wraps stETH to wstETH
     * @dev The caller must have previously approved stETH to the wstETH contract
     * @param _stETH_amount Amount of stETH to wrap
     * @return Amount of wstETH received
     */
    function wrap(uint256 _stETH_amount) external returns (uint256);

    /**
     * @notice Unwraps wstETH to stETH
     * @param _wstETH_amount Amount of wstETH to unwrap
     * @return Amount of stETH received
     */
    function unwrap(uint256 _wstETH_amount) external returns (uint256);

    /**
     * @notice Converts an amount of stETH to its wstETH equivalent
     * @dev View function for off-chain calculations and estimates
     * @param _stETH_amount Amount of stETH to convert to wstETH
     * @return Equivalent amount of wstETH
     */
    function getWstETHByStETH(uint256 _stETH_amount) external view returns (uint256);

    /**
     * @notice Converts an amount of wstETH to its stETH equivalent
     * @dev View function for off-chain calculations and estimates
     * @param _wstETH_amount Amount of wstETH to convert to stETH
     * @return Equivalent amount of stETH
     */
    function getStETHByWstETH(uint256 _wstETH_amount) external view returns (uint256);
}
