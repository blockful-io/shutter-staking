// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@forge-std/Test.sol";
import {TransparentUpgradeableProxy, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {FixedPointMathLib} from "src/libraries/FixedPointMathLib.sol";

import {Staking} from "src/Staking.sol";
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

    function setUp() public {
        // Set the block timestamp to an arbitrary value to avoid introducing assumptions into tests
        // based on a starting timestamp of 0, which is the default.
        _jumpAhead(1234);

        govToken = new MockGovToken();
        _mintGovToken(address(this), 100_000_000e18);
        vm.label(address(govToken), "govToken");

        // deploy rewards distributor
        rewardsDistributor = IRewardsDistributor(
            new RewardsDistributor(address(this), address(govToken))
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
            0,
            0
        );

        address delegateImpl = address(new DelegateStakingHarness());

        delegate = DelegateStakingHarness(
            address(
                new TransparentUpgradeableProxy(delegateImpl, address(this), "")
            )
        );
        vm.label(address(delegate), "staking");

        delegate.initialize(
            address(this), // owner
            address(govToken),
            address(rewardsDistributor),
            address(staking),
            LOCK_PERIOD
        );

        rewardsDistributor.setRewardConfiguration(
            address(staking),
            REWARD_RATE
        );

        // fund reward distribution
        govToken.transfer(address(rewardsDistributor), 100_000_000e18);
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
                _user != address(rewardsDistributor)
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
        return _amount.mulDivUp(supply + 1, assets + 1);
    }

    function _convertToSharesIncludeRewardsDistributed(
        uint256 _amount,
        uint256 _rewardsDistributed
    ) internal view returns (uint256) {
        uint256 supply = delegate.totalSupply();

        uint256 assets = govToken.balanceOf(address(delegate)) +
            _rewardsDistributed;

        return _amount.mulDivDown(supply + 1, assets + 1);
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

        assertEq(govToken.balanceOf(address(delegate)), 0);

        _stake(_depositor, _keyper, _amount);

        assertEq(
            govToken.balanceOf(_depositor),
            0,
            "Tokens were not transferred"
        );
        assertEq(
            govToken.balanceOf(address(delegate)),
            _amount,
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

        _mintGovToken(_depositor, _amount);
        _setKeyper(_keyper, true);

        vm.assume(
            _depositor != address(0) &&
                _depositor != ProxyUtils.getAdminAddress(address(delegate))
        );

        _stake(_depositor, _keyper, _amount);

        assertEq(delegate.totalSupply(), _amount);
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

        _mintGovToken(_depositor1, _amount1);
        _mintGovToken(_depositor2, _amount2);

        _setKeyper(_keyper, true);

        _stake(_depositor1, _keyper, _amount1);
        _stake(_depositor2, _keyper, _amount2);

        assertEq(
            delegate.totalSupply(),
            _amount1 + _amount2,
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

        _jumpAhead(_jump);
        uint256 _shares2 = _convertToSharesIncludeRewardsDistributed(
            _amount2,
            REWARD_RATE * _jump
        );

        _stake(_keyper, _depositor, _amount2);

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
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor1, _amount);
        _mintGovToken(_depositor2, _amount);

        _setKeyper(_keyper1, true);
        _setKeyper(_keyper2, true);

        uint256 shares = delegate.convertToShares(_amount);

        _stake(_depositor1, _keyper1, _amount);
        _stake(_depositor2, _keyper2, _amount);

        assertEq(
            delegate.balanceOf(_depositor1),
            delegate.balanceOf(_depositor2),
            "Wrong balance"
        );
        assertEq(delegate.balanceOf(_depositor1), shares);
        assertEq(delegate.balanceOf(_depositor2), shares);
        assertEq(delegate.totalSupply(), 2 * shares);
    }
}
