// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/**
 * @title IWstETH
 * @author cristianrisueo
 * @notice Interfaz del contrato wstETH (Wrapped Staked ETH) de Lido
 *
 * @dev stETH es un rebase token (balance crece automáticamente), lo que rompe la integración
 *      con algunos protocolos. wstETH es non-rebasing: balance fijo, exchange rate creciente
 *      Funciona igual, pero permite composibilidad. VynX usa wstETH para accounting simple y
 *      compatibilidad total con Aave, Curve y Uniswap V3
 *
 * @dev No importamos lidofinance/core porque:
 *      - 1. Mezcla Solidity 0.4/0.6/0.8 con dependencias legacy rotas
 *      - 2. Solo necesitamos 4 funciones
 *
 * @dev wstETH es también ERC20 (transfer, balanceOf, approve cubiertos por IERC20 de OpenZeppelin)
 *
 * @dev Signatures verificadas contra el contrato deployado en mainnet:
 *      https://etherscan.io/address/0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0
 */
interface IWstETH {
    /**
     * @notice Wrappea stETH a wstETH
     * @dev El caller debe haber aprobado previamente stETH al contrato wstETH
     * @param _stETH_amount Cantidad de stETH a wrappear
     * @return Cantidad de wstETH recibida
     */
    function wrap(uint256 _stETH_amount) external returns (uint256);

    /**
     * @notice Unwrappea wstETH a stETH
     * @param _wstETH_amount Cantidad de wstETH a unwrappear
     * @return Cantidad de stETH recibida
     */
    function unwrap(uint256 _wstETH_amount) external returns (uint256);

    /**
     * @notice Convierte una cantidad de stETH a su equivalente en wstETH
     * @dev Función view para cálculos off-chain y estimaciones
     * @param _stETH_amount Cantidad de stETH a convertir en wstETH
     * @return Cantidad equivalente de wstETH
     */
    function getWstETHByStETH(uint256 _stETH_amount) external view returns (uint256);

    /**
     * @notice Convierte una cantidad de wstETH a su equivalente en stETH
     * @dev Función view para cálculos off-chain y estimaciones
     * @param _wstETH_amount Cantidad de wstETH a convertir en stETH
     * @return Cantidad equivalente de stETH
     */
    function getStETHByWstETH(uint256 _wstETH_amount) external view returns (uint256);
}
