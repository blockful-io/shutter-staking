// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {OwnableUpgradeable} from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {ERC20VotesUpgradeable} from "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/ERC20VotesUpgradeable.sol";

import {IERC20} from "./interfaces/IERC20.sol";
import {SafeTransferLib} from "./libraries/SafeTransferLib.sol";
import {FixedPointMathLib} from "./libraries/FixedPointMathLib.sol";
import {IRewardsDistributor} from "./interfaces/IRewardsDistributor.sol";

/// @notice Shutter Staking Contract
///         Allows keypers to stake SHU for a lock period and earn rewards in exchange
contract Staking is ERC20VotesUpgradeable, OwnableUpgradeable {
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

    /// @notice the lock period in seconds
    /// @dev only owner can change
    uint256 public lockPeriod;

    /// @notice the minimum stake amount
    /// @dev only owner can change
    uint256 public minStake;

    /// @notice Unique identifier that will be used for the next stake.
    uint256 internal nextStakeId;

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

    // @notice stake ids belonging to a keyper
    mapping(address keyper => EnumerableSet.UintSet stakeIds)
        private keyperStakes;

    /// @notice keypers mapping
    mapping(address keyper => bool isKeyper) public keypers;

    /// @notice how many SHU a keyper has locked
    mapping(address keyper => uint256 totalLocked) public totalLocked;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a keyper stakes SHU
    event Staked(address indexed user, uint256 amount, uint256 lockPeriod);

    /// @notice Emitted when a keyper unstakes SHU
    event Unstaked(address indexed user, uint256 amount, uint256 shares);

    /// @notice Emitted when a keyper claims rewards
    event RewardsClaimed(address indexed user, uint256 rewards);

    /// @notice Emitted when a keyper is added or removed
    event KeyperSet(address indexed keyper, bool isKeyper);

    /// @notice Emitted when the lock period is changed
    event NewLockPeriod(uint256 indexed lockPeriod);

    /// @notice Emitted when the minimum stake is changed
    event NewMinStake(uint256 indexed minStake);

    /// @notice Emitted when the rewards distributor is changed
    event NewRewardsDistributor(address indexed rewardsDistributor);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a non-keyper attempts a call for which only keypers are allowed
    error OnlyKeyper();

    /// @notice  Thrown when transfer/tranferFrom is called
    error TransferDisabled();

    /// @notice Thrown when a keyper has no shares
    error UserHasNoShares();

    /// @notice Thrown when a keyper has staking for the first time and the
    /// amount is less than the minimum stake set by the DAO
    error FirstStakeLessThanMinStake();

    /// @notice Trown when amount is zero
    error ZeroAmount();

    /// @notice Thrown when someone try to unstake a stake that doesn't belong
    /// to the keyper in question
    error StakeDoesNotBelongToKeyper();

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

    /// @notice Ensure only keypers can stake
    modifier onlyKeyper() {
        require(keypers[msg.sender], OnlyKeyper());
        _;
    }

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

        address keyper = msg.sender;

        // Get the keyper stakes
        EnumerableSet.UintSet storage stakesIds = keyperStakes[keyper];

        // If the keyper has no stakes, the first stake must be at least the minimum stake
        if (stakesIds.length() == 0) {
            require(amount >= minStake, FirstStakeLessThanMinStake());
        }

        // Update the keyper's SHU balance
        totalLocked[keyper] += amount;

        // Mint the shares
        _mint(keyper, convertToShares(amount));

        // Get next stake id and increment it
        stakeId = nextStakeId++;

        // Add the stake to the stakes mapping
        stakes[stakeId].amount = amount;
        stakes[stakeId].timestamp = block.timestamp;
        stakes[stakeId].lockPeriod = lockPeriod;

        // Add the stake to the keyper stakes
        stakesIds.add(stakeId);

        // Lock the SHU in the contract
        stakingToken.safeTransferFrom(keyper, address(this), amount);

        emit Staked(keyper, amount, lockPeriod);
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
    ) external returns (uint256 amount) {
        require(
            keyperStakes[keyper].contains(stakeId),
            StakeDoesNotBelongToKeyper()
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

        // Calculates the amounf of shares to burn
        uint256 shares = previewWithdraw(amount);

        // Burn the shares
        _burn(keyper, shares);

        // Decrease the amount from the stake
        stakes[stakeId].amount -= amount;

        // Decrease the amount from the total locked
        totalLocked[keyper] -= amount;

        // If the stake is empty, remove it
        if (stakes[stakeId].amount == 0) {
            // Remove the stake from the stakes mapping
            delete stakes[stakeId];

            // Remove the stake from the keyper stakes
            keyperStakes[keyper].remove(stakeId);
        }

        // Transfer the SHU to the keyper
        stakingToken.safeTransfer(keyper, amount);

        emit Unstaked(keyper, amount, shares);
    }

    /// @notice Claim rewards
    ///         - If no amount is specified, will claim all the rewards
    ///         - If the amount is specified, the amount must be less than the
    ///           maximum withdrawable amount. The maximum withdrawable amount
    ///           is the total amount of assets the keyper has minus either the
    ///           total locked amount or the minimum stake, whichever is greater
    ///         - If the claim results in a balance less than the total locked
    ///            amount, the claim will be rejected
    ///         - The keyper can claim the rewards at any time as longs there is
    ///           a reward to claim
    /// @param amount The amount of rewards to claim
    function claimRewards(
        uint256 amount
    ) external updateRewards returns (uint256 rewards) {
        address keyper = msg.sender;

        // Prevents the keyper from claiming more than they should
        uint256 maxWithdrawAmount = maxWithdraw(keyper);

        rewards = _calculateWithdrawAmount(amount, maxWithdrawAmount);

        require(rewards > 0, NoRewardsToClaim());

        // Calculates the amount of shares to burn
        uint256 shares = previewWithdraw(rewards);

        _burn(keyper, shares);

        stakingToken.safeTransfer(keyper, rewards);

        emit RewardsClaimed(keyper, rewards);
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

    /// @notice Set the lock period
    /// @param _lockPeriod The lock period in seconds
    function setLockPeriod(uint256 _lockPeriod) external onlyOwner {
        lockPeriod = _lockPeriod;

        emit NewLockPeriod(_lockPeriod);
    }

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

    /// @notice Get the stake ids belonging to a keyper
    function getKeyperStakeIds(
        address keyper
    ) external view returns (uint256[] memory) {
        return keyperStakes[keyper].values();
    }

    function previewWithdraw(
        uint256 assets
    ) public view virtual returns (uint256) {
        uint256 supply = totalSupply(); // Saves an extra SLOAD if totalSupply is non-zero.

        return supply == 0 ? assets : assets.mulDivUp(supply, _totalAssets());
    }

    /// @notice Get the total amount of shares the assets are worth
    /// @param assets The amount of assets
    function convertToShares(
        uint256 assets
    ) public view virtual returns (uint256) {
        uint256 supply = totalSupply(); // Saves an extra SLOAD if totalSupply is non-zero.

        return supply == 0 ? assets : assets.mulDivDown(supply, _totalAssets());
    }

    /// @notice Get the total amount of assets the shares are worth
    /// @param shares The amount of shares
    function convertToAssets(
        uint256 shares
    ) public view virtual returns (uint256) {
        uint256 supply = totalSupply(); // Saves an extra SLOAD if totalSupply is non-zero.

        return supply == 0 ? shares : shares.mulDivDown(_totalAssets(), supply);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the maximum amount of assets that a keyper can withdraw
    ////         - if the keyper has no shares, the function will revert
    ///          - if the keyper sSHU balance is less or equal than the minimum stake or the total
    ///            locked amount, the function will return 0
    /// @param keyper The keyper address
    /// @return amount The maximum amount of assets that a keyper can withdraw
    function maxWithdraw(address keyper) public view virtual returns (uint256) {
        return _maxWithdraw(keyper, 0);
    }

    /// @notice Get the maximum amount of assets that a keyper can withdraw
    ///         after unlocking a certain amount
    ///         - if the keyper has no shares, the function will revert
    ///         - if the keyper sSHU balance is less or equal than the minimum
    ///         stake or the total locked amount, the function will return 0
    /// @param keyper The keyper address
    /// @param unlockedAmount The amount of assets to unlock
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

    /// @notice Get the amount of SHU staked for all keypers
    function _totalAssets() internal view virtual returns (uint256) {
        return stakingToken.balanceOf(address(this));
    }

    function _unstake(
        address keyper,
        uint256 stakeId,
        uint256 amount
    ) internal {}

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
