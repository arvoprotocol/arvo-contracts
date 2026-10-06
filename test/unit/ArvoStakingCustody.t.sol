// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { ArvoStaking } from "../../src/ArvoStaking.sol";
import { ArvoStakingTypes } from "../../src/ArvoStakingTypes.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";

contract ArvoStakingCustodyTest is Test {
    ArvoStaking internal staking;
    MockERC20 internal arvo;
    MockERC20 internal usdc;

    address internal admin = address(0xA11CE);
    address internal alice = address(0xB0B);
    address internal attacker = address(0xBAD);

    uint32 internal foundationPool;

    function setUp() public {
        arvo = new MockERC20("Arvo", "ARVO", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        ArvoStaking implementation = new ArvoStaking();

        bytes memory initialization =
            abi.encodeCall(ArvoStaking.initialize, (address(arvo), address(usdc), admin));

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initialization);

        staking = ArvoStaking(address(proxy));

        arvo.mint(admin, 1000000000 ether);
        usdc.mint(admin, 10_000_000e6);

        vm.startPrank(admin);

        arvo.approve(address(staking), type(uint256).max);

        usdc.approve(address(staking), type(uint256).max);

        staking.fundArvoRewards(100000000 ether);

        staking.fundUsdcRewards(1_000_000e6);

        foundationPool = staking.createStandardPool(
            ArvoStakingTypes.VaultKind.FOUNDATION,
            uint64(vm.getBlockTimestamp() + 1),
            0,
            0,
            0,
            true,
            true,
            false,
            true,
            true
        );

        staking.reservePoolRewardBudget(foundationPool, 50000000 ether, 500_000e6);

        vm.stopPrank();

        arvo.mint(alice, 10000000 ether);
        usdc.mint(alice, 100_000e6);

        vm.startPrank(alice);

        arvo.approve(address(staking), type(uint256).max);

        usdc.approve(address(staking), type(uint256).max);

        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function testInitialRewardReservesAreAvailable() public view {
        assertEq(staking.availableArvoRewardCapacity(), 50000000 ether);

        assertEq(staking.availableUsdcRewardCapacity(), 500_000e6);
    }

    function testFoundationArvoStakeCreatesCorrectLiabilities() public {
        vm.prank(alice);

        uint256 id = staking.stake(
            foundationPool,
            ArvoStakingTypes.StakeMode.ARVO,
            ArvoStakingTypes.RewardMode.ARVO,
            1000000 ether,
            0
        );

        ArvoStakingTypes.Position memory position = staking.position(id);

        assertEq(position.arvoPrincipal, 1000000 ether);

        assertEq(position.arvoReward, 220000 ether);

        assertEq(staking.arvoPrincipalLiability(), 1000000 ether);

        assertEq(staking.arvoRewardLiability(), 220000 ether);

        assertTrue(staking.isArvoSolvent());
    }

    function testFoundationUsdcStakeCreates14PercentReward() public {
        vm.prank(alice);

        uint256 id = staking.stake(
            foundationPool,
            ArvoStakingTypes.StakeMode.USDC,
            ArvoStakingTypes.RewardMode.USDC,
            0,
            10_000e6
        );

        ArvoStakingTypes.Position memory position = staking.position(id);

        assertEq(position.usdcPrincipal, 10_000e6);

        assertEq(position.usdcReward, 1_400e6);

        assertTrue(staking.isUsdcSolvent());
    }

    function testMixedRewardModeIsDisabledWithoutOracle() public {
        vm.startPrank(admin);

        uint32 dualPool = staking.createStandardPool(
            ArvoStakingTypes.VaultKind.FOUNDATION,
            uint64(vm.getBlockTimestamp() + 1),
            0,
            0,
            0,
            true,
            true,
            true,
            true,
            true
        );

        staking.reservePoolRewardBudget(dualPool, 10000000 ether, 100_000e6);

        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + 1);

        vm.prank(alice);

        vm.expectRevert(ArvoStaking.RewardModeDisabled.selector);

        staking.stake(
            dualPool,
            ArvoStakingTypes.StakeMode.DUAL,
            ArvoStakingTypes.RewardMode.MIXED,
            1000000 ether,
            10_000e6
        );
    }

    function testPrincipalIsNotCountedAsRewardCapacity() public {
        uint256 capacityBefore = staking.availableArvoRewardCapacity();

        vm.prank(alice);

        staking.stake(
            foundationPool,
            ArvoStakingTypes.StakeMode.ARVO,
            ArvoStakingTypes.RewardMode.ARVO,
            1000000 ether,
            0
        );

        /*
         * Principal enters the contract while an equal principal
         * liability is created.
         *
         * The position reward moves from reserved pool budget into
         * committed reward liability, so genuinely free reward
         * capacity remains unchanged.
         */
        assertEq(staking.availableArvoRewardCapacity(), capacityBefore);
    }

    function testStakeFailsIfPoolRewardIsNotReserved() public {
        vm.startPrank(admin);

        uint32 unfundedPool = staking.createStandardPool(
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

        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + 1);

        vm.prank(alice);

        vm.expectRevert(ArvoStaking.InsufficientPoolRewardBudget.selector);

        staking.stake(
            unfundedPool,
            ArvoStakingTypes.StakeMode.ARVO,
            ArvoStakingTypes.RewardMode.ARVO,
            1000000 ether,
            0
        );
    }

    function testUnauthorizedWalletCannotFundRewards() public {
        arvo.mint(attacker, 1000000 ether);

        vm.startPrank(attacker);

        arvo.approve(address(staking), type(uint256).max);

        vm.expectRevert();

        staking.fundArvoRewards(1000000 ether);

        vm.stopPrank();
    }

    function testUnauthorizedWalletCannotWithdrawSurplus() public {
        vm.prank(attacker);

        vm.expectRevert();

        staking.withdrawArvoSurplus(attacker, 100 ether);
    }

    function testAdminCannotWithdrawMoreThanTrueSurplus() public {
        vm.prank(alice);

        staking.stake(
            foundationPool,
            ArvoStakingTypes.StakeMode.ARVO,
            ArvoStakingTypes.RewardMode.ARVO,
            1000000 ether,
            0
        );

        uint256 genuineSurplus = staking.availableArvoRewardCapacity();

        vm.prank(admin);

        vm.expectRevert(ArvoStaking.InsufficientSurplus.selector);

        staking.withdrawArvoSurplus(admin, genuineSurplus + 1);
    }

    function testPausedProtocolRejectsNewStakes() public {
        vm.prank(admin);
        staking.pause();

        vm.prank(alice);
        vm.expectRevert();

        staking.stake(
            foundationPool,
            ArvoStakingTypes.StakeMode.ARVO,
            ArvoStakingTypes.RewardMode.ARVO,
            1000000 ether,
            0
        );
    }
}
