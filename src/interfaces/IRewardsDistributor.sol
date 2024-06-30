// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IRewardsDistributor {
    function collectRewards() external returns (uint256);

    function withdrawFunds(address to, uint256 amount) external;

    function setRewardConfiguration(
        address receiver,
        uint256 emissionRate
    ) external;

    function setRewardToken(address _rewardToken) external;
}
