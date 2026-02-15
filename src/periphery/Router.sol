// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IRouter} from "../interfaces/periphery/IRouter.sol";

/**
 * @title Router
 * @author cristianrisueo
 * @notice Contrato periférico que permite depositar cualquier token (ETH, USDC, DAI, etc.) en el Vault de VynX
 * @dev Swapea tokens a WETH vía Uniswap V3 y luego deposita en el Vault
 * @dev Principios de diseño del Router:
 *      - El Vault se mantiene como un ERC4626 puro (solo WETH)
 *      - El Router es un periférico sin estado (no retiene fondos entre transacciones)
 *      - Los usuarios reciben shares del vault directamente (el Router no custodia shares)
 *      - Pool con fee variable especificado por el frontend
 * @dev Características de seguridad:
 *      - ReentrancyGuard en todas las funciones públicas
 *      - Protección ante slippage mediante el parámetro min_weth_out
 *      - Verificación de balance (cumplimiento del diseño sin estado)
 *      - Sin privilegios especiales en el Vault (el Router es un usuario normal)
 */
contract Router is IRouter, ReentrancyGuard {
    //* library attachments

    /**
     * @notice Usa SafeERC20 para todas las operaciones IERC20 de manera segura
     * @dev Evita errores comunes con tokens legacy o mal implementados
     */
    using SafeERC20 for IERC20;

    //* Errores

    /**
     * @notice Error cuando se pasa la dirección cero al constructor
     */
    error Router__ZeroAddress();

    /**
     * @notice Error al intentar depositar una cantidad de cero
     */
    error Router__ZeroAmount();

    /**
     * @notice Error cuando se activa la protección ante slippage (se recibió menos del mínimo)
     */
    error Router__SlippageExceeded();

    /**
     * @notice Error cuando la operación de wrap de ETH falla
     */
    error Router__ETHWrapFailed();

    /**
     * @notice Error cuando quedan fondos atrapados en el Router tras la operación (violación del diseño sin estado)
     */
    error Router__FundsStuck();

    /**
     * @notice Error cuando el usuario intenta depositar WETH vía Router en vez de directamente en el Vault
     */
    error Router__UseVaultForWETH();

    /**
     * @notice Error cuando se recibe ETH de una dirección no autorizada (solo el contrato WETH puede enviar ETH)
     */
    error Router__UnauthorizedETHSender();

    /**
     * @notice Error cuando la operación de unwrap de WETH a ETH falla
     */
    error Router__ETHUnwrapFailed();

    //* Eventos: Heredados de la interfaz, no es necesario implementarlos

    //* Variables de estado

    /// @notice Dirección del token WETH
    address public immutable weth;

    /// @notice Dirección del Vault de VynX (compatible con ERC4626)
    address public immutable vault;

    /// @notice Dirección del SwapRouter de Uniswap V3
    address public immutable swap_router;

    //* Constructor

    /**
     * @notice Constructor del Router
     * @dev Inicializa las direcciones inmutables y aprueba la transferencia de WETH al Vault
     * @param _weth Dirección del token WETH
     * @param _vault Dirección del Vault de VynX
     * @param _swap_router Dirección del SwapRouter de Uniswap V3
     */
    constructor(address _weth, address _vault, address _swap_router) {
        // Comprueba que las direcciones no sean address(0)
        if (_weth == address(0)) revert Router__ZeroAddress();
        if (_vault == address(0)) revert Router__ZeroAddress();
        if (_swap_router == address(0)) revert Router__ZeroAddress();

        // Setea las direcciones
        weth = _weth;
        vault = _vault;
        swap_router = _swap_router;

        // Aprueba al vault la transferencia de todo el WETH de este contrato
        IERC20(_weth).forceApprove(_vault, type(uint256).max);
    }

    //* Funciones principales - Depósitos y retiros de ETH y ERC20

    /**
     * @notice Deposita ETH nativo en el Vault (hace wrap a WETH primero)
     * @dev Envuelve ETH a WETH, deposita en el Vault y emite shares a msg.sender
     * @dev Flujo:
     *      1. Recibe ETH mediante msg.value
     *      2. Envuelve ETH a WETH
     *      3. Deposita WETH en el Vault
     *      4. El Vault emite shares directamente al usuario
     * @return shares Cantidad de shares del vault recibidas por el usuario
     */
    function zapDepositETH() external payable nonReentrant returns (uint256 shares) {
        // Comprueba que msg.value no sea cero
        if (msg.value == 0) revert Router__ZeroAmount();

        // Envuelve ETH a WETH usando una función interna (aquí el balance ya es WETH 1:1)
        _wrapETH(msg.value);

        // Deposita WETH en el Vault (minteando las shares al caller, no al router)
        shares = IERC4626(vault).deposit(msg.value, msg.sender);

        // Comprueba que el router tenga balance 0 de WETH tras la operación
        if (IERC20(weth).balanceOf(address(this)) != 0) revert Router__FundsStuck();

        // Emite evento de ZapDeposit
        emit ZapDeposit(msg.sender, address(0), msg.value, msg.value, shares);
    }

    /**
     * @notice Deposita token ERC20 en el Vault (hace swap a WETH primero)
     * @dev Hace swap token_in → WETH vía Uniswap V3 usando el pool especificado, luego deposita en el Vault
     * @dev Flow:
     *      1. Transfiere token_in del usuario al Router
     *      2. Hace swap token_in → WETH (Uniswap V3, pool especificado por pool_fee)
     *      3. Valida protección de slippage
     *      4. Deposita WETH en el Vault
     *      5. El Vault acuña shares directamente al usuario
     *      6. Comprueba que el Router siga stateless (balance = 0)
     * @dev Tokens soportados: Cualquier token con par WETH en Uniswap V3
     * @dev Pools comunes: USDC/DAI/USDT típicamente usan 500 (0.05%), WBTC usa 3000 (0.3%)
     * @dev El frontend debe calcular el pool óptimo antes de llamar, escoge el más rentable para el par
     *      de tokens automáticamente
     * @param token_in Token a depositar
     * @param amount_in Cantidad de token_in a depositar
     * @param pool_fee Fee tier del pool de Uniswap V3 (100, 500, 3000, o 10000)
     * @param min_weth_out WETH mínimo a recibir del swap (protección de slippage)
     * @return shares Cantidad de shares del vault recibidas
     */
    function zapDepositERC20(address token_in, uint256 amount_in, uint24 pool_fee, uint256 min_weth_out)
        external
        nonReentrant
        returns (uint256 shares)
    {
        // Comprueba que token_in no sea address(0), si lo es ha mandado ETH o nos está trolleando
        if (token_in == address(0)) revert Router__ZeroAddress();

        // Comprueba que token_in no sea WETH (debería usar vault.deposit() directamente para WETH)
        if (token_in == weth) revert Router__UseVaultForWETH();

        // Comprueba que amount_in no sea cero
        if (amount_in == 0) revert Router__ZeroAmount();

        // Transfiere los tokens especificados del usuario al Router
        IERC20(token_in).safeTransferFrom(msg.sender, address(this), amount_in);

        // Swapea token_in → WETH usando una función interna (que llama a Uniswap V3, al pool especificado)
        uint256 weth_out = _swapToWETH(token_in, amount_in, pool_fee, min_weth_out);

        // Deposita WETH en el Vault (minteando las shares al caller, no al router)
        shares = IERC4626(vault).deposit(weth_out, msg.sender);

        // Comprueba que el router tenga balance 0 de WETH tras la operación
        if (IERC20(weth).balanceOf(address(this)) != 0) revert Router__FundsStuck();

        // Emite evento ZapDeposit
        emit ZapDeposit(msg.sender, token_in, amount_in, weth_out, shares);
    }

    /**
     * @notice Retira shares del Vault y recibe ETH nativo
     * @dev Redime shares del Vault por WETH, unwrappea WETH a ETH, envía ETH al usuario
     * @dev Flow:
     *      1. Transfiere shares del usuario al Router (requiere aprobación previa)
     *      2. Redime shares en el Vault → recibe WETH
     *      3. Unwrappea WETH → ETH
     *      5. Transfiere ETH al usuario
     *      6. Comrpueba que el Router siga stateless (balance = 0)
     * @param shares Cantidad de shares a quemar del vault
     * @return eth_out Cantidad de ETH recibida por el usuario
     */
    function zapWithdrawETH(uint256 shares) external nonReentrant returns (uint256 eth_out) {
        // Comprueba que shares a redimir no sea cero
        if (shares == 0) revert Router__ZeroAmount();

        // Transferir shares del usuario al Router (requiere aprobación previa)
        IERC20(vault).safeTransferFrom(msg.sender, address(this), shares);

        // Redime shares del Vault y obtiene el WETH correspondiente
        uint256 weth_redeemed = IERC4626(vault).redeem(shares, address(this), address(this));

        // Unwrappear WETH a ETH usando función interna (eth_out se podría omitir, la tenemos por conveniencia)
        eth_out = _unwrapWETH(weth_redeemed);

        // Transfiere el ETH al usuario
        (bool success,) = msg.sender.call{value: eth_out}("");
        if (!success) revert Router__ETHUnwrapFailed();

        // Comprueba que el router tenga balance 0 de WETH tras la operación
        if (IERC20(weth).balanceOf(address(this)) != 0) revert Router__FundsStuck();

        // Emite evento ZapWithdraw
        emit ZapWithdraw(msg.sender, shares, weth_redeemed, address(0), eth_out);
    }

    /**
     * @notice Retira shares del vault y recibe token ERC20 (hace swap desde WETH)
     * @dev Redime shares por WETH, hace swap WETH → token_out vía Uniswap V3, envía token_out al usuario
     * @dev Flow:
     *      1. Transfiere shares del usuario al Router (requiere aprobación previa)
     *      2. Router redime shares en el Vault → recibe WETH
     *      3. Hace swap WETH → token_out (Uniswap V3, pool especificado por pool_fee)
     *      4. Valida protección de slippage
     *      5. Transfiere token_out al usuario
     *      6. Comprueba que el Router siga stateless tras la operación (balances = 0)
     * @dev El frontend debe calcular el pool óptimo antes de llamar
     * @param shares Cantidad de shares a quemar del vault
     * @param token_out Token a recibir
     * @param pool_fee Fee tier del pool de Uniswap V3 (100, 500, 3000, o 10000)
     * @param min_token_out Mínimo token_out a recibir tras el swap (protección de slippage)
     * @return amount_out Cantidad de token_out recibida por el usuario
     */
    function zapWithdrawERC20(uint256 shares, address token_out, uint24 pool_fee, uint256 min_token_out)
        external
        nonReentrant
        returns (uint256 amount_out)
    {
        // Comprueba que token_out no sea address(0)
        if (token_out == address(0)) revert Router__ZeroAddress();

        // Comprueba que token_out no sea WETH (debería usar vault.redeem() directamente para WETH)
        if (token_out == weth) revert Router__UseVaultForWETH();

        // Comprueba que las shares a redimir no sean cero
        if (shares == 0) revert Router__ZeroAmount();

        // Transfiere shares del usuario al Router (requiere aprobación previa)
        IERC20(vault).safeTransferFrom(msg.sender, address(this), shares);

        // Redime shares en el vault y recibe WETH
        uint256 weth_redeemed = IERC4626(vault).redeem(shares, address(this), address(this));

        // Hacer swap WETH → token_out usando función interna
        amount_out = _swapFromWETH(weth_redeemed, token_out, pool_fee, min_token_out);

        // Transfiere el token_out al usuario
        IERC20(token_out).safeTransfer(msg.sender, amount_out);

        // Comprueba que el router tenga balance 0 de token_out después de la operación
        if (IERC20(token_out).balanceOf(address(this)) != 0) revert Router__FundsStuck();

        // Emite evento ZapWithdraw
        emit ZapWithdraw(msg.sender, shares, weth_redeemed, token_out, amount_out);
    }

    //* Funciones internas

    /**
     * @notice Wrappea ETH a WETH
     * @dev Llama a WETH.deposit() con el valor en ETH para recibir tokens WETH a 1:1
     *      No necesitamos devolver nada porque el WETH estará en el balance del contrato
     * @param amount Cantidad de ETH a envolver
     */
    function _wrapETH(uint256 amount) internal {
        // Llama a WETH.deposit() con el valor en ETH y comprueba que el wrap fue exitoso
        (bool success,) = weth.call{value: amount}(abi.encodeWithSignature("deposit()"));
        if (!success) revert Router__ETHWrapFailed();
    }

    /**
     * @notice Unwrappea WETH a ETH nativo
     * @dev Llama a WETH.withdraw() para convertir WETH a ETH a proporción 1:1
     *      Aquí si que necesitamos devolver la cantidad para usarla en el swap por ERC20
     * @param amount Cantidad de WETH a unwrappear
     * @return eth_out Cantidad de ETH recibida
     */
    function _unwrapWETH(uint256 amount) internal returns (uint256 eth_out) {
        // Llama a WETH.withdraw() con la cantidad de WETH y comprueba que el unwrap fue exitoso
        (bool success,) = weth.call(abi.encodeWithSignature("withdraw(uint256)", amount));
        if (!success) revert Router__ETHUnwrapFailed();

        // Devuelve la cantidad unwrapeada
        eth_out = amount;
    }

    /**
     * @notice Hace swap de ERC20 a WETH vía Uniswap V3
     * @dev Construye Uniswap V3 ISwapRouter.ExactInputSingleParams y ejecuta el swap
     * @param token_in Token a swapear
     * @param amount_in Cantidad a swapear
     * @param pool_fee Fee tier del pool de Uniswap V3 a usar
     * @param min_weth_out Mínimo WETH a recibir (protección de slippage)
     * @return weth_out WETH real recibido
     */
    function _swapToWETH(address token_in, uint256 amount_in, uint24 pool_fee, uint256 min_weth_out)
        internal
        returns (uint256 weth_out)
    {
        // Aprueba al router de Uniswap para hacer transferFrom de token_in
        IERC20(token_in).forceApprove(swap_router, amount_in);

        // Construye los parámetros del swap para Uniswap V3
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: token_in, // Token 1
            tokenOut: weth, // Token 2
            fee: pool_fee, // Fee
            recipient: address(this), // Recipient (este contrato)
            deadline: block.timestamp, // A ejecutar máximo en este bloque
            amountIn: amount_in, // Cantidad de token 1 entregada
            amountOutMinimum: min_weth_out, // Cantidad de token 2 esperada
            sqrtPriceLimitX96: 0 // Sin límite de precio
        });

        // Ejecuta el swap y obtiene la cantidad de WETH recibida
        weth_out = ISwapRouter(swap_router).exactInputSingle(params);

        // Comprueba que la cantidad recibida sea mayor que la esperada (protección de slippage)
        if (weth_out < min_weth_out) revert Router__SlippageExceeded();
    }

    /**
     * @notice Hace swap de WETH a token ERC20 vía Uniswap V3
     * @dev Construye Uniswap V3 ISwapRouter.ExactInputSingleParams y ejecuta el swap
     * @param weth_in Cantidad de WETH a swapear
     * @param token_out Token a recibir del swap
     * @param pool_fee Fee tier del pool de Uniswap V3 a usar
     * @param min_token_out Mínimo token_out a recibir (protección de slippage)
     * @return amount_out Cantidad real de token_out recibido del swap
     */
    function _swapFromWETH(uint256 weth_in, address token_out, uint24 pool_fee, uint256 min_token_out)
        internal
        returns (uint256 amount_out)
    {
        // Aprueba al router de Uniswap para hacer transferFrom de WETH
        IERC20(weth).forceApprove(swap_router, weth_in);

        // Construye los parámetros del swap para Uniswap V3
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: weth, // Token 1
            tokenOut: token_out, // Token 2
            fee: pool_fee, // Fee
            recipient: address(this), // Recipiente (este contrato)
            deadline: block.timestamp, // A ejecutar máximo en este bloque
            amountIn: weth_in, // Cantidad del token 1 entregada
            amountOutMinimum: min_token_out, // Cantidad de token 2 esperada
            sqrtPriceLimitX96: 0 // Sin límite de precio
        });

        // Ejecuta el swap y obtener cantidad de token_out recibida
        amount_out = ISwapRouter(swap_router).exactInputSingle(params);

        // Comprueba que la cantidad recibida sea mayor que la esperada (protección de slippage)
        if (amount_out < min_token_out) revert Router__SlippageExceeded();
    }

    /**
     * @notice Fallback para recibir ETH (necesario para el unwrap de WETH)
     * @dev Solo acepta ETH del contrato WETH para evitar envíos accidentales de ETH
     *      En caso de recibir ETH de otro address revierte la operación
     */
    receive() external payable {
        if (msg.sender != weth) revert Router__UnauthorizedETHSender();
    }
}
