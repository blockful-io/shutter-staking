// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";
import {TransparentUpgradeableProxy, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {FixedPointMathLib} from "src/libraries/FixedPointMathLib.sol";

import {Staking} from "src/Staking.sol";
import {BaseStaking} from "src/BaseStaking.sol";
import {DelegateStaking} from "src/DelegateStaking.sol";
import {RewardsDistributor} from "src/RewardsDistributor.sol";
import {IRewardsDistributor} from "src/interfaces/IRewardsDistributor.sol";
import {MockGovToken} from "test/mocks/MockGovToken.sol";
import {ProxyUtils} from "test/helpers/ProxyUtils.sol";
import {DelegateStakingHarness} from "test/helpers/DelegateStakingHarness.sol";

contract DelegateStakingTest is Test {
    using FixedPointMathLib for uint256;

    DelegateStakingHarness public delegate;
    IRewardsDistributor public rewardsDistributor;
    Staking public staking;
    MockGovToken public govToken;

    uint256 constant LOCK_PERIOD = 182 days; // 6 months
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
        address stakingImpl = address(new Staking());
        vm.label(stakingImpl, "stakingImpl");

        staking = Staking(
            address(
                new TransparentUpgradeableProxy(stakingImpl, address(this), "")
            )
        );
        vm.label(address(staking), "staking");

        _mintGovToken(address(this), INITIAL_DEPOSIT * 2);
        govToken.approve(address(staking), INITIAL_DEPOSIT);
        staking.initialize(
            address(this), // owner
            address(govToken),
            address(rewardsDistributor),
            0,
            0
        );

        address delegateImpl = address(new DelegateStakingHarness());
        vm.label(delegateImpl, "delegateImpl");

        delegate = DelegateStakingHarness(
            address(
                new TransparentUpgradeableProxy(delegateImpl, address(this), "")
            )
        );
        vm.label(address(delegate), "delegate");

        govToken.approve(address(delegate), INITIAL_DEPOSIT);

        delegate.initialize(
            address(this), // owner
            address(govToken),
            address(rewardsDistributor),
            address(staking),
            LOCK_PERIOD
        );

        rewardsDistributor.setRewardConfiguration(
            address(delegate),
            REWARD_RATE
        );

        // fund reward distribution
        _mintGovToken(address(rewardsDistributor), 100_000_000e18);
    }

    function _setKeyper(address _keyper, bool _isKeyper) internal {
        staking.setKeyper(_keyper, _isKeyper);
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
                _to != address(delegate) &&
                _to != ProxyUtils.getAdminAddress(address(delegate))
        );

        govToken.mint(_to, _amount);
    }

    function _boundToRealisticStake(
        uint256 _stakeAmount
    ) public pure returns (uint256 _boundedStakeAmount) {
        _boundedStakeAmount = uint256(
            bound(_stakeAmount, 100e18, 5_000_000e18)
        );
    }

    function _stake(
        address _user,
        address _keyper,
        uint256 _amount
    ) internal returns (uint256 stakeId) {
        vm.assume(
            _keyper != address(0) &&
                _keyper != ProxyUtils.getAdminAddress(address(staking))
        );

        vm.assume(
            _user != address(0) &&
                _user != address(this) &&
                _user != address(delegate) &&
                _user != ProxyUtils.getAdminAddress(address(delegate)) &&
                _user != address(rewardsDistributor) &&
                _user != address(staking)
        );

        vm.startPrank(_user);
        govToken.approve(address(delegate), _amount);
        stakeId = delegate.stake(_keyper, _amount);
        vm.stopPrank();
    }

    function _previewWithdrawIncludeRewardsDistributed(
        uint256 _amount,
        uint256 _rewardsDistributed
    ) internal view returns (uint256) {
        uint256 supply = delegate.totalSupply();

        uint256 assets = govToken.balanceOf(address(delegate)) +
            _rewardsDistributed;
        return _amount.mulDivUp(supply, assets);
    }

    function _convertToSharesIncludeRewardsDistributed(
        uint256 _amount,
        uint256 _rewardsDistributed
    ) internal view returns (uint256) {
        uint256 supply = delegate.totalSupply();

        uint256 assets = govToken.balanceOf(address(delegate)) +
            _rewardsDistributed;

        return _amount.mulDivDown(supply, assets);
    }

    function _convertToAssetsIncludeRewardsDistributed(
        uint256 _shares,
        uint256 _rewardsDistributed
    ) internal view returns (uint256) {
        uint256 supply = delegate.totalSupply();

        uint256 assets = govToken.balanceOf(address(delegate)) +
            _rewardsDistributed;

        return _shares.mulDivDown(assets, supply);
    }

    function _maxWithdraw(address user) internal view returns (uint256) {
        uint256 assets = delegate.convertToAssets(delegate.balanceOf(user));
        uint256 locked = delegate.totalLocked(user);

        return locked >= assets ? 0 : assets - locked;
    }
}

