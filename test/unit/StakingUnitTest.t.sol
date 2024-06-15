// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "@forge-std/Test.sol";

import {TransparentUpgradeableProxy, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Staking} from "../../src/Staking.sol";
import {IStaking} from "../../src/interfaces/IStaking.sol";
import {RewardsDistributor} from "../../src/RewardsDistributor.sol";
import {IRewardsDistributor} from "../../src/interfaces/IRewardsDistributor.sol";

import {MockShu} from "../mocks/MockShu.sol";

contract StakingUnitTest is Test {
    IStaking public staking;
    MockShu public shu;

    uint256 constant lockPeriod = 60 * 24 * 30 * 6; // 6 months
    uint256 constant minStake = 50_000 * 1e18; // 50k

    address keyper = address(0x1234);

    function setUp() public {
        // deploy mock shu
        shu = new MockShu();

        shu.mint(keyper, 1_000_000 * 1e18);

        // deploy rewards distributor
        address rewardsDistributionProxy = address(
            new TransparentUpgradeableProxy(
                address(new RewardsDistributor()),
                address(this),
                abi.encodeWithSignature("initialize(address)", address(this))
            )
        );

        // deploy staking
        address stakingContract = address(new Staking());

        address stakingProxy = address(
            new TransparentUpgradeableProxy(stakingContract, address(this), "")
        );

        Staking(stakingProxy).initialize(
            address(this), // owner
            address(shu),
            address(rewardsDistributionProxy),
            lockPeriod,
            minStake
        );

        staking = IStaking(stakingProxy);

        IRewardsDistributor(rewardsDistributionProxy).addRewardConfiguration(
            stakingProxy,
            address(shu),
            1e18
        );

        // fund reward distribution
        shu.transfer(rewardsDistributionProxy, 1_000_000 * 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                               HAPPY PATHS
    //////////////////////////////////////////////////////////////*/

    function testAddKeyper() public {
        vm.expectEmit(address(staking));
        emit IStaking.KeyperSet(keyper, true);
        staking.setKeyper(keyper, true);
    }

    function testStakeSucceed() public {
        testAddKeyper();

        vm.startPrank(keyper);
        shu.approve(address(staking), minStake);

        vm.expectEmit(true, true, true, true, address(staking));
        emit IStaking.Staked(
            keyper,
            minStake,
            minStake, // first stake, shares == amount
            lockPeriod
        );

        staking.stake(minStake);

        vm.stopPrank();
    }

    function testClaimRewardSucceed() public {
        testStakeSucceed();

        vm.warp(block.timestamp + 1000); // 1000 seconds later

        uint256 claimAmount = 1_000e18; // 1 SHU per second is distributed

        vm.expectEmit(true, true, true, true, address(staking));
        emit IStaking.ClaimRewards(keyper, address(shu), claimAmount);

        vm.prank(keyper);
        staking.claimReward(shu, claimAmount);
    }
}
