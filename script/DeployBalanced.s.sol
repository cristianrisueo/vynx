// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {StrategyManager} from "../src/core/StrategyManager.sol";
import {IStrategyManager} from "../src/interfaces/core/IStrategyManager.sol";
import {IVault} from "../src/interfaces/core/IVault.sol";
import {Vault} from "../src/core/Vault.sol";
import {LidoStrategy} from "../src/strategies/LidoStrategy.sol";
import {AaveStrategy} from "../src/strategies/AaveStrategy.sol";
import {CurveStrategy} from "../src/strategies/CurveStrategy.sol";

/**
 * @title DeployBalanced
 * @author cristianrisueo
 * @notice Script de deployment del tier Balanced de VynX V2
 * @dev Despliega: StrategyManager + LidoStrategy + AaveStrategy + CurveStrategy + Vault
 *
 * Tier Balanced:
 *   - Estrategias: Lido (staking) + Aave (wstETH lending) + Curve (stETH/ETH LP)
 *   - Allocations: max 50% por estrategia, min 20%
 *   - Rebalance: threshold 2%, min TVL 8 ETH
 *
 * Uso:
 *   forge script script/DeployBalanced.s.sol --rpc-url $MAINNET_RPC_URL --broadcast
 */
contract DeployBalanced is Script {
    //* Addresses mainnet

    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_REWARDS = 0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb;
    address constant AAVE_TOKEN = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;
    address constant CURVE_POOL = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;
    address constant CURVE_GAUGE = 0x182B723a58739a9c974cFDB385ceaDb237453c28;
    address constant CURVE_LP = 0x06325440D014e39736583c165C2963BA99fAf14E;
    address constant CRV_TOKEN = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address constant UNI_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    function run() external {
        // Lee treasury y founder desde variables de entorno
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address founder = vm.envAddress("FOUNDER_ADDRESS");

        // Validacion explicita: revierte con mensaje claro si no estan seteadas
        require(treasury != address(0), "DeployBalanced: TREASURY_ADDRESS no seteada");
        require(founder != address(0), "DeployBalanced: FOUNDER_ADDRESS no seteada");

        vm.startBroadcast();

        // 1. Despliega StrategyManager (necesita existir antes que las estrategias)
        StrategyManager manager = new StrategyManager(
            WETH,
            IStrategyManager.TierConfig({
                max_allocation_per_strategy: 5000, // 50%
                min_allocation_threshold: 2000, // 20%
                rebalance_threshold: 200, // 2%
                min_tvl_for_rebalance: 8 ether
            })
        );

        // 2. Despliega las 3 estrategias (necesitan address del manager)
        LidoStrategy lido_strat = new LidoStrategy(
            address(manager),
            WSTETH,
            WETH,
            UNI_ROUTER,
            uint24(500) // wstETH/WETH 0.05%
        );

        AaveStrategy aave_strat = new AaveStrategy(
            address(manager),
            WETH, // asset del StrategyManager
            AAVE_POOL,
            AAVE_REWARDS,
            AAVE_TOKEN,
            UNI_ROUTER,
            uint24(3000), // AAVE/WETH 0.3%
            WSTETH,
            WETH,
            STETH,
            CURVE_POOL
        );

        CurveStrategy curve_strat = new CurveStrategy(
            address(manager),
            STETH, // lido (stETH para submit)
            CURVE_POOL,
            CURVE_GAUGE,
            CURVE_LP,
            CRV_TOKEN,
            WETH,
            UNI_ROUTER,
            uint24(3000) // CRV/WETH 0.3%
        );

        // 3. Despliega Vault (necesita address del manager)
        Vault vault = new Vault(
            WETH,
            address(manager),
            treasury,
            founder,
            IVault.TierConfig({
                idle_threshold: 8 ether,
                min_profit_for_harvest: 0.08 ether,
                max_tvl: 1000 ether,
                min_deposit: 0.01 ether
            })
        );

        // 4. Resuelve la dependencia circular: conecta el vault al manager
        manager.initialize(address(vault));

        // 5. Registra las 3 estrategias en el manager
        manager.addStrategy(address(lido_strat));
        manager.addStrategy(address(aave_strat));
        manager.addStrategy(address(curve_strat));

        vm.stopBroadcast();

        // Log de addresses deployadas
        console.log("=== VynX V2 Balanced Tier ===");
        console.log("StrategyManager:", address(manager));
        console.log("Vault:          ", address(vault));
        console.log("LidoStrategy:   ", address(lido_strat));
        console.log("AaveStrategy:   ", address(aave_strat));
        console.log("CurveStrategy:  ", address(curve_strat));
    }
}
