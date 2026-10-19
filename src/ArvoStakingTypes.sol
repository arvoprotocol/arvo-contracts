// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @notice Shared data structures for the Arvo staking protocol.
library ArvoStakingTypes {
    uint16 internal constant BPS = 10_000;

    enum VaultKind {
        BUILD,
        ADVANCE,
        COMPOUND,
        FOUNDATION,
        CUSTOM
    }

    enum StakeMode {
        ARVO,
        USDC,
        DUAL
    }

    enum RewardMode {
        ARVO,
        USDC,
        MIXED
    }

    enum SettlementMode {
        CLAIM,
        RESTAKE_PRINCIPAL,
        COMPOUND
    }

    struct VaultConfig {
        // Vault term and base cycle rewards.
        uint32 duration;
        uint16 arvoRewardBps;
        uint16 usdcRewardBps;

        // Reward boosts.
        uint16 dualBoostBps;
        uint16 combinedBoostCapBps;

        // ARVO share of a mixed reward.
        // 5,000 = 50% ARVO / 50% USDC.
        uint16 mixedArvoShareBps;

        // Minimum deposits.
        uint256 minArvo;
        uint256 minUsdc;

        // Product controls.
        bool arvoStakeEnabled;
        bool usdcStakeEnabled;
        bool dualStakeEnabled;

        bool arvoRewardEnabled;
        bool usdcRewardEnabled;
        bool mixedRewardEnabled;
    }

    /// @notice Operational state for an individual staking pool.
    ///
    /// @dev Economic terms remain in VaultConfig. This structure holds
    ///      campaign-specific capacity, funding and lifecycle information.
    struct PoolConfig {
        VaultKind kind;

        // Staking can begin at opensAt.
        // closesAt == 0 means there is no scheduled closing time.
        uint64 opensAt;
        uint64 closesAt;

        // Public principal capacity. 0 means uncapped.
        uint256 maxArvoPrincipal;
        uint256 maxUsdcPrincipal;

        // Original reward amounts reserved for this pool.
        uint256 arvoRewardBudget;
        uint256 usdcRewardBudget;

        // Reserved reward amounts not yet committed to positions.
        uint256 arvoRewardBudgetRemaining;
        uint256 usdcRewardBudgetRemaining;

        // Capacity intentionally allocated by the protocol.
        // These amounts are NOT deposits, principal or reward-bearing.
        uint256 protocolArvoAllocation;
        uint256 protocolUsdcAllocation;

        bool enabled;
        bool finalized;
    }

    struct LoyaltyConfig {
        bool enabled;

        // Number of consecutive qualifying restakes required.
        uint16 qualifyingRestakes;

        // Reward uplift, not percentage points.
        // 500 = +5% to the calculated reward.
        uint16 boostBps;

        // Maximum loyalty uplift permitted.
        uint16 maximumBoostBps;

        // Whether taking everything back to the wallet resets the streak.
        bool resetOnFullClaim;
    }

    struct Position {
        address owner;

        uint32 vaultId;

        StakeMode stakeMode;
        RewardMode rewardMode;

        uint64 openedAt;
        uint64 maturesAt;
        uint64 settledAt;

        uint256 arvoPrincipal;
        uint256 usdcPrincipal;

        // These are snapshotted when the position opens.
        uint256 arvoReward;
        uint256 usdcReward;

        uint16 appliedDualBoostBps;
        uint16 appliedLoyaltyBoostBps;

        // Allows us to show a restaking chain in the dashboard.
        uint256 previousPositionId;
        uint256 nextPositionId;

        bool settled;
        bool emergencyExit;
    }

    struct UserLoyalty {
        uint32 consecutiveRestakes;
        uint32 lifetimeRestakes;
    }
}
