// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/**
 * @title ILido
 * @author cristianrisueo
 * @notice Interfaz mínima para stakear ETH en Lido y recibir stETH
 * 
 * @dev No importamos la librería oficial de Lido porque mezcla Solidity 0.4/0.6/0.8
 *      con dependencias legacy rotas. Solo necesitamos 2 funciones
 * 
 * @dev Signature verificada contra el contrato stETH deployado en mainnet:
 *      https://etherscan.io/address/0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84
 */
interface ILido {
    /**
     * @notice Stakea ETH en Lido y recibe stETH a cambio
     * @dev El ETH a stakear se pasa como msg.value, no como parámetro
     * @param _referral Dirección de referido (puede ser address(0) si no hay)
     * @return Cantidad de stETH recibida (shares de Lido)
     */
    function submit(address _referral) external payable returns (uint256);

    /**
     * @notice Devuelve el balance de stETH de una dirección
     * @param _account Dirección a consultar
     * @return Balance de stETH (en wei, rebasing token)
     */
    function balanceOf(address _account) external view returns (uint256);
}
