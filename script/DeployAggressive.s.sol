// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {IVault} from "../src/interfaces/core/IVault.sol";
import {Vault} from "../src/core/Vault.sol";
import {IStrategyManager} from "../src/interfaces/core/IStrategyManager.sol";
import {StrategyManager} from "../src/core/StrategyManager.sol";
import {CurveStrategy} from "../src/strategies/CurveStrategy.sol";
import {UniswapV3Strategy} from "../src/strategies/UniswapV3Strategy.sol";

/**
 * @title DeployAggressive
 * @author cristianrisueo
 * @notice Script de deployment del tier Aggressive de VynX V2
 * @dev Despliega: StrategyManager + CurveStrategy + UniswapV3Strategy + Vault
 *
 * Tier Aggressive:
 *   - Estrategias: Curve (stETH/ETH LP) + Uniswap V3 (WETH/USDC LP concentrado)
 *   - Allocations: max 70% por estrategia, min 10%
 *   - Rebalance: threshold 3%, min TVL 12 ETH
 *
 * Uso:
 *   forge script script/DeployAggressive.s.sol --rpc-url $MAINNET_RPC_URL --broadcast
 */
contract DeployAggressive is Script {
    //* Addresses mainnet

    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant CURVE_POOL = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;
    address constant CURVE_GAUGE = 0x182B723a58739a9c974cFDB385ceaDb237453c28;
    address constant CURVE_LP = 0x06325440D014e39736583c165C2963BA99fAf14E;
    address constant CRV_TOKEN = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address constant UNI_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant UNI_POS_MGR = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant WETH_USDC_POOL = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;

    function run() external {
        // Lee treasury y founder desde variables de entorno
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address founder = vm.envAddress("FOUNDER_ADDRESS");

        // Validacion explicita: revierte con mensaje claro si no estan seteadas
        require(treasury != address(0), "DeployAggressive: TREASURY_ADDRESS no seteada");
        require(founder != address(0), "DeployAggressive: FOUNDER_ADDRESS no seteada");

        vm.startBroadcast();

        // 1. Despliega StrategyManager (necesita existir antes que las estrategias)
        StrategyManager manager = new StrategyManager(
            WETH,
            IStrategyManager.TierConfig({
                max_allocation_per_strategy: 7000, // 70%
                min_allocation_threshold: 1000, // 10%
                rebalance_threshold: 300, // 3%
                min_tvl_for_rebalance: 12 ether
            })
        );

        // 2. Despliega las 2 estrategias (necesitan address del manager)
        CurveStrategy curve_strat = new CurveStrategy(
            address(manager),
            STETH, // lido (stETH para submit)
            CURVE_POOL,
            CURVE_GAUGE,
            CURVE_LP,
            CRV_TOKEN,
            WETH,
            UNI_ROUTER,
            uint24(3000) // CRV/WETH fee 0.3%
        );

        UniswapV3Strategy uni_strat =
            new UniswapV3Strategy(address(manager), UNI_POS_MGR, UNI_ROUTER, WETH_USDC_POOL, WETH, USDC);

        // 3. Despliega Vault (necesita address del manager)
        Vault vault = new Vault(
            WETH,
            address(manager),
            treasury,
            founder,
            IVault.TierConfig({
                idle_threshold: 12 ether,
                min_profit_for_harvest: 0.12 ether,
                max_tvl: 1000 ether,
                min_deposit: 0.01 ether
            })
        );

        // 4. Resuelve la dependencia circular: conecta el vault al manager
        manager.initialize(address(vault));

        // 5. Registra las 2 estrategias en el manager
        manager.addStrategy(address(curve_strat));
        manager.addStrategy(address(uni_strat));

        vm.stopBroadcast();

        // Log de addresses deployadas
        console.log("=== VynX V2 Aggressive Tier ===");
        console.log("StrategyManager:   ", address(manager));
        console.log("Vault:             ", address(vault));
        console.log("CurveStrategy:     ", address(curve_strat));
        console.log("UniswapV3Strategy: ", address(uni_strat));
    }
}
