// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@forge-std/Test.sol";

import {FixedPointMathLib} from "@solmate/utils/FixedPointMathLib.sol";
import {TransparentUpgradeableProxy, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Staking} from "src/Staking.sol";
import {RewardsDistributor} from "src/RewardsDistributor.sol";
import {IRewardsDistributor} from "src/interfaces/IRewardsDistributor.sol";
import {MockGovToken} from "test/mocks/MockGovToken.sol";
import {ProxyUtils} from "test/helpers/ProxyUtils.sol";
import {Staking} from "src/Staking.sol";
import {Deploy} from "script/Deploy.s.sol";
import "script/Constants.sol";

contract StakingIntegrationTest is Test {
    Staking staking;
    RewardsDistributor rewardsDistributor;

    function setUp() public {
        vm.label(STAKING_TOKEN, "SHU");
        vm.createSelectFork(vm.rpcUrl("mainnet"));

        Deploy deployScript = new Deploy();
        (staking, rewardsDistributor) = deployScript.run();
    }

    function testFork_DeployStakingContracts() public view {
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

    function testFork_SetRewardConfiguration() public {
        vm.prank(CONTRACT_OWNER);
        rewardsDistributor.setRewardConfiguration(
            address(staking),
            REWARD_RATE
        );

        (uint256 emissionRate, uint256 lastUpdate) = rewardsDistributor
            .rewardConfigurations(address(staking));

        assertEq(emissionRate, REWARD_RATE);
        assertEq(lastUpdate, block.timestamp);
    }

    function testForkFuzz_MultipleDepositorsStake(
        address[] calldata depositors,
        uint256[] calldata amounts
    ) public {
        vm.assume(depositors.length == amounts.length);

        vm.prank(CONTRACT_OWNER);
        staking.setKeypers(depositors, true);

        for (uint256 i = 0; i < depositors.length; i++) {
            uint256 amount = bound(amounts[i], MIN_STAKE, 5_000_000e18);

            deal(STAKING_TOKEN, depositors[i], amount);

            vm.startPrank(depositors[i]);
            IERC20(STAKING_TOKEN).approve(address(staking), amount);
            staking.stake(amount);
            vm.stopPrank();
        }
    }
}
