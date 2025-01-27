// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@forge-std/Test.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {TransparentUpgradeableProxy, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {FixedPointMathLib} from "src/libraries/FixedPointMathLib.sol";
import {Staking} from "src/Staking.sol";
import {BaseStaking} from "src/BaseStaking.sol";
import {RewardsDistributor} from "src/RewardsDistributor.sol";
import {IRewardsDistributor} from "src/interfaces/IRewardsDistributor.sol";
import {MockGovToken} from "test/mocks/MockGovToken.sol";
import {ProxyUtils} from "test/helpers/ProxyUtils.sol";
import {StakingHarness} from "test/helpers/StakingHarness.sol";

contract StakingTest is Test {
    using FixedPointMathLib for uint256;

    StakingHarness public staking;
    IRewardsDistributor public rewardsDistributor;
    MockGovToken public govToken;

    uint256 constant LOCK_PERIOD = 182 days; // 6 months
    uint256 constant MIN_STAKE = 50_000e18; // 50k
    uint256 constant REWARD_RATE = 0.1e18;
    uint256 constant INITIAL_DEPOSIT = 10000e18;

    function setUp() public {
        // Set the block timestamp to an arbitrary value to avoid introducing assumptions into tests
        // based on a starting timestamp of 0, which is the default.
        _jumpAhead(1234);

        govToken = new MockGovToken();
        vm.label(address(govToken), "govToken");

        // deploy rewards distributor
        rewardsDistributor = IRewardsDistributor(
            new RewardsDistributor(address(this), address(govToken))
        );

        // deploy staking
        address stakingImpl = address(new StakingHarness());

        staking = StakingHarness(
            address(
                new TransparentUpgradeableProxy(stakingImpl, address(this), "")
            )
        );
        vm.label(address(staking), "staking");

        _mintGovToken(address(this), INITIAL_DEPOSIT);

        govToken.approve(address(staking), INITIAL_DEPOSIT);

        staking.initialize(
            address(this), // owner
            address(govToken),
            address(rewardsDistributor),
            LOCK_PERIOD,
            MIN_STAKE
        );

        rewardsDistributor.setRewardConfiguration(
            address(staking),
            REWARD_RATE
        );

        // fund reward distribution

        _mintGovToken(address(rewardsDistributor), 100_000_000e18);
    }

    function _jumpAhead(uint256 _seconds) public {
        vm.warp(vm.getBlockTimestamp() + _seconds);
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
        return bound(_time, vm.getBlockTimestamp() + LOCK_PERIOD, 105 weeks);
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

    function _boundToMoreThanMinStake(
        uint256 _stakeAmount
    ) public pure returns (uint256 _boundedStakeAmount) {
        _boundedStakeAmount = uint256(
            bound(_stakeAmount, MIN_STAKE + 1, 5_000_000e18)
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
                _keyper != ProxyUtils.getAdminAddress(address(staking)) &&
                _keyper != address(rewardsDistributor)
        );

        vm.startPrank(_keyper);
        govToken.approve(address(staking), _amount);
        _stakeId = staking.stake(_amount);
        vm.stopPrank();
    }

    function _setKeyper(address _keyper, bool _isKeyper) internal {
        staking.setKeyper(_keyper, _isKeyper);
    }

    function _previewWithdrawIncludeRewardsDistributed(
        uint256 _amount,
        uint256 _rewardsDistributed
    ) internal view returns (uint256) {
        uint256 supply = staking.totalSupply();

        uint256 assets = govToken.balanceOf(address(staking)) +
            _rewardsDistributed;
        return _amount.mulDivUp(supply, assets);
    }

    function _convertToSharesIncludeRewardsDistributed(
        uint256 _amount,
        uint256 _rewardsDistributed
    ) internal view returns (uint256) {
        uint256 supply = staking.totalSupply();

        uint256 assets = govToken.balanceOf(address(staking)) +
            _rewardsDistributed;

        return _amount.mulDivDown(supply, assets);
    }

    function _convertToAssetsIncludeRewardsDistributed(
        uint256 _shares,
        uint256 _rewardsDistributed
    ) internal view returns (uint256) {
        uint256 supply = staking.totalSupply();

        uint256 assets = govToken.balanceOf(address(staking)) +
            _rewardsDistributed;

        return _shares.mulDivDown(assets, supply);
    }

    function _maxWithdraw(address user) internal view returns (uint256) {
        uint256 assets = staking.convertToAssets(staking.balanceOf(user));
        uint256 locked = staking.totalLocked(user);

        return locked >= assets ? 0 : assets - locked;
    }
}

contract Initializer is StakingTest {
    function test_Initialize() public view {
        assertEq(IERC20Metadata(address(staking)).name(), "Staked SHU");
        assertEq(IERC20Metadata(address(staking)).symbol(), "sSHU");
        assertEq(staking.owner(), address(this), "Wrong owner");
        assertEq(
            address(staking.stakingToken()),
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

        assertEq(staking.exposed_nextStakeId(), 1);
    }

    function test_RevertIf_InitializeImplementation() public {
        Staking stakingImpl = new Staking();

        vm.expectRevert();
        stakingImpl.initialize(
            address(this),
            address(govToken),
            address(rewardsDistributor),
            LOCK_PERIOD,
            MIN_STAKE
        );
    }
}

contract Stake is StakingTest {
    function testFuzz_ReturnStakeIdWhenStaking(
        address _depositor,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        vm.assume(_depositor != address(0));

        vm.startPrank(_depositor);
        govToken.approve(address(staking), _amount);

        uint256 expectedStakeId = staking.exposed_nextStakeId();

        uint256 stakeId = staking.stake(_amount);

        assertEq(stakeId, expectedStakeId, "Wrong stake id");
        vm.stopPrank();
    }

    function testFuzz_IncreaseNextStakeId(
        address _depositor,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        vm.assume(_depositor != address(0));

        uint256 nextStakeIdBefore = staking.exposed_nextStakeId();

        _stake(_depositor, _amount);

        uint256 nextStakeIdAfter = staking.exposed_nextStakeId();

        assertEq(
            nextStakeIdAfter - nextStakeIdBefore,
            1,
            "Wrong next stake id"
        );
    }

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
            _amount + INITIAL_DEPOSIT,
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

        vm.startPrank(_depositor);
        govToken.approve(address(staking), _amount);
        vm.expectEmit();
        emit Staking.Staked(_depositor, _amount, LOCK_PERIOD);

        staking.stake(_amount);
        vm.stopPrank();
    }

    function testFuzz_UpdateTotalSupplyWhenStaking(
        address _depositor,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        uint256 supplyBefore = staking.totalSupply();

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        vm.assume(_depositor != address(0));

        uint256 expectedShares = staking.convertToShares(_amount);

        _stake(_depositor, _amount);

        assertEq(
            staking.totalSupply(),
            supplyBefore + expectedShares,
            "Wrong total supply"
        );
    }

    function testFuzz_UpdateTotalSupplyWhenTwoAccountsStakes(
        address _depositor1,
        address _depositor2,
        uint256 _amount1,
        uint256 _amount2
    ) public {
        _amount1 = _boundToRealisticStake(_amount1);
        _amount2 = _boundToRealisticStake(_amount2);

        uint256 supplyBefore = staking.totalSupply();

        _mintGovToken(_depositor1, _amount1);
        _mintGovToken(_depositor2, _amount2);

        _setKeyper(_depositor1, true);
        _setKeyper(_depositor2, true);

        uint256 expectedSharesDepositor1 = staking.convertToShares(_amount1);
        _stake(_depositor1, _amount1);

        uint256 expectedSharesDepositor2 = staking.convertToShares(_amount2);
        _stake(_depositor2, _amount2);

        assertEq(
            staking.totalSupply(),
            supplyBefore + expectedSharesDepositor1 + expectedSharesDepositor2,
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

        uint256 _shares1 = staking.convertToShares(_amount1);

        uint256 timestampBefore = vm.getBlockTimestamp();

        _stake(_depositor, _amount1);

        _jumpAhead(_jump);
        uint256 _shares2 = _convertToSharesIncludeRewardsDistributed(
            _amount2,
            REWARD_RATE * (vm.getBlockTimestamp() - timestampBefore)
        );

        _stake(_depositor, _amount2);

        // need to accept a small error due to the donation attack prevention
        assertApproxEqAbs(
            staking.balanceOf(_depositor),
            _shares1 + _shares2,
            1e18,
            "Wrong balance"
        );
    }

    function testFuzz_SecondStakeDoesNotRequireMinStake(
        address _depositor,
        uint256 _amount1,
        uint256 _amount2
    ) public {
        _amount1 = _boundToRealisticStake(_amount1);
        _amount2 = bound(_amount2, 1, MIN_STAKE);

        _mintGovToken(_depositor, _amount1 + _amount2);
        _setKeyper(_depositor, true);

        vm.assume(_depositor != address(0));

        _stake(_depositor, _amount1);

        _stake(_depositor, _amount2);

        assertEq(
            staking.balanceOf(_depositor),
            _amount1 + _amount2,
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
        vm.assume(_depositor1 != _depositor2);

        uint256 shares = staking.convertToShares(_amount);

        _stake(_depositor1, _amount);
        _stake(_depositor2, _amount);

        assertEq(
            staking.balanceOf(_depositor1),
            staking.balanceOf(_depositor2),
            "Wrong balance"
        );
        assertEq(staking.balanceOf(_depositor1), shares);
        assertEq(staking.balanceOf(_depositor2), shares);
        assertEq(staking.totalSupply(), 2 * shares + INITIAL_DEPOSIT);
    }

    function testFuzz_Depositor1ReceivesMoreShareWhenStakingBeforeDepositor2(
        address _depositor1,
        address _depositor2,
        uint256 _amount,
        uint256 _jump
    ) public {
        vm.assume(_depositor1 != _depositor2);
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

    function testFuzz_TrackAmountStakedWhenStaking(
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

    function testFuzz_TrackTimestampWhenStaking(
        address _depositor,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        uint256 stakeId = _stake(_depositor, _amount);

        (, uint256 timestamp, ) = staking.stakes(stakeId);

        assertEq(timestamp, vm.getBlockTimestamp(), "Wrong timestamp");
    }

    function testFuzz_TrackLockPeriodWhenStaking(
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

    function testFuzz_TrackStakeIndividuallyPerStake(
        address _depositor,
        uint256 _amount1,
        uint256 _amount2
    ) public {
        _amount1 = _boundToRealisticStake(_amount1);
        _amount2 = _boundToRealisticStake(_amount2);

        _mintGovToken(_depositor, _amount1 + _amount2);
        _setKeyper(_depositor, true);

        uint256 stakeId1 = _stake(_depositor, _amount1);

        (uint256 amount1, uint256 timestamp, ) = staking.stakes(stakeId1);

        _jumpAhead(1);

        uint256 stakeId2 = _stake(_depositor, _amount2);
        (uint256 amount2, uint256 timestamp2, ) = staking.stakes(stakeId2);

        assertEq(amount1, _amount1, "Wrong amount");
        assertEq(amount2, _amount2, "Wrong amount");

        assertEq(timestamp, vm.getBlockTimestamp() - 1, "Wrong timestamp");
        assertEq(timestamp2, vm.getBlockTimestamp(), "Wrong timestamp");
    }

    function testFuzz_StakeReturnsStakeId(
        address _depositor,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        vm.assume(_depositor != address(0));

        uint256 stakeId = _stake(_depositor, _amount);

        assertGt(stakeId, 0, "Wrong stake id");
    }

    function testFuzz_IncreaseTotalLockedWhenStaking(
        address _depositor,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        vm.assume(_depositor != address(0));

        uint256 totalLockedBefore = staking.totalLocked(_depositor);

        _stake(_depositor, _amount);

        uint256 totalLockedAfter = staking.totalLocked(_depositor);

        assertEq(
            totalLockedAfter - totalLockedBefore,
            _amount,
            "Wrong total locked"
        );
    }

    function testFuzz_RevertIf_StakingLessThanMinStake(
        address _depositor
    ) public {
        uint256 amount = MIN_STAKE - 1;

        _mintGovToken(_depositor, amount);
        _setKeyper(_depositor, true);

        vm.assume(_depositor != address(0));

        vm.startPrank(_depositor);
        govToken.approve(address(staking), amount);

        vm.expectRevert(Staking.FirstStakeLessThanMinStake.selector);
        staking.stake(amount);

        vm.stopPrank();
    }

    function testFuzz_RevertIf_DepositorIsNotAKeyper(
        address _depositor,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor, _amount);

        vm.assume(_depositor != address(0));

        vm.startPrank(_depositor);
        govToken.approve(address(staking), _amount);

        vm.expectRevert(Staking.OnlyKeyper.selector);
        staking.stake(_amount);

        vm.stopPrank();
    }

    function testFuzz_RevertIf_ZeroAmount(address _depositor) public {
        vm.assume(
            _depositor != address(0) &&
                _depositor != ProxyUtils.getAdminAddress(address(staking))
        );
        _setKeyper(_depositor, true);

        vm.assume(_depositor != address(0));

        vm.startPrank(_depositor);

        vm.expectRevert(Staking.ZeroAmount.selector);
        staking.stake(0);

        vm.stopPrank();
    }

    function testFuzz_DonationAttackNoRewards(
        address bob,
        address alice,
        uint256 attackSize
    ) public {
        vm.assume(bob != alice);
        rewardsDistributor.removeRewardConfiguration(address(staking));

        attackSize = bound(attackSize, 2, 1000);

        uint256 initialStake = MIN_STAKE;
        uint256 donationAmount = MIN_STAKE * attackSize;
        uint256 bobStake = MIN_STAKE * attackSize;

        // first alice mints
        _mintGovToken(alice, initialStake);
        _setKeyper(alice, true);
        _stake(alice, initialStake);

        // simulate donation
        govToken.mint(address(staking), donationAmount);

        assertEq(
            govToken.balanceOf(address(staking)),
            initialStake + donationAmount + INITIAL_DEPOSIT
        );

        // bob mints
        _mintGovToken(bob, bobStake);
        _setKeyper(bob, true);
        uint256 bobStakeId = _stake(bob, bobStake);

        _jumpAhead(vm.getBlockTimestamp() + LOCK_PERIOD);
        vm.prank(alice);
        uint256 aliceUnstake = staking.unstake(alice, 1, 0);
        assertEq(aliceUnstake, initialStake);

        // alice claim rewards withdrawing donation
        vm.prank(alice);
        uint256 aliceRewards = staking.claimRewards(0);

        // attacker cost is greater than expected gains
        assertGtDecimal(
            donationAmount,
            aliceRewards,
            1e18,
            "Alice receive more than expend for the attack"
        );

        // bob unstake maximum he can unstake
        vm.prank(bob);
        staking.unstake(bob, bobStakeId, bobStake - MIN_STAKE - 1e17);

        assertApproxEqRel(
            govToken.balanceOf(bob),
            bobStake - MIN_STAKE,
            0.01e18,
            "Bob must receive the money back"
        );
    }
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

        _jumpAhead(_jump);

        // first 1000 shares was the dead shares so must decrease from the expected rewards
        uint256 assetsAmount = _convertToAssetsIncludeRewardsDistributed(
            staking.balanceOf(_depositor),
            REWARD_RATE * _jump
        );

        uint256 expectedRewards = assetsAmount - _amount;

        vm.prank(_depositor);
        staking.claimRewards(0);

        // need to accept a small error due to the donation attack prevention
        assertEq(
            govToken.balanceOf(_depositor),
            expectedRewards,
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

        uint256 timestampBefore = vm.getBlockTimestamp();

        _jumpAhead(_jump);

        vm.prank(_depositor);
        vm.expectEmit(true, true, false, false);
        emit BaseStaking.RewardsClaimed(
            _depositor,
            REWARD_RATE * (vm.getBlockTimestamp() - timestampBefore)
        );

        staking.claimRewards(0);
    }

    function testFuzz_ClaimRewardBurnShares(
        address _depositor,
        uint256 _amount,
        uint256 _jump
    ) public {
        _amount = _boundToRealisticStake(_amount);
        _jump = _boundRealisticTimeAhead(_jump);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        _stake(_depositor, _amount);

        uint256 sharesBefore = staking.balanceOf(_depositor);

        _jumpAhead(_jump);

        // first 1000 shares was the dead shares so must decrease from the expected rewards
        uint256 assetsAmount = _convertToAssetsIncludeRewardsDistributed(
            staking.balanceOf(_depositor),
            REWARD_RATE * _jump
        );

        uint256 expectedRewards = assetsAmount - _amount;

        uint256 burnShares = _previewWithdrawIncludeRewardsDistributed(
            expectedRewards,
            REWARD_RATE * _jump
        );

        vm.prank(_depositor);
        staking.claimRewards(0);

        uint256 sharesAfter = staking.balanceOf(_depositor);

        assertApproxEqAbs(
            sharesBefore - sharesAfter,
            burnShares,
            1e18,
            "Wrong shares burned"
        );
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

        uint256 totalSupplyBefore = staking.totalSupply();

        _jumpAhead(_jump);

        // first 1000 shares was the dead shares so must decrease from the expected rewards
        uint256 assetsAmount = _convertToAssetsIncludeRewardsDistributed(
            staking.balanceOf(_depositor),
            REWARD_RATE * _jump
        );

        uint256 expectedRewards = assetsAmount - _amount;

        uint256 burnShares = _previewWithdrawIncludeRewardsDistributed(
            expectedRewards,
            REWARD_RATE * _jump
        );

        vm.prank(_depositor);
        staking.claimRewards(0);

        uint256 totalSupplyAfter = staking.totalSupply();

        assertApproxEqAbs(
            totalSupplyAfter,
            totalSupplyBefore - burnShares,
            1,
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

        vm.assume(_depositor1 != _depositor2);

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

        vm.assume(_depositor1 != _depositor2);

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

        assertApproxEqAbs(rewards1, rewards2, 0.1e18, "Wrong rewards");
    }

    function testFuzz_DepositorGetExactSpecifiedAmountWhenClaimingRewards(
        address _depositor,
        uint256 _amount,
        uint256 _jump
    ) public {
        _amount = _boundToRealisticStake(_amount);
        _jump = _bound(_jump, 1 weeks, 105 weeks);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        _stake(_depositor, _amount);

        _jumpAhead(_jump);

        // first 1000 shares was the dead shares so must decrease from the expected rewards
        uint256 assetsAmount = _convertToAssetsIncludeRewardsDistributed(
            staking.balanceOf(_depositor),
            REWARD_RATE * _jump
        );

        uint256 expectedRewards = assetsAmount - _amount;

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

        uint256 sharesBefore = staking.balanceOf(_depositor);

        _jumpAhead(_jump);

        // first 1000 shares was the dead shares so must decrease from the expected rewards
        uint256 assetsAmount = _convertToAssetsIncludeRewardsDistributed(
            staking.balanceOf(_depositor),
            REWARD_RATE * _jump
        );

        uint256 expectedRewards = assetsAmount - _amount;

        uint256 burnShares = _previewWithdrawIncludeRewardsDistributed(
            expectedRewards / 2,
            REWARD_RATE * _jump
        );

        vm.prank(_depositor);
        staking.claimRewards(expectedRewards / 2);

        uint256 sharesAfter = staking.balanceOf(_depositor);

        assertEq(sharesBefore - sharesAfter, burnShares, "Wrong shares burned");
    }

    function testFuzz_RevertIf_NoRewardsToClaim(
        address _depositor,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        _stake(_depositor, _amount);

        vm.prank(_depositor);

        vm.expectRevert(BaseStaking.NoRewardsToClaim.selector);
        staking.claimRewards(0);
    }

    function testFuzz_RevertIf_UserHasNoShares(address _depositor) public {
        vm.assume(
            _depositor != address(0) &&
                _depositor != address(staking) &&
                _depositor != ProxyUtils.getAdminAddress(address(staking))
        );

        vm.prank(_depositor);
        vm.expectRevert(BaseStaking.NoRewardsToClaim.selector);
        staking.claimRewards(0);
    }

    function testFuzz_RevertIf_NoRewardsToClaimToThatUser(
        address _depositor1,
        address _depositor2,
        uint256 _amount1,
        uint256 _amount2,
        uint256 _jump
    ) public {
        _amount1 = _boundToRealisticStake(_amount1);
        _amount2 = _boundToRealisticStake(_amount2);
        _jump = _boundRealisticTimeAhead(_jump);

        vm.assume(_depositor1 != _depositor2);

        _mintGovToken(_depositor1, _amount1);
        _mintGovToken(_depositor2, _amount2);

        _setKeyper(_depositor1, true);
        _setKeyper(_depositor2, true);

        _stake(_depositor1, _amount1);

        _jumpAhead(_jump);

        _stake(_depositor2, _amount2);

        vm.prank(_depositor2);
        vm.expectRevert(BaseStaking.NoRewardsToClaim.selector);
        staking.claimRewards(0);
    }
}

contract Unstake is StakingTest {
    function testFuzz_UnstakeUpdateStakerGovTokenBalanceWhenUnstaking(
        address _depositor,
        uint256 _amount,
        uint256 _jump
    ) public {
        _amount = _boundToMoreThanMinStake(_amount);
        _jump = _boundUnlockedTime(_jump);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        uint256 stakeId = _stake(_depositor, _amount);

        assertEq(govToken.balanceOf(_depositor), 0, "Wrong balance");

        _jumpAhead(_jump);

        uint256 unstakeAmount = _amount - MIN_STAKE;
        vm.prank(_depositor);
        staking.unstake(_depositor, stakeId, unstakeAmount);

        assertEq(
            govToken.balanceOf(_depositor),
            unstakeAmount,
            "Wrong balance"
        );
    }

    function testFuzz_UnstakeShouldNotTransferRewards(
        address _depositor,
        uint256 _amount,
        uint256 _jump
    ) public {
        _amount = _boundToMoreThanMinStake(_amount);
        _jump = _boundUnlockedTime(_jump);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        uint256 stakeId = _stake(_depositor, _amount);

        uint256 timestampBefore = vm.getBlockTimestamp();

        _jumpAhead(_jump);

        uint256 expectedRewards = REWARD_RATE *
            (vm.getBlockTimestamp() - timestampBefore);

        uint256 unstakeAmount = _amount - MIN_STAKE;

        rewardsDistributor.collectRewardsTo(address(staking));

        vm.prank(_depositor);
        staking.unstake(_depositor, stakeId, unstakeAmount);

        assertEq(
            govToken.balanceOf(address(staking)),
            expectedRewards + MIN_STAKE + INITIAL_DEPOSIT,
            "Wrong balance"
        );
    }

    function testFuzz_EmitUnstakeEventWhenUnstaking(
        address _depositor,
        uint256 _amount,
        uint256 _jump
    ) public {
        _amount = _boundToMoreThanMinStake(_amount);
        _jump = _boundUnlockedTime(_jump);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        uint256 stakeId = _stake(_depositor, _amount);

        _jumpAhead(_jump);

        uint256 unstakeAmount = _amount - MIN_STAKE;
        uint256 shares = _previewWithdrawIncludeRewardsDistributed(
            unstakeAmount,
            REWARD_RATE * _jump
        );
        vm.expectEmit();
        emit Staking.Unstaked(_depositor, unstakeAmount, shares);

        vm.prank(_depositor);
        staking.unstake(_depositor, stakeId, unstakeAmount);
    }

    function testFuzz_UnstakeSpecifiedAmount(
        address _depositor,
        uint256 _amount,
        uint256 _jump
    ) public {
        _amount = _boundToMoreThanMinStake(_amount);
        _jump = _boundUnlockedTime(_jump);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        uint256 stakeId = _stake(_depositor, _amount);

        _jumpAhead(_jump);

        uint256 unstakeAmount = _amount - MIN_STAKE;

        vm.prank(_depositor);
        staking.unstake(_depositor, stakeId, unstakeAmount);

        assertEq(
            govToken.balanceOf(_depositor),
            unstakeAmount,
            "Wrong balance"
        );
    }

    function testFuzz_UpdateTotalSupplyWhenUnstaking(
        address _depositor,
        uint256 _amount,
        uint256 _jump
    ) public {
        _amount = bound(_amount, MIN_STAKE + 1, 5_000_000e18);
        _jump = _boundUnlockedTime(_jump);

        _mintGovToken(_depositor, _amount + MIN_STAKE);
        _setKeyper(_depositor, true);

        uint256 stakeId = _stake(_depositor, _amount);

        uint256 totalSupplyBefore = staking.totalSupply();

        _jumpAhead(_jump);

        uint256 sharesToBurn = _previewWithdrawIncludeRewardsDistributed(
            _amount - MIN_STAKE,
            REWARD_RATE * _jump
        );

        vm.prank(_depositor);
        staking.unstake(_depositor, stakeId, _amount - MIN_STAKE);

        assertEq(
            staking.totalSupply(),
            totalSupplyBefore - sharesToBurn,
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

        vm.assume(
            _anyone != address(0) &&
                _anyone != ProxyUtils.getAdminAddress(address(staking))
        );

        _mintGovToken(_depositor, _amount * 2);
        _setKeyper(_depositor, true);

        _stake(_depositor, _amount);
        _stake(_depositor, _amount);
        assertEq(govToken.balanceOf(_depositor), 0, "Wrong balance");

        _setKeyper(_depositor, false);

        vm.startPrank(_anyone);
        staking.unstake(_depositor, 1, 0);
        staking.unstake(_depositor, 2, 0);
        vm.stopPrank();

        assertEq(govToken.balanceOf(_depositor), _amount * 2, "Wrong balance");

        uint256[] memory stakeIds = staking.getUserStakeIds(_depositor);
        assertEq(stakeIds.length, 0, "Wrong stake ids");
    }

    function testFuzz_DepositorHasMultipleStakesUnstakeCorrectStake(
        address _depositor,
        uint256 _amount1,
        uint256 _amount2,
        uint256 _jump
    ) public {
        _amount1 = _boundToMoreThanMinStake(_amount1);
        _amount2 = _boundToRealisticStake(_amount2);
        _jump = _boundUnlockedTime(_jump);

        _mintGovToken(_depositor, _amount1 + _amount2);
        _setKeyper(_depositor, true);

        uint256 stakeId1 = _stake(_depositor, _amount1);
        uint256 stakeId2 = _stake(_depositor, _amount2);
        assertEq(govToken.balanceOf(_depositor), 0, "Wrong balance");

        _jumpAhead(_jump);

        vm.prank(_depositor);
        uint256 unstakeAmount = _amount1 - MIN_STAKE;
        staking.unstake(_depositor, stakeId1, unstakeAmount);

        assertEq(
            govToken.balanceOf(_depositor),
            unstakeAmount,
            "Wrong balance"
        );

        vm.prank(_depositor);
        staking.unstake(_depositor, stakeId2, 0);

        assertEq(
            govToken.balanceOf(_depositor),
            unstakeAmount + _amount2,
            "Wrong balance"
        );
    }

    function testFuzz_UnstakeOnlyAmountSpecified(
        address _depositor,
        uint256 _amount1,
        uint256 _amount2,
        uint256 _jump
    ) public {
        _amount1 = _boundToMoreThanMinStake(_amount1);
        _amount2 = _boundToRealisticStake(_amount2);
        _jump = _boundUnlockedTime(_jump);

        vm.assume(_amount1 > _amount2 && _amount1 - _amount2 > MIN_STAKE);
        _jump = _boundUnlockedTime(_jump);

        _mintGovToken(_depositor, _amount1);

        _setKeyper(_depositor, true);

        uint256 stakeId = _stake(_depositor, _amount1);
        assertEq(govToken.balanceOf(_depositor), 0, "Wrong balance");

        _jumpAhead(_jump);

        vm.prank(_depositor);
        staking.unstake(_depositor, stakeId, _amount2);

        assertEq(govToken.balanceOf(_depositor), _amount2, "Wrong balance");

        uint256[] memory stakeIds = staking.getUserStakeIds(_depositor);
        assertEq(stakeIds.length, 1, "Wrong stake ids");

        (uint256 amount, , ) = staking.stakes(stakeIds[0]);

        assertEq(amount, _amount1 - _amount2, "Wrong amount");
    }

    function testFuzz_RevertIf_StakeIsStillLocked(
        address _depositor,
        uint256 _amount,
        uint256 _jump
    ) public {
        _amount = _boundToRealisticStake(_amount);
        _jump = bound(_jump, vm.getBlockTimestamp(), LOCK_PERIOD);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        uint256 stakeId = _stake(_depositor, _amount);

        _jumpAhead(_jump);

        vm.prank(_depositor);
        vm.expectRevert(Staking.StakeIsStillLocked.selector);
        staking.unstake(_depositor, stakeId, 0);
    }

    function testFuzz_RevertIf_StakeIsStillLockedAfterLockPeriodChangedToLessThanCurrent(
        address _depositor,
        uint256 _amount,
        uint256 _jump
    ) public {
        _amount = _boundToRealisticStake(_amount);
        _jump = bound(_jump, vm.getBlockTimestamp(), LOCK_PERIOD - 1);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        uint256 stakeId = _stake(_depositor, _amount);

        staking.setLockPeriod(_jump);
        _jumpAhead(_jump);

        vm.prank(_depositor);
        vm.expectRevert(Staking.StakeIsStillLocked.selector);
        staking.unstake(_depositor, stakeId, 0);
    }

    function test_RevertIf_UnstakeResultsInBalanceLowerThanMinStaked() public {
        address depositor = address(uint160(123));

        // create multiple users staking to make the rewards amount accumulated
        // for _depositor not greater enough to withdraw the min stake
        for (uint256 i = 0; i < 50; i++) {
            address user = address(
                uint160(uint256(keccak256(abi.encodePacked(i))))
            );
            govToken.mint(user, MIN_STAKE);
            _setKeyper(user, true);
            vm.startPrank(user);
            govToken.approve(address(staking), MIN_STAKE);
            staking.stake(MIN_STAKE);
            vm.stopPrank();
        }

        _setKeyper(depositor, true);

        vm.startPrank(depositor);
        govToken.mint(depositor, MIN_STAKE);
        govToken.approve(address(staking), MIN_STAKE);
        uint256 stakeId = staking.stake(MIN_STAKE);
        vm.stopPrank();

        _jumpAhead(vm.getBlockTimestamp() + LOCK_PERIOD);

        vm.prank(depositor);
        vm.expectRevert(BaseStaking.WithdrawAmountTooHigh.selector);
        staking.unstake(depositor, stakeId, MIN_STAKE);
    }

    function testFuzz_RevertIf_StakeDoesNotBelongToUser(
        address _depositor1,
        address _depositor2,
        uint256 _amount1
    ) public {
        vm.assume(_depositor1 != _depositor2);
        vm.assume(
            _depositor1 != address(0) &&
                _depositor1 != ProxyUtils.getAdminAddress(address(staking))
        );
        vm.assume(
            _depositor2 != address(0) &&
                _depositor2 != ProxyUtils.getAdminAddress(address(staking))
        );
        _amount1 = _boundToRealisticStake(_amount1);

        _mintGovToken(_depositor1, _amount1);

        _setKeyper(_depositor1, true);

        uint256 stakeId = _stake(_depositor1, _amount1);

        vm.prank(_depositor2);
        vm.expectRevert(Staking.StakeDoesNotBelongToUser.selector);
        staking.unstake(_depositor2, stakeId, 0);
    }

    function testFuzz_RevertIf_AmountGreaterThanStakeAmount(
        address _depositor,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        uint256 stakeId = _stake(_depositor, _amount);

        vm.prank(_depositor);
        vm.expectRevert(BaseStaking.WithdrawAmountTooHigh.selector);
        staking.unstake(_depositor, stakeId, _amount + 1);
    }

    function testFuzz_RevertIf_NonKeyperTryToUnstake(
        address _depositor,
        address _anyone,
        uint256 _amount
    ) public {
        vm.assume(
            _depositor != address(0) &&
                _depositor != ProxyUtils.getAdminAddress(address(staking))
        );
        vm.assume(
            _anyone != address(0) &&
                _anyone != ProxyUtils.getAdminAddress(address(staking))
        );
        vm.assume(_depositor != _anyone);

        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor, _amount);

        _setKeyper(_depositor, true);

        uint256 stakeId = _stake(_depositor, _amount);

        vm.prank(_anyone);
        vm.expectRevert(Staking.OnlyKeyper.selector);
        staking.unstake(_depositor, stakeId, 0);
    }
}

contract OwnableFunctions is StakingTest {
    function testFuzz_setRewardsDistributor(
        address _newRewardsDistributor
    ) public {
        vm.assume(
            _newRewardsDistributor != address(0) &&
                _newRewardsDistributor != address(staking) &&
                _newRewardsDistributor != address(govToken)
        );

        staking.setRewardsDistributor(_newRewardsDistributor);

        assertEq(
            address(staking.rewardsDistributor()),
            _newRewardsDistributor,
            "Wrong rewards distributor"
        );
    }

    function testFuzz_setLockPeriod(uint256 _newLockPeriod) public {
        staking.setLockPeriod(_newLockPeriod);

        assertEq(staking.lockPeriod(), _newLockPeriod, "Wrong lock period");
    }

    function testFuzz_setMinStake(uint256 _newMinStake) public {
        staking.setMinStake(_newMinStake);

        assertEq(staking.minStake(), _newMinStake, "Wrong min stake");
    }

    function testFuzz_setKeyper(address keyper, bool isKeyper) public {
        vm.expectEmit();
        emit Staking.KeyperSet(keyper, isKeyper);
        staking.setKeyper(keyper, isKeyper);

        assertEq(staking.keypers(keyper), isKeyper, "Wrong keyper");
    }

    function testFuzz_RevertIf_NonOwnerSetRewardsDistributor(
        address _newRewardsDistributor,
        address _nonOwner
    ) public {
        vm.assume(
            _newRewardsDistributor != address(0) &&
                _newRewardsDistributor != address(staking) &&
                _newRewardsDistributor != address(govToken)
        );

        vm.assume(
            _nonOwner != address(0) &&
                _nonOwner != ProxyUtils.getAdminAddress(address(staking)) &&
                _nonOwner != address(this)
        );

        vm.prank(_nonOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                _nonOwner
            )
        );
        staking.setRewardsDistributor(_newRewardsDistributor);
    }

    function testFuzz_RevertIf_NonOwnerSetLockPeriod(
        uint256 _newLockPeriod,
        address _nonOwner
    ) public {
        vm.assume(
            _nonOwner != address(0) &&
                _nonOwner != ProxyUtils.getAdminAddress(address(staking)) &&
                _nonOwner != address(this)
        );

        vm.prank(_nonOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                _nonOwner
            )
        );
        staking.setLockPeriod(_newLockPeriod);
    }

    function testFuzz_RevertIf_NonOwnerSetMinStake(
        uint256 _newMinStake,
        address _nonOwner
    ) public {
        vm.assume(
            _nonOwner != address(0) &&
                _nonOwner != ProxyUtils.getAdminAddress(address(staking)) &&
                _nonOwner != address(this)
        );

        vm.prank(_nonOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                _nonOwner
            )
        );
        staking.setMinStake(_newMinStake);
    }

    function testFuzz_RevertIf_NonOwnerSetKeyper(
        address keyper,
        bool isKeyper,
        address _nonOwner
    ) public {
        vm.assume(
            _nonOwner != address(0) &&
                _nonOwner != ProxyUtils.getAdminAddress(address(staking)) &&
                _nonOwner != address(this)
        );

        vm.prank(_nonOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                _nonOwner
            )
        );
        staking.setKeyper(keyper, isKeyper);
    }
}

contract ViewFunctions is StakingTest {
    function testFuzz_MaxWithdrawDepositorHasLockedStakeNoRewards(
        address _depositor,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_depositor, true);

        _stake(_depositor, _amount);

        uint256 maxWithdraw = _maxWithdraw(_depositor);
        assertEq(maxWithdraw, 0, "Wrong max withdraw");
    }

    function testFuzz_MaxWithdrawDepositorHasLockedStakeAndReward(
        address _depositor1,
        address _depositor2,
        uint256 _amount1,
        uint256 _amount2,
        uint256 _jump
    ) public {
        vm.assume(_depositor1 != _depositor2);

        _amount1 = _boundToRealisticStake(_amount1);
        _amount2 = _boundToRealisticStake(_amount2);

        _jump = _boundUnlockedTime(_jump);

        _mintGovToken(_depositor1, _amount1);
        _setKeyper(_depositor1, true);

        _stake(_depositor1, _amount1);

        _jumpAhead(_jump);

        _mintGovToken(_depositor2, _amount2);
        _setKeyper(_depositor2, true);

        _stake(_depositor2, _amount2);

        uint256 assetsAmount = staking.convertToAssets(
            staking.balanceOf(_depositor1)
        );

        uint256 rewards = assetsAmount - _amount1;

        uint256 maxWithdraw = _maxWithdraw(_depositor1);
        assertApproxEqAbs(maxWithdraw, rewards, 0.1e18, "Wrong max withdraw");
    }

    function testFuzz_MaxWithdrawDepositorHasMultipleLockedStakes(
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

        _stake(_depositor, _amount1);
        _stake(_depositor, _amount2);

        uint256 maxWithdraw = _maxWithdraw(_depositor);
        assertEq(maxWithdraw, 0, "Wrong max withdraw");
    }

    function testFuzz_ConvertToSharesHasSupplySameBlock(
        address _depositor,
        uint256 _assets
    ) public {
        _assets = _boundToRealisticStake(_assets);

        _mintGovToken(_depositor, _assets);
        _setKeyper(_depositor, true);

        _stake(_depositor, _assets);

        uint256 shares = staking.convertToShares(_assets);

        assertEq(shares, _assets, "Wrong shares");
    }

    function testFuzz_ConvertToAssetsHasSupplySameBlock(
        address _depositor,
        uint256 _assets
    ) public {
        _assets = _boundToRealisticStake(_assets);

        _mintGovToken(_depositor, _assets);
        _setKeyper(_depositor, true);

        _stake(_depositor, _assets);

        uint256 shares = staking.convertToShares(_assets);
        uint256 assets = staking.convertToAssets(shares);

        assertEq(assets, _assets, "Wrong assets");
    }

    function testFuzz_GetUserStakeIds(
        address _depositor,
        uint256 _amount1,
        uint256 _amount2
    ) public {
        _amount1 = _boundToRealisticStake(_amount1);
        _amount2 = _boundToRealisticStake(_amount2);

        _mintGovToken(_depositor, _amount1 + _amount2);
        _setKeyper(_depositor, true);

        uint256 stakeId1 = _stake(_depositor, _amount1);
        uint256 stakeId2 = _stake(_depositor, _amount2);

        uint256[] memory stakeIds = staking.getUserStakeIds(_depositor);

        assertEq(stakeIds.length, 2, "Wrong stake ids");
        assertEq(stakeIds[0], stakeId1, "Wrong stake id");
        assertEq(stakeIds[1], stakeId2, "Wrong stake id");
    }
}

contract Transfer is StakingTest {
    function testFuzz_RevertWith_transferDisabled(
        address _from,
        address _to,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_from, _amount);
        _setKeyper(_from, true);

        _stake(_from, _amount);

        vm.expectRevert(BaseStaking.TransferDisabled.selector);
        staking.transfer(_to, _amount);
    }

    function testFuzz_RevertWith_transferFromDisabled(
        address _from,
        address _to,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_from, _amount);
        _setKeyper(_from, true);

        _stake(_from, _amount);

        vm.expectRevert(BaseStaking.TransferDisabled.selector);
        staking.transferFrom(_from, _to, _amount);
    }
}
