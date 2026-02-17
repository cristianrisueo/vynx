// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPool} from "@aave/contracts/interfaces/IPool.sol";
import {IAToken} from "@aave/contracts/interfaces/IAToken.sol";
import {IRewardsController} from "@aave/periphery/contracts/rewards/interfaces/IRewardsController.sol";
import {DataTypes} from "@aave/contracts/protocol/libraries/types/DataTypes.sol";
import {IStrategy} from "../interfaces/strategies/IStrategy.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

/**
 * @title AaveStrategy
 * @author cristianrisueo
 * @notice Estrategia que deposita assets en Aave v3 para generar yield
 * @dev Implementa IStrategy para integracion con StrategyManager
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

    /// @notice Instancia del Pool de Aave v3
    IPool private immutable aave_pool;

    /// @notice Instancia del controlador de rewards de Aave v3
    IRewardsController private immutable rewards_controller;

    /// @notice Direccion del asset subyacente
    address private immutable asset_address;

    /// @notice Instancia del token que representa los assets depositados en Aave
    IAToken private immutable a_token;

    /**
     * @notice Direccion del token de rewards de Aave (supongo que es el de gobernanza)
     * @dev Es el token que te regala Aave por depositar liquidez, no confundir
     *      con aToken. Este token es un extra yield de regalo que va a parte
     */
    address private immutable reward_token;

    /// @notice Instancia del router de Uniswap v3 para swaps
    ISwapRouter private immutable uniswap_router;

    /**
     * @notice Fee tier de Uniswap v3 para el pool reward/asset (3000 = 0.3%)
     * @dev Recuerdas que un pool de V3 lo define el par de tokens y el fee tier?
     */
    uint24 private immutable pool_fee;

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
     * @dev Inicializa la estrategia con Aave v3 y aprueba los contratos necesarios
     * @param _manager Direccion del StrategyManager
     * @param _aave_pool Direccion del Pool de Aave v3
     * @param _rewards_controller Direccion del RewardsController de Aave v3
     * @param _asset Direccion del asset subyacente
     * @param _reward_token Direccion del token de rewards (AAVE)
     * @param _uniswap_router Direccion del SwapRouter de Uniswap v3
     * @param _pool_fee Fee tier del pool Uniswap (3000 = 0.3%)
     */
    constructor(
        address _manager,
        address _aave_pool,
        address _rewards_controller,
        address _asset,
        address _reward_token,
        address _uniswap_router,
        uint24 _pool_fee
    ) {
        // Asigna addresses, inicializa contratos y establece el fee tier de UV3
        manager = _manager;
        aave_pool = IPool(_aave_pool);
        rewards_controller = IRewardsController(_rewards_controller);
        asset_address = _asset;
        reward_token = _reward_token;
        uniswap_router = ISwapRouter(_uniswap_router);
        pool_fee = _pool_fee;

        // Obtiene la direccion del aToken dinamicamente desde Aave
        address a_token_address = aave_pool.getReserveData(_asset).aTokenAddress;
        a_token = IAToken(a_token_address);

        // Aprueba Aave Pool para mover todos los assets de este contrato
        IERC20(_asset).forceApprove(_aave_pool, type(uint256).max);

        // Aprueba Uniswap Router para mover todos los rewards tokens de este contrato
        IERC20(_reward_token).forceApprove(_uniswap_router, type(uint256).max);
    }

    //* Funciones principales

    /**
     * @notice Deposita assets en Aave v3
     * @dev Solo puede ser llamado por el StrategyManager
     * @dev Asume que los assets ya fueron transferidos a este contrato desde StrategyManager
     * @param assets Cantidad de assets a depositar en Aave
     * @return shares En Aave es 1:1, devuelve la misma cantidad de aToken
     */
    function deposit(uint256 assets) external onlyManager returns (uint256 shares) {
        // Realiza el depósito, devuelve el aToken y emite evento. En caso de error revierte
        try aave_pool.supply(asset_address, assets, address(this), 0) {
            shares = assets;
            emit Deposited(msg.sender, assets, shares);
        } catch {
            revert AaveStrategy__DepositFailed();
        }
    }

    /**
     * @notice Retira assets de Aave v3
     * @dev Solo puede ser llamado por el StrategyManager
     * @dev Transfiere los assets retirados directamente a StrategyManager
     * @param assets Cantidad de assets a retirar de Aave
     * @return actual_withdrawn Assets realmente retirados (incluye yield)
     */
    function withdraw(uint256 assets) external onlyManager returns (uint256 actual_withdrawn) {
        // Realiza withdraw de Aave (quema aToken, recibe asset + yield). Transfiere a
        // StrategyManager y emite evento. En caso de error revierte
        try aave_pool.withdraw(asset_address, assets, address(this)) returns (uint256 withdrawn) {
            actual_withdrawn = withdrawn;
            IERC20(asset_address).safeTransfer(msg.sender, actual_withdrawn);
            emit Withdrawn(msg.sender, actual_withdrawn, assets);
        } catch {
            revert AaveStrategy__WithdrawFailed();
        }
    }

    /**
     * @notice Cosecha rewards de Aave, los swapea a assets y reinvierte en Aave de nuevo
     * @dev Solo puede ser llamado por el StrategyManager
     * @dev Reclama rewards de Aave, los swapea por assets via Uniswap v3 y los deposita
     *      de vuelta en Aave para maximizar yield compuesto
     * @return profit Cantidad de assets obtenidos tras swap y reinversion de rewards
     */
    function harvest() external onlyManager returns (uint256 profit) {
        // Construye array de assets (solo aToken) para reclamar los rewards
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

            // En caso de que si haya rewards a reclamar calcula el min amount esperado en el swap.
            // Hacemos esto para prevenir slippage (no debería haber igualmente, pero mejor prevenir)
            uint256 min_amount_out = (claimed_amounts[0] * (BASIS_POINTS - MAX_SLIPPAGE_BPS)) / BASIS_POINTS;

            // Crea los parámetros de los parámetros de llamada al pool de Uniswap V3 para hacer el swap
            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                tokenIn: reward_token, // Token A
                tokenOut: asset_address, // Token B
                fee: pool_fee, // Fee tier (con estos 3 ya hemos decidido el pool)
                recipient: address(this), // Address que recibe el swap (este contrato)
                deadline: block.timestamp, // A ejecutar en este bloque
                amountIn: claimed_amounts[0], // Cantidad del token A a swapear
                amountOutMinimum: min_amount_out, // Mínima cantidad esperada del Token B
                sqrtPriceLimitX96: 0 // Ni puta idea
            });

            // Realiza la llamada. Si todo va bien reinvierte los assets obtenidos tras el swap, devuelve
            // la cantidad de assets obtenidos y emite un evento. En caso de error revierte
            try uniswap_router.exactInputSingle(params) returns (uint256 amount_out) {
                aave_pool.supply(asset_address, amount_out, address(this), 0);
                profit = amount_out;
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
     * @notice Devuelve el total de assets bajo gestion en Aave
     * @dev Los aTokens hacen rebase automatico, el balance ya incluye yield
     *      por lo que no hay que hacer cálculos extra
     * @return total Cantidad de assets depositados + yield acumulado
     */
    function totalAssets() external view returns (uint256 total) {
        return a_token.balanceOf(address(this));
    }

    /**
     * @notice Devuelve el APY actual de Aave
     * @dev Convierte de RAY (1e27, unidad interna de Aave) a basis points (1e4)
     *      RAY / 1e23 = basis points
     * @return apy_basis_points APY en basis points (350 = 3.5%)
     */
    function apy() external view returns (uint256 apy_basis_points) {
        // Obtiene los datos de las reservas del asset en Aave
        DataTypes.ReserveData memory reserve_data = aave_pool.getReserveData(asset_address);
        uint256 liquidity_rate = reserve_data.currentLiquidityRate;

        // Devuelve el APY (liquidity rate) casteado a basis points
        apy_basis_points = liquidity_rate / 1e23;
    }

    /**
     * @notice Devuelve el nombre de la estrategia
     * @return strategy_name Nombre descriptivo de la estrategia
     */
    function name() external pure returns (string memory strategy_name) {
        return "Aave v3 Strategy";
    }

    /**
     * @notice Devuelve el address del asset
     * @return asset_address Direccion del asset subyacente
     */
    function asset() external view returns (address) {
        return asset_address;
    }

    /**
     * @notice Devuelve la liquidez disponible en Aave para withdraws
     * @dev Util para comprobar si hay suficiente liquidez antes de retirar
     * @return available Cantidad de assets disponibles en Aave
     */
    function availableLiquidity() external view returns (uint256 available) {
        return IERC20(asset_address).balanceOf(address(a_token));
    }

    /**
     * @notice Devuelve el balance de aToken de este contrato
     * @return balance Cantidad de aToken que posee el contrato
     */
    function aTokenBalance() external view returns (uint256 balance) {
        return a_token.balanceOf(address(this));
    }

    /**
     * @notice Devuelve los rewards pendientes de reclamar
     * @dev Util para estimar profit del harvest antes de ejecutarlo
     * @return pending Cantidad de rewards (AAVE) pendientes
     */
    function pendingRewards() external view returns (uint256 pending) {
        // Crea un array con el address del aToken (Aave lo necesita en un array, supongo)
        address[] memory assets_to_check = new address[](1);
        assets_to_check[0] = address(a_token);

        // Realiza la llamada a Aave para obtener el balance de los rewards de este contrato
        // realmente el balance del reward token (pero anyway)
        return rewards_controller.getUserRewards(assets_to_check, address(this), reward_token);
    }
}