contract Initializer is DelegateStakingTest {
    function test_Initialize() public view {
        assertEq(
            IERC20Metadata(address(delegate)).name(),
            "Delegated Staking SHU"
        );
        assertEq(IERC20Metadata(address(delegate)).symbol(), "dSHU");
        assertEq(delegate.owner(), address(this), "Wrong owner");
        assertEq(
            address(delegate.stakingToken()),
            address(govToken),
            "Wrong staking token"
        );
        assertEq(
            address(delegate.rewardsDistributor()),
            address(rewardsDistributor),
            "Wrong rewards distributor"
        );
        assertEq(delegate.lockPeriod(), LOCK_PERIOD, "Wrong lock period");
        assertEq(
            address(delegate.staking()),
            address(staking),
            "Wrong staking"
        );

        assertEq(delegate.exposed_nextStakeId(), 1);
    }

    function test_RevertIf_InitializeImplementation() public {
        DelegateStaking delegateImpl = new DelegateStaking();

        vm.expectRevert();
        delegateImpl.initialize(
            address(this),
            address(govToken),
            address(rewardsDistributor),
            address(staking),
            LOCK_PERIOD
        );
    }
}

contract Stake is DelegateStakingTest {
    function testFuzz_ReturnStakeIdWhenStaking(
        address _depositor,
        address _keyper,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_keyper, true);

        vm.assume(
            _depositor != address(0) &&
                _depositor != ProxyUtils.getAdminAddress(address(delegate))
        );

        vm.startPrank(_depositor);
        govToken.approve(address(delegate), _amount);

        uint256 expectedStakeId = delegate.exposed_nextStakeId();

        uint256 stakeId = delegate.stake(_keyper, _amount);

        assertEq(stakeId, expectedStakeId, "Wrong stake id");
        vm.stopPrank();
    }

    function testFuzz_IncreaseNextStakeId(
        address _keyper,
        address _depositor,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_keyper, true);

        vm.assume(
            _depositor != address(0) &&
                _depositor != ProxyUtils.getAdminAddress(address(delegate))
        );

        uint256 expectedStakeId = delegate.exposed_nextStakeId() + 1;

        _stake(_depositor, _keyper, _amount);

        assertEq(delegate.exposed_nextStakeId(), expectedStakeId);
    }

    function testFuzz_TransferTokensWhenStaking(
        address _keyper,
        address _depositor,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_keyper, true);

        vm.assume(
            _depositor != address(0) &&
                _depositor != ProxyUtils.getAdminAddress(address(delegate))
        );

        _stake(_depositor, _keyper, _amount);

        assertEq(
            govToken.balanceOf(_depositor),
            0,
            "Tokens were not transferred"
        );
        assertEq(
            govToken.balanceOf(address(delegate)),
            _amount + INITIAL_DEPOSIT,
            "Tokens were not transferred"
        );
        vm.stopPrank();
    }

    function testFuzz_EmitAStakeEventWhenStaking(
        address _keyper,
        address _depositor,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_keyper, true);

        vm.assume(
            _depositor != address(0) &&
                _depositor != ProxyUtils.getAdminAddress(address(delegate))
        );

        vm.startPrank(_depositor);
        govToken.approve(address(delegate), _amount);
        vm.expectEmit();
        emit DelegateStaking.Staked(_depositor, _keyper, _amount, LOCK_PERIOD);
        delegate.stake(_keyper, _amount);
        vm.stopPrank();
    }

    function testFuzz_UpdateTotalSupplyWhenStaking(
        address _keyper,
        address _depositor,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        uint256 supplyBefore = delegate.totalSupply();

        _mintGovToken(_depositor, _amount);
        _setKeyper(_keyper, true);

        vm.assume(
            _depositor != address(0) &&
                _depositor != ProxyUtils.getAdminAddress(address(delegate))
        );

        uint256 expectedShares = delegate.convertToShares(_amount);
        _stake(_depositor, _keyper, _amount);

        assertEq(delegate.totalSupply(), expectedShares + supplyBefore);
    }

    function testFuzz_UpdateTotalSupplyWhenTwoAccountsStakes(
        address _keyper,
        address _depositor1,
        address _depositor2,
        uint256 _amount1,
        uint256 _amount2
    ) public {
        _amount1 = _boundToRealisticStake(_amount1);
        _amount2 = _boundToRealisticStake(_amount2);

        uint256 supplyBefore = delegate.totalSupply();

        _mintGovToken(_depositor1, _amount1);
        _mintGovToken(_depositor2, _amount2);

        _setKeyper(_keyper, true);

        uint256 expectedSharesDepositor1 = staking.convertToShares(_amount1);
        _stake(_depositor1, _keyper, _amount1);

        uint256 expectedSharesDepositor2 = staking.convertToShares(_amount2);

        _stake(_depositor2, _keyper, _amount2);

        assertEq(
            delegate.totalSupply(),
            supplyBefore + expectedSharesDepositor1 + expectedSharesDepositor2,
            "Wrong total supply"
        );
    }

    function testFuzz_UpdateSharesWhenStaking(
        address _keyper,
        address _depositor,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_keyper, true);

        uint256 shares = delegate.convertToShares(_amount);

        _stake(_depositor, _keyper, _amount);

        assertEq(delegate.balanceOf(_depositor), shares);
    }

    function testFuzz_UpdateSharesWhenStakingTwice(
        address _keyper,
        address _depositor,
        uint256 _amount1,
        uint256 _amount2,
        uint256 _jump
    ) public {
        _amount1 = _boundToRealisticStake(_amount1);
        _amount2 = _boundToRealisticStake(_amount2);

        _jump = _boundRealisticTimeAhead(_jump);

        _mintGovToken(_depositor, _amount1 + _amount2);
        _setKeyper(_keyper, true);

        uint256 _shares1 = staking.convertToShares(_amount1);
        _stake(_depositor, _keyper, _amount1);
        uint256 timestampBefore = vm.getBlockTimestamp();

        _jumpAhead(_jump);
        uint256 _shares2 = _convertToSharesIncludeRewardsDistributed(
            _amount2,
            REWARD_RATE * (vm.getBlockTimestamp() - timestampBefore)
        );

        _stake(_depositor, _keyper, _amount2);

        // need to accept a small error due to the donation attack prevention
        assertApproxEqAbs(
            delegate.balanceOf(_depositor),
            _shares1 + _shares2,
            1e18,
            "Wrong balance"
        );
    }

    function testFuzz_Depositor1AndDepositor2ReceivesTheSameAmountOfSharesWhenStakingSameAmountInTheSameBlock(
        address _keyper1,
        address _keyper2,
        address _depositor1,
        address _depositor2,
        uint256 _amount
    ) public {
        vm.assume(_depositor1 != _depositor2);
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor1, _amount);
        _mintGovToken(_depositor2, _amount);

        _setKeyper(_keyper1, true);
        _setKeyper(_keyper2, true);

        uint256 shares = delegate.convertToShares(_amount);

        _stake(_depositor1, _keyper1, _amount);
        _stake(_depositor2, _keyper2, _amount);

        assertApproxEqAbs(
            delegate.balanceOf(_depositor1),
            delegate.balanceOf(_depositor2),
            1e5,
            "Wrong balance"
        );
        assertEq(delegate.balanceOf(_depositor1), shares);
        assertEq(delegate.balanceOf(_depositor2), shares);
        assertEq(delegate.totalSupply(), 2 * shares + INITIAL_DEPOSIT);
    }

    function testFuzz_Depositor1ReceivesMoreShareWhenStakingBeforeDepositor2(
        address _keyper1,
        address _keyper2,
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

        _setKeyper(_keyper1, true);
        _setKeyper(_keyper2, true);

        _stake(_depositor1, _keyper1, _amount);
        _jumpAhead(_jump);
        _stake(_depositor2, _keyper2, _amount);

        assertGt(
            delegate.balanceOf(_depositor1),
            delegate.balanceOf(_depositor2),
            "Wrong balance"
        );
    }

    function testFuzz_UpdateContractGovTokenBalanceWhenStaking(
        address _keyper,
        address _depositor,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_keyper, true);

        uint256 govTokenBalance = govToken.balanceOf(address(delegate));

        _stake(_depositor, _keyper, _amount);

        assertEq(
            govToken.balanceOf(address(delegate)),
            govTokenBalance + _amount,
            "Wrong balance"
        );
    }

    function testFuzz_TrackAmountStakedWhenStaking(
        address _keyper,
        address _depositor,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_keyper, true);

        uint256 stakeId = _stake(_depositor, _keyper, _amount);

        (, uint256 amount, , ) = delegate.stakes(stakeId);

        assertEq(amount, _amount, "Wrong amount");
    }

    function testFuzz_TrackKeyperWhenStaking(
        address _keyper,
        address _depositor,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_keyper, true);

        uint256 stakeId = _stake(_depositor, _keyper, _amount);

        (address keyper, , , ) = delegate.stakes(stakeId);

        assertEq(keyper, _keyper, "Wrong keyper");
    }

    function testFuzz_TrackTimestampWhenStaking(
        address _keyper,
        address _depositor,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_keyper, true);

        uint256 stakeId = _stake(_depositor, _keyper, _amount);

        (, , uint256 timestamp, ) = delegate.stakes(stakeId);

        assertEq(timestamp, vm.getBlockTimestamp(), "Wrong timestamp");
    }

    function testFuzz_TrackLockPeriodWhenStaking(
        address _keyper,
        address _depositor,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_keyper, true);

        uint256 stakeId = _stake(_depositor, _keyper, _amount);

        (, , , uint256 lockPeriod) = delegate.stakes(stakeId);

        assertEq(lockPeriod, LOCK_PERIOD, "Wrong lock period");
    }

    function testFuzz_TrackStakeIndividuallyPerStake(
        address _keyper,
        address _depositor,
        uint256 _amount1,
        uint256 _amount2
    ) public {
        _amount1 = _boundToRealisticStake(_amount1);
        _amount2 = _boundToRealisticStake(_amount2);

        _mintGovToken(_depositor, _amount1 + _amount2);
        _setKeyper(_keyper, true);

        uint256 stakeId1 = _stake(_depositor, _keyper, _amount1);

        (, uint256 amount1, uint256 timestamp1, ) = delegate.stakes(stakeId1);

        _jumpAhead(1);

        uint256 stakeId2 = _stake(_depositor, _keyper, _amount2);

        (, uint256 amount2, uint256 timestamp2, ) = delegate.stakes(stakeId2);

        assertEq(amount1, _amount1, "Wrong amount");
        assertEq(amount2, _amount2, "Wrong amount");

        assertEq(timestamp1, vm.getBlockTimestamp() - 1, "Wrong timestamp");
        assertEq(timestamp2, vm.getBlockTimestamp(), "Wrong timestamp");
    }

    function testFuzz_StakeReturnsStakeId(
        address _keyper,
        address _depositor,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_keyper, true);

        uint256 stakeId = _stake(_depositor, _keyper, _amount);

        assertGt(stakeId, 0, "Wrong stake id");
    }

    function testFuzz_IncreaseTotalLockedWhenStaking(
        address _keyper,
        address _depositor,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_keyper, true);

        uint256 totalLocked = delegate.totalLocked(_depositor);

        _stake(_depositor, _keyper, _amount);

        assertEq(
            delegate.totalLocked(_depositor),
            totalLocked + _amount,
            "Wrong total locked"
        );
    }

    function testFuzz_RevertIf_KeyperIsNotAKeyper(
        address _keyper,
        address _depositor,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor, _amount);

        vm.expectRevert(DelegateStaking.AddressIsNotAKeyper.selector);
        delegate.stake(_keyper, _amount);
    }

    function testFuzz_RevertIf_ZeroAmount(
        address _keyper,
        address _depositor
    ) public {
        _mintGovToken(_depositor, 0);

        vm.expectRevert(DelegateStaking.ZeroAmount.selector);
        delegate.stake(_keyper, 0);
    }

    function test_DonationAttackNoRewards(
        address keyper,
        address bob,
        address alice,
        uint256 bobAmount
    ) public {
        vm.assume(bob != alice);
        rewardsDistributor.removeRewardConfiguration(address(delegate));

        _setKeyper(keyper, true);

        bobAmount = _boundToRealisticStake(bobAmount);

        uint256 aliceDeposit = 1000e18;
        _mintGovToken(alice, aliceDeposit);
        uint256 aliceStakeId = _stake(alice, keyper, aliceDeposit);

        // simulate donation
        govToken.mint(address(delegate), bobAmount);

        // bob stake
        _mintGovToken(bob, bobAmount);
        uint256 bobStakeId = _stake(bob, keyper, bobAmount);

        _jumpAhead(vm.getBlockTimestamp() + LOCK_PERIOD);

        // alice withdraw rewards (bob stake) even when there is no rewards distributed
        vm.startPrank(alice);
        delegate.unstake(aliceStakeId, 0);
        delegate.claimRewards(0);
        vm.stopPrank();

        uint256 aliceBalanceAfterAttack = govToken.balanceOf(alice);

        // attack should not be profitable for alice
        assertGtDecimal(
            bobAmount + aliceDeposit, // amount alice has spend in total
            aliceBalanceAfterAttack,
            18,
            "Alice receive more than expend for the attack"
        );

        vm.startPrank(bob);
        delegate.unstake(bobStakeId, bobAmount - 1e5);

        assertApproxEqRel(
            govToken.balanceOf(bob),
            bobAmount,
            0.01e18,
            "Bob must receive the money back"
        );
    }

    function testFuzz_KeyperCanDelegateToHimself(
        address _keyper,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_keyper, _amount);
        _setKeyper(_keyper, true);

        uint256 stakeId = _stake(_keyper, _keyper, _amount);

        (address keyper, , , ) = delegate.stakes(stakeId);

        assertEq(keyper, _keyper, "Wrong keyper");
    }
}

