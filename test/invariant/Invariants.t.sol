// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../../src/core/Vault.sol";
import {IVault} from "../../src/interfaces/core/IVault.sol";
import {StrategyManager} from "../../src/core/StrategyManager.sol";
import {IStrategyManager} from "../../src/interfaces/core/IStrategyManager.sol";
import {AaveStrategy} from "../../src/strategies/AaveStrategy.sol";
import {LidoStrategy} from "../../src/strategies/LidoStrategy.sol";
import {Router} from "../../src/periphery/Router.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.sol";

/**
 * @title InvariantsTest
 * @author cristianrisueo
 * @notice Stateful invariant tests for the protocol
 * @dev Unlike fuzz tests, here Foundry executes RANDOM sequences of calls
 *      to the Handler (deposit, withdraw, deposit, withdraw...) and after each sequence verifies
 *      that the invariants hold. This finds bugs that only appear with specific
 *      combinations of operations
 */
contract InvariantsTest is Test {
    //* Variables de estado

    /// @notice Protocol instances
    Vault public vault;
    StrategyManager public manager;
    AaveStrategy public aave_strategy;
    LidoStrategy public lido_strategy;
    Router public router;
    Handler public handler;

    /// @notice Mainnet contract addresses
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant UNISWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_REWARDS = 0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb;
    address constant AAVE_TOKEN = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;
    address constant CURVE_POOL = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;

    /// @notice Uniswap router pool fee
    uint24 constant POOL_FEE = 3000;

    /// @notice List of simulated users
    address[] public actors;

    //* Testing environment setup

    /**
     * @notice Configures protocol, handler and target contracts for the fuzzer
     * @dev The handler is the only target so Foundry only calls bounded deposit/withdraw
     */
    function setUp() public {
        // Creates a Mainnet fork
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        // Deploys and connects vault and manager with Balanced tier parameters
        manager = new StrategyManager(
            WETH,
            IStrategyManager.TierConfig({
                max_allocation_per_strategy: 5000, // 50%
                min_allocation_threshold: 2000, // 20%
                rebalance_threshold: 200, // 2%
                min_tvl_for_rebalance: 8 ether
            })
        );
        vault = new Vault(
            WETH,
            address(manager),
            address(this),
            makeAddr("founder"),
            IVault.TierConfig({
                idle_threshold: 8 ether,
                min_profit_for_harvest: 0.08 ether,
                max_tvl: 1000 ether,
                min_deposit: 0.01 ether
            })
        );
        manager.initialize(address(vault));

        // Configures the test contract as the official keeper
        vault.setOfficialKeeper(address(this), true);

        // Deploys strategies with real Mainnet addresses
        aave_strategy = new AaveStrategy(
            address(manager),
            WETH,
            AAVE_POOL,
            AAVE_REWARDS,
            AAVE_TOKEN,
            UNISWAP_ROUTER,
            POOL_FEE,
            WSTETH,
            WETH,
            STETH,
            CURVE_POOL
        );
        lido_strategy = new LidoStrategy(address(manager), WSTETH, WETH, UNISWAP_ROUTER, uint24(500));

        // Connects strategies to the manager
        manager.addStrategy(address(aave_strategy));
        manager.addStrategy(address(lido_strategy));

        // Creates actors for the handler
        actors.push(makeAddr("actor1"));
        actors.push(makeAddr("actor2"));
        actors.push(makeAddr("actor3"));

        // Deploys Router
        router = new Router(WETH, address(vault), UNISWAP_ROUTER);

        // Deploys the handler and configures it as the only target of the tests
        handler = new Handler(vault, router, actors);
        targetContract(address(handler));
    }

    //* Invariants: properties that MUST ALWAYS hold

    /**
     * @notice Invariant: The vault is always solvent
     * @dev After any sequence of deposits and withdrawals, the vault's real assets
     *      must be >= issued shares. If this fails, the vault owes more than it has
     *      and the last users to withdraw would lose funds
     * @dev A solvent vault always has totalAssets >= totalSupply (1 share is worth >= 1 asset).
     *      We use a 1% margin to tolerate external protocol fees (Aave/Compound)
     *      on deposit/withdrawal, which can cause small losses due to slippage/rounding
     */
    function invariant_VaultIsSolvent() public view {
        // Gets total assets (WETH) and total supply (shares) of the vault
        uint256 total_assets = vault.totalAssets();
        uint256 total_supply = vault.totalSupply();

        // If there are no shares, there is nothing to check
        if (total_supply == 0) return;

        // totalAssets must be >= totalSupply with a 1% margin for protocol fees
        // Yield causes totalAssets to grow relative to totalSupply (correct, the vault earns money)
        // It would only be insolvent if total_assets < total_supply * 0.99
        assertGe(
            total_assets * 10000,
            total_supply * 9900,
            "BROKEN INVARIANT: Vault insolvent (totalAssets < 99% of totalSupply)"
        );
    }

    /**
     * @notice Invariant: Accounting always balances (idle + manager = totalAssets)
     * @dev The vault reports totalAssets as idle_buffer + manager.totalAssets()
     *      If this does not balance, there are phantom funds or lost funds
     */
    function invariant_AccountingIsConsistent() public view {
        // Gets IDLE buffer assets, manager assets (strategy deposits) and protocol TVL
        uint256 idle = vault.idle_buffer();
        uint256 manager_assets = manager.totalAssets();
        uint256 total_assets = vault.totalAssets();

        // Checks that TVL = idle buffer + strategy deposits
        assertEq(idle + manager_assets, total_assets, "BROKEN INVARIANT: Accounting mismatch");
    }

    /**
     * @notice Invariant: totalSupply is coherent with individual balances
     * @dev The sum of shares of all actors + known holders must be <= totalSupply
     *      If it is greater, shares are being created out of thin air
     * @dev The treasury receives shares for performance fees during harvest, so we include it
     *      in the sum of known holders along with the handler actors
     */
    function invariant_SupplyIsCoherent() public view {
        // Gets total vault share supply and accumulator for iterations
        uint256 total_supply = vault.totalSupply();
        uint256 known_holders_sum = 0;

        // Sums balances of all handler actors
        for (uint256 i = 0; i < actors.length; i++) {
            known_holders_sum += vault.balanceOf(actors[i]);
        }

        // Sums treasury balance (receives shares for performance fees on harvest)
        known_holders_sum += vault.balanceOf(vault.treasury_address());

        // Sum of known holder balances must be <= totalSupply
        assertLe(known_holders_sum, total_supply, "BROKEN INVARIANT: Shares appeared from nowhere");
    }

    /**
     * @notice Invariant: The Router always remains stateless
     * @dev The Router MUST NEVER retain funds between transactions
     *      WETH, ETH and any ERC20 balance must always be 0
     */
    function invariant_RouterAlwaysStateless() external view {
        assertEq(IERC20(WETH).balanceOf(address(router)), 0, "Router should never hold WETH");

        assertEq(address(router).balance, 0, "Router should never hold ETH");

        // We cannot verify all ERC20s, but WETH is the critical one
        // In production, the Router's internal balance check guarantees this
    }
}
