// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ISwapRouter02 } from "../../src/interfaces/ISwapRouter02.sol";

contract MockV3Router is ISwapRouter02 {
    mapping(address => mapping(address => uint256)) public rateE18; // out = in * rate / 1e18
    bool public failNext;
    bytes public lastCalldata;
    uint24 public lastFee;
    uint256 public lastAmountOutMinimum;
    address public lastRecipient;
    bool public pullTokens = true;

    function setRate(address tokenIn, address tokenOut, uint256 rate) external {
        rateE18[tokenIn][tokenOut] = rate;
    }

    function setFailNext(bool fail) external {
        failNext = fail;
    }

    /// @dev When disabled the mock records the call but does not pull tokens, which lets the gas
    ///      test compare the two calldata encodings without any approval in the way.
    function setPullTokens(bool pull) external {
        pullTokens = pull;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut)
    {
        if (failNext) revert("MockV3: forced failure");
        lastCalldata = msg.data;
        lastFee = params.fee;
        lastAmountOutMinimum = params.amountOutMinimum;
        lastRecipient = params.recipient;

        if (pullTokens) {
            IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        }
        amountOut = (params.amountIn * rateE18[params.tokenIn][params.tokenOut]) / 1e18;
        require(amountOut >= params.amountOutMinimum, "MockV3: slippage");
        if (pullTokens) {
            IERC20(params.tokenOut).transfer(params.recipient, amountOut);
        }
    }
}