contract ClaimRewards is DelegateStakingTest {
    function testFuzz_UpdateStakerGovTokenBalanceWhenClaimingRewards(
        address _keyper,
        address _depositor,
        uint256 _amount,
        uint256 _jump
    ) public {
        _amount = _boundToRealisticStake(_amount);
        _jump = _boundRealisticTimeAhead(_jump);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_keyper, true);

        _stake(_depositor, _keyper, _amount);

        _jumpAhead(_jump);

        // first 1000 shares was the dead shares so must decrease from the expected rewards
        uint256 assetsAmount = _convertToAssetsIncludeRewardsDistributed(
            delegate.balanceOf(_depositor),
            REWARD_RATE * _jump
        );

        uint256 expectedRewards = assetsAmount - _amount;

        vm.startPrank(_depositor);
        delegate.claimRewards(0);

        // need to accept a small error due to the donation attack prevention
        assertEq(
            govToken.balanceOf(_depositor),
            expectedRewards,
            "Wrong balance"
        );
    }

    function testFuzz_EmitRewardsClaimedEventWhenClaimingRewards(
        address _keyper,
        address _depositor,
        uint256 _amount,
        uint256 _jump
    ) public {
        _amount = _boundToRealisticStake(_amount);
        _jump = _boundRealisticTimeAhead(_jump);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_keyper, true);

        _stake(_depositor, _keyper, _amount);

        _jumpAhead(_jump);

        vm.expectEmit(true, true, false, false);
        emit BaseStaking.RewardsClaimed(_depositor, REWARD_RATE * _jump);

        vm.prank(_depositor);
        delegate.claimRewards(0);
    }

    function testFuzz_ClaimRewardBurnShares(
        address _keyper,
        address _depositor,
        uint256 _amount,
        uint256 _jump
    ) public {
        _amount = _boundToRealisticStake(_amount);
        _jump = _boundRealisticTimeAhead(_jump);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_keyper, true);

        _stake(_depositor, _keyper, _amount);

        uint256 sharesBefore = delegate.balanceOf(_depositor);

        _jumpAhead(_jump);

        // first 1000 shares was the dead shares so must decrease from the expected rewards
        uint256 assetsAmount = _convertToAssetsIncludeRewardsDistributed(
            delegate.balanceOf(_depositor),
            REWARD_RATE * _jump
        );

        uint256 expectedRewards = assetsAmount - _amount;

        uint256 burnShares = _previewWithdrawIncludeRewardsDistributed(
            expectedRewards,
            REWARD_RATE * _jump
        );

        vm.prank(_depositor);
        delegate.claimRewards(0);

        uint256 sharesAfter = delegate.balanceOf(_depositor);

        // need to accept a small error due to the donation attack prevention
        assertApproxEqAbs(
            sharesBefore - sharesAfter,
            burnShares,
            1,
            "Wrong shares burned"
        );
    }

    function testFuzz_UpdateTotalSupplyWhenClaimingRewards(
        address _keyper,
        address _depositor,
        uint256 _amount,
        uint256 _jump
    ) public {
        _amount = _boundToRealisticStake(_amount);
        _jump = _boundRealisticTimeAhead(_jump);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_keyper, true);

        _stake(_depositor, _keyper, _amount);

        uint256 totalSupplyBefore = delegate.totalSupply();

        _jumpAhead(_jump);

        // first 1000 shares was the dead shares so must decrease from the expected rewards
        uint256 assetsAmount = _convertToAssetsIncludeRewardsDistributed(
            delegate.balanceOf(_depositor),
            REWARD_RATE * _jump
        );

        uint256 expectedRewards = assetsAmount - _amount;

        uint256 burnShares = _previewWithdrawIncludeRewardsDistributed(
            expectedRewards,
            REWARD_RATE * _jump
        );

        vm.prank(_depositor);
        delegate.claimRewards(0);

        uint256 totalSupplyAfter = delegate.totalSupply();

        assertApproxEqAbs(
            totalSupplyAfter,
            totalSupplyBefore - burnShares,
            1,
            "Wrong total supply"
        );
    }

    function testFuzz_Depositor1GetsMoreRewardsThanDepositor2WhenStakingFirst(
        address _keyper,
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

        _setKeyper(_keyper, true);

        _stake(_depositor1, _keyper, _amount);

        _jumpAhead(_jump1);

        _stake(_depositor2, _keyper, _amount);

        _jumpAhead(_jump2);

        vm.prank(_depositor1);
        uint256 rewards1 = delegate.claimRewards(0);

        vm.prank(_depositor2);
        uint256 rewards2 = delegate.claimRewards(0);

        assertGt(rewards1, rewards2, "Wrong rewards");
    }

    function testFuzz_DepositorsGetApproxSameRewardAmountWhenStakingSameAmountInSameBlock(
        address _keyper,
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

        _setKeyper(_keyper, true);

        _stake(_depositor1, _keyper, _amount);

        _stake(_depositor2, _keyper, _amount);

        _jumpAhead(_jump);

        vm.prank(_depositor1);
        uint256 rewards1 = delegate.claimRewards(0);

        vm.prank(_depositor2);
        uint256 rewards2 = delegate.claimRewards(0);

        assertApproxEqAbs(rewards1, rewards2, 1e18, "Wrong rewards");
    }

    function testFuzz_DepositorGetExactSpecifiedAmountWhenClaimingRewards(
        address _keyper,
        address _depositor,
        uint256 _amount,
        uint256 _jump
    ) public {
        _amount = _boundToRealisticStake(_amount);
        _jump = _boundRealisticTimeAhead(_jump);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_keyper, true);

        _stake(_depositor, _keyper, _amount);

        _jumpAhead(_jump);

        // first 1000 shares was the dead shares so must decrease from the expected rewards
        uint256 assetsAmount = _convertToAssetsIncludeRewardsDistributed(
            delegate.balanceOf(_depositor),
            REWARD_RATE * _jump
        );

        uint256 expectedRewards = assetsAmount - _amount;

        vm.prank(_depositor);
        uint256 rewards = delegate.claimRewards(expectedRewards / 2);

        assertEq(rewards, expectedRewards / 2, "Wrong rewards");
    }

    function testFuzz_OnlyBurnTheCorrespondedAmountOfSharesSpecifiedWhenClaimingRewards(
        address _keyper,
        address _depositor,
        uint256 _amount,
        uint256 _jump
    ) public {
        _amount = _boundToRealisticStake(_amount);
        _jump = _boundRealisticTimeAhead(_jump);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_keyper, true);

        _stake(_depositor, _keyper, _amount);

        uint256 sharesBefore = delegate.balanceOf(_depositor);

        _jumpAhead(_jump);

        // first 1000 shares was the dead shares so must decrease from the expected rewards
        uint256 assetsAmount = _convertToAssetsIncludeRewardsDistributed(
            delegate.balanceOf(_depositor),
            REWARD_RATE * _jump
        );

        uint256 expectedRewards = assetsAmount - _amount;

        uint256 burnShares = _previewWithdrawIncludeRewardsDistributed(
            expectedRewards / 2,
            REWARD_RATE * _jump
        );

        vm.prank(_depositor);
        delegate.claimRewards(expectedRewards / 2);

        uint256 sharesAfter = delegate.balanceOf(_depositor);

        assertEq(sharesBefore - sharesAfter, burnShares, "Wrong shares burned");
    }

    function testFuzz_RevertIf_NoRewardsToClaim(
        address _keyper,
        address _depositor,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_keyper, true);

        _stake(_depositor, _keyper, _amount);

        vm.prank(_depositor);
        vm.expectRevert(BaseStaking.NoRewardsToClaim.selector);
        delegate.claimRewards(0);
    }

    function testFuzz_RevertIf_UserHasNoShares(address _depositor) public {
        vm.assume(
            _depositor != address(0) &&
                _depositor != address(delegate) &&
                _depositor != ProxyUtils.getAdminAddress(address(delegate))
        );

        vm.prank(_depositor);
        vm.expectRevert(BaseStaking.NoRewardsToClaim.selector);
        delegate.claimRewards(0);
    }

    function testFuzz_RevertIf_NoRewardsToClaimForThatUser(
        address _keyper,
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

        _setKeyper(_keyper, true);

        _stake(_depositor1, _keyper, _amount1);

        _jumpAhead(_jump);

        _stake(_depositor2, _keyper, _amount2);

        vm.prank(_depositor2);
        vm.expectRevert(BaseStaking.NoRewardsToClaim.selector);
        delegate.claimRewards(0);
    }
}

