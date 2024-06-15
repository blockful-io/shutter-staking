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
    IStaking staking;

    function setUp() public {
        // deploy mock shu
        MockShu shu = new MockShu();

        // deploy rewards distributor
        address rewardsDistributor = address(new RewardsDistributor());

        TransparentUpgradeableProxy rewardsDistributionProxy = new TransparentUpgradeableProxy(
                rewardsDistributor,
                address(this),
                abi.encodeWithSignature("initialize(address)", address(this))
            );

        // deploy staking
        address stakingContract = address(new Staking());

        address stakingProxy = address(
            new TransparentUpgradeableProxy(stakingContract, address(this), "")
        );

        uint256 lockPeriod = 60 * 24 * 30 * 6; // 6 months
        uint256 minStake = 50_000 * 1e18; // 50k

        Staking(address(stakingProxy)).initialize(
            address(this), // owner
            address(shu),
            address(rewardsDistributionProxy),
            lockPeriod,
            minStake
        );

        staking = IStaking(stakingProxy);
    }
}
