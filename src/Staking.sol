// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Staking {
    event Stake(
        address indexed user,
        uint256 indexed amount,
        uint256 indexed shares,
        uint256 lockPeriod
    );
    event Unstake(address user, uint256 amount, uint256 shares);
    event ClaimRewards(address user, address rewardToken, uint256 rewards);

    IERC20 public immutable shu;
    RewardsDistributor public rewardsDistributor;
    uint256 public totalSupply;
    uint256 public lockPeriod; // lock period in seconds
    uint256 public minStake;

    struct Stake {
        uint256 amount;
        uint256 shares;
        uint256 stakedTimestamp;
        uint256 lockPeriod;
    }

    mapping(address keyper => Stake[]) public userStakes;
    mapping(address keyper => uint256) public balances;
    mapping(address keyper => bool isKeyper) public keypers;

    address[] public rewardTokenList;

    constructor(IERC20 _shu, uint256 _lockPeriod) {
        shu = _shu;
        rewardsDistributor = RewardsDistributor(msg.sender);
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
            // Calculate and mint the amount of shares the Shu is worth. The ratio will change over time, as shares are burned/minted and SHU distributed to this contract
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
        emit Stake(sender, _amount, sharesToMint, lockPeriod);
    }

    // Unlocks the staked + gained Shu and burns shares
    function unstake(uint256 _stakeIndex) external returns (uint256 rewards) {
        address sender = msg.sender;

        require(_stakeIndex < userStakes[sender].length, "Invalid stake index");

        Stake storage userStake = userStakes[sender][_stakeIndex];

        require(
            block.timestamp >= userStake.stakeTimestamp + userStake.lockPeriod,
            "Stake is still locked"
        );

        // Before doing anything, get the unclaimed rewards first
        rewardsDistributor.distributeRewards();

        uint256 shares = userStake.shares;

        // Calculates the amount of SHU the shares are worth
        rewards = (shares * shu.balanceOf(address(this))) / totalSupply;

        _burn(sender, userStake.shares);
        shu.transfer(sender, rewards);

        // Claim other rewards (e.g., WETH)
        for (uint256 i = 0; i < rewardTokenList.length; i++) {
            IERC20 rewardToken = IERC20(rewardTokenList[i]);
            uint256 rewardAmount = (shares *
                rewardToken.balanceOf(address(this))) / totalSupply;

            if (rewardAmount > 0) {
                IERC20(rewardToken).transfer(msg.sender, rewardAmount);
                emit ClaimRewards(msg.sender, rewardToken, rewardAmount);
            }
        }

        emit Unstake(msg.sender, rewards, userStake.shares);

        // Remove the stake from the user's stake array
        userStakes[msg.sender][_stakeIndex] = userStakes[msg.sender][
            userStakes[msg.sender].length - 1
        ];
        userStakes[msg.sender].pop();
    }

    function claimRewards(address _rewardToken, uint256 _amount) public {
        rewardsDistributor.distributeRewards();

        // Calculate the user's total rewards for the specified reward token
        uint256 totalRewards = balances[msg.sender]
            .mul(rewardTokens[_rewardToken].balanceOf(address(this)))
            .div(totalSupply);

        if (amount > totalRewards) {
            amount = totalRewards;
        }

        // Transfer the specified amount of rewards to the user
        rewardTokens[_rewardToken].transfer(msg.sender, _amount);
        emit ClaimRewards(msg.sender, _rewardToken, _amount);
    }

    function getRewards(address user) external view returns (uint256[] memory) {
        uint256[] memory rewards = new uint256[](rewardTokenList.length);
        for (uint256 i = 0; i < rewardTokenList.length; i++) {
            address rewardToken = rewardTokenList[i];
            rewards[i] = balances[user]
                .mul(rewardTokens[rewardToken].balanceOf(address(this)))
                .div(totalSupply);
        }
        return rewards;
    }

    function _mint(address user, uint256 amount) internal {
        balances[user] = balances[user].add(amount);
        totalSupply = totalSupply.add(amount);
    }

    function _burn(address user, uint256 amount) internal {
        balances[user] = balances[user].sub(amount);
        totalSupply = totalSupply.sub(amount);
    }
}

abstract contract RewardsDistributor {
    function distributeRewards() external virtual;
}
