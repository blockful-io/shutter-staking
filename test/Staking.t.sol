// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "@forge-std/Test.sol";

import {FixedPointMathLib} from "@solmate/utils/FixedPointMathLib.sol";
import {TransparentUpgradeableProxy, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Staking} from "src/Staking.sol";
import {RewardsDistributor} from "src/RewardsDistributor.sol";
import {IRewardsDistributor} from "src/interfaces/IRewardsDistributor.sol";
import {MockGovToken} from "test/mocks/MockGovToken.sol";
import {ProxyUtils} from "test/helper/ProxyUtils.sol";

contract StakingTest is Test {
    using FixedPointMathLib for uint256;

    Staking public staking;
    IRewardsDistributor public rewardsDistributor;
    MockGovToken public govToken;

    uint256 constant LOCK_PERIOD = 182 days; // 6 months
    uint256 constant MIN_STAKE = 50_000 * 1e18; // 50k
    uint256 constant REWARD_RATE = 0.1e18;

    function setUp() public {
        // Set the block timestamp to an arbitrary value to avoid introducing assumptions into tests
        // based on a starting timestamp of 0, which is the default.
        _jumpAhead(1234);

        govToken = new MockGovToken();
        _mintGovToken(address(this), 100_000_000e18);
        vm.label(address(govToken), "govToken");

        // deploy rewards distributor
        rewardsDistributor = IRewardsDistributor(
            address(
                new TransparentUpgradeableProxy(
                    address(new RewardsDistributor()),
                    address(this),
                    abi.encodeWithSignature(
                        "initialize(address)",
                        address(this)
                    )
                )
            )
        );

        // deploy staking
        address stakingImpl = address(new Staking());

        staking = Staking(
            address(
                new TransparentUpgradeableProxy(stakingImpl, address(this), "")
            )
        );
        vm.label(address(staking), "staking");

        staking.initialize(
            address(this), // owner
            address(govToken),
            address(rewardsDistributor),
            LOCK_PERIOD,
            MIN_STAKE
        );

        staking = Staking(staking);

        rewardsDistributor.setRewardConfiguration(
            address(staking),
            address(govToken),
            REWARD_RATE
        );

        // fund reward distribution
        govToken.transfer(address(rewardsDistributor), 100_000_000e18);
    }

    function _jumpAhead(uint256 _seconds) public {
        vm.warp(block.timestamp + _seconds);
    }

    function _boundMintAmount(uint96 _amount) internal pure returns (uint256) {
        return bound(_amount, 0, 10_000_000e18);
    }

    function _boundRealisticTimeAhead(
        uint256 _time
    ) internal pure returns (uint256) {
        return bound(_time, 1, 105 weeks); // two years
    }

    function _boundUnlockedTime(uint256 _time) internal view returns (uint256) {
        return bound(_time, block.timestamp + LOCK_PERIOD, 105 weeks);
    }

    function _mintGovToken(address _to, uint256 _amount) internal {
        vm.assume(
            _to != address(0) &&
                _to != address(staking) &&
                _to != ProxyUtils.getAdminAddress(address(staking))
        );

        govToken.mint(_to, _amount);
    }

    function _boundToRealisticStake(
        uint256 _stakeAmount
    ) public pure returns (uint256 _boundedStakeAmount) {
        _boundedStakeAmount = uint256(
            bound(_stakeAmount, MIN_STAKE, 5_000_000e18)
        );
    }

    function _stake(
        address _keyper,
        uint256 _amount
    ) internal returns (uint256 _stakeId) {
        vm.assume(
            _keyper != address(0) &&
                uint160(_keyper) > 0x100 && // ignore precompiled address
                _keyper != address(this) &&
                _keyper != address(staking) &&
                _keyper != ProxyUtils.getAdminAddress(address(staking))
        );

        vm.startPrank(_keyper);
        govToken.approve(address(staking), _amount);
        _stakeId = staking.stake(_amount);
        vm.stopPrank();
    }

    function _setKeyper(address _keyper, bool _isKeyper) internal {
        staking.setKeyper(_keyper, _isKeyper);
    }

    function _convertToSharesIncludeRewardsDistributed(
        uint256 _amount,
        uint256 _rewardsDistributed
    ) internal view returns (uint256) {
        uint256 supply = staking.totalSupply();

        uint256 assets = staking.totalAssets() + _rewardsDistributed;

        return supply == 0 ? _amount : _amount.mulDivDown(supply, assets);
    }
}

