// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { ArvoStaking } from "../../src/ArvoStaking.sol";
import { ArvoStakingTypes } from "../../src/ArvoStakingTypes.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";

contract ArvoStakingGovernanceTest is Test {
    ArvoStaking internal staking;
    MockERC20 internal arvo;
    MockERC20 internal usdc;

    address internal admin = address(0xA11CE);
    address internal pauser = address(0xBEEF);
    address internal attacker = address(0xBAD);

    function setUp() public {
        arvo = new MockERC20("Arvo", "ARVO", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        ArvoStaking implementation = new ArvoStaking();

        bytes memory initialization =
            abi.encodeCall(ArvoStaking.initialize, (address(arvo), address(usdc), admin));

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initialization);

        staking = ArvoStaking(address(proxy));

        bytes32 pauserRole = staking.PAUSER_ROLE();

        vm.prank(admin);
        staking.grantRole(pauserRole, pauser);
    }

    function testDedicatedPauserCanPause() public {
        vm.prank(pauser);
        staking.pause();

        assertTrue(staking.paused());
    }

    function testDedicatedPauserCannotUnpause() public {
        vm.prank(pauser);
        staking.pause();

        vm.prank(pauser);
        vm.expectRevert();
        staking.unpause();

        assertTrue(staking.paused());
    }

    function testDefaultAdminCanUnpause() public {
        vm.prank(pauser);
        staking.pause();

        vm.prank(admin);
        staking.unpause();

        assertFalse(staking.paused());
    }

    function testUnauthorizedWalletCannotPause() public {
        vm.prank(attacker);
        vm.expectRevert();
        staking.pause();

        assertFalse(staking.paused());
    }

    function testUnauthorizedWalletCannotUnpause() public {
        vm.prank(pauser);
        staking.pause();

        vm.prank(attacker);
        vm.expectRevert();
        staking.unpause();

        assertTrue(staking.paused());
    }

    function testDefaultAdminControlsOperationalRoleAdministration() public {
        bytes32 vaultManagerRole = staking.VAULT_MANAGER_ROLE();

        vm.prank(admin);
        staking.grantRole(vaultManagerRole, pauser);

        assertTrue(staking.hasRole(vaultManagerRole, pauser));

        vm.prank(admin);
        staking.revokeRole(vaultManagerRole, pauser);

        assertFalse(staking.hasRole(vaultManagerRole, pauser));
    }

    function testNonAdminCannotGrantOperationalRole() public {
        bytes32 vaultManagerRole = staking.VAULT_MANAGER_ROLE();

        vm.expectRevert();
        vm.prank(attacker);
        staking.grantRole(vaultManagerRole, attacker);

        assertFalse(staking.hasRole(vaultManagerRole, attacker));
    }

    function testInitialAdminHoldsAllGovernanceRoles() public view {
        assertTrue(staking.hasRole(staking.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(staking.hasRole(staking.PAUSER_ROLE(), admin));
        assertTrue(staking.hasRole(staking.VAULT_MANAGER_ROLE(), admin));
        assertTrue(staking.hasRole(staking.REWARD_MANAGER_ROLE(), admin));
        assertTrue(staking.hasRole(staking.UPGRADER_ROLE(), admin));
    }

    function testPauserCannotCreatePool() public {
        vm.expectRevert();
        vm.prank(pauser);
        staking.createStandardPool(
            ArvoStakingTypes.VaultKind.BUILD,
            uint64(vm.getBlockTimestamp() + 1 days),
            0,
            100000000 ether,
            1_000_000e6,
            true,
            true,
            false,
            true,
            true
        );
    }

    function testPauserCannotWithdrawSurplus() public {
        vm.expectRevert();
        vm.prank(pauser);
        staking.withdrawArvoSurplus(pauser, 100 ether);
    }

    function testVaultManagerCannotWithdrawSurplus() public {
        address vaultManager = address(0xCAFE);
        bytes32 vaultManagerRole = staking.VAULT_MANAGER_ROLE();

        vm.prank(admin);
        staking.grantRole(vaultManagerRole, vaultManager);

        vm.expectRevert();
        vm.prank(vaultManager);
        staking.withdrawArvoSurplus(vaultManager, 100 ether);
    }

    function testRewardManagerCannotCreatePool() public {
        address rewardManager = address(0xD00D);
        bytes32 rewardManagerRole = staking.REWARD_MANAGER_ROLE();

        vm.prank(admin);
        staking.grantRole(rewardManagerRole, rewardManager);

        vm.expectRevert();
        vm.prank(rewardManager);
        staking.createStandardPool(
            ArvoStakingTypes.VaultKind.BUILD,
            uint64(vm.getBlockTimestamp() + 1 days),
            0,
            100000000 ether,
            1_000_000e6,
            true,
            true,
            false,
            true,
            true
        );
    }

    function testVaultManagerCannotPause() public {
        address vaultManager = address(0xCAFE);
        bytes32 vaultManagerRole = staking.VAULT_MANAGER_ROLE();

        vm.prank(admin);
        staking.grantRole(vaultManagerRole, vaultManager);

        vm.expectRevert();
        vm.prank(vaultManager);
        staking.pause();

        assertFalse(staking.paused());
    }

    function testRewardManagerCannotPause() public {
        address rewardManager = address(0xD00D);
        bytes32 rewardManagerRole = staking.REWARD_MANAGER_ROLE();

        vm.prank(admin);
        staking.grantRole(rewardManagerRole, rewardManager);

        vm.expectRevert();
        vm.prank(rewardManager);
        staking.pause();

        assertFalse(staking.paused());
    }

    function testOperationalRolesCannotGrantThemselvesOtherRoles() public {
        address vaultManager = address(0xCAFE);
        bytes32 vaultManagerRole = staking.VAULT_MANAGER_ROLE();
        bytes32 rewardManagerRole = staking.REWARD_MANAGER_ROLE();

        vm.prank(admin);
        staking.grantRole(vaultManagerRole, vaultManager);

        vm.expectRevert();
        vm.prank(vaultManager);
        staking.grantRole(rewardManagerRole, vaultManager);

        assertFalse(staking.hasRole(rewardManagerRole, vaultManager));
    }

    function testRevokedPauserImmediatelyLosesPauseAuthority() public {
        bytes32 pauserRole = staking.PAUSER_ROLE();

        vm.prank(admin);
        staking.revokeRole(pauserRole, pauser);

        assertFalse(staking.hasRole(pauserRole, pauser));

        vm.expectRevert();
        vm.prank(pauser);
        staking.pause();

        assertFalse(staking.paused());
    }

    function testGovernanceCanMigrateAwayFromDeploymentAdmin() public {
        address governance = address(0x515AFE);

        bytes32 defaultAdminRole = staking.DEFAULT_ADMIN_ROLE();
        bytes32 pauserRole = staking.PAUSER_ROLE();
        bytes32 vaultManagerRole = staking.VAULT_MANAGER_ROLE();
        bytes32 rewardManagerRole = staking.REWARD_MANAGER_ROLE();
        bytes32 upgraderRole = staking.UPGRADER_ROLE();

        // Deployment admin installs the new governance authority.
        vm.startPrank(admin);
        staking.grantRole(defaultAdminRole, governance);
        staking.grantRole(pauserRole, governance);
        staking.grantRole(vaultManagerRole, governance);
        staking.grantRole(rewardManagerRole, governance);
        staking.grantRole(upgraderRole, governance);
        vm.stopPrank();

        assertTrue(staking.hasRole(defaultAdminRole, governance));
        assertTrue(staking.hasRole(pauserRole, governance));
        assertTrue(staking.hasRole(vaultManagerRole, governance));
        assertTrue(staking.hasRole(rewardManagerRole, governance));
        assertTrue(staking.hasRole(upgraderRole, governance));

        // New governance removes the deployment wallet's operational powers.
        vm.startPrank(governance);
        staking.revokeRole(pauserRole, admin);
        staking.revokeRole(vaultManagerRole, admin);
        staking.revokeRole(rewardManagerRole, admin);
        staking.revokeRole(upgraderRole, admin);
        vm.stopPrank();

        // Deployment wallet removes its own final admin authority.
        vm.prank(admin);
        staking.renounceRole(defaultAdminRole, admin);

        assertFalse(staking.hasRole(defaultAdminRole, admin));
        assertFalse(staking.hasRole(pauserRole, admin));
        assertFalse(staking.hasRole(vaultManagerRole, admin));
        assertFalse(staking.hasRole(rewardManagerRole, admin));
        assertFalse(staking.hasRole(upgraderRole, admin));

        // New governance retains all intended authority.
        assertTrue(staking.hasRole(defaultAdminRole, governance));
        assertTrue(staking.hasRole(pauserRole, governance));
        assertTrue(staking.hasRole(vaultManagerRole, governance));
        assertTrue(staking.hasRole(rewardManagerRole, governance));
        assertTrue(staking.hasRole(upgraderRole, governance));

        // Former deployment admin cannot grant itself power again.
        vm.expectRevert();
        vm.prank(admin);
        staking.grantRole(vaultManagerRole, admin);

        assertFalse(staking.hasRole(vaultManagerRole, admin));

        // New governance still administers roles.
        vm.prank(governance);
        staking.grantRole(vaultManagerRole, pauser);

        assertTrue(staking.hasRole(vaultManagerRole, pauser));
    }
}
