// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";

import { ArvoStaking } from "../../src/ArvoStaking.sol";
import { ArvoStakingTypes } from "../../src/ArvoStakingTypes.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";

contract ArvoStakingEmergencyTest is Test {
    ArvoStaking internal staking;
    MockERC20 internal arvo;
    MockERC20 internal usdc;

    address internal admin = address(0xA11CE);
    address internal alice = address(0xB0B);
    address internal bob = address(0xB0B2);

    uint32 internal poolId;

    uint256 internal constant ARVO_PRINCIPAL = 1000000 ether;
    uint256 internal constant USDC_PRINCIPAL = 10_000e6;
    uint256 internal constant REWARD_RESERVE_ARVO = 100000000 ether;
    uint256 internal constant REWARD_RESERVE_USDC = 1_000_000e6;

    function setUp() public {
        arvo = new MockERC20("Arvo", "ARVO", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        staking = new ArvoStaking();

        // ArvoStaking disables initialization on the implementation, so use
        // the implementation code behind a simple ERC1967 proxy as the other
        // production-style tests do.
        bytes memory initData =
            abi.encodeCall(ArvoStaking.initialize, (address(arvo), address(usdc), admin));

        address implementation = address(staking);

        // Deploy the same minimal proxy helper used below.
        EmergencyTestProxy proxy = new EmergencyTestProxy(implementation, initData);
        staking = ArvoStaking(address(proxy));

        arvo.mint(admin, REWARD_RESERVE_ARVO);
        usdc.mint(admin, REWARD_RESERVE_USDC);

        vm.startPrank(admin);
        arvo.approve(address(staking), type(uint256).max);
        usdc.approve(address(staking), type(uint256).max);

        staking.fundArvoRewards(REWARD_RESERVE_ARVO);
        staking.fundUsdcRewards(REWARD_RESERVE_USDC);

        uint64 opensAt = uint64(vm.getBlockTimestamp() + 1);
        poolId = staking.createStandardPool(
            ArvoStakingTypes.VaultKind.FOUNDATION,
            opensAt,
            0,
            10000000 ether,
            100_000e6,
            true,
            true,
            true,
            true,
            true
        );

        staking.reservePoolRewardBudget(poolId, 10000000 ether, 100_000e6);
        vm.stopPrank();

        vm.warp(opensAt);

        arvo.mint(alice, 10000000 ether);
        usdc.mint(alice, 100_000e6);

        vm.startPrank(alice);
        arvo.approve(address(staking), type(uint256).max);
        usdc.approve(address(staking), type(uint256).max);
        vm.stopPrank();
    }

    function _stakeArvo() internal returns (uint256 positionId) {
        vm.prank(alice);
        positionId = staking.stake(
            poolId,
            ArvoStakingTypes.StakeMode.ARVO,
            ArvoStakingTypes.RewardMode.ARVO,
            ARVO_PRINCIPAL,
            0
        );
    }

    function _stakeUsdc() internal returns (uint256 positionId) {
        vm.prank(alice);
        positionId = staking.stake(
            poolId,
            ArvoStakingTypes.StakeMode.USDC,
            ArvoStakingTypes.RewardMode.USDC,
            0,
            USDC_PRINCIPAL
        );
    }

    function _stakeDual() internal returns (uint256 positionId) {
        vm.prank(alice);
        positionId = staking.stake(
            poolId,
            ArvoStakingTypes.StakeMode.DUAL,
            ArvoStakingTypes.RewardMode.ARVO,
            ARVO_PRINCIPAL,
            USDC_PRINCIPAL
        );
    }

    function _pause() internal {
        vm.prank(admin);
        staking.pause();
    }

    function testEmergencyExitRequiresPause() public {
        uint256 positionId = _stakeArvo();

        vm.expectRevert(ArvoStaking.EmergencyExitOnlyWhilePaused.selector);
        vm.prank(alice);
        staking.emergencyExit(positionId);

        ArvoStakingTypes.Position memory p = staking.position(positionId);
        assertFalse(p.settled);
        assertFalse(p.emergencyExit);
    }

    function testEmergencyExitRejectsNonexistentPosition() public {
        _pause();

        vm.expectRevert(ArvoStaking.InvalidPosition.selector);
        vm.prank(alice);
        staking.emergencyExit(type(uint256).max);
    }

    function testEmergencyExitRejectsWrongOwner() public {
        uint256 positionId = _stakeArvo();
        _pause();

        vm.expectRevert(ArvoStaking.NotPositionOwner.selector);
        vm.prank(bob);
        staking.emergencyExit(positionId);

        ArvoStakingTypes.Position memory p = staking.position(positionId);
        assertFalse(p.settled);
    }

    function testEmergencyExitReturnsArvoPrincipalOnly() public {
        uint256 positionId = _stakeArvo();

        ArvoStakingTypes.Position memory beforePosition = staking.position(positionId);
        uint256 reward = beforePosition.arvoReward;

        uint256 aliceBefore = arvo.balanceOf(alice);
        uint256 contractBefore = arvo.balanceOf(address(staking));

        assertGt(reward, 0);

        _pause();

        vm.prank(alice);
        (uint256 arvoPaid, uint256 usdcPaid) = staking.emergencyExit(positionId);

        assertEq(arvoPaid, ARVO_PRINCIPAL);
        assertEq(usdcPaid, 0);

        assertEq(arvo.balanceOf(alice), aliceBefore + ARVO_PRINCIPAL);
        assertEq(arvo.balanceOf(address(staking)), contractBefore - ARVO_PRINCIPAL);

        // Reward stays in the contract and is no longer a committed liability.
        assertEq(staking.arvoRewardLiability(), 0);
        assertEq(staking.arvoPrincipalLiability(), 0);
        assertEq(staking.vaultArvoPrincipal(poolId), 0);

        ArvoStakingTypes.Position memory afterPosition = staking.position(positionId);
        assertTrue(afterPosition.settled);
        assertTrue(afterPosition.emergencyExit);
        assertGt(afterPosition.settledAt, 0);

        // Historical snapshot remains intact.
        assertEq(afterPosition.arvoPrincipal, ARVO_PRINCIPAL);
        assertEq(afterPosition.arvoReward, reward);

        assertTrue(staking.isArvoSolvent());
    }

    function testEmergencyExitReturnsUsdcPrincipalOnly() public {
        uint256 positionId = _stakeUsdc();

        ArvoStakingTypes.Position memory beforePosition = staking.position(positionId);
        uint256 reward = beforePosition.usdcReward;
        uint256 aliceBefore = usdc.balanceOf(alice);

        assertGt(reward, 0);

        _pause();

        vm.prank(alice);
        (uint256 arvoPaid, uint256 usdcPaid) = staking.emergencyExit(positionId);

        assertEq(arvoPaid, 0);
        assertEq(usdcPaid, USDC_PRINCIPAL);
        assertEq(usdc.balanceOf(alice), aliceBefore + USDC_PRINCIPAL);

        assertEq(staking.usdcRewardLiability(), 0);
        assertEq(staking.usdcPrincipalLiability(), 0);
        assertEq(staking.vaultUsdcPrincipal(poolId), 0);

        ArvoStakingTypes.Position memory afterPosition = staking.position(positionId);
        assertTrue(afterPosition.settled);
        assertTrue(afterPosition.emergencyExit);
        assertEq(afterPosition.usdcReward, reward);

        assertTrue(staking.isUsdcSolvent());
    }

    function testEmergencyExitDualReturnsBothPrincipalAssetsAndNoReward() public {
        uint256 positionId = _stakeDual();

        ArvoStakingTypes.Position memory beforePosition = staking.position(positionId);
        assertGt(beforePosition.arvoReward, 0);
        assertEq(beforePosition.usdcReward, 0);

        uint256 aliceArvoBefore = arvo.balanceOf(alice);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        _pause();

        vm.prank(alice);
        (uint256 arvoPaid, uint256 usdcPaid) = staking.emergencyExit(positionId);

        assertEq(arvoPaid, ARVO_PRINCIPAL);
        assertEq(usdcPaid, USDC_PRINCIPAL);

        assertEq(arvo.balanceOf(alice), aliceArvoBefore + ARVO_PRINCIPAL);
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + USDC_PRINCIPAL);

        assertEq(staking.arvoPrincipalLiability(), 0);
        assertEq(staking.usdcPrincipalLiability(), 0);
        assertEq(staking.arvoRewardLiability(), 0);

        assertEq(staking.vaultArvoPrincipal(poolId), 0);
        assertEq(staking.vaultUsdcPrincipal(poolId), 0);

        assertTrue(staking.isArvoSolvent());
        assertTrue(staking.isUsdcSolvent());
    }

    function testEmergencyExitCannotBeUsedTwice() public {
        uint256 positionId = _stakeArvo();
        _pause();

        vm.prank(alice);
        staking.emergencyExit(positionId);

        vm.expectRevert(ArvoStaking.PositionAlreadySettled.selector);
        vm.prank(alice);
        staking.emergencyExit(positionId);
    }

    function testEmergencyExitCannotBeUsedAtMaturity() public {
        uint256 positionId = _stakeArvo();
        ArvoStakingTypes.Position memory p = staking.position(positionId);

        vm.warp(p.maturesAt);
        _pause();

        vm.expectRevert(ArvoStaking.EmergencyExitPositionMatured.selector);
        vm.prank(alice);
        staking.emergencyExit(positionId);

        // Normal matured claim remains available while paused.
        uint256 beforeBalance = arvo.balanceOf(alice);

        vm.prank(alice);
        staking.claim(positionId);

        assertEq(arvo.balanceOf(alice), beforeBalance + p.arvoPrincipal + p.arvoReward);
    }

    function testEmergencyExitCannotBeUsedAfterMaturity() public {
        uint256 positionId = _stakeUsdc();
        ArvoStakingTypes.Position memory p = staking.position(positionId);

        vm.warp(uint256(p.maturesAt) + 1);
        _pause();

        vm.expectRevert(ArvoStaking.EmergencyExitPositionMatured.selector);
        vm.prank(alice);
        staking.emergencyExit(positionId);

        ArvoStakingTypes.Position memory afterPosition = staking.position(positionId);
        assertFalse(afterPosition.settled);
    }

    function testEmergencyExitCannotSettleAlreadyClaimedPosition() public {
        uint256 positionId = _stakeArvo();
        ArvoStakingTypes.Position memory p = staking.position(positionId);

        vm.warp(p.maturesAt);

        vm.prank(alice);
        staking.claim(positionId);

        _pause();

        vm.expectRevert(ArvoStaking.PositionAlreadySettled.selector);
        vm.prank(alice);
        staking.emergencyExit(positionId);
    }

    function testEmergencyExitPreservesSolvencyAndCreatesOnlyTrueSurplus() public {
        uint256 positionId = _stakeArvo();

        ArvoStakingTypes.Position memory p = staking.position(positionId);

        uint256 surplusBefore = staking.availableArvoRewardCapacity();

        _pause();

        vm.prank(alice);
        staking.emergencyExit(positionId);

        uint256 surplusAfter = staking.availableArvoRewardCapacity();

        // Forfeited committed reward becomes free reward capacity.
        assertEq(surplusAfter, surplusBefore + p.arvoReward);

        assertTrue(staking.isArvoSolvent());
        assertTrue(staking.isUsdcSolvent());
    }

    function testAdminCannotEmergencyExitUsersPosition() public {
        uint256 positionId = _stakeArvo();
        _pause();

        vm.expectRevert(ArvoStaking.NotPositionOwner.selector);
        vm.prank(admin);
        staking.emergencyExit(positionId);

        ArvoStakingTypes.Position memory p = staking.position(positionId);
        assertFalse(p.settled);
        assertEq(staking.arvoPrincipalLiability(), ARVO_PRINCIPAL);
    }
}

/*
 * Minimal ERC1967-compatible proxy for this focused unit test.
 * Storage slot is the ERC1967 implementation slot.
 */
contract EmergencyTestProxy {
    bytes32 private constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    constructor(address implementation, bytes memory data) payable {
        assembly {
            sstore(IMPLEMENTATION_SLOT, implementation)
        }

        (bool success, bytes memory reason) = implementation.delegatecall(data);

        if (!success) {
            assembly {
                revert(add(reason, 32), mload(reason))
            }
        }
    }

    fallback() external payable {
        assembly {
            let implementation := sload(IMPLEMENTATION_SLOT)
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), implementation, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())

            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}
