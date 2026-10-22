// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ISwapRouter02 } from "../src/interfaces/ISwapRouter02.sol";
import { Ryo } from "../src/Ryo.sol";
import { RyoHarness } from "./harness/RyoHarness.sol";
import { RyoPlainReference } from "./harness/RyoPlainReference.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockBalancerVault } from "./mocks/MockBalancerVault.sol";
import { MockV2Router } from "./mocks/MockV2Router.sol";
import { MockV3Router } from "./mocks/MockV3Router.sol";

/// @dev Differential tests for the hand-written V3 calldata.
///
///      The plain-Solidity reference lives in an Ryo-derived contract so that both sides are
///      compiled under the same conditions: the compiler treats an inherited contract's code
///      differently from a standalone one, and a reference in its own small contract would not be
///      a fair gas comparison.
contract RyoAssemblyTest is Test {
    uint256 internal constant ONE = 1e18;

    MockBalancerVault internal vault;
    MockV2Router internal v2;
    MockV3Router internal v3;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    RyoHarness internal harness;
    RyoPlainReference internal plainRef;

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
        // The gas test compares the calldata only, so the mock must not pull any tokens.
        v3.setPullTokens(false);

        harness = new RyoHarness(
            address(vault),
            address(this),
            address(this),
            _route0(),
            _route1(),
            new address[](0),
            0,
            0,
            0
        );
        plainRef = new RyoPlainReference(
            address(vault),
            address(this),
            address(this),
            _route0(),
            _route1(),
            new address[](0),
            0,
            0,
            0
        );

        tokenA.mint(address(harness), 1_000 * ONE);
    }

    function _route0() internal view returns (Ryo.PrimaryRouteConfig memory) {
        return Ryo.PrimaryRouteConfig({
            asset: address(tokenA),
            intermediate: address(tokenB),
            buyRouter: address(v3),
            sellRouter: address(v2),
            buyDexType: 6,
            sellDexType: 8,
            buyFee: 500,
            sellFee: 0
        });
    }

    function _route1() internal pure returns (Ryo.PrimaryRouteConfig memory) {
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

    // ----------------------------------------------------------------------------------------
    // Calldata differential
    // ----------------------------------------------------------------------------------------

    function test_assemblyCalldata_matchesPlainReference() public {
        uint256 amountIn = 10 * ONE;
        uint256 minOut = 5 * ONE;

        uint256 snap = vm.snapshotState();

        harness.callExactInputSingleForTest(
            address(v3), address(tokenA), address(tokenB), address(harness), 500, amountIn, minOut
        );
        bytes memory assemblyCalldata = v3.lastCalldata();

        vm.revertToState(snap);

        plainRef.callExactInputSingleForTest(
            address(v3), address(tokenA), address(tokenB), address(harness), 500, amountIn, minOut
        );
        bytes memory plainCalldata = v3.lastCalldata();

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

    function test_assemblyCalldata_fuzzMatchesPlainReference(uint24 fee, uint256 amountIn) public {
        amountIn = bound(amountIn, 1, type(uint128).max);
        uint256 minOut = 1;

        uint256 snap = vm.snapshotState();

        harness.callExactInputSingleForTest(
            address(v3), address(tokenA), address(tokenB), address(harness), fee, amountIn, minOut
        );
        bytes memory assemblyCalldata = v3.lastCalldata();

        vm.revertToState(snap);

        plainRef.callExactInputSingleForTest(
            address(v3), address(tokenA), address(tokenB), address(harness), fee, amountIn, minOut
        );
        bytes memory plainCalldata = v3.lastCalldata();

        assertEq(keccak256(assemblyCalldata), keccak256(plainCalldata), "calldata mismatch");
    }

    // ----------------------------------------------------------------------------------------
    // Gas comparison
    // ----------------------------------------------------------------------------------------

    /// @dev Two cold calls of identical shape, one in each Ryo-derived contract. The only
    ///      difference is how the calldata is produced: hand-written versus ABI-encoded.
    function test_gas_assemblyCalldata_vsPlain() public {
        uint256 amountIn = 10 * ONE;
        uint256 minOut = 5 * ONE;

        uint256 snap = vm.snapshotState();

        vm.cool(address(harness));
        vm.cool(address(v3));
        uint256 before = gasleft();
        harness.callExactInputSingleForTest(
            address(v3), address(tokenA), address(tokenB), address(harness), 500, amountIn, minOut
        );
        uint256 assemblyGas = before - gasleft();

        vm.revertToState(snap);

        vm.cool(address(plainRef));
        vm.cool(address(v3));
        before = gasleft();
        plainRef.callExactInputSingleForTest(
            address(v3), address(tokenA), address(tokenB), address(harness), 500, amountIn, minOut
        );
        uint256 plainGas = before - gasleft();

        emit log_named_uint("assembly calldata gas", assemblyGas);
        emit log_named_uint("plain calldata gas", plainGas);
        assertLt(assemblyGas, plainGas, "assembly calldata should be cheaper");
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
