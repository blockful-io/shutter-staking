// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IRewardsDistributor} from "./interfaces/IRewardsDistributor.sol";
import {SafeTransferLib} from "./libraries/SafeTransferLib.sol";
import {IERC20} from "./interfaces/IERC20.sol";

contract RewardsDistributor is Ownable, IRewardsDistributor {
    /*//////////////////////////////////////////////////////////////
                                 LIBRARIES
    //////////////////////////////////////////////////////////////*/
    using SafeTransferLib for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice the reward token, i.e. SHU
    IERC20 public rewardToken;

    /*//////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice the reward configuration
    struct RewardConfiguration {
        uint256 emissionRate; // emission per second
        uint256 lastUpdate; // last update timestamp
    }

    /*//////////////////////////////////////////////////////////////
                                MAPPINGS
    //////////////////////////////////////////////////////////////*/

    mapping(address receiver => RewardConfiguration configuration)
        public rewardConfigurations;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event RewardConfigurationSet(
        address indexed receiver,
        uint256 emissionRate
    );

    event RewardCollected(address indexed receiver, uint256 reward);

    event RewardTokenSet(address indexed rewardToken);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when address is zero
    error ZeroAddress();

    /// @notice Thrown when emission rate is zero
    error EmissionRateZero();

    /// @notice Thrown when the contract doesn't have enough funds
    error NotEnoughFunds();

    /// @notice Thrown when the time delta is zero
    error TimeDeltaZero();

    /// @notice Initialize the contract
    /// @param _owner The owner of the contract, i.e. the DAO contract address
    /// @param _rewardToken The reward token, i.e. SHU
    constructor(address _owner, address _rewardToken) Ownable(_owner) {
        // Set the reward token
        rewardToken = IERC20(_rewardToken);
    }

    /// @notice Distribute rewards to receiver
    /// Caller must be the receiver
    function collectRewards() external override returns (uint256 rewards) {
        address receiver = msg.sender;

        RewardConfiguration storage rewardConfiguration = rewardConfigurations[
            receiver
        ];

        // difference in time since last update
        uint256 timeDelta = block.timestamp - rewardConfiguration.lastUpdate;

        uint256 funds = rewardToken.balanceOf(address(this));

        rewards = rewardConfiguration.emissionRate * timeDelta;

        // the contract must have enough funds to distribute
        // we don't want to revert in case its zero to not block the staking contract
        if (rewards == 0 || funds < rewards) {
            return 0;
        }

        // update the last update timestamp
        rewardConfiguration.lastUpdate = block.timestamp;

        // transfer the reward
        rewardToken.safeTransfer(receiver, rewards);

        emit RewardCollected(receiver, rewards);
    }

    /// @notice Send rewards to receiver
    /// @param receiver The receiver of the rewards
    function collectRewardsTo(
        address receiver
    ) external override returns (uint256 rewards) {
        RewardConfiguration storage rewardConfiguration = rewardConfigurations[
            receiver
        ];

        require(rewardConfiguration.emissionRate > 0, EmissionRateZero());

        // difference in time since last update
        uint256 timeDelta = block.timestamp - rewardConfiguration.lastUpdate;

        require(timeDelta > 0, TimeDeltaZero());

        uint256 funds = rewardToken.balanceOf(address(this));

        rewards = rewardConfiguration.emissionRate * timeDelta;

        // the contract must have enough funds to distribute
        require(funds >= rewards, NotEnoughFunds());

        // update the last update timestamp
        rewardConfiguration.lastUpdate = block.timestamp;

        // transfer the reward
        rewardToken.safeTransfer(receiver, rewards);

        emit RewardCollected(receiver, rewards);
    }

    /// @notice Add a reward configuration
    /// @param receiver The receiver of the rewards
    /// @param emissionRate The emission rate
    function setRewardConfiguration(
        address receiver,
        uint256 emissionRate
    ) external override onlyOwner {
        require(receiver != address(0), ZeroAddress());

        // to remove a rewards, it should call removeRewardConfiguration
        require(emissionRate > 0, EmissionRateZero());

        // only update last update if it's the first time
        if (rewardConfigurations[receiver].lastUpdate == 0) {
            rewardConfigurations[receiver].lastUpdate = block.timestamp;
        }
        rewardConfigurations[receiver].emissionRate = emissionRate;

        emit RewardConfigurationSet(receiver, emissionRate);
    }

    /// @notice Remove a reward configuration
    /// @param receiver The receiver of the rewards
    function removeRewardConfiguration(address receiver) external onlyOwner {
        delete rewardConfigurations[receiver];

        emit RewardConfigurationSet(receiver, 0);
    }

    /// @notice Withdraw funds from the contract
    /// @param to The address to withdraw to
    /// @param amount The amount to withdraw
    function withdrawFunds(
        address to,
        uint256 amount
    ) public override onlyOwner {
        rewardToken.safeTransfer(to, amount);
    }

    /// @notice Set the reward token
    /// @param _rewardToken The reward token
    function setRewardToken(address _rewardToken) external onlyOwner {
        require(_rewardToken != address(0), ZeroAddress());

        // withdraw remaining old reward token
        withdrawFunds(msg.sender, rewardToken.balanceOf(address(this)));

        // set the new reward token
        rewardToken = IERC20(_rewardToken);

        emit RewardTokenSet(_rewardToken);
    }
}
