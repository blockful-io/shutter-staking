// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20VotesUpgradeable} from "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {EnumerableSetLib} from "@solady/utils/EnumerableSetLib.sol";

import {BaseStaking} from "./BaseStaking.sol";
import {SafeTransferLib} from "./libraries/SafeTransferLib.sol";
import {FixedPointMathLib} from "./libraries/FixedPointMathLib.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IRewardsDistributor} from "./interfaces/IRewardsDistributor.sol";

/**
 * @title Shutter Staking Contract - sSHU token
 *
 * This contract lets keypers stake their SHU tokens for a set period and earn rewards.
 * When you stake SHU, you receive sSHU in return. sSHU is non-transferable and shows your share
 * in the total SHU deposited in this contract.
 *
 * A keyper's SHU balance is calculated using:
 *   balanceOf(keyper) * totalSupply() / totalShares()
 *
 * Staking, unstaking, and claiming rewards are based on shares, not the balance directly.
 * This method ensures the balance can change over time without needing too many storage updates.
 *
 * Security Considerations:
 *  Please be aware that the contract's Owner can change the minimum stake amount.
 *  If the Owner is compromised, they could set the minimum stake amount very high,
 *  making it impossible for keypers to unstake their SHU.
 *  The Owner of this contract is the Shutter DAO multisig with a Azorius module.
 *  By staking SHU, you trust the Owner not to set the minimum stake amount to
 *  an unreasonably high value.
 *
 * @dev SHU tokens transferred into the contract without using the `stake` function will be included
 *      in the rewards distribution and shared among all stakers. This contract only supports SHU
 *      tokens. Any non-SHU tokens transferred into the contract will be permanently lost.
 *
 */
