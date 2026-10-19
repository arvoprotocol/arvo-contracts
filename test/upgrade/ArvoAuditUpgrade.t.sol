// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ArvoStakingAuditedV1} from "./fixtures/ArvoStakingAuditedV1.sol";
import {ArvoStaking} from "../../src/ArvoStaking.sol";
import {ArvoAcquisitionEscrow} from "../../src/ArvoAcquisitionEscrow.sol";
import {ArvoStakingTypes as T} from "../../src/ArvoStakingTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {UpgradeArvoAuditTestnet} from "../../script/UpgradeArvoAuditTestnet.s.sol";

contract AuditUpgradeHarness is UpgradeArvoAuditTestnet {
    function upgrade(address proxy,address original,address admin) external returns(address) {
        return _upgrade(proxy,original,admin);
    }
}
contract ArvoAuditUpgradeTest is Test {
    function testAuditedLiveDualPositionSurvivesUpgradeAndCanExitArvoIndependently() public {
        vm.chainId(46630);
        MockERC20 a=new MockERC20("ARVO","ARVO",18);
        MockERC20 u=new MockERC20("USDC","USDC",6);
        ArvoStakingAuditedV1 oldImpl=new ArvoStakingAuditedV1();
        ArvoStaking old=ArvoStaking(address(new ERC1967Proxy(address(oldImpl),
            abi.encodeCall(ArvoStaking.initialize,(address(a),address(u),address(this))))));
        address treasury=address(new AuditUpgradeHarness());
        ArvoAcquisitionEscrow escrow=new ArvoAcquisitionEscrow(address(old),address(u));
        old.configureAcquisitionEscrow(escrow);
        a.mint(address(this),10_000 ether);u.mint(address(this),10_000e6);
        a.approve(address(old),type(uint256).max);u.approve(address(old),type(uint256).max);
        old.fundArvoRewards(1000 ether);
        T.VaultConfig memory c=T.VaultConfig(60 days,1000,1000,1000,1500,5000,500 ether,500e6,true,true,true,true,true,true);
        uint64 opens=uint64(block.timestamp+10);
        uint32 pool=old.createProductPool(T.VaultKind.CUSTOM,c,opens,opens+5 days,100_000 ether,10_000e6,32,0);
        old.configureAcquisitionPool(pool,treasury);old.addAcquisitionRewardLimit(pool,1000e6);
        old.reservePoolRewardBudget(pool,100 ether,0);old.setPoolVisibility(pool,2);
        vm.warp(opens);
        uint256 id=old.stake(pool,T.StakeMode.DUAL,T.RewardMode.MIXED,1000 ether,1000e6);
        vm.prank(treasury);escrow.releasePrincipal(pool,1000e6);
        bytes32 beforePosition=keccak256(abi.encode(old.position(id)));
        bytes32 beforePool=keccak256(abi.encode(old.pool(pool)));
        old.pause();
        new AuditUpgradeHarness().upgrade(address(old),address(oldImpl),address(this));
        assertEq(keccak256(abi.encode(old.position(id))),beforePosition);
        assertEq(keccak256(abi.encode(old.pool(pool))),beforePool);
        assertEq(address(old.acquisitionEscrow()),address(escrow));
        assertTrue(old.hasRole(old.DEFAULT_ADMIN_ROLE(),address(this)));
        assertTrue(old.paused());
        (uint256 arvoPaid,uint256 usdcPaid)=old.emergencyExit(id);
        assertEq(arvoPaid,1000 ether);assertEq(usdcPaid,0);
        assertEq(old.pendingEmergencyUsdc(id),1000e6);
        u.approve(address(escrow),1000e6);escrow.repay(pool,1000e6);
        old.claimEmergencyUsdc(id);
        assertEq(old.usdcPrincipalLiability(),0);
        assertEq(old.acquisitionUsdcPrincipal(),0);
    }
    function testWrongNetworkStopsBeforeUpgrade() public {
        vm.chainId(1);
        AuditUpgradeHarness harness=new AuditUpgradeHarness();
        vm.expectRevert(UpgradeArvoAuditTestnet.PreflightFailed.selector);
        harness.upgrade(address(1),address(2),address(3));
    }
}
