// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@forge-std/Test.sol";
import "@forge-std/StdUtils.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {RewardsDistributor} from "src/RewardsDistributor.sol";
import {MockGovToken} from "test/mocks/MockGovToken.sol";

contract RewardsDistributorTest is Test {
    RewardsDistributor public rewardsDistributor;
    MockGovToken public govToken;

    function setUp() public {
        // Set the block timestamp to an arbitrary value to avoid introducing assumptions into tests
        // based on a starting timestamp of 0, which is the default.
        _jumpAhead(1234);

        govToken = new MockGovToken();
        vm.label(address(govToken), "govToken");

        // deploy rewards distributor
        rewardsDistributor = new RewardsDistributor(
            address(this),
            address(govToken)
        );
    }

    function _jumpAhead(uint256 _seconds) public returns (uint256) {
        _seconds = bound(_seconds, 1, 26 weeks);
        vm.warp(vm.getBlockTimestamp() + _seconds);

        return _seconds;
    }
}

contract Constructor is RewardsDistributorTest {
    function test_SetOwnerAndRewardToken() public view {
        assertEq(address(rewardsDistributor.rewardToken()), address(govToken));
        assertEq(Ownable(address(rewardsDistributor)).owner(), address(this));
    }

    function testFuzz_SetOwnerAndRewardTokenToArbitraryAddress(
        address _owner,
        address _rewardToken
    ) public {
        vm.assume(_owner != address(0));

        RewardsDistributor rewardsDistributor = new RewardsDistributor(
            _owner,
            _rewardToken
        );
        assertEq(address(rewardsDistributor.rewardToken()), _rewardToken);
        assertEq(Ownable(address(rewardsDistributor)).owner(), _owner);
    }
}

