// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWETH} from "@aave/contracts/misc/interfaces/IWETH.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IStrategy} from "../interfaces/strategies/IStrategy.sol";
import {ILido} from "../interfaces/strategies/lido/ILido.sol";
import {ICurvePool} from "../interfaces/strategies/curve/ICurvePool.sol";
import {ICurveGauge} from "../interfaces/strategies/curve/ICurveGauge.sol";

/**
 * @title CurveStrategy
 * @author cristianrisueo
 * @notice Estrategia que provee liquidez al pool stETH/ETH de Curve y stakea LP tokens en el gauge
 * @dev Implementa IStrategy para integración con StrategyManager
 *
 * @dev Combina dos fuentes de yield:
 *      - Trading fees del pool Curve stETH/ETH
 *      - Rewards en CRV del gauge (reinvertidos via harvest)
 *
 * @dev Flujo depósito:  WETH → ETH (IWETH.withdraw) → stETH (Lido.submit) →
 *                       add_liquidity([0, stETH]) → LP tokens → gauge.deposit
 *
 * @dev Flujo retiro:    gauge.withdraw → remove_liquidity_one_coin (index 0 = ETH nativo) →
 *                       WETH (IWETH.deposit) → manager
 *
 * @dev Flujo harvest:   gauge.claim_rewards → CRV → Uniswap (CRV -> WETH) →
 *                       ETH → stETH (Lido) → add_liquidity → LP Tokens → gauge.deposit
 */
