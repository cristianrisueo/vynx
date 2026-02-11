// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IStrategy} from "../interfaces/core/IStrategy.sol";
import {IStrategyManager} from "../interfaces/core/IStrategyManager.sol";

/**
 * @title StrategyManager
 * @author cristianrisueo
 * @notice Cerebro del protocolo VynX que decide allocation y ejecuta rebalancing
 * @dev Usa weighted allocation basado en APY para diversificar entre strategies DeFi
 *      Coordina harvest con fail-safe, allocation óptimo y rebalancing rentable
 */
contract StrategyManager is IStrategyManager, Ownable {
    //* library attachments

    /**
     * @notice Usa SafeERC20 para todas las operaciones de IERC20 de manera segura
     * @dev Evita errores comunes con tokens legacy o mal implementados
     */
    using SafeERC20 for IERC20;

    //* Errores

    /**
     * @notice Error cuando no hay estrategias disponibles
     */
    error StrategyManager__NoStrategiesAvailable();

    /**
     * @notice Error cuando se intenta agregar una estrategia duplicada
     */
    error StrategyManager__StrategyAlreadyExists();

    /**
     * @notice Error cuando se intenta remover una estrategia que no existe
     */
    error StrategyManager__StrategyNotFound();

    /**
     * @notice Error cuando la estrategia tiene assets y no se puede remover
     */
    error StrategyManager__StrategyHasAssets();

    /**
     * @notice Error cuando el rebalance no es rentable
     */
    error StrategyManager__RebalanceNotProfitable();

    /**
     * @notice Error cuando se intenta operar con cantidad cero
     */
    error StrategyManager__ZeroAmount();

    /**
     * @notice Error cuando solo el vault puede llamar
     */
    error StrategyManager__OnlyVault();

    /**
     * @notice Error cuando se intenta inicializar vault ya inicializado
     */
    error StrategyManager__VaultAlreadyInitialized();

    /**
     * @notice Error cuando el asset de la estrategia no coincide
     */
    error StrategyManager__AssetMismatch();

    /**
     * @notice Error cuando se pasa address(0) como vault
     */
    error StrategyManager__InvalidVaultAddress();

    //* Eventos: Se heredan de la interfaz, no es necesario implementarlos

    //* Constantes

    /// @notice Base para calculos de basis points (100% = 10000 basis points)
    uint256 public constant BASIS_POINTS = 10000;

    /// @notice Maximo de estrategias permitidas para prevenir DoS por gas en loops
    uint256 public constant MAX_STRATEGIES = 10;

    //* Variables de estado

    /// @notice Direccion del vault autorizado para llamar allocate/withdraw/harvest
    address public vault;

    /// @notice Array de estrategias disponibles
    IStrategy[] public strategies;

    /// @notice Mapeo para verificar rapidamente si una estrategia existe
    mapping(address => bool) public is_strategy;

    /// @notice Target allocation para las estrategias, en basis points (10000 = 100%)
    mapping(IStrategy => uint256) public targetAllocation;

    /// @notice Direccion del asset subyacente del protocolo
    address public immutable asset;

    //? Por qué definirlo aquí y no en el constructor? Es una buena práctica, dejamos el
    //? constructor lo más simple posible para que no haya posibles fallos en deployment

    /// @notice Threshold minimo de diferencia de APY para considerar rebalance (2% en basis points)
    uint256 public rebalance_threshold = 200;

    /// @notice TVL minimo para ejecutar rebalance (hasta que llegue aquí se acumula en el idle buffer)
    uint256 public min_tvl_for_rebalance = 10 ether;

    /// @notice Allocation maximo por estrategia en basis points (50%)
    uint256 public max_allocation_per_strategy = 5000;

    /// @notice Allocation minimo por estrategia en basis points (10%)
    uint256 public min_allocation_threshold = 1000;

    //* Modificadores

    /**
     * @notice Solo permite llamadas del vault
     */
    modifier onlyVault() {
        if (msg.sender != vault) revert StrategyManager__OnlyVault();
        _;
    }

    //* Constructor y función de inicialización (problema chicken-egg, más info en comentario)

    /**
     * @notice Constructor del StrategyManager
     * @dev Inicializa con la dirección del asset a gestionar
     * @param _asset Direccion del asset subyacente
     */
    constructor(address _asset) Ownable(msg.sender) {
        // Comprueba que el asset no sea address(0) y setea el asset
        if (_asset == address(0)) revert StrategyManager__AssetMismatch();
        asset = _asset;
    }

    /**
     * @notice Inicializa el vault (solo si aun no está inicializado)
     * @dev Resuelve el problema de dependencias ciruculares en deployment y testing
     *      Vault necesita dirección de manager y manager necesita dirección de vault
     *      En constructor de manager ya no seteamos el address vault, y una vez que tengamos
     *      ambos contratos desplegados actualizamos el manager con el address del vault
     * @dev Solo puede llamarse una vez, cuando vault == address(0)
     * @param _vault Direccion del Vault
     */
    function initialize(address _vault) external onlyOwner {
        // Comprueba que el vault no este inicializado previamente y el address recibido != 0
        if (vault != address(0)) revert StrategyManager__VaultAlreadyInitialized();
        if (_vault == address(0)) revert StrategyManager__InvalidVaultAddress();

        // Setea el vault y emite evento
        vault = _vault;
        emit Initialized(_vault);
    }

    //* Lógica de negocio principal: Allocation, retiros y harvest (only vault)

    /**
     * @notice Deposita assets distribuyendolos entre estrategias segun target allocation
     * @dev Solo puede ser llamado por el vault
     * @dev El vault debe transferir assets a este contrato antes de llamar
     * @param assets Cantidad de assets a invertir en las estrategias
     */
    function allocate(uint256 assets) external onlyVault {
        // Comprueba que la cantidad a transferir no sea 0 y que existan estrategias disponibles
        if (assets == 0) revert StrategyManager__ZeroAmount();
        if (strategies.length == 0) revert StrategyManager__NoStrategiesAvailable();

        // Calcula target allocations nuevos basados en APYs actuales (este sí cambia el state)
        _calculateTargetAllocation();

        // Itera sobre las estrategias disponibles para distribuir los assets según su nuevo target allocation
        for (uint256 i = 0; i < strategies.length; i++) {
            // Obtiene la estrategia y su target allocation
            IStrategy strategy = strategies[i];
            uint256 target = targetAllocation[strategy];

            // Si la estrategia tiene allocation > 0, deposita proporcionalmente
            if (target > 0) {
                // Calcula cuanto debe recibir esta estrategia (% del total)
                // La formula es: (cantidad * target) / BASIS_POINTS
                uint256 amount_for_strategy = (assets * target) / BASIS_POINTS;

                // Transfiere la cantidad correspondiente (un % del total) a la estrategia,
                // invoca el método deposit de dicha estrategia y emite evento
                if (amount_for_strategy > 0) {
                    IERC20(asset).safeTransfer(address(strategy), amount_for_strategy);
                    strategy.deposit(amount_for_strategy);
                    emit Allocated(address(strategy), amount_for_strategy);
                }
            }
        }
    }

    /**
     * @notice Retira assets del manager hacia el vault
     * @dev Solo puede ser llamado por el vault
     * @dev Retira proporcionalmente de cada estrategia para mantener sus porcentajes iguales,
     *      gracias a que retira proporcionalmente no tenemos que llamar a _calculateTargetAllocation
     *      ahorrando de paso un puto montón de gas, porque los allocations siguen en la misma proporción
     * @param assets Cantidad de assets a retirar
     * @param receiver Direccion que recibira los assets (debe ser el vault)
     */
    function withdrawTo(uint256 assets, address receiver) external onlyVault {
        // Comprueba que la cantidad a retirar no sea 0
        if (assets == 0) revert StrategyManager__ZeroAmount();

        // Obtiene los assets totales del manager. Si no tiene assets retorna sin hacer nada
        uint256 total_assets = totalAssets();
        if (total_assets == 0) return;

        // Itera sobre cada estrategia para retirar proporcialmente
        for (uint256 i = 0; i < strategies.length; i++) {
            // Obtiene la estrategia y su balance actual
            IStrategy strategy = strategies[i];
            uint256 strategy_balance = strategy.totalAssets();

            // Si su balance es 0 omite esta iteración
            if (strategy_balance == 0) continue;

            // Calcula cuanto retirar de esta estrategia (proporcional a su balance)
            uint256 to_withdraw = (assets * strategy_balance) / total_assets;

            // Si el resultado es mayor que 0 invoca el método withdraw de esa estrategia
            if (to_withdraw > 0) {
                strategy.withdraw(to_withdraw);
            }
        }

        // Con los assets ya en el manager los transfiere al receiver (vault)
        IERC20(asset).safeTransfer(receiver, assets);
    }

    /**
     * @notice Ejecuta harvest en todas las estrategias activas y suma los profits
     * @dev Solo puede ser llamado por el vault (usuarios llaman Vault.harvest, no Manager.harvest)
     * @dev Usa try-catch para fail-safe: si una estrategia falla por problemas externos
     *      continua con las demas y emite evento de error. Este enfoque previene que una estrategia
     *      rota bloquee el harvest de todas las demas
     * @return total_profit Suma de profits de todas las estrategias convertido a assets
     */
    function harvest() external onlyVault returns (uint256 total_profit) {
        // Acumulador de profit (en asset gestionado por el protocolo) de todas las estrategias
        total_profit = 0;

        // Itera sobre las estrategias y ejecuta sus harvest con try-catch para seguridad
        for (uint256 i = 0; i < strategies.length; i++) {
            IStrategy strategy = strategies[i];

            // Si el harvest fue exitoso, acumula el profit de esta estrategia
            // Si falla con o sin mensaje de error, emite evento pero continúa
            try strategy.harvest() returns (uint256 strategy_profit) {
                total_profit += strategy_profit;
            } catch Error(string memory reason) {
                emit HarvestFailed(address(strategy), reason);
            } catch {
                emit HarvestFailed(address(strategy), "Unknown error");
            }
        }

        // Emite evento de harvest realizado y devuelve el acumulador
        emit Harvested(total_profit);
    }

    //* Lógica de negocio primaria: Rebalance (externa para que cualquiera pueda ejecutar el rebalanceo)
    //* Esto permite no centralizar el rebalanceo de estrategias e incentivar económicamente que ayuden

    /**
     * @notice Rebalancea capital entre estrategias si la operacion es rentable
     * @dev Mueve capital desde estrategias con bajo APY hacia estrategias con alto APY
     * @dev Cualquiera puede llamar esta funcion si shouldRebalance()
     */
    function rebalance() external {
        // Comprueba si es rentable rebalancear. Si no lo es revierte
        bool should_rebalance = shouldRebalance();
        if (!should_rebalance) revert StrategyManager__RebalanceNotProfitable();

        // Recalcula targets allocations y obtiene el TVL del protocolo
        // Estas dos lineas obtienen qué porcentaje repartir y cuánto tenemos para repartir
        _calculateTargetAllocation();
        uint256 total_tvl = totalAssets();

        // Arrays vacios para tracking: Estrategias con exceso de fondos y cuanto exceso tienen
        IStrategy[] memory strategies_with_excess = new IStrategy[](strategies.length);
        uint256[] memory excess_amounts = new uint256[](strategies.length);

        // Arrays vacios para tracking: Estrategias con falta de fondos y cuanta falta tienen
        IStrategy[] memory strategies_needing_funds = new IStrategy[](strategies.length);
        uint256[] memory needed_amounts = new uint256[](strategies.length);

        // Variables para tracking: Counters de estrategias con exceso y con falta de fondos
        uint256 excess_count = 0;
        uint256 needed_count = 0;

        // Itera sobre las estrategias para obtener aquellas con exceso o necesidad de fondos
        for (uint256 i = 0; i < strategies.length; i++) {
            // Obtiene la estrategia i
            IStrategy strategy = strategies[i];

            // Obtiene su balance actual y su balance target (el que deberia tener) basado en allocation
            uint256 current_balance = strategy.totalAssets();
            uint256 target_balance = (total_tvl * targetAllocation[strategy]) / BASIS_POINTS;

            // Si tiene exceso de fondos: Añade estrategia y exceso a arrays de tracking y aumenta count
            if (current_balance > target_balance) {
                strategies_with_excess[excess_count] = strategy;
                excess_amounts[excess_count] = current_balance - target_balance;
                excess_count++;
            }
            // Si tiene necesidad de fondos: Hace lo mismo con sus arrays y count correspondiente
            else if (target_balance > current_balance) {
                strategies_needing_funds[needed_count] = strategy;
                needed_amounts[needed_count] = target_balance - current_balance;
                needed_count++;
            }
        }

        // Itera sobre el contador de estrategias con exceso para mover fondos de estr.exceso -> estr.necesidad
        for (uint256 i = 0; i < excess_count; i++) {
            // Obtiene la estrategia con exceso i, y su cantidad excedida
            IStrategy from_strategy = strategies_with_excess[i];
            uint256 available = excess_amounts[i];

            // Retira el exceso de cantidad de la estrategia i. En este punto el sobrante ya está en el manager
            from_strategy.withdraw(available);

            // Itera sobre el contador de estrategias con necesidad de fondos mientras quede exceso disponible
            for (uint256 j = 0; j < needed_count && available > 0; j++) {
                // Obtiene la estrategia con necesidad j, y su cantidad necesaria
                IStrategy to_strategy = strategies_needing_funds[j];
                uint256 needed = needed_amounts[j];

                // Si necesita fondos (o sigue necesitando despues de tener todo el exceso de la primera estrategia)
                if (needed > 0) {
                    // Se obtiene la cantidad minima entre lo que excede de i y lo que necesita j
                    uint256 to_transfer = available > needed ? needed : available;

                    // Transfiere la cantidad minima a la estrategia que la necesita, la deposita y emite evento
                    IERC20(asset).safeTransfer(address(to_strategy), to_transfer);
                    to_strategy.deposit(to_transfer);
                    emit Rebalanced(address(from_strategy), address(to_strategy), to_transfer);

                    // Actualiza contadores: Resta lo transferido del exceso disponible y de lo necesario
                    available -= to_transfer;
                    needed_amounts[j] -= to_transfer;
                }
            }
        }

        // Emite evento de actualizacion de target allocations
        emit TargetAllocationUpdated();
    }

    //* Funciones de gestion de estrategias (onlyOwner)

    /**
     * @notice Añade una nueva estrategia al pool de estrategias disponibles
     * @dev Solo puede ser llamado por el owner
     * @dev Valida que la estrategia no exista previamente y que use el mismo asset
     * @param strategy Direccion del contrato de estrategia a añadir
     */
    function addStrategy(address strategy) external onlyOwner {
        // Comprueba rapidamente si la estrategia ya fue agregada. En caso afirmativo revierte
        if (is_strategy[strategy]) revert StrategyManager__StrategyAlreadyExists();

        // Comprueba que no se exceda el maximo de estrategias permitidas
        if (strategies.length >= MAX_STRATEGIES) revert StrategyManager__NoStrategiesAvailable();

        // Comprueba que la estrategia use el mismo asset que el manager
        IStrategy strategy_interface = IStrategy(strategy);
        if (strategy_interface.asset() != asset) revert StrategyManager__AssetMismatch();

        // Añade la estrategia al array y el address al mapping de rapida verificacion
        strategies.push(strategy_interface);
        is_strategy[strategy] = true;

        // Recalcula allocations para todas las estrategias. Como hemos añadido
        // esta estrategia, tenemos que recalcular porcentajes de nuevo
        _calculateTargetAllocation();

        // Emite evento de estrategia añadida
        emit StrategyAdded(strategy);
    }

    /**
     * @notice Remueve una estrategia del manager
     * @dev Solo el owner puede remover estrategias
     * @dev La estrategia debe tener balance cero antes de ser removida (usar withdraw primero)
     * @param index Indice de la estrategia en el array
     */
    function removeStrategy(uint256 index) external onlyOwner {
        // Comprueba que el indice sea valido
        if (index >= strategies.length) revert StrategyManager__StrategyNotFound();

        // Obtiene la estrategia en ese indice, y de la estrategia su address
        IStrategy strategy = strategies[index];
        address strategyAddress = address(strategy);

        // Comprueba que la estrategia no tenga assets bajo gestion (previene la pérdida de fondos)
        if (strategy.totalAssets() > 0) revert StrategyManager__StrategyHasAssets();

        // Elimina el allocation (% del TVL) de esta estrategia antes de eliminarla
        delete targetAllocation[strategy];

        // Elimina la estrategia del array y su address del mapping de verificacion rapida
        // Utiliza la estrategia swap&pop porque ahorra gas (creo que se llamaba asi)
        strategies[index] = strategies[strategies.length - 1];
        strategies.pop();
        is_strategy[strategyAddress] = false;

        // Recalcula allocations para el resto de estrategias. Como hemos eliminado
        // esta estrategia, su allocation (% TVL) esta disponible para las otras
        if (strategies.length > 0) {
            _calculateTargetAllocation();
        }

        // Emite evento de estrategia eliminada
        emit StrategyRemoved(strategyAddress);
    }

    //* Setters de parametros

    /**
     * @notice Actualiza el threshold minimo para rebalancing
     * @dev Porcentaje de mejora en APY de la nueva estrategia para considerar rebalancear
     * @param new_threshold Nuevo threshold en basis points
     */
    function setRebalanceThreshold(uint256 new_threshold) external onlyOwner {
        rebalance_threshold = new_threshold;
    }

    /**
     * @notice Actualiza el TVL minimo para rebalancing
     * @dev Cuantos assets debe acumular el idle buffer para considerar rebalancear
     * @param new_min_tvl Nuevo TVL minimo en wei
     */
    function setMinTVLForRebalance(uint256 new_min_tvl) external onlyOwner {
        min_tvl_for_rebalance = new_min_tvl;
    }

    /**
     * @notice Actualiza el % de allocation maximo por estrategia
     * @dev Tras actualizar el maximo recalcula los allocations de nuevo
     * @param new_max Nuevo maximo en basis points
     */
    function setMaxAllocationPerStrategy(uint256 new_max) external onlyOwner {
        max_allocation_per_strategy = new_max;
        _calculateTargetAllocation();
    }

    /**
     * @notice Actualiza el threshold minimo de allocation
     * @dev Tras actualizar el minimo recalcula los allocations de nuevo
     * @param new_min Nuevo minimo en basis points
     */
    function setMinAllocationThreshold(uint256 new_min) external onlyOwner {
        min_allocation_threshold = new_min;
        _calculateTargetAllocation();
    }

    //* Funciones de consulta: Check de rebalanceo, TVL del protocolo, stats y count de estrategias

    /**
     * @notice Comprueba si un rebalanceo seria beneficioso en el momento actual
     * @dev Valida: suficientes estrategias, TVL minimo y diferencia de APY significativa
     * @dev Los keepers calculan rentabilidad vs gas cost off-chain antes de ejecutar
     * @return profitable True si las condiciones para rebalancear se cumplen
     */
    function shouldRebalance() public view returns (bool profitable) {
        // Si no hay estrategias suficientes, no hay nada que rebalancear
        if (strategies.length < 2) return false;

        // Si el TVL es menor al minimo establecido, no vale la pena rebalancear
        if (totalAssets() < min_tvl_for_rebalance) return false;

        // Variables para tracking de diferencias de APY
        uint256 max_apy = 0;
        uint256 min_apy = type(uint256).max;

        // Itera sobre las estrategias para encontrar la que mayor y menor APY tienen
        for (uint256 i = 0; i < strategies.length; i++) {
            uint256 strategy_apy = strategies[i].apy();

            if (strategy_apy > max_apy) max_apy = strategy_apy;
            if (strategy_apy < min_apy) min_apy = strategy_apy;
        }

        // Rebalance es beneficioso si la diferencia de APY supera el threshold de rebalanceo
        return (max_apy - min_apy) >= rebalance_threshold;
    }

    /**
     * @notice Devuelve el total de assets bajo gestion del manager en las estrategias
     * @dev Suma de assets de todas las estrategias, tendrán xToken, la suma se vendrá
     *      convertida a assets
     * @return total Suma de assets en todas las estrategias
     */
    function totalAssets() public view returns (uint256 total) {
        for (uint256 i = 0; i < strategies.length; i++) {
            total += strategies[i].totalAssets();
        }
    }

    /**
     * @notice Devuelve el numero de estrategias disponibles
     * @return count Cantidad de estrategias
     */
    function strategiesCount() external view returns (uint256 count) {
        return strategies.length;
    }

    /**
     * @notice Devuelve informacion de todas las estrategias
     * @dev ADVERTENCIA: Gas intensivo (+1M aprox), solo usar para consultas off-chain
     *      o frontend. Si la llamas desde otro contrato, bajo tu cuenta y riesgo buddy
     * @return names Nombre de las estrategias
     * @return apys APYs de cada estrategia
     * @return tvls TVL de cada estrategia
     * @return targets Target allocation de cada estrategia
     */
    function getAllStrategiesInfo()
        external
        view
        returns (string[] memory names, uint256[] memory apys, uint256[] memory tvls, uint256[] memory targets)
    {
        // Obtiene el tamaño del array de estrategias
        uint256 length = strategies.length;

        // Crea los arrays de info con el tamaño de estrategias seteado
        names = new string[](length);
        apys = new uint256[](length);
        tvls = new uint256[](length);
        targets = new uint256[](length);

        // Recorre el array de estrategias y setea valores en los nuevos arrays
        for (uint256 i = 0; i < length; i++) {
            names[i] = strategies[i].name();
            apys[i] = strategies[i].apy();
            tvls[i] = strategies[i].totalAssets();
            targets[i] = targetAllocation[strategies[i]];
        }
    }

    //* Funciones internas usadas por el resto de metodos del contrato

    /**
     * @notice Calcula targets de allocation para cada estrategia basado en APY
     *         Recuerdo: Target allocation = % del TVL que va a cada estrategia
     * @dev Helper interno usado por shouldRebalance y _calculateTargetAllocation
     * @dev Aplica caps (max 50%, min 10%) y normaliza para que sume 100%
     * @return targets Array con allocation en basis points por estrategia
     */
    function _computeTargets() internal view returns (uint256[] memory targets) {
        // Si no hay estrategias devuelve array vacio
        if (strategies.length == 0) {
            return new uint256[](0);
        }

        // Si hay estrategias crea array para los targets calculados del tamaño de las estrategias
        targets = new uint256[](strategies.length);

        // Suma los APYs de todas las estrategias activas
        uint256 total_apy = 0;

        for (uint256 i = 0; i < strategies.length; i++) {
            total_apy += strategies[i].apy();
        }

        // Si no hay APY (imagina que todas en 0%), distribuye equitativamente el TVL y retorna
        if (total_apy == 0) {
            uint256 equal_share = BASIS_POINTS / strategies.length;

            for (uint256 i = 0; i < strategies.length; i++) {
                targets[i] = equal_share;
            }

            return targets;
        }

        // Este es el escenario normal. Calcula targets basados en APY y aplica caps
        for (uint256 i = 0; i < strategies.length; i++) {
            // Obtiene el APY de la estrategia, y calcula su target sin limites
            uint256 strategy_apy = strategies[i].apy();
            uint256 uncapped_target = (strategy_apy * BASIS_POINTS) / total_apy;

            // Si supera el maximo, su target allocation es el maximo
            if (uncapped_target > max_allocation_per_strategy) {
                targets[i] = max_allocation_per_strategy;
            }
            // Si no llega al minimo, su target allocation es 0
            else if (uncapped_target < min_allocation_threshold) {
                targets[i] = 0;
            }
            // Si esta entre el maximo y el minimo, se queda con el calculado
            else {
                targets[i] = uncapped_target;
            }
        }

        // Normaliza targets para que sumen exactamente BASIS_POINTS (100%)
        uint256 total_targets = 0;
        for (uint256 i = 0; i < strategies.length; i++) {
            total_targets += targets[i];
        }

        // Si no suman BASIS_POINTS, redistribuye proporcionalmente
        if (total_targets > 0 && total_targets != BASIS_POINTS) {
            for (uint256 i = 0; i < strategies.length; i++) {
                targets[i] = (targets[i] * BASIS_POINTS) / total_targets;
            }
        }

        // Devuelve array de targets calculados
        return targets;
    }

    /**
     * @notice Calcula el target allocation para cada estrategia basado en APY
     *         Recuerdo: Target allocation = % del TVL que va a cada estrategia
     * @dev Usa weighted allocation para repartir TVL -> mayor APY = mayor porcentaje
     *      Esta es la funcion que usan el resto de metodos de logica principal del contrato
     * @dev Aplica limites, max 50%, min 10% (por si lo oyes limites = caps)
     */
    function _calculateTargetAllocation() internal {
        // Si no existen estrategias retorna
        if (strategies.length == 0) return;

        // Calcula targets usando funcion interna
        uint256[] memory computed_allocations = _computeTargets();

        // Escribe los targets calculados al storage (el mapping)
        for (uint256 i = 0; i < strategies.length; i++) {
            targetAllocation[strategies[i]] = computed_allocations[i];
        }

        // Emite evento de targets allocations actualizados
        emit TargetAllocationUpdated();
    }
}
