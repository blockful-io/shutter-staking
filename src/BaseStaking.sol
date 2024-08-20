// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OwnableUpgradeable} from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {ERC20VotesUpgradeable as ERC20Votes} from "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/ERC20VotesUpgradeable.sol";

import {EnumerableSetLib} from "./libraries/EnumerableSetLib.sol";
import {FixedPointMathLib} from "./libraries/FixedPointMathLib.sol";
import {IRewardsDistributor} from "./interfaces/IRewardsDistributor.sol";

abstract contract BaseStaking is OwnableUpgradeable, ERC20Votes {
    /*//////////////////////////////////////////////////////////////
                                 LIBRARIES
    //////////////////////////////////////////////////////////////*/
    using EnumerableSetLib for EnumerableSetLib.Uint256Set;

    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                                 VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice the staking token, i.e. SHU
    /// @dev set in initialize, can't be changed
    ERC20Votes public stakingToken;

    /// @notice the rewards distributor contract
    /// @dev only owner can change
    IRewardsDistributor public rewardsDistributor;

    /// @notice the lock period in seconds
    /// @dev only owner can change
    uint256 public lockPeriod;

    /// @notice Unique identifier that will be used for the next stake.
    uint256 internal nextStakeId;

    /*//////////////////////////////////////////////////////////////
                                 MAPPINGS
    //////////////////////////////////////////////////////////////*/

    /// @notice how many SHU a user has locked
    mapping(address => uint256) public totalLocked;

    // @notice stake ids belonging to a user
    mapping(address => EnumerableSetLib.Uint256Set) internal userStakes;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a keyper claims rewards
    event RewardsClaimed(address indexed user, uint256 rewards);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when someone try to unstake a amount that is greater than
    /// the stake amount belonging to the stake id
    error WithdrawAmountTooHigh();

    /// @notice  Thrown when transfer/tranferFrom is called
    error TransferDisabled();

    /// @notice Thrown when a user try to claim rewards but has no rewards to
    /// claim
    error NoRewardsToClaim();

    /// @notice Thrown when the argument is the zero address
    error AddressZero();

    /// @notice Thrown when a user has no shares
    error UserHasNoShares();

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

    /// @notice Claim rewards
    ///         - If no amount is specified, will claim all the rewards
    ///         - If the amount is specified, the amount must be less than the
    ///           maximum withdrawable amount. The maximum withdrawable amount
    ///           is the total amount of assets the user has minus the
    ///           total locked amount
    ///         - The keyper can claim the rewards at any time as longs there is
    ///           a reward to claim
    /// @param amount The amount of rewards to claim
    function claimRewards(
        uint256 amount
    ) external updateRewards returns (uint256 rewards) {
        uint256 assets = convertToAssets(balanceOf(msg.sender));
        uint256 locked = totalLocked[msg.sender];

        uint256 maxWithdrawAmount;
        unchecked {
            // need the first branch as convertToAssets rounds down
            maxWithdrawAmount = locked >= assets ? 0 : assets - locked;
        }

        // Prevents the keyper from claiming more than they should
        rewards = _calculateWithdrawAmount(amount, maxWithdrawAmount);
        require(rewards > 0, NoRewardsToClaim());

        // Calculates the amount of shares to burn
        _burn(msg.sender, _previewWithdraw(rewards));
        stakingToken.transfer(msg.sender, rewards);

        emit RewardsClaimed(msg.sender, rewards);
    }

    /*//////////////////////////////////////////////////////////////
                         TRANSFER FUNCTIONS
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
                         RESTRICTED FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Set the rewards distributor contract
    /// @param _rewardsDistributor The address of the rewards distributor contract
    function setRewardsDistributor(
        address _rewardsDistributor
    ) external onlyOwner {
        require(_rewardsDistributor != address(0), AddressZero());
        rewardsDistributor = IRewardsDistributor(_rewardsDistributor);
        // no events for this function due to 24kb contract size limit
    }

    /// @notice Set the lock period
    /// @param _lockPeriod The lock period in seconds
    function setLockPeriod(uint256 _lockPeriod) external onlyOwner {
        lockPeriod = _lockPeriod;
        // no events for this function due to 24kb contract size limit
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

    /// @notice Get the stake ids belonging to a user
    function getUserStakeIds(
        address user
    ) external view returns (uint256[] memory) {
        return userStakes[user].values();
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit SHU into the contract
    /// @param amount The amount of SHU to deposit
    function _deposit(uint256 amount) internal {
        // Update the total locked amount
        unchecked {
            totalLocked[msg.sender] += amount;
        }

        // Mint the shares
        _mint(msg.sender, convertToShares(amount));

        // Lock the SHU in the contract
        stakingToken.transferFrom(msg.sender, address(this), amount);
    }

    /// @notice Withdraw SHU from the contract
    /// @param user The user address
    /// @param amount The amount of SHU to withdraw
    function _withdraw(
        address user,
        uint256 amount
    ) internal returns (uint256 shares) {
        shares = _previewWithdraw(amount);

        unchecked {
            // Decrease the amount from the total locked
            totalLocked[user] -= amount;
        }

        // Burn the shares
        _burn(user, shares);

        // Transfer the SHU to the keyper
        stakingToken.transfer(user, amount);
    }

    /// @notice Get the amount of shares that will be burned
    /// @param assets The amount of assets
    function _previewWithdraw(uint256 assets) internal view returns (uint256) {
        uint256 supply = totalSupply(); // Saves an extra SLOAD if totalSupply is non-zero.
        return supply == 0 ? assets : assets.mulDivUp(supply, _totalAssets());
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

    /// @notice Get the amount of SHU staked for all keypers
    function _totalAssets() internal view returns (uint256) {
        return stakingToken.balanceOf(address(this));
    }

    /// @notice Initialize the contract minting dead shares to avoid inflation attack
    function __BaseStaking_init() internal {
        // mint dead shares to avoid inflation attack
        uint256 amount = 10_000e18;

        // Mint the shares to the vault
        _mint(address(this), convertToShares(amount));

        // Transfer the SHU to the vault
        stakingToken.transferFrom(msg.sender, address(this), amount);
    }
}
