// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/**
 * @title ICometMarket
 * @author cristianrisueo
 * @notice Interfaz del Compound v3 Market (Comet)
 * @dev Funciones de lending: supply, withdraw, balanceOf
 * @dev Solo las funciones necesarias para CompoundStrategy. Por la forma en la que
 *      están diseñadas las librerías de compound son dos contratos diferentes:
 *      - ICometMarket: funciones de market (supply, withdraw, balanceOf)
 *      - ICometRewards: funciones de rewards (claim, getRewardOwed)
 * @dev A diferencia de Aave, no importamos las librerías oficiales porque:
 *      1. La importante: Las librerías oficiales están sucias/rotas (dependencias indexadas, etc)
 *      2. Solo necesitamos 5 funciones, no es necesario importar una librería entera
 */
interface ICometMarket {
    /**
     * @notice Deposita assets en Compound v3
     * @param asset Dirección del token a depositar
     * @param amount Cantidad a depositar
     */
    function supply(address asset, uint256 amount) external;

    /**
     * @notice Retira assets de Compound v3
     * @param asset Dirección del token a retirar
     * @param amount Cantidad a retirar
     */
    function withdraw(address asset, uint256 amount) external;

    /**
     * @notice Devuelve el balance de un usuario en Compound
     * @param account Dirección del usuario (en nuestro caso siempre será el mismo, la estrategia)
     * @return balance Balance del usuario (incluye yield)
     */
    function balanceOf(address account) external view returns (uint256 balance);

    /**
     * @notice Devuelve el supply rate actual del pool
     * @dev Supply rate es el interés que reciben los suppliers, calculado en base a utilization
     *      Cuanto más utilizado más reciben los suppliers porque -liquidez y +necesidad tiene el pool
     * @param utilization Utilización actual del pool
     * @return rate Supply rate (base 1e18)
     */
    function getSupplyRate(uint256 utilization) external view returns (uint64 rate);

    /**
     * @notice Devuelve la utilización actual del pool
     * @dev Utilization es el % del liquidez total que está siendo prestado (borrowed/disponible)
     * @return utilization Porcentaje de utilización (base 1e18)
     */
    function getUtilization() external view returns (uint256 utilization);
}
