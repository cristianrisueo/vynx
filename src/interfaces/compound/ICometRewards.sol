// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/**
 * @title ICometRewards
 * @notice Interface of the Compound v3 rewards contract
 * @dev In Compound's official library, cometMarket and cometRewards are two different contracts, so
 *      this cometRewards implementation has to be done in a separate interface
 */
interface ICometRewards {
    /**
     * @notice Structure representing a user's pending rewards
     * @param token Address of the reward token (generally COMP)
     * @param owed Amount of tokens pending to be claimed
     */
    struct RewardOwed {
        address token;
        uint256 owed;
    }

    /**
     * @notice Claims pending rewards
     * @param comet Address of the comet market contract
     * @param src Address of the user (in our case it will always be the same, the strategy)
     * @param shouldAccrue Whether it should accrue more before claiming (Compound's internal accounting)
     */
    function claim(address comet, address src, bool shouldAccrue) external;

    /**
     * @notice View pending rewards
     * @param comet Address of the comet market contract
     * @param account Address of the user (in our case it will always be the same, the strategy)
     * @return RewardOwed struct with the Compound token and the amount to receive
     */
    function getRewardOwed(address comet, address account) external view returns (RewardOwed memory);
}
