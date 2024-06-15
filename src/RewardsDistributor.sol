// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeTransferLib} from "@solmate/utils/SafeTransferLib.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";

interface IRewardsDistributor {
    function distributeRewards() external;
}

// TODO should be pausable?
contract RewardsDistributor is Ownable2StepUpgradeable {
    /*//////////////////////////////////////////////////////////////
                               LIBRARIES
    //////////////////////////////////////////////////////////////*/
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice the reward configuration
    struct RewardConfiguration {
        address token; // the reward token
        uint256 emissionRate; // emission per second
        uint256 lastUpdate; // last update timestamp
    }

    /// @notice reward configurations
    mapping(address receiver => RewardConfiguration[])
        public rewardConfigurations;

    mapping(address receiver => mapping(address token => uint256 id))
        public rewardConfigurationsIds;

    /// @notice Ensure logic contract is unusable
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the contract
    /// @param newOwner The owner of the contract, i.e. the DAO contract address
    function initialize(address newOwner) public initializer {
        __Ownable2Step_init();

        // Transfer ownership to the DAO contract
        transferOwnership(newOwner);
    }

    /// @notice Add a reward configuration
    /// @param receiver The receiver of the rewards
    /// @param token The reward token
    /// @param emissionRate The emission rate
    function addRewardConfiguration(
        address receiver,
        address token,
        uint256 emissionRate
    ) external onlyOwner {
        require(token != address(0), "No native rewards allowed");
        require(emissionRate > 0, "Emission rate must be greater than 0");

        rewardConfigurations[receiver].push(
            RewardConfiguration(token, emissionRate, block.timestamp)
        );

        rewardConfigurationsIds[receiver][token] = rewardConfigurations[
            receiver
        ].length;
    }

    /// @notice Update the emission rate of a reward configuration
    /// @param receiver The receiver of the rewards
    /// @param token The reward token
    /// @param emissionRate The new emission rate
    /// @dev set the emission rate to 0 to stop the rewards
    function updateEmissonRate(
        address receiver,
        address token,
        uint256 emissionRate
    ) external onlyOwner {
        uint256 id = rewardConfigurationsIds[receiver][token];
        require(
            rewardConfigurations[receiver].length > 0 && id > 0,
            "No reward configuration found"
        );

        // index is always 1 less than the id
        rewardConfigurations[receiver][id - 1].emissionRate = emissionRate;
    }

    /// @notice Distribute rewards to receiver
    /// @param token The reward token
    function distributeReward(address token) external {
        address receiver = msg.sender;

        uint256 id = rewardConfigurationsIds[receiver][token];

        require(
            rewardConfigurations[receiver].length > 0 && id > 0,
            "No reward configuration found"
        );

        RewardConfiguration storage rewardConfiguration = rewardConfigurations[
            receiver
        ][id - 1];

        // difference in time since last update
        uint256 timeDelta = block.timestamp - rewardConfiguration.lastUpdate;

        if (timeDelta == 0) {
            // nothing to do
            return;
        }

        uint256 reward = rewardConfiguration.emissionRate * timeDelta;

        // update the last update timestamp
        rewardConfiguration.lastUpdate = block.timestamp;

        // transfer the reward
        // TODO change to safeTransfer
        IERC20(token).safeTransfer(receiver, reward);
    }
}
