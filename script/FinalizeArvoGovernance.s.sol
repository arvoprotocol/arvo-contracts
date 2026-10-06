// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

import { ArvoStaking } from "../src/ArvoStaking.sol";

/// @notice Stage 2 of the Arvo governance handoff.
///
/// This script performs no deployment and grants no roles.
/// It first verifies the already-staged governance topology and then
/// removes every remaining deployment-admin privilege.
///
/// DEFAULT_ADMIN_ROLE is deliberately renounced last.
contract FinalizeArvoGovernance is Script {
    error GovernanceAuditMismatch();
    error ZeroAddress();
    error InvalidContractAddress();
    error InvalidTimelockDelay();
    error StageOneNotVerified();
    error FinalTopologyInvalid();

    uint256 public constant MIN_TIMELOCK_DELAY = 24 hours;

    struct GovernanceConfig {
        address stakingProxy;
        address deploymentAdmin;
        address governanceSafe;
        address emergencyAuthority;
        address timelock;
        uint256 timelockDelay;
    }

    function run() external {
        GovernanceConfig memory config = GovernanceConfig({
            stakingProxy: vm.envAddress("STAKING_PROXY"),
            deploymentAdmin: vm.envAddress("STAKING_ADMIN"),
            governanceSafe: vm.envAddress("GOVERNANCE_SAFE"),
            emergencyAuthority: vm.envAddress("EMERGENCY_AUTHORITY"),
            timelock: vm.envAddress("TIMELOCK_ADDRESS"),
            timelockDelay: vm.envUint("TIMELOCK_DELAY")
        });

        // A full event/state audit is mandatory for the operational entry point.
        // The manifest pins the reviewed chain, code, Safe owners and threshold.
        string[] memory command = new string[](7);
        command[0] = "python3";
        command[1] = "tooling/audit_governance.py";
        command[2] = "--config";
        command[3] = vm.envString("ARVO_GOVERNANCE_MANIFEST");
        command[4] = "--phase";
        command[5] = "staged";
        command[6] = "--ffi";
        // No shell, no signing keys, and the RPC URL is read from the environment.
        (address proxy, address admin, address safe, address emergency,
            address timelock, uint256 delay, uint256 chain) = abi.decode(
                vm.ffi(command), (address,address,address,address,address,uint256,uint256)
            );
        if (proxy != config.stakingProxy || admin != config.deploymentAdmin
            || safe != config.governanceSafe || emergency != config.emergencyAuthority
            || timelock != config.timelock || delay != config.timelockDelay
            || chain != block.chainid) revert GovernanceAuditMismatch();
        finalize(config);
    }

    function finalize(
        GovernanceConfig memory config
    ) public {
        if (!verifyStageOne(config)) {
            revert StageOneNotVerified();
        }

        ArvoStaking staking = ArvoStaking(config.stakingProxy);

        /*
         * Cache role identifiers before broadcasting.
         *
         * This also avoids external role-getter calls consuming one-shot
         * broadcast/prank behaviour in test or operational tooling.
         */
        bytes32 pauserRole = staking.PAUSER_ROLE();
        bytes32 vaultManagerRole = staking.VAULT_MANAGER_ROLE();
        bytes32 rewardManagerRole = staking.REWARD_MANAGER_ROLE();
        bytes32 upgraderRole = staking.UPGRADER_ROLE();
        bytes32 defaultAdminRole = staking.DEFAULT_ADMIN_ROLE();

        vm.startBroadcast(config.deploymentAdmin);

        staking.renounceRole(
            pauserRole,
            config.deploymentAdmin
        );

        staking.renounceRole(
            vaultManagerRole,
            config.deploymentAdmin
        );

        staking.renounceRole(
            rewardManagerRole,
            config.deploymentAdmin
        );

        staking.renounceRole(
            upgraderRole,
            config.deploymentAdmin
        );

        /*
         * Irreversible administrative handoff happens last.
         */
        staking.renounceRole(
            defaultAdminRole,
            config.deploymentAdmin
        );

        vm.stopBroadcast();

        if (!verifyFinalTopology(config)) {
            revert FinalTopologyInvalid();
        }
    }

    function verifyStageOne(
        GovernanceConfig memory config
    ) public view returns (bool) {
        if (!_validConfig(config)) {
            return false;
        }

        ArvoStaking staking = ArvoStaking(config.stakingProxy);

        TimelockController timelock =
            TimelockController(payable(config.timelock));

        if (timelock.getMinDelay() != config.timelockDelay) {
            return false;
        }

        if (
            !timelock.hasRole(
                timelock.DEFAULT_ADMIN_ROLE(),
                config.timelock
            )
        ) {
            return false;
        }

        if (
            !timelock.hasRole(
                timelock.PROPOSER_ROLE(),
                config.governanceSafe
            )
        ) {
            return false;
        }

        if (
            !timelock.hasRole(
                timelock.CANCELLER_ROLE(),
                config.governanceSafe
            )
        ) {
            return false;
        }

        if (
            !timelock.hasRole(
                timelock.EXECUTOR_ROLE(),
                config.governanceSafe
            )
        ) {
            return false;
        }

        if (
            timelock.hasRole(
                timelock.EXECUTOR_ROLE(),
                address(0)
            )
        ) {
            return false;
        }

        if (
            !staking.hasRole(
                staking.DEFAULT_ADMIN_ROLE(),
                config.timelock
            )
        ) {
            return false;
        }

        if (
            !staking.hasRole(
                staking.UPGRADER_ROLE(),
                config.timelock
            )
        ) {
            return false;
        }

        if (
            !staking.hasRole(
                staking.VAULT_MANAGER_ROLE(),
                config.governanceSafe
            )
        ) {
            return false;
        }

        if (
            !staking.hasRole(
                staking.REWARD_MANAGER_ROLE(),
                config.governanceSafe
            )
        ) {
            return false;
        }

        if (
            !staking.hasRole(
                staking.PAUSER_ROLE(),
                config.emergencyAuthority
            )
        ) {
            return false;
        }

        /*
         * Stage 2 may only begin while the deployment admin still holds
         * every original role.
         */
        return _deploymentAdminHasAllRoles(
            staking,
            config.deploymentAdmin
        );
    }

    function verifyFinalTopology(
        GovernanceConfig memory config
    ) public view returns (bool) {
        if (!_validConfig(config)) {
            return false;
        }

        ArvoStaking staking = ArvoStaking(config.stakingProxy);

        TimelockController timelock =
            TimelockController(payable(config.timelock));

        /*
         * Reconfirm the destination governance authorities.
         */
        if (timelock.getMinDelay() != config.timelockDelay) {
            return false;
        }

        if (
            !timelock.hasRole(
                timelock.DEFAULT_ADMIN_ROLE(),
                config.timelock
            )
        ) {
            return false;
        }

        if (
            !timelock.hasRole(
                timelock.PROPOSER_ROLE(),
                config.governanceSafe
            )
        ) {
            return false;
        }

        if (
            !timelock.hasRole(
                timelock.CANCELLER_ROLE(),
                config.governanceSafe
            )
        ) {
            return false;
        }

        if (
            !timelock.hasRole(
                timelock.EXECUTOR_ROLE(),
                config.governanceSafe
            )
        ) {
            return false;
        }

        if (
            timelock.hasRole(
                timelock.EXECUTOR_ROLE(),
                address(0)
            )
        ) {
            return false;
        }

        if (
            !staking.hasRole(
                staking.DEFAULT_ADMIN_ROLE(),
                config.timelock
            )
        ) {
            return false;
        }

        if (
            !staking.hasRole(
                staking.UPGRADER_ROLE(),
                config.timelock
            )
        ) {
            return false;
        }

        if (
            !staking.hasRole(
                staking.VAULT_MANAGER_ROLE(),
                config.governanceSafe
            )
        ) {
            return false;
        }

        if (
            !staking.hasRole(
                staking.REWARD_MANAGER_ROLE(),
                config.governanceSafe
            )
        ) {
            return false;
        }

        if (
            !staking.hasRole(
                staking.PAUSER_ROLE(),
                config.emergencyAuthority
            )
        ) {
            return false;
        }

        /*
         * No residual deployment-wallet privilege is permitted.
         */
        return !_deploymentAdminHasAnyRole(
            staking,
            config.deploymentAdmin
        );
    }

    function _validConfig(
        GovernanceConfig memory config
    ) internal view returns (bool) {
        if (
            config.stakingProxy == address(0)
                || config.deploymentAdmin == address(0)
                || config.governanceSafe == address(0)
                || config.emergencyAuthority == address(0)
                || config.timelock == address(0)
        ) {
            return false;
        }

        if (config.timelockDelay < MIN_TIMELOCK_DELAY) {
            return false;
        }

        if (
            config.stakingProxy.code.length == 0
                || config.timelock.code.length == 0
                || config.governanceSafe.code.length == 0
        ) {
            return false;
        }

        return true;
    }

    function _deploymentAdminHasAllRoles(
        ArvoStaking staking,
        address deploymentAdmin
    ) internal view returns (bool) {
        return staking.hasRole(
            staking.DEFAULT_ADMIN_ROLE(),
            deploymentAdmin
        )
            && staking.hasRole(
                staking.UPGRADER_ROLE(),
                deploymentAdmin
            )
            && staking.hasRole(
                staking.VAULT_MANAGER_ROLE(),
                deploymentAdmin
            )
            && staking.hasRole(
                staking.REWARD_MANAGER_ROLE(),
                deploymentAdmin
            )
            && staking.hasRole(
                staking.PAUSER_ROLE(),
                deploymentAdmin
            );
    }

    function _deploymentAdminHasAnyRole(
        ArvoStaking staking,
        address deploymentAdmin
    ) internal view returns (bool) {
        return staking.hasRole(
            staking.DEFAULT_ADMIN_ROLE(),
            deploymentAdmin
        )
            || staking.hasRole(
                staking.UPGRADER_ROLE(),
                deploymentAdmin
            )
            || staking.hasRole(
                staking.VAULT_MANAGER_ROLE(),
                deploymentAdmin
            )
            || staking.hasRole(
                staking.REWARD_MANAGER_ROLE(),
                deploymentAdmin
            )
            || staking.hasRole(
                staking.PAUSER_ROLE(),
                deploymentAdmin
            );
    }
}