contract OwnableFunctions is RewardsDistributorTest {
    function testFuzz_SetRewardConfigurationEmitEvent(
        address _receiver,
        uint256 _emissionRate
    ) public {
        _emissionRate = bound(_emissionRate, 1, 1e18);
        vm.assume(_receiver != address(0));

        vm.expectEmit();
        emit RewardsDistributor.RewardConfigurationSet(
            _receiver,
            _emissionRate
        );
        rewardsDistributor.setRewardConfiguration(_receiver, _emissionRate);
    }

    function testFuzz_SetRewardConfigurationSetEmissionRate(
        address _receiver,
        uint256 _emissionRate
    ) public {
        _emissionRate = bound(_emissionRate, 1, 1e18);
        vm.assume(_receiver != address(0));

        rewardsDistributor.setRewardConfiguration(_receiver, _emissionRate);

        (uint256 emissionRate, ) = rewardsDistributor.rewardConfigurations(
            _receiver
        );

        assertEq(emissionRate, _emissionRate);
    }

    function testFuzz_SetRewardConfigurationSetLastUpdate(
        address _receiver,
        uint256 _emissionRate
    ) public {
        _emissionRate = bound(_emissionRate, 1, 1e18);
        vm.assume(_receiver != address(0));

        rewardsDistributor.setRewardConfiguration(_receiver, _emissionRate);

        (, uint256 lastUpdate) = rewardsDistributor.rewardConfigurations(
            _receiver
        );
        assertEq(lastUpdate, vm.getBlockTimestamp());
    }

    function testFuzz_TransferTokensIfIsAnUpdate(
        address _receiver,
        uint256 _emissionRate
    ) public {
        _emissionRate = bound(_emissionRate, 1, 1e18);
        vm.assume(_receiver != address(0));

        rewardsDistributor.setRewardConfiguration(_receiver, _emissionRate);

        (, uint256 lastUpdateBefore) = rewardsDistributor.rewardConfigurations(
            _receiver
        );

        uint256 balanceBefore = govToken.balanceOf(_receiver);

        govToken.mint(address(rewardsDistributor), _emissionRate);

        vm.warp(vm.getBlockTimestamp() + 1);
        rewardsDistributor.setRewardConfiguration(_receiver, _emissionRate);

        assertEq(govToken.balanceOf(_receiver), balanceBefore + _emissionRate);

        (, uint256 lastUpdateAfter) = rewardsDistributor.rewardConfigurations(
            _receiver
        );

        assertEq(lastUpdateBefore + 1, lastUpdateAfter);
    }

    function testFuzz_RevertIf_SetRewardConfigurationZeroAddress(
        uint256 _emissionRate
    ) public {
        vm.expectRevert(RewardsDistributor.ZeroAddress.selector);
        rewardsDistributor.setRewardConfiguration(address(0), _emissionRate);
    }

    function testFuzz_RevertIf_SetRewardConfigurationEmissionRateZero(
        address _receiver
    ) public {
        vm.assume(_receiver != address(0));
        vm.expectRevert(RewardsDistributor.EmissionRateZero.selector);
        rewardsDistributor.setRewardConfiguration(_receiver, 0);
    }

    function testFuzz_RevertIf_SetRewardConfigurationNotOwner(
        address _anyone,
        address _receiver,
        uint256 _emissionRate
    ) public {
        vm.assume(_anyone != address(this));

        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                _anyone
            )
        );
        vm.prank(_anyone);
        rewardsDistributor.setRewardConfiguration(_receiver, _emissionRate);
    }

    function testFuzz_SetRewardTokenEmitEvent(address _token) public {
        vm.assume(_token != address(0));

        vm.expectEmit();
        emit RewardsDistributor.RewardTokenSet(_token);
        rewardsDistributor.setRewardToken(_token);
    }

    function testFuzz_SetRewardTokenWithdrawFunds(
        address _token,
        uint256 _depositAmount
    ) public {
        vm.assume(_token != address(0));

        _depositAmount = bound(
            _depositAmount,
            0,
            govToken.balanceOf(address(this))
        );
        govToken.transfer(address(rewardsDistributor), _depositAmount);

        uint256 balanceBeforeOwner = govToken.balanceOf(address(this));
        uint256 balanceBeforeContract = govToken.balanceOf(
            address(rewardsDistributor)
        );

        rewardsDistributor.setRewardToken(_token);

        assertEq(
            govToken.balanceOf(address(this)),
            balanceBeforeOwner + balanceBeforeContract
        );

        assertEq(govToken.balanceOf(address(rewardsDistributor)), 0);
    }

    function testFuzz_RevertIf_SetRewardTokenNotOwner(
        address _anyone,
        address _token
    ) public {
        vm.assume(_token != address(0));
        vm.assume(_anyone != address(this));

        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                _anyone
            )
        );
        vm.prank(_anyone);
        rewardsDistributor.setRewardToken(_token);
    }

    function testFuzz_RevertIf_SetRewardTokenZeroAddress() public {
        vm.expectRevert(RewardsDistributor.ZeroAddress.selector);
        rewardsDistributor.setRewardToken(address(0));
    }

    function testFuzz_WithdrawFunds(address _to, uint256 _amount) public {
        vm.assume(_to != address(0));

        _amount = bound(_amount, 0, govToken.balanceOf(address(this)));
        govToken.transfer(address(rewardsDistributor), _amount);

        uint256 balanceBefore = govToken.balanceOf(_to);

        rewardsDistributor.withdrawFunds(
            address(rewardsDistributor.rewardToken()),
            _to,
            _amount
        );

        assertEq(govToken.balanceOf(_to), balanceBefore + _amount);
    }

    function testFuzz_RevertIf_WithdrawFundsNotOwner(
        address _anyone,
        address _to,
        uint256 _amount
    ) public {
        vm.assume(_anyone != address(this));

        govToken.mint(address(rewardsDistributor), _amount);

        address token = address(rewardsDistributor.rewardToken());
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                _anyone
            )
        );

        vm.prank(_anyone);
        rewardsDistributor.withdrawFunds(token, _to, _amount);
    }
}

