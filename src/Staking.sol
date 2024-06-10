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
    //// ------------------- State Variables ------------------------
    //// ------------------------------------------------------------
    //// ------------------------------------------------------------

    IERC20 public shu;
    IRewardsDistributor public rewardsDistributor;
    uint256 public totalSupply;
    uint256 public lockPeriod; // lock period in seconds
    uint256 public minStake;

    //// ------------------------------------------------------------
    //// ------------------------------------------------------------
    //// ----------------------- Structs ----------------------------
    //// ------------------------------------------------------------
    //// ------------------------------------------------------------

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

    mapping(address keyper => Stake[]) public userStakes;
    mapping(address keyper => uint256) public balances;
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

    /// @notice ensure logic contract is unusable
    constructor() {
        _disableInitializers();
    }

    /// --------------------------------------------------------
    /// --------------------------------------------------------
    /// ---------------------- Initialize ----------------------
    /// --------------------------------------------------------
    /// --------------------------------------------------------

    /// @notice Initialize the bridge
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

    function addRewardToken(IERC20 _rewardToken) external {
        require(
            msg.sender == address(rewardsDistributor),
            "Only rewards distributor can add reward tokens"
        );
        rewardTokenList.push(address(_rewardToken));
    }

    // Locks SHU, update the user's shares (non-transferable)
    function stake(uint256 _amount) external returns (uint256 sharesToMint) {
        require(_amount >= minStake, "Amount is less than min stake");

        // Before doing anything, get the unclaimed rewards first
        rewardsDistributor.distributeRewards();

        // Gets the amount of Shu locked in the contract
        uint256 totalShu = shu.balanceOf(address(this));

        if (totalSupply == 0 || totalShu == 0) {
            // If no shares exist, mint it 1:1 to the amount put in
            sharesToMint = _amount;
        } else {
            // Calculate and mint the amount of shares the SHU is worth. The ratio will change over time, as shares are burned/minted and SHU distributed to this contract
            sharesToMint = (_amount * totalSupply) / totalShu;
        }

        address sender = msg.sender;

        _mint(sender, sharesToMint);

        // Lock the SHU in the contract
        shu.transferFrom(sender, address(this), _amount);

        // Record the new stake
        userStakes[sender].push(
            Stake(_amount, sharesToMint, block.timestamp, lockPeriod)
        );
        emit Staked(sender, _amount, sharesToMint, lockPeriod);
    }

    // Unlocks the staked + gained Shu and burns shares
    function unstake(uint256 _stakeIndex) external returns (uint256 rewards) {
        address sender = msg.sender;

        require(_stakeIndex < userStakes[sender].length, "Invalid stake index");

        Stake storage userStake = userStakes[sender][_stakeIndex];

        require(
            block.timestamp >= userStake.timestamp + userStake.lockPeriod,
            "Stake is still locked"
        );

        // Before doing anything, get the unclaimed rewards first
        rewardsDistributor.distributeRewards();

        uint256 shares = userStake.shares;

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
        userStakes[sender][_stakeIndex] = userStakes[sender][
            userStakes[sender].length - 1
        ];
        userStakes[sender].pop();
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
