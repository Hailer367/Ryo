// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Aerodrome classic router interface.
/// @dev Base mainnet router: 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43
///      (verified on-chain: `swapExactTokensForTokens(uint256,uint256,Route[],address,uint256)`
///      selector 0xcac88ea9).
///
///      Aerodrome does not use the Uniswap V2 "path" shape. A route is a list of hops, and each
///      hop states which two tokens it trades, whether the pool is a "stable" pool (pegged assets
///      priced differently from the constant-product formula) or a "volatile" one, and which
///      factory owns the pool. `factory == address(0)` means "use the router's default factory".
///
///      The router pulls the input token from `msg.sender`, so the caller must approve the router.
interface IAerodromeRouter {
    /// @param from Input token of this hop.
    /// @param to Output token of this hop.
    /// @param stable True for a stable (pegged) pool, false for a volatile pool.
    /// @param factory Pool factory, or address(0) for the router's default factory.
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}