contract Initializer is StakingTest {
    function test_Initialize() public view {
        assertEq(staking.owner(), address(this), "Wrong owner");
        assertEq(
            address(staking.STAKING_TOKEN()),
            address(govToken),
            "Wrong staking token"
        );
        assertEq(
            address(staking.rewardsDistributor()),
            address(rewardsDistributor),
            "Wrong rewards distributor"
        );
        assertEq(staking.lockPeriod(), LOCK_PERIOD, "Wrong lock period");
        assertEq(staking.minStake(), MIN_STAKE, "Wrong min stake");
    }
}

contract Stake is StakingTest {
    function testFuzz_TransferTokensWhenStaking(
        address _depositor,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        _stake(_depositor, _amount);
        assertEq(govToken.balanceOf(_depositor), 0, "Wrong balance");
        assertEq(
            govToken.balanceOf(address(staking)),
            _amount,
            "Wrong balance"
        );
    }

    function testFuzz_EmitsAStakeEventWhenStaking(
        address _depositor,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        vm.assume(_depositor != address(0));

        uint256 shares = staking.convertToShares(_amount);

        vm.startPrank(_depositor);
        govToken.approve(address(staking), _amount);
        vm.expectEmit();
        emit Staking.Staked(_depositor, _amount, shares, LOCK_PERIOD);

        staking.stake(_amount);
        vm.stopPrank();
    }

    function testFuzz_UpdatesTotalSupplyWhenStaking(
        address _depositor,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        vm.assume(_depositor != address(0));

        _stake(_depositor, _amount);

        assertEq(staking.totalSupply(), _amount, "Wrong total supply");
    }

    function testFuzz_UpdatesTotalSupplyWhenTwoAccountsStakes(
        address _depositor1,
        address _depositor2,
        uint256 _amount1,
        uint256 _amount2
    ) public {
        _amount1 = _boundToRealisticStake(_amount1);
        _amount2 = _boundToRealisticStake(_amount2);

        _mintGovToken(_depositor1, _amount1);
        _mintGovToken(_depositor2, _amount2);

        _setKeyper(_depositor1, true);
        _setKeyper(_depositor2, true);

        vm.assume(_depositor1 != address(0));
        vm.assume(_depositor2 != address(0));

        _stake(_depositor1, _amount1);
        _stake(_depositor2, _amount2);

        assertEq(
            staking.totalSupply(),
            _amount1 + _amount2,
            "Wrong total supply"
        );
    }

    function testFuzz_UpdateSharesWhenStaking(
        address _depositor,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        vm.assume(_depositor != address(0));

        uint256 _shares = staking.convertToShares(_amount);

        _stake(_depositor, _amount);

        assertEq(staking.balanceOf(_depositor), _shares, "Wrong balance");
    }

    function testFuzz_UpdateSharesWhenStakingTwice(
        address _depositor,
        uint256 _amount1,
        uint256 _amount2,
        uint256 _jump
    ) public {
        _amount1 = _boundToRealisticStake(_amount1);
        _amount2 = _boundToRealisticStake(_amount2);

        _jump = _boundRealisticTimeAhead(_jump);

        _mintGovToken(_depositor, _amount1 + _amount2);
        _setKeyper(_depositor, true);

        vm.assume(_depositor != address(0));

        uint256 _shares1 = staking.convertToShares(_amount1);

        uint256 timestampBefore = block.timestamp;

        _stake(_depositor, _amount1);

        _jumpAhead(_jump);
        uint256 _shares2 = _convertToSharesIncludeRewardsDistributed(
            _amount2,
            REWARD_RATE * (block.timestamp - timestampBefore)
        );

        _stake(_depositor, _amount2);

        assertEq(
            staking.balanceOf(_depositor),
            _shares1 + _shares2,
            "Wrong balance"
        );
    }

    function testFuzz_Depositor1AndDepositor2ReceivesTheSameAmountOfSharesWhenStakingSameAmountInTheSameBlock(
        address _depositor1,
        address _depositor2,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor1, _amount);
        _mintGovToken(_depositor2, _amount);

        _setKeyper(_depositor1, true);
        _setKeyper(_depositor2, true);

        vm.assume(_depositor1 != address(0));
        vm.assume(_depositor2 != address(0));

        _stake(_depositor1, _amount);
        _stake(_depositor2, _amount);

        assertEq(
            staking.balanceOf(_depositor1),
            staking.balanceOf(_depositor2),
            "Wrong balance"
        );
    }

    function testFuzz_Depositor1ReceivesMoreShareWhenStakingBeforeDepositor2(
        address _depositor1,
        address _depositor2,
        uint256 _amount,
        uint256 _jump
    ) public {
        _amount = _boundToRealisticStake(_amount);
        _jump = _boundRealisticTimeAhead(_jump);

        _mintGovToken(_depositor1, _amount);
        _mintGovToken(_depositor2, _amount);

        _setKeyper(_depositor1, true);
        _setKeyper(_depositor2, true);

        _stake(_depositor1, _amount);

        _jumpAhead(_jump);

        _stake(_depositor2, _amount);

        assertGt(
            staking.balanceOf(_depositor1),
            staking.balanceOf(_depositor2),
            "Wrong balance"
        );
    }

    function testFuzz_UpdateContractGovTokenBalanceWhenStaking(
        address _depositor,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        uint256 _contractBalanceBefore = govToken.balanceOf(address(staking));

        _stake(_depositor, _amount);

        uint256 _contractBalanceAfter = govToken.balanceOf(address(staking));

        assertEq(
            _contractBalanceAfter - _contractBalanceBefore,
            _amount,
            "Wrong balance"
        );
    }

    function testFuzz_trackAmountStakedWhenStaking(
        address _depositor,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        vm.assume(_depositor != address(0));

        uint256 stakeId = _stake(_depositor, _amount);

        (uint256 amount, , ) = staking.stakes(stakeId);

        assertEq(amount, _amount, "Wrong amount");
    }

    function testFuzz_trackTimestampWhenStaking(
        address _depositor,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        vm.assume(_depositor != address(0));

        uint256 stakeId = _stake(_depositor, _amount);

        (, uint256 timestamp, ) = staking.stakes(stakeId);

        assertEq(timestamp, block.timestamp, "Wrong timestamp");
    }

    function testFuzz_trackLockPeriodWhenStaking(
        address _depositor,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        vm.assume(_depositor != address(0));

        uint256 stakeId = _stake(_depositor, _amount);

        (, , uint256 lockPeriod) = staking.stakes(stakeId);

        assertEq(lockPeriod, LOCK_PERIOD, "Wrong lock period");
    }

    function testFuzz_trackStakeIndividuallyPerStake(
        address _depositor,
        uint256 _amount1,
        uint256 _amount2
    ) public {
        _amount1 = _boundToRealisticStake(_amount1);
        _amount2 = _boundToRealisticStake(_amount2);

        _mintGovToken(_depositor, _amount1 + _amount2);
        _setKeyper(_depositor, true);

        vm.assume(_depositor != address(0) && _depositor != address(this));

        uint256 stakeId1 = _stake(_depositor, _amount1);

        (uint256 amount1, uint256 timestamp, ) = staking.stakes(stakeId1);

        _jumpAhead(1);

        uint256 stakeId2 = _stake(_depositor, _amount2);
        (uint256 amount2, uint256 timestamp2, ) = staking.stakes(stakeId2);

        assertEq(amount1, _amount1, "Wrong amount");
        assertEq(amount2, _amount2, "Wrong amount");

        assertEq(timestamp, block.timestamp - 1, "Wrong timestamp");
        assertEq(timestamp2, block.timestamp, "Wrong timestamp");
    }

    function testFuzz_increaseDepositorTotalLockedWhenStaking() public {}
}

