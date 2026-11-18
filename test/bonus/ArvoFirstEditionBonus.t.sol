// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { ArvoStaking } from "../../src/ArvoStaking.sol";
import { ArvoStakingTypes as T } from "../../src/ArvoStakingTypes.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";
import { ArvoFirstEditionBonus, IArvoStakingBonusView } from "../../src/bonus/ArvoFirstEditionBonus.sol";

/// @dev Shared fixture: the audited ArvoStaking behind a real ERC1967 proxy,
///      configured as the First Edition working example from the handover:
///      60 days, 10% ARVO base, 50M ARVO cap, 2.5M ARVO fixed bonus pot.
abstract contract BonusFixture is Test {
    ArvoStaking internal staking;
    MockERC20 internal arvo;
    MockERC20 internal usdc;
    ArvoFirstEditionBonus internal bonus;

    address internal admin = address(0xA11CE);
    address internal treasury = address(0x7EA5);
    address internal alice = address(0xA1);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA201);

    uint32 internal poolId;
    uint64 internal opensAt;
    uint64 internal closesAt;

    uint256 internal constant MIN = 50_000 ether;
    uint256 internal constant CAP = 50_000_000 ether;
    uint256 internal constant BASE_BUDGET = 5_000_000 ether; // 10% of CAP
    uint256 internal constant POT = 2_500_000 ether;
    uint32 internal constant DURATION = 60 days;
    uint64 internal constant GRACE = 90 days;

    function setUp() public virtual {
        arvo = new MockERC20("Arvo", "ARVO", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        ArvoStaking implementation = new ArvoStaking();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(ArvoStaking.initialize, (address(arvo), address(usdc), admin))
        );
        staking = ArvoStaking(address(proxy));

        opensAt = uint64(block.timestamp + 1 days);
        closesAt = opensAt + 9 days;

        arvo.mint(admin, BASE_BUDGET);
        vm.startPrank(admin);
        arvo.approve(address(staking), type(uint256).max);
        staking.fundArvoRewards(BASE_BUDGET);
        poolId = staking.createProductPool(
            T.VaultKind.CUSTOM, _config(), opensAt, closesAt, CAP, 0, 1, 0
        );
        staking.reservePoolRewardBudget(poolId, BASE_BUDGET, 0);
        vm.stopPrank();

        bonus = new ArvoFirstEditionBonus(
            IArvoStakingBonusView(address(staking)), poolId, POT, treasury, GRACE
        );
        arvo.mint(address(bonus), POT);
    }

    function _config() internal pure returns (T.VaultConfig memory c) {
        c.duration = DURATION;
        c.arvoRewardBps = 1_000;
        c.minArvo = MIN;
        c.minUsdc = 1e6;
        c.mixedArvoShareBps = 5_000;
    }

    function _stake(address user, uint256 amount) internal returns (uint256 id) {
        arvo.mint(user, amount);
        vm.startPrank(user);
        arvo.approve(address(staking), amount);
        id = staking.stake(poolId, T.StakeMode.ARVO, T.RewardMode.ARVO, amount, 0);
        vm.stopPrank();
    }

    function _emergencyExit(address user, uint256 id) internal {
        vm.prank(admin);
        staking.pause();
        vm.prank(user);
        staking.emergencyExit(id);
        vm.prank(admin);
        staking.unpause();
    }
}

