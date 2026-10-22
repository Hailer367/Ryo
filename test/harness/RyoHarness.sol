// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ryo } from "../../src/Ryo.sol";

/// @dev Exposes internal assembly-optimized functions for differential and fork testing. This
///      contract is test-only and is never deployed.
///
///      The plain-Solidity reference implementations live in the test files themselves so that the
///      comparison is against an independent implementation, and so this contract stays under the
///      EIP-170 runtime size limit.
contract RyoHarness is Ryo {
    constructor(
        address vault_,
        address initialOwner,
        address initialOperator,
        PrimaryRouteConfig memory route0,
        PrimaryRouteConfig memory route1,
        address[] memory initialRouters,
        uint256 initialMaxGasPrice,
        uint256 route0MaxTradeSize,
        uint256 route1MaxTradeSize
    )
        Ryo(
            vault_,
            initialOwner,
            initialOperator,
            route0,
            route1,
            initialRouters,
            initialMaxGasPrice,
            route0MaxTradeSize,
            route1MaxTradeSize
        )
    { }

    function swapV3ForTest(
        address router,
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 minOut
    ) external returns (uint256) {
        return _swapV3(router, tokenIn, tokenOut, fee, amountIn, minOut, 0);
    }

    /// @dev Same shape as RyoPlainReference.callExactInputSingleForTest, but writes the calldata
    ///      by hand. The recipient is always this contract, which is what the production path
    ///      does, so the caller must pass this contract as `recipient` to get matching calldata.
    function callExactInputSingleForTest(
        address router,
        address tokenIn,
        address tokenOut,
        address,
        /* recipient */
        uint24 fee,
        uint256 amountIn,
        uint256 minOut
    ) external {
        _callExactInputSingle(router, tokenIn, tokenOut, fee, amountIn, minOut);
    }
}
