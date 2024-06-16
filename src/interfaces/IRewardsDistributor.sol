// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface IRewardsDistributor {
    struct RewardConfiguration {
        address token; // the reward token
        uint256 emissionRate; // emission per second
        uint256 lastUpdate; // last update timestamp
    }

    function addRewardConfiguration(
        address receiver,
        address token,
        uint256 emissionRate
    ) external;

    function updateEmissonRate(
        address receiver,
        address token,
        uint256 emissionRate
    ) external;

    function distributeReward(address token) external;

    function distributeRewards() external;

    function rewardConfigurations(
        address receiver,
        uint256 index
    )
        external
        view
        returns (address token, uint256 emissionRate, uint256 lastUpdate);

    function rewardConfigurationsIds(
        address receiver,
        address token
    ) external view returns (uint256);
}