contract CurveStrategy is IStrategy {
    //* library attachments

    /**
     * @notice Usa SafeERC20 para todas las operaciones de IERC20 de manera segura
     * @dev Evita errores comunes con tokens legacy o mal implementados
     */
    using SafeERC20 for IERC20;

    //* Errores

    /**
     * @notice Error cuando solo el strategy manager puede llamar
     */
    error CurveStrategy__OnlyManager();

    /**
     * @notice Error cuando se intenta depositar o retirar con cantidad cero
     */
    error CurveStrategy__ZeroAmount();

    /**
     * @notice Error cuando falla el swap de CRV a WETH en Uniswap V3 durante harvest
     */
    error CurveStrategy__SwapFailed();

    //* Constantes

    /// @notice Base para cálculos de basis points (10000 = 100%)
    uint256 private constant BASIS_POINTS = 10000;

    /// @notice Slippage máximo permitido en operaciones de liquidez y swaps en bps (100 = 1%)
    uint256 private constant MAX_SLIPPAGE_BPS = 100;

    /**
     * @notice APY histórico de Curve stETH/ETH en basis points (600 = 6%)
     * @dev Combina trading fees (~1-2%) + rewards en CRV del gauge (~4%)
     *      Hardcodeado ya que el APY real varía con el volumen del pool y el precio de CRV
     */
    uint256 private constant CURVE_APY = 600;

    //* Variables de estado

    /// @notice Dirección del StrategyManager autorizado
    address public immutable manager;

    /// @notice Dirección del asset subyacente (WETH)
    address private immutable asset_address;

    /**
     * @notice Instancia del contrato stETH de Lido
     * @dev submit() acepta ETH vía msg.value y devuelve stETH
     */
    ILido private immutable lido;

    /**
     * @notice Instancia del pool stETH/ETH de Curve
     * @dev Estructura del pool: index 0 = ETH (nativo), index 1 = stETH
     */
    ICurvePool private immutable curve_pool;

    /// @notice Instancia del gauge de Curve para stakear LP tokens y recibir CRV
    ICurveGauge private immutable gauge;

    /**
     * @notice LP token del pool stETH/ETH de Curve
     * @dev Dirección: 0x06325440D014e39736583c165C2963BA99fAf14E
     */
    IERC20 private immutable lp_token;

    /// @notice Token de rewards CRV de Curve
    IERC20 private immutable crv_token;

    /// @notice Instancia del contrato WETH para convertir WETH ↔ ETH
    IWETH private immutable weth;

    /// @notice Router de Uniswap V3 para swaps de CRV → WETH en harvest
    ISwapRouter private immutable uniswap_router;

    /// @notice Fee tier del pool CRV/WETH en Uniswap V3
    uint24 private immutable pool_fee;

    //* Modificadores

    /**
     * @notice Solo permite llamadas del StrategyManager
     */
    modifier onlyManager() {
        if (msg.sender != manager) revert CurveStrategy__OnlyManager();
        _;
    }

    //* Constructor

    /**
     * @notice Constructor de CurveStrategy
     * @dev Inicializa la estrategia con los contratos de Lido y Curve, y aprueba los contratos necesarios
     * @param _manager Dirección del StrategyManager
     * @param _lido Dirección del contrato stETH de Lido
     * @param _curve_pool Dirección del pool stETH/ETH de Curve
     * @param _gauge Dirección del gauge de Curve
     * @param _lp_token Dirección del LP token del pool Curve
     * @param _crv_token Dirección del token CRV
     * @param _weth Dirección del contrato WETH
     * @param _uniswap_router Dirección del SwapRouter de Uniswap V3
     * @param _pool_fee Fee tier del pool CRV/WETH en Uniswap V3
     */
    constructor(
        address _manager,
        address _lido,
        address _curve_pool,
        address _gauge,
        address _lp_token,
        address _crv_token,
        address _weth,
        address _uniswap_router,
        uint24 _pool_fee
    ) {
        // Asigna addresses e inicializa contratos
        manager = _manager;
        asset_address = _weth;
        lido = ILido(_lido);
        curve_pool = ICurvePool(_curve_pool);
        gauge = ICurveGauge(_gauge);
        lp_token = IERC20(_lp_token);
        crv_token = IERC20(_crv_token);
        weth = IWETH(_weth);
        uniswap_router = ISwapRouter(_uniswap_router);
        pool_fee = _pool_fee;

        // Aprueba el pool de Curve para mover stETH durante los depósitos y el harvest
        IERC20(_lido).forceApprove(_curve_pool, type(uint256).max);

        // Aprueba el gauge para mover LP tokens durante los depósitos y el harvest
        IERC20(_lp_token).forceApprove(_gauge, type(uint256).max);

        // Aprueba Uniswap Router para mover CRV durante el harvest
        IERC20(_crv_token).forceApprove(_uniswap_router, type(uint256).max);
    }

    //* Funciones especiales

    /**
     * @notice Acepta ETH de WETH.withdraw() (depósito/harvest) y del swap stETH a ETH (retiro)
     */
    receive() external payable {}

    //* Funciones principales

    /**
     * @notice Deposita assets en el pool stETH/ETH de Curve y stakea LP tokens en el gauge
     * @dev Solo puede ser llamado por el StrategyManager
     * @dev Asume que los assets ya fueron transferidos a este contrato desde StrategyManager
     * @param assets Cantidad de WETH a depositar
     * @return shares Cantidad de LP tokens stakeados en el gauge (medida via balance diff)
     */
    function deposit(uint256 assets) external onlyManager returns (uint256 shares) {
        // Comprueba que la cantidad a depositar no sea 0
        if (assets == 0) revert CurveStrategy__ZeroAmount();

        // Convierte WETH a ETH. El ETH se recibe en el receive() de este contrato
        weth.withdraw(assets);

        // Snapshot del balance de stETH antes de stakear en Lido
        uint256 steth_before = lido.balanceOf(address(this));

        // Stakea ETH en Lido. submit() acepta ETH vía msg.value y devuelve stETH al contrato
        lido.submit{value: assets}(address(0));

        // Calcula la cantidad exacta de stETH recibida (balance actual - anterior)
        uint256 steth_received = lido.balanceOf(address(this)) - steth_before;

        // Calcula el mínimo de LP tokens esperados usando el virtual price de curve (protección slippage)
        uint256 virtual_price = curve_pool.get_virtual_price();
        uint256 min_lp = (steth_received * 1e18 / virtual_price) * (BASIS_POINTS - MAX_SLIPPAGE_BPS) / BASIS_POINTS;

        // Snapshot del balance de LP tokens antes del add_liquidity
        uint256 lp_before = lp_token.balanceOf(address(this));

        // Añade liquidez al pool solo con stETH (index 1). No añadimos ETH (amounts[0] = 0)
        // Especifica la cantidad mínima de LP tokens esperados
        uint256[2] memory amounts = [uint256(0), steth_received];
        curve_pool.add_liquidity(amounts, min_lp);

        // Calcula la cantidad exacta de LP tokens recibida (balance actual - anterior)
        uint256 lp_received = lp_token.balanceOf(address(this)) - lp_before;

        // Stakea los LP tokens en el gauge para empezar a recibir rewards en CRV
        gauge.deposit(lp_received);

        // Retorna assets depositados y emite evento
        shares = assets;
        emit Deposited(msg.sender, assets, shares);
    }

    /**
     * @notice Retira assets del pool Curve unstakeando LP tokens y removiendo liquidez
     * @dev Solo puede ser llamado por el StrategyManager
     * @dev Flujo: gauge.withdraw → remove_liquidity_one_coin(index 0 = ETH nativo) → WETH
     * @param assets Cantidad de WETH a retirar
     * @return actual_withdrawn WETH realmente recibido tras el proceso
     */
    function withdraw(uint256 assets) external onlyManager returns (uint256 actual_withdrawn) {
        // Comprueba que la cantidad a retirar no sea 0
        if (assets == 0) revert CurveStrategy__ZeroAmount();

        // Calcula la cantidad de LP tokens necesaria para obtener `assets` en WETH
        // Añade el margen de slippage para asegurar suficiente cobertura
        uint256 virtual_price = curve_pool.get_virtual_price();
        uint256 lp_needed = (assets * 1e18 * (BASIS_POINTS + MAX_SLIPPAGE_BPS)) / (virtual_price * BASIS_POINTS);

        // Limita lp_needed al balance real stakeado en el gauge para no superar lo disponible
        uint256 gauge_balance = gauge.balanceOf(address(this));
        if (lp_needed > gauge_balance) {
            lp_needed = gauge_balance;
        }

        // Unstakea LP tokens del gauge: los LP tokens vuelven a este contrato
        gauge.withdraw(lp_needed);

        // Calcula la cantidad mínima de ETH que se quiere recibir para prevenir slippage
        uint256 min_eth = (assets * (BASIS_POINTS - MAX_SLIPPAGE_BPS)) / BASIS_POINTS;

        // Retira liquidez directamente en ETH nativo. El ETH recibido se envía a este contrato vía receive()
        uint256 eth_received = curve_pool.remove_liquidity_one_coin(lp_needed, int128(0), min_eth);

        // Convierte ETH a WETH para devolver al StrategyManager
        weth.deposit{value: eth_received}();

        // Transfiere WETH al manager, emite evento de retiro y devuelve la cantidad retirada
        actual_withdrawn = eth_received;
        IERC20(asset_address).safeTransfer(msg.sender, actual_withdrawn);

        emit Withdrawn(msg.sender, actual_withdrawn, assets);
    }

    /**
     * @notice Cosecha rewards CRV del gauge, los swapea a WETH y reinvierte en el pool
     * @dev Solo puede ser llamado por el StrategyManager
     * @dev Reclama CRV, swap CRV → WETH via Uniswap, convierte a stETH, añade liquidez y stakea de nuevo
     * @return profit Cantidad de WETH equivalente obtenido en el swap de CRV (antes de reinvertir)
     */
    function harvest() external onlyManager returns (uint256 profit) {
        // Reclama los rewards CRV acumulados en el gauge para este contrato
        gauge.claim_rewards(address(this));

        // Obtiene el balance de CRV del contrato
        uint256 crv_balance = crv_token.balanceOf(address(this));

        // Si no hay CRV que reclamar, emite evento y retorna 0
        if (crv_balance == 0) {
            emit Harvested(msg.sender, 0);
            return 0;
        }

        // Construye los parámetros del swap CRV → WETH en Uniswap V3
        // amountOutMinimum = 0: sin protección de precio. CRV y WETH tienen precios distintos
        // y calcular el mínimo sin oracle llevaría a un valor sin sentido que haría revertir siempre
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(crv_token), // Token A (CRV)
            tokenOut: asset_address, // Token B (WETH)
            fee: pool_fee, // Fee tier del pool CRV/WETH
            recipient: address(this), // Address que recibe el swap (este contrato)
            deadline: block.timestamp, // A ejecutar en este bloque
            amountIn: crv_balance, // Cantidad de CRV a swapear
            amountOutMinimum: 0, // Sin mínimo: no hay oracle para calcular precio CRV/WETH
            sqrtPriceLimitX96: 0 // Sin límite de precio
        });

        // Realiza el swap CRV → WETH. En caso de error revierte
        uint256 weth_received;
        try uniswap_router.exactInputSingle(params) returns (uint256 weth_out) {
            weth_received = weth_out;
        } catch {
            revert CurveStrategy__SwapFailed();
        }

        // Registra el profit antes de reinvertir (el WETH obtenido del swap)
        profit = weth_received;

        // Convierte WETH a ETH para stakear en Lido. El ETH se recibe en receive()
        weth.withdraw(weth_received);

        // Snapshot del balance de stETH antes del stake para calcular el stETH exacto recibido
        uint256 steth_before = lido.balanceOf(address(this));

        // Stakea ETH en Lido para obtener stETH
        lido.submit{value: weth_received}(address(0));

        // Calcula la cantidad exacta de stETH recibida via diferencia de balances
        uint256 steth_received = lido.balanceOf(address(this)) - steth_before;

        // Calcula mínimo LP esperado del reinvest usando virtual price
        uint256 virtual_price = curve_pool.get_virtual_price();
        uint256 min_lp = (steth_received * 1e18 / virtual_price) * (BASIS_POINTS - MAX_SLIPPAGE_BPS) / BASIS_POINTS;

        // Snapshot del balance de LP tokens antes del add_liquidity
        uint256 lp_before = lp_token.balanceOf(address(this));

        // Añade stETH al pool de Curve como liquidez (index 1 = stETH)
        uint256[2] memory amounts = [uint256(0), steth_received];
        curve_pool.add_liquidity(amounts, min_lp);

        // Calcula LP tokens nuevos recibidos y los stakea en el gauge para seguir acumulando rewards
        uint256 new_lp = lp_token.balanceOf(address(this)) - lp_before;
        gauge.deposit(new_lp);

        // Emite evento de harvest con el profit obtenido y devuelve el profit obtenido
        emit Harvested(msg.sender, profit);
    }

    //* Funciones de consulta

    /**
     * @notice Devuelve el total de assets bajo gestión en WETH
     * @dev Calcula el valor de los LP tokens stakeados en el gauge usando el virtual price
     *      El virtual price crece con el tiempo a medida que el pool acumula trading fees
     * @dev total = lp_balance * virtual_price / 1e18
     * @return total Valor total en WETH equivalente
     */
    function totalAssets() external view returns (uint256 total) {
        uint256 lp_balance = gauge.balanceOf(address(this));
        uint256 virtual_price = curve_pool.get_virtual_price();

        return (lp_balance * virtual_price) / 1e18;
    }

    /**
     * @notice Devuelve el APY histórico de Curve stETH/ETH (hardcodeado)
     * @dev Trading fees + CRV rewards. El yield real varía con el volumen y el precio de CRV
     * @return apy_basis_points APY en basis points (600 = 6%)
     */
    function apy() external pure returns (uint256 apy_basis_points) {
        return CURVE_APY;
    }

    /**
     * @notice Devuelve el nombre de la estrategia
     * @return strategy_name Nombre descriptivo de la estrategia
     */
    function name() external pure returns (string memory strategy_name) {
        return "Curve stETH/ETH Strategy";
    }

    /**
     * @notice Devuelve la dirección del asset subyacente
     * @return Dirección de WETH
     */
    function asset() external view returns (address) {
        return asset_address;
    }

    /**
     * @notice Devuelve el balance de LP tokens stakeados en el gauge
     * @dev Útil para debugging y comprobaciones off-chain
     * @return balance Cantidad de LP tokens stakeados en el gauge
     */
    function lpBalance() external view returns (uint256 balance) {
        return gauge.balanceOf(address(this));
    }
}