contract Unstake is DelegateStakingTest {
    function testFuzz_UnstakeUpdateStakerGovTokenBalanceWhenUnstaking(
        address _keyper,
        address _depositor,
        uint256 _amount,
        uint256 _jump
    ) public {
        _amount = _boundToRealisticStake(_amount);
        _jump = _boundUnlockedTime(_jump);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_keyper, true);

        uint256 stakeId = _stake(_depositor, _keyper, _amount);

        _jumpAhead(_jump);

        vm.prank(_depositor);
        delegate.unstake(stakeId, 0);

        assertEq(govToken.balanceOf(_depositor), _amount, "Wrong balance");
    }

    function testFuzz_UpdateTotalSupplyWhenUnstaking(
        address _keyper,
        address _depositor,
        uint256 _amount,
        uint256 _jump
    ) public {
        _amount = _boundToRealisticStake(_amount);
        _jump = _boundUnlockedTime(_jump);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_keyper, true);

        uint256 stakeId = _stake(_depositor, _keyper, _amount);

        uint256 totalSupplyBefore = delegate.totalSupply();

        _jumpAhead(_jump);

        uint256 burnShares = _previewWithdrawIncludeRewardsDistributed(
            _amount,
            REWARD_RATE * _jump
        );

        vm.prank(_depositor);
        delegate.unstake(stakeId, 0);

        assertEq(
            delegate.totalSupply(),
            totalSupplyBefore - burnShares,
            "Wrong total supply"
        );
    }

    function testFuzz_UnstakeShouldNotTransferRewards(
        address _keyper,
        address _depositor,
        uint256 _amount,
        uint256 _jump
    ) public {
        _amount = _boundToRealisticStake(_amount);
        _jump = _boundUnlockedTime(_jump);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_keyper, true);

        uint256 stakeId = _stake(_depositor, _keyper, _amount);

        _jumpAhead(_jump);

        uint256 expectedRewards = REWARD_RATE * _jump;

        vm.prank(_depositor);
        uint256 unstakeAmount = delegate.unstake(stakeId, 0);

        assertEq(
            govToken.balanceOf(address(delegate)),
            expectedRewards + INITIAL_DEPOSIT,
            "Wrong balance"
        );
        assertEq(
            govToken.balanceOf(_depositor),
            unstakeAmount,
            "Wrong balance"
        );
    }

    function testFuzz_EmitUnstakeEventWhenUnstaking(
        address _keyper,
        address _depositor,
        uint256 _amount,
        uint256 _jump
    ) public {
        _amount = _boundToRealisticStake(_amount);
        _jump = _boundUnlockedTime(_jump);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_keyper, true);

        uint256 stakeId = _stake(_depositor, _keyper, _amount);

        _jumpAhead(_jump);

        uint256 shares = _previewWithdrawIncludeRewardsDistributed(
            _amount,
            REWARD_RATE * _jump
        );
        vm.expectEmit();
        emit Staking.Unstaked(_depositor, _amount, shares);

        vm.prank(_depositor);
        delegate.unstake(stakeId, 0);
    }

    function testFuzz_DepositorHasMultipleStakesUnstakeCorrectStake(
        address _keyper,
        address _depositor,
        uint256 _amount1,
        uint256 _amount2,
        uint256 _jump
    ) public {
        _amount1 = _boundToRealisticStake(_amount1);
        _amount2 = _boundToRealisticStake(_amount2);
        _jump = _boundUnlockedTime(_jump);

        _mintGovToken(_depositor, _amount1 + _amount2);
        _setKeyper(_keyper, true);

        uint256 stakeId1 = _stake(_depositor, _keyper, _amount1);
        uint256 stakeId2 = _stake(_depositor, _keyper, _amount2);
        assertEq(govToken.balanceOf(_depositor), 0, "Wrong balance");

        _jumpAhead(_jump);

        vm.prank(_depositor);
        delegate.unstake(stakeId1, 0);

        assertEq(govToken.balanceOf(_depositor), _amount1, "Wrong balance");

        vm.prank(_depositor);
        delegate.unstake(stakeId2, 0);

        assertEq(
            govToken.balanceOf(_depositor),
            _amount1 + _amount2,
            "Wrong balance"
        );
    }

    function testFuzz_UnstakeOnlyAmountSpecified(
        address _keyper,
        address _depositor,
        uint256 _amount1,
        uint256 _amount2,
        uint256 _jump
    ) public {
        _amount1 = _boundToRealisticStake(_amount1);
        _amount2 = _boundToRealisticStake(_amount2);
        _jump = _boundUnlockedTime(_jump);

        vm.assume(_amount1 > _amount2);
        _jump = _boundUnlockedTime(_jump);

        _mintGovToken(_depositor, _amount1);

        _setKeyper(_keyper, true);

        uint256 stakeId = _stake(_depositor, _keyper, _amount1);
        assertEq(govToken.balanceOf(_depositor), 0, "Wrong balance");

        _jumpAhead(_jump);

        vm.prank(_depositor);
        delegate.unstake(stakeId, _amount2);

        assertEq(govToken.balanceOf(_depositor), _amount2, "Wrong balance");

        uint256[] memory stakeIds = delegate.getUserStakeIds(_depositor);
        assertEq(stakeIds.length, 1, "Wrong stake ids");

        (, uint256 amount, , ) = delegate.stakes(stakeIds[0]);

        assertEq(amount, _amount1 - _amount2, "Wrong amount");
    }

    function testFuzz_RevertIf_StakeIsStillLocked(
        address _keyper,
        address _depositor,
        uint256 _amount,
        uint256 _jump
    ) public {
        _amount = _boundToRealisticStake(_amount);
        _jump = bound(_jump, vm.getBlockTimestamp(), LOCK_PERIOD);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_keyper, true);

        uint256 stakeId = _stake(_depositor, _keyper, _amount);

        _jumpAhead(_jump);

        vm.prank(_depositor);
        vm.expectRevert(DelegateStaking.StakeIsStillLocked.selector);
        delegate.unstake(stakeId, 0);
    }

    function testFuzz_RevertIf_StakeIsStillLockedAfterLockPeriodChangedToLessThanCurrent(
        address _keyper,
        address _depositor,
        uint256 _amount,
        uint256 _jump
    ) public {
        _amount = _boundToRealisticStake(_amount);
        _jump = bound(_jump, vm.getBlockTimestamp(), LOCK_PERIOD - 1);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_keyper, true);

        uint256 stakeId = _stake(_depositor, _keyper, _amount);

        delegate.setLockPeriod(_jump);

        _jumpAhead(_jump);

        vm.prank(_depositor);
        vm.expectRevert(DelegateStaking.StakeIsStillLocked.selector);
        delegate.unstake(stakeId, 0);
    }

    function testFuzz_RevertIf_StakeDoesNotBelongToUser(
        address _keyper,
        address _depositor1,
        address _depositor2,
        uint256 _amount1
    ) public {
        vm.assume(_depositor1 != _depositor2);
        vm.assume(
            _depositor1 != address(0) &&
                _depositor1 != ProxyUtils.getAdminAddress(address(delegate))
        );
        vm.assume(
            _depositor2 != address(0) &&
                _depositor2 != ProxyUtils.getAdminAddress(address(delegate))
        );
        _amount1 = _boundToRealisticStake(_amount1);

        _mintGovToken(_depositor1, _amount1);

        _setKeyper(_keyper, true);

        uint256 stakeId = _stake(_depositor1, _keyper, _amount1);

        vm.prank(_depositor2);
        vm.expectRevert(DelegateStaking.StakeDoesNotBelongToUser.selector);
        delegate.unstake(stakeId, 0);
    }

    function testFuzz_RevertIf_AmountGreaterThanStakeAmount(
        address _keyper,
        address _depositor,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_keyper, true);

        uint256 stakeId = _stake(_depositor, _keyper, _amount);

        vm.prank(_depositor);
        vm.expectRevert(BaseStaking.WithdrawAmountTooHigh.selector);
        delegate.unstake(stakeId, _amount + 1);
    }
}

