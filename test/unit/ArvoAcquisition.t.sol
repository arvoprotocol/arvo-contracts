// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ArvoStaking} from "../../src/ArvoStaking.sol";
import {ArvoAcquisitionEscrow} from "../../src/ArvoAcquisitionEscrow.sol";
import {ArvoStakingTypes as T} from "../../src/ArvoStakingTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract AcquisitionTreasuryMock { }
contract ArvoAcquisitionTest is Test {
    ArvoStaking s;
    ArvoAcquisitionEscrow e;
    MockERC20 a;
    MockERC20 u;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address treasury;
    uint32 pool;
    uint64 opens;
    function setUp() public {
        a = new MockERC20("Test Arvo", "ARVO", 18);
        u = new MockERC20("Test USD", "USDC", 6);
        s = ArvoStaking(address(new ERC1967Proxy(address(new ArvoStaking()),
            abi.encodeCall(ArvoStaking.initialize,(address(a), address(u),address(this))))));
        treasury = address(new AcquisitionTreasuryMock());
        e=new ArvoAcquisitionEscrow(address(s),address(u));
        s.configureAcquisitionEscrow(e);

        u.mint(address(this),1_000_000e6);
        a.mint(address(this),1_000_000 ether);
        u.approve(address(s),type(uint256).max); u.approve(address(e),type(uint256).max);
        a.approve(address(s),type(uint256).max);
        a.mint(alice,10_000 ether); u.mint(alice,10_000e6);
        a.mint(bob,10_000 ether); u.mint(bob,10_000e6);
        vm.startPrank(alice); a.approve(address(s),type(uint256).max); u.approve(address(s),type(uint256).max); vm.stopPrank();
        vm.startPrank(bob); a.approve(address(s),type(uint256).max); u.approve(address(s),type(uint256).max); vm.stopPrank();
        opens = uint64(block.timestamp + 10);
        pool = newPool(4,60 days);
        s.configureAcquisitionPool(pool,treasury);
        s.addAcquisitionRewardLimit(pool,1000e6);
    }
    function cfg(uint32 duration) internal pure returns (T.VaultConfig memory c) {
        c = T.VaultConfig(duration,1000,1000,1000,1500,5000,500 ether,500e6,
            false,true,false,false,true,false);
    }
    function newPool(uint8 products,uint32 duration) internal returns (uint32) {
        return s.createProductPool(T.VaultKind.CUSTOM,cfg(duration), opens,opens + 5 days,
            100_000 ether,10_000e6,products,0);
    }
    function release(uint32 id,uint256 amount) internal {
        vm.prank(treasury); e.releasePrincipal(id,amount);
    }
    function withdrawExcess(uint32 id,uint256 amount) internal {
        vm.prank(treasury); e.withdrawExcess(id,amount);
    }
    function deposit(address who,uint256 amount) internal returns (uint256 id) {
        vm.prank(who); id = s.stake(pool,T.StakeMode.USDC,T.RewardMode.USDC,0,amount);
    }
    function cash(uint32 id) internal view returns (uint256 liquid,uint256 debt) {
        (,,,,liquid,,debt,,)=e.accounts(id);
    }
    function testIndividualMaturityAndExactPayout() public {
        vm.warp(opens); uint256 x=deposit(alice,1000e6);
        vm.warp(opens+1 days); uint256 y=deposit(bob,1000e6);
        assertEq(s.position(x).maturesAt,opens+60 days);
        assertEq(s.position(y).maturesAt,opens+61 days);
        release(pool,2000e6);
        assertEq(u.balanceOf(treasury),2000e6);
        assertEq(s.usdcPrincipalLiability(),2000e6);
        assertEq(s.usdcRewardLiability(),200e6);
        e.repay(pool,2200e6);
        vm.warp(opens+60 days);
        vm.prank(alice); (,uint256 paid)=s.claim(x); assertEq(paid,1100e6);
        vm.prank(bob); vm.expectRevert(ArvoStaking.PositionNotMatured.selector); s.claim(y);
        vm.warp(opens+61 days); vm.prank(bob); s.claim(y);
        assertEq(s.acquisitionUsdcPrincipal(),0); assertEq(s.acquisitionUsdcRewards(),0);
        assertEq(e.totalCash(),0);
    }
    function testUnfundedClaimLeavesPositionAndDebtUnchanged() public {
        vm.warp(opens); uint256 x=deposit(alice,1000e6);
        release(pool,1000e6);
        vm.warp(opens+60 days);
        vm.prank(alice); vm.expectRevert(ArvoAcquisitionEscrow.LiquidityUnavailable.selector); s.claim(x);
        assertFalse(s.position(x).settled); assertEq(s.usdcPrincipalLiability(),1000e6);
        e.repay(pool,1000e6);
        vm.prank(alice); vm.expectRevert(ArvoAcquisitionEscrow.LiquidityUnavailable.selector); s.claim(x);
        e.repay(pool,100e6); vm.prank(alice); s.claim(x);
    }
    function testOrdinaryReservesCannotFundAcquisitionClaim() public {
        s.fundUsdcRewards(5000e6);
        vm.warp(opens); uint256 x=deposit(alice,1000e6); release(pool,1000e6);
        assertEq(s.availableUsdcRewardCapacity(),5000e6);
        vm.warp(opens+60 days); vm.prank(alice);
        vm.expectRevert(ArvoAcquisitionEscrow.LiquidityUnavailable.selector); s.claim(x);
        s.withdrawUsdcSurplus(address(this),5000e6);
        assertEq(u.balanceOf(address(s)),0);
    }
    function testAcquisitionCashCannotBeWithdrawnAsOrdinarySurplus() public {
        vm.warp(opens); deposit(alice,1000e6);
        assertEq(s.availableUsdcRewardCapacity(),0);
        vm.expectRevert(ArvoStaking.InsufficientSurplus.selector); s.withdrawUsdcSurplus(address(this),1);
        e.repay(pool,100e6);
        assertEq(s.availableUsdcRewardCapacity(),0);
    }
    function testPoolsHaveSeparateRepayments() public {
        uint32 other=newPool(4,60 days);
        s.configureAcquisitionPool(other,treasury); s.addAcquisitionRewardLimit(other,1000e6);
        vm.warp(opens); uint256 x=deposit(alice,1000e6); release(pool,1000e6);
        e.repay(other,1100e6);
        vm.warp(opens+60 days); vm.prank(alice);
        vm.expectRevert(ArvoAcquisitionEscrow.LiquidityUnavailable.selector); s.claim(x);
    }
    function testPartialRepaymentTracksDebt() public {
        vm.warp(opens); deposit(alice,1000e6); release(pool,1000e6);
        e.repay(pool,400e6);
        (uint256 liquid,uint256 debt)=cash(pool); assertEq(liquid,400e6); assertEq(debt,600e6);
        assertEq(s.usdcPrincipalLiability(),1000e6);
    }
    function testReleaseAllowedAfterMaturityButBlockedWhilePaused() public {
        vm.warp(opens); deposit(alice,1000e6);
        s.pause(); vm.expectRevert(); release(pool,100e6);
        s.unpause(); vm.warp(opens+60 days);
        release(pool,100e6);
        (uint256 liquid,uint256 debt)=cash(pool);
        assertEq(liquid,900e6); assertEq(debt,100e6);
    }
    function testReleaseRequiresTreasuryAndCannotExceedPrincipal() public {
        vm.warp(opens); deposit(alice,1000e6); e.repay(pool,500e6);
        vm.prank(alice); vm.expectRevert(ArvoAcquisitionEscrow.Unauthorized.selector); e.releasePrincipal(pool,100e6);
        vm.expectRevert(ArvoAcquisitionEscrow.LiquidityUnavailable.selector); release(pool,1001e6);
        release(pool,1000e6);
        vm.expectRevert(ArvoAcquisitionEscrow.LiquidityUnavailable.selector); release(pool,1);
    }
    function testEmergencyExitRequiresReturnedPrincipalButForfeitsReward() public {
        vm.warp(opens); uint256 x=deposit(alice,1000e6); release(pool,1000e6);
        s.pause(); vm.prank(alice); vm.expectRevert(ArvoAcquisitionEscrow.LiquidityUnavailable.selector); s.emergencyExit(x);
        e.repay(pool,1000e6); vm.prank(alice); s.emergencyExit(x);
        assertTrue(s.position(x).settled); assertTrue(s.position(x).emergencyExit);
        assertEq(s.acquisitionUsdcRewards(),0); assertEq(e.totalCash(),0);
    }
    function testFinalizationCancelsUnusedLimitNotUserReward() public {
        vm.warp(opens); uint256 x=deposit(alice,1000e6); release(pool,1000e6);
        vm.warp(opens+5 days); s.finalizePool(pool);
        assertEq(s.acquisitionUsdcBudget(),0); assertEq(s.usdcRewardLiability(),100e6);
        e.repay(pool,1100e6); vm.warp(opens+60 days); vm.prank(alice); s.claim(x);
    }
    function testNoReclassificationOrTreasuryChange() public {
        vm.expectRevert(ArvoStaking.AcquisitionConfigurationLocked.selector); s.configureAcquisitionPool(pool,treasury);
        uint32 other=newPool(4,60 days);
        vm.expectRevert(ArvoAcquisitionEscrow.InvalidConfiguration.selector); s.configureAcquisitionPool(other,alice);
        s.fundUsdcRewards(1000e6); s.reservePoolRewardBudget(other,0,100e6);
        vm.expectRevert(ArvoStaking.AcquisitionConfigurationLocked.selector); s.configureAcquisitionPool(other,treasury);
        vm.warp(opens); vm.expectRevert(ArvoStaking.PoolBudgetLocked.selector); s.addAcquisitionRewardLimit(pool,100e6);
    }
    function testMaturityDoesNotChangeWhenProceedsLate() public {
        vm.warp(opens); uint256 x=deposit(alice,1000e6); release(pool,1000e6);
        vm.warp(opens+70 days); e.repay(pool,1100e6);
        assertEq(s.position(x).maturesAt,opens+60 days); assertEq(s.position(x).usdcReward,100e6);
        vm.prank(alice); s.claim(x);
    }
    function testAcquisitionRolloverRejectedWithoutSettling() public {
        vm.warp(opens); uint256 x=deposit(alice,1000e6); vm.warp(opens+60 days);
        vm.prank(alice); vm.expectRevert(ArvoStaking.AcquisitionRolloverDisabled.selector); s.restakePrincipal(x,pool,T.RewardMode.USDC);
        vm.prank(alice); vm.expectRevert(ArvoStaking.AcquisitionRolloverDisabled.selector); s.compound(x,pool,T.RewardMode.USDC);
        assertFalse(s.position(x).settled);
    }
    function testNativeMixedDualRewardsAndBoostAreSnapshotted() public {
        uint32 mixed=newPool(32,60 days); s.configureAcquisitionPool(mixed,treasury);
        s.fundArvoRewards(1000 ether); s.reservePoolRewardBudget(mixed,100 ether,0);
        s.addAcquisitionRewardLimit(mixed,1000e6);
        vm.warp(opens); vm.prank(alice);
        uint256 x=s.stake(mixed,T.StakeMode.DUAL,T.RewardMode.MIXED,1000 ether,1000e6);
        assertEq(s.position(x).arvoReward,55 ether); assertEq(s.position(x).usdcReward,55e6);
        release(mixed,1000e6); assertEq(a.balanceOf(address(s)),1000 ether+1000 ether);
        e.repay(mixed,1055e6); vm.warp(opens+60 days); vm.prank(alice);
        (uint256 ap,uint256 up)=s.claim(x); assertEq(ap,1055 ether); assertEq(up,1055e6);
    }
    function testProjectLinkIsImmutableAndLockedAtOpening() public {
        bytes32 project=keccak256("barbados");
        e.linkProject(pool,project);
        (,,,,,,,,bytes32 stored)=e.accounts(pool);
        assertEq(stored,project);
        vm.expectRevert(ArvoAcquisitionEscrow.InvalidConfiguration.selector);
        e.linkProject(pool,keccak256("other"));
        uint32 other=newPool(4,60 days); s.configureAcquisitionPool(other,treasury);
        vm.warp(opens); vm.expectRevert(ArvoAcquisitionEscrow.InvalidConfiguration.selector);
        e.linkProject(other,project);
    }
    function testOrdinaryUsersCanClaimWhileAcquisitionFundsAreOut() public {
        uint32 ordinary=newPool(4,60 days);
        s.fundUsdcRewards(1000e6); s.reservePoolRewardBudget(ordinary,0,1000e6);
        vm.warp(opens); deposit(alice,1000e6); release(pool,1000e6);
        vm.prank(bob); uint256 x=s.stake(ordinary,T.StakeMode.USDC,T.RewardMode.USDC,0,1000e6);
        vm.warp(opens+60 days); vm.prank(bob); s.claim(x);
        assertEq(u.balanceOf(bob),10100e6);
        assertEq(s.acquisitionUsdcPrincipal(),1000e6);
    }
    function testExcessCannotLeaveBeforeLastUserAndFinalization() public {
        vm.warp(opens); uint256 x=deposit(alice,1000e6);
        e.repay(pool,200e6);
        vm.expectRevert(ArvoAcquisitionEscrow.LiquidityUnavailable.selector);
        withdrawExcess(pool,1);
        vm.warp(opens+5 days); s.finalizePool(pool);
        vm.expectRevert(ArvoAcquisitionEscrow.LiquidityUnavailable.selector);
        withdrawExcess(pool,1);
        vm.warp(opens+60 days); vm.prank(alice); s.claim(x);
        withdrawExcess(pool,100e6);
        assertEq(e.totalCash(),0);
    }
    function testReleaseAfterFailedMatureClaimPreservesTermsAndCanRepay() public {
        vm.warp(opens); uint256 x=deposit(alice,1000e6);
        vm.warp(opens+60 days);
        vm.prank(alice); vm.expectRevert(ArvoAcquisitionEscrow.LiquidityUnavailable.selector); s.claim(x);
        release(pool,1000e6);
        assertFalse(s.position(x).settled);
        assertEq(s.position(x).maturesAt,opens+60 days);
        assertEq(s.position(x).usdcReward,100e6);
        e.repay(pool,1100e6);
        vm.prank(alice); s.claim(x);
        assertEq(u.balanceOf(alice),10100e6);
    }
    function testReleaseAfterEarlierUserSettlesKeepsLaterUserClaimable() public {
        vm.warp(opens); uint256 x=deposit(alice,1000e6);
        vm.warp(opens+1 days); uint256 y=deposit(bob,1000e6);
        e.repay(pool,200e6);
        vm.warp(opens+60 days); vm.prank(alice); s.claim(x);
        release(pool,1000e6);
        (uint256 liquid,uint256 debt)=cash(pool);
        assertEq(liquid,100e6); assertEq(debt,1000e6);
        vm.warp(opens+61 days);
        vm.prank(bob); vm.expectRevert(ArvoAcquisitionEscrow.LiquidityUnavailable.selector); s.claim(y);
        assertFalse(s.position(y).settled);
        e.repay(pool,1000e6); vm.prank(bob); s.claim(y);
        assertEq(e.totalCash(),0);
    }
    function testFuzzReleaseRepayConservation(uint96 raw) public {
        uint256 amount=bound(uint256(raw),500e6,10_000e6);
        vm.warp(opens); uint256 id=deposit(alice,amount);
        uint256 releaseAmount=amount/2; release(pool,releaseAmount);
        (uint256 liquid,uint256 debt)=cash(pool);
        assertEq(liquid+debt,amount); assertEq(s.acquisitionUsdcPrincipal(),amount);
        e.repay(pool,releaseAmount+amount/10);
        vm.warp(opens+60 days); vm.prank(alice); s.claim(id);
        assertEq(e.totalCash(),0); assertEq(s.usdcPrincipalLiability(),0);
    }
}
