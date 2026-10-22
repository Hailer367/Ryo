// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import { Ryo } from "../src/Ryo.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockFeeERC20 } from "./mocks/MockFeeERC20.sol";
import { MockBalancerVault } from "./mocks/MockBalancerVault.sol";
import { MockV2Router } from "./mocks/MockV2Router.sol";
import { MockV3Router } from "./mocks/MockV3Router.sol";
import { ReentrantV2Router } from "./mocks/ReentrantV2Router.sol";

contract RyoTest is Test {
    receive() external payable { }

    address internal constant OPERATOR = address(0xB0B);
    address internal constant STRANGER = address(0xBAD);

    MockBalancerVault internal vault;
    MockV2Router internal v2;
    MockV3Router internal v3;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockERC20 internal tokenC;
    Ryo internal ryo;

    uint256 internal constant ONE = 1e18;

    function setUp() public {
        vault = new MockBalancerVault();
        v2 = new MockV2Router();
        v3 = new MockV3Router();

        tokenA = new MockERC20("Token A", "A", 18);
        tokenB = new MockERC20("Token B", "B", 18);
        tokenC = new MockERC20("Token C", "C", 18);

        // Liquidity for the mock venues and the flash lender.
        tokenA.mint(address(vault), 1_000_000 * ONE);
        tokenA.mint(address(v2), 1_000_000 * ONE);
        tokenA.mint(address(v3), 1_000_000 * ONE);
        tokenB.mint(address(v2), 1_000_000 * ONE);
        tokenB.mint(address(v3), 1_000_000 * ONE);
        tokenC.mint(address(v2), 1_000_000 * ONE);
        tokenC.mint(address(v3), 1_000_000 * ONE);

        // Default profitable route: A -> B on V3 at 1.1, B -> A on V2 at 1.0.
        v3.setRate(address(tokenA), address(tokenB), 1.1e18);
        v2.setRate(address(tokenB), address(tokenA), 1.0e18);

        ryo = new Ryo(
            address(vault),
            address(this),
            OPERATOR,
            _route(address(tokenA), address(tokenB), address(v3), 6, 500, address(v2), 8),
            _disabledRoute(),
            new address[](0),
            0,
            100 * ONE,
            0
        );
    }

    // ----------------------------------------------------------------------------------------
    // Helpers
    // ----------------------------------------------------------------------------------------

    function _route(
        address asset,
        address intermediate,
        address buyRouter,
        uint8 buyType,
        uint24 buyFee,
        address sellRouter,
        uint8 sellType
    ) internal pure returns (Ryo.PrimaryRouteConfig memory) {
        return Ryo.PrimaryRouteConfig({
            asset: asset,
            intermediate: intermediate,
            buyRouter: buyRouter,
            sellRouter: sellRouter,
            buyDexType: buyType,
            sellDexType: sellType,
            buyFee: buyFee,
            sellFee: 0
        });
    }

    function _disabledRoute() internal pure returns (Ryo.PrimaryRouteConfig memory) {
        return Ryo.PrimaryRouteConfig({
            asset: address(0),
            intermediate: address(0),
            buyRouter: address(0),
            sellRouter: address(0),
            buyDexType: 0,
            sellDexType: 0,
            buyFee: 0,
            sellFee: 0
        });
    }

    function _primarySwaps() internal view returns (Ryo.Swap[] memory swaps) {
        swaps = new Ryo.Swap[](2);
        swaps[0] = Ryo.Swap({
            dexType: 6,
            router: address(v3),
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            extraData: abi.encode(uint24(500))
        });
        swaps[1] = Ryo.Swap({
            dexType: 8,
            router: address(v2),
            tokenIn: address(tokenB),
            tokenOut: address(tokenA),
            extraData: ""
        });
    }

    // ----------------------------------------------------------------------------------------
    // Profit paths
    // ----------------------------------------------------------------------------------------

    /// @dev Profiling tests. Each starts from a fresh setUp, so the comparison is cold-state for
    ///      both entry points. The primary path avoids dynamic-route decoding and calldata.
    function test_gas_executePrimary() public {
        vm.prank(OPERATOR);
        uint256 before = gasleft();
        uint256 profit = ryo.executePrimary(0, 10 * ONE, ONE);
        emit log_named_uint("executePrimary gas", before - gasleft());
        assertEq(profit, ONE);
    }

    function test_gas_execute() public {
        Ryo.Swap[] memory swaps = _primarySwaps();
        vm.prank(OPERATOR);
        uint256 before = gasleft();
        uint256 profit = ryo.execute(address(tokenA), 10 * ONE, swaps, ONE);
        emit log_named_uint("execute gas", before - gasleft());
        assertEq(profit, ONE);
    }

    function test_executePrimary_profit() public {
        uint256 amount = 10 * ONE;
        uint256 ownerBefore = tokenA.balanceOf(address(this));
        uint256 vaultBefore = tokenA.balanceOf(address(vault));

        vm.expectEmit(true, true, true, true, address(ryo));
        emit Ryo.PrimaryExecuted(OPERATOR, 0, address(tokenA), amount, ONE);

        vm.prank(OPERATOR);
        uint256 profit = ryo.executePrimary(0, amount, ONE);

        assertEq(profit, ONE, "profit");
        assertEq(tokenA.balanceOf(address(this)), ownerBefore + ONE, "owner profit");
        assertEq(tokenA.balanceOf(address(ryo)), 0, "contract holds nothing");
        assertEq(tokenA.balanceOf(address(vault)), vaultBefore, "loan repaid");
        assertEq(tokenA.allowance(address(ryo), address(vault)), 0, "no vault allowance used");
    }

    function test_executePrimary_withFlashLoanFee() public {
        vault.setFeeBps(100); // 1%
        uint256 vaultBefore = tokenA.balanceOf(address(vault));

        vm.prank(OPERATOR);
        uint256 profit = ryo.executePrimary(0, 10 * ONE, 0);

        assertEq(profit, 9e17, "profit after fee");
        assertEq(tokenA.balanceOf(address(vault)), vaultBefore + 1e17, "loan plus fee repaid");
    }

    function test_execute_profitAndEvent() public {
        uint256 amount = 10 * ONE;
        Ryo.Swap[] memory swaps = _primarySwaps();
        uint256 ownerBefore = tokenA.balanceOf(address(this));

        vm.expectEmit(true, true, true, true, address(ryo));
        emit Ryo.ArbitrageExecuted(OPERATOR, address(tokenA), amount, ONE, 2);

        vm.prank(OPERATOR);
        uint256 profit = ryo.execute(address(tokenA), amount, swaps, ONE);

        assertEq(profit, ONE);
        assertEq(tokenA.balanceOf(address(this)), ownerBefore + ONE);
        assertEq(tokenA.balanceOf(address(ryo)), 0);
    }

    function test_execute_triangularRoute() public {
        // A -> B (V3 1.2), B -> C (V2 1.2), C -> A (V3 1.1) = 1.584x
        v3.setRate(address(tokenA), address(tokenB), 1.2e18);
        v2.setRate(address(tokenB), address(tokenC), 1.2e18);
        v3.setRate(address(tokenC), address(tokenA), 1.1e18);

        Ryo.Swap[] memory swaps = new Ryo.Swap[](3);
        swaps[0] =
            Ryo.Swap(6, address(v3), address(tokenA), address(tokenB), abi.encode(uint24(500)));
        swaps[1] = Ryo.Swap(8, address(v2), address(tokenB), address(tokenC), "");
        swaps[2] =
            Ryo.Swap(6, address(v3), address(tokenC), address(tokenA), abi.encode(uint24(500)));

        vm.prank(OPERATOR);
        uint256 profit = ryo.execute(address(tokenA), 10 * ONE, swaps, 0);

        assertGt(profit, 5 * ONE, "triangular profit");
        assertEq(tokenA.balanceOf(address(ryo)), 0);
    }

    function test_execute_v2PathExtraData() public {
        // A -> B via an explicit V2 path, B -> A via V3.
        v2.setRate(address(tokenA), address(tokenB), 1.1e18);
        v3.setRate(address(tokenB), address(tokenA), 1.0e18);

        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        Ryo.Swap[] memory swaps = new Ryo.Swap[](2);
        swaps[0] = Ryo.Swap(
            8, address(v2), address(tokenA), address(tokenB), abi.encode(path, uint256(1))
        );
        swaps[1] =
            Ryo.Swap(6, address(v3), address(tokenB), address(tokenA), abi.encode(uint24(500)));

        vm.prank(OPERATOR);
        uint256 profit = ryo.execute(address(tokenA), 10 * ONE, swaps, ONE);
        assertEq(profit, ONE);
    }

    function test_execute_v3MinOut64Bytes() public {
        Ryo.Swap[] memory swaps = _primarySwaps();
        swaps[0].extraData = abi.encode(uint24(500), uint256(10 * ONE)); // 10 A -> 11 B, min 10 B
        vm.prank(OPERATOR);
        uint256 profit = ryo.execute(address(tokenA), 10 * ONE, swaps, ONE);
        assertEq(profit, ONE);
    }

    // ----------------------------------------------------------------------------------------
    // Simulations
    // ----------------------------------------------------------------------------------------

    function test_simulate_profit() public {
        Ryo.Swap[] memory swaps = _primarySwaps();
        vm.expectRevert(abi.encodeWithSelector(Ryo.SimulationResult.selector, int256(ONE)));
        vm.prank(OPERATOR);
        ryo.simulate(address(tokenA), 10 * ONE, swaps);
    }

    function test_simulatePrimary_profit() public {
        vm.expectRevert(abi.encodeWithSelector(Ryo.SimulationResult.selector, int256(ONE)));
        vm.prank(OPERATOR);
        ryo.simulatePrimary(0, 10 * ONE);
    }

    function test_simulate_loss() public {
        v3.setRate(address(tokenA), address(tokenB), 0.9e18);
        Ryo.Swap[] memory swaps = _primarySwaps();

        vm.expectRevert(abi.encodeWithSelector(Ryo.SimulationResult.selector, int256(-1e18)));
        vm.prank(OPERATOR);
        ryo.simulate(address(tokenA), 10 * ONE, swaps);
    }

    function test_simulate_lossWithDustReturnsSimulationResult() public {
        // 1 A dust + 4 A output = 5 A, less than the 10 A repayment. The loss must be reported
        // without attempting the unaffordable transfer.
        tokenA.mint(address(ryo), ONE);
        v3.setRate(address(tokenA), address(tokenB), 0.4e18);
        Ryo.Swap[] memory swaps = _primarySwaps();

        vm.expectRevert(abi.encodeWithSelector(Ryo.SimulationResult.selector, int256(-6e18)));
        vm.prank(OPERATOR);
        ryo.simulate(address(tokenA), 10 * ONE, swaps);
    }

    // ----------------------------------------------------------------------------------------
    // Route validation
    // ----------------------------------------------------------------------------------------

    function test_RevertWhen_routeTooShort() public {
        Ryo.Swap[] memory swaps = new Ryo.Swap[](1);
        swaps[0] =
            Ryo.Swap(6, address(v3), address(tokenA), address(tokenA), abi.encode(uint24(500)));
        vm.expectRevert(Ryo.RouteTooShort.selector);
        vm.prank(OPERATOR);
        ryo.execute(address(tokenA), ONE, swaps, 0);
    }

    function test_RevertWhen_incoherentRoute() public {
        Ryo.Swap[] memory swaps = _primarySwaps();
        swaps[1].tokenIn = address(tokenC);
        vm.expectRevert(abi.encodeWithSelector(Ryo.RouteMismatch.selector, 1));
        vm.prank(OPERATOR);
        ryo.execute(address(tokenA), ONE, swaps, 0);
    }

    function test_RevertWhen_routeDoesNotReturnBorrowedAsset() public {
        Ryo.Swap[] memory swaps = _primarySwaps();
        swaps[1].tokenOut = address(tokenC);
        vm.expectRevert(abi.encodeWithSelector(Ryo.RouteMismatch.selector, 2));
        vm.prank(OPERATOR);
        ryo.execute(address(tokenA), ONE, swaps, 0);
    }

    function test_RevertWhen_routerNotWhitelisted() public {
        MockV2Router other = new MockV2Router();
        Ryo.Swap[] memory swaps = _primarySwaps();
        swaps[1].router = address(other);
        vm.expectRevert(abi.encodeWithSelector(Ryo.RouterNotWhitelisted.selector, address(other)));
        vm.prank(OPERATOR);
        ryo.execute(address(tokenA), ONE, swaps, 0);
    }

    function test_RevertWhen_unknownDexType() public {
        Ryo.Swap[] memory swaps = _primarySwaps();
        swaps[0].dexType = 99;
        vm.expectRevert(abi.encodeWithSelector(Ryo.UnsupportedDexType.selector, 99));
        vm.prank(OPERATOR);
        ryo.execute(address(tokenA), ONE, swaps, 0);
    }

    function test_RevertWhen_invalidV3ExtraData() public {
        Ryo.Swap[] memory swaps = _primarySwaps();
        swaps[0].extraData = hex"001122";
        vm.expectRevert(abi.encodeWithSelector(Ryo.InvalidExtraData.selector, 0));
        vm.prank(OPERATOR);
        ryo.execute(address(tokenA), ONE, swaps, 0);
    }

    function test_RevertWhen_invalidV2Path() public {
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenC);

        Ryo.Swap[] memory swaps = _primarySwaps();
        swaps[1].extraData = abi.encode(path, uint256(1));
        vm.expectRevert(abi.encodeWithSelector(Ryo.InvalidPath.selector, 1));
        vm.prank(OPERATOR);
        ryo.execute(address(tokenA), ONE, swaps, 0);
    }

    function test_RevertWhen_v2ExtraDataTooShort() public {
        address[] memory path = new address[](1);
        path[0] = address(tokenB);

        Ryo.Swap[] memory swaps = _primarySwaps();
        swaps[1].extraData = abi.encode(path, uint256(1)); // 128 bytes: one-hop path
        vm.expectRevert(abi.encodeWithSelector(Ryo.InvalidExtraData.selector, 1));
        vm.prank(OPERATOR);
        ryo.execute(address(tokenA), ONE, swaps, 0);
    }

    function test_RevertWhen_swapOutputZero() public {
        v3.setRate(address(tokenA), address(tokenB), 0);
        Ryo.Swap[] memory swaps = _primarySwaps();
        vm.expectRevert();
        vm.prank(OPERATOR);
        ryo.execute(address(tokenA), 10 * ONE, swaps, 0);
    }

    function test_RevertWhen_swapFails() public {
        v3.setFailNext(true);
        Ryo.Swap[] memory swaps = _primarySwaps();
        vm.expectRevert("MockV3: forced failure");
        vm.prank(OPERATOR);
        ryo.execute(address(tokenA), 10 * ONE, swaps, 0);
    }

    function test_RevertWhen_unprofitable() public {
        v3.setRate(address(tokenA), address(tokenB), 0.9e18);
        vm.expectRevert();
        vm.prank(OPERATOR);
        ryo.executePrimary(0, 10 * ONE, 0);
    }

    function test_RevertWhen_minProfitNotMet() public {
        v3.setRate(address(tokenA), address(tokenB), 1.2e18);
        vm.expectRevert(
            abi.encodeWithSelector(Ryo.InsufficientProfit.selector, 3 * ONE, int256(2 * ONE))
        );
        vm.prank(OPERATOR);
        ryo.executePrimary(0, 10 * ONE, 3 * ONE);
    }

    function test_RevertWhen_tradeSizeExceeded() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Ryo.TradeSizeExceeded.selector, address(tokenA), 101 * ONE, 100 * ONE
            )
        );
        vm.prank(OPERATOR);
        ryo.executePrimary(0, 101 * ONE, 0);
    }

    function test_RevertWhen_zeroAmount() public {
        vm.expectRevert(Ryo.ZeroAmount.selector);
        vm.prank(OPERATOR);
        ryo.executePrimary(0, 0, 0);
    }

    function test_RevertWhen_gasPriceTooHigh() public {
        ryo.setMaxGasPrice(100 gwei);
        vm.txGasPrice(101 gwei);
        vm.expectRevert(abi.encodeWithSelector(Ryo.GasPriceTooHigh.selector, 100 gwei, 101 gwei));
        vm.prank(OPERATOR);
        ryo.executePrimary(0, 10 * ONE, 0);
        vm.txGasPrice(0);
    }

    // ----------------------------------------------------------------------------------------
    // Access / pause / callback hardening
    // ----------------------------------------------------------------------------------------

    function test_RevertWhen_strangerExecutes() public {
        vm.expectRevert(abi.encodeWithSelector(Ryo.NotOperator.selector, STRANGER));
        vm.prank(STRANGER);
        ryo.executePrimary(0, 10 * ONE, 0);
    }

    function test_RevertWhen_operatorCallsOwnerFunction() public {
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OPERATOR)
        );
        vm.prank(OPERATOR);
        ryo.setOperator(STRANGER);
    }

    function test_ownerCanExecute() public {
        // owner is address(this), which is also allowed through onlyOperator
        uint256 profit = ryo.executePrimary(0, 10 * ONE, 0);
        assertEq(profit, ONE);
    }

    function test_pauseAndUnpause() public {
        vm.prank(OPERATOR);
        ryo.pause();
        assertTrue(ryo.paused());

        vm.expectRevert(Ryo.ContractPaused.selector);
        vm.prank(OPERATOR);
        ryo.executePrimary(0, 10 * ONE, 0);

        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OPERATOR)
        );
        vm.prank(OPERATOR);
        ryo.unpause();

        ryo.unpause();
        assertFalse(ryo.paused());
    }

    function test_RevertWhen_pauseTwice() public {
        vm.prank(OPERATOR);
        ryo.pause();
        vm.expectRevert(Ryo.AlreadyPaused.selector);
        vm.prank(OPERATOR);
        ryo.pause();
    }

    function test_RevertWhen_directCallback() public {
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(tokenA));
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = ONE;
        uint256[] memory fees = new uint256[](1);

        vm.expectRevert(Ryo.UnauthorizedCallback.selector);
        ryo.receiveFlashLoan(tokens, amounts, fees, abi.encodePacked(uint8(0)));
    }

    function test_RevertWhen_fakeVaultCallsCallback() public {
        FakeVault fake = new FakeVault();
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(tokenA));
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = ONE;
        uint256[] memory fees = new uint256[](1);

        vm.expectRevert(Ryo.UnauthorizedCallback.selector);
        fake.call(address(ryo), tokens, amounts, fees, abi.encodePacked(uint8(0)));
    }

    function test_RevertWhen_vaultCallsWithoutActiveLoan() public {
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(tokenA));
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = ONE;
        uint256[] memory fees = new uint256[](1);

        vm.prank(address(vault));
        vm.expectRevert(Ryo.UnexpectedCallback.selector);
        ryo.receiveFlashLoan(tokens, amounts, fees, abi.encodePacked(uint8(0)));
    }

    function test_RevertWhen_vaultSkipsCallback() public {
        vault.setSkipCallback(true);
        vm.expectRevert(Ryo.UnexpectedCallback.selector);
        vm.prank(OPERATOR);
        ryo.executePrimary(0, 10 * ONE, 0);
    }

    function test_RevertWhen_reentrancy() public {
        // Deploy the malicious router first (with a temporary zero target), then deploy a Ryo whose
        // immutable sell router is that address and whose operator is the router. This lets the
        // reentrant call pass onlyOperator and hit the nonReentrant guard.
        MockBalancerVault v = new MockBalancerVault();
        MockV3Router buy = new MockV3Router();
        MockERC20 a = new MockERC20("A2", "A2", 18);
        MockERC20 b = new MockERC20("B2", "B2", 18);

        a.mint(address(v), 1_000_000 * ONE);
        a.mint(address(buy), 1_000_000 * ONE);
        b.mint(address(buy), 1_000_000 * ONE);
        buy.setRate(address(a), address(b), 1.1e18);

        ReentrantV2Router evil =
            new ReentrantV2Router(Ryo(payable(address(0))), IERC20(address(a)), 10 * ONE);

        Ryo target = new Ryo(
            address(v),
            address(this),
            address(evil),
            _route(address(a), address(b), address(buy), 6, 500, address(evil), 8),
            _disabledRoute(),
            new address[](0),
            0,
            0,
            0
        );
        evil.setTarget(target);
        a.mint(address(evil), 1_000_000 * ONE);

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        evil.attack();
    }

    // ----------------------------------------------------------------------------------------
    // Tokens / limits / admin
    // ----------------------------------------------------------------------------------------

    function test_feeOnTransferBorrowedAssetRevertsSafely() public {
        MockBalancerVault v = new MockBalancerVault();
        MockV3Router buy = new MockV3Router();
        MockV2Router sell = new MockV2Router();
        MockFeeERC20 fot = new MockFeeERC20("FOT", "FOT", 18, 100); // 1%
        MockERC20 b = new MockERC20("B3", "B3", 18);

        fot.mint(address(v), 1_000_000 * ONE);
        fot.mint(address(sell), 1_000_000 * ONE);
        b.mint(address(buy), 1_000_000 * ONE);
        buy.setRate(address(fot), address(b), 1.1e18);
        sell.setRate(address(b), address(fot), 1.0e18);

        Ryo r = new Ryo(
            address(v),
            address(this),
            OPERATOR,
            _route(address(fot), address(b), address(buy), 6, 500, address(sell), 8),
            _disabledRoute(),
            new address[](0),
            0,
            0,
            0
        );

        vm.expectRevert();
        vm.prank(OPERATOR);
        r.executePrimary(0, 10 * ONE, 0);
        assertEq(fot.balanceOf(address(r)), 0);
    }

    function test_withdrawAndRescue() public {
        tokenA.mint(address(ryo), 5 * ONE);
        ryo.withdraw(address(tokenA), 5 * ONE);
        assertEq(tokenA.balanceOf(address(this)), 5 * ONE);

        tokenA.mint(address(ryo), 3 * ONE);
        ryo.rescueTokens(address(tokenA), STRANGER, 3 * ONE);
        assertEq(tokenA.balanceOf(STRANGER), 3 * ONE);

        vm.deal(address(ryo), 1 ether);
        uint256 selfBefore = address(this).balance;
        ryo.withdrawETH(0.4 ether);
        assertEq(address(this).balance, selfBefore + 0.4 ether);

        uint256 strangerBefore = STRANGER.balance;
        ryo.rescueETH(STRANGER, 0.6 ether);
        assertEq(STRANGER.balance, strangerBefore + 0.6 ether);

        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OPERATOR)
        );
        vm.prank(OPERATOR);
        ryo.withdraw(address(tokenA), 1);
    }

    function test_twoStepOwnership() public {
        address newOwner = address(0xC0FFEE);
        ryo.transferOwnership(newOwner);
        assertEq(ryo.owner(), address(this));
        assertEq(ryo.pendingOwner(), newOwner);

        vm.prank(newOwner);
        ryo.acceptOwnership();
        assertEq(ryo.owner(), newOwner);
    }

    function test_routerWhitelistAndPrimaryRouteViews() public {
        Ryo.PrimaryRouteConfig memory r = ryo.primaryRoute(0);
        assertEq(r.asset, address(tokenA));
        assertEq(r.intermediate, address(tokenB));
        assertEq(r.buyRouter, address(v3));
        assertEq(r.sellRouter, address(v2));
        assertEq(r.buyDexType, 6);
        assertEq(r.sellDexType, 8);
        assertEq(r.buyFee, 500);

        assertTrue(ryo.isRouterWhitelisted(address(v2)));
        assertTrue(ryo.isRouterWhitelisted(address(v3)));

        ryo.setRouterWhitelist(address(v2), false);
        assertFalse(ryo.isRouterWhitelisted(address(v2)));

        vm.expectRevert(abi.encodeWithSelector(Ryo.RouterNotWhitelisted.selector, address(v2)));
        vm.prank(OPERATOR);
        ryo.executePrimary(0, 10 * ONE, 0);
    }

    function test_zeroMaxTradeSizeMeansUnlimited() public {
        ryo.setMaxTradeSize(address(tokenA), 0);
        vm.prank(OPERATOR);
        uint256 profit = ryo.executePrimary(0, 500 * ONE, 0);
        assertEq(profit, 50 * ONE);
    }

    function test_unsupportedPrimaryRouteId() public {
        vm.expectRevert(abi.encodeWithSelector(Ryo.InvalidRouteId.selector, 2));
        ryo.primaryRoute(2);
    }
}

contract FakeVault {
    function call(
        address target,
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory fees,
        bytes memory userData
    ) external {
        Ryo(payable(target)).receiveFlashLoan(tokens, amounts, fees, userData);
    }
}