contract CollectRewards is RewardsDistributorTest {
    function testFuzz_CollectRewardsReturnsRewardAmount(
        address _receiver,
        uint256 _jump,
        uint256 _emissionRate
    ) public {
        vm.assume(address(_receiver) != address(0));

        _emissionRate = bound(_emissionRate, 1, 1e18);
        rewardsDistributor.setRewardConfiguration(_receiver, _emissionRate);

        uint256 jump = _jumpAhead(_jump);
        govToken.mint(address(rewardsDistributor), _emissionRate * jump);

        uint256 expectedRewards = _emissionRate * jump;

        vm.prank(_receiver);
        uint256 rewards = rewardsDistributor.collectRewards();

        assertEq(rewards, expectedRewards);
    }

    function testFuzz_CollectRewardsEmitEvent(
        address _receiver,
        uint256 _jump,
        uint256 _emissionRate
    ) public {
        vm.assume(address(_receiver) != address(0));

        _emissionRate = bound(_emissionRate, 1, 1e18);
        rewardsDistributor.setRewardConfiguration(_receiver, _emissionRate);

        uint256 timestampBefore = vm.getBlockTimestamp();

        uint256 jump = _jumpAhead(_jump);
        govToken.mint(address(rewardsDistributor), _emissionRate * jump);

        vm.expectEmit();
        emit RewardsDistributor.RewardCollected(
            _receiver,
            _emissionRate * (vm.getBlockTimestamp() - timestampBefore)
        );

        vm.prank(_receiver);
        rewardsDistributor.collectRewards();
    }

    function testFuzz_CollectRewardsTransferTokens(
        address _receiver,
        uint256 _jump,
        uint256 _emissionRate
    ) public {
        vm.assume(
            _receiver != address(0) && _receiver != address(rewardsDistributor)
        );

        _emissionRate = bound(_emissionRate, 1, 1e18);
        rewardsDistributor.setRewardConfiguration(_receiver, _emissionRate);

        uint256 timestampBefore = vm.getBlockTimestamp();

        uint256 jump = _jumpAhead(_jump);
        govToken.mint(address(rewardsDistributor), _emissionRate * jump);

        uint256 expectedRewards = _emissionRate *
            (vm.getBlockTimestamp() - timestampBefore);

        vm.prank(_receiver);
        rewardsDistributor.collectRewards();

        assertEq(govToken.balanceOf(_receiver), expectedRewards);
    }

    function testFuzz_CollectRewardsReturnZeroWhenEmissionRateIsZero(
        address _receiver,
        uint256 _jump
    ) public {
        vm.assume(address(_receiver) != address(0));

        rewardsDistributor.removeRewardConfiguration(_receiver);

        _jumpAhead(_jump);

        vm.prank(_receiver);
        uint256 rewards = rewardsDistributor.collectRewards();

        assertEq(rewards, 0);
    }

    function testFuzz_CollectRewardsReturnZeroWhenTimeDeltaIsZero(
        address _receiver
    ) public {
        vm.assume(address(_receiver) != address(0));

        rewardsDistributor.setRewardConfiguration(_receiver, 1);

        vm.prank(_receiver);
        uint256 rewards = rewardsDistributor.collectRewards();

        assertEq(rewards, 0);
    }

    function testFuzz_CollectRewardsWhenFundsAreNotEnough(
        address _receiver,
        uint256 _jump,
        uint256 _emissionRate
    ) public {
        vm.assume(address(_receiver) != address(0));

        _emissionRate = bound(_emissionRate, 0.01e18, 1e18);
        rewardsDistributor.setRewardConfiguration(_receiver, _emissionRate);

        uint256 jump = _jumpAhead(_jump);

        deal(
            address(govToken),
            address(rewardsDistributor),
            _emissionRate * jump - 1
        );

        vm.prank(_receiver);
        uint256 rewards = rewardsDistributor.collectRewards();

        assertEq(rewards, 0);
    }
}
