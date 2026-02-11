// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title IVault
 * @author cristianrisueo
 * @notice Interfaz del vault del protocolo
 * @dev El vault actúa como punto de entrada para usuarios y delega la gestión de capital al strategy manager
 * @dev Extiende el estándar ERC4626 (Tokenized Vaults) con funcionalidades específicas para la
 *      gestión activa de yield:
 *      - Idle buffer management (buffer de liquidez sin asignar)
 *      - Harvest automático de rewards de todas las estrategias y distribución de performance fees
 *        entre treasury y founder
 */
interface IVault is IERC4626 {
    //* Eventos

    /**
     * @notice Emitido cuando un usuario deposita assets en el vault
     * @param user Dirección del usuario que realiza el depósito
     * @param assets Cantidad de assets depositados
     * @param shares Cantidad de shares (tokens del vault) recibidos por el usuario
     */
    event Deposited(address indexed user, uint256 assets, uint256 shares);

    /**
     * @notice Emitido cuando un usuario retira assets del vault
     * @param user Dirección del usuario que realiza el retiro
     * @param assets Cantidad de assets retirados
     * @param shares Cantidad de shares (tokens del vault) quemados
     */
    event Withdrawn(address indexed user, uint256 assets, uint256 shares);

    /**
     * @notice Emitido cuando se ejecuta harvest en el vault recolectando profits de estrategias
     * @param profit Profit total generado en assets antes de deducir performance fees
     * @param performanceFee Cantidad de performance fee cobrada sobre el profit
     * @param timestamp Timestamp del momento en que se ejecutó el harvest
     */
    event Harvested(uint256 profit, uint256 performanceFee, uint256 timestamp);

    /**
     * @notice Emitido cuando se distribuyen las performance fees entre treasury y founder
     * @param treasuryAmount Cantidad de assets enviados a la dirección treasury
     * @param founderAmount Cantidad de assets enviados a la dirección founder
     */
    event PerformanceFeeDistributed(uint256 treasuryAmount, uint256 founderAmount);

    /**
     * @notice Emitido cuando se asignan assets idle a las estrategias mediante el strategy manager
     * @param amount Cantidad de assets idle que fueron asignados a estrategias
     */
    event IdleAllocated(uint256 amount);

    /**
     * @notice Emitido cuando se actualiza la dirección del strategy manager
     * @param newManager Nueva dirección del strategy manager que gestionará las estrategias
     */
    event StrategyManagerUpdated(address indexed newManager);

    /**
     * @notice Emitido cuando se actualiza el performance fee
     * @param oldFee Performance fee anterior en basis points
     * @param newFee Nuevo performance fee en basis points
     */
    event PerformanceFeeUpdated(uint256 oldFee, uint256 newFee);

    /**
     * @notice Emitido cuando se actualiza el split de fees entre treasury y founder
     * @param treasurySplit Nuevo porcentaje para treasury en basis points
     * @param founderSplit Nuevo porcentaje para founder en basis points
     */
    event FeeSplitUpdated(uint256 treasurySplit, uint256 founderSplit);

    /**
     * @notice Emitido cuando se actualiza el depósito mínimo
     * @param oldMin Depósito mínimo anterior
     * @param newMin Nuevo depósito mínimo
     */
    event MinDepositUpdated(uint256 oldMin, uint256 newMin);

