// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";
import { Options } from "openzeppelin-foundry-upgrades/Options.sol";

import { ArvoStaking } from "../../src/ArvoStaking.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";
import { ArvoStakingV2 } from "./mocks/ArvoStakingV2.sol";

contract ArvoStakingUpgradeTest is Test {
    MockERC20 internal arvoToken;
    MockERC20 internal usdcToken;

    ArvoStaking internal staking;

    address internal admin = address(0xA11CE);
    address internal attacker = address(0xBAD);

    function setUp() public {
        arvoToken = new MockERC20("ARVO", "ARVO", 18);
        usdcToken = new MockERC20("USD Coin", "USDC", 6);

        bytes memory initializerData = abi.encodeCall(
            ArvoStaking.initialize, (address(arvoToken), address(usdcToken), admin)
        );

        Options memory opts;
        // Allow only the reviewed mapping-based factory library; no assembly or
        // external token calls occur in that library. Keep storage checks enabled.
        opts.unsafeAllow = "constructor,external-library-linking";

        address proxy =
            Upgrades.deployUUPSProxy("ArvoStaking.sol:ArvoStaking", initializerData, opts);

        staking = ArvoStaking(proxy);
    }

    function testUnauthorizedAccountCannotUpgrade() public {
        ArvoStakingV2 newImplementation = new ArvoStakingV2();

        address implementationBefore = Upgrades.getImplementationAddress(address(staking));

        vm.prank(attacker);
        vm.expectRevert();

        staking.upgradeToAndCall(address(newImplementation), bytes(""));

        assertEq(Upgrades.getImplementationAddress(address(staking)), implementationBefore);
    }

    function testAuthorizedUpgradeSucceedsAndPreservesState() public {
        address implementationBefore = Upgrades.getImplementationAddress(address(staking));

        Options memory opts;
        opts.referenceContract = "ArvoStaking.sol:ArvoStaking";
        // Allow only the reviewed mapping-based factory library; no assembly or
        // external token calls occur in that library. Keep storage checks enabled.
        opts.unsafeAllow = "constructor,external-library-linking";

        Upgrades.upgradeProxy(
            address(staking),
            "test/upgrade/mocks/ArvoStakingV2.sol:ArvoStakingV2",
            bytes(""),
            opts,
            admin
        );

        address implementationAfter = Upgrades.getImplementationAddress(address(staking));

        assertTrue(implementationAfter != implementationBefore);

        ArvoStakingV2 stakingV2 = ArvoStakingV2(address(staking));

        assertEq(stakingV2.version(), 2);

        // Existing proxy state must survive the implementation upgrade.
        assertEq(address(stakingV2.arvo()), address(arvoToken));
        assertEq(address(stakingV2.usdc()), address(usdcToken));

        assertTrue(stakingV2.hasRole(stakingV2.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(stakingV2.hasRole(stakingV2.PAUSER_ROLE(), admin));
        assertTrue(stakingV2.hasRole(stakingV2.VAULT_MANAGER_ROLE(), admin));
        assertTrue(stakingV2.hasRole(stakingV2.REWARD_MANAGER_ROLE(), admin));
        assertTrue(stakingV2.hasRole(stakingV2.UPGRADER_ROLE(), admin));
    }
}
