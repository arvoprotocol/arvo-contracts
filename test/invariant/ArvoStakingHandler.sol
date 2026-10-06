// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";

import { ArvoStaking } from "../../src/ArvoStaking.sol";
import { ArvoStakingTypes } from "../../src/ArvoStakingTypes.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";

contract ArvoStakingHandler is Test {
    ArvoStaking public staking;
    MockERC20 public arvo;
    MockERC20 public usdc;

    address public admin;
    uint32 public poolId;

    address[] internal users;
    uint256[] internal positionIds;

    uint256 public successfulClaims;
    uint256 public successfulRestakes;
    uint256 public successfulCompounds;
    uint256 public successfulEmergencyExits;

    constructor(
        ArvoStaking staking_,
        MockERC20 arvo_,
        MockERC20 usdc_,
        address admin_,
        uint32 poolId_
    ) {
        staking = staking_;
        arvo = arvo_;
        usdc = usdc_;
        admin = admin_;
        poolId = poolId_;

        users.push(address(0x1001));
        users.push(address(0x1002));
        users.push(address(0x1003));
        users.push(address(0x1004));

        for (uint256 i = 0; i < users.length; i++) {
            arvo.mint(users[i], 1000000000 ether);
            usdc.mint(users[i], 10_000_000e6);

            vm.startPrank(users[i]);

            arvo.approve(address(staking), type(uint256).max);
            usdc.approve(address(staking), type(uint256).max);

            vm.stopPrank();
        }
    }

    function stakeArvo(uint256 userSeed, uint256 amountSeed) external {
        address user = users[userSeed % users.length];

        uint256 amount = bound(amountSeed, 100000 ether, 10000000 ether);

        vm.prank(user);

        try staking.stake(
            poolId, ArvoStakingTypes.StakeMode.ARVO, ArvoStakingTypes.RewardMode.ARVO, amount, 0
        ) returns (
            uint256 positionId
        ) {
            positionIds.push(positionId);
        } catch { }
    }

    function stakeUsdc(uint256 userSeed, uint256 amountSeed) external {
        address user = users[userSeed % users.length];

        uint256 amount = bound(amountSeed, 1_000e6, 100_000e6);

        vm.prank(user);

        try staking.stake(
            poolId, ArvoStakingTypes.StakeMode.USDC, ArvoStakingTypes.RewardMode.USDC, 0, amount
        ) returns (
            uint256 positionId
        ) {
            positionIds.push(positionId);
        } catch { }
    }

    function stakeDualArvoReward(uint256 userSeed, uint256 arvoSeed, uint256 usdcSeed) external {
        address user = users[userSeed % users.length];

        uint256 arvoAmount = bound(arvoSeed, 100000 ether, 10000000 ether);

        uint256 usdcAmount = bound(usdcSeed, 1_000e6, 100_000e6);

        vm.prank(user);

        try staking.stake(
            poolId,
            ArvoStakingTypes.StakeMode.DUAL,
            ArvoStakingTypes.RewardMode.ARVO,
            arvoAmount,
            usdcAmount
        ) returns (
            uint256 positionId
        ) {
            positionIds.push(positionId);
        } catch { }
    }

    function claimMaturedPosition(uint256 positionSeed) external {
        if (positionIds.length == 0) {
            return;
        }

        uint256 positionId = positionIds[positionSeed % positionIds.length];

        ArvoStakingTypes.Position memory userPosition = staking.position(positionId);

        if (userPosition.owner == address(0) || userPosition.settled) {
            return;
        }

        if (vm.getBlockTimestamp() < userPosition.maturesAt) {
            vm.warp(userPosition.maturesAt);
        }

        vm.prank(userPosition.owner);

        try staking.claim(positionId) {
            successfulClaims++;
        } catch { }
    }

    function restakeMaturedPosition(uint256 positionSeed, uint256 rewardModeSeed) external {
        if (positionIds.length == 0) {
            return;
        }

        uint256 positionId = positionIds[positionSeed % positionIds.length];

        ArvoStakingTypes.Position memory userPosition = staking.position(positionId);

        if (userPosition.owner == address(0) || userPosition.settled) {
            return;
        }

        if (vm.getBlockTimestamp() < userPosition.maturesAt) {
            vm.warp(userPosition.maturesAt);
        }

        /*
         * Exercise both same-asset reward choices. Some combinations
         * deliberately revert under the current no-oracle rules; those
         * failures must leave the existing position/accounting intact.
         */
        ArvoStakingTypes.RewardMode rewardMode = rewardModeSeed % 2 == 0
            ? ArvoStakingTypes.RewardMode.ARVO
            : ArvoStakingTypes.RewardMode.USDC;

        vm.prank(userPosition.owner);

        try staking.restakePrincipal(positionId, poolId, rewardMode) returns (
            uint256 newPositionId
        ) {
            positionIds.push(newPositionId);
            successfulRestakes++;
        } catch { }
    }

    function compoundMaturedPosition(uint256 positionSeed, uint256 rewardModeSeed) external {
        if (positionIds.length == 0) {
            return;
        }

        uint256 positionId = positionIds[positionSeed % positionIds.length];

        ArvoStakingTypes.Position memory userPosition = staking.position(positionId);

        if (userPosition.owner == address(0) || userPosition.settled) {
            return;
        }

        if (vm.getBlockTimestamp() < userPosition.maturesAt) {
            vm.warp(userPosition.maturesAt);
        }

        /*
         * Exercise both supported next-cycle reward choices.
         *
         * Single-asset positions may reject the opposite reward asset
         * under the no-oracle rules. DUAL positions can validly choose
         * either ARVO or USDC for the successor cycle.
         *
         * Any rejected Compound attempt must leave the matured position
         * and all accounting unchanged.
         */
        ArvoStakingTypes.RewardMode rewardMode = rewardModeSeed % 2 == 0
            ? ArvoStakingTypes.RewardMode.ARVO
            : ArvoStakingTypes.RewardMode.USDC;

        vm.prank(userPosition.owner);

        try staking.compound(positionId, poolId, rewardMode) returns (uint256 newPositionId) {
            positionIds.push(newPositionId);
            successfulCompounds++;
        } catch { }
    }

    function emergencyExitUnmaturedPosition(uint256 userSeed, uint256 amountSeed) external {
        address user = users[userSeed % users.length];

        /*
         * Create a fresh position at the current fuzz timestamp so this
         * action always has an unmatured candidate even after another
         * handler has advanced time to settle older positions.
         */
        uint256 amount = bound(amountSeed, 100000 ether, 10000000 ether);

        vm.prank(user);

        uint256 positionId = type(uint256).max;

        try staking.stake(
            poolId, ArvoStakingTypes.StakeMode.ARVO, ArvoStakingTypes.RewardMode.ARVO, amount, 0
        ) returns (
            uint256 newPositionId
        ) {
            positionId = newPositionId;
            positionIds.push(newPositionId);
        } catch {
            return;
        }

        ArvoStakingTypes.Position memory userPosition = staking.position(positionId);

        if (
            userPosition.owner == address(0) || userPosition.settled
                || vm.getBlockTimestamp() >= userPosition.maturesAt
        ) {
            return;
        }

        /*
         * The admin only enables the emergency state. The position owner
         * must pull their own principal.
         */
        vm.prank(admin);

        try staking.pause() { }
        catch {
            return;
        }

        vm.prank(user);

        try staking.emergencyExit(positionId) {
            successfulEmergencyExits++;
        } catch { }

        /*
         * Restore normal operation so subsequent invariant actions can
         * continue exercising the rest of the protocol.
         */
        vm.prank(admin);

        try staking.unpause() { } catch { }
    }

    function fundArvo(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 100 ether, 100000000 ether);

        arvo.mint(admin, amount);

        vm.startPrank(admin);

        arvo.approve(address(staking), amount);

        try staking.fundArvoRewards(amount) { } catch { }

        vm.stopPrank();
    }

    function fundUsdc(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1e6, 1_000_000e6);

        usdc.mint(admin, amount);

        vm.startPrank(admin);

        usdc.approve(address(staking), amount);

        try staking.fundUsdcRewards(amount) { } catch { }

        vm.stopPrank();
    }

    function withdrawArvoSurplus(uint256 amountSeed) external {
        uint256 available = staking.availableArvoRewardCapacity();

        if (available == 0) {
            return;
        }

        uint256 amount = bound(amountSeed, 1, available);

        vm.prank(admin);

        try staking.withdrawArvoSurplus(admin, amount) { } catch { }
    }

    function withdrawUsdcSurplus(uint256 amountSeed) external {
        uint256 available = staking.availableUsdcRewardCapacity();

        if (available == 0) {
            return;
        }

        uint256 amount = bound(amountSeed, 1, available);

        vm.prank(admin);

        try staking.withdrawUsdcSurplus(admin, amount) { } catch { }
    }

    function trackedPositionCount() external view returns (uint256) {
        return positionIds.length;
    }
}
