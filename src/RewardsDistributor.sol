// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IRewardsDistributor} from "./interfaces/IRewardsDistributor.sol";

contract RewardsDistributor is Ownable2Step, IRewardsDistributor {
    /*//////////////////////////////////////////////////////////////
                                 LIBRARIES
    //////////////////////////////////////////////////////////////*/
    using SafeERC20 for IERC20;

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

    /// @notice Initialize the contract
    /// @param newOwner The owner of the contract, i.e. the DAO contract address
    /// @param _rewardToken The reward token, i.e. SHU
    constructor(address newOwner, address _rewardToken) Ownable(newOwner) {
        // Set the reward token
        rewardToken = IERC20(_rewardToken);
    }

    /// @notice Distribute rewards to receiver
    function collectRewards() external override returns (uint256) {
        address receiver = msg.sender;

        RewardConfiguration storage rewardConfiguration = rewardConfigurations[
            receiver
        ];

        // difference in time since last update
        uint256 timeDelta = block.timestamp - rewardConfiguration.lastUpdate;

        uint256 funds = rewardToken.balanceOf(address(this));

        uint256 rewards = rewardConfiguration.emissionRate * timeDelta;

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

        return rewards;
    }

    /// @notice Add a reward configuration
    /// @param receiver The receiver of the rewards
    /// @param emissionRate The emission rate
    function setRewardConfiguration(
        address receiver,
        uint256 emissionRate
    ) external override onlyOwner {
        require(receiver != address(0), ZeroAddress());

        // only update last update if it's the first time
        if (rewardConfigurations[receiver].lastUpdate == 0) {
            rewardConfigurations[receiver].lastUpdate = block.timestamp;
        }
        rewardConfigurations[receiver].emissionRate = emissionRate;

        emit RewardConfigurationSet(receiver, emissionRate);
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
