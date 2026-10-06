// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";

import { ArvoStakingTypes } from "../../src/ArvoStakingTypes.sol";
import { ArvoVaultDefaults } from "../../src/ArvoVaultDefaults.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";

contract ArvoVaultDefaultsTest is Test {
    function testBuildConfiguration() public pure {
        ArvoStakingTypes.VaultConfig memory vault = ArvoVaultDefaults.build();

        assertEq(vault.duration, 60 days);
        assertEq(vault.arvoRewardBps, 300);
        assertEq(vault.usdcRewardBps, 200);
        assertEq(vault.dualBoostBps, 1_000);
        assertEq(vault.combinedBoostCapBps, 1_500);
    }

    function testAdvanceConfiguration() public pure {
        ArvoStakingTypes.VaultConfig memory vault = ArvoVaultDefaults.advance();

        assertEq(vault.duration, 90 days);
        assertEq(vault.arvoRewardBps, 400);
        assertEq(vault.usdcRewardBps, 300);
    }

    function testCompoundConfiguration() public pure {
        ArvoStakingTypes.VaultConfig memory vault = ArvoVaultDefaults.compound();

        assertEq(vault.duration, 180 days);
        assertEq(vault.arvoRewardBps, 1_000);
        assertEq(vault.usdcRewardBps, 650);
    }

    function testFoundationConfiguration() public pure {
        ArvoStakingTypes.VaultConfig memory vault = ArvoVaultDefaults.foundation();

        assertEq(vault.duration, 365 days);
        assertEq(vault.arvoRewardBps, 2_200);
        assertEq(vault.usdcRewardBps, 1_400);
    }

    function testTokenDecimals() public {
        MockERC20 arvo = new MockERC20("Arvo", "ARVO", 18);
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);

        assertEq(arvo.decimals(), 18);
        assertEq(usdc.decimals(), 6);
    }
}