contract OwnableFunctions is DelegateStakingTest {
    function testFuzz_setRewardsDistributor(
        address _newRewardsDistributor
    ) public {
        vm.assume(
            _newRewardsDistributor != address(0) &&
                _newRewardsDistributor != address(delegate) &&
                _newRewardsDistributor != address(govToken)
        );

        delegate.setRewardsDistributor(_newRewardsDistributor);

        assertEq(
            address(delegate.rewardsDistributor()),
            _newRewardsDistributor,
            "Wrong rewards distributor"
        );
    }

    function testFuzz_setLockPeriod(uint256 _newLockPeriod) public {
        delegate.setLockPeriod(_newLockPeriod);

        assertEq(delegate.lockPeriod(), _newLockPeriod, "Wrong lock period");
    }

    function testFuzz_setStakingContract(address _newStaking) public {
        vm.assume(
            _newStaking != address(0) &&
                _newStaking != address(delegate) &&
                _newStaking != address(govToken)
        );

        vm.expectEmit();
        emit DelegateStaking.NewStakingContract(_newStaking);
        delegate.setStakingContract(_newStaking);

        assertEq(
            address(delegate.staking()),
            _newStaking,
            "Wrong staking contract"
        );
    }

    function testFuzz_RevertIf_NonOwnerSetRewardsDistributor(
        address _newRewardsDistributor,
        address _nonOwner
    ) public {
        vm.assume(
            _newRewardsDistributor != address(0) &&
                _newRewardsDistributor != address(delegate) &&
                _newRewardsDistributor != address(govToken)
        );

        vm.assume(
            _nonOwner != address(0) &&
                _nonOwner != ProxyUtils.getAdminAddress(address(delegate)) &&
                _nonOwner != address(this)
        );

        vm.prank(_nonOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                _nonOwner
            )
        );
        delegate.setRewardsDistributor(_newRewardsDistributor);
    }

    function testFuzz_RevertIf_NonOwnerSetLockPeriod(
        uint256 _newLockPeriod,
        address _nonOwner
    ) public {
        vm.assume(
            _nonOwner != address(0) &&
                _nonOwner != ProxyUtils.getAdminAddress(address(delegate)) &&
                _nonOwner != address(this)
        );

        vm.prank(_nonOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                _nonOwner
            )
        );
        delegate.setLockPeriod(_newLockPeriod);
    }

    function testFuzz_RevertIf_NonOwnerSetStakingContract(
        address _newStaking,
        address _nonOwner
    ) public {
        vm.assume(
            _newStaking != address(0) &&
                _newStaking != address(delegate) &&
                _newStaking != address(govToken)
        );

        vm.assume(
            _nonOwner != address(0) &&
                _nonOwner != ProxyUtils.getAdminAddress(address(delegate)) &&
                _nonOwner != address(this)
        );

        vm.prank(_nonOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                _nonOwner
            )
        );
        delegate.setStakingContract(_newStaking);
    }
}

