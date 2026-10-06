// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";
import { Options } from "openzeppelin-foundry-upgrades/Options.sol";

contract ArvoStakingUpgradeValidationTest is Test {
    function testUpgradePreservesReviewedStorageLayout() public {
        Options memory opts;
        opts.unsafeAllow = "constructor";
        opts.referenceContract = "ArvoStakingBaseline.sol:ArvoStakingBaseline";
        Upgrades.validateUpgrade("ArvoStaking.sol:ArvoStaking", opts);
    }

    function testImplementationPassesOpenZeppelinValidation() public {
        Options memory opts;

        // OpenZeppelin Contracts 5.7 marks ReentrancyGuard as stateless and
        // directs upgradeable contracts to use the regular implementation.
        // The upgrades validator still detects its constructor, so allow only
        // the constructor validation category. All other checks remain enabled.
        opts.unsafeAllow = "constructor";

        Upgrades.validateImplementation("ArvoStaking.sol:ArvoStaking", opts);
    }
}