contract ClaimRewards is StakingTest {
    function testFuzz_UpdateStakerGovTokenBalanceWhenClaimingRewards(
        address _depositor,
        uint256 _amount,
        uint256 _jump
    ) public {
        _amount = _boundToRealisticStake(_amount);
        _jump = _boundRealisticTimeAhead(_jump);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        _stake(_depositor, _amount);

        uint256 timestampBefore = block.timestamp;

        _jumpAhead(_jump);

        vm.prank(_depositor);
        staking.claimRewards(0);

        uint256 expectedRewards = REWARD_RATE *
            (block.timestamp - timestampBefore);

        assertEq(
            govToken.balanceOf(_depositor),
            expectedRewards,
            "Wrong balance"
        );
    }

    function testFuzz_GovTokenBalanceUnchangedWhenClaimingRewardsOnlyStaker(
        address _depositor,
        uint256 _amount,
        uint256 _jump
    ) public {
        _amount = _boundToRealisticStake(_amount);
        _jump = _boundRealisticTimeAhead(_jump);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        _stake(_depositor, _amount);

        uint256 contractBalanceBefore = govToken.balanceOf(address(staking));

        _jumpAhead(_jump);

        vm.prank(_depositor);
        staking.claimRewards(0);

        uint256 contractBalanceAfter = govToken.balanceOf(address(staking));

        assertEq(
            contractBalanceBefore - contractBalanceAfter,
            0,
            "Wrong balance"
        );
    }

    function testFuzz_EmitRewardsClaimedEventWhenClaimingRewards(
        address _depositor,
        uint256 _amount,
        uint256 _jump
    ) public {
        _amount = _boundToRealisticStake(_amount);
        _jump = _boundRealisticTimeAhead(_jump);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        _stake(_depositor, _amount);

        uint256 timestampBefore = block.timestamp;

        _jumpAhead(_jump);

        vm.prank(_depositor);
        vm.expectEmit();
        emit Staking.RewardsClaimed(
            _depositor,
            REWARD_RATE * (block.timestamp - timestampBefore)
        );

        staking.claimRewards(0);
    }

    function testFuzz_ClaimAllRewardsOnlyStaker(
        address _depositor,
        uint256 _amount,
        uint256 _jump
    ) public {
        _amount = _boundToRealisticStake(_amount);
        _jump = _boundRealisticTimeAhead(_jump);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        _stake(_depositor, _amount);

        uint256 timestampBefore = block.timestamp;

        _jumpAhead(_jump);

        vm.prank(_depositor);
        uint256 rewards = staking.claimRewards(0);

        uint256 expectedRewards = REWARD_RATE *
            (block.timestamp - timestampBefore);

        assertEq(rewards, expectedRewards, "Wrong rewards");
    }

    function testFuzz_claimRewardBurnShares(
        address _depositor,
        uint256 _amount,
        uint256 _jump
    ) public {
        _amount = _boundToRealisticStake(_amount);
        _jump = _boundRealisticTimeAhead(_jump);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        _stake(_depositor, _amount);

        uint256 timestampBefore = block.timestamp;
        uint256 sharesBefore = staking.balanceOf(_depositor);

        _jumpAhead(_jump);

        uint256 expectedRewards = REWARD_RATE *
            (block.timestamp - timestampBefore);

        uint256 burnShares = _convertToSharesIncludeRewardsDistributed(
            expectedRewards,
            expectedRewards
        );

        vm.prank(_depositor);
        staking.claimRewards(0);

        uint256 sharesAfter = staking.balanceOf(_depositor);

        assertEq(sharesBefore - sharesAfter, burnShares, "Wrong shares burned");
    }

    function testFuzz_UpdateTotalSupplyWhenClaimingRewards(
        address _depositor,
        uint256 _amount,
        uint256 _jump
    ) public {
        _amount = _boundToRealisticStake(_amount);
        _jump = _boundRealisticTimeAhead(_jump);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        _stake(_depositor, _amount);

        uint256 timestampBefore = block.timestamp;

        _jumpAhead(_jump);

        uint256 expectedRewards = REWARD_RATE *
            (block.timestamp - timestampBefore);

        uint256 burnShares = _convertToSharesIncludeRewardsDistributed(
            expectedRewards,
            expectedRewards
        );

        vm.prank(_depositor);
        staking.claimRewards(0);

        assertEq(
            staking.totalSupply(),
            _amount - burnShares,
            "Wrong total supply"
        );
    }

    function testFuzz_Depositor1GetsMoreRewardsThanDepositor2WhenStakingFirst(
        address _depositor1,
        address _depositor2,
        uint256 _amount,
        uint256 _jump1,
        uint256 _jump2
    ) public {
        _amount = _boundToRealisticStake(_amount);
        _jump1 = _boundRealisticTimeAhead(_jump1);
        _jump2 = _boundRealisticTimeAhead(_jump2);

        _mintGovToken(_depositor1, _amount);
        _mintGovToken(_depositor2, _amount);

        _setKeyper(_depositor1, true);
        _setKeyper(_depositor2, true);

        _stake(_depositor1, _amount);

        _jumpAhead(_jump1);

        _stake(_depositor2, _amount);

        _jumpAhead(_jump2);

        vm.prank(_depositor1);
        uint256 rewards1 = staking.claimRewards(0);
        vm.prank(_depositor2);
        uint256 rewards2 = staking.claimRewards(0);

        assertGt(rewards1, rewards2, "Wrong rewards");
    }

    function testFuzz_DepositorsGetApproxSameRewardAmountWhenStakingSameAmountInSameBlock(
        address _depositor1,
        address _depositor2,
        uint256 _amount,
        uint256 _jump
    ) public {
        _amount = _boundToRealisticStake(_amount);
        _jump = _boundRealisticTimeAhead(_jump);

        _mintGovToken(_depositor1, _amount);
        _mintGovToken(_depositor2, _amount);

        _setKeyper(_depositor1, true);
        _setKeyper(_depositor2, true);

        _stake(_depositor1, _amount);
        _stake(_depositor2, _amount);

        _jumpAhead(_jump);

        vm.prank(_depositor1);
        uint256 rewards1 = staking.claimRewards(0);
        vm.prank(_depositor2);
        uint256 rewards2 = staking.claimRewards(0);

        assertApproxEqAbs(rewards1, rewards2, 1e18, "Wrong rewards");
    }

    function testFuzz_DepositorGetExactSpecifiedAmountWhenClaimingRewards(
        address _depositor,
        uint256 _amount,
        uint256 _jump
    ) public {
        _amount = _boundToRealisticStake(_amount);
        _jump = _boundRealisticTimeAhead(_jump);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        _stake(_depositor, _amount);

        uint256 timestampBefore = block.timestamp;

        _jumpAhead(_jump);

        uint256 expectedRewards = REWARD_RATE *
            (block.timestamp - timestampBefore);

        vm.prank(_depositor);
        uint256 rewards = staking.claimRewards(expectedRewards);

        assertEq(rewards, expectedRewards, "Wrong rewards");
    }

    function testFuzz_OnlyBurnTheCorrespondedAmountOfSharesSpecifiedWhenClaimingRewards(
        address _depositor,
        uint256 _amount,
        uint256 _jump
    ) public {
        _amount = _boundToRealisticStake(_amount);
        _jump = _boundRealisticTimeAhead(_jump);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        _stake(_depositor, _amount);

        uint256 timestampBefore = block.timestamp;
        uint256 sharesBefore = staking.balanceOf(_depositor);

        _jumpAhead(_jump);

        uint256 expectedRewards = REWARD_RATE *
            (block.timestamp - timestampBefore);
        uint256 rewardsToClaim = expectedRewards / 2;

        uint256 burnShares = _convertToSharesIncludeRewardsDistributed(
            rewardsToClaim,
            expectedRewards
        );

        vm.prank(_depositor);
        staking.claimRewards(rewardsToClaim);

        uint256 sharesAfter = staking.balanceOf(_depositor);

        assertEq(sharesBefore - sharesAfter, burnShares, "Wrong shares burned");
    }
}

