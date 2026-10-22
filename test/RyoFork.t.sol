// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console2 } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { Ryo } from "../src/Ryo.sol";
import { ISwapRouter02 } from "../src/interfaces/ISwapRouter02.sol";
import { IUniswapV2Router02 } from "../src/interfaces/IUniswapV2Router02.sol";
import { IAerodromeRouter } from "../src/interfaces/IAerodromeRouter.sol";
import { RyoHarness } from "./harness/RyoHarness.sol";

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @notice Fork tests against Base mainnet. Set BASE_RPC_URL (and optionally BASE_FORK_BLOCK).
///         Tests are skipped when BASE_RPC_URL is not set so `forge test` still works offline.
contract RyoForkTest is Test {
    using SafeERC20 for IERC20;

    // Verified official Base addresses (see README/WATCHER_INTERFACE.md).
    address internal constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant UNISWAP_V3_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address internal constant UNISWAP_V2_ROUTER = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;
    address internal constant AERODROME_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
    address internal constant SLIPSTREAM_ROUTER = 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5;

    address internal constant OPERATOR = address(0xB0B);

    bool internal forked;
    uint256 internal forkBlock;
    Ryo internal ryo;
    RyoHarness internal harness;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;

        forkBlock = vm.envOr("BASE_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) {
            vm.createSelectFork(rpc);
            forkBlock = block.number;
        } else {
            vm.createSelectFork(rpc, forkBlock);
        }
        require(block.chainid == 8453, "Base mainnet fork required");
        forked = true;

        Ryo.PrimaryRouteConfig memory route0 = Ryo.PrimaryRouteConfig({
            asset: WETH,
            intermediate: USDC,
            buyRouter: UNISWAP_V3_ROUTER,
            sellRouter: UNISWAP_V2_ROUTER,
            buyDexType: 6,
            sellDexType: 8,
            buyFee: 500,
            sellFee: 0
        });
        Ryo.PrimaryRouteConfig memory route1 = Ryo.PrimaryRouteConfig({
            asset: USDC,
            intermediate: WETH,
            buyRouter: UNISWAP_V3_ROUTER,
            sellRouter: UNISWAP_V2_ROUTER,
            buyDexType: 6,
            sellDexType: 8,
            buyFee: 500,
            sellFee: 0
        });

        ryo = new Ryo(
            BALANCER_VAULT,
            address(this),
            OPERATOR,
            route0,
            route1,
            new address[](0),
            0,
            10 ether,
            30_000e6
        );
        ryo.setRouterWhitelist(AERODROME_ROUTER, true);
        ryo.setRouterWhitelist(SLIPSTREAM_ROUTER, true);

        // The harness gives the tests direct access to the internal adapters, so each venue can be
        // exercised against its real router.
        harness = new RyoHarness(
            BALANCER_VAULT, address(this), OPERATOR, route0, route1, new address[](0), 0, 0, 0
        );
        vm.deal(address(harness), 2 ether);
        deal(WETH, address(harness), 1 ether);

        vm.deal(address(this), 2 ether);
        IWETH9(WETH).deposit{ value: 1 ether }();
    }

    modifier onlyForked() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    // ----------------------------------------------------------------------------------------
    // Price-gap profit test (primary fast path)
    // ----------------------------------------------------------------------------------------

    function test_fork_primaryProfitPath() public onlyForked {
        // Dump WETH into Uniswap V2 so WETH becomes cheap there relative to Uniswap V3.
        _dumpWethOnV2(100 ether);

        uint256 amount = 5 ether;
        uint256 ownerBefore = IERC20(WETH).balanceOf(address(this));
        uint256 vaultBefore = IERC20(WETH).balanceOf(BALANCER_VAULT);

        vm.prank(OPERATOR);
        uint256 profit = ryo.executePrimary(0, amount, 0.01 ether);

        assertGt(profit, 0.01 ether, "expected arbitrage profit");
        assertEq(IERC20(WETH).balanceOf(address(this)), ownerBefore + profit, "owner got profit");
        assertEq(IERC20(WETH).balanceOf(address(ryo)), 0, "contract holds no WETH");
        assertEq(IERC20(WETH).balanceOf(BALANCER_VAULT), vaultBefore, "flash loan repaid");

        console2.log("primary profit (WETH wei)", profit);
        console2.log("fork block", forkBlock);
    }

    // ----------------------------------------------------------------------------------------
    // Price-gap profit test (parameterized path)
    // ----------------------------------------------------------------------------------------

    function test_fork_dynamicProfitPath() public onlyForked {
        _dumpWethOnV2(100 ether);

        Ryo.Swap[] memory swaps = new Ryo.Swap[](2);
        swaps[0] = Ryo.Swap({
            dexType: 6,
            router: UNISWAP_V3_ROUTER,
            tokenIn: WETH,
            tokenOut: USDC,
            extraData: abi.encode(uint24(500))
        });
        swaps[1] = Ryo.Swap({
            dexType: 8, router: UNISWAP_V2_ROUTER, tokenIn: USDC, tokenOut: WETH, extraData: ""
        });

        uint256 amount = 5 ether;
        uint256 ownerBefore = IERC20(WETH).balanceOf(address(this));

        vm.prank(OPERATOR);
        uint256 profit = ryo.execute(WETH, amount, swaps, 0.01 ether);

        assertGt(profit, 0.01 ether, "expected arbitrage profit");
        assertEq(IERC20(WETH).balanceOf(address(this)), ownerBefore + profit);
        assertEq(IERC20(WETH).balanceOf(address(ryo)), 0);

        console2.log("dynamic profit (WETH wei)", profit);
    }

    // ----------------------------------------------------------------------------------------
    // Price-gap profit test (primary route 1, USDC base)
    // ----------------------------------------------------------------------------------------

    function test_fork_primaryRoute1ProfitPath() public onlyForked {
        // Dump USDC into Uniswap V2 so WETH becomes expensive there relative to Uniswap V3.
        _dumpUsdcOnV2(100_000e6);

        uint256 amount = 10_000e6;
        uint256 ownerBefore = IERC20(USDC).balanceOf(address(this));
        uint256 vaultBefore = IERC20(USDC).balanceOf(BALANCER_VAULT);

        vm.prank(OPERATOR);
        uint256 profit = ryo.executePrimary(1, amount, 1e6);

        assertGt(profit, 1e6, "expected USDC arbitrage profit");
        assertEq(IERC20(USDC).balanceOf(address(this)), ownerBefore + profit);
        assertEq(IERC20(USDC).balanceOf(address(ryo)), 0);
        assertEq(IERC20(USDC).balanceOf(BALANCER_VAULT), vaultBefore, "flash loan repaid");

        console2.log("route1 profit (USDC units)", profit);
    }

    // ----------------------------------------------------------------------------------------
    // Aerodrome: real router, volatile and stable pools
    // ----------------------------------------------------------------------------------------

    /// @dev Round trip through the real Aerodrome volatile pool. The route cannot profit, so
    ///      `simulate` reports a small loss. The important part is that it reports a loss at all:
    ///      if the Aerodrome call had failed, the revert would carry the router's error instead.
    function test_fork_aerodromeVolatileRoundTrip() public onlyForked {
        int256 profit = _simulateRoundTrip(false, 0.1 ether, int24(0));

        assertLt(profit, 0, "round trip should not profit");
        assertGt(profit, -int256(0.01 ether), "loss should be small (fees only)");
        console2.log("Aerodrome volatile round trip (WETH wei)", profit);
    }

    function test_fork_aerodromeStableRoundTrip() public onlyForked {
        int256 profit = _simulateRoundTrip(true, 0.01 ether, int24(0));

        assertLt(profit, 0, "round trip should not profit");
        assertGt(profit, -int256(0.001 ether), "loss should be small (fees only)");
        console2.log("Aerodrome stable round trip (WETH wei)", profit);
    }

    function test_fork_aerodromeArbitrage() public onlyForked {
        // Dump WETH into the Aerodrome volatile pool so WETH becomes cheap there, then sell the
        // borrowed WETH on Uniswap V3 and buy it back on Aerodrome.
        _dumpWethOnAerodrome(100 ether);

        Ryo.Swap[] memory swaps = new Ryo.Swap[](2);
        swaps[0] = Ryo.Swap({
            dexType: 6,
            router: UNISWAP_V3_ROUTER,
            tokenIn: WETH,
            tokenOut: USDC,
            extraData: abi.encode(uint24(500))
        });
        swaps[1] = Ryo.Swap({
            dexType: 4,
            router: AERODROME_ROUTER,
            tokenIn: USDC,
            tokenOut: WETH,
            extraData: _aerodromeExtra(address(USDC), address(WETH), false, 1)
        });

        uint256 amount = 2 ether;
        uint256 ownerBefore = IERC20(WETH).balanceOf(address(this));
        uint256 vaultBefore = IERC20(WETH).balanceOf(BALANCER_VAULT);

        vm.prank(OPERATOR);
        uint256 profit = ryo.execute(WETH, amount, swaps, 0.001 ether);

        assertGt(profit, 0.001 ether, "expected Aerodrome arbitrage profit");
        assertEq(IERC20(WETH).balanceOf(address(this)), ownerBefore + profit);
        assertEq(IERC20(WETH).balanceOf(address(ryo)), 0);
        assertEq(IERC20(WETH).balanceOf(BALANCER_VAULT), vaultBefore, "flash loan repaid");

        console2.log("Aerodrome arbitrage profit (WETH wei)", profit);
    }

    // ----------------------------------------------------------------------------------------
    // Aerodrome Slipstream (concentrated liquidity): real router
    // ----------------------------------------------------------------------------------------

    function test_fork_slipstreamRoundTrip() public onlyForked {
        int256 profit = _simulateRoundTrip(false, 0.05 ether, int24(1));

        assertLt(profit, 0, "round trip should not profit");
        assertGt(profit, -int256(0.01 ether), "loss should be small (fees only)");
        console2.log("Slipstream round trip (WETH wei)", profit);
    }

    // ----------------------------------------------------------------------------------------
    // Assembly V3 call vs plain reference against the real SwapRouter02
    // ----------------------------------------------------------------------------------------

    function test_fork_assemblyV3MatchesPlainReference() public onlyForked {
        uint256 amountIn = 0.1 ether;
        uint256 snapshot = vm.snapshotState();

        uint256 assemblyOut = harness.swapV3ForTest(UNISWAP_V3_ROUTER, WETH, USDC, 500, amountIn, 1);
        vm.revertToState(snapshot);

        uint256 plainOut = _plainV3Swap(UNISWAP_V3_ROUTER, WETH, USDC, 500, amountIn, 1);

        assertEq(assemblyOut, plainOut, "assembly/plain output mismatch");
        assertGt(assemblyOut, 0, "zero output");
        console2.log("V3 assembly output (USDC units)", assemblyOut);
    }

    // ----------------------------------------------------------------------------------------
    // Historical replay (configurable via BASE_FORK_BLOCK)
    // ----------------------------------------------------------------------------------------

    function test_fork_historicalReplay() public onlyForked {
        // Reports the simulated primary-route result at the fork block. It intentionally does not
        // require a profit: the watcher uses this to evaluate blocks/routes after the fact.
        bytes memory callData =
            abi.encodeWithSelector(Ryo.simulatePrimary.selector, uint8(0), uint256(1 ether));

        vm.prank(OPERATOR);
        (bool ok, bytes memory ret) = address(ryo).call(callData);

        assertFalse(ok, "simulate must always revert");
        bytes4 selector = bytes4(ret);

        if (selector == Ryo.SimulationResult.selector) {
            int256 profit = abi.decode(_slice(ret, 4), (int256));
            console2.log("historical replay block", forkBlock);
            console2.log("historical replay profit (WETH wei, can be negative)", profit);
        } else {
            console2.log("historical replay reverted with selector:");
            console2.logBytes4(selector);
        }
    }

    // ----------------------------------------------------------------------------------------
    // Helpers
    // ----------------------------------------------------------------------------------------

    /// @dev Plain-Solidity reference for Ryo's assembly V3 swap, used by the fork differential test.
    function _plainV3Swap(
        address router,
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 minOut
    ) internal returns (uint256) {
        IERC20(tokenIn).forceApprove(router, amountIn);

        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));
        ISwapRouter02(router)
            .exactInputSingle(
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: fee,
                    recipient: address(this),
                    amountIn: amountIn,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                })
            );
        uint256 balanceAfter = IERC20(tokenOut).balanceOf(address(this));

        if (IERC20(tokenIn).allowance(address(this), router) != 0) {
            IERC20(tokenIn).forceApprove(router, 0);
        }

        return balanceAfter - balanceBefore;
    }

    function _aerodromeExtra(address tokenIn, address tokenOut, bool stable, uint256 minAmountOut)
        internal
        pure
        returns (bytes memory)
    {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        bool[] memory stables = new bool[](1);
        stables[0] = stable;
        return abi.encode(path, stables, minAmountOut);
    }

    /// @dev Runs a WETH -> USDC -> WETH round trip through the real router of the chosen venue
    ///      and returns the simulated profit. `tickSpacing == 0` selects the Aerodrome classic
    ///      router, otherwise the Slipstream router is used.
    function _simulateRoundTrip(bool stable, uint256 amount, int24 tickSpacing)
        internal
        returns (int256 profit)
    {
        Ryo.Swap[] memory swaps = new Ryo.Swap[](2);
        if (tickSpacing == 0) {
            swaps[0] = Ryo.Swap({
                dexType: 4,
                router: AERODROME_ROUTER,
                tokenIn: WETH,
                tokenOut: USDC,
                extraData: _aerodromeExtra(WETH, USDC, stable, 1)
            });
        } else {
            swaps[0] = Ryo.Swap({
                dexType: 7,
                router: SLIPSTREAM_ROUTER,
                tokenIn: WETH,
                tokenOut: USDC,
                extraData: abi.encode(tickSpacing)
            });
        }
        swaps[1] = Ryo.Swap({
            dexType: 6,
            router: UNISWAP_V3_ROUTER,
            tokenIn: USDC,
            tokenOut: WETH,
            extraData: abi.encode(uint24(500))
        });

        vm.prank(OPERATOR);
        (bool ok, bytes memory ret) =
            address(ryo).call(abi.encodeWithSelector(Ryo.simulate.selector, WETH, amount, swaps));

        assertFalse(ok, "simulate must revert");
        assertEq(bytes4(ret), Ryo.SimulationResult.selector, "expected SimulationResult");
        profit = abi.decode(_slice(ret, 4), (int256));
    }

    function _dumpWethOnV2(uint256 amount) internal {
        vm.deal(address(this), amount);
        IWETH9(WETH).deposit{ value: amount }();
        IERC20(WETH).approve(UNISWAP_V2_ROUTER, amount);

        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;
        IUniswapV2Router02(UNISWAP_V2_ROUTER)
            .swapExactTokensForTokens(amount, 0, path, address(this), block.timestamp);
    }

    function _dumpUsdcOnV2(uint256 amount) internal {
        deal(USDC, address(this), amount);
        IERC20(USDC).approve(UNISWAP_V2_ROUTER, amount);

        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = WETH;
        IUniswapV2Router02(UNISWAP_V2_ROUTER)
            .swapExactTokensForTokens(amount, 0, path, address(this), block.timestamp);
    }

    /// @dev Sells WETH into the Aerodrome volatile WETH/USDC pool, making WETH cheaper there.
    function _dumpWethOnAerodrome(uint256 amount) internal {
        vm.deal(address(this), amount);
        IWETH9(WETH).deposit{ value: amount }();
        IERC20(WETH).approve(AERODROME_ROUTER, amount);

        IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](1);
        routes[0] =
            IAerodromeRouter.Route({ from: WETH, to: USDC, stable: false, factory: address(0) });
        IAerodromeRouter(AERODROME_ROUTER)
            .swapExactTokensForTokens(amount, 0, routes, address(this), block.timestamp);
    }

    function _slice(bytes memory data, uint256 start) internal pure returns (bytes memory out) {
        uint256 len = data.length - start;
        out = new bytes(len);
        for (uint256 i; i < len;) {
            out[i] = data[start + i];
            unchecked {
                ++i;
            }
        }
    }
}
