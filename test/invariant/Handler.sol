// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {StrategyVault} from "../../src/core/StrategyVault.sol";
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
    StrategyVault public vault;

    /// @notice Dirección del contrato WETH en Mainnet
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @notice Lista de usuarios simulados
    address[] public actors;

    /// @notice Variables fantasma: total depositado y total retirado (para verificar solvencia)
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;

    //* Constructor

    /**
     * @notice Inicializa el handler con el vault y los actores disponibles
     * @param _vault Instancia del vault a testear
     * @param _actors Lista de direcciones que pueden interactuar
     */
    constructor(StrategyVault _vault, address[] memory _actors) {
        vault = _vault;
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
}
