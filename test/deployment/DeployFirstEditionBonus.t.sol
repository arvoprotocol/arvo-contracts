// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { BonusFixture } from "../bonus/ArvoFirstEditionBonus.t.sol";
import { DeployFirstEditionBonus } from "../../script/DeployFirstEditionBonus.s.sol";
import { ArvoFirstEditionBonus } from "../../src/bonus/ArvoFirstEditionBonus.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";

contract DeployFirstEditionBonusTest is BonusFixture {
    DeployFirstEditionBonus internal script;
    address internal safe;

    function setUp() public override {
        super.setUp();
        script = new DeployFirstEditionBonus();
        safe = address(new MockERC20("Safe stand-in", "SAFE", 18)); // any contract
        vm.setEnv("STAKING_PROXY", vm.toString(address(staking)));
        vm.setEnv("BONUS_POOL_ID", vm.toString(uint256(poolId)));
        vm.setEnv("BONUS_POT_ARVO", "2500000");
        vm.setEnv("BONUS_TREASURY", vm.toString(safe));
        vm.setEnv("BONUS_GRACE_DAYS", "90");
        vm.setEnv("EXPECTED_CHAIN_ID", vm.toString(block.chainid));
    }

    function testDeploysWithReviewedTerms() public {
        ArvoFirstEditionBonus b = script.run();
        assertEq(b.bonusPot(), POT);
        assertEq(b.poolId(), poolId);
        assertEq(b.treasury(), safe);
        assertEq(b.claimDeadline(), closesAt + DURATION + 90 days);
    }

    function testRejectsWrongChain() public {
        vm.setEnv("EXPECTED_CHAIN_ID", "4663");
        vm.chainId(1);
        vm.expectRevert(DeployFirstEditionBonus.WrongChain.selector);
        script.run();
    }

    function testRejectsEoaTreasury() public {
        vm.setEnv("BONUS_TREASURY", vm.toString(address(0xBEEF)));
        vm.expectRevert(DeployFirstEditionBonus.TreasuryNotContract.selector);
        script.run();
    }
}