    /**
     * @notice Emitido cuando se actualiza el idle threshold
     * @param oldThreshold Threshold anterior
     * @param newThreshold Nuevo threshold
     */
    event IdleThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);

    /**
     * @notice Emitido cuando se actualiza el TVL máximo
     * @param oldMax TVL máximo anterior
     * @param newMax Nuevo TVL máximo
     */
    event MaxTVLUpdated(uint256 oldMax, uint256 newMax);

    /**
     * @notice Emitido cuando se actualiza la dirección del treasury
     * @param oldTreasury Dirección anterior del treasury
     * @param newTreasury Nueva dirección del treasury
     */
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    /**
     * @notice Emitido cuando se actualiza la dirección del founder
     * @param oldFounder Dirección anterior del founder
     * @param newFounder Nueva dirección del founder
     */
    event FounderUpdated(address indexed oldFounder, address indexed newFounder);

    /**
     * @notice Emitido cuando se añade o remueve un keeper oficial
     * @param keeper Dirección del keeper
     * @param status True si se añade, false si se remueve
     */
    event OfficialKeeperUpdated(address indexed keeper, bool status);

    /**
     * @notice Emitido cuando se actualiza el profit mínimo para harvest
     * @param oldMin Profit mínimo anterior
     * @param newMin Nuevo profit mínimo
     */
    event MinProfitForHarvestUpdated(uint256 oldMin, uint256 newMin);

    /**
     * @notice Emitido cuando se actualiza el incentivo para keepers externos
     * @param oldIncentive Incentivo anterior en basis points
     * @param newIncentive Nuevo incentivo en basis points
     */
    event KeeperIncentiveUpdated(uint256 oldIncentive, uint256 newIncentive);

    //* Funciones principales

    /**
     * @notice Cosecha rewards de todas las estrategias activas y distribuye performance fees
     * @dev Llama a strategyManager.harvest() para recolectar profits de todas las estrategias,
     *      calcula la performance fee sobre el profit total, distribuye las fees entre treasury
     *      y founder según los splits configurados, y actualiza el lastHarvest timestamp
     * @dev Función pública sin restricciones: cualquier dirección puede ejecutar harvest para
     *      beneficio del protocolo (incentivando la ejecución frecuente mediante keeper bots)
     * @return profit Profit total cosechado en assets antes de deducir performance fees
     */
    function harvest() external returns (uint256 profit);

    /**
     * @notice Asigna assets idle buffer del vault a las estrategias mediante el strategy manager
     * @dev Solo ejecuta si idleBuffer >= idleThreshold, evitando gas innecesario en allocations
     *      pequeñas. Los assets idle se acumulan principalmente por nuevos deposits de usuarios
     *      que aún no han sido asignados a estrategias productivas
     * @dev Función pública sin restricciones: cualquier dirección puede llamarla cuando se alcance
     *      el threshold, incentivando la asignación eficiente de capital ocioso
     */
    function allocateIdle() external;

    //* Funciones administrativas - Setters de parámetros del protocolo

    /**
     * @notice Actualiza el performance fee cobrado sobre profits
     * @dev Solo puede ser llamada por el owner del vault
     * @param newFee Nuevo performance fee en basis points (debe ser <= BASIS_POINTS)
     */
    function setPerformanceFee(uint256 newFee) external;

    /**
     * @notice Actualiza el split de performance fees entre treasury y founder
     * @dev Solo puede ser llamada por el owner del vault
     * @param newTreasury Nuevo porcentaje para treasury en basis points
     * @param newFounder Nuevo porcentaje para founder en basis points
     * @dev La suma de ambos debe ser exactamente BASIS_POINTS (10000)
     */
    function setFeeSplit(uint256 newTreasury, uint256 newFounder) external;

    /**
     * @notice Actualiza el depósito mínimo permitido
     * @dev Solo puede ser llamada por el owner del vault
     * @param newMin Nuevo depósito mínimo en assets
     */
    function setMinDeposit(uint256 newMin) external;

    /**
     * @notice Actualiza el threshold de assets idle para ejecutar allocation
     * @dev Solo puede ser llamada por el owner del vault
     * @param newThreshold Nuevo threshold en assets
     */
    function setIdleThreshold(uint256 newThreshold) external;

    /**
     * @notice Actualiza el TVL máximo permitido en el vault
     * @dev Solo puede ser llamada por el owner del vault
     * @param newMax Nuevo TVL máximo en assets
     */
    function setMaxTVL(uint256 newMax) external;

    /**
     * @notice Actualiza la dirección del treasury
     * @dev Solo puede ser llamada por el owner del vault
     * @param newTreasury Nueva dirección del treasury (no puede ser address(0))
     */
    function setTreasury(address newTreasury) external;

    /**
     * @notice Actualiza la dirección del founder
     * @dev Solo puede ser llamada por el owner del vault
     * @param newFounder Nueva dirección del founder (no puede ser address(0))
     */
    function setFounder(address newFounder) external;

    /**
     * @notice Actualiza la dirección del strategy manager
     * @dev Solo puede ser llamada por el owner del vault
     * @param newManager Nueva dirección del strategy manager (no puede ser address(0))
     */
    function setStrategyManager(address newManager) external;

    /**
     * @notice Actualiza el profit mínimo requerido para ejecutar harvest
     * @dev Solo puede ser llamada por el owner del vault
     * @param newMin Nuevo profit mínimo en assets
     */
    function setMinProfitForHarvest(uint256 newMin) external;

    /**
     * @notice Actualiza el incentivo para keepers externos que ejecuten harvest
     * @dev Solo puede ser llamada por el owner del vault
     * @param newIncentive Nuevo incentivo en basis points (debe ser <= BASIS_POINTS)
     */
    function setKeeperIncentive(uint256 newIncentive) external;

    //* Funciones de consulta - Getters de parámetros y treaury del protocolo

    /**
     * @notice Devuelve el porcentaje de performance fee cobrado sobre profits generados (yield)
     * @dev En basis points: 100 = 1%, 1000 = 10%. Este fee se cobra sobre el profit generado
     *      por las estrategias en cada harvest y se distribuye entre treasury y founder
     * @return feeBps Performance fee en basis points
     */
    function performanceFee() external view returns (uint256 feeBps);

    /**
     * @notice Porcentaje del performance fee asignado al treasury
     * @dev En basis points sobre el total del performance fee (no sobre el profit total).
     * @return splitBps Split del treasury en basis points (debe sumar BASIS_POINTS con founderSplit)
     */
    function treasurySplit() external view returns (uint256 splitBps);

    /**
     * @notice Devuelve el porcentaje del performance fee asignado al founder
     * @dev En basis points sobre el total del performance fee (no sobre el profit total).
     * @return splitBps Split del founder en basis points (debe sumar BASIS_POINTS con treasurySplit)
     */
    function founderSplit() external view returns (uint256 splitBps);

    /**
     * @notice Devuelve el depósito mínimo permitido en el vault
     * @dev Previene deposits extremadamente pequeños que no sean económicamente eficientes
     *      debido al coste de gas. Los deposits menores a este threshold serán revertidos
     * @return minAmount Cantidad mínima de assets para un depósito válido
     */
    function minDeposit() external view returns (uint256 minAmount);

    /**
     * @notice Devuelve la límite de assets en el idle buffer requerido para ejecutar allocateIdle()
     * @dev Previene allocations antieconómicas. Solo cuando idleBuffer >= idleThreshold se
     *      justifica el coste de gas de asignar capital a estrategias. Por debajo de este
     *      threshold, allocateIdle() no ejecutará nada
     * @return threshold Límite mínimo de assets idle para realizar allocation
     */
    function idleThreshold() external view returns (uint256 threshold);

    /**
     * @notice Devuelve el TVL máximo permitido en el vault (circuit breaker)
     * @dev Límite de seguridad para prevenir riesgo excesivo en fase temprana. Los deposits que
     *      excedan este límite serán revertidos, protegiendo el protocolo mientras se demuestra
     *      su robustez. Se puede incrementar progresivamente según madurez del protocolo
     * @return maxTvl TVL máximo permitido en assets
     */
    function maxTVL() external view returns (uint256 maxTvl);

    /**
     * @notice Devuelve la dirección del treasury del protocolo
     * @dev El treasury recibe su porcentaje (treasurySplit) de las performance fees generadas.
     *      Estos fondos se usan típicamente para desarrollo, seguridad y crecimiento del protocolo
     * @return treasuryAddress Dirección del treasury que recibe performance fees
     */
    function treasury() external view returns (address treasuryAddress);

    /**
     * @notice Devuelve la dirección del founder o equipo del protocolo
     * @dev El founder recibe su porcentaje (founderSplit) de las performance fees generadas.
     *      Es la recompensa por el desarrollo y mantenimiento del protocolo
     * @return founderAddress Dirección del founder que recibe performance fees
     */
    function founder() external view returns (address founderAddress);

    /**
     * @notice Devuelve la dirección del strategy manager que gestiona las estrategias
     * @dev El strategy manager es el contrato responsable de allocation, rebalancing y harvest
     *      de todas las estrategias. El vault delega toda la gestión de capital a este contrato
     * @return managerAddress Dirección del contrato strategy manager
     */
    function strategyManager() external view returns (address managerAddress);

    /**
     * @notice Devuelve el balance de assets idle aún no asignados a estrategias
     * @dev El idle buffer representa liquidez disponible en el vault que no está generando yield.
     *      Se acumula por deposits de usuarios y se reduce mediante allocateIdle() cuando alcanza
     *      el idleThreshold. Mantener un buffer permite withdrawals rápidos sin retirar de estrategias
     *      y ahorrar mucho gas al no hacer depósitos de usuarios inmediatos en los protocolos
     * @return idleBalance Balance actual de assets idle buffer en el vault
     */
    function idleBuffer() external view returns (uint256 idleBalance);

    /**
     * @notice Devuelve el timestamp del último harvest ejecutado
     * @dev Se usa para calcular intervalos entre harvests y determinar cuándo es óptimo ejecutar
     *      el siguiente harvest basándose en la acumulación de rewards en las estrategias
     * @return timestamp Unix timestamp del último harvest (segundos desde epoch)
     */
    function lastHarvest() external view returns (uint256 timestamp);

    /**
     * @notice Devuelve el profit total acumulado desde el inicio del vault
     * @dev Suma de todos los profits cosechados a lo largo de la vida del vault, sin deducir fees.
     *      Representa el yield bruto generado por todas las estrategias antes de performance fees
     * @return totalProfit Profit total acumulado en assets desde el deploy del vault
     */
    function totalHarvested() external view returns (uint256 totalProfit);

    /**
     * @notice Devuelve si una direccion es keeper oficial del protocolo
     * @dev Los keepers oficiales no reciben incentivo al ejecutar harvest
     * @param keeper Address a comprobar
     * @return isOfficial True si es keeper oficial, false en caso contrario
     */
    function isOfficialKeeper(address keeper) external view returns (bool isOfficial);

    /**
     * @notice Devuelve el profit mínimo requerido para ejecutar harvest
     * @dev Previene harvests no rentables donde el gas cost excede el profit generado.
     *      Solo se ejecutará harvest si el profit total es mayor o igual a este threshold
     * @return minProfit Profit mínimo en assets para ejecutar harvest
     */
    function minProfitForHarvest() external view returns (uint256 minProfit);

    /**
     * @notice Devuelve el porcentaje de incentivo para keepers externos
     * @dev En basis points sobre el profit total. Los keepers externos que ejecuten harvest
     *      reciben este porcentaje como recompensa. Los keepers oficiales no reciben incentivo
     * @return incentiveBps Incentivo para keepers en basis points
     */
    function keeperIncentive() external view returns (uint256 incentiveBps);
}
