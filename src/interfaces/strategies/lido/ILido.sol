// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/**
 * @title ILido
 * @author cristianrisueo
 * @notice Minimal interface for staking ETH in Lido and receiving stETH
 *
 * @dev We don't import the official Lido library because it mixes Solidity 0.4/0.6/0.8
 *      with broken legacy dependencies. We only need 2 functions
 *
 * @dev Signature verified against the stETH contract deployed on mainnet:
 *      https://etherscan.io/address/0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84
 */
interface ILido {
    /**
     * @notice Stakes ETH in Lido and receives stETH in return
     * @dev The ETH to stake is passed as msg.value, not as a parameter
     * @param _referral Referral address (can be address(0) if none)
     * @return Amount of stETH received (Lido shares)
     */
    function submit(address _referral) external payable returns (uint256);

    /**
     * @notice Returns the stETH balance of an address
     * @param _account Address to query
     * @return stETH balance (in wei, rebasing token)
     */
    function balanceOf(address _account) external view returns (uint256);
}
