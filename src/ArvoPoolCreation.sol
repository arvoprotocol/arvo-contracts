// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {ArvoStakingTypes as T} from "./ArvoStakingTypes.sol";
import {ArvoVaultDefaults} from "./ArvoVaultDefaults.sol";
/// @notice Linked pool factory. It writes only the explicitly supplied mappings.
/// @dev Main contract checks VAULT_MANAGER_ROLE; counter increments are atomic.
///      No token transfers, external calls, assembly or unstructured storage.
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
        vaults[id]=c; vaultExists[id]=true;
        pools[id]=T.PoolConfig(p.kind,p.opensAt,p.closesAt,p.maxArvo,p.maxUsdc,0,0,0,0,0,0,true,false);
        poolExists[id]=true;
        emit VaultCreated(id); emit VaultConfigured(id); emit PoolCreated(id,p.kind,p.opensAt,p.closesAt);
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
    }





}
