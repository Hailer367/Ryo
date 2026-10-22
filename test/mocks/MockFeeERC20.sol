// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Fee-on-transfer token used only by adversarial tests. The fee is burned to 0xdead.
contract MockFeeERC20 is ERC20 {
    uint8 private immutable _decimals;
    uint16 public immutable feeBps;

    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint16 feeBps_)
        ERC20(name_, symbol_)
    {
        _decimals = decimals_;
        feeBps = feeBps_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && feeBps != 0) {
            uint256 fee = (value * feeBps) / 10_000;
            if (fee != 0) {
                super._update(from, address(0xdead), fee);
                value -= fee;
            }
        }
        super._update(from, to, value);
    }
}
