// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IRewardsDistributor {
    function setRewardConfiguration(
        address receiver,
        address token,
        uint256 emissionRate
    ) external;

    function distributeReward(address token) external;

    function distributeRewards() external;

    function getRewardTokens(
        address receiver
    ) external view returns (address[] memory);

    function rewardConfigurations(
        address receiver,
        address token
    ) external view returns (uint256 emissionRate, uint256 lastUpdate);
}
