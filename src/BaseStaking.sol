// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "@forge-std/console.sol";
import {OwnableUpgradeable} from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {ERC20VotesUpgradeable} from "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {EnumerableSetLib} from "@solady/utils/EnumerableSetLib.sol";

import {IERC20} from "./interfaces/IERC20.sol";
import {SafeTransferLib} from "./libraries/SafeTransferLib.sol";
import {FixedPointMathLib} from "./libraries/FixedPointMathLib.sol";
import {IRewardsDistributor} from "./interfaces/IRewardsDistributor.sol";

abstract contract BaseStaking is OwnableUpgradeable, ERC20VotesUpgradeable {
    /*//////////////////////////////////////////////////////////////
                               LIBRARIES
    //////////////////////////////////////////////////////////////*/
    using EnumerableSetLib for EnumerableSetLib.Uint256Set;

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

    /// @notice Unique identifier that will be used for the next stake.
    uint256 internal nextStakeId;

    /*//////////////////////////////////////////////////////////////
                                MAPPINGS
    //////////////////////////////////////////////////////////////*/

    /// @notice how many SHU a user has locked
    mapping(address user => uint256 totalLocked) public totalLocked;

    // @notice stake ids belonging to a user
    mapping(address user => EnumerableSetLib.Uint256Set stakeIds)
        internal userStakes;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a keyper claims rewards
    event RewardsClaimed(address indexed user, uint256 rewards);

    /// @notice Emitted when the lock period is changed
    event NewLockPeriod(uint256 indexed lockPeriod);

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

    /// @notice Thrown when the amount of shares is 0
    error SharesMustBeGreaterThanZero();

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
        uint256 shares = _previewWithdraw(rewards);

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
        // no events for this function due to 24kb contract size limit
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

    /// @notice Get the total amount of shares the assets are worth
    /// @param assets The amount of assets
    function convertToShares(
        uint256 assets
    ) public view virtual returns (uint256) {
        console.log("totoal supply", totalSupply());
        console.log("total assets", _totalAssets());
        console.log("assets", assets);
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

    /// @notice Get the total amount of assets that a keyper can withdraw
    /// @dev must be implemented by the child contract
    function maxWithdraw(address user) public view virtual returns (uint256);

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit SHU into the contract
    /// @param amount The amount of SHU to deposit
    function _deposit(address to, uint256 amount) internal {
        // Calculate the amount of shares to mint
        uint256 shares = convertToShares(amount);

        // Update the total locked amount
        unchecked {
            totalLocked[to] += amount;
        }

        // Mint the shares
        _mint(to, shares);

        // Lock the SHU in the contract
        stakingToken.safeTransferFrom(to, address(this), amount);
    }

    /// @notice Withdraw SHU from the contract
    /// @param user The user address
    /// @param amount The amount of SHU to withdraw
    function _withdraw(
        address user,
        uint256 amount
    ) internal returns (uint256 shares) {
        shares = _previewWithdraw(amount);

        // Decrease the amount from the total locked
        totalLocked[user] -= amount;

        // Burn the shares
        _burn(user, shares);

        // Transfer the SHU to the keyper
        stakingToken.safeTransfer(user, amount);
    }

    /// @notice Get the amount of SHU staked for all keypers
    function _totalAssets() internal view returns (uint256) {
        return stakingToken.balanceOf(address(this));
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
}
