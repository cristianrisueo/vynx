// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/**
 * @title IStrategy
 * @author cristianrisueo
 * @notice Interfaz estándar que todas las estrategoas deben implementar
 * @dev Permite que StrategyManager trate estrategias de distintos protocolos:
 *      Aave, Compound, etc... De manera uniforme
 */
interface IStrategy {
    //* Eventos

    /**
     * @notice Emitido cuando se depositan assets en la estrategia
     * @param caller Direccion que ejecuto el deposit (debería ser strategy manager)
     * @param assets Cantidad de asset depositados
     * @param shares Shares recibidos del protocolo dónde se deposita (xToken correspondiente)
     */
    event Deposited(address indexed caller, uint256 assets, uint256 shares);

    /**
     * @notice Emitido cuando se retiran assets de la estrategia
     * @param caller Direccion que ejecuto el withdraw (debería ser strategy manager)
     * @param assets Cantidad de assets retirados
     * @param shares Shares quemados por el protocolo (xToken redimidos por asset)
     */
    event Withdrawn(address indexed caller, uint256 assets, uint256 shares);

    /**
     * @notice Emitido cuando se recolectan y reinvierten los rewards de la estrategia
     * @param caller Direccion que ejecuto el harvest (debería ser strategy manager)
     * @param profit Profit generado en asset después de claim y swap de rewards (los xTokens)
     */
    event Harvested(address indexed caller, uint256 profit);

    //* Funciones principales

    /**
     * @notice Deposita assets en el protocolo subyacente
     * @dev El caller debe transferir assets a esta strategy antes de llamar. En un flujo normal
     *      stragey manager transfiere los assets a depositar a la estrategia correspondiente
     * @param assets Cantidad de assets a depositar
     * @return shares Shares recibidos (los xTokens representando el depósito en el protocolo X)
     */
    function deposit(uint256 assets) external returns (uint256 shares);

    /**
     * @notice Retira assets del protocolo subyacente
     * @dev Transfiere assets al caller después de retirar, es el flujo contrario a deposit:
     *      Los assets ya convertidos pasan de estrategia correspondiente a strategy manager
     * @param assets Cantidad de assets a retirar
     * @return actualWithdrawn assets realmente retirados (cantidad a retirar + yield generado)
     */
    function withdraw(uint256 assets) external returns (uint256 actualWithdrawn);

    /**
     * @notice Cosecha las rewards del protocolo subyacente. Se hace continuamente para maximizar APY
     * @dev Reclama rewards → Swap a asset → Re-invierte en el protocolo → Aumenta el APY todavía mas
     * @dev Recuerdo que los rewards vendrán en xToken, son una recomensa extra que da el protocolo
     *      subyacente por usarlo. Al buscar APY máximo, se swapea y reinverte de nuevo dicha recomensa
     * @return profit Profit en assets generado por rewards
     */
    function harvest() external returns (uint256 profit);

    //* Funciones de consulta

    /**
     * @notice Devuelve el valor total de assets bajo gestión
     * @dev Incluye assets depositado + yield acumulado
     * @dev Como el asset estará depositado en el protocolo X, se calculará
     *      usando los shares (xToken) recibidos del protocolo subyacente
     * @return total Valor total en assets (seguramente en wei)
     */
    function totalAssets() external view returns (uint256 total);

    /**
     * @notice Devuelve el APY actual del protocolo subyacente
     * @dev En basis points: 100 = 1%, 350 = 3.5%, 1000 = 10%
     * @return apyBasisPoints APY en basis points
     */
    function apy() external view returns (uint256 apyBasisPoints);

    /**
     * @notice Devuelve el nombre de la estrategia
     * @return strategyName Ej: "Aave v3 assets Strategy"
     */
    function name() external view returns (string memory strategyName);

    /**
     * @notice Devuelve la dirección del asset que maneja
     * @return assetAddress Dirección del token usado como underlying asset
     */
    function asset() external view returns (address assetAddress);
}
