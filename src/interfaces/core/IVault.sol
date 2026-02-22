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
    //* Structs

    /**
     * @notice Parametros de configuracion del vault específicos del risk tier, pasados en el constructor
     * @param idle_threshold Threshold de idle buffer para ejecutar allocateIdle
     * @param min_profit_for_harvest Profit minimo requerido para ejecutar harvest
     * @param max_tvl TVL maximo permitido como circuit breaker
     * @param min_deposit Deposito minimo permitido
     */
    struct TierConfig {
        uint256 idle_threshold;
        uint256 min_profit_for_harvest;
        uint256 max_tvl;
        uint256 min_deposit;
    }

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
     * @param performance_fee Cantidad de performance fee cobrada sobre el profit
     * @param timestamp Timestamp del momento en que se ejecutó el harvest
     */
    event Harvested(uint256 profit, uint256 performance_fee, uint256 timestamp);

    /**
     * @notice Emitido cuando se distribuyen las performance fees entre treasury y founder
     * @param treasury_amount Cantidad de assets enviados a la dirección treasury
     * @param founder_amount Cantidad de assets enviados a la dirección founder
     */
    event PerformanceFeeDistributed(uint256 treasury_amount, uint256 founder_amount);

    /**
     * @notice Emitido cuando se asignan assets idle a las estrategias mediante el strategy manager
     * @param amount Cantidad de assets idle que fueron asignados a estrategias
     */
    event IdleAllocated(uint256 amount);

    /**
     * @notice Emitido cuando se reconcilia idle_buffer con el balance real del vault (tras emergency exits)
     * @param old_buffer Valor de idle_buffer antes de la sincronización
     * @param new_buffer Valor de idle_buffer después de la sincronización (balance real de WETH)
     */
    event IdleBufferSynced(uint256 old_buffer, uint256 new_buffer);

    /**
     * @notice Emitido cuando se actualiza la dirección del strategy manager
     * @param new_manager Nueva dirección del strategy manager que gestionará las estrategias
     */
    event StrategyManagerUpdated(address indexed new_manager);

    /**
     * @notice Emitido cuando se actualiza el performance fee
     * @param old_fee Performance fee anterior en basis points
     * @param new_fee Nuevo performance fee en basis points
     */
    event PerformanceFeeUpdated(uint256 old_fee, uint256 new_fee);

    /**
     * @notice Emitido cuando se actualiza el split de fees entre treasury y founder
     * @param treasury_split Nuevo porcentaje para treasury en basis points
     * @param founder_split Nuevo porcentaje para founder en basis points
     */
    event FeeSplitUpdated(uint256 treasury_split, uint256 founder_split);

    /**
     * @notice Emitido cuando se actualiza el depósito mínimo
     * @param old_min Depósito mínimo anterior
     * @param new_min Nuevo depósito mínimo
     */
    event MinDepositUpdated(uint256 old_min, uint256 new_min);

    /**
     * @notice Emitido cuando se actualiza el idle threshold
     * @param old_threshold Threshold anterior
     * @param new_threshold Nuevo threshold
     */
    event IdleThresholdUpdated(uint256 old_threshold, uint256 new_threshold);

    /**
     * @notice Emitido cuando se actualiza el TVL máximo
     * @param old_max TVL máximo anterior
     * @param new_max Nuevo TVL máximo
     */
    event MaxTVLUpdated(uint256 old_max, uint256 new_max);

    /**
     * @notice Emitido cuando se actualiza la dirección del treasury
     * @param old_treasury Dirección anterior del treasury
     * @param new_treasury Nueva dirección del treasury
     */
    event TreasuryUpdated(address indexed old_treasury, address indexed new_treasury);

    /**
     * @notice Emitido cuando se actualiza la dirección del founder
     * @param old_founder Dirección anterior del founder
     * @param new_founder Nueva dirección del founder
     */
    event FounderUpdated(address indexed old_founder, address indexed new_founder);

    /**
     * @notice Emitido cuando se añade o remueve un keeper oficial
     * @param keeper Dirección del keeper
     * @param status True si se añade, false si se remueve
     */
    event OfficialKeeperUpdated(address indexed keeper, bool status);

    /**
     * @notice Emitido cuando se actualiza el profit mínimo para harvest
     * @param old_min Profit mínimo anterior
     * @param new_min Nuevo profit mínimo
     */
    event MinProfitForHarvestUpdated(uint256 old_min, uint256 new_min);

    /**
     * @notice Emitido cuando se actualiza el incentivo para keepers externos
     * @param old_incentive Incentivo anterior en basis points
     * @param new_incentive Nuevo incentivo en basis points
     */
    event KeeperIncentiveUpdated(uint256 old_incentive, uint256 new_incentive);

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
     * @param new_fee Nuevo performance fee en basis points (debe ser <= BASIS_POINTS)
     */
    function setPerformanceFee(uint256 new_fee) external;

    /**
     * @notice Actualiza el split de performance fees entre treasury y founder
     * @dev Solo puede ser llamada por el owner del vault
     * @param new_treasury Nuevo porcentaje para treasury en basis points
     * @param new_founder Nuevo porcentaje para founder en basis points
     * @dev La suma de ambos debe ser exactamente BASIS_POINTS (10000)
     */
    function setFeeSplit(uint256 new_treasury, uint256 new_founder) external;

    /**
     * @notice Actualiza el depósito mínimo permitido
     * @dev Solo puede ser llamada por el owner del vault
     * @param new_min Nuevo depósito mínimo en assets
     */
    function setMinDeposit(uint256 new_min) external;

    /**
     * @notice Actualiza el threshold de assets idle para ejecutar allocation
     * @dev Solo puede ser llamada por el owner del vault
     * @param new_threshold Nuevo threshold en assets
     */
    function setIdleThreshold(uint256 new_threshold) external;

    /**
     * @notice Actualiza el TVL máximo permitido en el vault
     * @dev Solo puede ser llamada por el owner del vault
     * @param new_max Nuevo TVL máximo en assets
     */
    function setMaxTVL(uint256 new_max) external;

    /**
     * @notice Actualiza la dirección del treasury
     * @dev Solo puede ser llamada por el owner del vault
     * @param new_treasury Nueva dirección del treasury (no puede ser address(0))
     */
    function setTreasury(address new_treasury) external;

    /**
     * @notice Actualiza la dirección del founder
     * @dev Solo puede ser llamada por el owner del vault
     * @param new_founder Nueva dirección del founder (no puede ser address(0))
     */
    function setFounder(address new_founder) external;

    /**
     * @notice Actualiza la dirección del strategy manager
     * @dev Solo puede ser llamada por el owner del vault
     * @param new_manager Nueva dirección del strategy manager (no puede ser address(0))
     */
    function setStrategyManager(address new_manager) external;

    /**
     * @notice Actualiza el profit mínimo requerido para ejecutar harvest
     * @dev Solo puede ser llamada por el owner del vault
     * @param new_min Nuevo profit mínimo en assets
     */
    function setMinProfitForHarvest(uint256 new_min) external;

    /**
     * @notice Actualiza el incentivo para keepers externos que ejecuten harvest
     * @dev Solo puede ser llamada por el owner del vault
     * @param new_incentive Nuevo incentivo en basis points (debe ser <= BASIS_POINTS)
     */
    function setKeeperIncentive(uint256 new_incentive) external;

    /**
     * @notice Reconcilia idle_buffer con el balance real de WETH del contrato
     * @dev Solo puede ser llamada por el owner. Ejecutado después de emergencyExit() del manager
     */
    function syncIdleBuffer() external;

    //* Funciones de consulta - Getters de parámetros y treaury del protocolo

    /**
     * @notice Devuelve el porcentaje de performance fee cobrado sobre profits generados (yield)
     * @dev En basis points: 100 = 1%, 1000 = 10%. Este fee se cobra sobre el profit generado
     *      por las estrategias en cada harvest y se distribuye entre treasury y founder
     * @return fee_bps Performance fee en basis points
     */
    function performance_fee() external view returns (uint256 fee_bps);

    /**
     * @notice Porcentaje del performance fee asignado al treasury
     * @dev En basis points sobre el total del performance fee (no sobre el profit total).
     * @return split_bps Split del treasury en basis points (debe sumar BASIS_POINTS con founder_split)
     */
    function treasury_split() external view returns (uint256 split_bps);

    /**
     * @notice Devuelve el porcentaje del performance fee asignado al founder
     * @dev En basis points sobre el total del performance fee (no sobre el profit total).
     * @return split_bps Split del founder en basis points (debe sumar BASIS_POINTS con treasury_split)
     */
    function founder_split() external view returns (uint256 split_bps);

    /**
     * @notice Devuelve el depósito mínimo permitido en el vault
     * @dev Previene deposits extremadamente pequeños que no sean económicamente eficientes
     *      debido al coste de gas. Los deposits menores a este threshold serán revertidos
     * @return min_amount Cantidad mínima de assets para un depósito válido
     */
    function minDeposit() external view returns (uint256 min_amount);

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
     * @return max_tvl TVL máximo permitido en assets
     */
    function maxTVL() external view returns (uint256 max_tvl);

    /**
     * @notice Devuelve la dirección del treasury del protocolo
     * @dev El treasury recibe su porcentaje (treasury_split) de las performance fees generadas.
     *      Estos fondos se usan típicamente para desarrollo, seguridad y crecimiento del protocolo
     * @return treasury_address Dirección del treasury que recibe performance fees
     */
    function treasury() external view returns (address treasury_address);

    /**
     * @notice Devuelve la dirección del founder o equipo del protocolo
     * @dev El founder recibe su porcentaje (founder_split) de las performance fees generadas.
     *      Es la recompensa por el desarrollo y mantenimiento del protocolo
     * @return founder_address Dirección del founder que recibe performance fees
     */
    function founder() external view returns (address founder_address);

    /**
     * @notice Devuelve la dirección del strategy manager que gestiona las estrategias
     * @dev El strategy manager es el contrato responsable de allocation, rebalancing y harvest
     *      de todas las estrategias. El vault delega toda la gestión de capital a este contrato
     * @return manager_address Dirección del contrato strategy manager
     */
    function strategyManager() external view returns (address manager_address);

    /**
     * @notice Devuelve el balance de assets idle aún no asignados a estrategias
     * @dev El idle buffer representa liquidez disponible en el vault que no está generando yield.
     *      Se acumula por deposits de usuarios y se reduce mediante allocateIdle() cuando alcanza
     *      el idleThreshold. Mantener un buffer permite withdrawals rápidos sin retirar de estrategias
     *      y ahorrar mucho gas al no hacer depósitos de usuarios inmediatos en los protocolos
     * @return idle_balance Balance actual de assets idle buffer en el vault
     */
    function idleBuffer() external view returns (uint256 idle_balance);

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
     * @return total_profit Profit total acumulado en assets desde el deploy del vault
     */
    function totalHarvested() external view returns (uint256 total_profit);

    /**
     * @notice Devuelve si una direccion es keeper oficial del protocolo
     * @dev Los keepers oficiales no reciben incentivo al ejecutar harvest
     * @param keeper Address a comprobar
     * @return is_official True si es keeper oficial, false en caso contrario
     */
    function is_official_keeper(address keeper) external view returns (bool is_official);

    /**
     * @notice Devuelve el profit mínimo requerido para ejecutar harvest
     * @dev Previene harvests no rentables donde el gas cost excede el profit generado.
     *      Solo se ejecutará harvest si el profit total es mayor o igual a este threshold
     * @return min_profit Profit mínimo en assets para ejecutar harvest
     */
    function minProfitForHarvest() external view returns (uint256 min_profit);

    /**
     * @notice Devuelve el porcentaje de incentivo para keepers externos
     * @dev En basis points sobre el profit total. Los keepers externos que ejecuten harvest
     *      reciben este porcentaje como recompensa. Los keepers oficiales no reciben incentivo
     * @return incentive_bps Incentivo para keepers en basis points
     */
    function keeperIncentive() external view returns (uint256 incentive_bps);
}
