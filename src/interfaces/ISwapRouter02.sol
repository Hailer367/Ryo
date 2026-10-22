// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Uniswap V3 SwapRouter02 interface (no deadline in the params struct).
/// @dev Base mainnet SwapRouter02: 0x2626664c2603336E57B271c5C0b26F421741e481.
///      Selector: 0x04e45aaf.
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}
