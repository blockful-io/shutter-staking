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

    uint256 constant CIRCULATION_SUPPLY = 81_000_000e18;

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

    function _calculateAPR(
        uint256 _rewardsReceived,
        uint256 _staked,
        uint256 _days
    ) internal pure returns (uint256) {
        // using scalar math
        uint256 SCALAR = 1e18;

        uint256 aprScalar = ((_rewardsReceived * SCALAR) * 365 days * 100) /
            (_staked * _days);

        return aprScalar;
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

    function testFork_25PercentParticipationRateGives20PercentAPR() public {
        _setRewardAndFund();

        uint256 staked = (CIRCULATION_SUPPLY * 25) / 100;

        deal(STAKING_TOKEN, address(this), staked);

        vm.prank(CONTRACT_OWNER);
        staking.setKeyper(address(this), true);

        IERC20(STAKING_TOKEN).approve(address(staking), staked);
        staking.stake(staked);

        uint256 jump = 86 days;

        _jumpAhead(jump);

        uint256 rewardsReceived = staking.claimRewards(0);

        uint256 APR = _calculateAPR(rewardsReceived, staked, jump);

        // 1% error margin
        assertApproxEqAbs(APR, 20e18, 1e18);
    }

    function testFork_FirstDepositorsAlwaysReceiveMoreRewards() public {
        uint256 depositorsCount = 400;

        _setRewardAndFund();

        uint256 jumpBetweenStakes = 1 hours;

        uint256[] memory timeStaked = new uint256[](depositorsCount);
        uint256 previousDepositorShares;

        uint256 timestampFirstStake = vm.getBlockTimestamp();

        for (uint256 i = 1; i <= depositorsCount; i++) {
            address participant = address(uint160(i));

            deal(STAKING_TOKEN, participant, MIN_STAKE);

            vm.prank(CONTRACT_OWNER);
            staking.setKeyper(participant, true);

            vm.startPrank(participant);
            IERC20(STAKING_TOKEN).approve(address(staking), MIN_STAKE);
            staking.stake(MIN_STAKE);
            vm.stopPrank();

            uint256 shares = staking.balanceOf(participant);
            if (i > 1) {
                assertGt(previousDepositorShares, shares);
            }
            previousDepositorShares = shares;

            timeStaked[i - 1] = vm.getBlockTimestamp();

            _jumpAhead(jumpBetweenStakes);
        }

        uint256 previousRewardsReceived;

        // collect rewards and calculate rewards
        for (uint256 i = 1; i <= depositorsCount; i++) {
            address participant = address(uint160(i));

            uint256 expectedTimestamp = timeStaked[i - 1] + 365 days;
            // jump the diferrence between expected and actual time
            _jumpAhead(expectedTimestamp - vm.getBlockTimestamp());

            vm.startPrank(participant);
            uint256 rewardsReceived = staking.claimRewards(0);

            vm.stopPrank();

            if (i > 1) {
                assertGt(rewardsReceived, previousRewardsReceived);
            }

            _jumpAhead(jumpBetweenStakes);

            uint256 assetsAfter = staking.convertToAssets(
                staking.balanceOf(participant)
            );
            assertApproxEqAbs(assetsAfter, MIN_STAKE, 2);
        }
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

        uint256 APR = _calculateAPR(expectedRewardPerKeyper, MIN_STAKE, _jump);

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
}
