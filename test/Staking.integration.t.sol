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
        vm.createSelectFork(vm.rpcUrl("mainnet"), 20254999);

        Deploy deployScript = new Deploy();
        (staking, rewardsDistributor) = deployScript.run();
    }

    function _boundUnlockedTime(uint256 _time) internal view returns (uint256) {
        return
            bound(
                _time,
                vm.getBlockTimestamp() + LOCK_PERIOD,
                vm.getBlockTimestamp() + 105 weeks
            );
    }

    function _boundRealisticTimeAhead(
        uint256 _time
    ) internal pure returns (uint256) {
        return bound(_time, 1, 105 weeks); // two years
    }

    function _jumpAhead(uint256 _seconds) public {
        vm.warp(vm.getBlockTimestamp() + _seconds);
    }

    function _setRewardAndFund() public {
        vm.prank(CONTRACT_OWNER);
        rewardsDistributor.setRewardConfiguration(
            address(staking),
            REWARD_RATE
        );

        uint256 poolSize = 10_000_000e18;
        deal(STAKING_TOKEN, CONTRACT_OWNER, poolSize);

        vm.prank(CONTRACT_OWNER);
        IERC20(STAKING_TOKEN).transfer(address(rewardsDistributor), poolSize);
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

    function testForkFuzz_MultipleDepositorsStakeMinStakeSameBlock(
        uint256 _depositorsCount,
        uint256 _jump
    ) public {
        _setRewardAndFund();

        _depositorsCount = bound(_depositorsCount, 1, 1000);

        address[] memory depositors = new address[](_depositorsCount);

        for (uint256 i = 0; i < depositors.length; i++) {
            address depositor = address(
                uint160(uint256(keccak256(abi.encodePacked(i))))
            );
            vm.prank(CONTRACT_OWNER);
            staking.setKeyper(depositor, true);

            deal(STAKING_TOKEN, depositor, MIN_STAKE);

            vm.startPrank(depositor);
            IERC20(STAKING_TOKEN).approve(address(staking), MIN_STAKE);
            staking.stake(MIN_STAKE);
            vm.stopPrank();
        }

        _jump = _boundRealisticTimeAhead(_jump);

        uint256 expectedRewardsDistributed = REWARD_RATE * _jump;

        uint256 expectedRewardPerKeyper = expectedRewardsDistributed /
            depositors.length;

        _jumpAhead(_jump);

        // collect rewards
        for (uint256 i = 0; i < depositors.length; i++) {
            address depositor = address(
                uint160(uint256(keccak256(abi.encodePacked(i))))
            );
            vm.startPrank(depositor);
            uint256 rewards = staking.claimRewards(0);
            vm.stopPrank();

            assertApproxEqAbs(rewards, expectedRewardPerKeyper, 0.1e18);
        }
    }

    function testFork_7PercentTotalSupplyStakedNoCompoundResultsIn20PercentAPR()
        public
    {
        _setRewardAndFund();

        uint256 totalSupply = IERC20(STAKING_TOKEN).totalSupply();
        uint256 staked = 0.07e18 * totalSupply;

        deal(STAKING_TOKEN, address(this), staked);

        vm.prank(CONTRACT_OWNER);
        staking.setKeyper(address(this), true);

        staking.stake(staked);

        uint256 jump = 365 days;

        uint256 expectedRewardsDistributed = REWARD_RATE * jump;

        uint256 rewardsReceived = staking.claimRewards(0);

        assertApproxEqAbs(rewardsReceived, expectedRewardsDistributed, 0.1e18);
        //APRi= Annualized percentage return based on how much participant i has staked versus how much they have earned in rewards over the year i.
        //For example for a Keyper APRKeyper=(RKeyperSKeyper)*365t*100

        uint256 apr = (rewardsReceived / staked) * (365 days) * 100;

        assertApproxEqAbs(apr, 20, 0.1e18);
    }
}
