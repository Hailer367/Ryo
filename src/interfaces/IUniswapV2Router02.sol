// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Minimal Uniswap V2-style router interface.
/// @dev Covers Uniswap V2, SushiSwap V2, PancakeSwap V2, BaseSwap and similar forks.
interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}
