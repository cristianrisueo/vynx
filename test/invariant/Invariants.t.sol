// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../../src/core/Vault.sol";
import {StrategyManager} from "../../src/core/StrategyManager.sol";
import {AaveStrategy} from "../../src/strategies/AaveStrategy.sol";
import {CompoundStrategy} from "../../src/strategies/CompoundStrategy.sol";
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
    //* State variables

    /// @notice Protocol instances
    Vault public vault;
    StrategyManager public manager;
    AaveStrategy public aave_strategy;
    CompoundStrategy public compound_strategy;
    Handler public handler;

    /// @notice Contract addresses on Mainnet
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant COMPOUND_COMET = 0xA17581A9E3356d9A858b789D68B4d866e593aE94;
    address constant AAVE_REWARDS = 0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb;
    address constant COMPOUND_REWARDS = 0x1B0e765F6224C21223AeA2af16c1C46E38885a40;
    address constant AAVE_TOKEN = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;
    address constant COMP_TOKEN = 0xc00e94Cb662C3520282E6f5717214004A7f26888;
    address constant UNISWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    uint24 constant POOL_FEE = 3000;

    /// @notice List of simulated users
    address[] public actors;

    //* Testing environment setup

    /**
     * @notice Configures protocol, handler and target contracts for the fuzzer
     * @dev The handler is the only target so that Foundry only calls bounded deposit/withdraw
     */
    function setUp() public {
        // Create a Mainnet fork
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        // Deploy and connect vault and manager
        manager = new StrategyManager(WETH);
        vault = new Vault(WETH, address(manager), address(this), makeAddr("founder"));
        manager.initialize(address(vault));

        // Configure the test contract as official keeper
        vault.setOfficialKeeper(address(this), true);

        // Deploy strategies with real Mainnet addresses
        aave_strategy = new AaveStrategy(address(manager), AAVE_POOL, AAVE_REWARDS, WETH, AAVE_TOKEN, UNISWAP_ROUTER, POOL_FEE);
        compound_strategy = new CompoundStrategy(address(manager), COMPOUND_COMET, COMPOUND_REWARDS, WETH, COMP_TOKEN, UNISWAP_ROUTER, POOL_FEE);

        // Connect strategies to the manager
        manager.addStrategy(address(aave_strategy));
        manager.addStrategy(address(compound_strategy));

        // Create actors for the handler
        actors.push(makeAddr("actor1"));
        actors.push(makeAddr("actor2"));
        actors.push(makeAddr("actor3"));

        // Deploy the handler and configure it as the only test target
        handler = new Handler(vault, actors);
        targetContract(address(handler));
    }

    //* Invariants: properties that must ALWAYS hold

    /**
     * @notice Invariant: The vault is always solvent
     * @dev After any sequence of deposits and withdrawals, the vault's real assets
     *      must be >= the shares issued. If this fails, the vault owes more than it has
     *      and the last users to withdraw would lose funds
     * @dev A solvent vault always has totalAssets >= totalSupply (1 share is worth >= 1 asset).
     *      We use a 1% margin to tolerate fees from external protocols (Aave/Compound)
     *      when depositing/withdrawing, which can cause small losses due to slippage/rounding
     */
    function invariant_VaultIsSolvent() public view {
        // Get the assets (WETH) and total supply (shares) of the vault
        uint256 total_assets = vault.totalAssets();
        uint256 total_supply = vault.totalSupply();

        // If there are no shares, there's nothing to check
        if (total_supply == 0) return;

        // totalAssets must be >= totalSupply with 1% margin for protocol fees
        // Yield causes totalAssets to grow relative to totalSupply (correct, the vault makes money)
        // It would only be insolvent if total_assets < total_supply * 0.99
        assertGe(
            total_assets * 10000,
            total_supply * 9900,
            "INVARIANT BROKEN: Vault insolvent (totalAssets < 99% of totalSupply)"
        );
    }

    /**
     * @notice Invariant: The accounting always adds up (idle + manager = totalAssets)
     * @dev The vault reports totalAssets as idle_buffer + manager.totalAssets()
     *      If this doesn't add up, there are phantom funds or lost funds
     */
    function invariant_AccountingIsConsistent() public view {
        // Get the assets from the IDLE buffer, the manager (deposits in strategies) and the protocol TVL
        uint256 idle = vault.idle_buffer();
        uint256 manager_assets = manager.totalAssets();
        uint256 total_assets = vault.totalAssets();

        // Check that TVL = idle buffer + deposits in strategies
        assertEq(idle + manager_assets, total_assets, "INVARIANT BROKEN: Accounting mismatch");
    }

    /**
     * @notice Invariant: totalSupply is coherent with individual balances
     * @dev The sum of shares of all actors + known holders must be <= totalSupply
     *      If it's greater, shares are being created out of thin air
     * @dev The treasury receives shares from performance fees during harvest, so we include it
     *      in the sum of known holders along with the handler's actors
     */
    function invariant_SupplyIsCoherent() public view {
        // Get the total supply of shares from the vault and the accumulator for iterations
        uint256 total_supply = vault.totalSupply();
        uint256 known_holders_sum = 0;

        // Sum the balances of all actors from the handler
        for (uint256 i = 0; i < actors.length; i++) {
            known_holders_sum += vault.balanceOf(actors[i]);
        }

        // Sum the treasury balance (receives shares from performance fees in harvest)
        known_holders_sum += vault.balanceOf(vault.treasury_address());

        // The sum of known holders' balances must be <= totalSupply
        assertLe(known_holders_sum, total_supply, "INVARIANT BROKEN: Shares appeared out of thin air");
    }
}
