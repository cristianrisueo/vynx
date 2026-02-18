// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {INonfungiblePositionManager} from "../interfaces/strategies/uniswap/INonfungiblePositionManager.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "../libraries/TickMath.sol";
import {FullMath} from "../libraries/FullMath.sol";
import {LiquidityAmounts} from "../libraries/LiquidityAmounts.sol";
import {IStrategy} from "../interfaces/strategies/IStrategy.sol";

/**
 * @title UniswapV3Strategy
 * @author cristianrisueo
 * @notice Estrategia que provee liquidez concentrada al pool WETH/USDC de Uniswap V3 para ganar fees de trading
 * @dev Implementa IStrategy para integración con StrategyManager
 *
 * @dev Cada posición LP en Uniswap V3 es un NFT único (tokenId). Esta estrategia mantiene UNA posición
 *      que se aumenta o disminuye según los deposits/withdrawals del StrategyManager
 *
 * @dev El rango de ticks se calcula en el constructor a partir del tick actual del pool (±TICK_RANGE ≈ ±10%)
 *      Un rango amplio minimiza el riesgo de salir del rango pero sacrifica APY vs rango estrecho
 *
 * @dev Flujo depósito:   WETH → swap 50% WETH a USDC → mint/increaseLiquidity (WETH+USDC → NFT)
 * @dev Flujo retiro:     decreaseLiquidity (NFT → WETH+USDC) → collect → swap USDC→WETH → manager
 * @dev Flujo harvest:    collect fees (WETH+USDC) → swap USDC→WETH → swap 50% WETH→USDC → increaseLiquidity
 *
 * @dev Pool principal WETH/USDC en mainnet (0.05% fee): 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640
 *      Token ordering: USDC (0xA0...) < WETH (0xC0...) → token0=USDC, token1=WETH
 */
