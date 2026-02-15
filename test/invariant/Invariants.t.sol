// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../../src/core/Vault.sol";
import {StrategyManager} from "../../src/core/StrategyManager.sol";
import {AaveStrategy} from "../../src/strategies/AaveStrategy.sol";
import {CompoundStrategy} from "../../src/strategies/CompoundStrategy.sol";
import {Router} from "../../src/periphery/Router.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.sol";

/**
 * @title InvariantsTest
 * @author cristianrisueo
 * @notice Invariant tests stateful para el protocolo
 * @dev A diferencia de fuzz tests, aquí Foundry ejecuta secuencias ALEATORIAS de llamadas
 *      al Handler (deposit, withdraw, deposit, withdraw...) y tras cada secuencia verifica
 *      que las invariantes se cumplan. Esto encuentra bugs que solo aparecen con combinaciones
 *      específicas de operaciones
 */
contract InvariantsTest is Test {
    //* Variables de estado

    /// @notice Instancias del protocolo
    Vault public vault;
    StrategyManager public manager;
    AaveStrategy public aave_strategy;
    CompoundStrategy public compound_strategy;
    Router public router;
    Handler public handler;

    /// @notice Direcciones de los contratos en Mainnet
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant UNISWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant COMPOUND_COMET = 0xA17581A9E3356d9A858b789D68B4d866e593aE94;
    address constant AAVE_REWARDS = 0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb;
    address constant COMPOUND_REWARDS = 0x1B0e765F6224C21223AeA2af16c1C46E38885a40;
    address constant AAVE_TOKEN = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;
    address constant COMP_TOKEN = 0xc00e94Cb662C3520282E6f5717214004A7f26888;

    /// @notice Pool fee de Uniswap router
    uint24 constant POOL_FEE = 3000;

    /// @notice Lista de usuarios simulados
    address[] public actors;

    //* Setup del entorno de testing

    /**
     * @notice Configura protocolo, handler y target contracts para el fuzzer
     * @dev El handler es el único target para que Foundry solo llame deposit/withdraw acotados
     */
    function setUp() public {
        // Crea un fork de Mainnet
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        // Despliega y conecta vault y manager
        manager = new StrategyManager(WETH);
        vault = new Vault(WETH, address(manager), address(this), makeAddr("founder"));
        manager.initialize(address(vault));

        // Configura al test contract como keeper oficial
        vault.setOfficialKeeper(address(this), true);

        // Despliega estrategias con direcciones reales de Mainnet
        aave_strategy =
            new AaveStrategy(address(manager), AAVE_POOL, AAVE_REWARDS, WETH, AAVE_TOKEN, UNISWAP_ROUTER, POOL_FEE);
        compound_strategy = new CompoundStrategy(
            address(manager), COMPOUND_COMET, COMPOUND_REWARDS, WETH, COMP_TOKEN, UNISWAP_ROUTER, POOL_FEE
        );

        // Conecta estrategias al manager
        manager.addStrategy(address(aave_strategy));
        manager.addStrategy(address(compound_strategy));

        // Crea actores para el handler
        actors.push(makeAddr("actor1"));
        actors.push(makeAddr("actor2"));
        actors.push(makeAddr("actor3"));

        // Despliega Router
        router = new Router(WETH, address(vault), UNISWAP_ROUTER);

        // Despliega el handler y lo configura como único target de los tests
        handler = new Handler(vault, router, actors);
        targetContract(address(handler));
    }

    //* Invariantes: propiedades que SIEMPRE deben cumplirse

    /**
     * @notice Invariante: El vault siempre es solvente
     * @dev Tras cualquier secuencia de deposits y withdraws, los assets reales del vault
     *      deben ser >= las shares emitidas. Si esto falla, el vault debe más de lo que tiene
     *      y los últimos usuarios en retirar perderían fondos
     * @dev Un vault solvente siempre tiene totalAssets >= totalSupply (1 share vale >= 1 asset).
     *      Usamos un margen del 1% para tolerar fees de protocolos externos (Aave/Compound)
     *      al depositar/retirar, que pueden causar pequeñas pérdidas por slippage/rounding
     */
    function invariant_VaultIsSolvent() public view {
        // Cogemos los assets (WETH) y supply (shares) totales del vault
        uint256 total_assets = vault.totalAssets();
        uint256 total_supply = vault.totalSupply();

        // Si no hay shares, no hay nada que comprobar
        if (total_supply == 0) return;

        // totalAssets debe ser >= totalSupply con margen del 1% para fees de protocolos
        // El yield hace que totalAssets crezca respecto a totalSupply (correcto, el vault gana dinero)
        // Solo sería insolvente si total_assets < total_supply * 0.99
        assertGe(
            total_assets * 10000,
            total_supply * 9900,
            "INVARIANTE ROTA: Vault insolvente (totalAssets < 99% de totalSupply)"
        );
    }

    /**
     * @notice Invariante: La contabilidad siempre cuadra (idle + manager = totalAssets)
     * @dev El vault reporta totalAssets como idle_buffer + manager.totalAssets()
     *      Si esto no cuadra, hay fondos fantasma o fondos perdidos
     */
    function invariant_AccountingIsConsistent() public view {
        // Obtenemos los assets del IDLE buffer, el manager (depósitos en estrategias) y el TVL del protocolo
        uint256 idle = vault.idle_buffer();
        uint256 manager_assets = manager.totalAssets();
        uint256 total_assets = vault.totalAssets();

        // Comprobamos que el TVL = buffer idle + depósitos en estrategias
        assertEq(idle + manager_assets, total_assets, "INVARIANTE ROTA: Contabilidad descuadrada");
    }

    /**
     * @notice Invariante: totalSupply es coherente con los balances individuales
     * @dev La suma de shares de todos los actores + holders conocidos debe ser <= totalSupply
     *      Si es mayor, se están creando shares de la nada
     * @dev El treasury recibe shares por performance fees durante harvest, así que lo incluimos
     *      en la suma de holders conocidos junto con los actores del handler
     */
    function invariant_SupplyIsCoherent() public view {
        // Obtenemos el totalsupply de shares del vault y el acumulador para iteraciones
        uint256 total_supply = vault.totalSupply();
        uint256 known_holders_sum = 0;

        // Suma los balances de todos los actores del handler
        for (uint256 i = 0; i < actors.length; i++) {
            known_holders_sum += vault.balanceOf(actors[i]);
        }

        // Suma el balance del treasury (recibe shares por performance fees en harvest)
        known_holders_sum += vault.balanceOf(vault.treasury_address());

        // La suma de balances de holders conocidos debe ser <= totalSupply
        assertLe(known_holders_sum, total_supply, "INVARIANTE ROTA: Shares aparecieron de la nada");
    }

    /**
     * @notice Invariante: El Router siempre permanece stateless
     * @dev El Router NUNCA debe retener fondos entre transacciones
     *      Balance de WETH, ETH y cualquier ERC20 debe ser siempre 0
     */
    function invariant_RouterAlwaysStateless() external view {
        assertEq(IERC20(WETH).balanceOf(address(router)), 0, "Router should never hold WETH");

        assertEq(address(router).balance, 0, "Router should never hold ETH");

        // No podemos verificar todos los ERC20, pero WETH es el crítico
        // En producción, el balance check interno del Router garantiza esto
    }
}
