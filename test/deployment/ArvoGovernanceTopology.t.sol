// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { ArvoStaking } from "../../src/ArvoStaking.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";

contract ArvoGovernanceTopologyTest is Test {
    uint256 internal constant TIMELOCK_DELAY = 48 hours;

    address internal deployer = address(0xD3E10);
    address internal safe = address(0x5AFE);
    address internal outsider = address(0xBAD);

    MockERC20 internal arvo;
    MockERC20 internal usdc;

    ArvoStaking internal staking;
    TimelockController internal timelock;

    function setUp() public {
        arvo = new MockERC20("Arvo", "ARVO", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        ArvoStaking implementation = new ArvoStaking();

        bytes memory initialization =
            abi.encodeCall(ArvoStaking.initialize, (address(arvo), address(usdc), deployer));

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initialization);

        staking = ArvoStaking(address(proxy));

        address[] memory proposers = new address[](1);
        proposers[0] = safe;

        address[] memory executors = new address[](1);
        executors[0] = safe;

        timelock = new TimelockController(TIMELOCK_DELAY, proposers, executors, address(0));

        _handoffGovernance();
    }

    function _handoffGovernance() internal {
        vm.startPrank(deployer);

        staking.grantRole(staking.DEFAULT_ADMIN_ROLE(), address(timelock));

        staking.grantRole(staking.UPGRADER_ROLE(), address(timelock));

        staking.grantRole(staking.VAULT_MANAGER_ROLE(), safe);

        staking.grantRole(staking.REWARD_MANAGER_ROLE(), safe);

        staking.grantRole(staking.PAUSER_ROLE(), safe);

        staking.renounceRole(staking.PAUSER_ROLE(), deployer);

        staking.renounceRole(staking.VAULT_MANAGER_ROLE(), deployer);

        staking.renounceRole(staking.REWARD_MANAGER_ROLE(), deployer);

        staking.renounceRole(staking.UPGRADER_ROLE(), deployer);

        staking.renounceRole(staking.DEFAULT_ADMIN_ROLE(), deployer);

        vm.stopPrank();
    }

    function testFinalRoleTopologyIsCorrect() public view {
        assertTrue(staking.hasRole(staking.DEFAULT_ADMIN_ROLE(), address(timelock)));

        assertTrue(staking.hasRole(staking.UPGRADER_ROLE(), address(timelock)));

        assertTrue(staking.hasRole(staking.VAULT_MANAGER_ROLE(), safe));

        assertTrue(staking.hasRole(staking.REWARD_MANAGER_ROLE(), safe));

        assertTrue(staking.hasRole(staking.PAUSER_ROLE(), safe));
    }

    function testDeploymentWalletHasNoRemainingPrivileges() public view {
        assertFalse(staking.hasRole(staking.DEFAULT_ADMIN_ROLE(), deployer));

        assertFalse(staking.hasRole(staking.UPGRADER_ROLE(), deployer));

        assertFalse(staking.hasRole(staking.VAULT_MANAGER_ROLE(), deployer));

        assertFalse(staking.hasRole(staking.REWARD_MANAGER_ROLE(), deployer));

        assertFalse(staking.hasRole(staking.PAUSER_ROLE(), deployer));
    }

    function testSafeCanPauseImmediately() public {
        vm.prank(safe);
        staking.pause();

        assertTrue(staking.paused());
    }

    function testSafeCannotUnpauseDirectly() public {
        vm.prank(safe);
        staking.pause();

        vm.prank(safe);
        vm.expectRevert();

        staking.unpause();
    }

    function testDeployerCannotPauseAfterHandoff() public {
        vm.prank(deployer);
        vm.expectRevert();

        staking.pause();
    }

    function testOutsiderCannotPause() public {
        vm.prank(outsider);
        vm.expectRevert();

        staking.pause();
    }

    function testTimelockCanUnpauseAfterDelay() public {
        vm.prank(safe);
        staking.pause();

        bytes memory data = abi.encodeCall(ArvoStaking.unpause, ());

        bytes32 predecessor = bytes32(0);
        bytes32 salt = keccak256("ARVO_UNPAUSE_TEST");

        vm.prank(safe);
        timelock.schedule(address(staking), 0, data, predecessor, salt, TIMELOCK_DELAY);

        vm.warp(vm.getBlockTimestamp() + TIMELOCK_DELAY);

        vm.prank(safe);
        timelock.execute(address(staking), 0, data, predecessor, salt);

        assertFalse(staking.paused());
    }

    function testTimelockCannotExecuteBeforeDelay() public {
        vm.prank(safe);
        staking.pause();

        bytes memory data = abi.encodeCall(ArvoStaking.unpause, ());

        bytes32 predecessor = bytes32(0);
        bytes32 salt = keccak256("ARVO_EARLY_EXECUTION_TEST");

        vm.prank(safe);
        timelock.schedule(address(staking), 0, data, predecessor, salt, TIMELOCK_DELAY);

        vm.prank(safe);
        vm.expectRevert();

        timelock.execute(address(staking), 0, data, predecessor, salt);

        assertTrue(staking.paused());
    }

    function testSafeCanPerformVaultManagement() public {
        uint64 opensAt = uint64(vm.getBlockTimestamp() + 1 days);

        vm.prank(safe);

        uint32 poolId = staking.createStandardPool(
            ArvoStakingTypes.VaultKind.BUILD,
            opensAt,
            0,
            10000000 ether,
            100_000e6,
            true,
            true,
            true,
            true,
            true
        );

        assertTrue(staking.poolExists(poolId));
    }
}

import { ArvoStakingTypes } from "../../src/ArvoStakingTypes.sol";
