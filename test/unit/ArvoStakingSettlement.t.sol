// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { ArvoStaking } from "../../src/ArvoStaking.sol";
import { ArvoStakingTypes } from "../../src/ArvoStakingTypes.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";

contract ArvoStakingSettlementTest is Test {
    ArvoStaking internal staking;
    MockERC20 internal arvo;
    MockERC20 internal usdc;

    address internal admin = address(0xA11CE);
    address internal alice = address(0xB0B);
    address internal attacker = address(0xBAD);

    uint32 internal foundationPool;

    uint256 internal constant ARVO_STAKE = 1000000 ether;
    uint256 internal constant ARVO_REWARD = 220000 ether;

    uint256 internal constant USDC_STAKE = 10_000e6;
    uint256 internal constant USDC_REWARD = 1_400e6;

    uint256 internal constant ARVO_REWARD_BUDGET = 50000000 ether;
    uint256 internal constant USDC_REWARD_BUDGET = 500_000e6;

    function setUp() public {
        arvo = new MockERC20("Arvo", "ARVO", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        ArvoStaking implementation = new ArvoStaking();

        bytes memory initialization =
            abi.encodeCall(ArvoStaking.initialize, (address(arvo), address(usdc), admin));

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initialization);

        staking = ArvoStaking(address(proxy));

        arvo.mint(admin, 1000000000 ether);
        usdc.mint(admin, 10_000_000e6);

        vm.startPrank(admin);

        arvo.approve(address(staking), type(uint256).max);
        usdc.approve(address(staking), type(uint256).max);

        staking.fundArvoRewards(100000000 ether);
        staking.fundUsdcRewards(1_000_000e6);

        foundationPool = staking.createStandardPool(
            ArvoStakingTypes.VaultKind.FOUNDATION,
            uint64(vm.getBlockTimestamp() + 1),
            0,
            5000000 ether,
            50_000e6,
            true,
            true,
            false,
            true,
            true
        );

        staking.reservePoolRewardBudget(foundationPool, ARVO_REWARD_BUDGET, USDC_REWARD_BUDGET);

        vm.stopPrank();

        arvo.mint(alice, 10000000 ether);
        usdc.mint(alice, 100_000e6);

        vm.startPrank(alice);

        arvo.approve(address(staking), type(uint256).max);
        usdc.approve(address(staking), type(uint256).max);

        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _stakeArvo() internal returns (uint256 positionId) {
        vm.prank(alice);

        positionId = staking.stake(
            foundationPool,
            ArvoStakingTypes.StakeMode.ARVO,
            ArvoStakingTypes.RewardMode.ARVO,
            ARVO_STAKE,
            0
        );
    }

    function _stakeUsdc() internal returns (uint256 positionId) {
        vm.prank(alice);

        positionId = staking.stake(
            foundationPool,
            ArvoStakingTypes.StakeMode.USDC,
            ArvoStakingTypes.RewardMode.USDC,
            0,
            USDC_STAKE
        );
    }

    function _warpToMaturity(uint256 positionId) internal {
        ArvoStakingTypes.Position memory userPosition = staking.position(positionId);

        vm.warp(userPosition.maturesAt);
    }

    function testMaturedUsdcPositionPaysPrincipalAndReward() public {
        uint256 positionId = _stakeUsdc();

        uint256 balanceBefore = usdc.balanceOf(alice);

        _warpToMaturity(positionId);

        vm.prank(alice);

        (uint256 arvoPaid, uint256 usdcPaid) = staking.claim(positionId);

        assertEq(arvoPaid, 0);
        assertEq(usdcPaid, USDC_STAKE + USDC_REWARD);

        assertEq(usdc.balanceOf(alice), balanceBefore + USDC_STAKE + USDC_REWARD);
    }

    function testMaturedArvoPositionPaysPrincipalAndReward() public {
        uint256 positionId = _stakeArvo();

        uint256 balanceBefore = arvo.balanceOf(alice);

        _warpToMaturity(positionId);

        vm.prank(alice);

        (uint256 arvoPaid, uint256 usdcPaid) = staking.claim(positionId);

        assertEq(arvoPaid, ARVO_STAKE + ARVO_REWARD);
        assertEq(usdcPaid, 0);

        assertEq(arvo.balanceOf(alice), balanceBefore + ARVO_STAKE + ARVO_REWARD);
    }

    function testClaimAllowedExactlyAtMaturity() public {
        uint256 positionId = _stakeUsdc();

        ArvoStakingTypes.Position memory beforeClaim = staking.position(positionId);

        vm.warp(beforeClaim.maturesAt);

        vm.prank(alice);
        staking.claim(positionId);

        ArvoStakingTypes.Position memory afterClaim = staking.position(positionId);

        assertTrue(afterClaim.settled);
        assertEq(afterClaim.settledAt, beforeClaim.maturesAt);
    }

    function testCannotClaimBeforeMaturity() public {
        uint256 positionId = _stakeUsdc();

        ArvoStakingTypes.Position memory userPosition = staking.position(positionId);

        vm.warp(userPosition.maturesAt - 1);

        vm.prank(alice);
        vm.expectRevert(ArvoStaking.PositionNotMatured.selector);

        staking.claim(positionId);
    }

    function testWrongOwnerCannotClaim() public {
        uint256 positionId = _stakeUsdc();

        _warpToMaturity(positionId);

        vm.prank(attacker);
        vm.expectRevert(ArvoStaking.NotPositionOwner.selector);

        staking.claim(positionId);
    }

    function testCannotClaimNonexistentPosition() public {
        vm.prank(alice);
        vm.expectRevert(ArvoStaking.InvalidPosition.selector);

        staking.claim(type(uint256).max);
    }

    function testCannotClaimPositionTwice() public {
        uint256 positionId = _stakeUsdc();

        _warpToMaturity(positionId);

        vm.prank(alice);
        staking.claim(positionId);

        vm.prank(alice);
        vm.expectRevert(ArvoStaking.PositionAlreadySettled.selector);

        staking.claim(positionId);
    }

    function testMaturedClaimStillWorksWhileProtocolPaused() public {
        uint256 positionId = _stakeUsdc();

        _warpToMaturity(positionId);

        vm.prank(admin);
        staking.pause();

        assertTrue(staking.paused());

        vm.prank(alice);
        staking.claim(positionId);

        ArvoStakingTypes.Position memory userPosition = staking.position(positionId);

        assertTrue(userPosition.settled);
    }

    function testMaturedPositionCanClaimAfterPoolFinalized() public {
        uint256 positionId = _stakeUsdc();

        ArvoStakingTypes.Position memory beforeFinalization = staking.position(positionId);

        assertEq(staking.usdcPrincipalLiability(), USDC_STAKE);
        assertEq(staking.usdcRewardLiability(), USDC_REWARD);

        vm.prank(admin);
        staking.setPoolEnabled(foundationPool, false);

        vm.prank(admin);
        staking.finalizePool(foundationPool);

        ArvoStakingTypes.PoolConfig memory finalizedPool = staking.pool(foundationPool);

        assertTrue(finalizedPool.finalized);
        assertFalse(finalizedPool.enabled);
        assertEq(finalizedPool.usdcRewardBudgetRemaining, 0);

        /*
         * Finalization releases only the unused reward reserve.
         * The reward already committed to this position remains a
         * protected liability until the owner settles it.
         */
        assertEq(staking.usdcPrincipalLiability(), USDC_STAKE);
        assertEq(staking.usdcRewardLiability(), USDC_REWARD);
        assertTrue(staking.isUsdcSolvent());

        vm.warp(beforeFinalization.maturesAt);

        uint256 balanceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        (uint256 arvoPaid, uint256 usdcPaid) = staking.claim(positionId);

        assertEq(arvoPaid, 0);
        assertEq(usdcPaid, USDC_STAKE + USDC_REWARD);
        assertEq(usdc.balanceOf(alice), balanceBefore + USDC_STAKE + USDC_REWARD);

        ArvoStakingTypes.Position memory afterClaim = staking.position(positionId);

        assertTrue(afterClaim.settled);
        assertFalse(afterClaim.emergencyExit);

        assertEq(staking.usdcPrincipalLiability(), 0);
        assertEq(staking.usdcRewardLiability(), 0);
        assertEq(staking.vaultUsdcPrincipal(foundationPool), 0);

        assertTrue(staking.isUsdcSolvent());
    }

    function testClaimClearsCommittedLiabilitiesAndPoolPrincipal() public {
        uint256 positionId = _stakeUsdc();

        assertEq(staking.usdcPrincipalLiability(), USDC_STAKE);
        assertEq(staking.usdcRewardLiability(), USDC_REWARD);
        assertEq(staking.vaultUsdcPrincipal(foundationPool), USDC_STAKE);

        _warpToMaturity(positionId);

        vm.prank(alice);
        staking.claim(positionId);

        assertEq(staking.usdcPrincipalLiability(), 0);
        assertEq(staking.usdcRewardLiability(), 0);
        assertEq(staking.vaultUsdcPrincipal(foundationPool), 0);

        assertTrue(staking.isUsdcSolvent());
    }

    function testClaimDoesNotReleaseUnusedPoolRewardBudget() public {
        uint256 positionId = _stakeUsdc();

        ArvoStakingTypes.PoolConfig memory poolBefore = staking.pool(foundationPool);

        uint256 reservedBefore = staking.usdcRewardBudgetReserved();

        assertEq(poolBefore.usdcRewardBudgetRemaining, USDC_REWARD_BUDGET - USDC_REWARD);

        _warpToMaturity(positionId);

        vm.prank(alice);
        staking.claim(positionId);

        ArvoStakingTypes.PoolConfig memory poolAfter = staking.pool(foundationPool);

        assertEq(poolAfter.usdcRewardBudgetRemaining, poolBefore.usdcRewardBudgetRemaining);

        assertEq(staking.usdcRewardBudgetReserved(), reservedBefore);
    }

    function testClaimMarksPositionSettledWithoutEmergencyExit() public {
        uint256 positionId = _stakeArvo();

        _warpToMaturity(positionId);

        vm.prank(alice);
        staking.claim(positionId);

        ArvoStakingTypes.Position memory userPosition = staking.position(positionId);

        assertTrue(userPosition.settled);
        assertGt(userPosition.settledAt, 0);
        assertFalse(userPosition.emergencyExit);

        assertEq(userPosition.arvoPrincipal, ARVO_STAKE);
        assertEq(userPosition.arvoReward, ARVO_REWARD);
    }

    function testClaimKeepsRewardCapacityAccountingBalanced() public {
        uint256 positionId = _stakeUsdc();

        uint256 freeCapacityBefore = staking.availableUsdcRewardCapacity();

        _warpToMaturity(positionId);

        vm.prank(alice);
        staking.claim(positionId);

        /*
         * Principal + reward leave the contract at the same time their
         * liabilities disappear, so free reward capacity must not change.
         */
        assertEq(staking.availableUsdcRewardCapacity(), freeCapacityBefore);

        assertTrue(staking.isUsdcSolvent());
    }
}
