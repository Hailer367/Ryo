// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ISwapRouter02 } from "../src/interfaces/ISwapRouter02.sol";
import { Ryo } from "../src/Ryo.sol";
import { RyoHarness } from "./harness/RyoHarness.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockBalancerVault } from "./mocks/MockBalancerVault.sol";
import { MockV2Router } from "./mocks/MockV2Router.sol";
import { MockV3Router } from "./mocks/MockV3Router.sol";

contract RyoAssemblyTest is Test {
    uint256 internal constant ONE = 1e18;

    MockBalancerVault internal vault;
    MockV2Router internal v2;
    MockV3Router internal v3;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    RyoHarness internal harness;

    function setUp() public {
        vault = new MockBalancerVault();
        v2 = new MockV2Router();
        v3 = new MockV3Router();
        tokenA = new MockERC20("Token A", "A", 18);
        tokenB = new MockERC20("Token B", "B", 18);

        tokenA.mint(address(vault), 1_000_000 * ONE);
        tokenB.mint(address(v3), 1_000_000 * ONE);
        tokenA.mint(address(v2), 1_000_000 * ONE);
        v3.setRate(address(tokenA), address(tokenB), 1.1e18);
        v2.setRate(address(tokenB), address(tokenA), 1.0e18);

        harness = new RyoHarness(
            address(vault),
            address(this),
            address(this),
            Ryo.PrimaryRouteConfig({
                asset: address(tokenA),
                intermediate: address(tokenB),
                buyRouter: address(v3),
                sellRouter: address(v2),
                buyDexType: 6,
                sellDexType: 8,
                buyFee: 500,
                sellFee: 0
            }),
            Ryo.PrimaryRouteConfig({
                asset: address(0),
                intermediate: address(0),
                buyRouter: address(0),
                sellRouter: address(0),
                buyDexType: 0,
                sellDexType: 0,
                buyFee: 0,
                sellFee: 0
            }),
            new address[](0),
            0,
            0,
            0
        );

        tokenA.mint(address(harness), 1_000 * ONE);
    }

    // ----------------------------------------------------------------------------------------
    // Assembly ABI encoding + output differential
    // ----------------------------------------------------------------------------------------

    function test_assemblySwap_matchesPlainReference() public {
        uint256 amountIn = 10 * ONE;
        uint256 minOut = 5 * ONE;

        uint256 snap = vm.snapshotState();

        uint256 outAssembly = harness.swapV3ForTest(
            address(v3), address(tokenA), address(tokenB), 500, amountIn, minOut
        );
        bytes memory assemblyCalldata = v3.lastCalldata();

        vm.revertToState(snap);

        uint256 outPlain = harness.swapV3PlainForTest(
            address(v3), address(tokenA), address(tokenB), 500, amountIn, minOut
        );
        bytes memory plainCalldata = v3.lastCalldata();

        assertEq(outAssembly, outPlain, "output mismatch");
        assertEq(keccak256(assemblyCalldata), keccak256(plainCalldata), "calldata mismatch");

        bytes memory expected = abi.encodeWithSelector(
            ISwapRouter02.exactInputSingle.selector,
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: address(tokenA),
                tokenOut: address(tokenB),
                fee: 500,
                recipient: address(harness),
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
        assertEq(keccak256(assemblyCalldata), keccak256(expected), "ABI layout mismatch");
        assertEq(assemblyCalldata.length, 4 + 7 * 32, "calldata length");
    }

    /// @dev Measures the two implementations from the same state. This is test-only profiling; the
    ///      production path is the assembly one in Ryo._callExactInputSingle.
    function test_gas_assemblySwap_vsPlain() public {
        uint256 amountIn = 10 * ONE;
        uint256 minOut = 5 * ONE;

        uint256 snap = vm.snapshotState();

        vm.cool(address(harness));
        vm.cool(address(v3));
        vm.cool(address(tokenA));
        vm.cool(address(tokenB));
        uint256 before = gasleft();
        harness.swapV3ForTest(address(v3), address(tokenA), address(tokenB), 500, amountIn, minOut);
        uint256 assemblyGas = before - gasleft();

        vm.revertToState(snap);

        vm.cool(address(harness));
        vm.cool(address(v3));
        vm.cool(address(tokenA));
        vm.cool(address(tokenB));
        before = gasleft();
        harness.swapV3PlainForTest(
            address(v3), address(tokenA), address(tokenB), 500, amountIn, minOut
        );
        uint256 plainGas = before - gasleft();

        emit log_named_uint("assembly swap gas", assemblyGas);
        emit log_named_uint("plain swap gas", plainGas);
        assertLt(assemblyGas, plainGas, "assembly should be cheaper");
    }

    function test_assemblySwap_bubblesRouterRevert() public {
        v3.setFailNext(true);
        vm.expectRevert("MockV3: forced failure");
        harness.swapV3ForTest(address(v3), address(tokenA), address(tokenB), 500, ONE, 1);
    }

    function test_assemblySwap_enforcesMinOut() public {
        v3.setRate(address(tokenA), address(tokenB), 0.5e18);
        vm.expectRevert("MockV3: slippage");
        harness.swapV3ForTest(address(v3), address(tokenA), address(tokenB), 500, ONE, ONE);
    }

    // ----------------------------------------------------------------------------------------
    // Assembly extraData decode differential
    // ----------------------------------------------------------------------------------------

    function test_gas_decodeV3Extra_vsReference() public {
        bytes memory data = abi.encode(uint24(500), uint256(1e18));

        vm.cool(address(harness));
        uint256 before = gasleft();
        harness.decodeV3ExtraForTest(data);
        uint256 assemblyGas = before - gasleft();

        vm.cool(address(harness));
        before = gasleft();
        harness.decodeV3ExtraReference(data);
        uint256 plainGas = before - gasleft();

        emit log_named_uint("assembly decode gas", assemblyGas);
        emit log_named_uint("plain decode gas", plainGas);
        assertLt(assemblyGas, plainGas, "assembly decoder should be cheaper");
    }

    function test_decodeV3Extra_32Byte_matchesReference_fuzz(uint24 fee) public view {
        bytes memory data = abi.encode(fee);
        (uint24 gotFee, uint256 gotMin) = harness.decodeV3ExtraForTest(data);
        (uint24 refFee, uint256 refMin) = harness.decodeV3ExtraReference(data);
        assertEq(gotFee, refFee);
        assertEq(gotMin, refMin);
        assertEq(gotMin, 1);
    }

    function test_decodeV3Extra_64Byte_matchesReference_fuzz(uint24 fee, uint256 minOut)
        public
        view
    {
        minOut = bound(minOut, 0, type(uint128).max);
        bytes memory data = abi.encode(fee, minOut);
        (uint24 gotFee, uint256 gotMin) = harness.decodeV3ExtraForTest(data);
        (uint24 refFee, uint256 refMin) = harness.decodeV3ExtraReference(data);
        assertEq(gotFee, refFee);
        assertEq(gotMin, refMin);
    }

    function test_decodeV3Extra_rejectsBadLength() public {
        bytes memory data = hex"001122";
        vm.expectRevert(abi.encodeWithSelector(Ryo.InvalidExtraData.selector, 0));
        harness.decodeV3ExtraForTest(data);
    }
}
