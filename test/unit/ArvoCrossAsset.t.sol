// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ArvoStaking} from "../../src/ArvoStaking.sol";
import {ArvoStakingBaseline} from "../../src/ArvoStakingBaseline.sol";
import {ArvoStakingTypes as T} from "../../src/ArvoStakingTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockArvoPriceOracle} from "../../src/mocks/MockArvoPriceOracle.sol";
contract ArvoCrossAssetTest is Test {
    ArvoStaking s; MockERC20 a; MockERC20 u; MockArvoPriceOracle o;
    uint32 pool; address alice = address(0x123);
    function setUp() public {
        vm.warp(100000);
        a = new MockERC20("ARVO","ARVO",18); u = new MockERC20("USDC","USDC",6);
        s = ArvoStaking(address(new ERC1967Proxy(address(new ArvoStaking()),abi.encodeCall(ArvoStaking.initialize,(address(a),address(u),address(this))))));
        o = new MockArvoPriceOracle(1e6,6); s.configurePriceOracle(address(o),3600);
        T.VaultConfig memory config;
        pool = s.createProductPool(T.VaultKind.BUILD,config,uint64(vm.getBlockTimestamp()+1),0,0,0,3,150000 ether);
        u.mint(address(this),1000000e6); u.approve(address(s),type(uint256).max); s.fundUsdcRewards(1000000e6); s.reservePoolRewardBudget(pool,0,1000000e6);
        a.mint(alice,1000000 ether); vm.prank(alice); a.approve(address(s),type(uint256).max);
        vm.warp(vm.getBlockTimestamp()+1);
    }
    function stake() internal returns(uint256 id) { vm.prank(alice); return s.stakeArvoForUsdc(pool,150000 ether,3000e6); }
    function testRewardLockedDespiteLaterPriceAndOracleDisable() public {
        uint256 id=stake(); T.Position memory p=s.position(id); assertEq(p.usdcReward,3000e6);
        o.setPrice(2e6); s.configurePriceOracle(address(0),0); assertEq(s.position(id).usdcReward,3000e6);
        vm.warp(p.maturesAt); vm.prank(alice); s.claim(id);
        assertEq(u.balanceOf(alice),3000e6); assertEq(a.balanceOf(alice),1000000 ether); assertEq(s.usdcRewardLiability(),0);
    }
    function testBelowMinimumRejectedWithoutTransfer() public {
        vm.expectRevert(ArvoStaking.BelowMinimum.selector); vm.prank(alice); s.stakeArvoForUsdc(pool,149999 ether,1);
        assertEq(a.balanceOf(alice),1000000 ether);
    }
    function testSlippageRejectedWithoutTransferOrReserveUse() public {
        o.setPrice(5e5); vm.expectRevert(ArvoStaking.RewardBelowMinimum.selector); vm.prank(alice); s.stakeArvoForUsdc(pool,150000 ether,3000e6);
        assertEq(a.balanceOf(alice),1000000 ether); assertEq(s.usdcRewardLiability(),0);
    }
    function testFullBudgetRequired() public {
        uint32 empty=s.createProductPool(T.VaultKind.BUILD,s.vault(pool),uint64(vm.getBlockTimestamp()+1),0,0,0,2,150000 ether);
        vm.warp(vm.getBlockTimestamp()+1);
        vm.expectRevert(); vm.prank(alice); s.stakeArvoForUsdc(empty,150000 ether,3000e6);
        assertEq(a.balanceOf(alice),1000000 ether);
    }
    function testStaleFutureZeroPriceFailClosed() public {
        o.setPriceAndTimestamp(1e6,vm.getBlockTimestamp()-3601); vm.expectRevert(ArvoStaking.InvalidPrice.selector); stake();
        o.setPriceAndTimestamp(1e6,vm.getBlockTimestamp()+1); vm.expectRevert(ArvoStaking.InvalidPrice.selector); stake();
        o.setPriceAndTimestamp(0,vm.getBlockTimestamp()); vm.expectRevert(ArvoStaking.InvalidPrice.selector); stake();
    }
    function testMissingOracleFailsClosed() public { s.configurePriceOracle(address(0),0); vm.expectRevert(ArvoStaking.InvalidPrice.selector); stake(); }
    function testLegacyStakeCannotBypassAcceptedReward() public {
        vm.expectRevert(ArvoStaking.RewardBelowMinimum.selector); vm.prank(alice); s.stake(pool,T.StakeMode.ARVO,T.RewardMode.USDC,150000 ether,0);
    }
    function testExplicitPairRejectsOtherProduct() public {
        uint32 only=s.createProductPool(T.VaultKind.BUILD,s.vault(pool),uint64(vm.getBlockTimestamp()+1),0,0,0,2,150000 ether);
        vm.expectRevert(ArvoStaking.ProductDisabled.selector); vm.prank(alice); s.stake(only,T.StakeMode.ARVO,T.RewardMode.ARVO,150000 ether,0);
    }
    function testReservationCannotBeWithdrawnAsSurplus() public {
        uint256 id=stake(); assertEq(s.availableUsdcRewardCapacity(),0); assertEq(s.usdcRewardLiability(),s.position(id).usdcReward);
        vm.expectRevert(); s.withdrawUsdcSurplus(address(this),1);
    }
    function testMinimumDefaultsAndCustomTerms() public {
        assertEq(s.standardVaultConfig(T.VaultKind.BUILD).minArvo,100000 ether);
        T.VaultConfig memory c=s.vault(pool); c.duration=120 days; c.usdcRewardBps=555; c.minArvo=200000 ether;
        uint32 custom=s.createProductPool(T.VaultKind.CUSTOM,c,uint64(vm.getBlockTimestamp()+1),0,0,0,2,250000 ether);
        assertEq(s.vault(custom).duration,120 days); assertEq(s.vault(custom).usdcRewardBps,555); assertEq(s.minArvoForUsdc(custom),250000 ether);
    }
    function testVisibilityAndDepositsIndependentWithRoleProtection() public {
        s.setPoolVisibility(pool,1); assertEq(s.poolVisibility(pool),1); assertTrue(s.pool(pool).enabled);
        vm.expectRevert(); vm.prank(alice); s.setPoolVisibility(pool,2);
        s.setPoolEnabled(pool,false); vm.expectRevert(); stake();
    }
    function testCrossRestakeFailsClosedWithoutAcceptanceEntrypoint() public {
        uint256 id=stake(); vm.warp(s.position(id).maturesAt); o.setPrice(2e6);
        vm.expectRevert(ArvoStaking.RewardBelowMinimum.selector); vm.prank(alice); s.restakePrincipal(id,pool,T.RewardMode.USDC);
        assertFalse(s.position(id).settled);
    }
    function testUpgradeKeepsLiveLegacyPositionAndItsReward() public {
        ArvoStakingBaseline old=ArvoStakingBaseline(address(new ERC1967Proxy(address(new ArvoStakingBaseline()),abi.encodeCall(ArvoStakingBaseline.initialize,(address(a),address(u),address(this))))));
        uint32 legacy=old.createStandardPool(T.VaultKind.BUILD,uint64(vm.getBlockTimestamp()+1),0,0,0,true,false,false,true,false);
        a.mint(address(this),1000 ether); a.approve(address(old),type(uint256).max); old.fundArvoRewards(1000 ether); old.reservePoolRewardBudget(legacy,1000 ether,0);
        vm.warp(vm.getBlockTimestamp()+1);
        vm.startPrank(alice); a.approve(address(old),type(uint256).max); uint256 id=old.stake(legacy,T.StakeMode.ARVO,T.RewardMode.ARVO,1000 ether,0); vm.stopPrank();
        old.upgradeToAndCall(address(new ArvoStaking()),""); ArvoStaking upgraded=ArvoStaking(address(old));
        assertEq(upgraded.position(id).arvoReward,30 ether); assertEq(upgraded.vault(legacy).minArvo,1000 ether);
        vm.warp(upgraded.position(id).maturesAt); vm.prank(alice); upgraded.claim(id); assertTrue(upgraded.position(id).settled);
    }
}
