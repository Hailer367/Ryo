// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ryo } from "../../src/Ryo.sol";
import { ISwapRouter02 } from "../../src/interfaces/ISwapRouter02.sol";

/// @dev Plain-Solidity reference implementations of the two assembly-optimized paths in Ryo.
///
///      This contract deliberately inherits Ryo, exactly like the harness that exposes the
///      production assembly paths. The compiler treats an inherited contract's code differently
///      from a standalone contract, so a reference that lives in its own small contract would not
///      be a fair gas comparison. Keeping both sides in Ryo-derived contracts makes the two
///      measurements comparable: same contract size class, same call shape, same cold access.
///
///      This contract is test-only and is never deployed.
contract RyoPlainReference is Ryo {
    using SafeERC20 for IERC20;

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

    /// @dev Same shape as RyoHarness.callExactInputSingleForTest, but the router is called through
    ///      the normal ABI encoder instead of the hand-written calldata.
    function callExactInputSingleForTest(
        address router,
        address tokenIn,
        address tokenOut,
        address recipient,
        uint24 fee,
        uint256 amountIn,
        uint256 minOut
    ) external {
        ISwapRouter02(router)
            .exactInputSingle(
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: fee,
                    recipient: recipient,
                    amountIn: amountIn,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                })
            );
    }
}
