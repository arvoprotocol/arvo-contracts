// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ArvoStaking} from "../../src/ArvoStaking.sol";
import {ArvoStakingTestnetV1} from "./fixtures/ArvoStakingTestnetV1.sol";
import {ArvoAcquisitionEscrow} from "../../src/ArvoAcquisitionEscrow.sol";
import {ArvoStakingTypes as T} from "../../src/ArvoStakingTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockArvoPriceOracle} from "../../src/mocks/MockArvoPriceOracle.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";
contract ArvoAcquisitionUpgradeTest is Test {
    function testCurrentTestnetUpgradePreservesPositionsRolesOracleAndCash() public {
        MockERC20 a=new MockERC20("ARVO","ARVO",18);
        MockERC20 u=new MockERC20("USD","USDC",6);
        ArvoStakingTestnetV1 beforeImpl=new ArvoStakingTestnetV1();
        ArvoStakingTestnetV1 old=ArvoStakingTestnetV1(address(new ERC1967Proxy(address(beforeImpl),
            abi.encodeCall(ArvoStakingTestnetV1.initialize,(address(a),address(u),address(this))))));
        a.mint(address(this),10000 ether); u.mint(address(this),10000e6);
        a.approve(address(old),type(uint256).max); u.approve(address(old),type(uint256).max);
        old.fundArvoRewards(5000 ether); old.fundUsdcRewards(5000e6);
        T.VaultConfig memory c=T.VaultConfig(60 days,1000,1000,1000,1500,5000,500 ether,500e6,true,true,false,true,true,false);
        uint64 opens=uint64(block.timestamp+10);
        uint32 pool=old.createProductPool(T.VaultKind.CUSTOM,c,opens,opens+5 days,10000 ether,10000e6,7,550 ether);
        old.reservePoolRewardBudget(pool,1000 ether,1000e6); old.setPoolVisibility(pool,2);
        MockArvoPriceOracle oracle=new MockArvoPriceOracle(1e6,6);
        old.configurePriceOracle(address(oracle),3600);
        old.grantRole(old.REWARD_MANAGER_ROLE(),address(0xB0B));
        vm.warp(opens);
        uint256 ap=old.stake(pool,T.StakeMode.ARVO,T.RewardMode.ARVO,500 ether,0);
        uint256 up=old.stake(pool,T.StakeMode.USDC,T.RewardMode.USDC,0,500e6);
        bytes32 arvoPosition=keccak256(abi.encode(old.position(ap)));
        bytes32 usdcPosition=keccak256(abi.encode(old.position(up)));
        bytes32 oldPool=keccak256(abi.encode(old.pool(pool)));
        bytes32 oldTerms=keccak256(abi.encode(old.vault(pool)));
        old.pause();
        ArvoStaking next=new ArvoStaking();
        assertLe(address(next).code.length,24576,"implementation must respect EIP-170");
        old.upgradeToAndCall(address(next),"");
        ArvoStaking nowS=ArvoStaking(address(old));
        assertEq(keccak256(abi.encode(nowS.position(ap))),arvoPosition);
        assertEq(keccak256(abi.encode(nowS.position(up))),usdcPosition);
        assertEq(keccak256(abi.encode(nowS.pool(pool))),oldPool);
        assertEq(keccak256(abi.encode(nowS.vault(pool))),oldTerms);
        assertEq(nowS.poolProducts(pool),7); assertEq(nowS.poolVisibility(pool),2);
        assertEq(nowS.minArvoForUsdc(pool),550 ether); assertEq(address(nowS.priceOracle()),address(oracle));
        assertTrue(nowS.hasRole(nowS.REWARD_MANAGER_ROLE(),address(0xB0B)));
        assertTrue(nowS.paused()); assertFalse(nowS.acquisitionPools(pool));
        assertEq(address(nowS.acquisitionEscrow()),address(0));
        assertEq(nowS.usdcPrincipalLiability(),500e6); assertEq(nowS.usdcRewardLiability(),50e6);
        vm.warp(opens+60 days); nowS.claim(ap); nowS.claim(up);
        assertEq(nowS.usdcPrincipalLiability(),0); assertEq(nowS.usdcRewardLiability(),0);
        assertEq(a.balanceOf(address(this)),5050 ether); assertEq(u.balanceOf(address(this)),5050e6);
    }
    function testOpenZeppelinUpgradeFromExactReviewedTestnetV1() public {
        Options memory opts; opts.unsafeAllow="constructor,external-library-linking";
        opts.referenceContract="ArvoStakingTestnetV1.sol:ArvoStakingTestnetV1";
        Upgrades.validateUpgrade("ArvoStaking.sol:ArvoStaking",opts);
    }
}
