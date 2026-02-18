// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPool} from "@aave/contracts/interfaces/IPool.sol";
import {IAToken} from "@aave/contracts/interfaces/IAToken.sol";
import {IRewardsController} from "@aave/periphery/contracts/rewards/interfaces/IRewardsController.sol";
import {DataTypes} from "@aave/contracts/protocol/libraries/types/DataTypes.sol";
import {IWETH} from "@aave/contracts/misc/interfaces/IWETH.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IStrategy} from "../interfaces/strategies/IStrategy.sol";
import {IWstETH} from "../interfaces/strategies/lido/IWstETH.sol";
import {ICurvePool} from "../interfaces/strategies/curve/ICurvePool.sol";

/**
 * @title AaveStrategy
 * @author cristianrisueo
 * @notice Estrategia que deposita wstETH en Aave v3 para generar yield doble (Lido + Aave)
 * @dev Implementa IStrategy para integración con StrategyManager
 *
 * @dev El asset del vault es WETH. La conversión WETH <-> wstETH se realiza de manera interna:
 *      - Deposit:  WETH → ETH (IWETH) → wstETH (Lido) → Aave
 *      - Withdraw: wstETH (Aave) → stETH (IWstETH) → ETH (Curve swap) → WETH (IWETH)
 *
 * @dev Cuando envías ETH directamente al contrato wstETH, este directamente stakea en Lido,
 *      recibe stETH, lo wrappea, y le devuelve a este contrato wstETH
 *
 * @dev Esta estrategia se llama Aave por simplicidad y porque es donde acaba la liquidez
 *      pero combina dos llamadas a protocolos externos:
 *      - Lido staking yield (~4%): capturado via el exchange rate creciente de wstETH
 *      - Aave lending yield (~3.5%): capturado via aWstETH acumulando interés
 */
