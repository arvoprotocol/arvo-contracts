// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeArvoAcquisitionTestnet} from "../../script/UpgradeArvoAcquisitionTestnet.s.sol";
import {ArvoStakingTestnetV1} from "../upgrade/fixtures/ArvoStakingTestnetV1.sol";
import {ArvoStaking} from "../../src/ArvoStaking.sol";
import {ArvoStakingTypes as T} from "../../src/ArvoStakingTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract AcquisitionUpgradeHarness is UpgradeArvoAcquisitionTestnet {
    function simulate(address proxy, address old, address admin) external returns (address, address) {
        return _upgrade(proxy, old, admin);
    }
}
contract UpgradeArvoAcquisitionTestnetTest is Test {
    AcquisitionUpgradeHarness script;
    ArvoStakingTestnetV1 old;
    address implementation;
    address admin = address(0xA11CE);
    MockERC20 a;
    MockERC20 u;

    function setUp() public {
        vm.chainId(46630);
        a = new MockERC20("ARVO", "ARVO", 18);
        u = new MockERC20("USDC", "USDC", 6);
        implementation = address(new ArvoStakingTestnetV1());
        old = ArvoStakingTestnetV1(address(new ERC1967Proxy(implementation,
            abi.encodeCall(ArvoStakingTestnetV1.initialize, (address(a), address(u), admin)))));
        script = new AcquisitionUpgradeHarness();
    }
    function testRejectsWrongNetworkBeforeDeploying() public {
        vm.chainId(1);
        vm.expectRevert(UpgradeArvoAcquisitionTestnet.WrongChain.selector);
        script.simulate(address(old), implementation, admin);
    }
    function testRejectsDifferentImplementation() public {
        vm.expectRevert(UpgradeArvoAcquisitionTestnet.UnexpectedImplementation.selector);
        script.simulate(address(old), address(0xBAD), admin);
    }
    function testRejectsUnauthorizedAdmin() public {
        vm.expectRevert(UpgradeArvoAcquisitionTestnet.MissingAdminRole.selector);
        script.simulate(address(old), implementation, address(0xBAD));
    }
    function testUpgradeAndBindingPreserveLivePositionAndPool() public {
        a.mint(admin, 10000 ether);
        vm.startPrank(admin);
        a.approve(address(old), type(uint256).max);
        old.fundArvoRewards(1000 ether);
        T.VaultConfig memory c=T.VaultConfig(60 days,1000,1000,0,0,5000,500 ether,500e6,
            true,false,false,true,false,false);
        uint64 opens=uint64(block.timestamp+1);
        uint32 pool=old.createProductPool(T.VaultKind.CUSTOM,c,opens,0,10000 ether,0,1,0);
        old.reservePoolRewardBudget(pool,1000 ether,0);
        old.setPoolVisibility(pool,2);
        vm.warp(opens);
        uint256 pos=old.stake(pool,T.StakeMode.ARVO,T.RewardMode.ARVO,500 ether,0);
        vm.stopPrank();
        (address next,address escrow)=script.simulate(address(old),implementation,admin);
        ArvoStaking s=ArvoStaking(address(old));
        assertEq(address(s.acquisitionEscrow()),escrow);
        assertGt(next.code.length,0); assertLe(next.code.length,24576);
        assertFalse(s.acquisitionPools(pool));
        assertEq(s.poolVisibility(pool),2);
        assertEq(s.position(pos).arvoReward,50 ether);
        vm.warp(opens+60 days); vm.prank(admin); s.claim(pos);
        assertEq(a.balanceOf(admin),9050 ether);
        vm.expectRevert(UpgradeArvoAcquisitionTestnet.UnexpectedImplementation.selector);
        script.simulate(address(old),implementation,admin);
    }
}
