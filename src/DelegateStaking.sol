// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EnumerableSetLib} from "@solady/utils/EnumerableSetLib.sol";
import {OwnableUpgradeable} from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {ERC20VotesUpgradeable} from "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/ERC20VotesUpgradeable.sol";

import {BaseStaking} from "./BaseStaking.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {SafeTransferLib} from "./libraries/SafeTransferLib.sol";
import {FixedPointMathLib} from "./libraries/FixedPointMathLib.sol";
import {IRewardsDistributor} from "./interfaces/IRewardsDistributor.sol";

interface IStaking {
    function keypers(address user) external returns (bool);
}

/**
 * @title Shutter Delegate Staking Contract - dSHU token
 *
 * This contract lets users stake their SHU tokens for a set period and earn rewards.
 * When you stake SHU, you receive dSHU in return. dSHU is non-transferable and represents
 * your share in the total SHU deposited in this contract.
 *
 * A user's SHU balance is calculated as:
 *   balanceOf(user) * totalSupply() / totalShares()
 *
 * Staking, unstaking, and claiming rewards are based on shares, not the balance directly.
 * This method ensures the balance can change over time without needing too many storage updates.
 *
 * When staking, you must specify a keyper address. This symbolically demonstrates your support
 * for that keyper. The keyper address must be a valid keyper in the staking contract.
 *
 * @dev SHU tokens transferred into the contract without using the `stake` function will be included
 *      in the rewards distribution and shared among all stakers. This contract only supports SHU
 *      tokens. Any non-SHU tokens transferred into the contract will be permanently lost.
 *
 */
