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
 * @notice Deployment script for VynX V1 protocol on Ethereum Mainnet
 * @dev Deploys the 4 contracts and resolves the circular dependency between vault and manager
 *      The deployer (msg.sender) remains as owner of vault, manager, and as treasury/founder
 *
 * Deployment sequence:
 *   1. StrategyManager   — needs mainnet address of WETH
 *   2. AaveStrategy      — needs mainnet address of manager, WETH, Aave Pool
 *   3. CompoundStrategy  — needs mainnet address of manager, WETH, Compound Comet
 *   4. Vault             — needs mainnet address of: WETH, manager, treasury, founder
 *   5. manager.initialize(vault)        — resolves circular dependency
 *   6. manager.addStrategy(aave)        — registers Aave
 *   7. manager.addStrategy(compound)    — registers Compound
 *   8. vault.setOfficialKeeper(deployer, true) — configures official keeper
 *
 * Usage:
 *   forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL --broadcast --verify
 *
 *   Dry-run (no broadcast, real test that everything works but you don't get charged):
 *   forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL -vvv
 */
contract Deploy is Script {
    //* Mainnet Addresses

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

    /// @notice AAVE token (Aave v3 reward)
    address constant AAVE_TOKEN = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;

    /// @notice COMP token (Compound v3 reward)
    address constant COMP_TOKEN = 0xc00e94Cb662C3520282E6f5717214004A7f26888;

    /// @notice Uniswap V3 SwapRouter
    address constant UNISWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    /// @notice Uniswap V3 pool fee tier (3000 = 0.3%)
    uint24 constant POOL_FEE = 3000;

    //* Entry point

    /**
     * @notice Deploys the complete protocol
     * @dev The deployer (transaction signer) is assigned as protocol owner, treasury and founder
     *      After deployment, the owner can change treasury via setTreasury() and founder via setFounder()
     */
    function run() external {
        // Gets the deployer's private key from the environment variable and the address associated with it
        uint256 deployer_pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployer_pk);

        // Deploy start logs on Mainnet
        console.log("=== VynX V1 Deploy ===");
        console.log("Deployer:", deployer);
        console.log("Network: Ethereum Mainnet");

        // Starts the broadcast to mainnet
        vm.startBroadcast(deployer_pk);

        // 1. StrategyManager: allocation brain, without vault address yet
        StrategyManager manager = new StrategyManager(WETH);
        console.log("StrategyManager:", address(manager));

        // 2. AaveStrategy: deposits WETH into Aave v3 Pool, harvests rewards via Uniswap V3
        AaveStrategy aave_strategy =
            new AaveStrategy(address(manager), AAVE_POOL, AAVE_REWARDS, WETH, AAVE_TOKEN, UNISWAP_ROUTER, POOL_FEE);
        console.log("AaveStrategy:", address(aave_strategy));

        // 3. CompoundStrategy: deposits WETH into Compound v3 Comet, harvests rewards via Uniswap V3
        CompoundStrategy compound_strategy = new CompoundStrategy(
            address(manager), COMPOUND_COMET, COMPOUND_REWARDS, WETH, COMP_TOKEN, UNISWAP_ROUTER, POOL_FEE
        );
        console.log("CompoundStrategy:", address(compound_strategy));

        // 4. Vault: ERC4626 vault, deployer as treasury and founder initially
        Vault vault = new Vault(WETH, address(manager), deployer, deployer);
        console.log("Vault:", address(vault));

        // 5. Resolves circular dependency: Manager now has the vault address as "owner/invoker"
        manager.initialize(address(vault));
        console.log("Vault initialized in manager");

        // 6. Adds strategies to the manager
        manager.addStrategy(address(aave_strategy));
        manager.addStrategy(address(compound_strategy));
        console.log("Strategies registered: Aave + Compound");

        // 8. Configures the deployer as official keeper (address that calls harvest without charging a fee)
        vault.setOfficialKeeper(deployer, true);
        console.log("Deployer configured as official keeper");

        // Stops the broadcast and shows deployment completed message
        vm.stopBroadcast();
        console.log("=== Deploy completed ===");
    }
}
