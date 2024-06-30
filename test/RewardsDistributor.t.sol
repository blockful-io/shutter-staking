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
    function test_SetRewardConfigurationEmitEvent(
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

    function test_SetRewardConfigurationSetEmissionRate(
        address _receiver,
        uint256 _emissionRate
    ) public {
        rewardsDistributor.setRewardConfiguration(_receiver, _emissionRate);

        (uint256 emissionRate, ) = rewardsDistributor.rewardConfigurations(
            _receiver
        );

        assertEq(emissionRate, _emissionRate);
    }

    function test_SetRewardConfigurationSetLastUpdate(
        address _receiver,
        uint256 _emissionRate
    ) public {
        rewardsDistributor.setRewardConfiguration(_receiver, _emissionRate);

        (, uint256 lastUpdate) = rewardsDistributor.rewardConfigurations(
            _receiver
        );
        assertEq(lastUpdate, vm.getBlockTimestamp());
    }

    function test_RevertIf_SetRewardConfigurationZeroAddress(
        uint256 _emissionRate
    ) public {
        vm.expectRevert(RewardsDistributor.ZeroAddress.selector);
        rewardsDistributor.setRewardConfiguration(address(0), _emissionRate);
    }

    function test_RevertIf_SetRewardConfigurationNotOwner(
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
}
