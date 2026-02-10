// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IStrategy} from "./IStrategy.sol";

/**
 * @title IStrategyManager
 * @author cristianrisueo
 * @notice Interfaz del gestor de estrategias del protocolo
 * @dev Coordina la asignación de assets entre múltiples estrategias (Aave, Compound, etc.),
 *      gestiona el rebalanceo automático basado en APY y ejecuta harvest de rewards
 * @dev Solo por aclarar, lo creo conveniente: assets = underlying asset del vault, lo verás
 *      mucho en comentarios, por si te confunde
 */
interface IStrategyManager {
    //* Eventos

    /**
     * @notice Emitido cuando se asignan assets a una estrategia específica
     * @param strategy Dirección de la estrategia que recibe los assets
     * @param assets Cantidad de assets asignados a esta estrategia
     */
    event Allocated(address indexed strategy, uint256 assets);

    /**
     * @notice Emitido cuando se rebalancea capital entre dos estrategias
     * @param fromStrategy Estrategia origen desde donde se retiran los assets
     * @param toStrategy Estrategia destino hacia donde se mueven los assets
     * @param assets Cantidad de assets rebalanceados entre estrategias
     */
    event Rebalanced(address indexed fromStrategy, address indexed toStrategy, uint256 assets);

    /**
     * @notice Emitido cuando se ejecuta harvest en todas las estrategias activas
     * @param totalProfit Profit total generado en assets sumando todas las estrategias
     */
    event Harvested(uint256 totalProfit);

    /**
     * @notice Emitido cuando se añade una nueva estrategia al pool de estrategias disponibles
     * @param strategy Dirección de la estrategia añadida
     */
    event StrategyAdded(address indexed strategy);

    /**
     * @notice Emitido cuando se elimina una estrategia del pool de estrategias activas
     * @param strategy Dirección de la estrategia eliminada
     */
    event StrategyRemoved(address indexed strategy);

    /**
     * @notice Emitido cuando se actualiza la asignación de assets de las estrategias
     * @dev Esto ocurre cuando se recalculan los porcentajes objetivo de cada estrategia
     * @dev Normalmente esto precede a un rebalanceo, por lo que no sería raro encontrar el evento
     *      Rebalanced tras este
     */
    event TargetAllocationUpdated();

    //* Funciones principales

    /**
     * @notice Asigna assets a las estrategias según su APY actual
     * @dev Primero recibe los assets del vault, luego los distribuye entre las estrategias activas
     *      priorizando aquellas con mayor APY. La distribución sigue el target allocation calculado
     *      dinámicamente en base a los APYs de cada estrategia en ese momento
     * @param amount Cantidad de assets (WETH) a asignar entre las estrategias
     */
    function allocate(uint256 amount) external;

    /**
     * @notice Retira assets de las estrategias de forma proporcional a su balance actual
     * @dev Itera sobre todas las estrategias activas y retira proporcionalmente según el amount
     *      solicitado. Los assets retirados se transfieren directamente al receiver especificado
     * @param amount Cantidad de assets (WETH) a retirar del pool total de estrategias
     * @param receiver Dirección que recibirá los assets retirados (generalmente el vault)
     */
    function withdrawTo(uint256 amount, address receiver) external;

    /**
     * @notice Rebalancea capital entre estrategias si la operación es rentable
     * @dev Analiza los APYs actuales de todas las estrategias y mueve capital desde las de menor
     *      APY hacia las de mayor APY. Solo ejecuta si el profit esperado es mayor a 2x el costo
     *      del gas, garantizando que el rebalanceo sea económicamente beneficioso
     * @dev El umbral 2x gas evita pérdidas por rebalanceos frecuentes con ganancias marginales
     */
    function rebalance() external;

    /**
     * @notice Ejecuta harvest en todas las estrategias activas del protocolo
     * @dev Itera sobre cada estrategia llamando a su función harvest(), recolecta todos los rewards,
     *      los convierte a asset base y reinvierte automáticamente para maximizar APY compuesto
     * @return totalProfit Profit total generado en assets (WETH) sumando todas las estrategias
     */
    function harvest() external returns (uint256 totalProfit);

