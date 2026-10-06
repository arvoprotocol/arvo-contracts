// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {ArvoCrossAssetTest} from "../unit/ArvoCrossAsset.t.sol";
import {ArvoStaking} from "../../src/ArvoStaking.sol";
import {ArvoStakingTypes as T} from "../../src/ArvoStakingTypes.sol";
contract ArvoEarlyCloseTest is ArvoCrossAssetTest {
    function testEarlyClosePreservesExistingCrossAssetPayout() public {
        uint256 id = stake();
        T.Position memory beforeClose = s.position(id);
        s.setPoolEnabled(pool, false);
        vm.expectRevert(ArvoStaking.PoolClosed.selector);
        vm.prank(alice);
        s.stakeArvoForUsdc(pool, 150_000 ether, 3_000e6);
        assertEq(s.position(id).maturesAt, beforeClose.maturesAt);
        assertEq(s.position(id).usdcReward, beforeClose.usdcReward);
        vm.warp(beforeClose.maturesAt);
        vm.prank(alice); s.claim(id);
        assertEq(u.balanceOf(alice), 3_000e6);
        assertEq(a.balanceOf(alice), 1_000_000 ether);
    }
    function testEarlyClosePreservesExistingArvoPayout() public {
        a.mint(address(this), 3_000 ether);
        a.approve(address(s), type(uint256).max);
        s.fundArvoRewards(3_000 ether);
        uint64 opens = uint64(block.timestamp + 1);
        T.VaultConfig memory config;
        uint32 arvoPool = s.createProductPool(T.VaultKind.BUILD,config,opens,opens+5 days,100_000 ether,0,1,0);
        s.reservePoolRewardBudget(arvoPool,3_000 ether,0);
        vm.warp(opens);
        vm.prank(alice);
        uint256 id = s.stake(arvoPool,T.StakeMode.ARVO,T.RewardMode.ARVO,100_000 ether,0);
        s.setPoolEnabled(arvoPool,false);
        vm.expectRevert(ArvoStaking.PoolClosed.selector);
        vm.prank(alice);
        s.stake(arvoPool,T.StakeMode.ARVO,T.RewardMode.ARVO,100_000 ether,0);
        vm.warp(s.position(id).maturesAt);
        vm.prank(alice);s.claim(id);
        assertEq(a.balanceOf(alice),1_003_000 ether);
    }
}
