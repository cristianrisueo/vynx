// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/**
 * @title IRouter
 * @author cristianrisueo
 * @notice Router interface for multi-token deposits into the protocol
 * @dev The router acts as a peripheral contract that allows depositing any token (ETH, USDC, DAI, etc.)
 *      into the VynX Vault, automatically swapping to WETH via Uniswap V3
 * @dev Router features:
 *      - Wrap ETH and deposit (native ETH → WETH → Vault shares via direct WETH contract)
 *      - Swap ERC20 and deposit (any token → WETH → Vault shares via Uniswap V3)
 *      - Uniswap pool with variable fee calculated by frontend for optimal prices
 *      - Stateless design (the contract implementing this interface will never hold a balance, it only moves funds)
 * @dev We borrow the Zap concept (functions that convert and deposit in 1 tx) in case you see it a lot
 */
interface IRouter {
    //* Events

    /**
     * @notice Emitted when a user deposits through the router
     * @param user Address that receives the vault shares
     * @param token_in Token deposited by the user (address(0) if native ETH)
     * @param amount_in Amount of token_in deposited
     * @param weth_out Amount of WETH obtained after the swap or wrap
     * @param shares_out Amount of vault shares issued to the user
     */
    event ZapDeposit(
        address indexed user, address indexed token_in, uint256 amount_in, uint256 weth_out, uint256 shares_out
    );

    /**
     * @notice Emitted when a user withdraws via the router
     * @param user Address that burns shares and receives tokens
     * @param shares_in Amount of vault shares burned
     * @param weth_redeemed Amount of WETH redeemed from the vault
     * @param token_out Token received by the user (address(0) if native ETH)
     * @param amount_out Amount of token_out received by the user
     */
    event ZapWithdraw(
        address indexed user, uint256 shares_in, uint256 weth_redeemed, address indexed token_out, uint256 amount_out
    );

    //* Query functions - Representation of the interface state variables

    /**
     * @notice Address of the WETH token
     * @dev Immutable address set in the constructor
     * @return weth_address Address of the WETH token contract
     */
    function weth() external view returns (address weth_address);

    /**
     * @notice Address of the VynX Vault
     * @dev Immutable address set in the constructor. The Router deposits WETH into this vault
     * @return vault_address Address of the VynX Vault (ERC4626 compatible)
     */
    function vault() external view returns (address vault_address);

    /**
     * @notice Address of the Uniswap V3 SwapRouter
     * @dev Immutable address set in the constructor. The Router executes swaps through this contract
     * @return swap_router_address Address of the Uniswap V3 SwapRouter
     */
    function swap_router() external view returns (address swap_router_address);

    //* Main functions - ETH and ERC20 deposits and withdrawals

    /**
     * @notice Deposits native ETH into the vault
     * @dev Wraps ETH to WETH, deposits into the Vault and emits shares directly to msg.sender
     * @dev Flow: ETH (user) → WETH (wrap) → Vault (deposit) → Shares (user)
     * @dev This function is payable and receives ETH via msg.value
     * @return shares Amount of vault shares received by the user
     */
    function zapDepositETH() external payable returns (uint256 shares);

    /**
     * @notice Deposits ERC20 token into the vault (swaps to WETH first via Uniswap V3)
     * @dev Flow: ERC20 (user) → Router (transfer) → WETH (swap) → Vault (deposit) → Shares (user)
     * @dev Requires prior approval of token_in to the Router contract
     * @dev Frontend should calculate the optimal pool by querying Uniswap quoters
     * @param token_in Token to deposit (must have a Uniswap V3 pool with WETH)
     * @param amount_in Amount of token_in to deposit
     * @param pool_fee Fee tier of the Uniswap V3 pool to use (100, 500, 3000, or 10000)
     * @param min_weth_out Minimum WETH to receive from the swap (slippage protection)
     * @return shares Amount of vault shares received by the user
     */
    function zapDepositERC20(address token_in, uint256 amount_in, uint24 pool_fee, uint256 min_weth_out)
        external
        returns (uint256 shares);

    /**
     * @notice Withdraws shares from the vault and receives native ETH
     * @dev Redeems shares from the Vault for WETH, unwraps WETH to ETH, sends ETH to user
     * @dev Flow: Shares (user) → Vault (redeem) → WETH (Router) → ETH (unwrap) → ETH (user)
     * @dev Requires prior approval of Vault shares to the Router
     * @param shares Amount of shares to burn from the vault
     * @return eth_out Amount of ETH received by the user
     */
    function zapWithdrawETH(uint256 shares) external returns (uint256 eth_out);

    /**
     * @notice Withdraws shares from the vault and receives an ERC20 token (swaps from WETH via Uniswap V3)
     * @dev Redeems shares for WETH, swaps WETH → token_out using the specified pool
     * @dev Flow: Shares (user) → Vault (redeem) → WETH (Router) → token_out (swap) → token_out (user)
     * @dev Requires prior approval of Vault shares to the Router
     * @dev Frontend should calculate the optimal pool by querying Uniswap quoters
     * @param shares Amount of shares to burn from the vault
     * @param token_out Token to receive (must have a Uniswap V3 pool with WETH)
     * @param pool_fee Fee tier of the Uniswap V3 pool to use (100, 500, 3000, or 10000)
     * @param min_token_out Minimum token_out to receive from the swap (slippage protection)
     * @return amount_out Amount of token_out received by the user
     */
    function zapWithdrawERC20(uint256 shares, address token_out, uint24 pool_fee, uint256 min_token_out)
        external
        returns (uint256 amount_out);
}
