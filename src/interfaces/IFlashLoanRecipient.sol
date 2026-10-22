// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Balancer V2 flash-loan recipient interface.
/// @dev The Balancer Vault calls this after transferring the borrowed tokens to the recipient.
///      The recipient must transfer `amount + feeAmount` of each token back to the Vault before
///      returning; the Vault checks its token balances after the callback rather than pulling.
interface IFlashLoanRecipient {
    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external;
}
