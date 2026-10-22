// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IUniswapV2Router02 } from "../../src/interfaces/IUniswapV2Router02.sol";

contract MockV2Router is IUniswapV2Router02 {
    mapping(address => mapping(address => uint256)) public rateE18; // out = in * rate / 1e18
    bool public failNext;

    function setRate(address tokenIn, address tokenOut, uint256 rate) external {
        rateE18[tokenIn][tokenOut] = rate;
    }

    function setFailNext(bool fail) external {
        failNext = fail;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        if (failNext) revert("MockV2: forced failure");
        require(path.length >= 2, "MockV2: path");

        address tokenIn = path[0];
        address tokenOut = path[path.length - 1];

        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = (amountIn * rateE18[tokenIn][tokenOut]) / 1e18;
        require(out >= amountOutMin, "MockV2: slippage");
        IERC20(tokenOut).transfer(to, out);

        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = out;
    }
}
