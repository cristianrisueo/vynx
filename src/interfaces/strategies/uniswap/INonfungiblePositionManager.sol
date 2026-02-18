// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/**
 * @title INonfungiblePositionManager
 * @author cristianrisueo
 * @notice Interfaz mínima del NonfungiblePositionManager de Uniswap V3
 *
 * @dev No importamos la interfaz oficial de v3-periphery porque depende de IERC721Metadata e
 *      IERC721Enumerable de OpenZeppelin v4 (en token/ERC721/), que en OZ v5 se movieron a
 *      token/ERC721/extensions/. Solo necesitamos las funciones de gestión de posiciones.
 *
 * @dev Signatures verificadas contra el contrato deployado en mainnet:
 *      https://etherscan.io/address/0xC36442b4a4522E871399CD717aBDD847Ab11FE88
 */
interface INonfungiblePositionManager {
    /**
     * @notice Parámetros para crear una nueva posición LP
     */
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    /**
     * @notice Parámetros para aumentar la liquidez de una posición existente
     */
    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    /**
     * @notice Parámetros para disminuir la liquidez de una posición
     */
    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    /**
     * @notice Parámetros para recoger tokens pendientes (fees + liquidez retirada)
     */
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    /**
     * @notice Crea una nueva posición LP en el rango [tickLower, tickUpper] y mintea un NFT
     * @dev El NFT representa la posición. El caller recibe el tokenId como dueño de la posición
     * @param params Parámetros de la posición (ver MintParams)
     * @return tokenId ID del NFT creado
     * @return liquidity Liquidez añadida al pool
     * @return amount0 Token0 efectivamente depositado
     * @return amount1 Token1 efectivamente depositado
     */
    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    /**
     * @notice Aumenta la liquidez de una posición existente sin cambiar el rango de ticks
     * @param params Parámetros del aumento de liquidez (ver IncreaseLiquidityParams)
     * @return liquidity Liquidez añadida
     * @return amount0 Token0 efectivamente depositado
     * @return amount1 Token1 efectivamente depositado
     */
    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);

    /**
     * @notice Disminuye la liquidez de una posición, pasando los tokens a estado "owed"
     * @dev Los tokens NO se transfieren automáticamente: hay que llamar a collect() después
     * @param params Parámetros de la reducción de liquidez (ver DecreaseLiquidityParams)
     * @return amount0 Token0 movido a estado owed
     * @return amount1 Token1 movido a estado owed
     */
    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    /**
     * @notice Recoge los tokens en estado "owed" de la posición (fees + liquidez retirada)
     * @dev Combina fees acumulados y tokens de decreaseLiquidity en una sola llamada
     * @param params Parámetros de la recogida (ver CollectParams)
     * @return amount0 Token0 recogido
     * @return amount1 Token1 recogido
     */
    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);

    /**
     * @notice Quema el NFT de una posición vacía (liquidity == 0 y sin tokens owed)
     * @dev Revierte si la posición aún tiene liquidez o tokens pendientes
     * @param tokenId ID del NFT a quemar
     */
    function burn(uint256 tokenId) external payable;

    /**
     * @notice Consulta los datos completos de una posición por su tokenId
     * @param tokenId ID del NFT de la posición
     * @return nonce Nonce usado para permisos
     * @return operator Operador aprobado para la posición
     * @return token0 Token de menor dirección del par
     * @return token1 Token de mayor dirección del par
     * @return fee Fee tier del pool (ej: 500 = 0.05%)
     * @return tickLower Tick inferior del rango
     * @return tickUpper Tick superior del rango
     * @return liquidity Liquidez activa actual en el rango
     * @return feeGrowthInside0LastX128 Acumulador de fees para token0
     * @return feeGrowthInside1LastX128 Acumulador de fees para token1
     * @return tokensOwed0 Token0 pendiente de collect (fees + liquidez retirada)
     * @return tokensOwed1 Token1 pendiente de collect (fees + liquidez retirada)
     */
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}
