// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IArvoPriceOracle } from "../interfaces/IArvoPriceOracle.sol";

/// @notice TESTING ONLY. Never use this implementation on mainnet.
contract MockArvoPriceOracle is IArvoPriceOracle {
    uint256 private _price;
    uint8 private immutable _decimals;
    uint256 private _updatedAt;

    constructor(uint256 initialPrice, uint8 priceDecimals) {
        _price = initialPrice;
        _decimals = priceDecimals;
        _updatedAt = block.timestamp;
    }

    function setPrice(uint256 newPrice) external {
        _price = newPrice;
        _updatedAt = block.timestamp;
    }

    function setPriceAndTimestamp(uint256 newPrice, uint256 timestamp) external {
        _price = newPrice;
        _updatedAt = timestamp;
    }

    function getArvoUsdPrice()
        external
        view
        returns (uint256 price, uint8 decimals, uint256 updatedAt)
    {
        return (_price, _decimals, _updatedAt);
    }
}
