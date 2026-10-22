// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IAerodromeRouter } from "../../src/interfaces/IAerodromeRouter.sol";

/// @dev Test double for the Aerodrome classic router. Uses a fixed rate per token pair and
///      records the hops it was called with so tests can assert on the stable/volatile flags.
contract MockAerodromeRouter is IAerodromeRouter {
    mapping(address => mapping(address => uint256)) public rateE18; // out = in * rate / 1e18
    bool public failNext;
    Route[] public lastRoutes;
    address public lastTo;
    uint256 public lastAmountIn;

    function setRate(address tokenIn, address tokenOut, uint256 rate) external {
        rateE18[tokenIn][tokenOut] = rate;
    }

    function setFailNext(bool fail) external {
        failNext = fail;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        if (failNext) revert("MockAero: forced failure");
        require(routes.length >= 1, "MockAero: routes");

        delete lastRoutes;
        for (uint256 i = 0; i < routes.length; ++i) {
            lastRoutes.push(routes[i]);
        }
        lastTo = to;
        lastAmountIn = amountIn;

        address tokenIn = routes[0].from;
        address tokenOut = routes[routes.length - 1].to;

        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = (amountIn * rateE18[tokenIn][tokenOut]) / 1e18;
        require(out >= amountOutMin, "MockAero: slippage");
        IERC20(tokenOut).transfer(to, out);

        amounts = new uint256[](routes.length + 1);
        amounts[0] = amountIn;
        amounts[routes.length] = out;
    }
}
