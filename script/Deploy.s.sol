// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {Vault} from "../src/core/Vault.sol";
import {StrategyManager} from "../src/core/StrategyManager.sol";
import {AaveStrategy} from "../src/strategies/AaveStrategy.sol";
import {CompoundStrategy} from "../src/strategies/CompoundStrategy.sol";

/**
 * @title Deploy
 * @author cristianrisueo
 * @notice Script de despliegue del protocolo VynX V1 en Ethereum Mainnet
 * @dev Despliega los 4 contratos y resuelve la dependencia circular entre vault y manager
 *      El deployer (msg.sender) queda como owner de vault, manager, y como treasury/founder
 *
 * Secuencia de despliegue:
 *   1. StrategyManager   — necesita address mainnet de WETH
 *   2. AaveStrategy      — necesita address mainnet de manager, WETH, Aave Pool
 *   3. CompoundStrategy  — necesita address mainnet de manager, WETH, Compound Comet
 *   4. Vault             — necesita address mainnet de: WETH, manager, treasury, founder
 *   5. manager.initialize(vault)        — resuelve dependencia circular
 *   6. manager.addStrategy(aave)        — registra Aave
 *   7. manager.addStrategy(compound)    — registra Compound
 *   8. vault.setOfficialKeeper(deployer, true) — configura keeper oficial
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

    /// @notice Aave v3 RewardsController
    address constant AAVE_REWARDS = 0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb;

    /// @notice Compound v3 CometRewards
    address constant COMPOUND_REWARDS = 0x1B0e765F6224C21223AeA2af16c1C46E38885a40;

    /// @notice Token AAVE (reward de Aave v3)
    address constant AAVE_TOKEN = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;

    /// @notice Token COMP (reward de Compound v3)
    address constant COMP_TOKEN = 0xc00e94Cb662C3520282E6f5717214004A7f26888;

    /// @notice Uniswap V3 SwapRouter
    address constant UNISWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    /// @notice Fee tier del pool Uniswap V3 (3000 = 0.3%)
    uint24 constant POOL_FEE = 3000;

    //* Entry point

    /**
     * @notice Despliega el protocolo completo
     * @dev El deployer (quien firma la transacción) se asigna como owner del protocolo, treasury y founder
     *      Tras el despliegue, el owner puede cambiar treasury via setTreasury() y founder via setFounder()
     */
    function run() external {
        // Obtiene la private key del deployer desde la variable de entorno y el address asociada a esta
        uint256 deployer_pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployer_pk);

        // Logs de inicio de deploy en Mainnet
        console.log("=== VynX V1 Deploy ===");
        console.log("Deployer:", deployer);
        console.log("Red: Ethereum Mainnet");

        // Comienza el broadcast a mainnet
        vm.startBroadcast(deployer_pk);

        // 1. StrategyManager: cerebro de allocation, sin address del vault todavia
        StrategyManager manager = new StrategyManager(WETH);
        console.log("StrategyManager:", address(manager));

        // 2. AaveStrategy: deposita WETH en Aave v3 Pool, cosecha rewards via Uniswap V3
        AaveStrategy aave_strategy =
            new AaveStrategy(address(manager), AAVE_POOL, AAVE_REWARDS, WETH, AAVE_TOKEN, UNISWAP_ROUTER, POOL_FEE);
        console.log("AaveStrategy:", address(aave_strategy));

        // 3. CompoundStrategy: deposita WETH en Compound v3 Comet, cosecha rewards via Uniswap V3
        CompoundStrategy compound_strategy = new CompoundStrategy(
            address(manager), COMPOUND_COMET, COMPOUND_REWARDS, WETH, COMP_TOKEN, UNISWAP_ROUTER, POOL_FEE
        );
        console.log("CompoundStrategy:", address(compound_strategy));

        // 4. Vault: vault ERC4626, deployer como treasury y founder inicialmente
        Vault vault = new Vault(WETH, address(manager), deployer, deployer);
        console.log("Vault:", address(vault));

        // 5. Resuelve dependencia circular: Manager ahora tiene el address del vault como "owner/invoker"
        manager.initialize(address(vault));
        console.log("Vault inicializado en manager");

        // 6. Añade las estrategias al manager
        manager.addStrategy(address(aave_strategy));
        manager.addStrategy(address(compound_strategy));
        console.log("Estrategias registradas: Aave + Compound");

        // 8. Configura al deployer como keeper oficial (address que llama al harvest sin cobrar fee)
        vault.setOfficialKeeper(deployer, true);
        console.log("Deployer configurado como keeper oficial");

        // Detiene el broadcast y muestra mensaje de deployment completado
        vm.stopBroadcast();
        console.log("=== Deploy completado ===");
    }
}
