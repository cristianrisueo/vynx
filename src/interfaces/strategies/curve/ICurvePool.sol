// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/**
 * @title ICurvePool
 * @author cristianrisueo
 * @notice Interfaz del pool de liquidez stETH/ETH de Curve
 *
 * @dev Los contratos reales de Curve están escritos en Vyper
 *      Esta interfaz Solidity está derivada del ABI del contrato deployado
 *      Solo contiene las funciones necesarias para CurveStrategy
 *
 * @dev Signatures verificadas contra el contrato de mainnet:
 *      https://etherscan.io/address/0xDC24316b9AE028F1497c275EB9192a3Ea0f67022
 */
interface ICurvePool {
    /**
     * @notice Añade liquidez al pool y recibe LP tokens
     * @dev El pool stETH/ETH tiene 2 tokens: index 0 = ETH, index 1 = stETH
     *      Para depositar ETH se envía msg.value y _amounts[0] = msg.value
     * @param _amounts Array de cantidades a depositar [ETH, stETH]
     * @param _min_mint_amount Cantidad mínima de LP tokens a recibir (slippage protection)
     * @return Cantidad de LP tokens minteados
     */
    function add_liquidity(uint256[2] calldata _amounts, uint256 _min_mint_amount) external payable returns (uint256);

    /**
     * @notice Retira liquidez en un solo token quemando LP tokens
     * @dev Permite retirar toda la posición en un solo token del pool
     * @param _token_amount Cantidad de LP tokens a quemar
     * @param _i Índice del token a recibir (0 = ETH, 1 = stETH)
     * @param _min_amount Cantidad mínima a recibir (slippage protection)
     * @return Cantidad del token seleccionado recibida
     */
    function remove_liquidity_one_coin(uint256 _token_amount, int128 _i, uint256 _min_amount) external returns (uint256);

    /**
     * @notice Devuelve el precio virtual del LP token (Aportación inicial + fees generadas)
     * @dev El virtual price es siempre creciente y refleja el valor acumulado del pool. Es
     *      útil para calcular el valor de los LP tokens sin necesidad de simular un withdraw
     *      Normalizado a 1e18 (de puta madre, sin unidades de medida propias)
     * @return Precio virtual del LP token (base 1e18)
     */
    function get_virtual_price() external view returns (uint256);

    /**
     * @notice Calcula cuánto recibirías al quemar LP tokens por un solo token
     * @dev View function - no ejecuta, solo simula
     * @param _token_amount Cantidad de LP tokens a quemar
     * @param _i Índice del token a recibir (0 = ETH, 1 = stETH)
     * @return Cantidad del token que recibirías
     */
    function calc_withdraw_one_coin(uint256 _token_amount, int128 _i) external view returns (uint256);

    /**
     * @notice Devuelve la dirección del token en el índice dado
     * @dev En el pool stETH/ETH: coins(0) = ETH, coins(1) = stETH
     * @param _i Índice del token (0 o 1)
     * @return Dirección del token
     */
    function coins(uint256 _i) external view returns (address);

    /**
     * @notice Intercambia stETH por ETH (o viceversa) dentro del pool
     * @dev La función es payable porque también soporta ETH como token de entrada (i=0)
     *      Para stETH → ETH: i=1, j=0, El ETH se envía al caller
     *      Para ETH → stETH: i=0, j=1, Se envía ETH en el msg.value
     * @param i Índice del token de entrada (0=ETH, 1=stETH)
     * @param j Índice del token de salida (0=ETH, 1=stETH)
     * @param dx Cantidad del token de entrada
     * @param min_dy Cantidad mínima del token de salida (slippage protection)
     * @return Cantidad del token de salida recibida
     */
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external payable returns (uint256);
}
