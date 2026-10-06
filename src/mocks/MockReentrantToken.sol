// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test-only ERC20 that attempts a callback during token movement.
/// @dev The callback failure is swallowed so the outer token transfer can
///      continue. Tests can therefore prove that Arvo's reentrancy guard
///      rejected the nested call without relying on the whole transfer reverting.
contract MockReentrantToken is ERC20 {
    uint8 private immutable _customDecimals;

    address public callbackTarget;
    bytes public callbackData;

    bool public attackEnabled;
    bool public callbackAttempted;
    bool public callbackSucceeded;

    bool private _insideCallback;

    constructor(string memory name_, string memory symbol_, uint8 decimals_)
        ERC20(name_, symbol_)
    {
        _customDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _customDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configureAttack(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
        callbackAttempted = false;
        callbackSucceeded = false;
    }

    function setAttackEnabled(bool enabled) external {
        attackEnabled = enabled;
    }

    function resetAttackResult() external {
        callbackAttempted = false;
        callbackSucceeded = false;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);

        if (
            attackEnabled
                && !_insideCallback
                && from != address(0)
                && to != address(0)
                && callbackTarget != address(0)
        ) {
            _insideCallback = true;
            callbackAttempted = true;

            (bool success,) = callbackTarget.call(callbackData);

            callbackSucceeded = success;
            _insideCallback = false;
        }
    }
}
