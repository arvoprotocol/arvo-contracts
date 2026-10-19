// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @notice Price abstraction used when rewards require ARVO/USD conversion.
///
/// @dev Mainnet must use an approved external pricing source.
///      An administrator-entered spot price must not be used for production
///      cross-asset reward calculations.
interface IArvoPriceOracle {
    /// @return price ARVO/USD price.
    /// @return decimals Number of decimals used by price.
    /// @return updatedAt Timestamp of the underlying price observation.
    function getArvoUsdPrice()
        external
        view
        returns (uint256 price, uint8 decimals, uint256 updatedAt);
}
