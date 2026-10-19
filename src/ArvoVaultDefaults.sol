// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { ArvoStakingTypes } from "./ArvoStakingTypes.sol";

/// @notice Initial Arvo vault configuration.
///
/// @dev These are launch/testnet defaults. The staking contract will snapshot
///      a position's terms at entry so future configuration changes cannot
///      alter an existing position.
library ArvoVaultDefaults {
    function build() internal pure returns (ArvoStakingTypes.VaultConfig memory) {
        return _vault(60 days, 300, 200);
    }

    function advance() internal pure returns (ArvoStakingTypes.VaultConfig memory) {
        return _vault(90 days, 400, 300);
    }

    function compound() internal pure returns (ArvoStakingTypes.VaultConfig memory) {
        return _vault(180 days, 1_000, 650);
    }

    function foundation() internal pure returns (ArvoStakingTypes.VaultConfig memory) {
        return _vault(365 days, 2_200, 1_400);
    }

    function _vault(uint32 duration, uint16 arvoRewardBps, uint16 usdcRewardBps)
        private
        pure
        returns (ArvoStakingTypes.VaultConfig memory config)
    {
        config.duration = duration;

        config.arvoRewardBps = arvoRewardBps;
        config.usdcRewardBps = usdcRewardBps;

        // Testnet placeholder: +10% reward uplift for dual staking.
        config.dualBoostBps = 1_000;

        // Dual + loyalty + future boosts can never exceed +15%
        // without explicitly changing this configuration.
        config.combinedBoostCapBps = 1_500;

        // Initial mixed reward preference: 50/50.
        config.mixedArvoShareBps = 5_000;

        config.minArvo = 100_000 ether;

        // Mock USDC uses 6 decimals.
        config.minUsdc = 1_000e6;

        config.arvoStakeEnabled = true;
        config.usdcStakeEnabled = true;
        config.dualStakeEnabled = true;

        config.arvoRewardEnabled = true;
        config.usdcRewardEnabled = true;
        config.mixedRewardEnabled = true;
    }
}
