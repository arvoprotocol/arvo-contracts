// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockFeeToken is ERC20 {
    uint256 public constant FEE_BPS = 100; // 1%
    uint256 public constant BPS = 10_000;

    constructor() ERC20("Fee Token", "FEE") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = (value * FEE_BPS) / BPS;
            uint256 received = value - fee;

            super._update(from, to, received);

            if (fee != 0) {
                super._update(from, address(0), fee);
            }

            return;
        }

        super._update(from, to, value);
    }
}
