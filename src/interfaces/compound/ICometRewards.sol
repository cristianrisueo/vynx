// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/**
 * @title ICometRewards
 * @notice Interfaz del contrato de rewards de Compound v3
 * @dev En la librería oficial de cometMarket y cometRewards son dos contratos diferentes, por
 *      lo que esta implementación de cometRewards se tiene que hacer en una interfaz separada
 */
interface ICometRewards {
    /**
     * @notice Estructura que representa los rewards pendientes de un usuario
     * @param token Dirección del token de reward (generalmente COMP)
     * @param owed Cantidad de tokens pendientes de reclamar
     */
    struct RewardOwed {
        address token;
        uint256 owed;
    }

    /**
     * @notice Reclama los rewards pendientes
     * @param comet Dirección del contrato comet market
     * @param src Dirección del usuario (en nuestro caso siempre será el mismo, la estrategia)
     * @param shouldAccrue Si debe acumular más antes antes de claim (accounting interno de compound)
     */
    function claim(address comet, address src, bool shouldAccrue) external;

    /**
     * @notice Ver rewards pendientes
     * @param comet Dirección del contrato comet market
     * @param account Dirección del usuario (en nuestro caso siempre será el mismo, la estrategia)
     * @return RewardOwed struct con el token de compound y la cantidad a recibir
     */
    function getRewardOwed(address comet, address account) external view returns (RewardOwed memory);
}
