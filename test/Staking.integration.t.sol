// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@forge-std/Test.sol";

import {FixedPointMathLib} from "@solmate/utils/FixedPointMathLib.sol";
import {TransparentUpgradeableProxy, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Staking} from "src/Staking.sol";
import {RewardsDistributor} from "src/RewardsDistributor.sol";
import {IRewardsDistributor} from "src/interfaces/IRewardsDistributor.sol";
import {MockGovToken} from "test/mocks/MockGovToken.sol";
import {ProxyUtils} from "test/helpers/ProxyUtils.sol";
import {Staking} from "src/Staking.sol";
import {Deploy} from "script/Deploy.s.sol";
import "script/Constants.sol";

contract StakingIntegrationTest is Test {
    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"));
    }

    function testFork_DeployStakingContracts() public {
        Deploy deployScript = new Deploy();
        (Staking staking, RewardsDistributor rewardsDistributor) = deployScript
            .run();

        assertEq(staking.owner(), CONTRACT_OWNER);
        assertEq(address(staking.stakingToken()), STAKING_TOKEN);
        assertEq(
            address(staking.rewardsDistributor()),
            address(rewardsDistributor)
        );
        assertEq(staking.lockPeriod(), LOCK_PERIOD);
        assertEq(staking.minStake(), MIN_STAKE);

        assertEq(rewardsDistributor.owner(), CONTRACT_OWNER);
        assertEq(address(rewardsDistributor.rewardToken()), STAKING_TOKEN);
    }
}
