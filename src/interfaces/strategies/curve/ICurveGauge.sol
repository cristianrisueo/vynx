// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/**
 * @title ICurveGauge
 * @author cristianrisueo
 * @notice Interface for the Curve stETH/ETH pool staking contract
 *
 * @dev Gauge is the name Curve gives to its staking contract —
 *      it allows staking pool LP tokens to receive rewards (CRV, LDO... there are 8).
 *      These fucking primitives always giving things nerdy names, CurveStake fuck's sake.
 *
 * @dev The real Curve contracts are written in Vyper.
 *      This Solidity interface is derived from the ABI of the deployed contract.
 *      It only contains the functions needed for CurveStrategy.
 *
 * @dev Signatures verified against the mainnet contract:
 *      https://etherscan.io/address/0x182B723a58739a9c974cFDB385ceaDb237453c28
 */
interface ICurveGauge {
    /**
     * @notice Deposits LP tokens into the gauge
     * @dev The caller must have previously approved LP tokens to the gauge
     * @param _value Amount of LP tokens to stake
     */
    function deposit(uint256 _value) external;

    /**
     * @notice Redeems LP tokens from the gauge
     * @param _value Amount of LP tokens to withdraw
     */
    function withdraw(uint256 _value) external;

    /**
     * @notice Claims accumulated rewards (CRV, LDO, etc.)
     * @dev In the stETH gauge, claim_rewards allows claiming rewards from
     *      any address, not just one's own (enables keeper bot economies)
     * @param _addr Address for which to claim rewards
     */
    function claim_rewards(address _addr) external;

    /**
     * @notice Returns the balance of staked LP tokens for an address
     * @param _addr Address to query
     * @return Balance of staked LP tokens
     */
    function balanceOf(address _addr) external view returns (uint256);

    /**
     * @notice Returns the address of the reward token at the given index
     * @dev The gauge supports up to 8 reward tokens (MAX_REWARDS = 8).
     *      Normally: index 0 = CRV, index 1 = LDO, the rest I have no idea
     * @param _index Index of the reward token
     * @return Address of the reward token (address(0) if no more)
     */
    function reward_tokens(uint256 _index) external view returns (address);
}
