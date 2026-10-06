// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ArvoStaking } from "../../../src/ArvoStaking.sol";

contract ArvoStakingV2 is ArvoStaking {
    function version() external pure returns (uint256) {
        return 2;
    }
}
