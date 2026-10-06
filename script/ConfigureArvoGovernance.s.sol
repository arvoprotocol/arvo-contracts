// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

import { ArvoStaking } from "../src/ArvoStaking.sol";

contract ConfigureArvoGovernance is Script {
    error ZeroAddress();
    error InvalidTimelockDelay();
    error DeploymentAdminMissingRole();
    error GovernanceHandoffIncomplete();
    error DeprecatedUseStagedGovernance();

    uint256 public constant MIN_TIMELOCK_DELAY = 24 hours;

    struct GovernanceConfig {
        address stakingProxy;
        address deploymentAdmin;
        address governanceSafe;
        address emergencyAuthority;
        uint256 timelockDelay;
    }

    /// @dev Deprecated in Phase 5E.
    /// Use StageArvoGovernance followed by FinalizeArvoGovernance.
    function run() external pure returns (address) {
        revert DeprecatedUseStagedGovernance();
    }

    function verifyTopology(GovernanceConfig memory config, address timelockAddress)
        external
        view
        returns (bool)
    {
        _validateConfig(config);

        if (timelockAddress == address(0)) {
            revert ZeroAddress();
        }

        ArvoStaking staking = ArvoStaking(config.stakingProxy);

        return _topologyCorrect(staking, config, timelockAddress);
    }

    function _validateConfig(GovernanceConfig memory config) internal pure {
        if (
            config.stakingProxy == address(0) || config.deploymentAdmin == address(0)
                || config.governanceSafe == address(0) || config.emergencyAuthority == address(0)
        ) {
            revert ZeroAddress();
        }

        if (config.timelockDelay < MIN_TIMELOCK_DELAY) {
            revert InvalidTimelockDelay();
        }
    }

    function _requireDeploymentAdmin(ArvoStaking staking, address deploymentAdmin) internal view {
        if (
            !staking.hasRole(staking.DEFAULT_ADMIN_ROLE(), deploymentAdmin)
                || !staking.hasRole(staking.PAUSER_ROLE(), deploymentAdmin)
                || !staking.hasRole(staking.VAULT_MANAGER_ROLE(), deploymentAdmin)
                || !staking.hasRole(staking.REWARD_MANAGER_ROLE(), deploymentAdmin)
                || !staking.hasRole(staking.UPGRADER_ROLE(), deploymentAdmin)
        ) {
            revert DeploymentAdminMissingRole();
        }
    }

    function _requireFinalTopology(
        ArvoStaking staking,
        GovernanceConfig memory config,
        address timelockAddress
    ) internal view {
        if (!_topologyCorrect(staking, config, timelockAddress)) {
            revert GovernanceHandoffIncomplete();
        }
    }

    function _topologyCorrect(
        ArvoStaking staking,
        GovernanceConfig memory config,
        address timelockAddress
    ) internal view returns (bool) {
        return staking.hasRole(staking.DEFAULT_ADMIN_ROLE(), timelockAddress)
            && staking.hasRole(staking.UPGRADER_ROLE(), timelockAddress)
            && staking.hasRole(staking.VAULT_MANAGER_ROLE(), config.governanceSafe)
            && staking.hasRole(staking.REWARD_MANAGER_ROLE(), config.governanceSafe)
            && staking.hasRole(staking.PAUSER_ROLE(), config.emergencyAuthority)
            && !staking.hasRole(staking.DEFAULT_ADMIN_ROLE(), config.deploymentAdmin)
            && !staking.hasRole(staking.UPGRADER_ROLE(), config.deploymentAdmin)
            && !staking.hasRole(staking.VAULT_MANAGER_ROLE(), config.deploymentAdmin)
            && !staking.hasRole(staking.REWARD_MANAGER_ROLE(), config.deploymentAdmin)
            && !staking.hasRole(staking.PAUSER_ROLE(), config.deploymentAdmin);
    }
}
