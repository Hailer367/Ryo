// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IBalancerVault } from "../../src/interfaces/IBalancerVault.sol";
import { IFlashLoanRecipient } from "../../src/interfaces/IFlashLoanRecipient.sol";

/// @dev Minimal Balancer V2 Vault stand-in: lend, callback, then check that the recipient repaid
///      by transferring tokens back. This mirrors the real Vault, which does not pull repayment.
contract MockBalancerVault is IBalancerVault {
    error InvalidPostLoanBalance();
    error InsufficientFlashLoanBalance();

    uint256 public feeBps;
    bool public skipCallback;

    function setFeeBps(uint256 feeBps_) external {
        feeBps = feeBps_;
    }

    function setSkipCallback(bool skip) external {
        skipCallback = skip;
    }

    function flashLoan(
        IFlashLoanRecipient recipient,
        IERC20[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external {
        uint256 len = tokens.length;
        uint256[] memory fees = new uint256[](len);
        uint256[] memory preLoanBalances = new uint256[](len);

        for (uint256 i; i < len;) {
            fees[i] = (amounts[i] * feeBps) / 10_000;
            preLoanBalances[i] = tokens[i].balanceOf(address(this));
            if (preLoanBalances[i] < amounts[i]) revert InsufficientFlashLoanBalance();
            tokens[i].transfer(address(recipient), amounts[i]);
            unchecked {
                ++i;
            }
        }

        if (skipCallback) return;
        recipient.receiveFlashLoan(tokens, amounts, fees, userData);

        for (uint256 i; i < len;) {
            if (tokens[i].balanceOf(address(this)) < preLoanBalances[i] + fees[i]) {
                revert InvalidPostLoanBalance();
            }
            unchecked {
                ++i;
            }
        }
    }
}
