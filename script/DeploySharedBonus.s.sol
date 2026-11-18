// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Script, console2 } from "forge-std/Script.sol";
import { ArvoStakingTypes as T } from "../src/ArvoStakingTypes.sol";
import { ArvoSharedBonus, IArvoStakingBonusView } from "../src/bonus/ArvoSharedBonus.sol";

/// @notice Deploys a shared bonus for any existing, not-yet-open ARVO->ARVO
///         pool (one bonus contract per vault). Run with --dry-run first and review the printed
///         terms. Funding the pot is a separate transfer from the Treasury Safe.
///
/// Required env: STAKING_PROXY, BONUS_POOL_ID, BONUS_POT_ARVO (whole ARVO),
///               BONUS_TREASURY (Safe), BONUS_GRACE_DAYS, EXPECTED_CHAIN_ID.
contract DeploySharedBonus is Script {
    error WrongChain();
    error TreasuryNotContract();

    function run() external returns (ArvoSharedBonus bonus) {
        if (block.chainid != vm.envUint("EXPECTED_CHAIN_ID")) revert WrongChain();
        IArvoStakingBonusView staking = IArvoStakingBonusView(vm.envAddress("STAKING_PROXY"));
        uint32 poolId = uint32(vm.envUint("BONUS_POOL_ID"));
        uint256 pot = vm.envUint("BONUS_POT_ARVO") * 1 ether;
        address treasury = vm.envAddress("BONUS_TREASURY");
        uint64 grace = uint64(vm.envUint("BONUS_GRACE_DAYS") * 1 days);
        // The treasury should be the Safe, not an EOA.
        if (treasury.code.length == 0) revert TreasuryNotContract();

        T.PoolConfig memory p = staking.pool(poolId);
        T.VaultConfig memory v = staking.vault(poolId);
        console2.log("Chain", block.chainid);
        console2.log("Staking proxy", address(staking));
        console2.log("Pool", poolId);
        console2.log("Opens / closes (unix)", p.opensAt, p.closesAt);
        console2.log("Duration days", v.duration / 1 days);
        console2.log("Base reward bps", v.arvoRewardBps);
        console2.log("Max ARVO principal (whole)", p.maxArvoPrincipal / 1 ether);
        console2.log("Bonus pot (whole ARVO)", pot / 1 ether);
        if (p.maxArvoPrincipal != 0) {
            console2.log("Bonus bps at full capacity", pot * 10_000 / p.maxArvoPrincipal);
        }
        console2.log("Treasury", treasury);
        console2.log("Claim grace days", grace / 1 days);

        vm.startBroadcast();
        bonus = new ArvoSharedBonus(staking, poolId, pot, treasury, grace);
        vm.stopBroadcast();

        console2.log("ArvoSharedBonus", address(bonus));
        console2.log("Claim deadline (unix)", bonus.claimDeadline());
        console2.log("NEXT STEP: Treasury Safe transfers exactly the pot to this address before opensAt.");
    }
}
