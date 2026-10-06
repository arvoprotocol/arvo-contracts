// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { ArvoStaking } from "../../src/ArvoStaking.sol";
import { ArvoStakingTypes } from "../../src/ArvoStakingTypes.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";
import { MockReentrantToken } from "../../src/mocks/MockReentrantToken.sol";

contract ArvoStakingReentrancyTest is Test {
    address internal admin = address(0xA11CE);
    address internal user = address(0xB0B);

    MockReentrantToken internal arvo;
    MockERC20 internal usdc;
    ArvoStaking internal staking;

    uint32 internal poolId;

    function setUp() public {
        arvo = new MockReentrantToken("Arvo", "ARVO", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        ArvoStaking implementation = new ArvoStaking();

        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                ArvoStaking.initialize,
                (address(arvo), address(usdc), admin)
            )
        );

        staking = ArvoStaking(address(proxy));

        /*
         * Seed reward capital directly so attack behaviour is isolated
         * from the reward-funding path.
         */
        arvo.mint(address(staking), 100000000 ether);

        vm.prank(admin);
        poolId = staking.createStandardPool(
            ArvoStakingTypes.VaultKind.FOUNDATION,
            uint64(vm.getBlockTimestamp() + 1),
            0,
            0,
            0,
            true,
            false,
            false,
            true,
            false
        );

        vm.prank(admin);
        staking.reservePoolRewardBudget(poolId, 50000000 ether, 0);

        arvo.mint(user, 10000000 ether);

        vm.prank(user);
        arvo.approve(address(staking), type(uint256).max);

        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function testReentrantStakeCallbackIsBlocked() public {
        uint256 amount = 1000000 ether;

        bytes memory nestedStake = abi.encodeCall(
            ArvoStaking.stake,
            (
                poolId,
                ArvoStakingTypes.StakeMode.ARVO,
                ArvoStakingTypes.RewardMode.ARVO,
                amount,
                0
            )
        );

        arvo.configureAttack(address(staking), nestedStake);
        arvo.setAttackEnabled(true);

        vm.prank(user);
        uint256 positionId = staking.stake(
            poolId,
            ArvoStakingTypes.StakeMode.ARVO,
            ArvoStakingTypes.RewardMode.ARVO,
            amount,
            0
        );

        assertTrue(arvo.callbackAttempted());
        assertFalse(arvo.callbackSucceeded());

        assertEq(positionId, 1);
        assertEq(staking.nextPositionId(), 2);
        assertEq(staking.userPositionIds(user).length, 1);
        assertEq(staking.arvoPrincipalLiability(), amount);

        ArvoStakingTypes.Position memory p = staking.position(positionId);

        assertEq(p.owner, user);
        assertEq(p.arvoPrincipal, amount);
        assertFalse(p.settled);
        assertTrue(staking.isArvoSolvent());
    }

    function testReentrantClaimCallbackIsBlocked() public {
        uint256 amount = 1000000 ether;

        vm.prank(user);
        uint256 positionId = staking.stake(
            poolId,
            ArvoStakingTypes.StakeMode.ARVO,
            ArvoStakingTypes.RewardMode.ARVO,
            amount,
            0
        );

        ArvoStakingTypes.Position memory beforeClaim =
            staking.position(positionId);

        vm.warp(beforeClaim.maturesAt);

        bytes memory nestedClaim =
            abi.encodeCall(ArvoStaking.claim, (positionId));

        arvo.configureAttack(address(staking), nestedClaim);
        arvo.resetAttackResult();
        arvo.setAttackEnabled(true);

        uint256 balanceBefore = arvo.balanceOf(user);

        vm.prank(user);
        (uint256 arvoPaid,) = staking.claim(positionId);

        assertTrue(arvo.callbackAttempted());
        assertFalse(arvo.callbackSucceeded());

        ArvoStakingTypes.Position memory afterClaim =
            staking.position(positionId);

        assertTrue(afterClaim.settled);
        assertFalse(afterClaim.emergencyExit);

        assertEq(arvo.balanceOf(user), balanceBefore + arvoPaid);
        assertEq(staking.arvoPrincipalLiability(), 0);
        assertEq(staking.arvoRewardLiability(), 0);
        assertEq(staking.vaultArvoPrincipal(poolId), 0);

        assertTrue(staking.isArvoSolvent());
    }

    function testReentrantRewardFundingCallbackIsBlocked() public {
        uint256 amount = 2500000 ether;

        arvo.mint(admin, amount);

        vm.prank(admin);
        arvo.approve(address(staking), type(uint256).max);

        bytes memory nestedFunding =
            abi.encodeCall(ArvoStaking.fundArvoRewards, (amount));

        arvo.configureAttack(address(staking), nestedFunding);
        arvo.resetAttackResult();
        arvo.setAttackEnabled(true);

        uint256 stakingBalanceBefore = arvo.balanceOf(address(staking));

        vm.prank(admin);
        staking.fundArvoRewards(amount);

        assertTrue(arvo.callbackAttempted());
        assertFalse(arvo.callbackSucceeded());

        assertEq(
            arvo.balanceOf(address(staking)),
            stakingBalanceBefore + amount
        );

        assertTrue(staking.isArvoSolvent());
    }
}
