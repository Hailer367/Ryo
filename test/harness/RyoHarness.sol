// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ryo } from "../../src/Ryo.sol";
import { ISwapRouter02 } from "../../src/interfaces/ISwapRouter02.sol";

interface IWETH {
    function deposit() external payable;
}

/// @dev Exposes internal assembly-optimized functions and plain-Solidity references for
///      differential testing. This contract is test-only and is never deployed.
contract RyoHarness is Ryo {
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

    function wrapETH(address weth, uint256 amount) external {
        IWETH(weth).deposit{ value: amount }();
    }

    function swapV3ForTest(
        address router,
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 minOut
    ) external returns (uint256) {
        return _swapV3(router, tokenIn, tokenOut, fee, amountIn, minOut, 0);
    }

    /// @dev Plain-Solidity reference used by the assembly differential tests.
    function swapV3PlainForTest(
        address router,
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 minOut
    ) external returns (uint256 amountOut) {
        IERC20(tokenIn).forceApprove(router, amountIn);

        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));
        ISwapRouter02(router)
            .exactInputSingle(
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: fee,
                    recipient: address(this),
                    amountIn: amountIn,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                })
            );
        uint256 balanceAfter = IERC20(tokenOut).balanceOf(address(this));

        if (IERC20(tokenIn).allowance(address(this), router) != 0) {
            IERC20(tokenIn).forceApprove(router, 0);
        }

        return balanceAfter - balanceBefore;
    }

    function decodeV3ExtraForTest(bytes calldata data)
        external
        pure
        returns (uint24 fee, uint256 minOut)
    {
        return _decodeV3Extra(data);
    }

    /// @dev Plain reference for the assembly fee/minOut decoder. Takes memory like the production
    ///      `_decodeV3Extra`, so the gas comparison does not include an extra calldata copy.
    function decodeV3ExtraReference(bytes calldata data)
        external
        pure
        returns (uint24 fee, uint256 minOut)
    {
        return _decodeV3ExtraReferenceMemory(data);
    }

    function _decodeV3ExtraReferenceMemory(bytes memory data)
        internal
        pure
        returns (uint24 fee, uint256 minOut)
    {
        if (data.length == 32) {
            fee = abi.decode(data, (uint24));
            minOut = 1;
        } else if (data.length == 64) {
            (fee, minOut) = abi.decode(data, (uint24, uint256));
            if (minOut == 0) minOut = 1;
        } else {
            revert("reference: bad length");
        }
    }
}
