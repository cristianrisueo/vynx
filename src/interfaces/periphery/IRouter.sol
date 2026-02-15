// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/**
 * @title IRouter
 * @author cristianrisueo
 * @notice Interfaz del router del protocolo para depósitos multi-token
 * @dev El router actúa como contrato periférico que permite depositar cualquier token (ETH, USDC, DAI, etc.)
 *      en el Vault de VynX, realizando automáticamente el swap a WETH vía Uniswap V3
 * @dev Funcionalidades del Router:
 *      - Envolver ETH y depositar (ETH nativo → WETH → shares del Vault vía contrato WETH directo)
 *      - Swap de ERC20 y depositar (cualquier token → WETH → shares del Vault vía Uniswap V3)
 *      - Pool de Uniswap con fee variable calculado por el frontend para precios óptimos
 *      - Diseño stateless (el contrato que implemente esta interfaz nunca tendrá balance, solo mueve)
 * @dev Tomamos prestado el concepto de Zap (funciones que convierten y depositan en 1 tx) por si lo ves mucho
 */
interface IRouter {
    //* Eventos

    /**
     * @notice Se emite cuando un usuario deposita a través del router
     * @param user Dirección que recibe las shares del vault
     * @param token_in Token depositado por el usuario (address(0) si es ETH nativo)
     * @param amount_in Cantidad de token_in depositada
     * @param weth_out Cantidad de WETH obtenida tras el swap o wrap
     * @param shares_out Cantidad de shares del vault emitidas al usuario
     */
    event ZapDeposit(
        address indexed user, address indexed token_in, uint256 amount_in, uint256 weth_out, uint256 shares_out
    );

    /**
     * @notice Emitido cuando un usuario retira vía el router
     * @param user Dirección que quema shares y recibe tokens
     * @param shares_in Cantidad de shares quemadas del vault
     * @param weth_redeemed Cantidad de WETH redimido del vault
     * @param token_out Token recibido por el usuario (address(0) si es ETH nativo)
     * @param amount_out Cantidad de token_out recibida por el usuario
     */
    event ZapWithdraw(
        address indexed user, uint256 shares_in, uint256 weth_redeemed, address indexed token_out, uint256 amount_out
    );

    //* Funciones de consulta - Representación de las variables de estado de la interfaz

    /**
     * @notice Dirección del token WETH
     * @dev Dirección inmutable establecida en el constructor
     * @return weth_address Dirección del contrato del token WETH
     */
    function weth() external view returns (address weth_address);

    /**
     * @notice Dirección del Vault de VynX
     * @dev Dirección inmutable establecida en el constructor. El Router deposita WETH en este vault
     * @return vault_address Dirección del Vault de VynX (compatible con ERC4626)
     */
    function vault() external view returns (address vault_address);

    /**
     * @notice Dirección del SwapRouter de Uniswap V3
     * @dev Dirección inmutable establecida en el constructor. El Router ejecuta swaps a través de este contrato
     * @return swap_router_address Dirección del SwapRouter de Uniswap V3
     */
    function swap_router() external view returns (address swap_router_address);

    //* Funciones principales - Depósitos y retiros de ETH y ERC20

    /**
     * @notice Deposita ETH nativo en el vault
     * @dev Envuelve ETH a WETH, deposita en el Vault y emite shares directamente a msg.sender
     * @dev Flujo: ETH (usuario) → WETH (wrap) → Vault (depósito) → Shares (usuario)
     * @dev Esta función es payable y recibe ETH mediante msg.value
     * @return shares Cantidad de shares del vault recibidas por el usuario
     */
    function zapDepositETH() external payable returns (uint256 shares);

    /**
     * @notice Deposita token ERC20 en el vault (hace swap a WETH primero vía Uniswap V3)
     * @dev Flow: ERC20 (usuario) → Router (transfer) → WETH (swap) → Vault (deposit) → Shares (usuario)
     * @dev Requiere aprobación previa de token_in al contrato Router
     * @dev El frontend debe calcular el pool óptimo consultando quoters de Uniswap
     * @param token_in Token a depositar (debe tener pool de Uniswap V3 con WETH)
     * @param amount_in Cantidad de token_in a depositar
     * @param pool_fee Fee tier del pool de Uniswap V3 a usar (100, 500, 3000, o 10000)
     * @param min_weth_out WETH mínimo a recibir del swap (protección de slippage)
     * @return shares Cantidad de shares del vault recibidas por el usuario
     */
    function zapDepositERC20(address token_in, uint256 amount_in, uint24 pool_fee, uint256 min_weth_out)
        external
        returns (uint256 shares);

    /**
     * @notice Retira shares del vault y recibe ETH nativo
     * @dev Redime shares del Vault por WETH, unwrappea WETH a ETH, envía ETH al usuario
     * @dev Flow: Shares (usuario) → Vault (redeem) → WETH (Router) → ETH (unwrap) → ETH (usuario)
     * @dev Requiere aprobación previa de shares del Vault al Router
     * @param shares Cantidad de shares a quemar del vault
     * @return eth_out Cantidad de ETH recibida por el usuario
     */
    function zapWithdrawETH(uint256 shares) external returns (uint256 eth_out);

    /**
     * @notice Retira shares del vault y recibe token ERC20 (hace swap desde WETH vía Uniswap V3)
     * @dev Redime shares por WETH, hace swap WETH → token_out usando el pool especificado
     * @dev Flow: Shares (usuario) → Vault (redeem) → WETH (Router) → token_out (swap) → token_out (usuario)
     * @dev Requiere aprobación previa de shares del Vault al Router
     * @dev El frontend debe calcular el pool óptimo consultando quoters de Uniswap
     * @param shares Cantidad de shares a quemar del vault
     * @param token_out Token a recibir (debe tener pool de Uniswap V3 con WETH)
     * @param pool_fee Fee tier del pool de Uniswap V3 a usar (100, 500, 3000, o 10000)
     * @param min_token_out Mínimo token_out a recibir del swap (protección de slippage)
     * @return amount_out Cantidad de token_out recibida por el usuario
     */
    function zapWithdrawERC20(uint256 shares, address token_out, uint24 pool_fee, uint256 min_token_out)
        external
        returns (uint256 amount_out);
}
