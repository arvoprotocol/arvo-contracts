// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";
import {ArvoStaking} from "../src/ArvoStaking.sol";
import {ArvoAcquisitionEscrow} from "../src/ArvoAcquisitionEscrow.sol";

/// @notice Upgrade only the reviewed Robinhood testnet proxy; no pool activation
/// or Treasury movements. Both upgrade and escrow binding use one proxy call.
contract UpgradeArvoAcquisitionTestnet is Script {
    address constant PROXY = 0x54697F1BE0E26d079CEb97992df54b8A700C6968;
    address constant ADMIN = 0x8A382ca8B4536b924C5d1cb77A048f44396C1477;
    address constant ORIGINAL = 0x9b0eB74EedFb0A2d4f5cbDb385FeE73645605814;
    error WrongChain();
    error UnexpectedImplementation();
    error MissingAdminRole();
    error SnapshotTooLarge();
    error StateChanged();
    error ModuleMismatch();
    error OversizedImplementation();

    function run() external returns (address implementation, address escrow) {
        return _upgrade(PROXY, ORIGINAL, ADMIN);
    }

    function _upgrade(address proxy, address original, address admin)
        internal returns (address implementation, address escrow)
    {
        if (block.chainid != 46630) revert WrongChain();
        if (Upgrades.getImplementationAddress(proxy) != original) revert UnexpectedImplementation();
        ArvoStaking staking = ArvoStaking(proxy);
        if (!staking.hasRole(staking.DEFAULT_ADMIN_ROLE(), admin)
            || !staking.hasRole(staking.UPGRADER_ROLE(), admin)) revert MissingAdminRole();
        bytes32 beforeState = _snapshot(staking, admin);

        Options memory opts;
        opts.referenceContract = "ArvoStakingTestnetV1.sol:ArvoStakingTestnetV1";
        opts.unsafeAllow = "constructor,external-library-linking";

        // Full storage validation is retained. No private key is read by Solidity.
        Upgrades.validateUpgrade("ArvoStaking.sol:ArvoStaking", opts);
        vm.startBroadcast(admin);
        // Explicit creation lets Forge link and deploy ArvoPoolCreation for scripts.
        // prepareUpgrade/getCode cannot load an unlinked artifact in this path.
        implementation = address(new ArvoStaking());
        if (implementation.code.length > 24576) revert OversizedImplementation();
        ArvoAcquisitionEscrow module = new ArvoAcquisitionEscrow(proxy, address(staking.usdc()));
        escrow = address(module);
        staking.upgradeToAndCall(implementation,
            abi.encodeCall(ArvoStaking.configureAcquisitionEscrow, (module)));
        vm.stopBroadcast();

        if (_snapshot(staking, admin) != beforeState) revert StateChanged();
        if (Upgrades.getImplementationAddress(proxy) != implementation
            || address(staking.acquisitionEscrow()) != escrow
            || module.controller() != proxy || address(module.usdc()) != address(staking.usdc())
            || module.totalCash() != 0 || staking.acquisitionUsdcPrincipal() != 0
            || staking.acquisitionUsdcRewards() != 0 || staking.acquisitionUsdcBudget() != 0) {
            revert ModuleMismatch();
        }
        console2.log("Staking proxy (unchanged):", proxy);
        console2.log("New implementation:", implementation);
        console2.log("Acquisition escrow:", escrow);
        console2.log("Existing pools, positions, balances and admin roles preserved.");
        console2.log("No acquisition pools activated. No Treasury transfers.");
    }

    function _snapshot(ArvoStaking s, address admin) internal view returns (bytes32 hash) {
        uint32 pools = s.nextVaultId();
        uint256 positions = s.nextPositionId();
        if (pools > 256 || positions > 1024) revert SnapshotTooLarge();
        hash = keccak256(abi.encode(address(s.arvo()), address(s.usdc()), pools, positions));
        hash = keccak256(abi.encode(hash, s.arvoPrincipalLiability(), s.usdcPrincipalLiability(),
            s.arvoRewardLiability(), s.usdcRewardLiability()));
        hash = keccak256(abi.encode(hash, s.arvoRewardBudgetReserved(), s.usdcRewardBudgetReserved(),
            s.arvo().balanceOf(address(s)), s.usdc().balanceOf(address(s))));
        hash = keccak256(abi.encode(hash, s.paused(), address(s.priceOracle()), s.maxPriceAge()));
        for (uint32 i; i < pools; ++i) {
            hash = keccak256(abi.encode(hash, s.pool(i), s.vault(i), s.poolProducts(i),
                s.poolVisibility(i), s.minArvoForUsdc(i), s.vaultArvoPrincipal(i), s.vaultUsdcPrincipal(i)));
        }
        for (uint256 i; i < positions; ++i) hash = keccak256(abi.encode(hash, s.position(i)));
        bytes32[5] memory roles = [s.DEFAULT_ADMIN_ROLE(), s.UPGRADER_ROLE(),
            s.VAULT_MANAGER_ROLE(), s.REWARD_MANAGER_ROLE(), s.PAUSER_ROLE()];
        for (uint256 i; i < roles.length; ++i) hash = keccak256(abi.encode(hash, s.hasRole(roles[i], admin)));
    }
}
