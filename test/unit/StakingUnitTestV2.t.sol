// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "@forge-std/Test.sol";

import {TransparentUpgradeableProxy, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {StakingV2 as Staking} from "../../src/StakingV2.sol";
import {RewardsDistributor} from "../../src/RewardsDistributor.sol";
import {IRewardsDistributor} from "../../src/interfaces/IRewardsDistributor.sol";

import {MockGovToken} from "../mocks/MockGovToken.sol";

contract StakingUnitTest is Test {
    Staking public staking;
    MockGovToken public govToken;

    uint256 constant LOCK_PERIOD = 60 * 24 * 30 * 6; // 6 months
    uint256 constant MIN_STAKE = 50_000 * 1e18; // 50k

    address keyper1 = address(0x1234);
    address keyper2 = address(0x5678);

    function setUp() public {
        // Set the block timestamp to an arbitrary value to avoid introducing assumptions into tests
        // based on a starting timestamp of 0, which is the default.
        _jumpAhead(1234);

        govToken = new MockGovToken();
        vm.label(govToken, "govToken");

        // deploy rewards distributor
        address rewardsDistributionProxy = address(
            new TransparentUpgradeableProxy(
                address(new RewardsDistributor()),
                address(this),
                abi.encodeWithSignature("initialize(address)", address(this))
            )
        );

        // deploy staking
        address stakingImpl = address(new Staking());

        staking = Staking(
            new TransparentUpgradeableProxy(stakingImpl, address(this), "")
        );
        vm.label(staking, "staking");

        staking.initialize(
            address(this), // owner
            address(govToken),
            address(rewardsDistributionProxy),
            lockPeriod,
            minStake
        );

        staking = Staking(stakingProxy);

        IRewardsDistributor(rewardsDistributionProxy).setRewardConfiguration(
            stakingProxy,
            address(shu),
            1e18
        );

        // fund reward distribution
        govToken.transfer(rewardsDistributionProxy, 1_000_000 * 1e18);
    }

    function _jumpAhead(uint256 _seconds) public {
        vm.warp(block.timestamp + _seconds);
    }

    function _boundMintAmount(uint96 _amount) internal pure returns (uint96) {
        return uint96(bound(_amount, 0, 100_000_000e18));
    }

    function _mintGovToken(address _to, uint96 _amount) internal {
        vm.assume(_to != address(0));
        govToken.mint(_to, _amount);
    }

    function _boundToRealisticStake(
        uint256 _stakeAmount
    ) public pure returns (uint256 _boundedStakeAmount) {
        _boundedStakeAmount = uint256(
            bound(_stakeAmount, MIN_STAKE, 25_000_000e18)
        );
    }

    function _stake(
        address _keyper,
        uint256 _amount
    ) internal returns (uint256 _depositId) {
        vm.assume(_keyper != address(0));

        vm.startPrank(_keyper);
        govToken.approve(address(staking), _amount);
        _depositId = uniStaker.stake(_amount, _delegatee, _beneficiary);
        vm.stopPrank();
    }

    function _setKeyper(address _keyper, bool _isKeyper) internal {
        staking.setKeyper(_keyper, _isKeyper);
    }
}

contract Initializer is StakingUnitTest {
    function test_Initialize() public {
        assertEq(staking.owner(), address(this), "Wrong owner");
        assertEq(
            staking.stakingToken(),
            address(govToken),
            "Wrong staking token"
        );
        assertEq(
            staking.rewardsDistributor(),
            address(rewardsDistributionProxy),
            "Wrong rewards distributor"
        );
        assertEq(staking.lockPeriod(), lockPeriod, "Wrong lock period");
        assertEq(staking.minStake(), minStake, "Wrong min stake");
    }
}

contract Stake is StakingUnitTest {
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

    function testFuz_EmitsAStakeEventWhenStaking(
        address _depositor,
        uint256 _amount
    ) {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor, _amount);

        vm.assume(_depositor != address(0));

        vm.startPrank(_depositor);
        govToken.approve(address(staking), _amount);
        vm.expectEmit();
        emit IStaking.Staked(keyper1, _amount, LOCK_PERIOD);

        staking.stake(_amount);
        vm.stopPrank();
    }

    function testFuzz_UpdatesTotalSupplyWhenStaking(
        address _depositor,
        uint256 _amount
    ) {
        _amount = _boundToRealisticStake(_amount);

        _mintGovToken(_depositor, _amount);

        vm.assume(_depositor != address(0));

        _stake(_depositor, _amount);

        assertEq(staking.totalSupply(), _amount, "Wrong total supply");
    }

    function testFuzz_UpdatesTotalSupplyWhenTwoAccountsStakes(
        address _depositor1,
        address _depositor2,
        uint256 _amount1,
        uint256 _amount2
    ) {
        _amount1 = _boundToRealisticStake(_amount1);
        _amount2 = _boundToRealisticStake(_amount2);

        _mintGovToken(_depositor1, _amount1);
        _mintGovToken(_depositor2, _amount2);

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
}