// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@forge-std/Test.sol";

import {FixedPointMathLib} from "@solmate/utils/FixedPointMathLib.sol";
import {TransparentUpgradeableProxy, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DelegateStaking} from "src/DelegateStaking.sol";
import {Staking} from "src/Staking.sol";
import {RewardsDistributor} from "src/RewardsDistributor.sol";
import {IRewardsDistributor} from "src/interfaces/IRewardsDistributor.sol";
import {MockGovToken} from "test/mocks/MockGovToken.sol";
import {ProxyUtils} from "test/helpers/ProxyUtils.sol";
import {Staking} from "src/Staking.sol";
import {Deploy} from "script/Deploy.s.sol";
import "script/Constants.sol";

contract DelegateStakingIntegrationTest is Test {
    DelegateStaking delegate;
    Staking staking;
    RewardsDistributor rewardsDistributor;

    uint256 constant CIRCULATION_SUPPLY = 81_000_000e18;

    function setUp() public {
        vm.label(STAKING_TOKEN, "SHU");
        vm.createSelectFork(vm.rpcUrl("mainnet"), 20254999);
        (, address sender, ) = vm.readCallers();

        deal(STAKING_TOKEN, sender, INITIAL_MINT * 2);

        Deploy deployScript = new Deploy();
        (staking, rewardsDistributor, delegate) = deployScript.run();
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
            address(delegate),
            REWARD_RATE
        );

        uint256 poolSize = 10_000_000e18;
        deal(STAKING_TOKEN, CONTRACT_OWNER, poolSize);

        vm.prank(CONTRACT_OWNER);
        IERC20(STAKING_TOKEN).transfer(address(rewardsDistributor), poolSize);
    }

    function _calculateReturnOverPrincipal(
        uint256 _rewardsReceived,
        uint256 _staked,
        uint256 _days
    ) internal pure returns (uint256) {
        uint256 SCALAR = 1e18;

        uint256 aprScalar = ((_rewardsReceived * SCALAR) * 365 days * 100) /
            (_staked * _days);

        return aprScalar;
    }

    function testFork_DeployStakingContracts() public view {
        assertEq(delegate.owner(), CONTRACT_OWNER);
        assertEq(address(delegate.stakingToken()), STAKING_TOKEN);
        assertEq(
            address(delegate.rewardsDistributor()),
            address(rewardsDistributor)
        );
        assertEq(delegate.lockPeriod(), LOCK_PERIOD);
        assertEq(address(delegate.staking()), address(staking));

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

        IERC20(STAKING_TOKEN).approve(address(delegate), staked);
        delegate.stake(address(this), staked);

        uint256 jump = 86 days;

        _jumpAhead(jump);

        uint256 rewardsReceived = delegate.claimRewards(0);

        uint256 APR = _calculateReturnOverPrincipal(
            rewardsReceived,
            staked,
            jump
        );

        // 1% error margin
        assertApproxEqAbs(APR, 21e18, 1e18);
    }

    function testForkFuzz_MultipleDepositorsStakAmountDifferentTimestamp(
        uint256 _jump,
        uint256 _amount,
        uint256 _depositorsCount
    ) public {
        _amount = bound(_amount, 1e18, 10000000e18);
        _depositorsCount = bound(_depositorsCount, 2, 1000);

        _setRewardAndFund();

        _jump = bound(_jump, 1 minutes, 12 hours);

        uint256[] memory timeStaked = new uint256[](_depositorsCount);
        uint256 previousDepositorShares;

        address keyper = address(1);
        vm.prank(CONTRACT_OWNER);
        staking.setKeyper(keyper, true);

        for (uint256 i = 1; i <= _depositorsCount; i++) {
            address participant = address(uint160(i));

            deal(STAKING_TOKEN, participant, _amount);

            vm.startPrank(participant);
            IERC20(STAKING_TOKEN).approve(address(delegate), _amount);
            delegate.stake(keyper, _amount);
            vm.stopPrank();

            uint256 shares = delegate.balanceOf(participant);
            if (i > 1) {
                assertGt(previousDepositorShares, shares);
            }
            previousDepositorShares = shares;

            timeStaked[i - 1] = vm.getBlockTimestamp();

            _jumpAhead(_jump);
        }

        uint256 previousRewardsReceived;

        for (uint256 i = 1; i <= _depositorsCount; i++) {
            address participant = address(uint160(i));

            uint256 expectedTimestamp = timeStaked[i - 1] + 365 days;
            // jump the diferrence between expected and actual time
            _jumpAhead(expectedTimestamp - vm.getBlockTimestamp());

            vm.startPrank(participant);
            uint256 rewardsReceived = delegate.claimRewards(0);

            vm.stopPrank();

            if (i > 1) {
                assertGt(rewardsReceived, previousRewardsReceived);
            }

            uint256 assetsAfter = delegate.convertToAssets(
                delegate.balanceOf(participant)
            );
            assertApproxEqAbs(assetsAfter, _amount, 1e18);
        }
    }

    function testFork_ClaimRewardsAtTheEndOfSemester() public {
        _setRewardAndFund();

        uint256 staked = (CIRCULATION_SUPPLY * 25) / 100;

        deal(STAKING_TOKEN, address(this), staked);

        vm.prank(CONTRACT_OWNER);
        staking.setKeyper(address(this), true);

        IERC20(STAKING_TOKEN).approve(address(delegate), staked);
        delegate.stake(address(this), staked);

        uint256 jump = 86 days;

        _jumpAhead(jump);

        uint256 rewardsReceived = delegate.claimRewards(0);

        uint256 APR = _calculateReturnOverPrincipal(
            rewardsReceived,
            staked,
            jump
        );

        // 1% error margin
        assertApproxEqAbs(APR, 21e18, 1e18);
    }

    function testFork_ClaimRewardsEveryDayAndReestakeUntilEndSemester() public {
        _setRewardAndFund();

        uint256 staked = (CIRCULATION_SUPPLY * 25) / 100;

        deal(STAKING_TOKEN, address(this), staked);

        vm.prank(CONTRACT_OWNER);
        staking.setKeyper(address(this), true);

        IERC20(STAKING_TOKEN).approve(address(delegate), staked);
        delegate.stake(address(this), staked);

        uint256 previousTimestamp = vm.getBlockTimestamp();

        for (uint256 i = 1; i < 2064; i++) {
            _jumpAhead(1 hours);

            previousTimestamp = vm.getBlockTimestamp();
            uint256 rewardsReceived = delegate.claimRewards(0);

            IERC20(STAKING_TOKEN).approve(address(delegate), rewardsReceived);
            delegate.stake(address(this), rewardsReceived);
        }

        _jumpAhead(1 hours);

        uint256 assets = delegate.convertToAssets(
            delegate.balanceOf(address(this))
        );

        uint256 APR = _calculateReturnOverPrincipal(
            assets - staked,
            staked,
            86 days
        );

        assertApproxEqAbs(APR, 21e18, 1e18);
    }

    function testForkFuzz_MultipleDepositorsStakeSameStakeSameTimestamp(
        uint256 _depositorsCount,
        uint256 _jump,
        uint256 _amount
    ) public {
        _amount = bound(_amount, 1e18, 10000000e18);
        _depositorsCount = bound(_depositorsCount, 1, 1000);

        _jump = _boundRealisticTimeAhead(_jump);

        _setRewardAndFund();

        address keyper = address(1);

        vm.prank(CONTRACT_OWNER);
        staking.setKeyper(keyper, true);

        for (uint256 i = 0; i < _depositorsCount; i++) {
            address depositor = address(
                uint160(uint256(keccak256(abi.encodePacked(i))))
            );

            deal(STAKING_TOKEN, depositor, _amount);

            vm.startPrank(depositor);
            IERC20(STAKING_TOKEN).approve(address(delegate), _amount);
            delegate.stake(keyper, _amount);
            vm.stopPrank();
        }

        _jumpAhead(_jump);

        uint256 rewardsPreviousKeyper = 0;

        for (uint256 i = 0; i < _depositorsCount; i++) {
            address depositor = address(
                uint160(uint256(keccak256(abi.encodePacked(i))))
            );
            vm.startPrank(depositor);
            uint256 rewards = delegate.claimRewards(0);
            vm.stopPrank();

            if (i > 0) {
                assertApproxEqAbs(rewards, rewardsPreviousKeyper, 0.1e18);
            }

            rewardsPreviousKeyper = rewards;
        }
    }
}
