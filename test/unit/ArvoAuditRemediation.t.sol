// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ArvoAcquisitionTest} from "./ArvoAcquisition.t.sol";
import {ArvoStaking} from "../../src/ArvoStaking.sol";
import {ArvoAcquisitionEscrow} from "../../src/ArvoAcquisitionEscrow.sol";
import {ArvoPoolCreation} from "../../src/ArvoPoolCreation.sol";
import {ArvoStakingTypes as T} from "../../src/ArvoStakingTypes.sol";
import {Vm} from "forge-std/Vm.sol";

contract ArvoAuditRemediationTest is ArvoAcquisitionTest {
    function testM001ArvoOnlyAcquisitionExitDoesNotStrandAnEscrowPosition() public {
        uint32 other = newPool(5,60 days);
        s.configureAcquisitionPool(other,treasury);
        s.fundArvoRewards(1000 ether);
        s.reservePoolRewardBudget(other,100 ether,0);
        vm.warp(opens);
        vm.prank(alice);
        uint256 id=s.stake(other,T.StakeMode.ARVO,T.RewardMode.ARVO,1000 ether,0);
        s.pause();
        vm.prank(alice);
        (uint256 arvoPaid,uint256 usdcPaid)=s.emergencyExit(id);
        assertEq(arvoPaid,1000 ether);assertEq(usdcPaid,0);
        assertEq(s.pendingEmergencyUsdc(id),0);
        (,,,,,,,uint256 active,)=e.accounts(other);
        assertEq(active,0);
        e.repay(other,10e6);
        vm.warp(opens+5 days);s.finalizePool(other);
        withdrawExcess(other,10e6);
    }
    function testL003EscrowLifecycleEventsIdentifyPoolAndOwner() public {
        uint32 other = newPool(4, 60 days);
        vm.recordLogs();
        s.configureAcquisitionPool(other, treasury);
        s.addAcquisitionRewardLimit(other,1000e6);
        vm.warp(opens);
        vm.prank(alice);
        uint256 id=s.stake(other,T.StakeMode.USDC,T.RewardMode.USDC,0,1000e6);
        s.pause();
        vm.prank(alice);s.emergencyExit(id);
        vm.warp(opens+5 days);s.finalizePool(other);
        Vm.Log[] memory logs=vm.getRecordedLogs();
        uint256 seen;
        for(uint256 i;i<logs.length;i++) {
            if(logs[i].emitter!=address(e))continue;
            assertEq(logs[i].topics[1],bytes32(uint256(other)));
            bytes32 topic=logs[i].topics[0];
            if(topic==keccak256("Configured(uint32,address,uint64)"))seen|=1;
            if(topic==keccak256("Deposited(uint32,uint256,uint64)"))seen|=2;
            if(topic==keccak256("Settled(uint32,address,uint256,uint256)")) {
                assertEq(logs[i].topics[2],bytes32(uint256(uint160(alice))));seen|=4;
            }
            if(topic==keccak256("Finalized(uint32)"))seen|=8;
        }
        assertEq(seen,15);
    }
    function collectDeferred(uint256 id) internal returns(uint256 paid) { paid=s.claimEmergencyUsdc(id); }

    function dualPosition() internal returns (uint32 dual, uint256 id) {
        dual = newPool(32, 60 days);
        s.configureAcquisitionPool(dual, treasury);
        s.fundArvoRewards(1000 ether);
        s.reservePoolRewardBudget(dual, 100 ether, 0);
        s.addAcquisitionRewardLimit(dual, 1000e6);
        vm.warp(opens);
        vm.prank(alice);
        id = s.stake(dual, T.StakeMode.DUAL, T.RewardMode.MIXED, 1000 ether, 1000e6);
    }

    function testM001ArvoReturnsImmediatelyAndUsdcReceiptSurvivesFailedClaim() public {
        (uint32 dual, uint256 id) = dualPosition();
        T.Position memory original = s.position(id);
        release(dual, 1000e6);
        s.pause();
        vm.prank(alice);
        (uint256 paidArvo, uint256 paidUsdc) = s.emergencyExit(id);
        assertEq(paidArvo, 1000 ether);
        assertEq(paidUsdc, 0);
        assertEq(a.balanceOf(alice), 10_000 ether);
        assertEq(s.pendingEmergencyUsdc(id), 1000e6);
        assertEq(s.usdcPrincipalLiability(), 1000e6);
        assertEq(s.acquisitionUsdcPrincipal(), 1000e6);
        assertEq(s.vaultUsdcPrincipal(dual), 1000e6);
        assertEq(s.arvoPrincipalLiability(), 0);
        assertEq(s.arvoRewardLiability(), 0);
        assertEq(s.usdcRewardLiability(), 0);
        assertEq(s.acquisitionUsdcRewards(), 0);
        assertEq(s.position(id).arvoReward, original.arvoReward);
        assertEq(s.position(id).maturesAt, original.maturesAt);
        vm.prank(alice);
        vm.expectRevert(ArvoAcquisitionEscrow.LiquidityUnavailable.selector);
        collectDeferred(id);
        assertEq(s.pendingEmergencyUsdc(id), 1000e6);
        e.repay(pool, 1000e6); // Another pool's cash cannot pay this receipt.
        vm.prank(alice);
        vm.expectRevert(ArvoAcquisitionEscrow.LiquidityUnavailable.selector);
        collectDeferred(id);
        vm.prank(bob);
        vm.expectRevert(ArvoStaking.NotPositionOwner.selector);
        collectDeferred(id);
        vm.prank(alice);
        vm.expectRevert(ArvoStaking.PositionAlreadySettled.selector);
        s.emergencyExit(id);
        e.repay(dual, 1000e6);
        s.unpause();
        vm.warp(opens + 90 days);
        s.finalizePool(dual);
        vm.prank(alice);
        assertEq(collectDeferred(id), 1000e6);
        assertEq(u.balanceOf(alice), 10_000e6);
        assertEq(s.usdcPrincipalLiability(), 0);
        assertEq(s.acquisitionUsdcPrincipal(), 0);
        assertEq(s.vaultUsdcPrincipal(dual), 0);
        vm.prank(alice);
        vm.expectRevert(ArvoStaking.InvalidAmount.selector);
        collectDeferred(id);
        vm.prank(alice);
        vm.expectRevert(ArvoStaking.PositionAlreadySettled.selector);
        s.claim(id);
    }

    function testM001LiquidDualReceiptCanBeCollectedImmediatelyWhilePaused() public {
        (, uint256 id) = dualPosition();
        s.pause();
        vm.prank(alice); s.emergencyExit(id);
        vm.prank(alice); collectDeferred(id);
        assertEq(s.pendingEmergencyUsdc(id), 0);
        assertEq(e.totalCash(), 0);
    }

    function testL005UnfundedLimitIsNotCashButRealDeficitsStillReportFalse() public {
        assertTrue(s.isUsdcSolvent());
        vm.warp(opens);
        uint256 id = deposit(alice, 1000e6);
        // A promised acquisition reward is not yet cash: signal the shortfall.
        assertFalse(s.isUsdcSolvent());
        e.repay(pool, 100e6);
        assertTrue(s.isUsdcSolvent());
        release(pool, 1000e6);
        assertFalse(s.isUsdcSolvent());
        e.repay(pool, 1000e6);
        vm.warp(opens + 60 days);
        vm.prank(alice); s.claim(id);
        assertTrue(s.isUsdcSolvent());
    }

    function testL001SingleFloorAndWideIntermediateProducts() public pure {
        // Previous two-floor result was 0; exact reward is one USDC micro-unit.
        assert(ArvoPoolCreation.crossReward(19e17, 1, 9999, 6) == 1);
        // amount*price overflows uint256, but the final answer fits.
        assert(ArvoPoolCreation.crossReward(type(uint256).max, 10_000, 1, 18)
            == type(uint256).max / 1e30);
    }

    function testFuzzL001MatchesSingleDivision(uint96 amount, uint96 price, uint16 rate) public pure {
        uint16 boundedRate = uint16(uint256(rate) % 10_001);
        uint256 expected = uint256(amount) * uint256(price) * boundedRate / 1e22;
        assert(ArvoPoolCreation.crossReward(amount, price, boundedRate, 6) == expected);
    }

    function testL002CustomModeMinimumsCannotBeZero() public {
        T.VaultConfig memory c = cfg(60 days);
        c.minUsdc = 0;
        vm.expectRevert(ArvoStaking.InvalidConfiguration.selector);
        s.createCustomPool(c, opens, opens + 5 days, 0, 10_000e6);
        c = cfg(60 days); c.arvoStakeEnabled = true; c.minArvo = 0;
        vm.expectRevert(ArvoStaking.InvalidConfiguration.selector);
        s.createCustomPool(c, opens, opens + 5 days, 100_000 ether, 10_000e6);
    }
}
