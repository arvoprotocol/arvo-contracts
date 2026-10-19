// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {ArvoStakingTypes as T} from "./ArvoStakingTypes.sol";
import {ArvoVaultDefaults} from "./ArvoVaultDefaults.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IArvoPriceOracle} from "./interfaces/IArvoPriceOracle.sol";
/// @notice Linked pool factory and pure validation/reward helpers.
/// @dev Only create/finalize write storage, through explicitly supplied mappings; the
/// staking caller enforces its role. Math/validation helpers are pure; oracle
/// helpers read only the supplied oracle. Math.mulDiv uses arithmetic assembly
/// with no storage access or token transfers.
library ArvoPoolCreation {
    uint256 internal constant BPS=10_000;
    struct Terms {
        T.VaultKind kind;
        T.VaultConfig config;
        uint64 opensAt;
        uint64 closesAt;
        uint256 maxArvo;
        uint256 maxUsdc;
        uint8 products;
        uint256 crossMinimum;
        uint8 factory;
    }
    error InvalidConfiguration();
    error InvalidPoolWindow();
    error StakeModeDisabled();
    error InvalidAmount();
    error BelowMinimum();
    error RewardModeDisabled();
    error ProductDisabled();
    error InvalidPrice();
    error PoolFinalizedAlready();
    error PoolStillOpen();
    error PoolClosed();
    error PoolNotOpen();
    event PoolStatusChanged(uint32 indexed poolId,bool enabled);
    event PoolFinalized(uint32 indexed poolId,uint256 releasedArvoRewardBudget,uint256 releasedUsdcRewardBudget);
    event VaultCreated(uint32 indexed vaultId);
    event VaultConfigured(uint32 indexed vaultId);
    event PoolCreated(uint32 indexed poolId,T.VaultKind indexed kind,uint64 opensAt,uint64 closesAt);
    function create(mapping(uint32=>T.VaultConfig) storage vaults,
        mapping(uint32=>bool) storage vaultExists,
        mapping(uint32=>T.PoolConfig) storage pools,
        mapping(uint32=>bool) storage poolExists,
        mapping(uint32=>uint8) storage products,
        mapping(uint32=>uint256) storage crossMinimum,
        uint32 id,Terms memory p) external {
        if(p.opensAt<block.timestamp || (p.closesAt!=0 && p.closesAt<=p.opensAt)) revert InvalidPoolWindow();
        T.VaultConfig memory c;
        if(p.kind==T.VaultKind.CUSTOM) { c=p.config; validate(c); }
        else c=standard(p.kind);
        if(p.factory==0) {
            c.arvoStakeEnabled=(p.products&1)!=0; c.usdcStakeEnabled=(p.products&2)!=0;
            c.dualStakeEnabled=(p.products&4)!=0; c.arvoRewardEnabled=(p.products&8)!=0;
            c.usdcRewardEnabled=(p.products&16)!=0; c.mixedRewardEnabled=false;
        } else if(p.factory==1) c.mixedRewardEnabled=false;
        else {
            if(p.products==0 || p.products>63) revert InvalidConfiguration();
            if(p.kind!=T.VaultKind.CUSTOM && (p.products&2)!=0 && p.crossMinimum!=150_000 ether) revert InvalidConfiguration();
            if((p.products&2)!=0 && (p.crossMinimum==0 || p.crossMinimum<c.minArvo)) revert InvalidConfiguration();
            c.arvoStakeEnabled=(p.products&3)!=0; c.usdcStakeEnabled=(p.products&4)!=0;
            c.dualStakeEnabled=(p.products&56)!=0; c.arvoRewardEnabled=(p.products&41)!=0;
            c.usdcRewardEnabled=(p.products&54)!=0; c.mixedRewardEnabled=(p.products&32)!=0;
            if(c.mixedRewardEnabled && (c.mixedArvoShareBps==0 || c.mixedArvoShareBps==10_000
                || c.arvoRewardBps==0 || c.usdcRewardBps==0)) revert InvalidConfiguration();
            if((c.arvoStakeEnabled || c.dualStakeEnabled) && c.minArvo==0) revert InvalidConfiguration();
            if((c.usdcStakeEnabled || c.dualStakeEnabled) && c.minUsdc==0) revert InvalidConfiguration();
            products[id]=p.products; crossMinimum[id]=p.crossMinimum;
        }
        // Validate the final enabled modes, including custom factory flags.
        validate(c);
        vaults[id]=c; vaultExists[id]=true;
        pools[id]=T.PoolConfig(p.kind,p.opensAt,p.closesAt,p.maxArvo,p.maxUsdc,0,0,0,0,0,0,true,false);
        poolExists[id]=true;
        emit VaultCreated(id); emit VaultConfigured(id); emit PoolCreated(id,p.kind,p.opensAt,p.closesAt);
    }
    function validateStake(
        T.VaultConfig memory config,
        T.StakeMode stakeMode,
        uint256 arvoAmount,
        uint256 usdcAmount
    ) private pure {
        if (stakeMode == T.StakeMode.ARVO) {
            if (!config.arvoStakeEnabled) {
                revert StakeModeDisabled();
            }

            if (arvoAmount == 0 || usdcAmount != 0) {
                revert InvalidAmount();
            }

            if (arvoAmount < config.minArvo) {
                revert BelowMinimum();
            }

            return;
        }

        if (stakeMode == T.StakeMode.USDC) {
            if (!config.usdcStakeEnabled) {
                revert StakeModeDisabled();
            }

            if (usdcAmount == 0 || arvoAmount != 0) {
                revert InvalidAmount();
            }

            if (usdcAmount < config.minUsdc) {
                revert BelowMinimum();
            }

            return;
        }

        if (!config.dualStakeEnabled) {
            revert StakeModeDisabled();
        }

        if (arvoAmount == 0 || usdcAmount == 0) {
            revert InvalidAmount();
        }

        if (arvoAmount < config.minArvo || usdcAmount < config.minUsdc) {
            revert BelowMinimum();
        }
    }

    function validateRewardMode(
        T.VaultConfig memory config,
        T.RewardMode rewardMode
    ) private pure {
        if (rewardMode == T.RewardMode.ARVO && !config.arvoRewardEnabled) {
            revert RewardModeDisabled();
        }

        if (rewardMode == T.RewardMode.USDC && !config.usdcRewardEnabled) {
            revert RewardModeDisabled();
        }

        if (rewardMode == T.RewardMode.MIXED && !config.mixedRewardEnabled) {
            revert RewardModeDisabled();
        }
    }

    function calculateReward(
        T.VaultConfig memory config,
        T.StakeMode stakeMode,
        T.RewardMode rewardMode,
        uint256 arvoAmount,
        uint256 usdcAmount,
        bool cross
    ) external pure returns (uint256 arvoReward, uint256 usdcReward, uint16 appliedDualBoost) {
        validateStake(config, stakeMode, arvoAmount, usdcAmount);
        validateRewardMode(config, rewardMode);
        if (cross) return (0, 0, 0);
        uint256 rewardMultiplier = BPS;

        if (stakeMode == T.StakeMode.DUAL) {
            appliedDualBoost = config.dualBoostBps;

            uint256 cappedBoost = appliedDualBoost;

            if (cappedBoost > config.combinedBoostCapBps) {
                cappedBoost = config.combinedBoostCapBps;
            }

            rewardMultiplier = BPS + cappedBoost;
        }

        // Native-asset rewards; cross-asset quotes use crossReward separately.

        if (rewardMode == T.RewardMode.ARVO) {
            if (arvoAmount == 0) {
                revert RewardModeDisabled();
            }

            arvoReward = (arvoAmount * config.arvoRewardBps * rewardMultiplier) / (BPS * BPS);

            return (arvoReward, 0, appliedDualBoost);
        }

        if (rewardMode == T.RewardMode.USDC) {
            if (usdcAmount == 0) {
                revert RewardModeDisabled();
            }

            usdcReward = (usdcAmount * config.usdcRewardBps * rewardMultiplier) / (BPS * BPS);

            return (0, usdcReward, appliedDualBoost);
        }

        if (stakeMode != T.StakeMode.DUAL) {
            revert RewardModeDisabled();
        }

        uint256 arvoShare = config.mixedArvoShareBps;

        uint256 usdcShare = BPS - arvoShare;

        arvoReward =
            (arvoAmount * config.arvoRewardBps * rewardMultiplier * arvoShare) / (BPS * BPS * BPS);

        usdcReward =
            (usdcAmount * config.usdcRewardBps * rewardMultiplier * usdcShare) / (BPS * BPS * BPS);
    }

    function validateProduct(uint8 products, uint256 crossMinimum, T.StakeMode stakeMode,
        T.RewardMode rewardMode, uint256 amount) external pure {
        if (products == 0) {
            if (stakeMode == T.StakeMode.ARVO && rewardMode == T.RewardMode.USDC) revert ProductDisabled();
            return;
        }
        uint8 bit;
        if (stakeMode == T.StakeMode.ARVO) {
            if (rewardMode == T.RewardMode.ARVO) bit = 1;
            else if (rewardMode == T.RewardMode.USDC) {
                bit = 2;
                if (amount < crossMinimum) revert BelowMinimum();
            }
        } else if (stakeMode == T.StakeMode.USDC && rewardMode == T.RewardMode.USDC) bit = 4;
        else if (stakeMode == T.StakeMode.DUAL) {
            if (rewardMode == T.RewardMode.ARVO) bit = 8;
            else if (rewardMode == T.RewardMode.USDC) bit = 16;
            else if (rewardMode == T.RewardMode.MIXED) bit = 32;
        }
        if ((products & bit) == 0) revert ProductDisabled();
    }

    /// @dev Main caller authenticates VAULT_MANAGER_ROLE and updates aggregate budgets.
    function finalize(mapping(uint32=>T.PoolConfig) storage pools,uint32 poolId)
        external returns(uint256 releasedArvo,uint256 releasedUsdc) {
        T.PoolConfig storage p=pools[poolId];
        if(p.finalized)revert PoolFinalizedAlready();
        bool closed=p.closesAt!=0 && block.timestamp>=p.closesAt;
        if(p.enabled && !closed)revert PoolStillOpen();
        releasedArvo=p.arvoRewardBudgetRemaining;
        releasedUsdc=p.usdcRewardBudgetRemaining;
        p.arvoRewardBudgetRemaining=0;
        p.usdcRewardBudgetRemaining=0;
        p.enabled=false;p.finalized=true;
        emit PoolStatusChanged(poolId,false);
        emit PoolFinalized(poolId,releasedArvo,releasedUsdc);
    }

    function validatePoolOpen(mapping(uint32=>T.PoolConfig) storage pools,uint32 poolId) external view {
        T.PoolConfig storage poolConfig = pools[poolId];

        if (!poolConfig.enabled || poolConfig.finalized) {
            revert PoolClosed();
        }

        if (block.timestamp < poolConfig.opensAt) {
            revert PoolNotOpen();
        }

        if (poolConfig.closesAt != 0 && block.timestamp >= poolConfig.closesAt) {
            revert PoolClosed();
        }
    }

    function standard(T.VaultKind kind) public pure returns(T.VaultConfig memory c) {
        c=ArvoVaultDefaults.build();
        if(kind==T.VaultKind.BUILD) return c;
        if(kind==T.VaultKind.ADVANCE) { c.duration=90 days; c.arvoRewardBps=400; c.usdcRewardBps=300; }
        else if(kind==T.VaultKind.COMPOUND) { c.duration=180 days; c.arvoRewardBps=1000; c.usdcRewardBps=650; }
        else if(kind==T.VaultKind.FOUNDATION) { c.duration=365 days; c.arvoRewardBps=2200; c.usdcRewardBps=1400; }
        else revert InvalidConfiguration();
    }
    function validate(T.VaultConfig memory c) private pure {
        if(c.duration==0 || c.arvoRewardBps>10_000 || c.usdcRewardBps>10_000
            || c.mixedArvoShareBps>10_000 || c.dualBoostBps>5000 || c.combinedBoostCapBps>5000
            || c.dualBoostBps>c.combinedBoostCapBps) revert InvalidConfiguration();
        if ((c.arvoStakeEnabled || c.dualStakeEnabled) && c.minArvo == 0) revert InvalidConfiguration();
        if ((c.usdcStakeEnabled || c.dualStakeEnabled) && c.minUsdc == 0) revert InvalidConfiguration();
    }

    /// @dev Exact floor(amount * price * rate / denominator), with 512-bit
    /// multiplication. Quotient/remainder decomposition avoids price*rate overflow.
    function crossReward(uint256 amount, uint256 price, uint16 rate, uint8 decimals)
        public pure returns (uint256) {
        if (rate == 0) return 0;
        uint256 denominator = 10 ** (uint256(decimals) + 12) * BPS;
        return Math.mulDiv(amount, price, denominator) * rate
            + Math.mulDiv(mulmod(amount, price, denominator), rate, denominator);
    }

    function validateOracle(IArvoPriceOracle oracle,uint32 maxAge) external view {
        readPrice(oracle,maxAge);
    }

    function quote(IArvoPriceOracle oracle,uint32 maxAge,uint256 amount,uint16 rate)
        external view returns(uint256 reward) {
        (uint256 price,uint8 decimals)=readPrice(oracle,maxAge);
        reward=crossReward(amount,price,rate,decimals);
        if(reward==0)revert InvalidAmount();
    }

    function readPrice(IArvoPriceOracle oracle,uint32 maxAge) private view returns(uint256 price,uint8 decimals) {
        if(address(oracle)==address(0))revert InvalidPrice();
        uint256 updatedAt;
        (price,decimals,updatedAt)=oracle.getArvoUsdPrice();
        if(price==0 || decimals>18 || updatedAt==0 || updatedAt>block.timestamp
            || block.timestamp-updatedAt>maxAge)revert InvalidPrice();
    }





}
