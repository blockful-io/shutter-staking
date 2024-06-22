// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {console} from "@forge-std/console.sol";
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
        uint256 emissionRate; // emission per second
        uint256 lastUpdate; // last update timestamp
    }

    /*//////////////////////////////////////////////////////////////
                             MAPPINGS/ARRAYS
    //////////////////////////////////////////////////////////////*/

    mapping(address receiver => mapping(address token => RewardConfiguration configuration))
        public rewardConfigurations;

    mapping(address receiver => address[] rewardsTokens) public rewardTokens;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event RewardConfigurationSet(
        address indexed receiver,
        address indexed token,
        uint256 emissionRate
    );

    event RewardDistributed(
        address indexed receiver,
        address indexed token,
        uint256 reward
    );

    /// @notice Ensure logic contract is unusable
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the contract
    /// @param newOwner The owner of the contract, i.e. the DAO contract address
    function initialize(address newOwner) public initializer {
        __Ownable2Step_init();

        // Transfer ownership to the DAO contract
        _transferOwnership(newOwner);
    }

    /// @notice Add a reward configuration
    /// @param receiver The receiver of the rewards
    /// @param token The reward token
    /// @param emissionRate The emission rate
    function setRewardConfiguration(
        address receiver,
        address token,
        uint256 emissionRate
    ) external onlyOwner {
        require(receiver != address(0), "Invalid receiver");
        require(token != address(0), "No native rewards allowed");

        if (rewardConfigurations[receiver][token].emissionRate == 0) {
            rewardTokens[receiver].push(token);
        }

        rewardConfigurations[receiver][token] = RewardConfiguration(
            emissionRate,
            block.timestamp
        );

        if (emissionRate == 0) {
            // remove the token
            address[] storage tokens = rewardTokens[receiver];
            for (uint256 i = 0; i < tokens.length; i++) {
                if (tokens[i] == token) {
                    tokens[i] = tokens[tokens.length - 1];
                    tokens.pop();
                    break;
                }
            }
        }

        emit RewardConfigurationSet(receiver, token, emissionRate);
    }

    /// @notice Distribute rewards to receiver
    /// @param token The reward token
    function distributeReward(address token) external {
        distributeRewardInternal(msg.sender, token);
    }

    /// @notice Distribute rewards to all tokens
    function distributeRewards() external {
        address receiver = msg.sender;

        for (uint256 i = 0; i < rewardTokens[receiver].length; i++) {
            distributeRewardInternal(receiver, rewardTokens[receiver][i]);
        }
    }

    /// @notice Distribute rewards to token
    /// @param receiver The receiver of the rewards
    /// @param token The reward token
    function distributeRewardInternal(
        address receiver,
        address token
    ) internal {
        RewardConfiguration storage rewardConfiguration = rewardConfigurations[
            receiver
        ][token];

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
        IERC20(token).safeTransfer(receiver, reward);

        emit RewardDistributed(receiver, token, reward);
    }

    function getRewardTokens(
        address receiver
    ) external view returns (address[] memory) {
        return rewardTokens[receiver];
    }
}
