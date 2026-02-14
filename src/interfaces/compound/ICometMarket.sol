// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/**
 * @title ICometMarket
 * @author cristianrisueo
 * @notice Interface of the Compound v3 Market (Comet)
 * @dev Lending functions: supply, withdraw, balanceOf
 * @dev Only the functions needed for CompoundStrategy. Because of the way
 *      Compound's libraries are designed, they are two different contracts:
 *      - ICometMarket: market functions (supply, withdraw, balanceOf)
 *      - ICometRewards: rewards functions (claim, getRewardOwed)
 * @dev Unlike Aave, we don't import the official libraries because:
 *      1. The important one: The official libraries are dirty/broken (indexed dependencies, etc)
 *      2. We only need 5 functions, there's no need to import an entire library
 */
interface ICometMarket {
    /**
     * @notice Deposits assets into Compound v3
     * @param asset Address of the token to deposit
     * @param amount Amount to deposit
     */
    function supply(address asset, uint256 amount) external;

    /**
     * @notice Withdraws assets from Compound v3
     * @param asset Address of the token to withdraw
     * @param amount Amount to withdraw
     */
    function withdraw(address asset, uint256 amount) external;

    /**
     * @notice Returns a user's balance in Compound
     * @param account Address of the user (in our case it will always be the same, the strategy)
     * @return balance User's balance (includes yield)
     */
    function balanceOf(address account) external view returns (uint256 balance);

    /**
     * @notice Returns the current supply rate of the pool
     * @dev Supply rate is the interest that suppliers receive, calculated based on utilization
     *      The more utilized, the more suppliers receive because -liquidity and +need the pool has
     * @param utilization Current utilization of the pool
     * @return supply_rate Supply rate (base 1e18)
     */
    function getSupplyRate(uint256 utilization) external view returns (uint64 supply_rate);

    /**
     * @notice Returns the current utilization of the pool
     * @dev Utilization is the % of total liquidity that is being lent (borrowed/available)
     * @return utilization Utilization percentage (base 1e18)
     */
    function getUtilization() external view returns (uint256 utilization);
}
