// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeTransferLib} from "@solmate/utils/SafeTransferLib.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import {IRewardsDistributor} from "./interfaces/IRewardsDistributor.sol";

contract RewardsDistributor is Ownable2StepUpgradeable, IRewardsDistributor {
    /*//////////////////////////////////////////////////////////////
                               LIBRARIES
    //////////////////////////////////////////////////////////////*/
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice the reward token, i.e. SHU
    /// @dev set in initialize, can't be changed
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
                             MAPPINGS/ARRAYS
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

    /// @notice Initialize the contract
    /// @param newOwner The owner of the contract, i.e. the DAO contract address
    constructor(address newOwner, address _rewardToken) {
        // Transfer ownership to the DAO contract
        _transferOwnership(newOwner);

        // Set the reward token
        rewardToken = IERC20(_rewardToken);
    }

    /// @notice Distribute rewards to receiver
    function collectRewards() external override returns (uint256 rewards) {
        address receiver = msg.sender;

        RewardConfiguration storage rewardConfiguration = rewardConfigurations[
            receiver
        ];

        // difference in time since last update
        uint256 timeDelta = block.timestamp - rewardConfiguration.lastUpdate;

        if (rewardConfiguration.emissionRate == 0 || timeDelta == 0) {
            // nothing to do
            return 0;
        }

        rewards = rewardConfiguration.emissionRate * timeDelta;

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
        require(receiver != address(0), "Invalid receiver");

        rewardConfigurations[receiver] = RewardConfiguration(
            emissionRate,
            block.timestamp
        );

        emit RewardConfigurationSet(receiver, emissionRate);
    }

    function withdrawFunds(
        address to,
        uint256 amount
    ) external override onlyOwner {
        rewardToken.safeTransfer(to, amount);
    }
}
