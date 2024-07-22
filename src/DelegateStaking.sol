// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {OwnableUpgradeable} from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {ERC20VotesUpgradeable} from "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/ERC20VotesUpgradeable.sol";

import {IERC20} from "./interfaces/IERC20.sol";
import {SafeTransferLib} from "./libraries/SafeTransferLib.sol";
import {FixedPointMathLib} from "./libraries/FixedPointMathLib.sol";
import {IRewardsDistributor} from "./interfaces/IRewardsDistributor.sol";

interface IStaking {
    function keypers(address user) external returns (bool);
}

/// @notice Shutter Delegate Staking Contract
///         Allows users to stake SHU and earn rewards in exchange.
contract DelegateStaking is ERC20VotesUpgradeable, OwnableUpgradeable {
    /*//////////////////////////////////////////////////////////////
                               LIBRARIES
    //////////////////////////////////////////////////////////////*/
    using EnumerableSet for EnumerableSet.UintSet;

    using SafeTransferLib for IERC20;

    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                                 VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice the staking token, i.e. SHU
    /// @dev set in initialize, can't be changed
    IERC20 public stakingToken;

    /// @notice the rewards distributor contract
    /// @dev only owner can change
    IRewardsDistributor public rewardsDistributor;

    /// @notice the staking contract
    /// @dev only owner can change
    IStaking public staking;

    /// @notice Unique identifier that will be used for the next stake.
    uint256 internal nextStakeId;

    /// @notice the lock period in seconds
    /// @dev only owner can change
    uint256 public lockPeriod;

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

    // @notice stake ids belonging to a user
    mapping(address user => EnumerableSet.UintSet stakeIds) private userStakes;

    /// @notice how many SHU a user has locked
    mapping(address keyper => uint256 totalLocked) public totalLocked;

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

    /// @notice Emitted when a keyper claims rewards
    event RewardsClaimed(address indexed user, uint256 rewards);

    /// @notice Emitted when the rewards distributor is changed
    event NewRewardsDistributor(address indexed rewardsDistributor);

    /// @notice Emitted when a new staking contract is set
    event NewStakingContract(address indexed stakingContract);

    /// @notice Emitted when the lock period is changed
    event NewLockPeriod(uint256 indexed lockPeriod);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice  Thrown when transfer/tranferFrom is called
    error TransferDisabled();

    /// @notice Thrown when a keyper has no shares
    error UserHasNoShares();

    /// @notice Trown when amount is zero
    error ZeroAmount();

    /// @notice Thrown when someone try to unstake a stake that doesn't belong
    /// to them
    error StakeDoesNotBelongToUser();

    /// @notice Thrown when someone try to unstake a stake that doesn't exist
    error StakeDoesNotExist();

    /// @notice Thrown when someone try to unstake a amount that is greater than
    /// the stake amount belonging to the stake id
    error WithdrawAmountTooHigh();

    /// @notice Thrown when someone try to unstake a stake that is still locked
    error StakeIsStillLocked();

    /// @notice Thrown when a keyper try to claim rewards but has no rewards to
    /// claim
    error NoRewardsToClaim();

    /// @notice Thrown when the argument is the zero address
    error AddressZero();

    /*//////////////////////////////////////////////////////////////
                                 MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Update rewards for a keyper
    modifier updateRewards() {
        // Distribute rewards
        rewardsDistributor.collectRewards();

        _;
    }

    /// @notice Ensure logic contract is unusable
    constructor() {
        _disableInitializers();
    }

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
    ///          - this function will mint sdSHU to the keyper
    ////         - dSHU is non-transferable
    /// @param amount The amount of SHU to stake
    /// @return stakeId The index of the stake
    function stake(
        address keyper,
        uint256 amount
    ) external updateRewards returns (uint256 stakeId) {
        require(amount > 0, ZeroAmount());

        address user = msg.sender;

        // Update the keyper's SHU balance
        totalLocked[user] += amount;

        // Mint the shares
        _mint(user, convertToShares(amount));

        // Get next stake id and increment it
        stakeId = nextStakeId++;

        // Add the stake to the stakes mapping
        stakes[stakeId].keyper = keyper;
        stakes[stakeId].amount = amount;
        stakes[stakeId].timestamp = block.timestamp;
        stakes[stakeId].lockPeriod = lockPeriod;

        // Add the stake to the keyper stakes
        userStakes[user].add(stakeId);

        // Lock the SHU in the contract
        stakingToken.safeTransferFrom(user, address(this), amount);

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
    ) external returns (uint256 amount) {
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

        // Calculates the amounf of shares to burn
        uint256 shares = previewWithdraw(amount);

        // Burn the shares
        _burn(user, shares);

        // Decrease the amount from the stake
        stakes[stakeId].amount -= amount;

        // Decrease the amount from the total locked
        totalLocked[user] -= amount;

        // If the stake is empty, remove it
        if (stakes[stakeId].amount == 0) {
            // Remove the stake from the stakes mapping
            delete stakes[stakeId];

            // Remove the stake from the user stakes
            userStakes[user].remove(stakeId);
        }

        // Transfer the SHU to the keyper
        stakingToken.safeTransfer(user, amount);

        emit Unstaked(user, amount, shares);
    }

    /// @notice Claim rewards
    ///         - If no amount is specified, will claim all the rewards
    ///         - If the amount is specified, the amount must be less than the
    ///           maximum withdrawable amount. The maximum withdrawable amount
    ///           is the total amount of assets the user has minus the
    ///           total locked amount
    ///         - If the claim results in a balance less than the total locked
    ///            amount, the claim will be rejected
    ///         - The keyper can claim the rewards at any time as longs there is
    ///           a reward to claim
    /// @param amount The amount of rewards to claim
    function claimRewards(
        uint256 amount
    ) external updateRewards returns (uint256 rewards) {
        address user = msg.sender;

        // Prevents the keyper from claiming more than they should
        uint256 maxWithdrawAmount = maxWithdraw(user);

        rewards = _calculateWithdrawAmount(amount, maxWithdrawAmount);

        require(rewards > 0, NoRewardsToClaim());

        // Calculates the amount of shares to burn
        uint256 shares = previewWithdraw(rewards);

        _burn(user, shares);

        stakingToken.safeTransfer(user, rewards);

        emit RewardsClaimed(user, rewards);
    }

    /*//////////////////////////////////////////////////////////////
                         RESTRICTED FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Set the rewards distributor contract
    /// @param _rewardsDistributor The address of the rewards distributor contract
    function setRewardsDistributor(
        address _rewardsDistributor
    ) external onlyOwner {
        require(_rewardsDistributor != address(0), AddressZero());
        rewardsDistributor = IRewardsDistributor(_rewardsDistributor);

        emit NewRewardsDistributor(_rewardsDistributor);
    }

    function setStakingContract(address _stakingContract) external onlyOwner {
        require(_stakingContract != address(0), AddressZero());
        staking = IStaking(_stakingContract);

        emit NewStakingContract(_stakingContract);
    }

    /// @notice Set the lock period
    /// @param _lockPeriod The lock period in seconds
    function setLockPeriod(uint256 _lockPeriod) external onlyOwner {
        lockPeriod = _lockPeriod;

        emit NewLockPeriod(_lockPeriod);
    }

    /*//////////////////////////////////////////////////////////////
                              TRANSFER LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Transfer is disabled
    function transfer(address, uint256) public pure override returns (bool) {
        revert TransferDisabled();
    }

    /// @notice Transfer is disabled
    function transferFrom(
        address,
        address,
        uint256
    ) public pure override returns (bool) {
        revert TransferDisabled();
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the stake ids belonging to a user
    function getUserStakeIds(
        address keyper
    ) external view returns (uint256[] memory) {
        return userStakes[keyper].values();
    }

    function previewWithdraw(
        uint256 assets
    ) public view virtual returns (uint256) {
        // sum + 1 on both sides to prevent donation attack
        return assets.mulDivUp(totalSupply() + 1, _totalAssets() + 1);
    }

    /// @notice Get the total amount of shares the assets are worth
    /// @param assets The amount of assets
    function convertToShares(
        uint256 assets
    ) public view virtual returns (uint256) {
        // sum + 1 on both sides to prevent donation attack
        return assets.mulDivDown(totalSupply() + 1, _totalAssets() + 1);
    }

    /// @notice Get the total amount of assets the shares are worth
    /// @param shares The amount of shares
    function convertToAssets(
        uint256 shares
    ) public view virtual returns (uint256) {
        // sum + 1 on both sides to prevent donation attack
        return shares.mulDivDown(_totalAssets() + 1, totalSupply() + 1);
    }

    /// @notice Get the maximum amount of assets that a keyper can withdraw
    ////         - if the user has no shares, the function will revert
    ///          - if the user dSHU balance is less or equal than the total
    ///            locked amount, the function will return 0
    /// @param user The user address
    /// @return amount The maximum amount of assets that a user can withdraw
    function maxWithdraw(
        address user
    ) public view virtual returns (uint256 amount) {
        uint256 shares = balanceOf(user);
        require(shares > 0, UserHasNoShares());

        uint256 assets = convertToAssets(shares);
        uint256 locked = totalLocked[user];

        // need the first branch as convertToAssets rounds down
        amount = locked >= assets ? 0 : assets - locked;
    }

    /// @notice Get the amount of SHU staked for all keypers
    function _totalAssets() internal view virtual returns (uint256) {
        return stakingToken.balanceOf(address(this));
    }

    /// @notice Calculates the amount to withdraw
    /// @param _amount The amount to withdraw
    /// @param maxWithdrawAmount The maximum amount that can be withdrawn
    function _calculateWithdrawAmount(
        uint256 _amount,
        uint256 maxWithdrawAmount
    ) internal pure returns (uint256 amount) {
        // If the amount is 0, withdraw all available amount
        if (_amount == 0) {
            amount = maxWithdrawAmount;
        } else {
            require(_amount <= maxWithdrawAmount, WithdrawAmountTooHigh());
            amount = _amount;
        }
    }
}