contract DelegateStaking is BaseStaking {
    /*//////////////////////////////////////////////////////////////
                               LIBRARIES
    //////////////////////////////////////////////////////////////*/
    using EnumerableSetLib for EnumerableSetLib.Uint256Set;

    using SafeTransferLib for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice the staking contract
    /// @dev only owner can change
    IStaking public staking;

    /*//////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice the stake struct
    /// @dev timestamp is the time the stake was made
    struct Stake {
        address keyper;
        uint256 amount;
        uint256 timestamp;
        uint256 lockPeriod;
    }

    /*//////////////////////////////////////////////////////////////
                                MAPPINGS
    //////////////////////////////////////////////////////////////*/

    /// @notice stores the metadata associated with a given stake
    mapping(uint256 id => Stake _stake) public stakes;

    /// @notice stores the amount delegated to a keyper
    mapping(address keyper => uint256 totalDelegated) public totalDelegated;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a keyper stakes SHU
    event Staked(
        address indexed user,
        address indexed keyper,
        uint256 amount,
        uint256 lockPeriod
    );

    /// @notice Emitted when a keyper unstakes SHU
    event Unstaked(address indexed user, uint256 amount, uint256 shares);

    /// @notice Emitted when a new staking contract is set
    event NewStakingContract(address indexed stakingContract);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a user has no shares
    error UserHasNoShares();

    /// @notice Trown when amount is zero
    error ZeroAmount();

    /// @notice Thrown when someone try to unstake a stake that doesn't belong
    /// to them
    error StakeDoesNotBelongToUser();

    /// @notice Thrown when someone try to unstake a stake that doesn't exist
    error StakeDoesNotExist();

    /// @notice Thrown when someone try to unstake a stake that is still locked
    error StakeIsStillLocked();

    /// @notice Thrown when the address is not a keyper
    error AddressIsNotAKeyper();

    /// @notice Initialize the contract
    /// @param _owner The owner of the contract, i.e. the DAO contract address
    /// @param _stakingToken The address of the staking token, i.e. SHU
    /// @param _rewardsDistributor The address of the rewards distributor
    /// contract
    /// @param _stakingContract The address of the staking contract
    /// @param _lockPeriod The lock period in seconds
    function initialize(
        address _owner,
        address _stakingToken,
        address _rewardsDistributor,
        address _stakingContract,
        uint256 _lockPeriod
    ) public initializer {
        __ERC20_init("Delegated Staking SHU", "dSHU");

        // Transfer ownership to the DAO contract
        _transferOwnership(_owner);

        stakingToken = IERC20(_stakingToken);
        rewardsDistributor = IRewardsDistributor(_rewardsDistributor);
        staking = IStaking(_stakingContract);
        lockPeriod = _lockPeriod;

        nextStakeId = 1;
    }

    /// @notice Stake SHU
    ///          - amount will be locked in the contract for the lock period
    ///          - user must approve the contract to spend the SHU before staking
    ///          - this function will mint dSHU to the keyper
    ////         - dSHU is non-transferable
    /// @param amount The amount of SHU to stake
    /// @return stakeId The index of the stake
    function stake(
        address keyper,
        uint256 amount
    ) external updateRewards returns (uint256 stakeId) {
        require(amount > 0, ZeroAmount());

        require(staking.keypers(keyper), AddressIsNotAKeyper());

        address user = msg.sender;

        stakeId = nextStakeId++;

        // Add the stake id to the user stakes
        userStakes[user].add(stakeId);

        // Add the stake to the stakes mapping
        stakes[stakeId].keyper = keyper;
        stakes[stakeId].amount = amount;
        stakes[stakeId].timestamp = block.timestamp;
        stakes[stakeId].lockPeriod = lockPeriod;

        // Increase the keyper total delegated amount
        totalDelegated[keyper] += amount;

        _deposit(user, amount);

        emit Staked(user, keyper, amount, lockPeriod);
    }

    /// @notice Unstake SHU
    ///          - stakeId must be a valid id beloging to the user
    ///          - if the stake lock period is less than the global lock period, the
    ///            block.timestamp must be greater than the stake timestamp +
    ///            lock period
    ///          - if the stake lock period is greater than the global lock
    ///            period, the block.timestamp must be greater than the stake timestamp +
    ///            lock period
    ///          - if amount is zero, the contract will transfer the stakeId
    ///            total amount
    ///          - if amount is specified, it must be less than the stakeId amount
    ///          - amount must be specified in SHU, not dSHU
    /// @param stakeId The stake index
    /// @param _amount The amount
    /// @return amount The amount of SHU unstaked
    function unstake(
        uint256 stakeId,
        uint256 _amount
    ) external updateRewards returns (uint256 amount) {
        address user = msg.sender;
        require(userStakes[user].contains(stakeId), StakeDoesNotBelongToUser());
        Stake memory userStake = stakes[stakeId];

        require(userStake.amount > 0, StakeDoesNotExist());

        amount = _calculateWithdrawAmount(_amount, userStake.amount);

        // If the lock period is less than the global lock period, the stake
        // must be locked for the lock period
        // If the global lock period is greater than the stake lock period,
        // the stake must be locked for the stake lock period
        uint256 lock = userStake.lockPeriod > lockPeriod
            ? lockPeriod
            : userStake.lockPeriod;

        require(
            block.timestamp > userStake.timestamp + lock,
            StakeIsStillLocked()
        );

        // Decrease the amount from the stake
        stakes[stakeId].amount -= amount;

        // Decrease the total delegated amount
        totalDelegated[userStake.keyper] -= amount;

        // If the stake is empty, remove it
        if (stakes[stakeId].amount == 0) {
            // Remove the stake from the stakes mapping
            delete stakes[stakeId];

            // Remove the stake from the user stakes
            userStakes[user].remove(stakeId);
        }

        uint256 shares = _withdraw(user, amount);

        emit Unstaked(user, amount, shares);
    }

    /*//////////////////////////////////////////////////////////////
                         RESTRICTED FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Set the staking contract
    ///         The staking contract is the contract that will be used to
    ///         determine if an address is a keyper
    /// @param _stakingContract The address of the staking contract
    /// @dev Only the owner can call this function
    /// @dev The staking contract must not be the zero address
    function setStakingContract(address _stakingContract) external onlyOwner {
        require(_stakingContract != address(0), AddressZero());
        staking = IStaking(_stakingContract);

        emit NewStakingContract(_stakingContract);
    }

    /*//////////////////////////////////////////////////////////////
                                OVERRIDE
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the maximum amount of assets that a keyper can withdraw
    ////         - if the user has no shares, the function will revert
    ///          - if the user dSHU balance is less or equal than the total
    ///            locked amount, the function will return 0
    /// @param user The user address
    /// @return amount The maximum amount of assets that a user can withdraw
    function maxWithdraw(
        address user
    ) public view override returns (uint256 amount) {
        uint256 shares = balanceOf(user);
        require(shares > 0, UserHasNoShares());

        uint256 assets = convertToAssets(shares);
        uint256 locked = totalLocked[user];

        // need the first branch as convertToAssets rounds down
        amount = locked >= assets ? 0 : assets - locked;
    }
}