contract ArvoFirstEditionBonusTest is BonusFixture {
    // ---------------------------------------------------------------- config

    function testImmutablesMatchPool() public view {
        assertEq(address(bonus.arvo()), address(arvo));
        assertEq(bonus.poolId(), poolId);
        assertEq(bonus.bonusPot(), POT);
        assertEq(bonus.closesAt(), closesAt);
        assertEq(bonus.earliestMaturity(), opensAt + DURATION);
        assertEq(bonus.claimDeadline(), closesAt + DURATION + GRACE);
    }

    function testConstructorRejectsOpenPool() public {
        vm.warp(opensAt);
        vm.expectRevert(ArvoFirstEditionBonus.InvalidConfiguration.selector);
        new ArvoFirstEditionBonus(IArvoStakingBonusView(address(staking)), poolId, POT, treasury, GRACE);
    }

    function testConstructorRejectsPoolWithoutClose() public {
        vm.prank(admin);
        uint32 open = staking.createProductPool(T.VaultKind.CUSTOM, _config(), opensAt, 0, CAP, 0, 1, 0);
        vm.expectRevert(ArvoFirstEditionBonus.InvalidConfiguration.selector);
        new ArvoFirstEditionBonus(IArvoStakingBonusView(address(staking)), open, POT, treasury, GRACE);
    }

    function testConstructorRejectsWindowLongerThanTerm() public {
        vm.prank(admin);
        uint32 longWindow = staking.createProductPool(
            T.VaultKind.CUSTOM, _config(), opensAt, opensAt + DURATION, CAP, 0, 1, 0
        );
        vm.expectRevert(ArvoFirstEditionBonus.InvalidConfiguration.selector);
        new ArvoFirstEditionBonus(IArvoStakingBonusView(address(staking)), longWindow, POT, treasury, GRACE);
    }

    function testConstructorRejectsBadParameters() public {
        IArvoStakingBonusView s = IArvoStakingBonusView(address(staking));
        vm.expectRevert(ArvoFirstEditionBonus.InvalidConfiguration.selector);
        new ArvoFirstEditionBonus(s, poolId, 0, treasury, GRACE);
        vm.expectRevert(ArvoFirstEditionBonus.InvalidConfiguration.selector);
        new ArvoFirstEditionBonus(s, poolId, POT, address(0), GRACE);
        vm.expectRevert(ArvoFirstEditionBonus.InvalidConfiguration.selector);
        new ArvoFirstEditionBonus(s, poolId, POT, treasury, 29 days);
        vm.expectRevert(ArvoFirstEditionBonus.InvalidConfiguration.selector);
        new ArvoFirstEditionBonus(s, poolId, POT, treasury, 731 days);
        vm.expectRevert();
        new ArvoFirstEditionBonus(s, 99, POT, treasury, GRACE);
    }

    // ------------------------------------------------------------- handover maths

    /// Handover example: B = 2.5M, S = 25M -> bonus 10% (total 20%).
    function testHandoverExampleAtHalfCapacity() public {
        vm.warp(opensAt);
        uint256 a = _stake(alice, 10_000_000 ether);
        uint256 b = _stake(bob, 15_000_000 ether);
        vm.warp(closesAt);
        bonus.snapshot();
        assertEq(bonus.totalEligible(), 25_000_000 ether);

        vm.warp(opensAt + DURATION + 1);
        assertEq(bonus.claim(a), 1_000_000 ether); // 10% of 10M
        assertEq(bonus.claim(b), 1_500_000 ether); // 10% of 15M
        assertEq(arvo.balanceOf(alice), 1_000_000 ether);

        // Base reward from the audited contract is unchanged: 10% of principal.
        vm.prank(alice);
        (uint256 paid,) = staking.claim(a);
        assertEq(paid, 11_000_000 ether);
    }

    /// At full capacity the bonus is exactly 5% (total 15%).
    function testFullCapacityBonusIsFivePercent() public {
        vm.warp(opensAt);
        uint256 a = _stake(alice, 20_000_000 ether);
        _stake(bob, 30_000_000 ether);
        arvo.mint(carol, MIN);
        vm.startPrank(carol);
        arvo.approve(address(staking), MIN);
        vm.expectRevert(); // cap enforced by the audited contract
        staking.stake(poolId, T.StakeMode.ARVO, T.RewardMode.ARVO, MIN, 0);
        vm.stopPrank();
        vm.warp(closesAt);
        bonus.snapshot();
        vm.warp(opensAt + DURATION);
        assertEq(bonus.claim(a), 1_000_000 ether);
    }

    function testSoleParticipantReceivesWholePot() public {
        vm.warp(opensAt);
        uint256 a = _stake(alice, MIN);
        vm.warp(closesAt);
        bonus.snapshot();
        vm.warp(opensAt + DURATION);
        assertEq(bonus.claim(a), POT);
        assertEq(arvo.balanceOf(address(bonus)), 0);
    }

    function testEstimateFallsAsStakeEnters() public {
        vm.warp(opensAt);
        uint256 a = _stake(alice, 5_000_000 ether);
        assertEq(bonus.bonusFor(a), POT);
        _stake(bob, 5_000_000 ether);
        assertEq(bonus.bonusFor(a), POT / 2);
    }

    // ---------------------------------------------------------------- snapshot

    function testSnapshotTiming() public {
        vm.warp(opensAt);
        _stake(alice, MIN);
        vm.warp(closesAt - 1);
        vm.expectRevert(ArvoFirstEditionBonus.SnapshotTooEarly.selector);
        bonus.snapshot();
        vm.warp(opensAt + DURATION);
        vm.expectRevert(ArvoFirstEditionBonus.SnapshotWindowMissed.selector);
        bonus.snapshot();
    }

    function testSnapshotOnceAndRequiresFunding() public {
        ArvoFirstEditionBonus unfunded = new ArvoFirstEditionBonus(
            IArvoStakingBonusView(address(staking)), poolId, POT, treasury, GRACE
        );
        vm.warp(closesAt);
        vm.expectRevert(ArvoFirstEditionBonus.PotNotFunded.selector);
        unfunded.snapshot();
        bonus.snapshot();
        vm.expectRevert(ArvoFirstEditionBonus.SnapshotAlreadyTaken.selector);
        bonus.snapshot();
    }

    function testSnapshotIsPermissionless() public {
        vm.warp(opensAt);
        _stake(alice, MIN);
        vm.warp(closesAt);
        vm.prank(address(0xBEEF));
        bonus.snapshot();
        assertTrue(bonus.snapshotTaken());
    }

    // ------------------------------------------------------------------- claims

    function testClaimGuards() public {
        vm.warp(opensAt);
        uint256 a = _stake(alice, MIN);
        vm.expectRevert(ArvoFirstEditionBonus.SnapshotMissing.selector);
        bonus.claim(a);
        vm.warp(closesAt);
        bonus.snapshot();
        vm.expectRevert(ArvoFirstEditionBonus.NotMatured.selector);
        bonus.claim(a);
        vm.expectRevert(ArvoFirstEditionBonus.WrongPool.selector);
        bonus.claim(999);
        vm.warp(opensAt + DURATION);
        bonus.claim(a);
        vm.expectRevert(ArvoFirstEditionBonus.AlreadyClaimed.selector);
        bonus.claim(a);
    }

    function testThirdPartyClaimPaysOwnerOnly() public {
        vm.warp(opensAt);
        uint256 a = _stake(alice, MIN);
        vm.warp(closesAt);
        bonus.snapshot();
        vm.warp(opensAt + DURATION);
        vm.prank(address(0xBAD));
        bonus.claim(a);
        assertEq(arvo.balanceOf(alice), POT);
        assertEq(arvo.balanceOf(address(0xBAD)), 0);
    }

    function testBonusStillClaimableAfterPrincipalClaim() public {
        vm.warp(opensAt);
        uint256 a = _stake(alice, MIN);
        vm.warp(closesAt);
        bonus.snapshot();
        vm.warp(opensAt + DURATION);
        vm.prank(alice);
        staking.claim(a);
        assertEq(bonus.claim(a), POT);
    }

    function testPositionsFromOtherPoolsRejected() public {
        arvo.mint(admin, 1_000_000 ether);
        vm.startPrank(admin);
        staking.fundArvoRewards(1_000_000 ether);
        uint32 other = staking.createProductPool(T.VaultKind.CUSTOM, _config(), opensAt, closesAt, CAP, 0, 1, 0);
        staking.reservePoolRewardBudget(other, 1_000_000 ether, 0);
        vm.stopPrank();

        vm.warp(opensAt);
        uint256 a = _stake(alice, MIN);
        arvo.mint(bob, 5_000_000 ether);
        vm.startPrank(bob);
        arvo.approve(address(staking), type(uint256).max);
        uint256 foreign = staking.stake(other, T.StakeMode.ARVO, T.RewardMode.ARVO, 5_000_000 ether, 0);
        vm.stopPrank();

        assertEq(bonus.bonusFor(foreign), 0);
        vm.warp(closesAt);
        bonus.snapshot();
        assertEq(bonus.totalEligible(), MIN); // other pool's stake not counted
        vm.warp(opensAt + DURATION);
        vm.expectRevert(ArvoFirstEditionBonus.WrongPool.selector);
        bonus.claim(foreign);
        assertEq(bonus.claim(a), POT);
    }

    function testClaimManyPaysEachOwner() public {
        vm.warp(opensAt);
        uint256[] memory ids = new uint256[](3);
        ids[0] = _stake(alice, 1_000_000 ether);
        ids[1] = _stake(bob, 2_000_000 ether);
        ids[2] = _stake(carol, 2_000_000 ether);
        vm.warp(closesAt);
        bonus.snapshot();
        vm.warp(opensAt + DURATION + 9 days);
        assertEq(bonus.claimMany(ids), POT);
        assertEq(arvo.balanceOf(alice), 500_000 ether);
        assertEq(arvo.balanceOf(bob), 1_000_000 ether);
        assertEq(arvo.balanceOf(carol), 1_000_000 ether);
    }

    // ---------------------------------------------------------- emergency exits

    function testExitBeforeSnapshotLeavesDenominatorAndForfeits() public {
        vm.warp(opensAt);
        uint256 a = _stake(alice, 10_000_000 ether);
        uint256 b = _stake(bob, 10_000_000 ether);
        _emergencyExit(bob, b);
        vm.warp(closesAt);
        bonus.snapshot();
        assertEq(bonus.totalEligible(), 10_000_000 ether);
        vm.warp(opensAt + DURATION);
        assertEq(bonus.claim(a), POT);
        vm.expectRevert(ArvoFirstEditionBonus.EmergencyExited.selector);
        bonus.claim(b);
    }

    function testExitAfterSnapshotForfeitsToTreasury() public {
        vm.warp(opensAt);
        uint256 a = _stake(alice, 10_000_000 ether);
        uint256 b = _stake(bob, 10_000_000 ether);
        vm.warp(closesAt);
        bonus.snapshot();
        _emergencyExit(bob, b);
        vm.warp(opensAt + DURATION);
        assertEq(bonus.claim(a), POT / 2);
        vm.expectRevert(ArvoFirstEditionBonus.EmergencyExited.selector);
        bonus.claim(b);

        vm.expectRevert(ArvoFirstEditionBonus.NothingToReturn.selector);
        bonus.returnToTreasury();
        vm.warp(bonus.claimDeadline());
        assertEq(bonus.returnToTreasury(), POT / 2);
        assertEq(arvo.balanceOf(treasury), POT / 2);
    }

    // ---------------------------------------------------------------- treasury

    function testOverfundingReturnableButObligationProtected() public {
        arvo.mint(address(bonus), 7 ether);
        assertEq(bonus.returnToTreasury(), 7 ether);
        vm.expectRevert(ArvoFirstEditionBonus.NothingToReturn.selector);
        bonus.returnToTreasury();
        assertEq(arvo.balanceOf(address(bonus)), POT);
    }

    function testNoParticipantsReturnsWholePot() public {
        vm.warp(closesAt);
        bonus.snapshot();
        assertEq(bonus.returnToTreasury(), POT);
    }

    function testMissedSnapshotReturnsWholePot() public {
        vm.warp(opensAt);
        _stake(alice, MIN);
        vm.warp(opensAt + DURATION);
        assertEq(bonus.returnToTreasury(), POT);
    }

    function testClaimsCloseAtDeadline() public {
        vm.warp(opensAt);
        uint256 a = _stake(alice, MIN);
        vm.warp(closesAt);
        bonus.snapshot();
        vm.warp(bonus.claimDeadline());
        vm.expectRevert(ArvoFirstEditionBonus.ClaimWindowClosed.selector);
        bonus.claim(a);
        assertEq(bonus.returnToTreasury(), POT);
    }

    // -------------------------------------------------------------------- fuzz

    /// Random stakers, amounts, entry times and exits: total paid never exceeds
    /// the pot, every eligible staker is paid pro rata, and rounding dust is
    /// below one wei per position.
    function testFuzzConservation(uint256 seed, uint8 count, uint8 exitMask) public {
        count = uint8(bound(count, 1, 12));
        vm.warp(opensAt);
        uint256[] memory ids = new uint256[](count);
        address[] memory users = new address[](count);
        uint256 remaining = CAP;
        for (uint256 i; i < count; ++i) {
            uint256 maxAmount = remaining - MIN * (count - i - 1);
            if (maxAmount > 10_000_000 ether) maxAmount = 10_000_000 ether;
            uint256 amount = bound(uint256(keccak256(abi.encode(seed, i))), MIN, maxAmount);
            remaining -= amount;
            users[i] = address(uint160(0x1000 + i));
            vm.warp(opensAt + (i * 8 days) / count);
            ids[i] = _stake(users[i], amount);
        }
        // Exits before the snapshot.
        for (uint256 i; i < count; ++i) {
            if ((exitMask >> (i % 8)) & 1 == 1 && i % 2 == 0) _emergencyExit(users[i], ids[i]);
        }
        vm.warp(closesAt);
        bonus.snapshot();
        // Exits after the snapshot.
        for (uint256 i; i < count; ++i) {
            if ((exitMask >> (i % 8)) & 1 == 1 && i % 2 == 1) _emergencyExit(users[i], ids[i]);
        }
        vm.warp(closesAt + DURATION);
        uint256 paid;
        uint256 eligibleAtClaim;
        for (uint256 i; i < count; ++i) {
            if (staking.position(ids[i]).emergencyExit) {
                vm.expectRevert(ArvoFirstEditionBonus.EmergencyExited.selector);
                bonus.claim(ids[i]);
            } else {
                uint256 expected = (POT * staking.position(ids[i]).arvoPrincipal) / bonus.totalEligible();
                assertEq(bonus.claim(ids[i]), expected);
                paid += expected;
                eligibleAtClaim += staking.position(ids[i]).arvoPrincipal;
            }
        }
        assertLe(paid, POT);
        assertEq(paid, bonus.totalClaimed());
        if (eligibleAtClaim == bonus.totalEligible() && eligibleAtClaim != 0) {
            assertLe(POT - paid, count); // floor dust only
        }
        vm.warp(bonus.claimDeadline());
        if (POT > paid) bonus.returnToTreasury();
        assertEq(arvo.balanceOf(address(bonus)), 0);
        assertEq(arvo.balanceOf(treasury) + paid, POT);
    }
}
