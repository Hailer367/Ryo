// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ISlipstreamSwapRouter } from "../../src/interfaces/ISlipstreamSwapRouter.sol";

/// @dev Test double for the Aerodrome Slipstream (concentrated liquidity) swap router. Records
///      the tick spacing and recipient so tests can assert the adapter passed them through.
contract MockSlipstreamSwapRouter is ISlipstreamSwapRouter {
    mapping(address => mapping(address => uint256)) public rateE18; // out = in * rate / 1e18
    bool public failNext;
    int24 public lastTickSpacing;
    address public lastRecipient;
    uint256 public lastAmountIn;
    uint256 public lastDeadline;

    function setRate(address tokenIn, address tokenOut, uint256 rate) external {
        rateE18[tokenIn][tokenOut] = rate;
    }

    function setFailNext(bool fail) external {
        failNext = fail;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut)
    {
        if (failNext) revert("MockSlipstream: forced failure");
        lastTickSpacing = params.tickSpacing;
        lastRecipient = params.recipient;
        lastAmountIn = params.amountIn;
        lastDeadline = params.deadline;

        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        amountOut = (params.amountIn * rateE18[params.tokenIn][params.tokenOut]) / 1e18;
        require(amountOut >= params.amountOutMinimum, "MockSlipstream: slippage");
        IERC20(params.tokenOut).transfer(params.recipient, amountOut);
    }
}
