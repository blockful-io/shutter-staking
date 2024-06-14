// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import {ERC20VotesUpgradeable} from "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {SafeTransferLib} from "@solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "@solmate/utils/FixedPointMathLib.sol";

interface IRewardsDistributor {
    function distributeRewards() external;
}

// TODO should be pausable?
// TODO use SafeTransferLib to every calculation
contract Staking is ERC20VotesUpgradeable, Ownable2StepUpgradeable {
    /*//////////////////////////////////////////////////////////////
                               LIBRARIES
    //////////////////////////////////////////////////////////////*/
    using SafeTransferLib for ERC20;
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

    /*//////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice the stake struct
    /// @dev timestamp is the time the stake was made
    struct Stake {
        uint256 amount;
        uint256 shares;
        uint256 timestamp;
        uint256 lockPeriod;
    }

    /*//////////////////////////////////////////////////////////////
                             MAPPINGS/ARRAYS
    //////////////////////////////////////////////////////////////*/

    /// @notice the keyper stakes mapping
    mapping(address keyper => Stake[]) public keyperStakes;

    /// @notice how many SHU a keyper has staked
    mapping(address keyper => uint256) public stakingTokenBalances;

    /// TODO when remove keyper also unstake the first stake
    mapping(address keyper => bool isKeyper) public keypers;

    address[] public rewardTokenList;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Staked(
        address indexed user,
        uint256 indexed amount,
        uint256 indexed shares,
        uint256 lockPeriod
    );
    event Unstaked(address user, uint256 amount, uint256 shares);
    event ClaimRewards(address user, address rewardToken, uint256 rewards);

    /*//////////////////////////////////////////////////////////////
                                 MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Ensure only keypers can stake
    modifier onlyKeyper() {
        require(keypers[msg.sender], "Only keypers can stake");
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
        IERC20 _stakingToken,
        IRewardsDistributor _rewardsDistributor,
        uint256 _lockPeriod,
        uint256 _minStake
    ) public initializer {
        // Does nothing but calls anyway for consistency
        __ERC20Votes_init();
        __Ownable2Step_init();

        // Transfer ownership to the DAO contract
        transferOwnership(newOwner);

        stakingToken = _stakingToken;
        rewardsDistributor = _rewardsDistributor;
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
    /// TODO check for reentrancy
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

        uint256 sharesToMint = convertToShares(amount);

        // Update the keyper's SHU balance
        stakingTokenBalances[keyper] += amount;

        // Mint the shares
        _mint(keyper, sharesToMint);

        // Lock the SHU in the contract
        stakingToken.transferFrom(keyper, address(this), amount);

        // Record the new stake
        stakes.push(Stake(amount, sharesToMint, block.timestamp, lockPeriod));

        emit Staked(keyper, amount, sharesToMint, lockPeriod);
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
    ///          - amount must be specified in SHU, not shares
    /// @param keyper The keyper address
    /// @param stakeIndex The index of the stake to unstake
    /// @param amount The amount
    /// TODO check for reentrancy
    function unstake(
        address keyper,
        uint256 stakeIndex,
        uint256 amount
    ) external {
        /////////////////////////// CHECKS ///////////////////////////////

        require(
            stakeIndex < keyperStakes[keyper].length,
            "Invalid stake index"
        );

        // Gets the keyper stake
        Stake storage keyperStake = keyperStakes[keyper][stakeIndex];

        // Checks below only apply if keyper is still a keyper
        // if keyper is not a keyper anymore, anyone can unstake, lock period is
        // ignored and minStake is not enforced
        if (keypers[keyper]) {
            require(msg.sender == keyper, "Only keyper can unstake");

            // minStake must be respected after unstaking
            require(
                stakingTokenBalances[keyper] - amount >= minStake,
                "Keyper can't unstake below minStake"
            );

            if (lockPeriod < keyperStake.lockPeriod) {
                require(
                    keyperStake.timestamp + lockPeriod <= block.timestamp,
                    "Stake is still locked"
                );
            } else {
                require(
                    keyperStake.timestamp + keyperStake.lockPeriod <=
                        block.timestamp,
                    "Stake is still locked"
                );
            }
        }

        /////////////////////////// EFFECTS ///////////////////////////////

        // Before doing anything, get the unclaimed rewards first
        rewardsDistributor.distributeRewards();

        // Prevents the keyper from unstaking more than they have staked
        uint256 maxWithdrawAmount = maxWithdraw(keyper);
        amount = maxWithdrawAmount < amount ? maxWithdrawAmount : amount;

        // Calculates the amounf of shares to burn
        uint256 shares = convertToShares(amount);

        // Burn the shares
        _burn(keyper, shares);

        // Decrease the amount from the stake
        keyperStake.amount -= amount;

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
        stakingToken.transfer(keyper, amount);

        emit Unstaked(keyper, amount, shares);
    }

    /// @notice Claim reward for a specific reward token
    /// @param rewardToken The address of the reward token
    /// @param amount The amount of rewards to claim
    function claimReward(IERC20 rewardToken, uint256 amount) external {
        require(address(rewardToken) != address(0), "No native token rewards");

        // Before doing anything, get the unclaimed rewards first
        rewardsDistributor.distributeRewards();

        address sender = msg.sender;

        // Calculate the user's total rewards for the specified reward token
        // TODO see this
        uint256 totalRewards = (balanceOf(sender) * totalSupply()) /
            rewardToken.balanceOf(address(this));

        if (amount > totalRewards) {
            amount = totalRewards;
        }

        // Transfer the specified amount of rewards to the user
        rewardToken.transfer(sender, amount);

        emit ClaimRewards(sender, address(rewardToken), amount);
    }

    /*//////////////////////////////////////////////////////////////
                         RESTRICTED FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Set the rewards distributor contract
    /// @param _rewardsDistributor The address of the rewards distributor contract
    function setRewardsDistributor(
        IRewardsDistributor _rewardsDistributor
    ) external onlyOwner {
        rewardsDistributor = _rewardsDistributor;
    }

    /// @notice Set the lock period
    /// @param _lockPeriod The lock period in seconds
    function setLockPeriod(uint256 _lockPeriod) external onlyOwner {
        lockPeriod = _lockPeriod;
    }

    /// @notice Set the minimum stake amount
    /// @param _minStake The minimum stake amount
    function setMinStake(uint256 _minStake) external onlyOwner {
        minStake = _minStake;
    }

    /// @notice Set a keyper
    /// @param keyper The keyper address
    /// @param isKeyper Whether the keyper is a keyper or not
    function setKeyper(address keyper, bool isKeyper) external onlyOwner {
        keypers[keyper] = isKeyper;
    }

    /// @notice Set multiple keypers
    /// @param _keypers The keyper addresses
    /// @param isKeyper Whether the keypers are keypers or not
    function setKeypers(
        address[] memory _keypers,
        bool isKeyper
    ) external onlyOwner {
        for (uint256 i = 0; i < _keypers.length; i++) {
            keypers[_keypers[i]] = isKeyper;
        }
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

    /// @notice Get the maximum amount of assets a keyper can unstake
    /// @param keyper The keyper address
    function maxWithdraw(address keyper) public view virtual returns (uint256) {
        return convertToAssets(balanceOf(keyper));
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
}
