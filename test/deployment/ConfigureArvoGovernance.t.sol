// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { ConfigureArvoGovernance } from "../../script/ConfigureArvoGovernance.s.sol";
import { ArvoStaking } from "../../src/ArvoStaking.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";

contract ConfigureArvoGovernanceTest is Test {
    uint256 internal constant DELAY = 48 hours;

    address internal deploymentAdmin = address(0xA11CE);
    address internal safe = address(0x5AFE);
    address internal emergency = address(0xE911);

    ArvoStaking internal staking;
    ConfigureArvoGovernance internal configurator;
    TimelockController internal timelock;

    function setUp() public {
        MockERC20 arvo = new MockERC20("Arvo", "ARVO", 18);

        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);

        ArvoStaking implementation = new ArvoStaking();

        bytes memory initialization = abi.encodeCall(
            ArvoStaking.initialize, (address(arvo), address(usdc), deploymentAdmin)
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initialization);

        staking = ArvoStaking(address(proxy));

        address[] memory proposers = new address[](1);
        proposers[0] = safe;

        address[] memory executors = new address[](1);
        executors[0] = safe;

        timelock = new TimelockController(DELAY, proposers, executors, address(0));

        configurator = new ConfigureArvoGovernance();

        _performHandoff();
    }

    function _performHandoff() internal {
        vm.startPrank(deploymentAdmin);

        staking.grantRole(staking.DEFAULT_ADMIN_ROLE(), address(timelock));

        staking.grantRole(staking.UPGRADER_ROLE(), address(timelock));

        staking.grantRole(staking.VAULT_MANAGER_ROLE(), safe);

        staking.grantRole(staking.REWARD_MANAGER_ROLE(), safe);

        staking.grantRole(staking.PAUSER_ROLE(), emergency);

        staking.renounceRole(staking.PAUSER_ROLE(), deploymentAdmin);

        staking.renounceRole(staking.VAULT_MANAGER_ROLE(), deploymentAdmin);

        staking.renounceRole(staking.REWARD_MANAGER_ROLE(), deploymentAdmin);

        staking.renounceRole(staking.UPGRADER_ROLE(), deploymentAdmin);

        staking.renounceRole(staking.DEFAULT_ADMIN_ROLE(), deploymentAdmin);

        vm.stopPrank();
    }

    function _config()
        internal
        view
        returns (ConfigureArvoGovernance.GovernanceConfig memory config)
    {
        config = ConfigureArvoGovernance.GovernanceConfig({
            stakingProxy: address(staking),
            deploymentAdmin: deploymentAdmin,
            governanceSafe: safe,
            emergencyAuthority: emergency,
            timelockDelay: DELAY
        });
    }

    function testVerifierAcceptsCorrectTopology() public view {
        assertTrue(configurator.verifyTopology(_config(), address(timelock)));
    }

    function testVerifierRejectsWrongTimelock() public view {
        assertFalse(configurator.verifyTopology(_config(), address(0x1234)));
    }

    function testDeployerHasNoRoles() public view {
        assertFalse(staking.hasRole(staking.DEFAULT_ADMIN_ROLE(), deploymentAdmin));

        assertFalse(staking.hasRole(staking.UPGRADER_ROLE(), deploymentAdmin));

        assertFalse(staking.hasRole(staking.VAULT_MANAGER_ROLE(), deploymentAdmin));

        assertFalse(staking.hasRole(staking.REWARD_MANAGER_ROLE(), deploymentAdmin));

        assertFalse(staking.hasRole(staking.PAUSER_ROLE(), deploymentAdmin));
    }

    function testEmergencyAuthorityCanPause() public {
        vm.prank(emergency);
        staking.pause();

        assertTrue(staking.paused());
    }

    function testEmergencyAuthorityCannotUnpause() public {
        vm.prank(emergency);
        staking.pause();

        vm.prank(emergency);
        vm.expectRevert();

        staking.unpause();
    }

    function testLegacyAllInOneRunIsDisabled() public {
        vm.expectRevert(
            ConfigureArvoGovernance.DeprecatedUseStagedGovernance.selector
        );
        configurator.run();
    }
}
