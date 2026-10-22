// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Aerodrome Slipstream (concentrated liquidity) swap router interface.
/// @dev Base mainnet router: 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5
///      (verified on-chain: `exactInputSingle((address,address,int24,address,uint256,uint256,uint256,uint160))`
///      selector 0xa026383e).
///
///      Slipstream is Uniswap V3's "concentrated liquidity" model, but its router differs from
///      Uniswap's: instead of a fee tier it uses a "tick spacing" number to identify the pool, and
///      it carries an extra deadline field. The field order below is the deployed order and must
///      not be changed.
///
///      The router pulls the input token from `msg.sender` through its swap callback, so the caller
///      must approve the router.
interface ISlipstreamSwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        int24 tickSpacing;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}
