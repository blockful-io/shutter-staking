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
contract StakingV2 is ERC20VotesUpgradeable, Ownable2StepUpgradeable {
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
    IERC20 public immutable STAKING_TOKEN;

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

    /*//////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice the stake struct
    /// @dev timestamp is the time the stake was made
    struct Deposit {
        uint256 amount;
        uint256 timestamp;
        uint256 lockPeriod;
    }

    /*//////////////////////////////////////////////////////////////
                             MAPPINGS/ARRAYS
    //////////////////////////////////////////////////////////////*/

    /// @notice the keyper stakes mapping
    mapping(address keyper => Deposit[]) public deposits;

    /// TODO when remove keyper also unstake the first stake
    /// @notice the keypers mapping
    mapping(address keyper => bool isKeyper) public keypers;

    /// @notice how many SHU a keyper has locked
    mapping(address keyper => uint256 totalLocked) public totalLocked;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Staked(
        address indexed user,
        uint256 indexed amount,
        uint256 lockPeriod
    );
    event Unstaked(address user, uint256 amount);
    event ClaimRewards(address user, uint256 rewards);
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
    modifier updateRewards() {
        // Distribute rewards
        rewardsDistributor.distributeReward(address(stakingToken));

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

        STAKING_TOKEN = IERC20(_stakingToken);
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
    ) external onlyKeyper updateRewards returns (uint256) {
        /////////////////////////// CHECKS ///////////////////////////////
        address keyper = msg.sender;

        // Get the keyper stakes
        Deposit[] storage stakes = deposits[keyper];

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

        uint256 sharesToMint = convertToShares(amount);

        // Mint the shares
        _mint(keyper, sharesToMint);

        /////////////////////////// INTERACTIONS ///////////////////////////

        // Lock the SHU in the contract
        stakingToken.safeTransferFrom(keyper, address(this), amount);

        // Record the new stake
        stakes.push(Stake(amount, block.timestamp, lockPeriod));

        emit Staked(keyper, amount, lockPeriod);

        return stakes.length - 1;
    }

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
    ) external updateRewards {
        /////////////////////////// CHECKS ///////////////////////////////
        require(stakeIndex < deposits[keyper].length, "Invalid stake index");

        // Gets the keyper stake
        Stake storage keyperStake = deposits[keyper][stakeIndex];

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
            maxWithdrawAmount = convertToAssets(balanceOf(keyper));
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
        // Calculates the amounf of shares to burn
        uint256 shares = convertToShares(amount);

        // Burn the shares
        _burn(keyper, shares);

        // Decrease the amount from the stake
        keyperStake.amount -= amount;

        // Decrease the amount from the total locked
        totalLocked[keyper] -= amount;

        // If the stake is empty, remove it
        if (keyperStake.amount == 0) {
            // Remove the stake from the keyper's stake array
            deposits[keyper][stakeIndex] = deposits[keyper][
                deposits[keyper].length - 1
            ];
            deposits[keyper].pop();
        }

        /////////////////////////// INTERACTIONS ///////////////////////////

        // Transfer the SHU to the keyper
        stakingToken.safeTransfer(keyper, amount);

        emit Unstaked(keyper, amount, shares);
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
    /// @param amount The amount of rewards to claim
    function claimReward(
        uint256 amount
    ) external onlyKeyper updateRewards returns (uint256 rewards) {
        address keyper = msg.sender;

        // Prevents the keyper from claiming more than they should
        uint256 maxWithdrawAmount = maxWithdraw(keyper);

        require(maxWithdrawAmount > 0, "No rewards to claim");

        // If the amount is greater than the max withdraw amount, the contract
        // will transfer the maximum amount available not the requested amount
        // If the amount is 0, claim all the rewards
        if (maxWithdrawAmount < amount || amount == 0) {
            rewards = maxWithdrawAmount;
        } else {
            rewards = amount;
        }

        // Calculates the amount of shares to burn
        uint256 shares = convertToShares(amount);

        // If the balance minus the shares is less than the locked in shares
        // the keyper can't claim below the total locked amount
        // TODO I think this is never going to happen
        require(
            balanceOf(keyper) - shares >= convertToShares(totalLocked[keyper]),
            "Keyper can't claim below total locked"
        );

        _burn(keyper, shares);

        rewardToken.safeTransfer(keyper, amount);

        emit ClaimRewards(keyper, address(rewardToken), amount);
    }

    /*//////////////////////////////////////////////////////////////
                         RESTRICTED FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Set the rewards distributor contract
    /// @param _rewardsDistributor The address of the rewards distributor contract
    function setRewardsDistributor(
        IRewardsDistributor _rewardsDistributor
    ) external onlyOwner updateRewards {
        rewardsDistributor = _rewardsDistributor;
    }

    /// @notice Set the lock period
    /// @param _lockPeriod The lock period in seconds
    function setLockPeriod(
        uint256 _lockPeriod
    ) external onlyOwner updateRewards {
        lockPeriod = _lockPeriod;
    }

    /// @notice Set the minimum stake amount
    /// @param _minStake The minimum stake amount
    function setMinStake(uint256 _minStake) external onlyOwner updateRewards {
        minStake = _minStake;
    }

    /// @notice Set a keyper
    /// @param keyper The keyper address
    /// @param isKeyper Whether the keyper is a keyper or not
    function setKeyper(
        address keyper,
        bool isKeyper
    ) external onlyOwner updateRewards {
        keypers[keyper] = isKeyper;

        emit KeyperSet(keyper, isKeyper);
    }

    /// @notice Set multiple keypers
    /// @param _keypers The keyper addresses
    /// @param isKeyper Whether the keypers are keypers or not
    function setKeypers(
        address[] memory _keypers,
        bool isKeyper
    ) external onlyOwner updateRewards {
        for (uint256 i = 0; i < _keypers.length; i++) {
            keypers[_keypers[i]] = isKeyper;

            emit KeyperSet(_keypers[i], isKeyper);
        }
    }

    /// @notice Calculates the maximum amount of assets that a keyper can withdraw,
    ///         factoring in the principal and any un-compounded rewards.
    ///         This function subtracts the minimum required stake and includes any amounts
    ///         currently locked. As a result, the maximum withdrawable amount might be less
    ///         than the total withdrawable at the current block timestamp.
    ///         TODO revisirt natspec
    /// @param keyper The keyper address
    /// @return The maximum amount of assets that a keyper can withdraw
    function maxWithdraw(address keyper) public view virtual returns (uint256) {
        return
            convertToAssets(balanceOf(keyper)) -
            (totalLocked[keyper] >= minStake ? totalLocked[keyper] : minStake);
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
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the total amount of shares the assets are worth
    /// @param assets The amount of assets
    function convertToShares(
        uint256 assets
    ) public view virtual returns (uint256) {
        uint256 supply = totalSupply(); // Saves an extra SLOAD if totalSupply is non-zero.

        return supply == 0 ? assets : assets.mulDivDown(supply, totalAssets());
    }

    /// @notice Get the total amount of assets the shares are worth
    /// @param shares The amount of shares
    /// y = shares * totalAssets() / totalSupply()
    function convertToAssets(
        uint256 shares
    ) public view virtual returns (uint256) {
        uint256 supply = totalSupply(); // Saves an extra SLOAD if totalSupply is non-zero.

        return supply == 0 ? shares : shares.mulDivDown(totalAssets(), supply);
    }

    /// @notice Get the amount of SHU staked for all keypers
    function totalAssets() public view virtual returns (uint256) {
        return stakingToken.balanceOf(address(this));
    }
}
