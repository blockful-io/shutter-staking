// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import {SafeTransferLib} from "@solmate/utils/SafeTransferLib.sol";

interface IRewardsDistributor {
    function distributeRewards() external;
}

// TODO should be pausable?
contract RewardsDistributor is Ownable2StepUpgradeable {
    /*//////////////////////////////////////////////////////////////
                               LIBRARIES
    //////////////////////////////////////////////////////////////*/
    using SafeTransferLib for ERC20;

    /*//////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice the reward configuration
    struct RewardConfiguration {
        ERC20 token; // the reward token
        uint256 emissionRate; // emission per second
        uint256 lastUpdate; // last update timestamp
    }

    /// @notice reward configurations
    mapping(address receiver => RewardConfiguration[])
        public rewardConfigurations;

    mapping(address receiver => mapping(ERC20 => uint256 id))
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
        ERC20 token,
        uint256 emissionRate
    ) external onlyOwner {
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
        ERC20 token,
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
    function distributeReward(ERC20 token) external {
        uint256 id = rewardConfigurationsIds[msg.sender][token];

        require(
            rewardConfigurations[msg.sender].length > 0 && id > 0,
            "No reward configuration found"
        );

        RewardConfiguration storage rewardConfiguration = rewardConfigurations[
            msg.sender
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
        token.safeTransfer(msg.sender, reward);
    }
}