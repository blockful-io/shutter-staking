// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@forge-std/Test.sol";
import {TransparentUpgradeableProxy, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {Staking} from "src/Staking.sol";
import {DelegateStaking} from "src/DelegateStaking.sol";
import {RewardsDistributor} from "src/RewardsDistributor.sol";
import {IRewardsDistributor} from "src/interfaces/IRewardsDistributor.sol";
import {MockGovToken} from "test/mocks/MockGovToken.sol";
import {ProxyUtils} from "test/helpers/ProxyUtils.sol";
import {DelegateStakingHarness} from "test/helpers/DelegateStakingHarness.sol";

contract DelegateStakingTest is Test {
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
