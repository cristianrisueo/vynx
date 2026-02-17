// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/**
 * @title ICurveGauge
 * @author cristianrisueo
 * @notice Interfaz del contrato de staking del pool stETH/ETH de Curve
 *
 * @dev Gauge (medir) es el nombre que Curve le da a su contrato de staking
 *      permite stakear LP tokens del pool para recibir rewards (CRV, LDO... hay 8)
 *      Estos putos primitivos siempre poniéndoles nombres frikis, CurveStake joder
 *
 * @dev Los contratos reales de Curve están escritos en Vyper
 *      Esta interfaz Solidity está derivada del ABI del contrato deployado
 *      Solo contiene las funciones necesarias para CurveStrategy
 *
 * @dev Signatures verificadas contra el contrato de mainnet:
 *      https://etherscan.io/address/0x182B723a58739a9c974cFDB385ceaDb237453c28
 */
interface ICurveGauge {
    /**
     * @notice Deposita LP tokens en el gauge
     * @dev El caller debe haber aprobado previamente los LP tokens al gauge
     * @param _value Cantidad de LP tokens a stakear
     */
    function deposit(uint256 _value) external;

    /**
     * @notice Redime los LP tokens del gauge
     * @param _value Cantidad de LP tokens a retirar
     */
    function withdraw(uint256 _value) external;

    /**
     * @notice Reclama los rewards acumulados (CRV, LDO, etc.)
     * @dev En el gauge de stETH, claim_rewards permite reclamar los rewards de
     *      cualquier address, no solo propios (permite economías de keeper bots)
     * @param _addr Dirección para la cual reclamar rewards
     */
    function claim_rewards(address _addr) external;

    /**
     * @notice Devuelve el balance de LP tokens stakeados de una dirección
     * @param _addr Dirección a consultar
     * @return Balance de LP tokens stakeados
     */
    function balanceOf(address _addr) external view returns (uint256);

    /**
     * @notice Devuelve la dirección del token de rewards en el índice dado
     * @dev El gauge soporta hasta 8 reward tokens (MAX_REWARDS = 8).
     *      normalmente: index 0 = CRV, index 1 = LDO, el resto los desconozco
     * @param _index Índice del reward token
     * @return Dirección del reward token (address(0) si no hay más)
     */
    function reward_tokens(uint256 _index) external view returns (address);
}
