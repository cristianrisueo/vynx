// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/**
 * @title INonfungiblePositionManager
 * @author cristianrisueo
 * @notice Minimal interface for the Uniswap V3 NonfungiblePositionManager
 *
 * @dev We don't import the official v3-periphery interface because it depends on IERC721Metadata and
 *      IERC721Enumerable from OpenZeppelin v4 (in token/ERC721/), which in OZ v5 were moved to
 *      token/ERC721/extensions/. We only need the position management functions.
 *
 * @dev Signatures verified against the contract deployed on mainnet:
 *      https://etherscan.io/address/0xC36442b4a4522E871399CD717aBDD847Ab11FE88
 */
interface INonfungiblePositionManager {
    /**
     * @notice Parameters for creating a new LP position
     */
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    /**
     * @notice Parameters for increasing liquidity of an existing position
     */
    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    /**
     * @notice Parameters for decreasing liquidity of a position
     */
    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    /**
     * @notice Parameters for collecting pending tokens (fees + withdrawn liquidity)
     */
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    /**
     * @notice Creates a new LP position in the range [tickLower, tickUpper] and mints an NFT
     * @dev The NFT represents the position. The caller receives the tokenId as the position owner
     * @param params Position parameters (see MintParams)
     * @return tokenId ID of the minted NFT
     * @return liquidity Liquidity added to the pool
     * @return amount0 Token0 actually deposited
     * @return amount1 Token1 actually deposited
     */
    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    /**
     * @notice Increases liquidity of an existing position without changing the tick range
     * @param params Increase liquidity parameters (see IncreaseLiquidityParams)
     * @return liquidity Liquidity added
     * @return amount0 Token0 actually deposited
     * @return amount1 Token1 actually deposited
     */
    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);

    /**
     * @notice Decreases liquidity of a position, moving tokens to "owed" state
     * @dev Tokens are NOT automatically transferred: collect() must be called afterwards
     * @param params Decrease liquidity parameters (see DecreaseLiquidityParams)
     * @return amount0 Token0 moved to owed state
     * @return amount1 Token1 moved to owed state
     */
    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    /**
     * @notice Collects tokens in "owed" state from the position (fees + withdrawn liquidity)
     * @dev Combines accumulated fees and tokens from decreaseLiquidity in a single call
     * @param params Collection parameters (see CollectParams)
     * @return amount0 Token0 collected
     * @return amount1 Token1 collected
     */
    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);

    /**
     * @notice Burns the NFT of an empty position (liquidity == 0 and no tokens owed)
     * @dev Reverts if the position still has liquidity or pending tokens
     * @param tokenId ID of the NFT to burn
     */
    function burn(uint256 tokenId) external payable;

    /**
     * @notice Queries the complete data of a position by its tokenId
     * @param tokenId ID of the position NFT
     * @return nonce Nonce used for permissions
     * @return operator Approved operator for the position
     * @return token0 Token with the lower address of the pair
     * @return token1 Token with the higher address of the pair
     * @return fee Fee tier of the pool (e.g. 500 = 0.05%)
     * @return tickLower Lower tick of the range
     * @return tickUpper Upper tick of the range
     * @return liquidity Current active liquidity in the range
     * @return feeGrowthInside0LastX128 Fee accumulator for token0
     * @return feeGrowthInside1LastX128 Fee accumulator for token1
     * @return tokensOwed0 Token0 pending collection (fees + withdrawn liquidity)
     * @return tokensOwed1 Token1 pending collection (fees + withdrawn liquidity)
     */
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}