    //* Funciones de gestión de estrategias (onlyOwner)

    /**
     * @notice Añade una nueva estrategia al pool de estrategias disponibles
     * @dev Solo puede ser llamada por el owner. La estrategia debe implementar IStrategy y usar
     *      el mismo asset base que el resto del protocolo. Una vez añadida, la estrategia estará
     *      disponible para recibir allocations en futuras distribuciones de capital
     * @param strategy Dirección del contrato de la estrategia a añadir
     */
    function addStrategy(address strategy) external;

    /**
     * @notice Elimina una estrategia del pool de estrategias activas
     * @dev Solo puede ser llamada por el owner. IMPORTANTE: Antes de eliminar una estrategia,
     *      se debe haber retirado todo su capital mediante withdraw, dejando su balance en 0.
     *      Esto previene pérdida de fondos al eliminar estrategias con capital activo
     * @param index Índice de la estrategia en el array de estrategias activas
     */
    function removeStrategy(uint256 index) external;

    //* Funciones de consulta

    /**
     * @notice Comprueba si un rebalanceo sería rentable en el momento actual
     * @dev Calcula la diferencia de APY entre estrategias y estima si mover capital generaría
     *      un profit mayor a X el costo del gas. Se usa antes de llamar a rebalance() para
     *      evitar transacciones que resultarían en pérdida neta
     * @return profitable True si el rebalanceo sería rentable, false en caso contrario
     */
    function shouldRebalance() external view returns (bool profitable);

    /**
     * @notice Devuelve el valor total de assets bajo gestión en todas las estrategias
     * @dev Suma el totalAssets() de cada estrategia activa. Representa el TVL (Total Value Locked)
     *      del strategy manager, incluyendo capital inicial + yields acumulados de todas las estrategias
     * @return total Valor total en assets gestionados por el strategy manager
     */
    function totalAssets() external view returns (uint256 total);

    /**
     * @notice Devuelve el número de estrategias activas en el protocolo
     * @dev Se usa para iterar sobre el array de estrategias o comprobar cuántas estrategias
     *      están actualmente operativas y recibiendo allocations
     * @return count Número de estrategias activas
     */
    function strategiesCount() external view returns (uint256 count);

    /**
     * @notice Devuelve la estrategia ubicada en el índice especificado
     * @dev Permite acceso directo a cualquier estrategia del array de estrategias activas.
     *      Útil para iterar sobre todas las estrategias o consultar una específica
     * @param index Índice de la estrategia en el array (0-indexed)
     * @return strategy Instancia de la estrategia en ese índice
     */
    function strategies(uint256 index) external view returns (IStrategy strategy);

    /**
     * @notice Devuelve el porcentaje de allocation de assets para una estrategia específica
     * @dev El target allocation se calcula dinámicamente en base al APY de cada estrategia.
     *      Estrategias con mayor APY reciben mayor porcentaje del capital total
     * @param strategy Dirección de la estrategia a consultar
     * @return allocationBps Target allocation en basis points (100 = 1%, 1000 = 10%, 10000 = 100%)
     */
    function targetAllocation(IStrategy strategy) external view returns (uint256 allocationBps);

    /**
     * @notice Devuelve la dirección del vault principal del protocolo
     * @dev El vault es el contrato que interactúa directamente con los usuarios (hasta que llegue el router)
     *      y delega a gestión de assets al strategy manager. Es el punto de entrada de deposits/withdrawals
     * @return vaultAddress Dirección del contrato vault
     */
    function vault() external view returns (address vaultAddress);

    /**
     * @notice Devuelve la dirección del underlying asset que gestiona el protocolo
     * @dev Todas las estrategias deben usar este mismo asset
     * @return assetAddress Dirección del token usado como underlying asset
     */
    function asset() external view returns (address assetAddress);
}
