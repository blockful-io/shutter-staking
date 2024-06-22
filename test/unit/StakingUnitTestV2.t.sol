// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "@forge-std/Test.sol";

import {FixedPointMathLib} from "@solmate/utils/FixedPointMathLib.sol";
import {TransparentUpgradeableProxy, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Staking} from "src/Staking.sol";
import {RewardsDistributor} from "src/RewardsDistributor.sol";
import {IRewardsDistributor} from "src/interfaces/IRewardsDistributor.sol";
import {MockGovToken} from "test/mocks/MockGovToken.sol";

contract StakingTest is Test {
    using FixedPointMathLib for uint256;

    Staking public staking;
    IRewardsDistributor public rewardsDistributor;
    MockGovToken public govToken;

    uint256 constant LOCK_PERIOD = 60 * 24 * 30 * 6; // 6 months
    uint256 constant MIN_STAKE = 50_000 * 1e18; // 50k
    uint256 constant REWARD_RATE = 1e18;

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
        return bound(_amount, 0, 100_000_000e18);
    }

    function _boundRealisticTimeAhead(
        uint256 _time
    ) internal pure returns (uint256) {
        return bound(_time, 1, 105 weeks); // two years
    }

    function _mintGovToken(address _to, uint256 _amount) internal {
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
        _depositId = staking.stake(_amount);
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

        vm.assume(_depositor1 != address(0));
        vm.assume(_depositor2 != address(0));

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

        vm.assume(_depositor != address(0));

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

        uint256 depositIndex = _stake(_depositor, _amount);

        (uint256 amount, , ) = staking.stakes(_depositor, depositIndex);

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

        uint256 depositIndex = _stake(_depositor, _amount);

        (, uint256 timestamp, ) = staking.stakes(_depositor, depositIndex);

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

        uint256 depositIndex = _stake(_depositor, _amount);

        (, , uint256 lockPeriod) = staking.stakes(_depositor, depositIndex);

        assertEq(lockPeriod, LOCK_PERIOD, "Wrong lock period");
    }

    function testFuzz_trackAmountStakedIndividuallyPerStake(
        address _depositor,
        uint256 _amount1,
        uint256 _amount2
    ) public {
        _amount1 = _boundToRealisticStake(_amount1);
        _amount2 = _boundToRealisticStake(_amount2);

        _mintGovToken(_depositor, _amount1 + _amount2);
        _setKeyper(_depositor, true);

        vm.assume(_depositor != address(0));

        uint256 depositIndex1 = _stake(_depositor, _amount1);
        uint256 depositIndex2 = _stake(_depositor, _amount2);

        (uint256 amount1, , ) = staking.stakes(_depositor, depositIndex1);
        (uint256 amount2, , ) = staking.stakes(_depositor, depositIndex2);

        assertEq(amount1, _amount1, "Wrong amount");
        assertEq(amount2, _amount2, "Wrong amount");
    }
}
