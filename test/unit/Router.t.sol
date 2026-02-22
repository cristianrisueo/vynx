// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {Router} from "../../src/periphery/Router.sol";
import {Vault} from "../../src/core/Vault.sol";
import {IVault} from "../../src/interfaces/core/IVault.sol";
import {StrategyManager} from "../../src/core/StrategyManager.sol";
import {IStrategyManager} from "../../src/interfaces/core/IStrategyManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title RouterTest
 * @author cristianrisueo
 * @notice Tests unitarios para el Router del protocolo
 * @dev Fork de Mainnet para usar pools reales de Uniswap V3
 */
contract RouterTest is Test {
    //* Eventos (declarados para testing)

    event ZapDeposit(
        address indexed user, address indexed token_in, uint256 amount_in, uint256 weth_out, uint256 shares_out
    );

    //* Variables de estado

    Router public router;
    Vault public vault;
    StrategyManager public manager;

    // Direcciones Mainnet
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant UNISWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    // Usuarios de prueba
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    //* Setup

    function setUp() public {
        // Fork de Mainnet
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        // Deploy protocolo con parámetros del tier Balanced
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

        // Deploy Router
        router = new Router(WETH, address(vault), UNISWAP_ROUTER);
    }

    //* === zapDepositETH ===

    /**
     * @notice Test: zapDepositETH deposita ETH correctamente y emite shares
     */
    function test_ZapDepositETH_Success() external {
        // Setup
        uint256 deposit_amount = 1 ether;
        deal(alice, deposit_amount);

        // Ejecutar
        vm.prank(alice);
        uint256 shares = router.zapDepositETH{value: deposit_amount}();

        // Verificar
        assertGt(shares, 0, "Should receive shares");
        assertEq(vault.balanceOf(alice), shares, "Alice should own shares");
        assertEq(IERC20(WETH).balanceOf(address(router)), 0, "Router should be stateless");
    }

    /**
     * @notice Test: zapDepositETH revierte si msg.value es cero
     */
    function test_ZapDepositETH_RevertsIfZeroAmount() external {
        vm.prank(alice);
        vm.expectRevert(Router.Router__ZeroAmount.selector);
        router.zapDepositETH{value: 0}();
    }

    /**
     * @notice Test: zapDepositETH mantiene Router stateless (balance WETH = 0)
     */
    function test_ZapDepositETH_StatelessEnforcement() external {
        uint256 deposit_amount = 1 ether;
        deal(alice, deposit_amount);

        vm.prank(alice);
        router.zapDepositETH{value: deposit_amount}();

        assertEq(IERC20(WETH).balanceOf(address(router)), 0, "Router must remain stateless");
    }

    /**
     * @notice Test: zapDepositETH emite evento ZapDeposit correctamente
     */
    function test_ZapDepositETH_EmitsEvent() external {
        uint256 deposit_amount = 1 ether;
        deal(alice, deposit_amount);

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit ZapDeposit(alice, address(0), deposit_amount, deposit_amount, deposit_amount);
        router.zapDepositETH{value: deposit_amount}();
    }

    //* === zapDepositERC20 ===

    /**
     * @notice Test: zapDepositERC20 deposita USDC y recibe shares
     */
    function test_ZapDepositERC20_Success_USDC() external {
        // Setup: dar USDC a Alice
        uint256 usdc_amount = 1000e6; // 1000 USDC
        deal(USDC, alice, usdc_amount);

        // Aprobar Router
        vm.startPrank(alice);
        IERC20(USDC).approve(address(router), usdc_amount);

        // Ejecutar con pool 0.05%
        uint256 shares = router.zapDepositERC20(USDC, usdc_amount, 500, 0);
        vm.stopPrank();

        // Verificar
        assertGt(shares, 0, "Should receive shares");
        assertEq(vault.balanceOf(alice), shares, "Alice should own shares");
        assertEq(IERC20(WETH).balanceOf(address(router)), 0, "Router should be stateless");
    }

    /**
     * @notice Test: zapDepositERC20 revierte si token_in es address(0)
     */
    function test_ZapDepositERC20_RevertsIfZeroAddress() external {
        vm.prank(alice);
        vm.expectRevert(Router.Router__ZeroAddress.selector);
        router.zapDepositERC20(address(0), 100, 500, 0);
    }

    /**
     * @notice Test: zapDepositERC20 revierte si token_in es WETH
     */
    function test_ZapDepositERC20_RevertsIfTokenIsWETH() external {
        vm.prank(alice);
        vm.expectRevert(Router.Router__UseVaultForWETH.selector);
        router.zapDepositERC20(WETH, 100, 500, 0);
    }

    /**
     * @notice Test: zapDepositERC20 revierte si amount_in es cero
     */
    function test_ZapDepositERC20_RevertsIfZeroAmount() external {
        vm.prank(alice);
        vm.expectRevert(Router.Router__ZeroAmount.selector);
        router.zapDepositERC20(USDC, 0, 500, 0);
    }

    /**
     * @notice Test: zapDepositERC20 protege contra slippage
     */
    function test_ZapDepositERC20_SlippageProtection() external {
        uint256 usdc_amount = 1000e6;
        deal(USDC, alice, usdc_amount);

        vm.startPrank(alice);
        IERC20(USDC).approve(address(router), usdc_amount);

        // Pedir más WETH del que es posible obtener (1000 ETH es imposible con 1000 USDC)
        vm.expectRevert();
        router.zapDepositERC20(USDC, usdc_amount, 500, 1000 ether);
        vm.stopPrank();
    }

    //* === zapWithdrawETH ===

    /**
     * @notice Test: zapWithdrawETH retira shares y recibe ETH
     */
    function test_ZapWithdrawETH_Success() external {
        // Setup: Alice deposita primero
        uint256 deposit_amount = 1 ether;
        deal(alice, deposit_amount);

        vm.prank(alice);
        uint256 shares = router.zapDepositETH{value: deposit_amount}();

        // Aprobar Router para quemar shares
        vm.startPrank(alice);
        vault.approve(address(router), shares);

        // Retirar y capturar ETH recibido
        uint256 eth_out = router.zapWithdrawETH(shares);

        vm.stopPrank();

        // Verificar
        assertEq(vault.balanceOf(alice), 0, "Shares should be burned");
        assertGt(eth_out, 0, "Should receive ETH");
        assertApproxEqRel(eth_out, deposit_amount, 0.001e18, "Should receive ~deposited amount");
        assertEq(IERC20(WETH).balanceOf(address(router)), 0, "Router should be stateless");
    }

    /**
     * @notice Test: zapWithdrawETH revierte si shares es cero
     */
    function test_ZapWithdrawETH_RevertsIfZeroShares() external {
        vm.prank(alice);
        vm.expectRevert(Router.Router__ZeroAmount.selector);
        router.zapWithdrawETH(0);
    }

    /**
     * @notice Test: zapWithdrawETH mantiene Router stateless
     */
    function test_ZapWithdrawETH_StatelessEnforcement() external {
        uint256 deposit_amount = 1 ether;
        deal(alice, deposit_amount);

        vm.prank(alice);
        uint256 shares = router.zapDepositETH{value: deposit_amount}();

        vm.startPrank(alice);
        vault.approve(address(router), shares);
        router.zapWithdrawETH(shares);
        vm.stopPrank();

        assertEq(IERC20(WETH).balanceOf(address(router)), 0, "Router must remain stateless");
    }

    //* === zapWithdrawERC20 ===

    /**
     * @notice Test: zapWithdrawERC20 retira shares y recibe USDC
     */
    function test_ZapWithdrawERC20_Success_USDC() external {
        // Setup: Alice deposita ETH primero
        uint256 deposit_amount = 1 ether;
        deal(alice, deposit_amount);

        vm.prank(alice);
        uint256 shares = router.zapDepositETH{value: deposit_amount}();

        // Retirar en USDC
        vm.startPrank(alice);
        vault.approve(address(router), shares);
        uint256 usdc_out = router.zapWithdrawERC20(shares, USDC, 500, 0);
        vm.stopPrank();

        // Verificar
        assertGt(usdc_out, 0, "Should receive USDC");
        assertEq(IERC20(USDC).balanceOf(alice), usdc_out, "Alice should have USDC");
        assertEq(vault.balanceOf(alice), 0, "Shares should be burned");
        assertEq(IERC20(USDC).balanceOf(address(router)), 0, "Router should be stateless");
    }

    /**
     * @notice Test: zapWithdrawERC20 revierte si token_out es WETH
     */
    function test_ZapWithdrawERC20_RevertsIfTokenIsWETH() external {
        vm.prank(alice);
        vm.expectRevert(Router.Router__UseVaultForWETH.selector);
        router.zapWithdrawERC20(100, WETH, 500, 0);
    }

    /**
     * @notice Test: zapWithdrawERC20 solo verifica balance de token_out (no WETH)
     */
    function test_ZapWithdrawERC20_OnlyChecksTokenOutBalance() external {
        // Este test verifica que NO se hace double-check de WETH
        // (ya discutimos que WETH es transitorio: redeem → swap consume todo)

        uint256 deposit_amount = 1 ether;
        deal(alice, deposit_amount);

        vm.prank(alice);
        uint256 shares = router.zapDepositETH{value: deposit_amount}();

        vm.startPrank(alice);
        vault.approve(address(router), shares);
        router.zapWithdrawERC20(shares, USDC, 500, 0);
        vm.stopPrank();

        // Solo verificar que token_out balance es 0, no WETH
        assertEq(IERC20(USDC).balanceOf(address(router)), 0, "USDC balance should be 0");
        // No hacemos assert de WETH porque no se verifica en el contrato
    }
}
