// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { BonusFixture } from "./ArvoSharedBonus.t.sol";
import { ArvoStakingTypes as T } from "../../src/ArvoStakingTypes.sol";
import { ArvoAcquisitionEscrow } from "../../src/ArvoAcquisitionEscrow.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";
import { ArvoSharedBonus, IArvoStakingBonusView } from "../../src/bonus/ArvoSharedBonus.sol";

contract ArvoSharedBonusReviewTest is BonusFixture {
    function _cfg(uint32 d) internal pure returns (T.VaultConfig memory c) {
        c = _config(); c.duration = d;
    }

    function _shortPool(uint64 o, uint64 cl) internal returns (uint32 id) {
        arvo.mint(admin, 1_000_000 ether);
        vm.startPrank(admin);
        staking.fundArvoRewards(1_000_000 ether);
        id = staking.createProductPool(T.VaultKind.CUSTOM, _cfg(1 days), o, cl, 0, 0, 1, 0);
        staking.reservePoolRewardBudget(id, 1_000_000 ether, 0);
        vm.stopPrank();
    }

    function _stakeIn(uint32 pid, address u, uint256 amt) internal returns (uint256 id) {
        arvo.mint(u, amt);
        vm.startPrank(u); arvo.approve(address(staking), amt);
        id = staking.stake(pid, T.StakeMode.ARVO, T.RewardMode.ARVO, amt, 0);
        vm.stopPrank();
    }

    /// Overpayment attempt: restake + compound INTO bonus pool, emergency
    /// exits before & after snapshot (incl. same block), compound OUT after
    /// maturity, claim of principal before bonus claim, third-party claims.
    function testPoC_RolloversIntoAndOutOfPoolNoOverpay() public {
        uint32 a = _shortPool(opensAt - 12 hours, opensAt + 2 days);
        vm.warp(opensAt - 12 hours);
        uint256 ra = _stakeIn(a, alice, 1_000_000 ether);
        uint256 rb = _stakeIn(a, bob, 2_000_000 ether);
        vm.warp(opensAt + 1 days);
        vm.prank(alice); uint256 aliceNew = staking.restakePrincipal(ra, poolId, T.RewardMode.ARVO);
        vm.prank(bob); uint256 bobNew = staking.compound(rb, poolId, T.RewardMode.ARVO);
        assertEq(staking.position(bobNew).arvoPrincipal, 2_000_000 ether + staking.position(rb).arvoReward);
        uint256 c1 = _stake(carol, 3_000_000 ether);
        address dave = address(0xDA);
        uint256 d1 = _stake(dave, 500_000 ether);
        _emergencyExit(dave, d1); // before snapshot
        address eve = address(0xEE);
        uint256 e1 = _stake(eve, 700_000 ether);

        // Same-block: snapshot then exit
        vm.warp(closesAt);
        bonus.snapshot();
        _emergencyExit(eve, e1);
        assertEq(bonus.totalEligible(), 1_000_000 ether + staking.position(bobNew).arvoPrincipal + 3_000_000 ether + 700_000 ether);

        // Old pool-A positions must not be claimable from the bonus
        vm.warp(closesAt + DURATION);
        vm.expectRevert(ArvoSharedBonus.WrongPool.selector); bonus.claim(ra);
        vm.expectRevert(ArvoSharedBonus.WrongPool.selector); bonus.claim(rb);

        // carol claims principal first, alice compounds OUT into a new pool
        vm.prank(carol); staking.claim(c1);
        uint64 o2 = uint64(block.timestamp + 1);
        uint32 p2 = _shortPool(o2, o2 + 1 days);
        vm.warp(o2);
        vm.prank(alice); uint256 aliceOut = staking.compound(aliceNew, p2, T.RewardMode.ARVO);
        vm.expectRevert(ArvoSharedBonus.WrongPool.selector); bonus.claim(aliceOut);

        uint256 paid;
        paid += bonus.claim(aliceNew);
        paid += bonus.claim(bobNew);
        paid += bonus.claim(c1);
        vm.expectRevert(ArvoSharedBonus.EmergencyExited.selector); bonus.claim(d1);
        vm.expectRevert(ArvoSharedBonus.EmergencyExited.selector); bonus.claim(e1);
        assertLe(paid, POT);
        assertEq(paid, bonus.totalClaimed());
        // eve's forfeited share remains locked until deadline, then to treasury
        assertEq(arvo.balanceOf(address(bonus)), POT - paid);
        vm.warp(bonus.claimDeadline());
        bonus.returnToTreasury();
        assertEq(arvo.balanceOf(treasury), POT - paid);
    }

    /// Constructor's acquisition check is time-of-check only: admin can flip
    /// the pool to an acquisition pool after the bonus is deployed.

    /// Constructor does not restrict stake products: DUAL stakers dilute the pot.

    /// Constructor accepts a 1-second snapshot window; missing it sends the
    /// entire pot to treasury.

    /// Donations cannot block snapshot or be used to steal owed funds.
    function testPoC_DonationAndEarlySweep() public {
        vm.warp(opensAt);
        _stake(alice, 1_000_000 ether);
        arvo.mint(address(bonus), 123 ether);
        assertEq(bonus.returnToTreasury(), 123 ether);
        vm.expectRevert(ArvoSharedBonus.NothingToReturn.selector);
        bonus.returnToTreasury();
        vm.warp(closesAt);
        bonus.snapshot();
        vm.expectRevert(ArvoSharedBonus.NothingToReturn.selector);
        bonus.returnToTreasury();
    }
    /// Review L-2: pools with dual or cross-asset products are rejected.
    function testRejectsDualAndCrossAssetPools() public {
        vm.startPrank(admin);
        uint32 dual = staking.createProductPool(T.VaultKind.CUSTOM, _config(), opensAt, closesAt, CAP, 1_000_000e6, 1 | 8, 0);
        T.VaultConfig memory c = _config();
        c.usdcRewardBps = 500;
        uint32 cross = staking.createProductPool(T.VaultKind.CUSTOM, c, opensAt, closesAt, CAP, 0, 1 | 2, MIN);
        vm.stopPrank();
        IArvoStakingBonusView s_ = IArvoStakingBonusView(address(staking));
        vm.expectRevert(ArvoSharedBonus.InvalidConfiguration.selector);
        new ArvoSharedBonus(s_, dual, POT, treasury, GRACE);
        vm.expectRevert(ArvoSharedBonus.InvalidConfiguration.selector);
        new ArvoSharedBonus(s_, cross, POT, treasury, GRACE);
    }

    /// Review L-1: the snapshot window must be at least one day.
    function testRejectsSnapshotWindowUnderOneDay() public {
        vm.startPrank(admin);
        uint32 tight = staking.createProductPool(T.VaultKind.CUSTOM, _config(), opensAt, opensAt + DURATION - 1 days + 1, CAP, 0, 1, 0);
        uint32 exact = staking.createProductPool(T.VaultKind.CUSTOM, _config(), opensAt, opensAt + DURATION - 1 days, CAP, 0, 1, 0);
        vm.stopPrank();
        vm.expectRevert(ArvoSharedBonus.InvalidConfiguration.selector);
        new ArvoSharedBonus(IArvoStakingBonusView(address(staking)), tight, POT, treasury, GRACE);
        new ArvoSharedBonus(IArvoStakingBonusView(address(staking)), exact, POT, treasury, GRACE);
    }

    /// Review I-1: converting the pool to an acquisition pool after deployment
    /// blocks the snapshot (if the staking contract allows the conversion at all).
    function testAcquisitionConversionBlocksSnapshot() public {
        ArvoAcquisitionEscrow esc = new ArvoAcquisitionEscrow(address(staking), address(usdc));
        MockERC20 tre = new MockERC20("t", "t", 18);
        vm.startPrank(admin);
        staking.configureAcquisitionEscrow(esc);
        try staking.configureAcquisitionPool(poolId, address(tre)) {
            vm.stopPrank();
            vm.warp(closesAt);
            vm.expectRevert(ArvoSharedBonus.InvalidConfiguration.selector);
            bonus.snapshot();
        } catch {
            vm.stopPrank();
            assertFalse(staking.acquisitionPools(poolId)); // ARVO-only pools cannot be converted
        }
    }

    /// Review I-3: estimates read zero once the bonus can no longer be paid.
    function testEstimateZeroWhenUnpayable() public {
        vm.warp(opensAt);
        uint256 a = _stake(alice, MIN);
        assertEq(bonus.bonusFor(a), POT);
        vm.warp(opensAt + DURATION); // snapshot window missed
        assertEq(bonus.bonusFor(a), 0);
    }

}