contract UniswapV3Strategy is IStrategy {
    //* library attachments

    /**
     * @notice Usa SafeERC20 para todas las operaciones de IERC20 de manera segura
     */
    using SafeERC20 for IERC20;

    //* Errores

    /// @notice Error cuando solo el strategy manager puede llamar
    error UniswapV3Strategy__OnlyManager();

    /// @notice Error cuando se intenta depositar o retirar con cantidad cero
    error UniswapV3Strategy__ZeroAmount();

    /// @notice Error cuando falla el mint de la posición LP
    error UniswapV3Strategy__MintFailed();

    /// @notice Error cuando falla un swap WETH ↔ USDC en el router
    error UniswapV3Strategy__SwapFailed();

    /// @notice Error cuando se intenta retirar sin posición activa o con liquidez insuficiente
    error UniswapV3Strategy__InsufficientLiquidity();

    //* Constantes

    /// @notice Base para cálculos de basis points (10000 = 100%)
    uint256 private constant BASIS_POINTS = 10000;

    /// @notice Fee tier del pool WETH/USDC en Uniswap V3 (500 = 0.05%)
    uint24 private constant POOL_FEE = 500;

    /// @notice Tick spacing del pool 0.05% fee (cada fee tier tiene su propio spacing)
    int24 private constant TICK_SPACING = 10;

    /**
     * @notice Rango de ticks a cada lado del tick actual para definir el rango de la posición
     * @dev 960 ticks ≈ ±10% de precio (log(1.10) / log(1.0001) ≈ 953, redondeado a múltiplo de 10)
     *      Un rango más amplio = menos fees pero menos riesgo de salir del rango
     */
    int24 private constant TICK_RANGE = 960;

    /**
     * @notice APY histórico de Uniswap V3 WETH/USDC en basis points (1400 = 14%)
     * @dev Altamente variable según el volumen de trading. Este valor es un estimado histórico.
     */
    uint256 private constant UNISWAP_V3_APY = 1400;

    /// @notice 2^96 usado para cálculos de precio con sqrtPriceX96
    uint256 private constant Q96 = 2 ** 96;

    //* Variables de estado

    /// @notice Dirección del StrategyManager autorizado
    address public immutable manager;

    /// @notice Dirección del asset subyacente (WETH)
    address private immutable asset_address;

    /// @notice NonfungiblePositionManager de Uniswap V3: gestiona posiciones LP como NFTs
    INonfungiblePositionManager private immutable position_manager;

    /// @notice SwapRouter de Uniswap V3 para intercambios WETH ↔ USDC
    ISwapRouter private immutable swap_router;

    /**
     * @notice Instancia del pool WETH/USDC de Uniswap V3
     * @dev Usado para leer el precio actual (slot0.sqrtPriceX96) en totalAssets()
     */
    IUniswapV3Pool private immutable pool;

    /// @notice Dirección del contrato WETH
    address private immutable weth;

    /// @notice Dirección del contrato USDC
    address private immutable usdc;

    /**
     * @notice Token ordenado en posición 0 del pool (menor dirección entre WETH y USDC)
     * @dev Uniswap V3 requiere token0 < token1 en dirección. Para WETH/USDC: token0 = USDC
     */
    address private immutable token0;

    /// @notice Token ordenado en posición 1 del pool (mayor dirección entre WETH y USDC)
    address private immutable token1;

    /**
     * @notice Indica si WETH es token0 en el pool
     * @dev En el pool WETH/USDC: USDC (0xA0...) < WETH (0xC0...), por lo que weth_is_token0 = false
     *      Este flag determina cómo mapear amount0/amount1 a WETH/USDC en todo el contrato
     */
    bool private immutable weth_is_token0;

    /**
     * @notice Tick inferior del rango de la posición LP (calculado en constructor)
     * @dev Tick más bajo del rango de precio en el que la posición acumula fees
     */
    int24 public immutable lower_tick;

    /**
     * @notice Tick superior del rango de la posición LP (calculado en constructor)
     * @dev Tick más alto del rango de precio en el que la posición acumula fees
     */
    int24 public immutable upper_tick;

    /**
     * @notice ID del NFT que representa la posición LP de este contrato
     * @dev 0 = sin posición activa. Se asigna en el primer deposit y se resetea a 0 al quemar el NFT
     */
    uint256 public token_id;

    //* Modificadores

    /// @notice Solo permite llamadas del StrategyManager
    modifier onlyManager() {
        if (msg.sender != manager) revert UniswapV3Strategy__OnlyManager();
        _;
    }

    //* Constructor

    /**
     * @notice Constructor de UniswapV3Strategy
     * @dev Lee el tick actual del pool para calcular el rango inmutable de la posición (±TICK_RANGE ≈ ±10%)
     * @dev Aprueba el position manager y swap router para mover WETH y USDC
     * @param _manager Dirección del StrategyManager
     * @param _position_manager NonfungiblePositionManager de Uniswap V3 (0xC36442b4a4522E871399CD717aBDD847Ab11FE88)
     * @param _swap_router SwapRouter de Uniswap V3 (0xE592427A0AEce92De3Edee1F18E0157C05861564)
     * @param _pool Pool WETH/USDC 0.05% de Uniswap V3 (0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640)
     * @param _weth Dirección del contrato WETH (0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2)
     * @param _usdc Dirección del contrato USDC (0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48)
     */
    constructor(
        address _manager,
        address _position_manager,
        address _swap_router,
        address _pool,
        address _weth,
        address _usdc
    ) {
        manager = _manager;
        asset_address = _weth;
        position_manager = INonfungiblePositionManager(_position_manager);
        swap_router = ISwapRouter(_swap_router);
        pool = IUniswapV3Pool(_pool);
        weth = _weth;
        usdc = _usdc;

        // Determina el orden de tokens: Uniswap V3 requiere token0 < token1 en dirección
        // Para WETH/USDC: USDC (0xA0...) < WETH (0xC0...) → token0=USDC, token1=WETH
        weth_is_token0 = _weth < _usdc;
        token0 = _weth < _usdc ? _weth : _usdc;
        token1 = _weth < _usdc ? _usdc : _weth;

        // Lee el tick actual del pool y calcula el rango de la posición (±TICK_RANGE ticks ≈ ±10% precio)
        // El tick actual se redondea al múltiplo de TICK_SPACING más cercano por debajo
        (, int24 current_tick,,,,,) = IUniswapV3Pool(_pool).slot0();
        int24 rounded = (current_tick / TICK_SPACING) * TICK_SPACING;
        lower_tick = rounded - TICK_RANGE;
        upper_tick = rounded + TICK_RANGE;

        // Aprueba el position manager para mover WETH y USDC en mint/increaseLiquidity
        IERC20(_weth).forceApprove(_position_manager, type(uint256).max);
        IERC20(_usdc).forceApprove(_position_manager, type(uint256).max);

        // Aprueba el swap router para intercambios WETH ↔ USDC en deposit, withdraw y harvest
        IERC20(_weth).forceApprove(_swap_router, type(uint256).max);
        IERC20(_usdc).forceApprove(_swap_router, type(uint256).max);
    }

    //* Funciones principales

    /**
     * @notice Deposita WETH en la posición LP del pool WETH/USDC de Uniswap V3
     * @dev Solo puede ser llamado por el StrategyManager
     * @dev Asume que los assets ya fueron transferidos a este contrato desde StrategyManager
     * @dev Proceso: swap 50% WETH→USDC → mint (si primera vez) o increaseLiquidity
     * @param assets Cantidad de WETH a depositar
     * @return shares Assets depositados (consistente con el resto de estrategias)
     */
    function deposit(uint256 assets) external onlyManager returns (uint256 shares) {
        if (assets == 0) revert UniswapV3Strategy__ZeroAmount();

        // Swap mitad de WETH a USDC para construir el par de la posición LP
        // La posición WETH/USDC requiere ambos tokens en proporción al precio actual
        uint256 weth_to_swap = assets / 2;
        uint256 weth_to_keep = assets - weth_to_swap;

        // Swap WETH → USDC sin mínimo: el ratio WETH/USDC no puede calcularse sin oracle
        // El keeper que llama a deposit es responsable de condiciones de mercado razonables
        uint256 usdc_received;
        try swap_router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: weth,
                tokenOut: usdc,
                fee: POOL_FEE,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: weth_to_swap,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        ) returns (uint256 amount_out) {
            usdc_received = amount_out;
        } catch {
            revert UniswapV3Strategy__SwapFailed();
        }

        // Mapea WETH y USDC a amount0/amount1 según el orden de tokens del pool
        uint256 amount0_desired = weth_is_token0 ? weth_to_keep : usdc_received;
        uint256 amount1_desired = weth_is_token0 ? usdc_received : weth_to_keep;

        if (token_id == 0) {
            // Primera vez: mintea una nueva posición LP y guarda el tokenId
            try position_manager.mint(
                INonfungiblePositionManager.MintParams({
                    token0: token0,
                    token1: token1,
                    fee: POOL_FEE,
                    tickLower: lower_tick,
                    tickUpper: upper_tick,
                    amount0Desired: amount0_desired,
                    amount1Desired: amount1_desired,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: address(this),
                    deadline: block.timestamp
                })
            ) returns (uint256 new_token_id, uint128, uint256, uint256) {
                token_id = new_token_id;
            } catch {
                revert UniswapV3Strategy__MintFailed();
            }
        } else {
            // Posición existente: aumenta la liquidez sin cambiar el rango de ticks
            position_manager.increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams({
                    tokenId: token_id,
                    amount0Desired: amount0_desired,
                    amount1Desired: amount1_desired,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            );
        }

        shares = assets;
        emit Deposited(msg.sender, assets, shares);
    }

    /**
     * @notice Retira assets de la posición LP disminuyendo liquidez y convirtiendo a WETH
     * @dev Solo puede ser llamado por el StrategyManager
     * @dev Proceso: decreaseLiquidity → collect → swap USDC→WETH → transfer manager
     * @dev Si la liquidez queda a 0, quema el NFT y resetea token_id = 0
     * @param assets Cantidad de WETH a retirar
     * @return actual_withdrawn WETH realmente recibido (puede diferir por precio y slippage)
     */
    function withdraw(uint256 assets) external onlyManager returns (uint256 actual_withdrawn) {
        if (assets == 0) revert UniswapV3Strategy__ZeroAmount();
        if (token_id == 0) revert UniswapV3Strategy__InsufficientLiquidity();

        // Obtiene la liquidez total actual de la posición
        (,,,,,,, uint128 total_liquidity,,,,) = position_manager.positions(token_id);
        if (total_liquidity == 0) revert UniswapV3Strategy__InsufficientLiquidity();

        // Calcula la proporción de liquidez a retirar: assets / totalAssets
        // Si se solicita más de lo disponible, retira toda la posición
        uint256 total = _totalAssets();
        uint128 liquidity_to_remove;
        if (total == 0 || assets >= total) {
            liquidity_to_remove = total_liquidity;
        } else {
            liquidity_to_remove = uint128(FullMath.mulDiv(total_liquidity, assets, total));
        }

        // Disminuye la liquidez: los tokens pasan a estado "owed" (pendientes de collect)
        position_manager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: token_id,
                liquidity: liquidity_to_remove,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );

        // Recoge todos los tokens pendientes (liquidez retirada + fees acumulados)
        (uint256 collected0, uint256 collected1) = position_manager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: token_id,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        // Si la posición quedó sin liquidez, quema el NFT y resetea el token_id
        (,,,,,,, uint128 remaining_liquidity,,,,) = position_manager.positions(token_id);
        if (remaining_liquidity == 0) {
            position_manager.burn(token_id);
            token_id = 0;
        }

        // Separa WETH y USDC según el orden de tokens del pool
        uint256 weth_collected = weth_is_token0 ? collected0 : collected1;
        uint256 usdc_collected = weth_is_token0 ? collected1 : collected0;

        // Swap USDC → WETH para devolver todo en WETH al StrategyManager
        if (usdc_collected > 0) {
            try swap_router.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: usdc,
                    tokenOut: weth,
                    fee: POOL_FEE,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: usdc_collected,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            ) returns (uint256 weth_from_usdc) {
                weth_collected += weth_from_usdc;
            } catch {
                revert UniswapV3Strategy__SwapFailed();
            }
        }

        // Transfiere todo el WETH al manager y emite evento
        actual_withdrawn = weth_collected;
        IERC20(asset_address).safeTransfer(msg.sender, actual_withdrawn);
        emit Withdrawn(msg.sender, actual_withdrawn, assets);
    }

    /**
     * @notice Cosecha los fees acumulados de la posición LP y los reinvierte como liquidez
     * @dev Solo puede ser llamado por el StrategyManager
     * @dev Collect no toca la liquidez principal, solo recoge fees. Los fees se reinvierten
     *      convirtiendo 50% de WETH a USDC y aumentando la posición LP existente
     * @return profit Cantidad de WETH equivalente obtenida en fees antes de reinvertir
     */
    function harvest() external onlyManager returns (uint256 profit) {
        // Sin posición activa, no hay fees que reclamar
        if (token_id == 0) {
            emit Harvested(msg.sender, 0);
            return 0;
        }

        // Recoge los fees acumulados sin afectar la liquidez principal
        (uint256 collected0, uint256 collected1) = position_manager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: token_id,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        // Sin fees que procesar
        if (collected0 == 0 && collected1 == 0) {
            emit Harvested(msg.sender, 0);
            return 0;
        }

        // Separa WETH y USDC según el orden de tokens del pool
        uint256 weth_fees = weth_is_token0 ? collected0 : collected1;
        uint256 usdc_fees = weth_is_token0 ? collected1 : collected0;

        // Convierte fees en USDC a WETH para tener todo como base de cálculo de profit
        if (usdc_fees > 0) {
            try swap_router.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: usdc,
                    tokenOut: weth,
                    fee: POOL_FEE,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: usdc_fees,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            ) returns (uint256 weth_from_usdc) {
                weth_fees += weth_from_usdc;
            } catch {
                revert UniswapV3Strategy__SwapFailed();
            }
        }

        // Registra el profit total en WETH antes de reinvertir
        profit = weth_fees;

        // Reinvierte los fees: swap 50% WETH → USDC, luego aumenta la posición LP
        uint256 weth_to_swap = weth_fees / 2;
        uint256 weth_to_keep = weth_fees - weth_to_swap;

        uint256 usdc_for_reinvest;
        if (weth_to_swap > 0) {
            try swap_router.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: weth,
                    tokenOut: usdc,
                    fee: POOL_FEE,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: weth_to_swap,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            ) returns (uint256 usdc_out) {
                usdc_for_reinvest = usdc_out;
            } catch {
                revert UniswapV3Strategy__SwapFailed();
            }
        }

        // Aumenta la liquidez de la posición existente con los fees reinvertidos
        uint256 amount0 = weth_is_token0 ? weth_to_keep : usdc_for_reinvest;
        uint256 amount1 = weth_is_token0 ? usdc_for_reinvest : weth_to_keep;

        position_manager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: token_id,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );

        emit Harvested(msg.sender, profit);
    }

    //* Funciones de consulta

    /**
     * @notice Devuelve el total de assets bajo gestión expresado en WETH equivalente
     * @dev Calcula el valor de la posición LP usando el precio actual del pool:
     *      1. Obtiene la liquidez de la posición y los fees pendientes
     *      2. Usa LiquidityAmounts para convertir liquidez a cantidades de token0/token1
     *      3. Convierte token0/token1 a WETH usando el sqrtPriceX96 del pool
     * @return total Valor total en WETH equivalente
     */
    function totalAssets() external view returns (uint256 total) {
        return _totalAssets();
    }

    /**
     * @notice Devuelve el APY histórico de Uniswap V3 WETH/USDC (hardcodeado)
     * @dev Altamente variable según volumen. Este valor es un estimado histórico
     * @return apy_basis_points APY en basis points (1400 = 14%)
     */
    function apy() external pure returns (uint256 apy_basis_points) {
        return UNISWAP_V3_APY;
    }

    /**
     * @notice Devuelve el nombre de la estrategia
     * @return strategy_name Nombre descriptivo de la estrategia
     */
    function name() external pure returns (string memory strategy_name) {
        return "Uniswap V3 WETH/USDC Strategy";
    }

    /**
     * @notice Devuelve la dirección del asset subyacente
     * @return Dirección de WETH
     */
    function asset() external view returns (address) {
        return asset_address;
    }

    //* Funciones internas

    /**
     * @notice Lógica interna de totalAssets para reutilización en withdraw
     * @dev Separada de totalAssets() para evitar una llamada externa dentro de withdraw
     */
    function _totalAssets() internal view returns (uint256) {
        if (token_id == 0) return 0;

        // Obtiene liquidez y fees pendientes de la posición
        (,,,,,,, uint128 liquidity,,, uint128 tokens_owed0, uint128 tokens_owed1) =
            position_manager.positions(token_id);

        if (liquidity == 0 && tokens_owed0 == 0 && tokens_owed1 == 0) return 0;

        // Lee el precio actual del pool (sqrtPriceX96 = sqrt(token1/token0) * 2^96)
        (uint160 sqrt_price_x96,,,,,,) = pool.slot0();

        // Calcula sqrtPrices en los extremos del rango para usar con LiquidityAmounts
        uint160 sqrt_price_lower = TickMath.getSqrtRatioAtTick(lower_tick);
        uint160 sqrt_price_upper = TickMath.getSqrtRatioAtTick(upper_tick);

        // Calcula las cantidades de token0 y token1 correspondientes a la liquidez actual
        // Tiene en cuenta si el precio está dentro, por debajo o por encima del rango
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrt_price_x96, sqrt_price_lower, sqrt_price_upper, liquidity
        );

        // Suma los fees pendientes de collect (también en token0/token1)
        amount0 += tokens_owed0;
        amount1 += tokens_owed1;

        // Mapea amount0/amount1 a WETH/USDC según el orden de tokens del pool
        uint256 weth_amount = weth_is_token0 ? amount0 : amount1;
        uint256 usdc_amount = weth_is_token0 ? amount1 : amount0;

        // Convierte USDC a WETH usando el precio actual del pool
        // price = sqrtPriceX96^2 / Q96^2 = token1_raw / token0_raw
        //
        // Caso weth_is_token0 = false (nuestro pool: token0=USDC, token1=WETH):
        //   price = WETH_raw / USDC_raw
        //   weth_from_usdc = usdc * price = usdc * sqrtPriceX96^2 / Q96^2
        //
        // Caso weth_is_token0 = true (hipotético pool: token0=WETH, token1=USDC):
        //   price = USDC_raw / WETH_raw (inverso del precio en términos de WETH)
        //   weth_from_usdc = usdc / price = usdc * Q96^2 / sqrtPriceX96^2
        uint256 weth_from_usdc;
        if (usdc_amount > 0) {
            if (weth_is_token0) {
                // price = USDC/WETH → invertir para obtener WETH/USDC
                weth_from_usdc = FullMath.mulDiv(
                    FullMath.mulDiv(usdc_amount, Q96, uint256(sqrt_price_x96)),
                    Q96,
                    uint256(sqrt_price_x96)
                );
            } else {
                // price = WETH/USDC → multiplicar directamente
                weth_from_usdc = FullMath.mulDiv(
                    FullMath.mulDiv(usdc_amount, uint256(sqrt_price_x96), Q96),
                    uint256(sqrt_price_x96),
                    Q96
                );
            }
        }

        return weth_amount + weth_from_usdc;
    }
}
