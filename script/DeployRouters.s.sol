// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {Router} from "../src/periphery/Router.sol";

/**
 * @title DeployRouters
 * @author cristianrisueo
 * @notice Script de deployment de los dos Routers periféricos de VynX V2
 * @dev Despliega un Router por cada vault (Balanced y Aggressive)
 *
 * El Router es stateless: vault es immutable, por lo que se necesita
 * una instancia por vault.
 *
 * Uso:
 *   forge script script/DeployRouters.s.sol \
 *     --rpc-url $MAINNET_RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast \
 *     --verify \
 *     --etherscan-api-key $ETHERSCAN_API_KEY \
 *     -vvvv
 */
contract DeployRouters is Script {
    //* Addresses mainnet

    address constant WETH             = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant UNISWAP_ROUTER   = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant VAULT_BALANCED   = 0x9D002dF2A5B632C0D8022a4738C1fa7465d88444;
    address constant VAULT_AGGRESSIVE = 0xA8cA9d84e35ac8F5af6F1D91fe4bE1C0BAf44296;

    function run() external {
        vm.startBroadcast();

        // Router para el tier Balanced (Lido + Aave wstETH + Curve)
        Router router_balanced = new Router(WETH, VAULT_BALANCED, UNISWAP_ROUTER);

        // Router para el tier Aggressive (Curve + Uniswap V3)
        Router router_aggressive = new Router(WETH, VAULT_AGGRESSIVE, UNISWAP_ROUTER);

        vm.stopBroadcast();

        // Log de addresses deployadas
        console.log("=== VynX V2 Routers ===");
        console.log("Router Balanced:   ", address(router_balanced));
        console.log("Router Aggressive: ", address(router_aggressive));
    }
}
