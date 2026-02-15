// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../../src/core/Vault.sol";
import {Router} from "../../src/periphery/Router.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Handler
 * @author cristianrisueo
 * @notice Contrato intermediario que acota las llamadas al vault para invariant testing
 * @dev Sin un handler, Foundry llamaría funciones con inputs inválidos y perdería
 *      el 99% del tiempo en reverts inútiles. El handler garantiza que las llamadas
 *      tengan sentido, permitiendo al fuzzer encontrar bugs reales
 */
contract Handler is Test {
    //* Variables de estado

    /// @notice Instancia del vault a testear
    Vault public vault;

    /// @notice Instancia del router
    Router public router;

    /// @notice Dirección del contrato WETH en Mainnet
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @notice Dirección del contrato USDC en Mainnet
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @notice Lista de usuarios simulados
    address[] public actors;

    /// @notice Variables fantasma: total depositado y total retirado (para verificar solvencia)
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;

    //* Constructor

    /**
     * @notice Inicializa el handler con el vault, router y los actores disponibles
     * @param _vault Instancia del vault a testear
     * @param _router Instancia del router a testear
     * @param _actors Lista de direcciones que pueden interactuar
     */
    constructor(Vault _vault, Router _router, address[] memory _actors) {
        vault = _vault;
        router = _router;
        actors = _actors;
    }

    //* Acciones acotadas que el fuzzer puede ejecutar

    /**
     * @notice Acción: Depositar en el vault con inputs acotados
     * @dev El fuzzer elige un actor aleatorio y un amount válido,
     *      acota amount entre min_deposit y lo que queda de TVL
     * @param actor_seed Seed para elegir un actor aleatorio
     * @param amount Cantidad aleatoria a depositar
     */
    function deposit(uint256 actor_seed, uint256 amount) external {
        // Elige un actor aleatorio del array
        address actor = actors[actor_seed % actors.length];

        // Obtiene TVL máximo permitido y TVL actual
        uint256 max_tvl = vault.max_tvl();
        uint256 current_total = vault.totalAssets();

        // Si ya se ha superado el máximo TVL permitido, no hace nada
        if (current_total >= max_tvl) return;

        // Calcula el espacio disponible en el vault (max_tvl - tvl_actual)
        uint256 available = max_tvl - current_total;

        // Obtiene el mínimo depósito (0.001 WETH creo recordar)
        uint256 min = vault.min_deposit();

        // Si no hay espacio suficiente para el depósito mínimo, no hace nada
        if (available < min) return;

        // Acota amount al rango válido
        amount = bound(amount, min, available);

        // Ejecuta el depósito como el actor elegido
        deal(WETH, actor, amount);
        vm.startPrank(actor);

        IERC20(WETH).approve(address(vault), amount);
        vault.deposit(amount, actor);

        vm.stopPrank();

        // Actualiza ghost variable para tracking
        ghost_totalDeposited += amount;
    }

    /**
     * @notice Acción: Retirar del vault con inputs acotados
     * @dev Solo retira si el actor tiene shares. Acota el retiro al máximo posible
     * @param actor_seed Seed para elegir un actor aleatorio
     * @param amount Cantidad aleatoria a retirar
     */
    function withdraw(uint256 actor_seed, uint256 amount) external {
        // Elige un actor aleatorio
        address actor = actors[actor_seed % actors.length];

        // Comprueba que el actor tenga shares
        uint256 actor_shares = vault.balanceOf(actor);
        if (actor_shares == 0) return;

        // Calcula el máximo que puede retirar (neto, después de fees)
        // previewRedeem devuelve assets netos que recibiría por sus shares
        uint256 max_withdraw = vault.previewRedeem(actor_shares);
        if (max_withdraw == 0) return;

        // Acota amount al rango posible (mínimo 1 wei para evitar ZeroAmount)
        amount = bound(amount, 1, max_withdraw);

        // Ejecuta el retiro
        vm.prank(actor);
        vault.withdraw(amount, actor, actor);

        // Actualiza ghost variable
        ghost_totalWithdrawn += amount;
    }

    /**
     * @notice Acción: Ejecuta harvest (cosecha rewards de estrategias)
     * @dev Accion aleatoria 3: keeper ejecuta harvest si hay profit minimo
     */
    function harvest() external {
        // Skip tiempo para acumular yield
        skip(bound(block.timestamp, 1 days, 7 days));

        // Solo harvest si hay suficiente profit
        if (vault.totalAssets() > vault.min_profit_for_harvest()) {
            vault.harvest();
        }
    }

    //* === Router Actions ===

    /**
     * @notice Acción: Depositar ETH vía Router
     */
    function routerZapDepositETH(uint256 actor_seed, uint256 amount) external {
        address actor = actors[actor_seed % actors.length];

        uint256 max_tvl = vault.max_tvl();
        uint256 current_total = vault.totalAssets();

        if (current_total >= max_tvl) return;

        uint256 available = max_tvl - current_total;
        uint256 min = vault.min_deposit();

        if (available < min) return;

        amount = bound(amount, min, available);

        deal(actor, amount);

        vm.prank(actor);
        router.zapDepositETH{value: amount}();

        ghost_totalDeposited += amount;
    }

    /**
     * @notice Acción: Depositar USDC vía Router
     */
    function routerZapDepositUSDC(uint256 actor_seed, uint256 amount) external {
        address actor = actors[actor_seed % actors.length];

        uint256 max_tvl = vault.max_tvl();
        uint256 current_total = vault.totalAssets();

        if (current_total >= max_tvl) return;

        uint256 available = max_tvl - current_total;
        uint256 min = vault.min_deposit();

        if (available < min) return;

        // USDC tiene 6 decimales, WETH tiene 18
        // 1 USDC ~= 0.0004 WETH (asumiendo precio ETH ~$2500)
        // Acotar amount en USDC
        amount = bound(amount, min * 2500 / 1e12, available * 2500 / 1e12); // conversión burda WETH → USDC

        deal(USDC, actor, amount);

        vm.startPrank(actor);
        IERC20(USDC).approve(address(router), amount);
        router.zapDepositERC20(USDC, amount, 500, 0);
        vm.stopPrank();

        // Aproximar cantidad depositada en WETH
        ghost_totalDeposited += amount * 1e12 / 2500;
    }

    /**
     * @notice Acción: Retirar vía Router a ETH
     */
    function routerZapWithdrawETH(uint256 actor_seed, uint256 shares) external {
        address actor = actors[actor_seed % actors.length];

        uint256 actor_shares = vault.balanceOf(actor);
        if (actor_shares == 0) return;

        shares = bound(shares, 1, actor_shares);

        uint256 assets_to_withdraw = vault.previewRedeem(shares);

        vm.startPrank(actor);
        vault.approve(address(router), shares);
        router.zapWithdrawETH(shares);
        vm.stopPrank();

        ghost_totalWithdrawn += assets_to_withdraw;
    }
}
