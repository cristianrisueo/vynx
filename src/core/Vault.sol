// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IVault} from "../interfaces/core/IVault.sol";
import {IStrategyManager} from "../interfaces/core/IStrategyManager.sol";

/**
 * @title Vault
 * @author cristianrisueo
 * @notice Vault ERC4626 del protocolo VynX que actua como punto de entrada para los usuarios
 * @dev Gestiona deposits/withdrawals de usuarios, mantiene idle buffer para optimizar gas,
 *      coordina harvest de estrategias y distribuye performance fees entre treasury y founder
 * @dev Extiende ERC4626 (Tokenized Vault Standard) con funcionalidades adicionales:
 *      - Idle buffer management (acumula deposits hasta threshold antes de allocar)
 *      - Performance fees (20% sobre profits, split 80/20 treasury/founder)
 *      - Circuit breakers (minDeposit, maxTVL, pausable)
 */
contract Vault is IVault, ERC4626, Ownable, Pausable {
    //* library attachments

    /**
     * @notice Usa SafeERC20 para todas las operaciones de IERC20 de manera segura
     * @dev Evita errores comunes con tokens legacy o mal implementados
     */
    using SafeERC20 for IERC20;

    /**
     * @notice Usa Math de OpenZeppelin para operaciones matematicas seguras
     * @dev Incluye min, max, average y otras utilidades
     */
    using Math for uint256;

    //* Errores

    /**
     * @notice Error cuando se intenta depositar menos del minimo establecido
     */
    error Vault__DepositBelowMinimum();

    /**
     * @notice Error cuando el depósito excede el TVL maximo permitido
     */
    error Vault__MaxTVLExceeded();

    /**
     * @notice Error se intenta invertir pero el idle buffer no es suficiente
     */
    error Vault__InsufficientIdleBuffer();

    /**
     * @notice Error cuando el performance fee excede el 100%
     */
    error Vault__InvalidPerformanceFee();

    /**
     * @notice Error cuando la suma de splits (treasury + founder) no es exactamente 100%
     */
    error Vault__InvalidFeeSplit();

    /**
     * @notice Error cuando se pasa address(0) como treasury
     */
    error Vault__InvalidTreasuryAddress();

    /**
     * @notice Error cuando se pasa address(0) como founder
     */
    error Vault__InvalidFounderAddress();

    /**
     * @notice Error cuando se pasa address(0) como strategy manager
     */
    error Vault__InvalidStrategyManagerAddress();

    //* Eventos: Se heredan de la interfaz, no es necesario implementarlos

    //* Constantes

    /// @notice Base para calculos de basis points (100% = 10000 basis points)
    uint256 public constant BASIS_POINTS = 10000;

    //* Variables de estado

    /// @notice Direccion del strategy manager que gestiona las estrategias
    address public strategy_manager;

    /// @notice Mapeo de keepers oficiales del protocolo (no reciben incentivo)
    mapping(address => bool) public is_official_keeper;

    /// @notice Direccion del treasury que recibe su parte de performance fees
    address public treasury_address;

    /// @notice Direccion del founder que recibe su parte de performance fees
    address public founder_address;

    /// @notice Balance de assets idle (no asignados a estrategias)
    uint256 public idle_buffer;

    /// @notice Timestamp del ultimo harvest ejecutado
    uint256 public last_harvest;

    /// @notice Profit total (bruto) acumulado desde el inicio del vault
    uint256 public total_harvested;

    //? Por que definirlo aqui y no en el constructor? Es una buena practica, dejamos el
    //? constructor lo mas simple posible para que no haya posibles fallos en deployment

    /// @notice Profit minimo requerido para ejecutar harvest (evita harvests no rentables por gas)
    uint256 public min_profit_for_harvest = 0.1 ether;

    /// @notice Porcentaje de los profits generados que van al keeper externo que ejecute el harvest
    uint256 public keeper_incentive = 100;

    /// @notice Performance fee cobrado sobre profits generados, en basis points (2000 = 20%)
    uint256 public performance_fee = 2000;

    /// @notice Porcentaje del performance fee que va al treasury (8000 = 80%)
    uint256 public treasury_split = 8000;

    /// @notice Porcentaje del performance fee que va al founder (2000 = 20%)
    uint256 public founder_split = 2000;

    /// @notice Deposito minimo permitido (0.01 ETH en wei)
    uint256 public min_deposit = 0.01 ether;

    /// @notice Threshold de idle buffer para ejecutar allocateIdle (10 ETH)
    uint256 public idle_threshold = 10 ether;

    /// @notice TVL maximo permitido como circuit breaker (1000 ETH)
    uint256 public max_tvl = 1000 ether;

    //* Constructor

    /**
     * @notice Constructor del Vault
     * @dev Inicializa el vault ERC4626 con el asset base y setea direcciones criticas
     * @param _asset Direccion del asset subyacente
     * @param _strategyManager Direccion del strategy manager
     * @param _treasury Direccion del treasury
     * @param _founder Direccion del founder
     */
    constructor(address _asset, address _strategyManager, address _treasury, address _founder)
        ERC4626(IERC20(_asset))
        ERC20(string.concat("VynX ", ERC20(_asset).symbol(), " Vault"), string.concat("vx", ERC20(_asset).symbol()))
        Ownable(msg.sender)
    {
        // Comprueba que las direcciones criticas no sean address(0)
        if (_strategyManager == address(0)) revert Vault__InvalidStrategyManagerAddress();
        if (_treasury == address(0)) revert Vault__InvalidTreasuryAddress();
        if (_founder == address(0)) revert Vault__InvalidFounderAddress();

        // Setea las direcciones criticas del protocolo
        strategy_manager = _strategyManager;
        treasury_address = _treasury;
        founder_address = _founder;

        // Inicializa timestamp del ultimo harvest
        last_harvest = block.timestamp;
    }

    //* ERC4626 overrides: deposit, mint, withdraw, redeem y totalAssets con logica custom

    /**
     * @notice Deposita assets en el vault y recibe shares a cambio
     * @dev Override de ERC4626.deposit con Compruebaciones adicionales y gestion de idle buffer
     * @dev Los assets se acumulan en idle_buffer hasta alcanzar idle_threshold, momento en
     *      el cual se invierten en las estrategias
     * @param assets Cantidad de assets a depositar
     * @param receiver Direccion que recibira los shares
     * @return shares Cantidad de shares minteados para el receiver
     */
    function deposit(uint256 assets, address receiver)
        public
        override(ERC4626, IERC4626)
        whenNotPaused
        returns (uint256 shares)
    {
        // Comprueba que el depósito sea mayor que el mínimo y no exceda el TVL max permitido
        if (assets < min_deposit) revert Vault__DepositBelowMinimum();
        if (totalAssets() + assets > max_tvl) revert Vault__MaxTVLExceeded();

        // Calcula shares a mintear (ERC4626 standard)
        shares = previewDeposit(assets);

        // Ejecuta el depósito: transferFrom user -> vault, mint shares
        _deposit(_msgSender(), receiver, assets, shares);

        // Incrementa el idle buffer con los assets depositados
        idle_buffer += assets;

        // Si el idle buffer alcanza el threshold, invierte en las estrategias
        if (idle_buffer >= idle_threshold) {
            _allocateIdle();
        }

        // Emite evento de depósito
        emit Deposited(receiver, assets, shares);
    }

    /**
     * @notice Mintea shares exactos depositando la cantidad necesaria de assets
     * @dev Override de ERC4626.mint con Compruebaciones adicionales
     * @param shares Cantidad de shares a mintear
     * @param receiver Direccion que recibira los shares
     * @return assets Cantidad de assets depositados para mintear esos shares
     */
    function mint(uint256 shares, address receiver)
        public
        override(ERC4626, IERC4626)
        whenNotPaused
        returns (uint256 assets)
    {
        // Calcula assets necesarios para mintear esos shares (ERC4626 standard)
        assets = previewMint(shares);

        // Comprueba que los assets necesarios superen el depósito mínimo y no excedan el TVL permitido
        if (assets < min_deposit) revert Vault__DepositBelowMinimum();
        if (totalAssets() + assets > max_tvl) revert Vault__MaxTVLExceeded();

        // Ejecuta el mint: transferFrom user -> vault, mint shares
        _deposit(_msgSender(), receiver, assets, shares);

        // Incrementa el idle buffer con los assets depositados
        idle_buffer += assets;

        // Si el idle buffer alcanza el threshold, invierte en las estrategias
        if (idle_buffer >= idle_threshold) {
            _allocateIdle();
        }

        // Emite evento de depósito
        emit Deposited(receiver, assets, shares);
    }

    /**
     * @notice Retira assets del vault quemando shares
     * @dev Override de ERC4626.withdraw con logica de retiro desde idle buffer o estrategias
     * @dev Prioriza retirar desde idle buffer (gas efficient). Si no hay suficiente idle,
     *      retira proporcionalmente de estrategias via strategy manager
     * @param assets Cantidad de assets a retirar
     * @param receiver Direccion que recibira los assets
     * @param owner Direccion del owner de los shares a quemar
     * @return shares Cantidad de shares quemados
     */
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override(ERC4626, IERC4626)
        whenNotPaused
        returns (uint256 shares)
    {
        // Calcula shares a quemar para retirar esos assets (ERC4626 standard)
        shares = previewWithdraw(assets);

        // Ejecuta el withdraw: quema shares y retira assets priorizando desde idle buffer
        _withdraw(_msgSender(), receiver, owner, assets, shares);

        // Emite evento de retiro y devuelve las shares quemadas
        emit Withdrawn(receiver, assets, shares);
    }

    /**
     * @notice Quema shares exactos retirando la cantidad correspondiente de assets
     * @dev Override de ERC4626.redeem con logica de retiro desde idle buffer o estrategias
     * @param shares Cantidad de shares a quemar
     * @param receiver Direccion que recibira los assets
     * @param owner Direccion del owner de los shares
     * @return assets Cantidad de assets retirados
     */
    function redeem(uint256 shares, address receiver, address owner)
        public
        override(ERC4626, IERC4626)
        whenNotPaused
        returns (uint256 assets)
    {
        // Calcula assets a retirar por esos shares (ERC4626 standard)
        assets = previewRedeem(shares);

        // Ejecuta el redeem: quema shares y retira assets priorizando desde idle buffer
        _withdraw(_msgSender(), receiver, owner, assets, shares);

        // Emite evento de retiro y devuelve los assets enviados
        emit Withdrawn(receiver, assets, shares);
    }

    /**
     * @notice Devuelve el total de assets bajo gestion del vault
     * @dev Override de ERC4626.totalAssets
     * @dev Suma: idle buffer + assets en estrategias via strategy manager
     * @return total Total de assets gestionados por el vault
     */
    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256 total) {
        total = idle_buffer + IStrategyManager(strategy_manager).totalAssets();
    }

    /**
     * @notice Devuelve el maximo de assets que un usuario puede depositar
     * @dev Override de ERC4626.maxDeposit para respetar el circuit breaker de maxTVL
     * @return maxAssets Maximo de assets depositables antes de alcanzar maxTVL
     */
    function maxDeposit(address) public view override(ERC4626, IERC4626) returns (uint256 maxAssets) {
        if (paused()) return 0;

        uint256 current = totalAssets();
        if (current >= max_tvl) return 0;

        return max_tvl - current;
    }

    /**
     * @notice Devuelve el maximo de shares que un usuario puede mintear
     * @dev Override de ERC4626.maxMint para respetar el circuit breaker de maxTVL
     * @return maxShares Maximo de shares minteables antes de alcanzar maxTVL
     */
    function maxMint(address) public view override(ERC4626, IERC4626) returns (uint256 maxShares) {
        if (paused()) return 0;

        uint256 current = totalAssets();
        if (current >= max_tvl) return 0;

        return convertToShares(max_tvl - current);
    }

    //* Funciones principales: harvest y allocateIdle (publicas, sin restricciones)

    /**
     * @notice Cosecha rewards de todas las estrategias y distribuye performance fees
     * @dev Funcion publica: cualquiera puede llamarla (keepers, bots, usuarios)
     * @dev Los keepers oficiales no reciben incentivo. Los externos si (keeper_incentive)
     * @dev Solo ejecuta si profit >= min_profit_for_harvest (evita harvests no rentables)
     * @dev Flujo:
     *      - strategyManager.harvest() ->
     *      - valida profit minimo ->
     *      - paga incentivo al keeper externo ->
     *      - calcula performance fee ->
     *      - distribuye fees ->
     *      - actualiza contadores (last_harvest, total_harvested)
     * @return profit Profit total cosechado antes de deducir fees e incentivos
     */
    function harvest() external whenNotPaused returns (uint256 profit) {
        // Llama al strategy manager para cosechar profits de todas las estrategias
        profit = IStrategyManager(strategy_manager).harvest();

        // Si no hay profit o no alcanza el minimo, no ejecuta
        if (profit < min_profit_for_harvest) return 0;

        // Calcula y paga incentivo solo si el caller no es keeper oficial
        uint256 keeper_reward = 0;
        if (!is_official_keeper[msg.sender]) {
            // Calcula el keeper reward
            keeper_reward = (profit * keeper_incentive) / BASIS_POINTS;

            // A no ser que keeper_incentive = 0 siempre entra, pero programación defensiva
            // Intenta pagar primero del idle buffer, si no hay suficiente el restante lo
            // saca de las estrategias
            if (keeper_reward > 0) {
                if (keeper_reward > idle_buffer) {
                    uint256 to_withdraw = keeper_reward - idle_buffer;
                    IStrategyManager(strategy_manager).withdrawTo(to_withdraw, address(this));
                } else {
                    idle_buffer -= keeper_reward;
                }

                // Trasnfiere al keeper su fee por hacer la llamada
                IERC20(asset()).safeTransfer(msg.sender, keeper_reward);
            }
        }

        // Calcula performance fee sobre el profit neto (despues de keeper reward)
        uint256 net_profit = profit - keeper_reward;
        uint256 perf_fee = (net_profit * performance_fee) / BASIS_POINTS;

        // Distribuye fees entre treasury y founder
        _distributePerformanceFee(perf_fee);

        // Actualiza contadores
        last_harvest = block.timestamp;
        total_harvested += profit;

        // Emite evento de cosechado de profits
        emit Harvested(profit, perf_fee, block.timestamp);
    }

    /**
     * @notice Asigna assets idle a estrategias cuando se alcanza el threshold
     * @dev Funcion publica: cualquiera puede llamarla cuando idle >= threshold
     * @dev Solo ejecuta si hay suficiente idle buffer, evitando gas waste en allocations pequeños
     */
    function allocateIdle() external whenNotPaused {
        if (idle_buffer < idle_threshold) revert Vault__InsufficientIdleBuffer();
        _allocateIdle();
    }

    //* Funciones administrativas: Setters de parametros del protocolo (onlyOwner)

    //? Antipattern poner el evento antes de setear las variables pero nos ahorramos una variable
    //? temporal = menos gas. Lo vas a ver en casi todos

    /**
     * @notice Actualiza el performance fee
     * @param new_fee Nuevo performance fee en basis points
     */
    function setPerformanceFee(uint256 new_fee) external onlyOwner {
        // Comprueba que el fee no exceda 100% (max = BASIS_POINTS)
        if (new_fee > BASIS_POINTS) revert Vault__InvalidPerformanceFee();

        // Emite evento de cambio con fee anterior y nuevo
        emit PerformanceFeeUpdated(performance_fee, new_fee);

        // Actualiza el performance fee
        performance_fee = new_fee;
    }

    /**
     * @notice Actualiza el split de fees entre treasury y founder
     * @param new_treasury Nuevo porcentaje para treasury en basis points
     * @param new_founder Nuevo porcentaje para founder en basis points
     */
    function setFeeSplit(uint256 new_treasury, uint256 new_founder) external onlyOwner {
        // Comprueba que la suma sea exactamente 100% (BASIS_POINTS)
        if (new_treasury + new_founder != BASIS_POINTS) revert Vault__InvalidFeeSplit();

        // Actualiza los splits
        treasury_split = new_treasury;
        founder_split = new_founder;

        // Emite evento con nuevos splits
        emit FeeSplitUpdated(new_treasury, new_founder);
    }

    /**
     * @notice Actualiza el deposito minimo
     * @param new_min Nuevo deposito minimo en assets
     */
    function setMinDeposit(uint256 new_min) external onlyOwner {
        // Emite evento con minimo anterior y nuevo
        emit MinDepositUpdated(min_deposit, new_min);

        // Actualiza el minimo
        min_deposit = new_min;
    }

    /**
     * @notice Actualiza el idle threshold
     * @param new_threshold Nuevo threshold en assets
     */
    function setIdleThreshold(uint256 new_threshold) external onlyOwner {
        // Emite evento con threshold anterior y nuevo
        emit IdleThresholdUpdated(idle_threshold, new_threshold);

        // Actualiza el threshold
        idle_threshold = new_threshold;
    }

    /**
     * @notice Actualiza el TVL maximo
     * @param new_max Nuevo TVL maximo en assets
     */
    function setMaxTVL(uint256 new_max) external onlyOwner {
        // Emite evento con maximo anterior y nuevo
        emit MaxTVLUpdated(max_tvl, new_max);

        // Actualiza el maximo
        max_tvl = new_max;
    }

    /**
     * @notice Actualiza la direccion del treasury
     * @param new_treasury Nueva direccion del treasury
     */
    function setTreasury(address new_treasury) external onlyOwner {
        // Comprueba que la nueva direccion no sea address(0)
        if (new_treasury == address(0)) revert Vault__InvalidTreasuryAddress();

        // Emite evento con direccion anterior y nueva
        emit TreasuryUpdated(treasury_address, new_treasury);

        // Actualiza la direccion
        treasury_address = new_treasury;
    }

    /**
     * @notice Actualiza la direccion del founder
     * @param new_founder Nueva direccion del founder
     */
    function setFounder(address new_founder) external onlyOwner {
        // Comprueba que la nueva direccion no sea address(0)
        if (new_founder == address(0)) revert Vault__InvalidFounderAddress();

        // Emite evento con direccion anterior y nueva
        emit FounderUpdated(founder_address, new_founder);

        // Actualiza la direccion
        founder_address = new_founder;
    }

    /**
     * @notice Actualiza la direccion del strategy manager
     * @param new_manager Nueva direccion del strategy manager
     */
    function setStrategyManager(address new_manager) external onlyOwner {
        // Comprueba que la nueva direccion no sea address(0)
        if (new_manager == address(0)) revert Vault__InvalidStrategyManagerAddress();

        // Emite evento con nueva direccion
        emit StrategyManagerUpdated(new_manager);

        // Actualiza la direccion
        strategy_manager = new_manager;
    }

    /**
     * @notice Añade o remueve un keeper oficial
     * @param keeper Direccion del keeper
     * @param status True para añadir, false para remover
     */
    function setOfficialKeeper(address keeper, bool status) external onlyOwner {
        is_official_keeper[keeper] = status;
        emit OfficialKeeperUpdated(keeper, status);
    }

    /**
     * @notice Actualiza el profit minimo requerido para ejecutar harvest
     * @param new_min Nuevo profit minimo en assets
     */
    function setMinProfitForHarvest(uint256 new_min) external onlyOwner {
        // Emite evento con minimo anterior y nuevo
        emit MinProfitForHarvestUpdated(min_profit_for_harvest, new_min);

        // Actualiza el profit minimo
        min_profit_for_harvest = new_min;
    }

    /**
     * @notice Actualiza el incentivo para keepers externos
     * @param new_incentive Nuevo incentivo en basis points
     */
    function setKeeperIncentive(uint256 new_incentive) external onlyOwner {
        // Comprueba que el incentivo no exceda 100% (max = BASIS_POINTS)
        if (new_incentive > BASIS_POINTS) revert Vault__InvalidPerformanceFee();

        // Emite evento con incentivo anterior y nuevo
        emit KeeperIncentiveUpdated(keeper_incentive, new_incentive);

        // Actualiza el incentivo
        keeper_incentive = new_incentive;
    }

    //* Funciones administrativas: Emergency stop y resume del protocolo (onlyOwner)

    /**
     * @notice Pausa el vault (emergency stop)
     * @dev Solo el owner puede pausar. Bloquea deposits/withdrawals/harvest/allocate
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Despausa el vault
     * @dev Solo el owner puede despausar
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    //* Funciones de consulta: Getters de parametros y estado del protocolo

    /**
     * @notice Devuelve el performance fee actual
     * @return fee_bps Performance fee en basis points
     */
    function performanceFee() external view returns (uint256 fee_bps) {
        return performance_fee;
    }

    /**
     * @notice Devuelve el treasury split actual
     * @return split_bps Treasury split en basis points
     */
    function treasurySplit() external view returns (uint256 split_bps) {
        return treasury_split;
    }

    /**
     * @notice Devuelve el founder split actual
     * @return split_bps Founder split en basis points
     */
    function founderSplit() external view returns (uint256 split_bps) {
        return founder_split;
    }

    /**
     * @notice Devuelve el deposito minimo actual
     * @return min_amount Deposito minimo en assets
     */
    function minDeposit() external view returns (uint256 min_amount) {
        return min_deposit;
    }

    /**
     * @notice Devuelve el idle threshold actual
     * @return threshold Idle threshold en assets
     */
    function idleThreshold() external view returns (uint256 threshold) {
        return idle_threshold;
    }

    /**
     * @notice Devuelve el TVL maximo actual
     * @return max_tvl TVL maximo en assets
     */
    function maxTVL() external view returns (uint256) {
        return max_tvl;
    }

    /**
     * @notice Devuelve la direccion del treasury
     * @return treasury_address Direccion del treasury
     */
    function treasury() external view returns (address) {
        return treasury_address;
    }

    /**
     * @notice Devuelve la direccion del founder
     * @return founder_address Direccion del founder
     */
    function founder() external view returns (address) {
        return founder_address;
    }

    /**
     * @notice Devuelve la direccion del strategy manager
     * @return manager_address Direccion del strategy manager
     */
    function strategyManager() external view returns (address) {
        return strategy_manager;
    }

    /**
     * @notice Devuelve el balance de idle buffer actual
     * @return idle_balance Balance de assets idle
     */
    function idleBuffer() external view returns (uint256) {
        return idle_buffer;
    }

    /**
     * @notice Devuelve el timestamp del ultimo harvest
     * @return timestamp Timestamp del ultimo harvest
     */
    function lastHarvest() external view returns (uint256 timestamp) {
        return last_harvest;
    }

    /**
     * @notice Devuelve el profit total acumulado
     * @return total_profit Profit total desde el inicio
     */
    function totalHarvested() external view returns (uint256 total_profit) {
        return total_harvested;
    }

    /**
     * @notice Devuelve el profit minimo requerido para ejecutar harvest
     * @return min_profit Profit minimo en assets
     */
    function minProfitForHarvest() external view returns (uint256 min_profit) {
        return min_profit_for_harvest;
    }

    /**
     * @notice Devuelve el incentivo para keepers externos
     * @return incentive_bps Incentivo en basis points
     */
    function keeperIncentive() external view returns (uint256 incentive_bps) {
        return keeper_incentive;
    }

    //* Funciones internas: Helpers para deposit/withdraw y fee distribution

    /**
     * @notice Retira assets del vault desde idle buffer o estrategias
     * @dev Override de ERC4626._withdraw para implementar logica custom de retiro
     * @dev Prioriza retirar desde idle buffer. Si no hay suficiente, retira de estrategias
     * @param caller Direccion que llama la funcion (msg.sender)
     * @param receiver Direccion que recibira los assets
     * @param owner Direccion del owner de los shares
     * @param assets Cantidad de assets a retirar
     * @param shares Cantidad de shares a quemar
     */
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        // Si caller != owner, reduce allowance (ERC4626 standard)
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        // Quema los shares del owner
        _burn(owner, shares);

        // Determina de donde retirar: idle buffer primero (gas efficient)
        uint256 from_idle = assets.min(idle_buffer);
        uint256 from_strategies = assets - from_idle;

        // Retira desde idle buffer si hay disponible
        if (from_idle > 0) {
            idle_buffer -= from_idle;
        }

        // Si no hay suficiente en el idle buffer, retira proporcionalmente de estrategias
        if (from_strategies > 0) {
            IStrategyManager(strategy_manager).withdrawTo(from_strategies, address(this));
        }

        // Obtiene el balance del vault que ya tiene todo el idle buffer + lo extraido de las
        // estrategias si era neesario
        uint256 balance = IERC20(asset()).balanceOf(address(this));

        // Calcula la cantidad a transferir al usuario, el mínimo entre el balance del vault y
        // la cantidad a retirar por el usuario. Para asegurar que el vault no es insolvente
        uint256 to_transfer = assets.min(balance);

        /**
         * Comprueba que la cantidad a transferir esté menos de 20 wei por debajo de lo esperado
         *
         * Los protocolos externos (Aave, Compound...) redondean a la baja perdiendo ~1-2 wei por
         * operación. Actualmente tenemos 2 estrategias, pero en el plan es ir aumentándolas
         * Toleramos hasta 20 wei (2 wei × ~10 estrategias futuras = margen conservador)
         *
         * Si la diferencia excede 20 wei, tenemos un problema de accounting serio: el vault
         * no tiene suficientes assets para redimir las shares emitidas (insolvencia = prison bars)
         *
         * Costo para el usuario: $0.00000000000005 con ETH a $2,500 (una mierda)
         */
        if (to_transfer < assets) {
            require(assets - to_transfer < 20, "Excessive rounding");
        }

        // Transfiere los assets al receiver
        IERC20(asset()).safeTransfer(receiver, to_transfer);
    }

    /**
     * @notice Asigna assets idle a estrategias via strategy manager
     * @dev Funcion interna llamada por deposit/mint cuando idle >= threshold o por allocateIdle()
     */
    function _allocateIdle() internal {
        // Guarda la cantidad a depositar en las estrategias y resetea el idle buffer
        uint256 to_allocate = idle_buffer;
        idle_buffer = 0;

        // Transfiere assets idle al strategy manager
        IERC20(asset()).safeTransfer(strategy_manager, to_allocate);

        // Llama al strategy manager para distribuir entre estrategias
        IStrategyManager(strategy_manager).allocate(to_allocate);

        // Emite evento de allocation de idle assets realizada
        emit IdleAllocated(to_allocate);
    }

    /**
     * @notice Distribuye performance fees entre treasury y founder
     * @dev Treasury recibe shares (auto-compound), founder recibe assets (liquid)
     * @param perf_fee Cantidad total de performance fee a distribuir
     */
    function _distributePerformanceFee(uint256 perf_fee) internal {
        // Calcula las cantidades para el treasury y el founder
        uint256 treasury_amount = (perf_fee * treasury_split) / BASIS_POINTS;
        uint256 founder_amount = (perf_fee * founder_split) / BASIS_POINTS;

        // Treasury recibe shares (auto-compound, mejora el crecimiento del protocolo)
        // Convierte assets a shares y las mintea al address del treasury
        uint256 treasury_shares = convertToShares(treasury_amount);
        _mint(treasury_address, treasury_shares);

        // Founder recibe el underlying asset directamente (de algo hay que vivir)
        // Intenta retirar primero del idle buffer y si no hay suficiente, el restante de las estrategias
        if (founder_amount > idle_buffer) {
            uint256 to_withdraw = founder_amount - idle_buffer;
            IStrategyManager(strategy_manager).withdrawTo(to_withdraw, address(this));
        } else {
            idle_buffer -= founder_amount;
        }

        // Transfiere assets al founder
        IERC20(asset()).safeTransfer(founder_address, founder_amount);

        // Emite evento de distribucion de fees
        emit PerformanceFeeDistributed(treasury_amount, founder_amount);
    }
}
