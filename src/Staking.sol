// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import {ERC20VotesUpgradeable} from "@openzeppelin-upgradeable/contracts/token/ERC20/extensiions/ERC20VotesUpgradeable";
import {SafeTransferLib} from "@solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "@solmate/utils/FixedPointMathLib.sol";

interface IRewardsDistributor {
    function distributeRewards() external;
}

// TODO should be pausable?
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
    IERC20 public shu;

    /*//////////////////////////////////////////////////////////////
                                 VARIABLES
    //////////////////////////////////////////////////////////////*/

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
    mapping(address keyper => uint256) public shuBalances;

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
        require(isKeyper[msg.sender], "Only keypers can stake");
        _;
    }

    /// @notice Ensure logic contract is unusable
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the contract
    /// @param newOwner The owner of the contract, i.e. the DAO contract address
    /// @param stakingToken The address of the staking token, i.e. SHU
    /// @param _rewardsDistributor The address of the rewards distributor
    /// contract
    /// @param _lockPeriod The lock period in seconds
    /// @param _minStake The minimum stake amount
    function initialize(
        address newOwner,
        IERC20 stakingToken,
        IRewardsDistributor _rewardsDistributor,
        uint256 _lockPeriod,
        uint256 _minStake
    ) public initializer {
        // Does nothing but calls anyway for consistency
        __ERC20Votes_init();
        __Ownable2Step_init();

        // Transfer ownership to the DAO contract
        transferOwnership(newOwner);

        shu = stakingToken;
        rewardsDistributor = _rewardsDistributor;
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
    ///          - If amount is greater than the keyper stake, the contract will
    ///            transfer the maximum amount available not the requested amount
    ///          - amount must be specified in SHU, not shares
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

        // Checks below only apply if keyper is still a keyper
        // if keyper is not a keyper anymore, anyone can unstake, lock period is
        // ignored and minStake is not enforced
        if (keypers[keyper]) {
            require(msg.sender == keyper, "Only keyper can unstake");

            // minStake must be respected after unstaking
            require(
                shuBalances[keyper] - amount >= minStake,
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
        _burn(sender, shares);

        // Decrease the amount from the stake
        keyperStake.amount -= amount;

        // If the stake is empty, remove it
        if (keyperStake.amount == 0) {
            // Remove the stake from the keyper's stake array
            keyperStakes[keyper][_stakeIndex] = keyperStakes[keyper][
                keyperStakes[keyper].length - 1
            ];
            keyperStakes[keyper].pop();
        }

        /////////////////////////// INTERACTIONS ///////////////////////////

        // Transfer the SHU to the keyper
        shu.transfer(keyper, amount);

        emit Unstaked(keyper, amount, shares);
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

    /*//////////////////////////////////////////////////////////////
                         OWNABLE FUNCTIONS
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
    /// @param keypers The keyper addresses
    /// @param isKeyper Whether the keypers are keypers or not
    function setKeypers(address[] keypers, bool isKeyper) external onlyOwner {
        for (uint256 i = 0; i < keypers.length; i++) {
            keypers[keypers[i]] = isKeyper;
        }
    }

    /// @notice Get the total amount of shares the assets are worth
    /// @param assets The amount of assets
    function convertToShares(
        uint256 assets
    ) public view virtual returns (uint256) {
        uint256 supply = totalSupply; // Saves an extra SLOAD if totalSupply is non-zero.

        return supply == 0 ? assets : assets.mulDivDown(supply, totalAssets());
    }

    /// @notice Get the total amount of assets the shares are worth
    /// @param shares The amount of shares
    function convertToAssets(
        uint256 shares
    ) public view virtual returns (uint256) {
        uint256 supply = totalSupply; // Saves an extra SLOAD if totalSupply is non-zero.

        return supply == 0 ? shares : shares.mulDivDown(totalAssets(), supply);
    }

    /*//////////////////////////////////////////////////////////////
                              TRANSFER LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Transfer is disabled
    function transfer(
        address to,
        uint256 value
    ) public override returns (bool) {
        revert("Transfer is disabled");
    }

    /// @notice Transfer is disabled
    function transferFrom(
        address from,
        address to,
        uint256 value
    ) public override returns (bool) {
        revert("Transfer is disabled");
    }

    /*//////////////////////////////////////////////////////////////
                           UNSTAKE LIMIT LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the maximum amount of assets a keyper can unstake
    /// @param keyper The keyper address
    function maxWithdraw(address keyper) public view virtual returns (uint256) {
        return convertToAssets(balanceOf[keyper]);
    }

    /// @notice Get the maximum amount of shares a keyper can unstake
    /// @param keyper The keyper address
    function maxRedeem(address owner) public view virtual returns (uint256) {
        return balanceOf[owner];
    }
}