contract Staking is BaseStaking {
    /*//////////////////////////////////////////////////////////////
                               LIBRARIES
    //////////////////////////////////////////////////////////////*/
    using EnumerableSetLib for EnumerableSetLib.Uint256Set;

    using SafeTransferLib for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice the minimum stake amount
    /// @dev only owner can change
    uint256 public minStake;

    /*//////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice the stake struct
    /// @dev timestamp is the time the stake was made
    struct Stake {
        uint256 amount;
        uint256 timestamp;
        uint256 lockPeriod;
    }

    /*//////////////////////////////////////////////////////////////
                                MAPPINGS
    //////////////////////////////////////////////////////////////*/

    /// @notice stores the metadata associated with a given stake
    mapping(uint256 id => Stake _stake) public stakes;

    /// @notice keypers mapping
    mapping(address keyper => bool isKeyper) public keypers;

    /// @notice Emitted when a keyper stakes SHU
    event Staked(address indexed user, uint256 amount, uint256 lockPeriod);

    /// @notice Emitted when a keyper unstakes SHU
    event Unstaked(address indexed user, uint256 amount, uint256 shares);

    /// @notice Emitted when a keyper is added or removed
    event KeyperSet(address indexed keyper, bool isKeyper);

    /// @notice Emitted when the minimum stake is changed
    event NewMinStake(uint256 indexed minStake);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    /// @notice Thrown when a user has no shares
    error UserHasNoShares();

    /// @notice Thrown when a non-keyper attempts a call for which only keypers are allowed
    error OnlyKeyper();

    /// @notice Thrown when a keyper has staking for the first time and the
    /// amount is less than the minimum stake set by the DAO
    error FirstStakeLessThanMinStake();

    /// @notice Trown when amount is zero
    error ZeroAmount();

    /// @notice Thrown when someone try to unstake a stake that doesn't belong
    /// to the keyper in question
    error StakeDoesNotBelongToUser();

    /// @notice Thrown when someone try to unstake a stake that doesn't exist
    error StakeDoesNotExist();

    /// @notice Thrown when someone try to unstake a stake that is still locked
    error StakeIsStillLocked();

    /*//////////////////////////////////////////////////////////////
                                 MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Ensure only keypers can stake
    modifier onlyKeyper() {
        require(keypers[msg.sender], OnlyKeyper());
        _;
    }

    /// @notice Initialize the contract
    /// @param _owner The owner of the contract, i.e. the DAO contract address
    /// @param _stakingToken The address of the staking token, i.e. SHU
    /// @param _rewardsDistributor The address of the rewards distributor
    /// contract
    /// @param _lockPeriod The lock period in seconds
    /// @param _minStake The minimum stake amount
    function initialize(
        address _owner,
        address _stakingToken,
        address _rewardsDistributor,
        uint256 _lockPeriod,
        uint256 _minStake
    ) public initializer {
        __ERC20_init("Staked SHU", "sSHU");

        // Transfer ownership to the DAO contract
        _transferOwnership(_owner);

        stakingToken = IERC20(_stakingToken);
        rewardsDistributor = IRewardsDistributor(_rewardsDistributor);
        lockPeriod = _lockPeriod;
        minStake = _minStake;

        nextStakeId = 1;
    }

    /// @notice Stake SHU
    ///          - first stake must be at least the minimum stake
    ///          - amount will be locked in the contract for the lock period
    ///          - keyper must approve the contract to spend the SHU before staking
    ///          - this function will mint sSHU to the keyper
    ////         - sSHU is non-transferable
    ///          - only keypers can stake
    /// @param amount The amount of SHU to stake
    /// @return stakeId The index of the stake
    function stake(
        uint256 amount
    ) external onlyKeyper updateRewards returns (uint256 stakeId) {
        require(amount > 0, ZeroAmount());

        address user = msg.sender;

        // Get the keyper stakes
        EnumerableSetLib.Uint256Set storage stakesIds = userStakes[user];

        // If the keyper has no stakes, the first stake must be at least the minimum stake
        if (stakesIds.length() == 0) {
            require(amount >= minStake, FirstStakeLessThanMinStake());
        }

        stakeId = nextStakeId++;

        // Add the stake id to the user stakes
        userStakes[user].add(stakeId);

        // Add the stake to the stakes mapping
        stakes[stakeId].amount = amount;
        stakes[stakeId].timestamp = block.timestamp;
        stakes[stakeId].lockPeriod = lockPeriod;

        _deposit(user, amount);

        emit Staked(user, amount, lockPeriod);
    }

    /// @notice Unstake SHU
    ///          - stakeId must be a valid id beloging to the keyper
    ///          - If address keyper is a keyper only the keyper can unstake
    ///          - if keyper address is not a keyper, anyone can unstake
    ///          - Unstake can't never result in a keyper SHU staked < minStake
    ///            if the keyper is still a keyper
    ///          - if the stake lock period is less than the global lock period, the
    ///            block.timestamp must be greater than the stake timestamp +
    ///            lock period
    ///          - if the stake lock period is greater than the global lock
    ///            period, the block.timestamp must be greater than the stake timestamp +
    ///            lock period
    ///          - if address is not a keyper, lock period is ignored
    ///          - if amount is zero, the contract will transfer the stakeId
    ///            total amount
    ///          - if amount is specified, it must be less than the stakeId amount
    ///          - amount must be specified in SHU, not sSHU
    /// @param keyper The keyper address
    /// @param stakeId The stake index
    /// @param _amount The amount
    /// @return amount The amount of SHU unstaked
    function unstake(
        address keyper,
        uint256 stakeId,
        uint256 _amount
    ) external updateRewards returns (uint256 amount) {
        require(
            userStakes[keyper].contains(stakeId),
            StakeDoesNotBelongToUser()
        );
        Stake memory keyperStake = stakes[stakeId];

        require(keyperStake.amount > 0, StakeDoesNotExist());

        amount = _calculateWithdrawAmount(_amount, keyperStake.amount);

        // Checks below only apply if keyper is still a keyper
        // if keyper is not a keyper anymore, anyone can unstake for them, lock period is
        // ignored and minStake is not enforced
        if (keypers[keyper]) {
            // Only the keyper can unstake
            require(msg.sender == keyper, OnlyKeyper());

            // If the lock period is less than the global lock period, the stake
            // must be locked for the lock period
            // If the global lock period is greater than the stake lock period,
            // the stake must be locked for the stake lock period
            uint256 lock = keyperStake.lockPeriod > lockPeriod
                ? lockPeriod
                : keyperStake.lockPeriod;

            require(
                block.timestamp > keyperStake.timestamp + lock,
                StakeIsStillLocked()
            );

            // The unstake can't never result in a keyper SHU staked < minStake
            require(
                _maxWithdraw(keyper, keyperStake.amount) >= amount,
                WithdrawAmountTooHigh()
            );
        } else {
            // doesn't include the min stake and locked staked as the keyper is not a keyper anymore
            require(
                convertToAssets(balanceOf(keyper)) >= amount,
                WithdrawAmountTooHigh()
            );
        }

        // Decrease the amount from the stake
        stakes[stakeId].amount -= amount;

        // If the stake is empty, remove it
        if (stakes[stakeId].amount == 0) {
            // Remove the stake from the stakes mapping
            delete stakes[stakeId];

            // Remove the stake from the keyper stakes
            userStakes[keyper].remove(stakeId);
        }

        uint256 shares = _withdraw(keyper, amount);

        emit Unstaked(keyper, amount, shares);
    }

    /*//////////////////////////////////////////////////////////////
                         RESTRICTED FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /// @notice Set the minimum stake amount
    /// @param _minStake The minimum stake amount
    function setMinStake(uint256 _minStake) external onlyOwner {
        minStake = _minStake;
        emit NewMinStake(_minStake);
    }

    /// @notice Set a keyper
    ///        - if the keyper is not a keyper anymore, the first stake will be
    ///          unstaked
    /// @param keyper The keyper address
    /// @param isKeyper Whether the keyper is a keyper or not
    function setKeyper(address keyper, bool isKeyper) external onlyOwner {
        keypers[keyper] = isKeyper;
        emit KeyperSet(keyper, isKeyper);
    }

    /*//////////////////////////////////////////////////////////////
                                OVERRIDE
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the maximum amount of assets that a keyper can withdraw
    ////         - if the keyper has no shares, the function will revert
    ///          - if the keyper sSHU balance is less or equal than the minimum stake or the total
    ///            locked amount, the function will return 0
    /// @param keyper The keyper address
    /// @return amount The maximum amount of assets that a keyper can withdraw
    function maxWithdraw(
        address keyper
    ) public view override returns (uint256) {
        return _maxWithdraw(keyper, 0);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the maximum amount of assets that a keyper can withdraw
    ///         after unlocking a certain amount
    ///         - if the keyper has no shares, the function will revert
    ///         - if the keyper sSHU balance is less or equal than the minimum
    ///         stake or the total locked amount, the function will return 0
    /// @param keyper The keyper address
    /// @param unlockedAmount The amount of unlocked assets
    /// @return amount The maximum amount of assets that a keyper can withdraw after unlocking a certain amount
    function _maxWithdraw(
        address keyper,
        uint256 unlockedAmount
    ) internal view virtual returns (uint256 amount) {
        uint256 shares = balanceOf(keyper);
        require(shares > 0, UserHasNoShares());

        uint256 assets = convertToAssets(shares);

        uint256 locked = totalLocked[keyper] - unlockedAmount;
        uint256 compare = locked >= minStake ? locked : minStake;

        // need the first branch as convertToAssets rounds down
        amount = compare >= assets ? 0 : assets - compare;
    }
}
