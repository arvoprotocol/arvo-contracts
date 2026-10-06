// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { StageArvoGovernance } from "../../script/StageArvoGovernance.s.sol";
import { ArvoStaking } from "../../src/ArvoStaking.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";

contract StageArvoGovernanceTest is Test {
    uint256 internal constant DELAY = 48 hours;

    address internal deploymentAdmin = address(0xA11CE);
    address internal safe = address(0x5AFE);
    address internal emergency = address(0xE911);
    address internal outsider = address(0xBAD);

    ArvoStaking internal staking;
    StageArvoGovernance internal stage;

    function setUp() public {
        vm.etch(safe, hex"00"); // Contract fixture; real Safe is checked by the RPC audit.
        MockERC20 arvo =
            new MockERC20("Arvo", "ARVO", 18);

        MockERC20 usdc =
            new MockERC20("USD Coin", "USDC", 6);

        ArvoStaking implementation = new ArvoStaking();

        bytes memory initialization = abi.encodeCall(
            ArvoStaking.initialize,
            (address(arvo), address(usdc), deploymentAdmin)
        );

        ERC1967Proxy proxy =
            new ERC1967Proxy(address(implementation), initialization);

        staking = ArvoStaking(address(proxy));
        stage = new StageArvoGovernance();
    }

    function testRejectsGovernanceEOA() public {
        vm.etch(safe, "");
        vm.expectRevert(StageArvoGovernance.InvalidContractAddress.selector);
        stage.stage(_config());
    }

    function _config()
        internal
        view
        returns (StageArvoGovernance.GovernanceConfig memory)
    {
        return StageArvoGovernance.GovernanceConfig({
            stakingProxy: address(staking),
            deploymentAdmin: deploymentAdmin,
            governanceSafe: safe,
            emergencyAuthority: emergency,
            timelockDelay: DELAY
        });
    }

    function _deployTimelock(
        uint256 delay,
        address proposer,
        address executor
    ) internal returns (TimelockController timelock) {
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;

        address[] memory executors = new address[](1);
        executors[0] = executor;

        timelock = new TimelockController(
            delay,
            proposers,
            executors,
            address(0)
        );
    }

    function _grantStageOneRoles(
        TimelockController timelock
    ) internal {
        vm.startPrank(deploymentAdmin);

        staking.grantRole(
            staking.DEFAULT_ADMIN_ROLE(),
            address(timelock)
        );

        staking.grantRole(
            staking.UPGRADER_ROLE(),
            address(timelock)
        );

        staking.grantRole(
            staking.VAULT_MANAGER_ROLE(),
            safe
        );

        staking.grantRole(
            staking.REWARD_MANAGER_ROLE(),
            safe
        );

        staking.grantRole(
            staking.PAUSER_ROLE(),
            emergency
        );

        vm.stopPrank();
    }

    function testStageExecutesCompleteStageOneHandoff() public {
        StageArvoGovernance.GovernanceConfig memory config =
            _config();

        /*
         * Exercise the actual Stage-1 implementation, including its
         * deployment-admin-bound broadcast.
         */
        address timelockAddress = stage.stage(config);

        assertGt(timelockAddress.code.length, 0);

        assertTrue(
            stage.verifyStageOne(
                config,
                timelockAddress
            )
        );

        TimelockController deployedTimelock =
            TimelockController(payable(timelockAddress));

        assertEq(
            deployedTimelock.getMinDelay(),
            DELAY
        );

        assertTrue(
            deployedTimelock.hasRole(
                deployedTimelock.DEFAULT_ADMIN_ROLE(),
                timelockAddress
            )
        );

        assertTrue(
            deployedTimelock.hasRole(
                deployedTimelock.PROPOSER_ROLE(),
                safe
            )
        );

        assertTrue(
            deployedTimelock.hasRole(
                deployedTimelock.CANCELLER_ROLE(),
                safe
            )
        );

        assertTrue(
            deployedTimelock.hasRole(
                deployedTimelock.EXECUTOR_ROLE(),
                safe
            )
        );

        assertFalse(
            deployedTimelock.hasRole(
                deployedTimelock.EXECUTOR_ROLE(),
                address(0)
            )
        );

        /*
         * Destination staking authorities are established.
         */
        assertTrue(
            staking.hasRole(
                staking.DEFAULT_ADMIN_ROLE(),
                timelockAddress
            )
        );

        assertTrue(
            staking.hasRole(
                staking.UPGRADER_ROLE(),
                timelockAddress
            )
        );

        assertTrue(
            staking.hasRole(
                staking.VAULT_MANAGER_ROLE(),
                safe
            )
        );

        assertTrue(
            staking.hasRole(
                staking.REWARD_MANAGER_ROLE(),
                safe
            )
        );

        assertTrue(
            staking.hasRole(
                staking.PAUSER_ROLE(),
                emergency
            )
        );

        /*
         * Stage 1 must leave the deployment admin fully recoverable.
         */
        assertTrue(
            staking.hasRole(
                staking.DEFAULT_ADMIN_ROLE(),
                deploymentAdmin
            )
        );

        assertTrue(
            staking.hasRole(
                staking.UPGRADER_ROLE(),
                deploymentAdmin
            )
        );

        assertTrue(
            staking.hasRole(
                staking.VAULT_MANAGER_ROLE(),
                deploymentAdmin
            )
        );

        assertTrue(
            staking.hasRole(
                staking.REWARD_MANAGER_ROLE(),
                deploymentAdmin
            )
        );

        assertTrue(
            staking.hasRole(
                staking.PAUSER_ROLE(),
                deploymentAdmin
            )
        );
    }


    function testStageOneAcceptsCorrectTopology() public {
        TimelockController timelock =
            _deployTimelock(DELAY, safe, safe);

        _grantStageOneRoles(timelock);

        assertTrue(
            stage.verifyStageOne(
                _config(),
                address(timelock)
            )
        );
    }

    function testStageOnePreservesEveryDeploymentAdminRole() public {
        TimelockController timelock =
            _deployTimelock(DELAY, safe, safe);

        _grantStageOneRoles(timelock);

        assertTrue(
            staking.hasRole(
                staking.DEFAULT_ADMIN_ROLE(),
                deploymentAdmin
            )
        );

        assertTrue(
            staking.hasRole(
                staking.UPGRADER_ROLE(),
                deploymentAdmin
            )
        );

        assertTrue(
            staking.hasRole(
                staking.VAULT_MANAGER_ROLE(),
                deploymentAdmin
            )
        );

        assertTrue(
            staking.hasRole(
                staking.REWARD_MANAGER_ROLE(),
                deploymentAdmin
            )
        );

        assertTrue(
            staking.hasRole(
                staking.PAUSER_ROLE(),
                deploymentAdmin
            )
        );
    }

    function testRejectsWrongTimelockDelay() public {
        TimelockController timelock =
            _deployTimelock(DELAY + 1 hours, safe, safe);

        _grantStageOneRoles(timelock);

        assertFalse(
            stage.verifyStageOne(
                _config(),
                address(timelock)
            )
        );
    }

    function testRejectsWrongProposer() public {
        TimelockController timelock =
            _deployTimelock(DELAY, outsider, safe);

        _grantStageOneRoles(timelock);

        assertFalse(
            stage.verifyStageOne(
                _config(),
                address(timelock)
            )
        );
    }

    function testRejectsWrongExecutor() public {
        TimelockController timelock =
            _deployTimelock(DELAY, safe, outsider);

        _grantStageOneRoles(timelock);

        assertFalse(
            stage.verifyStageOne(
                _config(),
                address(timelock)
            )
        );
    }

    function testRejectsOpenExecutor() public {
        TimelockController timelock =
            _deployTimelock(DELAY, safe, address(0));

        _grantStageOneRoles(timelock);

        assertFalse(
            stage.verifyStageOne(
                _config(),
                address(timelock)
            )
        );
    }

    function testRejectsMissingStakingDestinationRole() public {
        TimelockController timelock =
            _deployTimelock(DELAY, safe, safe);

        vm.startPrank(deploymentAdmin);

        staking.grantRole(
            staking.DEFAULT_ADMIN_ROLE(),
            address(timelock)
        );

        staking.grantRole(
            staking.UPGRADER_ROLE(),
            address(timelock)
        );

        staking.grantRole(
            staking.VAULT_MANAGER_ROLE(),
            safe
        );

        staking.grantRole(
            staking.PAUSER_ROLE(),
            emergency
        );

        vm.stopPrank();

        assertFalse(
            stage.verifyStageOne(
                _config(),
                address(timelock)
            )
        );
    }

    function testRejectsPrematureAdminRenunciation() public {
        TimelockController timelock =
            _deployTimelock(DELAY, safe, safe);

        _grantStageOneRoles(timelock);

        bytes32 upgraderRole = staking.UPGRADER_ROLE();

        vm.prank(deploymentAdmin);
        staking.renounceRole(
            upgraderRole,
            deploymentAdmin
        );

        assertFalse(
            stage.verifyStageOne(
                _config(),
                address(timelock)
            )
        );
    }
}
