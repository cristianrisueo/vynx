// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICometMarket} from "../interfaces/compound/ICometMarket.sol";
import {ICometRewards} from "../interfaces/compound/ICometRewards.sol";
import {IStrategy} from "../interfaces/core/IStrategy.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

/**
 * @title CompoundStrategy
 * @author cristianrisueo
 * @notice Estrategia que deposita assets en Compound v3 para generar yield
 * @dev Implementa IStrategy para integracion con StrategyManager
 */
contract CompoundStrategy is IStrategy {
    //* library attachments

    /**
     * @notice Usa SafeERC20 para todas las operaciones de IERC20 de manera segura
     * @dev Evita errores comunes con tokens legacy o mal implementados
     */
    using SafeERC20 for IERC20;

    //* Errores

    /**
     * @notice Error cuando el depósito en Compound falla
     */
    error CompoundStrategy__DepositFailed();

    /**
     * @notice Error cuando el retiro de Compound falla
     */
    error CompoundStrategy__WithdrawFailed();

    /**
     * @notice Error cuando solo el strategy manager puede llamar
     */
    error CompoundStrategy__OnlyManager();

    /**
     * @notice Error cuando el harvest falla al reclamar rewards
     */
    error CompoundStrategy__HarvestFailed();

    /**
     * @notice Error cuando el swap de rewards a assets falla
     */
    error CompoundStrategy__SwapFailed();

    //* Constantes

    /// @notice Base para calculos de basis points (10000 = 100%)
    uint256 private constant BASIS_POINTS = 10000;

    /// @notice Slippage maximo permitido en swaps en bps (100 = 1%)
    uint256 private constant MAX_SLIPPAGE_BPS = 100;

    //* Variables de estado

    /// @notice Direccion del StrategyManager autorizado
    address public immutable manager;

    /// @notice Instancia del Comet market de Compound v3
    ICometMarket private immutable compound_comet;

    /// @notice Instancia del controlador de rewards de Compound v3
    ICometRewards private immutable compound_rewards;

    /// @notice Direccion del asset subyacente
    address private immutable asset_address;

    /// @notice Direccion del token de rewards (COMP)
    address private immutable reward_token;

    /// @notice Router de Uniswap v3 para swaps
    ISwapRouter private immutable uniswap_router;

    /// @notice Fee tier de Uniswap v3 para el pool reward/asset (3000 = 0.3%)
    /// @dev Recuerdas que un pool de V3 lo define el par de tokens y el fee tier?
    uint24 private immutable pool_fee;

    //* Modificadores

    /**
     * @notice Solo permite llamadas del StrategyManager
     */
    modifier onlyManager() {
        if (msg.sender != manager) revert CompoundStrategy__OnlyManager();
        _;
    }

    //* Constructor

    /**
     * @notice Constructor de CompoundStrategy
     * @dev Inicializa la estrategia con Compound v3 y aprueba los contratos necesarios
     * @param _manager Direccion del StrategyManager
     * @param _compound_comet Direccion del Comet market de Compound v3
     * @param _compound_rewards Direccion del CometRewards de Compound v3
     * @param _asset Direccion del asset subyacente
     * @param _reward_token Direccion del token de rewards (COMP)
     * @param _uniswap_router Direccion del SwapRouter de Uniswap v3
     * @param _pool_fee Fee tier del pool Uniswap (3000 = 0.3%)
     */
    constructor(
        address _manager,
        address _compound_comet,
        address _compound_rewards,
        address _asset,
        address _reward_token,
        address _uniswap_router,
        uint24 _pool_fee
    ) {
        // Asigna addresses, inicializa contratos y establece el fee tier de UV3
        manager = _manager;
        compound_comet = ICometMarket(_compound_comet);
        compound_rewards = ICometRewards(_compound_rewards);
        asset_address = _asset;
        reward_token = _reward_token;
        uniswap_router = ISwapRouter(_uniswap_router);
        pool_fee = _pool_fee;

        // Aprueba Compound Comet para mover todos los assets de este contrato
        IERC20(_asset).forceApprove(_compound_comet, type(uint256).max);

        // Aprueba Uniswap Router para mover todos los rewards tokens de este contrato
        IERC20(_reward_token).forceApprove(_uniswap_router, type(uint256).max);
    }

    //* Funciones principales

    /**
     * @notice Deposita assets en Compound v3
     * @dev Solo puede ser llamado por el StrategyManager
     * @dev Asume que los assets ya fueron transferidos a este contrato desde StrategyManager
     * @param assets Cantidad de assets a depositar en Compound
     * @return shares Devuelve cantidad depositada (Compound no usa tokens tipo cToken en v3)
     */
    function deposit(uint256 assets) external onlyManager returns (uint256 shares) {
        // Realiza el depósito en Compound y emite evento. En caso de error revierte
        try compound_comet.supply(asset_address, assets) {
            shares = assets;
            emit Deposited(msg.sender, assets, shares);
        } catch {
            revert CompoundStrategy__DepositFailed();
        }
    }

    /**
     * @notice Retira assets de Compound v3
     * @dev Solo puede ser llamado por el StrategyManager
     * @dev Transfiere los assets retirados directamente a StrategyManager
     * @param assets Cantidad de assets a retirar de Compound
     * @return actualWithdrawn Assets realmente retirados (incluye yield)
     */
    function withdraw(uint256 assets) external onlyManager returns (uint256 actualWithdrawn) {
        // Balance de assets del contrato antes del withdraw = 0 (todo está en compound)
        uint256 balance_before = IERC20(asset_address).balanceOf(address(this));

        // Realiza withdraw de Compound, transfiere a StrategyManager y emite evento. En caso de error revierte
        try compound_comet.withdraw(asset_address, assets) {
            // Resta el balance actual de assets (lo realmente retirado de compound) - assets antes del retiro (0)
            // para calcular lo que se ha obtenido realmente de compound (assets puede ser 100, pero perderse 1 wei)
            actualWithdrawn = IERC20(asset_address).balanceOf(address(this)) - balance_before;

            IERC20(asset_address).safeTransfer(msg.sender, actualWithdrawn);
            emit Withdrawn(msg.sender, actualWithdrawn, assets);
        } catch {
            revert CompoundStrategy__WithdrawFailed();
        }
    }

    /**
     * @notice Cosecha rewards de Compound, los swapea a assets y reinvierte en Compound de nuevo
     * @dev Solo puede ser llamado por el StrategyManager
     * @dev Reclama rewards de Compound, los swapea por assets via Uniswap v3 y los deposita
     *      de vuelta en Compound para maximizar yield compuesto
     * @return profit Cantidad de assets obtenidos tras swap y reinversion de rewards
     */
    function harvest() external onlyManager returns (uint256 profit) {
        // Reclama los rewards acumulados del Comet market en Compound. En caso de error revierte
        try compound_rewards.claim(address(compound_comet), address(this), true) {
            // Obtiene el balance de reward tokens del contrato
            uint256 reward_amount = IERC20(reward_token).balanceOf(address(this));

            // Si no hay rewards que reclamar, retorna 0
            if (reward_amount == 0) {
                return 0;
            }

            // En caso de que si haya rewards a reclamar calcula el min amount esperado en el swap.
            // Hacemos esto para prevenir slippage (no debería haber igualmente, pero mejor prevenir)
            uint256 min_amount_out = (reward_amount * (BASIS_POINTS - MAX_SLIPPAGE_BPS)) / BASIS_POINTS;

            // Crea los parámetros de los parámetros de llamada al pool de Uniswap V3 para hacer el swap
            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                tokenIn: reward_token, // Token A
                tokenOut: asset_address, // Token B
                fee: pool_fee, // Fee tier (con estos 3 ya hemos decidido el pool)
                recipient: address(this), // Address que recibe el swap (este contrato)
                deadline: block.timestamp, // A ejecutar en este bloque
                amountIn: reward_amount, // Cantidad del token A a swapear
                amountOutMinimum: min_amount_out, // Mínima cantidad esperada del Token B
                sqrtPriceLimitX96: 0 // Ni puta idea
            });

            // Realiza la llamada. Si todo va bien reinvierte los assets obtenidos tras el swap, devuelve
            // la cantidad de assets obtenidos y emite un evento. En caso de error revierte
            try uniswap_router.exactInputSingle(params) returns (uint256 amount_out) {
                compound_comet.supply(asset_address, amount_out);
                profit = amount_out;
                emit Harvested(msg.sender, profit);
            } catch {
                revert CompoundStrategy__SwapFailed();
            }
        } catch {
            revert CompoundStrategy__HarvestFailed();
        }
    }

    //* Funciones de consulta

    /**
     * @notice Devuelve el total de assets bajo gestion en Compound
     * @dev Compound v3 usa accounting interno, consulta balance del usuario en el Comet
     *      por lo que no hay que hacer cálculos extra
     * @return total Cantidad de assets depositados + yield acumulado
     */
    function totalAssets() external view returns (uint256 total) {
        return compound_comet.balanceOf(address(this));
    }

    /**
     * @notice Devuelve el APY actual de Compound
     * @dev Calcula APY desde el supply rate que devuelve Compound
     * @dev Supply rate esta en por segundo (1e18 base), convertimos a basis points anuales
     * @return apyBasisPoints APY en basis points (350 = 3.5%)
     */
    function apy() external view returns (uint256 apyBasisPoints) {
        // Obtiene utilizacion actual del pool
        uint256 utilization = compound_comet.getUtilization();

        // Obtiene supply rate basado en utilizacion (Compound V3 devuelve uint64)
        uint64 supply_rate_per_second = compound_comet.getSupplyRate(utilization);

        // Convierte rate por segundo a APY anual en basis points
        // Cast a uint256 para evitar overflow en multiplicacion
        // supply_rate * seconds_per_year / 1e18 * 10000 = basis points
        // Simplificado: (rate * 31536000 * 10000) / 1e18
        apyBasisPoints = (uint256(supply_rate_per_second) * 315360000000) / 1e18;
    }

    /**
     * @notice Devuelve el nombre de la estrategia
     * @return strategyName Nombre descriptivo de la estrategia
     */
    function name() external pure returns (string memory strategyName) {
        return "Compound v3 Strategy";
    }

    /**
     * @notice Devuelve el address del asset
     * @return assetAddress Direccion del asset subyacente
     */
    function asset() external view returns (address assetAddress) {
        return asset_address;
    }

    /**
     * @notice Devuelve el supply rate actual de Compound
     * @dev Util para debugging y verificacion de APY
     * @return rate Supply rate por segundo (base 1e18) convertido a uint256
     */
    function getSupplyRate() external view returns (uint256 rate) {
        return uint256(compound_comet.getSupplyRate(compound_comet.getUtilization()));
    }

    /**
     * @notice Devuelve la utilizacion actual del pool de Compound
     * @dev Utilization = borrowed / supplied
     * @return utilization Porcentaje de utilizacion (base 1e18, ej: 0.5e18 = 50%)
     */
    function getUtilization() external view returns (uint256 utilization) {
        return compound_comet.getUtilization();
    }

    /**
     * @notice Devuelve los rewards pendientes de reclamar
     * @dev Util para estimar profit del harvest antes de ejecutarlo
     * @return pending Cantidad de rewards (COMP) pendientes
     */
    function pendingRewards() external view returns (uint256 pending) {
        // Realiza la llamada a Compound para obtener el balance de los rewards de este contrato
        return compound_rewards.getRewardOwed(address(compound_comet), address(this)).owed;
    }
}
