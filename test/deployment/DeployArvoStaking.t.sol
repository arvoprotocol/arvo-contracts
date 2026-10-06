// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

import { DeployArvoStaking } from "../../script/DeployArvoStaking.s.sol";
import { ArvoStaking } from "../../src/ArvoStaking.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";

contract DeployArvoStakingTest is Test {
    MockERC20 internal arvo;
    MockERC20 internal usdc;

    DeployArvoStaking internal deployer;

    address internal admin = address(0xA11CE);

    function setUp() public {
        arvo = new MockERC20("Arvo", "ARVO", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        deployer = new DeployArvoStaking();
    }

    function testDeployCreatesInitializedUUPSProxy() public {
        (address proxy, address implementation) =
            deployer.deploy(address(arvo), address(usdc), admin);

        ArvoStaking staking = ArvoStaking(proxy);

        assertTrue(proxy != address(0));
        assertTrue(implementation != address(0));
        assertTrue(proxy != implementation);

        assertGt(proxy.code.length, 0);
        assertGt(implementation.code.length, 0);

        assertEq(Upgrades.getImplementationAddress(proxy), implementation);

        assertEq(address(staking.arvo()), address(arvo));
        assertEq(address(staking.usdc()), address(usdc));

        assertEq(staking.nextPositionId(), 1);
        assertEq(staking.nextVaultId(), 0);

        assertTrue(staking.hasRole(staking.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(staking.hasRole(staking.PAUSER_ROLE(), admin));
        assertTrue(staking.hasRole(staking.VAULT_MANAGER_ROLE(), admin));
        assertTrue(staking.hasRole(staking.REWARD_MANAGER_ROLE(), admin));
        assertTrue(staking.hasRole(staking.UPGRADER_ROLE(), admin));
    }

    function testImplementationRemainsInitializationLocked() public {
        (, address implementation) = deployer.deploy(address(arvo), address(usdc), admin);

        vm.expectRevert();

        ArvoStaking(implementation).initialize(address(arvo), address(usdc), admin);
    }

    function testProxyCannotBeInitializedTwice() public {
        (address proxy,) = deployer.deploy(address(arvo), address(usdc), admin);

        vm.expectRevert();

        ArvoStaking(proxy).initialize(address(arvo), address(usdc), admin);
    }

    function testRejectsZeroArvoAddress() public {
        vm.expectRevert(DeployArvoStaking.ZeroAddress.selector);

        deployer.deploy(address(0), address(usdc), admin);
    }

    function testRejectsZeroUsdcAddress() public {
        vm.expectRevert(DeployArvoStaking.ZeroAddress.selector);

        deployer.deploy(address(arvo), address(0), admin);
    }

    function testRejectsZeroAdminAddress() public {
        vm.expectRevert(DeployArvoStaking.ZeroAddress.selector);

        deployer.deploy(address(arvo), address(usdc), address(0));
    }
}
