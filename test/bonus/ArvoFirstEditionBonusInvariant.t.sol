// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Test } from "forge-std/Test.sol";
import { ArvoStaking } from "../../src/ArvoStaking.sol";
import { ArvoStakingTypes as T } from "../../src/ArvoStakingTypes.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";
import { ArvoFirstEditionBonus } from "../../src/bonus/ArvoFirstEditionBonus.sol";
import { BonusFixture } from "./ArvoFirstEditionBonus.t.sol";

contract BonusHandler is Test {
    ArvoStaking internal staking;
    MockERC20 internal arvo;
    ArvoFirstEditionBonus internal bonus;
    address internal admin;
    uint32 internal poolId;

    uint256[] public ids;
    mapping(uint256 => address) public ownerOf;
    uint256 public claimedSum;
    mapping(uint256 => bool) public exitedBeforeSnapshot;

    constructor(ArvoStaking s, MockERC20 a, ArvoFirstEditionBonus b, address adm, uint32 p) {
        staking = s; arvo = a; bonus = b; admin = adm; poolId = p;
    }

    function idsLength() external view returns (uint256) { return ids.length; }

    function stake(uint256 actorSeed, uint256 amount) external {
        address user = address(uint160(0x5000 + (actorSeed % 6)));
        amount = bound(amount, 50_000 ether, 8_000_000 ether);
        arvo.mint(user, amount);
        vm.startPrank(user);
        arvo.approve(address(staking), amount);
        try staking.stake(poolId, T.StakeMode.ARVO, T.RewardMode.ARVO, amount, 0) returns (uint256 id) {
            ids.push(id); ownerOf[id] = user;
        } catch { }
        vm.stopPrank();
    }

    function exit(uint256 index) external {
        if (ids.length == 0) return;
        uint256 id = ids[index % ids.length];
        vm.prank(admin); staking.pause();
        vm.prank(ownerOf[id]);
        try staking.emergencyExit(id) { if (!bonus.snapshotTaken()) exitedBeforeSnapshot[id] = true; } catch { }
        vm.prank(admin); staking.unpause();
    }

    function snapshot() external {
        try bonus.snapshot() { } catch { }
    }

    function claim(uint256 index) external {
        if (ids.length == 0) return;
        try bonus.claim(ids[index % ids.length]) returns (uint256 amount) { claimedSum += amount; } catch { }
    }

    function principalClaim(uint256 index) external {
        if (ids.length == 0) return;
        uint256 id = ids[index % ids.length];
        vm.prank(ownerOf[id]);
        try staking.claim(id) { } catch { }
    }

    function returnToTreasury() external {
        try bonus.returnToTreasury() { } catch { }
    }

    function warp(uint256 secondsAhead) external {
        vm.warp(block.timestamp + bound(secondsAhead, 1 hours, 12 days));
    }
}

contract ArvoFirstEditionBonusInvariantTest is BonusFixture {
    BonusHandler internal handler;

    function setUp() public override {
        super.setUp();
        vm.warp(opensAt);
        handler = new BonusHandler(staking, arvo, bonus, admin, poolId);
        targetContract(address(handler));
    }

    /// The pot is never overpaid and every ARVO is accounted for.
    function invariant_conservation() public view {
        assertLe(bonus.totalClaimed(), POT);
        assertEq(bonus.totalClaimed(), handler.claimedSum());
        assertEq(arvo.balanceOf(address(bonus)) + bonus.totalClaimed() + arvo.balanceOf(treasury), POT);
    }

    /// Unclaimed obligation is always backed once the pot is funded.
    function invariant_obligationBacked() public view {
        assertGe(arvo.balanceOf(address(bonus)), bonus.outstanding());
    }

    /// The snapshot, once taken, equals the principal of unexited pool positions
    /// that existed at the snapshot (no position is counted twice or missed).
    function invariant_claimsBoundedByShare() public view {
        if (!bonus.snapshotTaken() || bonus.totalEligible() == 0) return;
        uint256 n = handler.idsLength();
        uint256 sumShares;
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.ids(i);
            if (handler.exitedBeforeSnapshot(id)) continue;
            sumShares += staking.position(id).arvoPrincipal;
        }
        assertEq(sumShares, bonus.totalEligible());
    }

    /// The bonus contract never holds or moves staking principal.
    function invariant_stakingSolvent() public view {
        assertTrue(staking.isArvoSolvent());
    }
}
