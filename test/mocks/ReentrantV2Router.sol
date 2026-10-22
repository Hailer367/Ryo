// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IUniswapV2Router02 } from "../../src/interfaces/IUniswapV2Router02.sol";
import { Ryo } from "../../src/Ryo.sol";

/// @dev Router that re-enters Ryo while a swap is executing. The reentrant call must be
///      rejected by the transient reentrancy guard.
contract ReentrantV2Router is IUniswapV2Router02 {
    Ryo public target;
    IERC20 public immutable tokenOut;
    uint256 public immutable borrowAmount;
    bool public entered;

    constructor(Ryo target_, IERC20 tokenOut_, uint256 borrowAmount_) {
        target = target_;
        tokenOut = tokenOut_;
        borrowAmount = borrowAmount_;
    }

    /// @dev Test-only circular-deployment helper.
    function setTarget(Ryo target_) external {
        target = target_;
    }

    function attack() external {
        target.executePrimary(0, borrowAmount, 0);
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        require(amountOutMin <= amountIn, "Reentrant: slippage");
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        tokenOut.transfer(to, amountIn);

        if (!entered) {
            entered = true;
            // msg.sender is Ryo; target's operator is this router, so onlyOperator passes and the
            // reentrancy guard must revert.
            target.executePrimary(0, borrowAmount, 0);
        }

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn;
    }
}