contract ViewFunctions is DelegateStakingTest {
    function testFuzz_MaxWithdrawDepositorHasLockedStakeNoRewards(
        address _keyper,
        address _depositor,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_keyper, true);

        _stake(_depositor, _keyper, _amount);

        uint256 maxWithdraw = _maxWithdraw(_depositor);
        assertEq(maxWithdraw, 0, "Wrong max withdraw");
    }

    function testFuzz_MaxWithdrawDepositorHasLockedStakeAndReward(
        address _keyper,
        address _depositor1,
        uint256 _amount1,
        uint256 _jump
    ) public {
        _amount1 = _boundToRealisticStake(_amount1);

        _jump = _boundUnlockedTime(_jump);

        _mintGovToken(_depositor1, _amount1);
        _setKeyper(_keyper, true);

        _stake(_depositor1, _keyper, _amount1);

        _jumpAhead(_jump);

        // first 1000 shares was the dead shares so must decrease from the expected rewards
        uint256 assetsAmount = _convertToAssetsIncludeRewardsDistributed(
            delegate.balanceOf(_depositor1),
            REWARD_RATE * _jump
        );

        uint256 rewards = assetsAmount - _amount1;

        rewardsDistributor.collectRewardsTo(address(delegate));

        uint256 maxWithdraw = _maxWithdraw(_depositor1);

        assertApproxEqAbs(maxWithdraw, rewards, 0.1e18, "Wrong max withdraw");
    }

    function testFuzz_MaxWithdrawDepositorHasMultipleLockedStakes(
        address _keyper,
        address _depositor,
        uint256 _amount1,
        uint256 _amount2,
        uint256 _jump
    ) public {
        _amount1 = _boundToRealisticStake(_amount1);
        _amount2 = _boundToRealisticStake(_amount2);
        _jump = _boundUnlockedTime(_jump);

        _mintGovToken(_depositor, _amount1 + _amount2);
        _setKeyper(_keyper, true);

        _stake(_depositor, _keyper, _amount1);
        _stake(_depositor, _keyper, _amount2);

        uint256 maxWithdraw = _maxWithdraw(_depositor);
        assertEq(maxWithdraw, 0, "Wrong max withdraw");
    }

    function testFuzz_ConvertToSharesHasSupplySameBlock(
        address _keyper,
        address _depositor,
        uint256 _assets
    ) public {
        _assets = _boundToRealisticStake(_assets);

        _mintGovToken(_depositor, _assets);
        _setKeyper(_keyper, true);

        _stake(_depositor, _keyper, _assets);

        uint256 shares = delegate.convertToShares(_assets);

        assertEq(shares, _assets, "Wrong shares");
    }

    function testFuzz_ConvertToAssetsHasSupplySameBlock(
        address _keyper,
        address _depositor,
        uint256 _assets
    ) public {
        _assets = _boundToRealisticStake(_assets);

        _mintGovToken(_depositor, _assets);
        _setKeyper(_keyper, true);

        _stake(_depositor, _keyper, _assets);

        uint256 shares = delegate.convertToShares(_assets);
        uint256 assets = delegate.convertToAssets(shares);

        assertEq(assets, _assets, "Wrong assets");
    }

    function testFuzz_GetUserStakeIds(
        address _keyper,
        address _depositor,
        uint256 _amount1,
        uint256 _amount2
    ) public {
        _amount1 = _boundToRealisticStake(_amount1);
        _amount2 = _boundToRealisticStake(_amount2);

        _mintGovToken(_depositor, _amount1 + _amount2);
        _setKeyper(_keyper, true);

        uint256 stakeId1 = _stake(_depositor, _keyper, _amount1);
        uint256 stakeId2 = _stake(_depositor, _keyper, _amount2);

        uint256[] memory stakeIds = delegate.getUserStakeIds(_depositor);

        assertEq(stakeIds.length, 2, "Wrong stake ids");
        assertEq(stakeIds[0], stakeId1, "Wrong stake id");
        assertEq(stakeIds[1], stakeId2, "Wrong stake id");
    }

    function testFuzz_CalculateWithdrawAmountReturnsAmount(
        address _keyper,
        address _depositor,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor, _amount);
        _setKeyper(_keyper, true);

        uint256 stakeId = _stake(_depositor, _keyper, _amount);

        uint256 withdrawAmount = delegate.exposed_calculateWithdrawAmount(
            _amount / 2,
            _amount
        );

        assertEq(withdrawAmount, _amount / 2, "Wrong withdraw amount");
    }
}

contract Transfer is DelegateStakingTest {
    function testFuzz_RevertWith_transferDisabled(
        address _from,
        address _to,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_from, _amount);
        _setKeyper(_from, true);

        _stake(_from, _from, _amount);

        vm.expectRevert(BaseStaking.TransferDisabled.selector);
        delegate.transfer(_to, _amount);
    }

    function testFuzz_RevertWith_transferFromDisabled(
        address _from,
        address _to,
        uint256 _amount
    ) public {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_from, _amount);
        _setKeyper(_from, true);

        _stake(_from, _from, _amount);

        vm.expectRevert(BaseStaking.TransferDisabled.selector);
        delegate.transferFrom(_from, _to, _amount);
    }
}
