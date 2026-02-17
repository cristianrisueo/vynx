// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IWETH} from "@aave/contracts/misc/interfaces/IWETH.sol";
import {IStrategy} from "../interfaces/strategies/IStrategy.sol";
import {IWstETH} from "../interfaces/strategies/lido/IWstETH.sol";

/**
 * @title LidoStrategy
 * @author cristianrisueo
 * @notice Estrategia que deposita assets en Lido (liquidity staking) y recibe wstETH (wrap. stakingETH)
 * @dev Implementa IStrategy para integración con StrategyManager
 *
 * @dev wstETH auto incrementea yield via exchange rate creciente, sin necesidad de harvest manual
 *      No hay rewards que reclamar ni swapear, harvest() de lido siempre devuelve 0
 *
 * @dev Flujo de depósito: WETH → ETH (IWETH.withdraw) → wstETH (wstETH.receive)
 * @dev Flujo de retiro: wstETH → WETH directo via swap en Uniswap V3 wstETH/WETH pool
 */
contract LidoStrategy is IStrategy {
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
    error LidoStrategy__OnlyManager();

    /**
     * @notice Error cuando se intenta depositar o retirar con cantidad cero
     */
    error LidoStrategy__ZeroAmount();

    /**
     * @notice Error cuando falla el envío de ETH al contrato wstETH para stakear
     */
    error LidoStrategy__WrapFailed();

    /**
     * @notice Error cuando falla el swap de wstETH a WETH en Uniswap V3
     */
    error LidoStrategy__UnwrapFailed();

    //* Constantes

    /// @notice Base para cálculos de basis points (10000 = 100%)
    uint256 private constant BASIS_POINTS = 10000;

    /// @notice Slippage máximo permitido en swaps en bps (100 = 1%)
    uint256 private constant MAX_SLIPPAGE_BPS = 100;

    /**
     * @notice APY histórico de Lido en basis points (400 = 4%)
     * @dev Hardcodeado ya que Lido no expone un oracle de APY on-chain de forma simple
     *      Lido APY histórico: ~3.5-4.5%
     */
    uint256 private constant LIDO_APY = 400;

    //* Variables de estado

    /// @notice Dirección del StrategyManager autorizado
    address public immutable manager;

    /**
     * @notice Instancia del contrato wstETH de Lido
     * @dev Su receive() acepta ETH y devuelve wstETH stakeando internamente con Lido
     */
    IWstETH private immutable wst_eth;

    /**
     * @notice Instancia del contrato WETH para convertir WETH ↔ ETH (wraps/unwraps)
     * @dev WETH.withdraw() convierte WETH → ETH (ETH se recibe en el receive() de este contrato)
     */
    IWETH private immutable weth;

    /// @notice Dirección del asset subyacente (WETH)
    address private immutable asset_address;

    /// @notice Instancia del router de Uniswap v3 para swaps
    ISwapRouter private immutable uniswap_router;

    /**
     * @notice Fee tier del pool wstETH/WETH en Uniswap V3
     * @dev El pool principal wstETH/WETH en mainnet usa el tier 500 (0.05%)
     */
    uint24 private immutable pool_fee;

    //* Modificadores

    /**
     * @notice Solo permite llamadas del StrategyManager
     */
    modifier onlyManager() {
        if (msg.sender != manager) revert LidoStrategy__OnlyManager();
        _;
    }

    //* Constructor

    /**
     * @notice Constructor de LidoStrategy
     * @dev Inicializa la estrategia con Lido y aprueba el router de Uniswap para retirar
     * @param _manager Dirección del StrategyManager
     * @param _wst_eth Dirección del contrato wstETH de Lido
     * @param _weth Dirección del contrato WETH
     * @param _uniswap_router Dirección del SwapRouter de Uniswap V3
     * @param _pool_fee Fee tier del pool wstETH/WETH en Uniswap (ej: 500 = 0.05%)
     */
    constructor(address _manager, address _wst_eth, address _weth, address _uniswap_router, uint24 _pool_fee) {
        // Asigna addresses, inicializa contratos y establece el fee tier de UV3
        manager = _manager;
        asset_address = _weth;
        wst_eth = IWstETH(_wst_eth);
        weth = IWETH(_weth);
        uniswap_router = ISwapRouter(_uniswap_router);
        pool_fee = _pool_fee;

        // Aprueba el router de Uniswap para mover wstETH de este contrato durante los retiros
        IERC20(_wst_eth).forceApprove(_uniswap_router, type(uint256).max);
    }

    //* Funciones especiales

    /**
     * @notice Acepta ETH recibido de WETH.withdraw() antes de depositarlo en Lido
     * @dev Lido recibe ETH, pero el underlying asset del protocolo es WETH. Solución: Unwrappear
     */
    receive() external payable {}

    //* Funciones principales

    /**
     * @notice Deposita assets en Lido y recibe wstETH que auto-acumula yield
     * @dev Solo puede ser llamado por el StrategyManager
     * @dev Asume que los assets ya fueron transferidos a este contrato desde StrategyManager
     * @param assets Cantidad de WETH a depositar
     * @return shares Cantidad exacta de wstETH recibida (medida via balance diff)
     */
    function deposit(uint256 assets) external onlyManager returns (uint256 shares) {
        // Comprueba que la cantidad a depositar no sea 0
        if (assets == 0) revert LidoStrategy__ZeroAmount();

        // Calcula el balance de wstETH del contrato antes del depósito para calcular shares exactos
        uint256 wsteth_before = IERC20(address(wst_eth)).balanceOf(address(this));

        // Convierte WETH a ETH. El ETH se recibe en el receive() de este contrato
        weth.withdraw(assets);

        // Envía ETH al contrato wstETH. Su receive() lo stakea en Lido y devuelve wstETH
        (bool ok,) = address(wst_eth).call{value: assets}("");
        if (!ok) revert LidoStrategy__WrapFailed();

        // Calcula de nuevo el balance de wstWTH del contrato después del depósito
        uint256 wsteth_after = IERC20(address(wst_eth)).balanceOf(address(this));

        // Calcula las shares exactas recibidas de Lido como diferencia de balances
        shares = wsteth_after - wsteth_before;

        // Emite evento de depósito y devuelve los shares calculados
        emit Deposited(msg.sender, assets, shares);
    }

    /**
     * @notice Retira assets de Lido swapeando wstETH a WETH via Uniswap V3
     * @dev Solo puede ser llamado por el StrategyManager
     * @dev Flujo: calcula wstETH equivalente → swap wstETH a WETH → transfiere WETH al manager
     * @param assets Cantidad de WETH a retirar
     * @return actual_withdrawn WETH realmente recibido tras el swap (puede diferir por slippage)
     */
    function withdraw(uint256 assets) external onlyManager returns (uint256 actual_withdrawn) {
        // Comprueba que la cantidad a retirar no sea 0
        if (assets == 0) revert LidoStrategy__ZeroAmount();

        // Calcula cuánto wstETH se necesita para obtener la cantidad de WETH. En realidad
        // calcula wstETH para ETH, pero con ETH y WETH es lo mismo
        uint256 wsteth_to_swap = wst_eth.getWstETHByStETH(assets);

        // Mínimo WETH esperado del swap (calcula slippage de 1%)
        uint256 min_weth_out = (assets * (BASIS_POINTS - MAX_SLIPPAGE_BPS)) / BASIS_POINTS;

        // Construye los parámetros del swap exactInputSingle en Uniswap V3
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(wst_eth), // Token A (wstETH)
            tokenOut: asset_address, // Token B (WETH)
            fee: pool_fee, // Fee tier
            recipient: address(this), // Address que recibe el swap (este contrato)
            deadline: block.timestamp, // A ejecutar en este bloque
            amountIn: wsteth_to_swap, // Cantidad del token A a swapear
            amountOutMinimum: min_weth_out, // Mínima cantidad esperada del Token B
            sqrtPriceLimitX96: 0 // Sin límite de precio
        });

        // Realiza el swap de wstETH a WETH y transfiere el resultado al StrategyManager, transfiere la cantidad
        // al manager, emite evento de depósito y devuelve cantidad WETH retirada. En caso de error revierte
        try uniswap_router.exactInputSingle(params) returns (uint256 weth_out) {
            actual_withdrawn = weth_out;
            IERC20(asset_address).safeTransfer(msg.sender, actual_withdrawn);
            emit Withdrawn(msg.sender, actual_withdrawn, assets);
        } catch {
            revert LidoStrategy__UnwrapFailed();
        }
    }

    /**
     * @notice No hace nada pero es necesario para implementar la interfaz
     * @dev Solo puede ser llamado por el StrategyManager
     * @dev A diferencia de otros protocolos, Lido no emite reward tokens
     *      El yield ya está embebido en el valor de wstETH y se refleja en totalAssets()
     * @return profit Siempre 0
     */
    function harvest() external onlyManager returns (uint256 profit) {
        emit Harvested(msg.sender, 0);
        return 0;
    }

    //* Funciones de consulta

    /**
     * @notice Devuelve el total de assets bajo gestión expresado en WETH equivalente
     * @dev Convierte el balance de wstETH a su equivalente en stETH/ETH usando el exchange rate
     *      stETH ≈ ETH en valor (soft peg 1:1), por lo que es equivalente al valor en WETH
     *      El yield se refleja aquí: a medida que sube el exchange rate de wstETH, totalAssets() crece
     * @return total Valor total en ETH (y por lo tanto WETH) equivalente
     */
    function totalAssets() external view returns (uint256 total) {
        uint256 wsteth_balance = IERC20(address(wst_eth)).balanceOf(address(this));
        return wst_eth.getStETHByWstETH(wsteth_balance);
    }

    /**
     * @notice Devuelve el APY histórico de Lido (hardcodeado)
     * @dev Lido no expone un oracle de APY on-chain de forma directa El yield real
     *      se refleja en totalAssets(), no en este valor, pero nos sirve de referencia
     * @return apy_basis_points APY en basis points (400 = 4%)
     */
    function apy() external pure returns (uint256 apy_basis_points) {
        return LIDO_APY;
    }

    /**
     * @notice Devuelve el nombre de la estrategia
     * @return strategy_name Nombre descriptivo de la estrategia
     */
    function name() external pure returns (string memory strategy_name) {
        return "Lido wstETH Strategy";
    }

    /**
     * @notice Devuelve la dirección del asset subyacente
     * @return Dirección de WETH
     */
    function asset() external view returns (address) {
        return asset_address;
    }

    /**
     * @notice Devuelve el balance de wstETH del contrato
     * @dev Útil para debugging y comprobaciones off-chain
     * @return balance Cantidad de wstETH stakeado
     */
    function wstEthBalance() external view returns (uint256 balance) {
        return IERC20(address(wst_eth)).balanceOf(address(this));
    }
}
