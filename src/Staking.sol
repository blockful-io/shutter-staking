// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {console} from "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import {ERC20VotesUpgradeable} from "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {SafeTransferLib} from "@solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "@solmate/utils/FixedPointMathLib.sol";
import {IRewardsDistributor} from "./interfaces/IRewardsDistributor.sol";

// TODO should be pausable?
// TODO is this vulnerable to first deposit attack?
// TODO check calculations
contract Staking is ERC20VotesUpgradeable, Ownable2StepUpgradeable {
    /*//////////////////////////////////////////////////////////////
                               LIBRARIES
    //////////////////////////////////////////////////////////////*/
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice the staking token, i.e. SHU
    /// @dev set in initialize, can't be changed
    IERC20 public stakingToken;

    /*//////////////////////////////////////////////////////////////
                                 VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice the rewards distributor contract
    /// @dev only owner can change
    IRewardsDistributor public rewardsDistributor;

    /// @notice the lock period in seconds
    /// @dev only owner can change
    uint256 public lockPeriod;

    /// @notice the minimum stake amount
    /// @dev only owner can change
    uint256 public minStake;

    /// @notice the last time the contract was updated
    uint256 updatedAt;

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

    struct Reward {
        uint256 earned;
        uint256 userRewardPerTokenPaid;
    }

    /*//////////////////////////////////////////////////////////////
                             MAPPINGS/ARRAYS
    //////////////////////////////////////////////////////////////*/

    /// @notice the keyper stakes mapping
    mapping(address keyper => Stake[]) public keyperStakes;

    /// TODO when remove keyper also unstake the first stake
    /// @notice the keypers mapping
    mapping(address keyper => bool isKeyper) public keypers;

    /// @notice how many SHU a keyper has locked
    mapping(address keyper => uint256 totalLocked) public totalLocked;

    mapping(address token => uint256 rewardPerTokenStored)
        public rewardPerTokenStored;

    mapping(address keyper => mapping(address token => Reward keyperRewards))
        public keyperRewards;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Staked(
        address indexed user,
        uint256 indexed amount,
        uint256 lockPeriod
    );
    event Unstaked(address user, uint256 amount);
    event ClaimRewards(address user, address rewardToken, uint256 rewards);
    event KeyperSet(address keyper, bool isKeyper);

    /*//////////////////////////////////////////////////////////////
                                 MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Ensure only keypers can stake
    modifier onlyKeyper() {
        require(keypers[msg.sender], "Only keypers can stake");
        _;
    }

    /// @notice Update rewards for a keyper
    /// @param caller The keyper address
    modifier updateRewards(address caller) {
        // Distribute rewards
        rewardsDistributor.distributeRewards();

        address[] memory rewardTokens = rewardsDistributor.getRewardTokens(
            address(this)
        );

        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address token = rewardTokens[i];

            uint256 _rewardPerToken = rewardPerToken(token);
            rewardPerTokenStored[token] = _rewardPerToken;

            console.log(
                "after rewardPerTokenStored[token]",
                rewardPerTokenStored[token]
            );

            if (caller != address(0)) {
                console.log("caller balance before earn", balanceOf(caller));
                uint256 earned = (balanceOf(caller) *
                    (_rewardPerToken -
                        keyperRewards[caller][token].userRewardPerTokenPaid)) /
                    1e18;

                console.log("earned", earned);

                keyperRewards[caller][token].earned += earned;
                keyperRewards[caller][token]
                    .userRewardPerTokenPaid = _rewardPerToken;

                // compound
                if (token == address(stakingToken)) {
                    uint256 reward = keyperRewards[caller][token].earned;

                    if (reward > 0) {
                        keyperRewards[caller][token].earned = 0;
                        _mint(caller, reward);
                    }
                }
            }
        }

        updatedAt = block.timestamp;

        _;
    }

    /// @notice Ensure logic contract is unusable
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the contract
    /// @param newOwner The owner of the contract, i.e. the DAO contract address
    /// @param _stakingToken The address of the staking token, i.e. SHU
    /// @param _rewardsDistributor The address of the rewards distributor
    /// contract
    /// @param _lockPeriod The lock period in seconds
    /// @param _minStake The minimum stake amount
    function initialize(
        address newOwner,
        address _stakingToken,
        address _rewardsDistributor,
        uint256 _lockPeriod,
        uint256 _minStake
    ) public initializer {
        // Does nothing but calls anyway for consistency
        __ERC20Votes_init();
        __Ownable2Step_init();

        // Transfer ownership to the DAO contract
        _transferOwnership(newOwner);

        stakingToken = IERC20(_stakingToken);
        rewardsDistributor = IRewardsDistributor(_rewardsDistributor);
        lockPeriod = _lockPeriod;
        minStake = _minStake;
    }

    /// @notice Stake SHU
    ///          - The first stake must be at least the minimum stake
    ///          - The SHU will be locked in the contract for the lock period
    ///          - The keyper must approve the contract to spend the SHU before staking
    ///          - The shares are non-transferable
    ///          - Only keypers can stake
    /// @param amount The amount of SHU to stake
    /// @return The index of the stake
    /// TODO check for reentrancy
    function stake(
        uint256 amount
    ) external onlyKeyper updateRewards(msg.sender) returns (uint256) {
        /////////////////////////// CHECKS ///////////////////////////////

        address keyper = msg.sender;

        // Get the keyper stakes
        Stake[] storage stakes = keyperStakes[keyper];

        // If the keyper has no stakes, the first stake must be at least the minimum stake
        if (stakes.length == 0) {
            require(
                amount >= minStake,
                "The first stake must be at least the minimum stake"
            );
        }

        /////////////////////////// EFFECTS ///////////////////////////////

        // Update the keyper's SHU balance
        totalLocked[keyper] += amount;

        // Mint the shares
        _mint(keyper, amount);

        /////////////////////////// INTERACTIONS ///////////////////////////

        // Lock the SHU in the contract
        stakingToken.safeTransferFrom(keyper, address(this), amount);

        // Record the new stake
        stakes.push(Stake(amount, block.timestamp, lockPeriod));

        emit Staked(keyper, amount, lockPeriod);

        return stakes.length - 1;
    }

    // TODO function unstakeAll();
    // TODO function claimRewardsAndUnstake();

    /// @notice Unstake SHU
    ///          - If caller is a keyper only them can unstake
    ///          - If caller is not a keyper anymore, anyone can unstake
    ///          - If caller is not a keyepr anymore, lock period is ignored
    ///          - Unstake can't never result in a user SHU balance < minStake
    ///            if user is a keyper
    ///          - If amount is greater than the keyper stake, the contract will
    ///            transfer the maximum amount available not the requested amount
    ///          - If the lock period is less than the global lock period, the
    ///            stake must be locked for the lock period specified in the stake
    ///          - If the global lock period is greater than the stake lock
    ///            period, the stake must be locked for the stake lock period
    ///          - If amount is greater than the stake amount belonging to the
    ///            stake index, the contract will transfer the maximum amount available
    ///          - amount must be specified in SHU, not shares
    /// @param keyper The keyper address
    /// @param stakeIndex The index of the stake to unstake
    /// @param amount The amount
    /// TODO check for reentrancy
    /// TODO unstake only principal
    function unstake(
        address keyper,
        uint256 stakeIndex,
        uint256 amount
    ) external updateRewards(msg.sender) {
        /////////////////////////// CHECKS ///////////////////////////////
        require(
            stakeIndex < keyperStakes[keyper].length,
            "Invalid stake index"
        );

        // Gets the keyper stake
        Stake storage keyperStake = keyperStakes[keyper][stakeIndex];

        uint256 maxWithdrawAmount;

        // Checks below only apply if keyper is still a keyper
        // if keyper is not a keyper anymore, anyone can unstake, lock period is
        // ignored and minStake is not enforced
        if (keypers[keyper]) {
            require(msg.sender == keyper, "Only keyper can unstake");

            // If the lock period is less than the global lock period, the stake
            // must be locked for the lock period
            if (lockPeriod < keyperStake.lockPeriod) {
                require(
                    keyperStake.timestamp + lockPeriod <= block.timestamp,
                    "Stake is still locked"
                );
            } else {
                // If the global lock period is greater than the stake lock period,
                // the stake must be locked for the stake lock period
                require(
                    keyperStake.timestamp + keyperStake.lockPeriod <=
                        block.timestamp,
                    "Stake is still locked"
                );
            }

            maxWithdrawAmount = maxWithdraw(keyper, keyperStake.amount);
        } else {
            // doesn't exclude the min stake and locked staked as the keyper is not a keyper anymore
            maxWithdrawAmount = balanceOf(keyper);
        }

        require(maxWithdrawAmount > 0, "Keyper has no stake");

        // If the amount is still greater than the stake amount for the specified stake index
        // the contract will transfer the stake amount not the requested amount
        if (amount > keyperStake.amount) {
            amount = keyperStake.amount;
        }

        // If the amount is greater than the max withdraw amount, the contract
        // will transfer the maximum amount available not the requested amount
        // TODO I think this is never going to happen
        if (amount > maxWithdrawAmount) {
            amount = maxWithdrawAmount;
        }

        /////////////////////////// EFFECTS ///////////////////////////////

        // Burn the shares
        _burn(keyper, amount);

        // Decrease the amount from the stake
        keyperStake.amount -= amount;

        // Decrease the amount from the total locked
        totalLocked[keyper] -= amount;

        // If the stake is empty, remove it
        if (keyperStake.amount == 0) {
            // Remove the stake from the keyper's stake array
            keyperStakes[keyper][stakeIndex] = keyperStakes[keyper][
                keyperStakes[keyper].length - 1
            ];
            keyperStakes[keyper].pop();
        }

        /////////////////////////// INTERACTIONS ///////////////////////////

        // Transfer the SHU to the keyper
        stakingToken.safeTransfer(keyper, amount);

        emit Unstaked(keyper, amount);
    }

    /// @notice Claim reward for a specific reward token
    ///         - If the specified amount is greater than the claimable rewards,
    ///           the contract will transfer the maximum amount available not the requested amount
    ///         - If the specified amount is 0 claim all the rewards
    ///         - If the claim results in a balance less than the total locked
    ///            amount, the claim will be rejected
    ///         - The keyper can claim the rewards at any time but not the principal
    ///         - The principal must be unstake by the unstake function and the
    ///           lock period for the principal must be respected
    ///
    /// @param rewardToken The address of the reward token
    /// @param amount The amount of rewards to claim
    function claimReward(
        IERC20 rewardToken,
        uint256 amount
    ) external onlyKeyper updateRewards(msg.sender) {
        require(address(rewardToken) != address(0), "No native token rewards");

        address keyper = msg.sender;

        // If the reward token is the staking token, the user is claimingthe staking rewards
        if (rewardToken == stakingToken) {
            // Prevents the keyper from claiming more than they should
            uint256 maxWithdrawAmount = maxWithdraw(keyper);

            require(maxWithdrawAmount > 0, "No rewards to claim");

            console.log("maxWithdrawAmount", maxWithdrawAmount);

            // If the amount is greater than the max withdraw amount, the contract
            // will transfer the maximum amount available not the requested amount
            // If the amount is 0, claim all the rewards
            if (maxWithdrawAmount < amount || amount == 0) {
                amount = maxWithdrawAmount;
            }

            // If the balance minus the shares is less than the locked in shares
            // the keyper can't claim below the total locked amount
            // TODO I think this is never going to happen
            require(
                balanceOf(keyper) - amount >= totalLocked[keyper],
                "Keyper can't claim below total locked"
            );

            // Burn the shares
            _burn(keyper, amount);

            // Transfer the SHU to the keyper
            rewardToken.safeTransfer(keyper, amount);
        }

        emit ClaimRewards(keyper, address(rewardToken), amount);
    }

    function compound(address keyper) external updateRewards(keyper) {}

    /*//////////////////////////////////////////////////////////////
                         RESTRICTED FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Set the rewards distributor contract
    /// @param _rewardsDistributor The address of the rewards distributor contract
    function setRewardsDistributor(
        IRewardsDistributor _rewardsDistributor
    ) external onlyOwner updateRewards(address(0)) {
        rewardsDistributor = _rewardsDistributor;
    }

    /// @notice Set the lock period
    /// @param _lockPeriod The lock period in seconds
    function setLockPeriod(
        uint256 _lockPeriod
    ) external onlyOwner updateRewards(address(0)) {
        lockPeriod = _lockPeriod;
    }

    /// @notice Set the minimum stake amount
    /// @param _minStake The minimum stake amount
    function setMinStake(
        uint256 _minStake
    ) external onlyOwner updateRewards(address(0)) {
        minStake = _minStake;
    }

    /// @notice Set a keyper
    /// @param keyper The keyper address
    /// @param isKeyper Whether the keyper is a keyper or not
    function setKeyper(
        address keyper,
        bool isKeyper
    ) external onlyOwner updateRewards(address(0)) {
        keypers[keyper] = isKeyper;

        emit KeyperSet(keyper, isKeyper);
    }

    /// @notice Set multiple keypers
    /// @param _keypers The keyper addresses
    /// @param isKeyper Whether the keypers are keypers or not
    function setKeypers(
        address[] memory _keypers,
        bool isKeyper
    ) external onlyOwner updateRewards(address(0)) {
        for (uint256 i = 0; i < _keypers.length; i++) {
            keypers[_keypers[i]] = isKeyper;

            emit KeyperSet(_keypers[i], isKeyper);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS 
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculates the maximum amount of assets that a keyper can withdraw,
    ///         factoring in the principal and any un-compounded rewards.
    ///         This function subtracts the minimum required stake and includes any amounts
    ///         currently locked. As a result, the maximum withdrawable amount might be less
    ///         than the total withdrawable at the current block timestamp.
    ///         TODO revisirt natspec
    /// @param keyper The keyper address
    /// @return The maximum amount of assets that a keyper can withdraw
    function maxWithdraw(address keyper) public view virtual returns (uint256) {
        console.log("maxWithdraw: keyper balance", balanceOf(keyper));
        console.log("maxWithdraw: total locked", totalLocked[keyper]);
        console.log("maxWithdraw: min stake", minStake);

        return
            balanceOf(keyper) -
            (totalLocked[keyper] >= minStake ? totalLocked[keyper] : minStake);
    }

    function maxWithdraw(
        address keyper,
        uint256 unlockedAmount
    ) public view virtual returns (uint256) {
        return
            balanceOf(keyper) -
            (
                (totalLocked[keyper] - unlockedAmount) >= minStake
                    ? minStake
                    : totalLocked[keyper]
            );
    }

    /*//////////////////////////////////////////////////////////////
                              TRANSFER LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Transfer is disabled
    function transfer(address, uint256) public pure override returns (bool) {
        revert("Transfer is disabled");
    }

    /// @notice Transfer is disabled
    function transferFrom(
        address,
        address,
        uint256
    ) public pure override returns (bool) {
        revert("Transfer is disabled");
    }

    /*//////////////////////////////////////////////////////////////
                              PRIVATE
    //////////////////////////////////////////////////////////////*/

    function rewardPerToken(address token) private view returns (uint256) {
        uint256 supply = totalSupply(); // Saves an extra SLOAD if totalSupply is non-zero.

        if (supply == 0) {
            return rewardPerTokenStored[token];
        }

        (uint256 rewardRate, ) = rewardsDistributor.rewardConfigurations(
            address(this),
            token
        );
        console.log("reward rate", rewardRate);
        console.log("rewardPerTokenStored[token]", rewardPerTokenStored[token]);
        console.log("block.timestamp", block.timestamp);
        console.log("updatedAt", updatedAt);
        console.log("supply", supply / 1e18);

        return
            rewardPerTokenStored[token] +
            (rewardRate * (block.timestamp - updatedAt) * 1e18) /
            supply;
    }
}