contract Unstake is StakingTest {
    function testFuzz_UpdateStakerGovTokenBalanceWhenUnstaking(
        address _depositor,
        uint256 _amount,
        uint256 _jump
    ) public {
        _amount = _boundToRealisticStake(_amount);
        _jump = _boundUnlockedTime(_jump);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        uint256 stakeIndex = _stake(_depositor, _amount);

        assertEq(govToken.balanceOf(_depositor), 0, "Wrong balance");

        _jumpAhead(_jump);

        vm.prank(_depositor);
        staking.unstake(_depositor, stakeIndex, 0);

        assertEq(govToken.balanceOf(_depositor), _amount, "Wrong balance");
    }

    function testFuzz_GovTokenBalanceUnchangedWhenUnstakingOnlyStaker(
        address _depositor,
        uint256 _amount,
        uint256 _jump
    ) public {
        _amount = _boundToRealisticStake(_amount);
        _jump = _boundUnlockedTime(_jump);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        uint256 stakeIndex = _stake(_depositor, _amount);

        uint256 timestampBefore = block.timestamp;

        _jumpAhead(_jump);

        uint256 expectedRewards = REWARD_RATE *
            (block.timestamp - timestampBefore);

        vm.prank(_depositor);
        staking.unstake(_depositor, stakeIndex, 0);

        if (expectedRewards > 0) {
            assertEq(
                govToken.balanceOf(address(staking)),
                expectedRewards,
                "Wrong balance"
            );
        }
    }

    function testFuzz_EmitUnstakeEventWhenUnstaking(
        address _depositor,
        uint256 _amount,
        uint256 _jump
    ) public {
        _amount = _boundToRealisticStake(_amount);
        _jump = _boundUnlockedTime(_jump);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        uint256 stakeIndex = _stake(_depositor, _amount);

        uint256 timestampBefore = block.timestamp;

        _jumpAhead(_jump);

        uint256 shares = _convertToSharesIncludeRewardsDistributed(
            _amount,
            REWARD_RATE * (block.timestamp - timestampBefore)
        );
        vm.expectEmit();
        emit Staking.Unstaked(_depositor, _amount, shares);

        vm.prank(_depositor);
        staking.unstake(_depositor, stakeIndex, 0);
    }

    function testFuzz_UnstakeSpecifiedAmount(
        address _depositor,
        uint256 _amount,
        uint256 _jump
    ) public {
        _amount = _boundToRealisticStake(_amount);
        _jump = _boundUnlockedTime(_jump);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        uint256 stakeIndex = _stake(_depositor, _amount);

        _jumpAhead(_jump);

        vm.prank(_depositor);
        staking.unstake(_depositor, stakeIndex, _amount);

        assertEq(govToken.balanceOf(_depositor), _amount, "Wrong balance");
    }

    function testFuzz_UpdateTotalSupplyWhenUnstaking(
        address _depositor,
        uint256 _amount,
        uint256 _jump
    ) public {
        _amount = _boundToRealisticStake(_amount);
        _jump = _boundUnlockedTime(_jump);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        uint256 stakeIndex = _stake(_depositor, _amount);

        uint256 timestampBefore = block.timestamp;

        _jumpAhead(_jump);

        uint256 rewards = REWARD_RATE * (block.timestamp - timestampBefore);

        vm.prank(_depositor);
        staking.unstake(_depositor, stakeIndex, 0);

        uint256 expectedSharesRemaining = staking.convertToShares(rewards);

        uint256 totalSupplyAfter = staking.totalSupply();

        assertEq(
            totalSupplyAfter,
            expectedSharesRemaining,
            "Wrong total supply"
        );
    }

    function testFuzz_AnyoneCanUnstakeOnBehalfOfKeyperWhenKeyperIsNotAKeyperAnymore(
        address _depositor,
        address _anyone,
        uint256 _amount,
        uint256 _jump
    ) public {
        _amount = _boundToRealisticStake(_amount);
        _jump = _boundRealisticTimeAhead(_jump);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        uint256 stakeIndex = _stake(_depositor, _amount);
        assertEq(govToken.balanceOf(_depositor), 0, "Wrong balance");

        _setKeyper(_depositor, false);

        _jumpAhead(_jump);

        vm.prank(_anyone);
        staking.unstake(_depositor, stakeIndex, 0);

        assertEq(govToken.balanceOf(_depositor), _amount, "Wrong balance");
    }

    function testFuzz_DepositorHasMultipleStakesUnstakeCorrectStake(
        address _depositor,
        uint256 _amount1,
        uint256 _amount2,
        uint256 _jump
    ) public {
        _amount1 = _boundToRealisticStake(_amount1);
        _amount2 = _boundToRealisticStake(_amount2);
        _jump = _boundUnlockedTime(_jump);

        _mintGovToken(_depositor, _amount1 + _amount2);
        _setKeyper(_depositor, true);

        uint256 stakeIndex1 = _stake(_depositor, _amount1);
        uint256 stakeIndex2 = _stake(_depositor, _amount2);
        assertEq(govToken.balanceOf(_depositor), 0, "Wrong balance");

        _jumpAhead(_jump);

        vm.prank(_depositor);
        staking.unstake(_depositor, stakeIndex1, 0);

        assertEq(govToken.balanceOf(_depositor), _amount1, "Wrong balance");

        vm.prank(_depositor);
        staking.unstake(_depositor, stakeIndex2, 0);

        assertEq(
            govToken.balanceOf(_depositor),
            _amount1 + _amount2,
            "Wrong balance"
        );
    }
}
