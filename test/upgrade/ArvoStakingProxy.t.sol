// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";
import { Options } from "openzeppelin-foundry-upgrades/Options.sol";

import { ArvoStaking } from "../../src/ArvoStaking.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";

contract ArvoStakingProxyTest is Test {
    MockERC20 internal arvoToken;
    MockERC20 internal usdcToken;

    ArvoStaking internal staking;

    address internal admin = address(0xA11CE);

    function setUp() public {
        arvoToken = new MockERC20("ARVO", "ARVO", 18);
        usdcToken = new MockERC20("USD Coin", "USDC", 6);

        bytes memory initializerData = abi.encodeCall(
            ArvoStaking.initialize, (address(arvoToken), address(usdcToken), admin)
        );

        Options memory opts;
        opts.unsafeAllow = "constructor";

        address proxy =
            Upgrades.deployUUPSProxy("ArvoStaking.sol:ArvoStaking", initializerData, opts);

        staking = ArvoStaking(proxy);
    }

    function testProxyDeploysAndInitializes() public view {
        assertEq(address(staking.arvo()), address(arvoToken));
        assertEq(address(staking.usdc()), address(usdcToken));

        assertTrue(staking.hasRole(staking.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(staking.hasRole(staking.PAUSER_ROLE(), admin));
        assertTrue(staking.hasRole(staking.VAULT_MANAGER_ROLE(), admin));
        assertTrue(staking.hasRole(staking.REWARD_MANAGER_ROLE(), admin));
        assertTrue(staking.hasRole(staking.UPGRADER_ROLE(), admin));
    }

    function testProxyHasImplementation() public view {
        address implementation = Upgrades.getImplementationAddress(address(staking));

        assertTrue(implementation != address(0));
        assertTrue(implementation != address(staking));
        assertGt(implementation.code.length, 0);
    }

    function testProxyCannotBeInitializedTwice() public {
        vm.expectRevert();

        staking.initialize(address(arvoToken), address(usdcToken), admin);
    }

    function testImplementationCannotBeInitializedDirectly() public {
        address implementation = Upgrades.getImplementationAddress(address(staking));

        vm.expectRevert();

        ArvoStaking(implementation).initialize(address(arvoToken), address(usdcToken), admin);
    }
}
