// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRewardsDistributor} from "./IRewardsDistributor.sol";

interface IStaking {
    function initialize(
        address newOwner,
        IERC20 _stakingToken,
        IRewardsDistributor _rewardsDistributor,
        uint256 _lockPeriod,
        uint256 _minStake
    ) external;

    function stake(uint256 amount) external;

    function unstake(
        address keyper,
        uint256 stakeIndex,
        uint256 amount
    ) external;

    function claimReward(IERC20 rewardToken, uint256 amount) external;

    function harvest(address keyper) external;

    function setRewardsDistributor(
        IRewardsDistributor _rewardsDistributor
    ) external;

    function setLockPeriod(uint256 _lockPeriod) external;

    function setMinStake(uint256 _minStake) external;

    function setKeyper(address keyper, bool isKeyper) external;

    function setKeypers(address[] memory _keypers, bool isKeyper) external;

    function addRewardToken(address rewardToken) external;

    function convertToShares(uint256 assets) external view returns (uint256);

    function convertToAssets(uint256 shares) external view returns (uint256);

    function totalAssets() external view returns (uint256);

    function maxWithdraw(address keyper) external view returns (uint256);

    function maxClaimableRewards(
        address keyper
    ) external view returns (uint256);

    event Staked(
        address indexed user,
        uint256 indexed amount,
        uint256 indexed shares,
        uint256 lockPeriod
    );
    event Unstaked(address user, uint256 amount, uint256 shares);
    event ClaimRewards(address user, address rewardToken, uint256 rewards);
}
