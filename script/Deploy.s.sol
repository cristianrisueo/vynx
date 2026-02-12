// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {StrategyVault} from "../src/core/StrategyVault.sol";
import {StrategyManager} from "../src/core/StrategyManager.sol";
import {AaveStrategy} from "../src/strategies/AaveStrategy.sol";
import {CompoundStrategy} from "../src/strategies/CompoundStrategy.sol";

/**
 * @title Deploy
 * @author cristianrisueo
 * @notice Script de despliegue del protocolo Multi-Strategy Vault en Ethereum Mainnet
 * @dev Despliega los 4 contratos y resuelve la dependencia circular entre vault y manager
 *      El deployer (msg.sender) queda como owner de vault, manager, y como fee_receiver
 *
 * Secuencia de despliegue:
 *   1. StrategyManager   — necesita address mainnet de WETH
 *   2. AaveStrategy      — necesita address mainnet de manager, WETH, Aave Pool
 *   3. CompoundStrategy  — necesita address mainnet de manager, WETH, Compound Comet
 *   4. StrategyVault     — necesita address mainnet de: WETH, manager y fee_receiver
 *   5. manager.initializeVault(vault)   — resuelve dependencia circular. Setea el vault como owner de manager
 *   6. manager.addStrategy(aave)        — registra Aave
 *   7. manager.addStrategy(compound)    — registra Compound
 *
 * Uso:
 *   forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL --broadcast --verify
 *
 *   Dry-run (sin broadcast, prueba real de que todo ok pero no te cobran):
 *   forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL -vvv
 */
contract Deploy is Script {
    //* Direcciones de Mainnet

    /// @notice WETH (Wrapped Ether)
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @notice Aave v3 Pool
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    /// @notice Compound v3 Comet (WETH market)
    address constant COMPOUND_COMET = 0xA17581A9E3356d9A858b789D68B4d866e593aE94;

    //* Entry point

    /**
     * @notice Despliega el protocolo completo
     * @dev El deployer (quien firma la transacción) se asigna como owner del protocolo y fee_receiver
     *      Tras el despliegue, el owner puede cambiar fee_receiver via setFeeReceiver()
     */
    function run() external {
        // Obtiene la private key del deployer desde la variable de entorno y el address asociada a esta
        uint256 deployer_pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployer_pk);

        // Logs de inicio de deploy en Mainnet
        console.log("=== Multi-Strategy Vault Deploy ===");
        console.log("Deployer:", deployer);
        console.log("Red: Ethereum Mainnet");

        // Comienza el broadcast a mainnet
        vm.startBroadcast(deployer_pk);

        // 1. StrategyManager: cerebro de allocation, sin address del vault todavia
        StrategyManager manager = new StrategyManager(WETH);
        console.log("StrategyManager:", address(manager));

        // 2. AaveStrategy: deposita WETH en Aave v3 Pool
        AaveStrategy aave_strategy = new AaveStrategy(address(manager), WETH, AAVE_POOL);
        console.log("AaveStrategy:", address(aave_strategy));

        // 3. CompoundStrategy: deposita WETH en Compound v3 Comet
        CompoundStrategy compound_strategy = new CompoundStrategy(address(manager), WETH, COMPOUND_COMET);
        console.log("CompoundStrategy:", address(compound_strategy));

        // 4. StrategyVault: vault ERC4626, deployer como fee_receiver
        StrategyVault vault = new StrategyVault(WETH, address(manager), deployer);
        console.log("StrategyVault:", address(vault));

        // 5. Resuelve dependencia circular: Manager ahora tiene el address del vault como "owner/invoker"
        manager.initializeVault(address(vault));
        console.log("Vault inicializado en manager");

        // 6. Añade las estrategias al manager
        manager.addStrategy(address(aave_strategy));
        manager.addStrategy(address(compound_strategy));
        console.log("Estrategias registradas: Aave + Compound");

        // Detiene el broadcast y muestra mensaje de deployment completado
        vm.stopBroadcast();

        console.log("=== Deploy completado ===");
    }
}
