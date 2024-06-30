// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@forge-std/Test.sol";
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
        govToken.mint(address(this), 1_000_000_000e18);
        vm.label(address(govToken), "govToken");

        // deploy rewards distributor
        rewardsDistributor = new RewardsDistributor(
            address(this),
            address(govToken)
        );
    }

    function _jumpAhead(uint256 _seconds) public {
        vm.warp(vm.getBlockTimestamp() + _seconds);
    }

    function _setRewardConfiguration(
        address receiver,
        uint256 emissionRate
    ) internal {
        emissionRate = bound(emissionRate, 0, 1e18);
        rewardsDistributor.setRewardConfiguration(receiver, emissionRate);
    }
}

contract OwnableFunctions is RewardsDistributorTest {
    function testFuzz_SetRewardConfigurationEmitEvent(
        address _receiver,
        uint256 _emissionRate
    ) public {
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
        rewardsDistributor.setRewardConfiguration(_receiver, _emissionRate);

        (, uint256 lastUpdate) = rewardsDistributor.rewardConfigurations(
            _receiver
        );
        assertEq(lastUpdate, vm.getBlockTimestamp());
    }

    function testFuzz_RevertIf_SetRewardConfigurationZeroAddress(
        uint256 _emissionRate
    ) public {
        vm.expectRevert(RewardsDistributor.ZeroAddress.selector);
        rewardsDistributor.setRewardConfiguration(address(0), _emissionRate);
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

        uint256 balanceBefore = govToken.balanceOf(address(this));

        rewardsDistributor.setRewardToken(_token);

        assertEq(
            govToken.balanceOf(address(this)),
            balanceBefore + _depositAmount
        );
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
        _amount = bound(_amount, 0, govToken.balanceOf(address(this)));
        govToken.transfer(address(rewardsDistributor), _amount);

        uint256 balanceBefore = govToken.balanceOf(_to);

        rewardsDistributor.withdrawFunds(_to, _amount);

        assertEq(govToken.balanceOf(_to), balanceBefore + _amount);
    }

    function testFuzz_RevertIf_WithdrawFundsNotOwner(
        address _anyone,
        address _to,
        uint256 _amount
    ) public {
        vm.assume(_anyone != address(this));

        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                _anyone
            )
        );
        vm.prank(_anyone);
        rewardsDistributor.withdrawFunds(_to, _amount);
    }
}