contract AaveStrategy is IStrategy {
    //* library attachments

    /**
     * @notice Usa SafeERC20 para todas las operaciones de IERC20 de manera segura
     * @dev Evita errores comunes con tokens legacy o mal implementados
     */
    using SafeERC20 for IERC20;

    //* Errores

    /**
     * @notice Error cuando el depósito en Aave falla
     */
    error AaveStrategy__DepositFailed();

    /**
     * @notice Error cuando el retiro de Aave falla
     */
    error AaveStrategy__WithdrawFailed();

    /**
     * @notice Error cuando solo el strategy manager puede llamar
     */
    error AaveStrategy__OnlyManager();

    /**
     * @notice Error cuando el harvest falla al reclamar rewards
     */
    error AaveStrategy__HarvestFailed();

    /**
     * @notice Error cuando el swap de rewards a assets falla
     */
    error AaveStrategy__SwapFailed();

    //* Constantes

    /// @notice Base para calculos de basis points (10000 = 100%)
    uint256 private constant BASIS_POINTS = 10000;

    /// @notice Slippage maximo permitido en swaps en bps (100 = 1%)
    uint256 private constant MAX_SLIPPAGE_BPS = 100;

    //* Variables de estado

    /// @notice Direccion del StrategyManager autorizado
    address public immutable manager;

    /// @notice Direccion del asset subyacente del vault (WETH)
    address private immutable asset_address;

    /// @notice Instancia del Pool de Aave v3
    IPool private immutable aave_pool;

    /// @notice Instancia del controlador de rewards de Aave v3
    IRewardsController private immutable rewards_controller;

    /// @notice Instancia del aToken que representa los assets depositados en Aave (aWstETH)
    IAToken private immutable a_token;

    /// @notice Direccion del token de rewards de Aave (token de gobernanza)
    address private immutable reward_token;

    /// @notice Instancia del router de Uniswap v3 para swaps de rewards
    ISwapRouter private immutable uniswap_router;

    /// @notice Fee tier de Uniswap v3 para el pool reward/asset (3000 = 0.3%)
    uint24 private immutable pool_fee;

    /// @notice Instancia del contrato wstETH de Lido para convertir wstETH <-> stETH
    IWstETH private immutable wst_eth;

    /// @notice Instancia del contrato WETH para convertir WETH ↔ ETH
    IWETH private immutable weth;

    /**
     * @notice stETH como ERC20, necesario para pre-aprobar el pool de Curve
     * @dev stETH se recibe al hacer unwrap() de wstETH. Curve necesita allowance para
     *      ejecutar el swap stETH→ETH durante el withdrawal
     */
    IERC20 private immutable st_eth;

    /// @notice Instancia del pool stETH/ETH de Curve para el swap del withdrawal
    ICurvePool private immutable curve_pool;

    //* Modificadores

    /**
     * @notice Solo permite llamadas del StrategyManager
     */
    modifier onlyManager() {
        if (msg.sender != manager) revert AaveStrategy__OnlyManager();
        _;
    }

    //* Constructor

    /**
     * @notice Constructor de AaveStrategy
     * @dev Inicializa la estrategia con Aave v3, Lido y Curve. Aprueba los contratos necesarios
     * @param _manager Direccion del StrategyManager
     * @param _asset Direccion del asset subyacente del vault (WETH)
     * @param _aave_pool Direccion del Pool de Aave v3
     * @param _rewards_controller Direccion del RewardsController de Aave v3
     * @param _reward_token Direccion del token de rewards (AAVE)
     * @param _uniswap_router Direccion del SwapRouter de Uniswap v3
     * @param _pool_fee Fee tier del pool Uniswap para reward/WETH (3000 = 0.3%)
     * @param _wst_eth Direccion del contrato wstETH de Lido
     * @param _weth Direccion del contrato WETH
     * @param _st_eth Direccion del contrato stETH
     * @param _curve_pool Direccion del pool stETH/ETH de Curve
     */
    constructor(
        address _manager,
        address _asset,
        address _aave_pool,
        address _rewards_controller,
        address _reward_token,
        address _uniswap_router,
        uint24 _pool_fee,
        address _wst_eth,
        address _weth,
        address _st_eth,
        address _curve_pool
    ) {
        // Asigna addresses, inicializa contratos y establece el fee tier de UV3
        manager = _manager;
        asset_address = _asset;
        aave_pool = IPool(_aave_pool);
        rewards_controller = IRewardsController(_rewards_controller);
        reward_token = _reward_token;
        uniswap_router = ISwapRouter(_uniswap_router);
        pool_fee = _pool_fee;
        wst_eth = IWstETH(_wst_eth);
        weth = IWETH(_weth);
        st_eth = IERC20(_st_eth);
        curve_pool = ICurvePool(_curve_pool);

        // Obtiene la direccion del aToken de wstETH dinamicamente desde Aave
        address a_token_address = aave_pool.getReserveData(_wst_eth).aTokenAddress;
        a_token = IAToken(a_token_address);

        // Aprueba Aave Pool para mover todo el wstETH de este contrato (para supply)
        IERC20(_wst_eth).forceApprove(_aave_pool, type(uint256).max);

        // Aprueba Uniswap Router para mover todos los reward tokens de Aave (para harvest, swap WETH)
        IERC20(_reward_token).forceApprove(_uniswap_router, type(uint256).max);

        // Aprueba Curve pool para mover todo el stETH (para withdrawal, swap por ETH). No usamos
        // Uniswap para este swap porque Curve tiene muchísima más liquidez para el par stETH/ETH
        IERC20(_st_eth).forceApprove(_curve_pool, type(uint256).max);
    }

    //* Funciones especiales

    /**
     * @notice Acepta ETH de WETH.withdraw() (deposit path) y del Curve swap (withdraw path)
     * @dev WETH.withdraw() envía ETH al caller (este contrato). El pool de Curve también
     *      envía ETH al caller al hacer exchange(stETH -> ETH). Ambos usan este receive()
     */
    receive() external payable {}

    //* Funciones principales

    /**
     * @notice Deposita WETH en Lido, recibe wstETH y lo deposita en Aave v3
     * @dev Solo puede ser llamado por el StrategyManager
     * @dev Asume que los assets (WETH) ya fueron transferidos a este contrato por el manager
     * @param assets Cantidad de WETH a depositar
     * @return shares Cantidad de WETH depositada
     */
    function deposit(uint256 assets) external onlyManager returns (uint256 shares) {
        // Calcula el balance de wstETH del contrato antes de la operación (debería ser 0)
        uint256 wsteth_before = IERC20(address(wst_eth)).balanceOf(address(this));

        // Convierte WETH a ETH. El ETH se recibe en el receive() de este contrato
        weth.withdraw(assets);

        // Envía ETH al contrato wstETH. Su receive() lo stakea en Lido y devuelve wstETH
        (bool ok,) = address(wst_eth).call{value: assets}("");
        if (!ok) revert AaveStrategy__DepositFailed();

        // Calcula exactamente cuánto wstETH recibimos de Lido (balance actual - 0)
        uint256 wsteth_received = IERC20(address(wst_eth)).balanceOf(address(this)) - wsteth_before;

        // Deposita el wstETH recibido en Aave, devuelve las shares (no les da uso, pero necesario para
        // cumplir con la interfaz) y emite evento. En caso de error revierte
        try aave_pool.supply(address(wst_eth), wsteth_received, address(this), 0) {
            shares = assets;
            emit Deposited(msg.sender, assets, shares);
        } catch {
            revert AaveStrategy__DepositFailed();
        }
    }

    /**
     * @notice Retira assets de Aave v3 y los devuelve en WETH al StrategyManager
     * @dev Solo puede ser llamado por el StrategyManager
     * @param assets Cantidad de WETH a retirar
     * @return actual_withdrawn WETH realmente recibido (puede diferir por slippage)
     */
    function withdraw(uint256 assets) external onlyManager returns (uint256 actual_withdrawn) {
        // Convierte la cantidad de WETH pedida a su equivalente en wstETH stETH ≈ WETH (soft peg 1:1)
        uint256 wsteth_amount = wst_eth.getWstETHByStETH(assets);

        // Retira wstETH de Aave. En caso de error revierte
        try aave_pool.withdraw(address(wst_eth), wsteth_amount, address(this)) {
            // Unwrappea de wstETH a stETH
            uint256 steth_amount = wst_eth.unwrap(wsteth_amount);

            // Calcula el mínimo ETH esperado del swap en Curve (1% max slippage)
            uint256 min_eth = (assets * (BASIS_POINTS - MAX_SLIPPAGE_BPS)) / BASIS_POINTS;

            // Swapea stETH (index 1) por ETH (index 0) via Curve pool. El ETH recibido llega al receive()
            uint256 eth_received = curve_pool.exchange(1, 0, steth_amount, min_eth);

            // Convierte ETH a WETH
            weth.deposit{value: eth_received}();

            // Envía el WETH del contrato (el recibido de Aave al retirar) al manager
            actual_withdrawn = eth_received;
            IERC20(asset_address).safeTransfer(msg.sender, actual_withdrawn);

            // Emite evento y devuelve la cantidad real retirada (debería diferir 1% máx)
            emit Withdrawn(msg.sender, actual_withdrawn, assets);
        } catch {
            revert AaveStrategy__WithdrawFailed();
        }
    }

    /**
     * @notice Cosecha rewards de Aave, los swapea a WETH y reinvierte como wstETH en Aave
     * @dev Solo puede ser llamado por el StrategyManager
     * @dev Flujo: reclama AAVE reward tokens → swap a WETH vía Uniswap → ETH → wstETH → Aave
     * @return profit Cantidad de WETH equivalente obtenido tras swap y reinversión de rewards
     */
    function harvest() external onlyManager returns (uint256 profit) {
        // Construye array de aTokens (aWstETH) para reclamar los rewards de Aave
        address[] memory assets_to_claim = new address[](1);
        assets_to_claim[0] = address(a_token);

        // Reclama los rewards acumulados para el aToken en Aave. En caso de error revierte
        try rewards_controller.claimAllRewards(assets_to_claim, address(this)) returns (
            address[] memory, uint256[] memory claimed_amounts
        ) {
            // Si no hay rewards que reclamar, retorna 0
            if (claimed_amounts.length == 0 || claimed_amounts[0] == 0) {
                return 0;
            }

            // En caso de que si haya rewards a reclamar calcula el min amount esperado en el swap
            uint256 min_amount_out = (claimed_amounts[0] * (BASIS_POINTS - MAX_SLIPPAGE_BPS)) / BASIS_POINTS;

            // Crea los parámetros de llamada al pool de Uniswap V3 para hacer el swap reward -> WETH
            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                tokenIn: reward_token, // Token A (reward token)
                tokenOut: asset_address, // Token B (WETH)
                fee: pool_fee, // Fee tier
                recipient: address(this), // Address que recibe el swap (este contrato)
                deadline: block.timestamp, // A ejecutar en este bloque
                amountIn: claimed_amounts[0], // Cantidad del token A a swapear
                amountOutMinimum: min_amount_out, // Mínima cantidad esperada del Token B
                sqrtPriceLimitX96: 0 // Sin límite de precio
            });

            // Realiza el swap aToken → WETH. Si funciona, reinvierte como wstETH en Aave. Si error, revierte
            try uniswap_router.exactInputSingle(params) returns (uint256 weth_out) {
                // Calcula balance de wstETH antes del wrap (debería ser 0)
                uint256 wsteth_before = IERC20(address(wst_eth)).balanceOf(address(this));

                // Convierte WETH → ETH → wstETH (mismo flujo que en deposit)
                weth.withdraw(weth_out);

                (bool ok,) = address(wst_eth).call{value: weth_out}("");
                if (!ok) revert AaveStrategy__SwapFailed();

                // Reinvierte el wstETH recibido en Aave
                uint256 wsteth_received = IERC20(address(wst_eth)).balanceOf(address(this)) - wsteth_before;
                aave_pool.supply(address(wst_eth), wsteth_received, address(this), 0);

                // Devuelve el beneficio en equivalente a WETH (menos mal que todos los tokens son derivados de
                // ETH que si no estaríamos muy jodidos para el accounting) y emite el evento
                profit = weth_out;
                emit Harvested(msg.sender, profit);
            } catch {
                revert AaveStrategy__SwapFailed();
            }
        } catch {
            revert AaveStrategy__HarvestFailed();
        }
    }

    //* Funciones de consulta

    /**
     * @notice Devuelve el total de assets bajo gestión en WETH equivalente
     * @dev El balance de aWstETH es 1:1 con wstETH. Se convierte a WETH equivalente
     *      usando getStETHByWstETH() que aplica el exchange rate actual de Lido.
     *      stETH ≈ ETH ≈ WETH en valor, por lo que este retorno es el valor en WETH.
     *      El yield doble (Lido + Aave) se refleja aquí a medida que crecen ambos rates.
     * @return total Valor total en WETH equivalente
     */
    function totalAssets() external view returns (uint256 total) {
        uint256 awsteth_balance = a_token.balanceOf(address(this));
        return wst_eth.getStETHByWstETH(awsteth_balance);
    }

    /**
     * @notice Devuelve el APY actual de Aave para wstETH
     *
     * @dev Convierte de RAY (1e27, unidad interna de Aave) a basis points (1e4)
     *      RAY / 1e23 = basis points
     *
     * @dev Nota: este APY refleja solo el lending yield de Aave (~3.5%).
     *      El Lido staking yield (~4%) está embebido en el exchange rate creciente
     *      de wstETH y se refleja en totalAssets(), no en este valor.
     *
     * @return apy_basis_points APY de lending en Aave en basis points (350 = 3.5%)
     */
    function apy() external view returns (uint256 apy_basis_points) {
        // Obtiene los datos de las reservas de wstETH en Aave (no WETH)
        DataTypes.ReserveData memory reserve_data = aave_pool.getReserveData(address(wst_eth));
        uint256 liquidity_rate = reserve_data.currentLiquidityRate;

        // Devuelve el APY (liquidity rate) casteado a basis points
        apy_basis_points = liquidity_rate / 1e23;
    }

    /**
     * @notice Devuelve el nombre de la estrategia
     * @return strategy_name Nombre descriptivo de la estrategia
     */
    function name() external pure returns (string memory strategy_name) {
        return "Aave v3 wstETH Strategy";
    }

    /**
     * @notice Devuelve el address del asset del vault (WETH)
     * @return asset_address Direccion del asset subyacente (WETH)
     */
    function asset() external view returns (address) {
        return asset_address;
    }

    /**
     * @notice Devuelve la liquidez disponible de wstETH en Aave para withdraws
     * @dev Util para comprobar si hay suficiente liquidez antes de retirar
     * @return available Cantidad de wstETH disponible en Aave
     */
    function availableLiquidity() external view returns (uint256 available) {
        return IERC20(address(wst_eth)).balanceOf(address(a_token));
    }

    /**
     * @notice Devuelve el balance de aToken (aWstETH) de este contrato
     * @return balance Cantidad de aWstETH que posee el contrato
     */
    function aTokenBalance() external view returns (uint256 balance) {
        return a_token.balanceOf(address(this));
    }

    /**
     * @notice Devuelve los rewards pendientes de reclamar en Aave
     * @dev Util para estimar profit del harvest antes de ejecutarlo
     * @return pending Cantidad de rewards (AAVE) pendientes
     */
    function pendingRewards() external view returns (uint256 pending) {
        // Crea un array con el address del aToken (Aave lo necesita en un array)
        address[] memory assets_to_check = new address[](1);
        assets_to_check[0] = address(a_token);

        // Realiza la llamada a Aave para obtener el balance de los rewards de este contrato
        return rewards_controller.getUserRewards(assets_to_check, address(this), reward_token);
    }
}
