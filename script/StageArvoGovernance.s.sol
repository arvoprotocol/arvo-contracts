// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

import { ArvoStaking } from "../src/ArvoStaking.sol";

/// @notice Stage 1 of the Arvo governance handoff.
///
/// Deploys and verifies the destination governance topology WITHOUT
/// renouncing any deployment-admin privileges.
///
/// Deployment-admin renunciation must only happen in a separate Stage 2
/// transaction after this topology has been independently verified.
contract StageArvoGovernance is Script {
    error ZeroAddress();
    error InvalidTimelockDelay();
    error InvalidContractAddress();
    error DeploymentAdminMissingRole();
    error StageOneVerificationFailed();

    uint256 public constant MIN_TIMELOCK_DELAY = 24 hours;

    struct GovernanceConfig {
        address stakingProxy;
        address deploymentAdmin;
        address governanceSafe;
        address emergencyAuthority;
        uint256 timelockDelay;
    }

    function run() external returns (address timelockAddress) {
        GovernanceConfig memory config = GovernanceConfig({
            stakingProxy: vm.envAddress("STAKING_PROXY"),
            deploymentAdmin: vm.envAddress("STAKING_ADMIN"),
            governanceSafe: vm.envAddress("GOVERNANCE_SAFE"),
            emergencyAuthority: vm.envAddress("EMERGENCY_AUTHORITY"),
            timelockDelay: vm.envUint("TIMELOCK_DELAY")
        });

        return stage(config);
    }

    function stage(
        GovernanceConfig memory config
    ) public returns (address timelockAddress) {
        _validateConfig(config);

        ArvoStaking staking = ArvoStaking(config.stakingProxy);

        _requireDeploymentAdmin(staking, config.deploymentAdmin);

        address[] memory proposers = new address[](1);
        proposers[0] = config.governanceSafe;

        address[] memory executors = new address[](1);
        executors[0] = config.governanceSafe;

        vm.startBroadcast(config.deploymentAdmin);

        TimelockController timelock =
            new TimelockController(
                config.timelockDelay,
                proposers,
                executors,
                address(0)
            );

        timelockAddress = address(timelock);

        staking.grantRole(
            staking.DEFAULT_ADMIN_ROLE(),
            timelockAddress
        );

        staking.grantRole(
            staking.UPGRADER_ROLE(),
            timelockAddress
        );

        staking.grantRole(
            staking.VAULT_MANAGER_ROLE(),
            config.governanceSafe
        );

        staking.grantRole(
            staking.REWARD_MANAGER_ROLE(),
            config.governanceSafe
        );

        staking.grantRole(
            staking.PAUSER_ROLE(),
            config.emergencyAuthority
        );

        vm.stopBroadcast();

        if (!verifyStageOne(config, timelockAddress)) {
            revert StageOneVerificationFailed();
        }
    }

    function verifyStageOne(
        GovernanceConfig memory config,
        address timelockAddress
    ) public view returns (bool) {
        _validateConfig(config);

        if (timelockAddress == address(0)) {
            return false;
        }

        if (timelockAddress.code.length == 0) {
            return false;
        }

        ArvoStaking staking = ArvoStaking(config.stakingProxy);
        TimelockController timelock =
            TimelockController(payable(timelockAddress));

        /*
         * Verify the actual Timelock configuration, not merely the roles
         * assigned to the staking proxy.
         */
        if (timelock.getMinDelay() != config.timelockDelay) {
            return false;
        }

        if (
            !timelock.hasRole(
                timelock.DEFAULT_ADMIN_ROLE(),
                timelockAddress
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

        /*
         * address(0) as executor would make execution permissionless.
         */
        if (
            timelock.hasRole(
                timelock.EXECUTOR_ROLE(),
                address(0)
            )
        ) {
            return false;
        }

        /*
         * Destination staking roles.
         */
        if (
            !staking.hasRole(
                staking.DEFAULT_ADMIN_ROLE(),
                timelockAddress
            )
        ) {
            return false;
        }

        if (
            !staking.hasRole(
                staking.UPGRADER_ROLE(),
                timelockAddress
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
         * CRITICAL STAGE-1 PROPERTY:
         *
         * The deployment admin must still retain every original role.
         * Nothing irreversible happens until Stage 2.
         */
        if (
            !staking.hasRole(
                staking.DEFAULT_ADMIN_ROLE(),
                config.deploymentAdmin
            )
        ) {
            return false;
        }

        if (
            !staking.hasRole(
                staking.UPGRADER_ROLE(),
                config.deploymentAdmin
            )
        ) {
            return false;
        }

        if (
            !staking.hasRole(
                staking.VAULT_MANAGER_ROLE(),
                config.deploymentAdmin
            )
        ) {
            return false;
        }

        if (
            !staking.hasRole(
                staking.REWARD_MANAGER_ROLE(),
                config.deploymentAdmin
            )
        ) {
            return false;
        }

        if (
            !staking.hasRole(
                staking.PAUSER_ROLE(),
                config.deploymentAdmin
            )
        ) {
            return false;
        }

        return true;
    }

    function _validateConfig(
        GovernanceConfig memory config
    ) internal view {
        if (
            config.stakingProxy == address(0)
                || config.deploymentAdmin == address(0)
                || config.governanceSafe == address(0)
                || config.emergencyAuthority == address(0)
        ) {
            revert ZeroAddress();
        }

        if (config.timelockDelay < MIN_TIMELOCK_DELAY) {
            revert InvalidTimelockDelay();
        }

        if (config.stakingProxy.code.length == 0 || config.governanceSafe.code.length == 0) {
            revert InvalidContractAddress();
        }
    }

    function _requireDeploymentAdmin(
        ArvoStaking staking,
        address deploymentAdmin
    ) internal view {
        if (
            !staking.hasRole(
                staking.DEFAULT_ADMIN_ROLE(),
                deploymentAdmin
            )
                || !staking.hasRole(
                    staking.PAUSER_ROLE(),
                    deploymentAdmin
                )
                || !staking.hasRole(
                    staking.VAULT_MANAGER_ROLE(),
                    deploymentAdmin
                )
                || !staking.hasRole(
                    staking.REWARD_MANAGER_ROLE(),
                    deploymentAdmin
                )
                || !staking.hasRole(
                    staking.UPGRADER_ROLE(),
                    deploymentAdmin
                )
        ) {
            revert DeploymentAdminMissingRole();
        }
    }
}
