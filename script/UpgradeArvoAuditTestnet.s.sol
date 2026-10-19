// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";
import {ArvoStaking} from "../src/ArvoStaking.sol";

/// @notice Upgrade the existing testnet implementation only. The immutable
/// escrow binding, all accounts, positions, pool terms and roles are preserved.
contract UpgradeArvoAuditTestnet is Script {
    address constant PROXY = 0x54697F1BE0E26d079CEb97992df54b8A700C6968;
    address constant ORIGINAL = 0xc7c5706b92801d97D873283E56fadb453adc241c;
    address constant ADMIN = 0x8A382ca8B4536b924C5d1cb77A048f44396C1477;
    error PreflightFailed();
    error StateChanged();

    function run() external returns (address implementation) {
        return _upgrade(PROXY, ORIGINAL, ADMIN);
    }

    function _upgrade(address proxy,address original,address admin) internal returns (address implementation) {
        if (block.chainid != 46630 || Upgrades.getImplementationAddress(proxy) != original) revert PreflightFailed();
        ArvoStaking s = ArvoStaking(proxy);
        if (!s.hasRole(s.UPGRADER_ROLE(),admin)) revert PreflightFailed();
        address escrow = address(s.acquisitionEscrow());
        if (escrow == address(0) || s.acquisitionEscrow().controller()!=proxy
            || address(s.acquisitionEscrow().usdc())!=address(s.usdc())) revert PreflightFailed();
        bytes32 beforeState = _snapshot(s,admin);
        Options memory opts;
        opts.referenceContract = "ArvoStakingAuditedV1.sol:ArvoStakingAuditedV1";
        opts.unsafeAllow = "constructor,external-library-linking";
        Upgrades.validateUpgrade("ArvoStaking.sol:ArvoStaking",opts);
        vm.startBroadcast(admin);
        implementation = address(new ArvoStaking());
        if (implementation.code.length>24576) revert PreflightFailed();
        s.upgradeToAndCall(implementation,"");
        vm.stopBroadcast();
        if (_snapshot(s,admin)!=beforeState || Upgrades.getImplementationAddress(proxy)!=implementation) revert StateChanged();
        console2.log("Staking proxy:",proxy);
        console2.log("New implementation:",implementation);
        console2.log("Existing immutable escrow retained:",escrow);
        console2.log("No Treasury movements, pool activation or role handoff.");
    }

    function _snapshot(ArvoStaking s,address admin) internal view returns(bytes32 hash) {
        uint32 pools=s.nextVaultId(); uint256 positions=s.nextPositionId();
        if(pools>256 || positions>1024) revert PreflightFailed();
        hash=keccak256(abi.encode(address(s.arvo()),address(s.usdc()),pools,positions,
            s.arvoPrincipalLiability(),s.usdcPrincipalLiability(),s.arvoRewardLiability(),s.usdcRewardLiability(),
            s.arvoRewardBudgetReserved(),s.usdcRewardBudgetReserved()));
        hash=keccak256(abi.encode(hash,address(s.acquisitionEscrow()),s.acquisitionUsdcPrincipal(),
            s.acquisitionUsdcRewards(),s.acquisitionUsdcBudget(),s.paused(),address(s.priceOracle()),s.maxPriceAge(),
            s.arvo().balanceOf(address(s)),s.usdc().balanceOf(address(s)),s.acquisitionEscrow().totalCash()));
        for(uint32 i;i<pools;i++) hash=keccak256(abi.encode(hash,s.pool(i),s.vault(i),s.poolProducts(i),
            s.poolVisibility(i),s.minArvoForUsdc(i),s.vaultArvoPrincipal(i),s.vaultUsdcPrincipal(i),s.acquisitionPools(i)));
        for(uint256 i;i<positions;i++) hash=keccak256(abi.encode(hash,s.position(i)));
        bytes32[5] memory roles=[s.DEFAULT_ADMIN_ROLE(),s.UPGRADER_ROLE(),s.VAULT_MANAGER_ROLE(),s.REWARD_MANAGER_ROLE(),s.PAUSER_ROLE()];
        for(uint256 i;i<5;i++) hash=keccak256(abi.encode(hash,s.hasRole(roles[i],admin)));
    }
}
