// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";

interface IRewardsDistributor {
    function distributeRewards() external;
}

contract Staking is Ownable2StepUpgradeable {
    //// ------------------------------------------------------------
    //// ------------------------------------------------------------
    //// ----------------- Imutable Variables -----------------------
    //// ------------------------------------------------------------
    //// ------------------------------------------------------------

    /// @notice the staking token, i.e. SHU
    /// @dev set in initialize, can't be changed
    IERC20 public shu;

    //// ------------------------------------------------------------
    //// ------------------------------------------------------------
    //// ------------------ Mutable Variables -----------------------
    //// ------------------------------------------------------------
    //// ------------------------------------------------------------

    /// @notice the rewards distributor contract
    /// @dev only owner can change
    IRewardsDistributor public rewardsDistributor;

    /// @notice the total amount of shares
    /// @dev increases when users stake and decreases when users unstake
    uint256 public totalSupply;

    /// @notice the lock period in seconds
    /// @dev only owner can change
    uint256 public lockPeriod;

    /// @notice the minimum stake amount
    /// @dev only owner can change
    uint256 public minStake;

    //// ------------------------------------------------------------
    //// ------------------------------------------------------------
    //// ----------------------- Structs ----------------------------
    //// ------------------------------------------------------------
    //// ------------------------------------------------------------

    /// @notice the stake struct
    /// @dev timestamp is the time the stake was made
    struct Stake {
        uint256 amount;
        uint256 shares;
        uint256 timestamp;
        uint256 lockPeriod;
    }

    //// ------------------------------------------------------------
    //// ------------------------------------------------------------
    //// ------------------ Mappings/Arrays -------------------------
    //// ------------------------------------------------------------
    //// ------------------------------------------------------------

    /// @notice the keyper stakes mapping
    mapping(address keyper => Stake[]) public keyperStakes;

    /// @notice how many SHU a keyper has staked
    mapping(address keyper => uint256) public shuBalances;

    /// TODO when remove keyper also unstake the first stake
    mapping(address keyper => bool isKeyper) public keypers;

    address[] public rewardTokenList;

    //// ------------------------------------------------------------
    //// ------------------------------------------------------------
    //// ------------------------ Events ----------------------------
    //// ------------------------------------------------------------

    event Staked(
        address indexed user,
        uint256 indexed amount,
        uint256 indexed shares,
        uint256 lockPeriod
    );
    event Unstaked(address user, uint256 amount, uint256 shares);
    event ClaimRewards(address user, address rewardToken, uint256 rewards);

    /// --------------------------------------------------------
    /// --------------------------------------------------------
    /// ---------------------- Modifiers -----------------------
    /// --------------------------------------------------------
    /// --------------------------------------------------------

    modifier onlyKeyper() {
        require(isKeyper[msg.sender], "Only keypers can stake");
        _;
    }

    /// @notice ensure logic contract is unusable
    constructor() {
        _disableInitializers();
    }

    /// --------------------------------------------------------
    /// --------------------------------------------------------
    /// ---------------------- Initialize ----------------------
    /// --------------------------------------------------------
    /// --------------------------------------------------------

    /// @notice Initialize the contract
    /// @param newOwner The owner of the contract, i.e. the DAO contract address
    /// @param stakingToken The address of the staking token, i.e. SHU
    /// @param _rewardsDistributor The address of the rewards distributor
    /// contract
    /// @param _lockPeriod The lock period in seconds
    /// @param _minStake The minimum stake amount
    function initialize(
        address newOwner,
        address stakingToken,
        address _rewardsDistributor,
        uint256 _lockPeriod,
        uint256 _minStake
    ) public initializer {
        transferOwnership(newOwner);
        shu = IERC20(stakingToken);
        rewardsDistributor = IRewardsDistributor(_rewardsDistributor);
        lockPeriod = _lockPeriod;
        minStake = _minStake;
    }

    /// @notice Add a reward token
    /// @dev Only the rewards distributor can add reward tokens
    /// @param rewardToken The address of the reward token
    function addRewardToken(address rewardToken) external {
        require(
            msg.sender == address(rewardsDistributor),
            "Only rewards distributor can add reward tokens"
        );

        rewardTokenList.push(rewardToken);
    }

    /// @notice Stake SHU
    ///          - The first stake must be at least the minimum stake
    ///          - The SHU will be locked in the contract for the lock period
    ///          - The keyper must approve the contract to spend the SHU before staking
    ///          - The shares are non-transferable
    ///          - Only keypers can stake
    /// @param amount The amount of SHU to stake
    /// @return sharesToMint The amount of shares minted
    function stake(uint256 amount) external onlyKeyper {
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

        // Before doing anything, get the unclaimed rewards first
        rewardsDistributor.distributeRewards();

        // Gets the amount of staking token in the contract
        uint256 totalShu = shu.balanceOf(address(this));

        if (totalSupply == 0 || totalShu == 0) {
            // If no shares exist, mint it 1:1 to the amount put in
            sharesToMint = amount;
        } else {
            // Calculate and mint the amount of shares the SHU is worth. The ratio will change over time, as shares are burned/minted and SHU distributed to this contract
            sharesToMint = (amount * totalSupply) / totalShu;
        }

        // Update the keyper's SHU balance
        shuBalances[keyper] += amount;

        // Mint the shares
        _mint(keyper, sharesToMint);

        // Lock the SHU in the contract
        shu.transferFrom(keyper, address(this), amount);

        // Record the new stake
        stakes.push(Stake(amount, sharesToMint, block.timestamp, lockPeriod));

        emit Staked(keyper, amount, sharesToMint, lockPeriod);
    }

    //function unstakeAll();
    // function claimRewardsAndUnstake();

    /// @notice Unstake SHU
    ///          - If caller is a keyper only them can unstake
    ///          - If caller is not a keyper anymore, anyone can unstake
    ///          - If caller is not a keyepr anymore, lock period is ignored
    ///          - Unstake can't never result in a user SHU balance < minStake
    ///            if user is a keyper
    /// @param keyper The keyper address
    /// @param stakeIndex The index of the stake to unstake
    /// @param amount The amount of SHU to unstake
    function unstake(
        address keyper,
        uint256 stakeIndex,
        uint256 amount
    ) external {
        /////////////////////////// CHECKS ///////////////////////////////
        require(
            _stakeIndex < keyperStakes[keyper].length,
            "Invalid stake index"
        );

        // Gets the keyper stake
        Stake storage keyperStake = keyperStakes[keyper][_stakeIndex];

        // checks below only apply if keyper is still a keyper
        // if keyper is not a keyper anymore, anyone can unstake, lock period is
        // ignored and minStake is not enforced
        if (keypers[keyper]) {
            require(msg.sender == keyper, "Only keyper can unstake");

            // minStake must be respected after unstaking
            require(
                shuBalances[keyper] - amount >= minStake,
                "Keyper can't unstake below minStake"
            );

            // check if the stake is still locked
            require(
                keyperStake.timestamp + keyperStake.lockPeriod <=
                    block.timestamp,
                "Stake is still locked"
            );
        }

        /////////////////////////// EFFECTS ///////////////////////////////

        // Before doing anything, get the unclaimed rewards first
        rewardsDistributor.distributeRewards();

        // Gets the stake shares
        uint256 shares = keyperStake.shares;

        // Calculates the amount of SHU the shares are worth
        rewards = (shares * shu.balanceOf(address(this))) / totalSupply;

        _burn(sender, userStake.shares);

        uint256 amount = userStake.amount + rewards;

        shu.transfer(sender, amount);

        // Claim other rewards (e.g., WETH)
        for (uint256 i = 0; i < rewardTokenList.length; i++) {
            IERC20 rewardToken = IERC20(rewardTokenList[i]);
            uint256 rewardAmount = (shares *
                rewardToken.balanceOf(address(this))) / totalSupply;

            if (rewardAmount > 0) {
                IERC20(rewardToken).transfer(sender, rewardAmount);
                emit ClaimRewards(sender, address(rewardToken), rewardAmount);
            }
        }

        emit Unstaked(sender, amount, userStake.shares);

        // Remove the stake from the user's stake array
        keyperStakes[sender][_stakeIndex] = keyperStakes[sender][
            keyperStakes[sender].length - 1
        ];
        keyperStakes[sender].pop();
    }

    function claimRewards(address rewardToken, uint256 amount) external {
        rewardsDistributor.distributeRewards();

        IERC20 token = IERC20(rewardToken);

        address sender = msg.sender;

        // Calculate the user's total rewards for the specified reward token
        uint256 totalRewards = (balances[sender] *
            token.balanceOf(address(this))) / totalSupply;

        if (amount > totalRewards) {
            amount = totalRewards;
        }

        // Transfer the specified amount of rewards to the user
        token.transfer(sender, amount);
        emit ClaimRewards(sender, rewardToken, amount);
    }

    function _mint(address user, uint256 amount) private {
        balances[user] += amount;
        totalSupply += amount;
    }

    function _burn(address user, uint256 amount) private {
        balances[user] -= amount;
        totalSupply -= amount;
    }
}
