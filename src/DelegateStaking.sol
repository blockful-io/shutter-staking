// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {OwnableUpgradeable} from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {ERC20VotesUpgradeable} from "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/ERC20VotesUpgradeable.sol";

import {IERC20} from "./interfaces/IERC20.sol";
import {SafeTransferLib} from "./libraries/SafeTransferLib.sol";
import {FixedPointMathLib} from "./libraries/FixedPointMathLib.sol";
import {IRewardsDistributor} from "./interfaces/IRewardsDistributor.sol";

interface IStaking {
    function keypers(address user) external returns (bool);
}

/// @notice Shutter Delegate Staking Contract
///         Allows users to stake SHU and earn rewards in exchange.
contract Delegate is ERC20VotesUpgradeable, OwnableUpgradeable {
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

    /// @notice the staking contract
    /// @dev only owner can change
    IStaking public staking;

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

    // @notice stake ids belonging to a user
    mapping(address user => EnumerableSet.UintSet stakeIds) private userStakes;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a keyper stakes SHU
    event Staked(address indexed user, address indexed keyper, uint256 amount);

    /// @notice Emitted when a keyper unstakes SHU
    event Unstaked(address indexed user, uint256 amount, uint256 shares);

    /// @notice Emitted when a keyper claims rewards
    event RewardsClaimed(address indexed user, uint256 rewards);

    /// @notice Emitted when the rewards distributor is changed
    event NewRewardsDistributor(address indexed rewardsDistributor);

    /// @notice Emitted when a new staking contract is set
    event NewStakingContract(address indexed stakingContract);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice  Thrown when transfer/tranferFrom is called
    error TransferDisabled();

    /// @notice Thrown when a keyper has no shares
    error UserHasNoShares();

    /// @notice Trown when amount is zero
    error ZeroAmount();

    /// @notice Thrown when someone try to unstake a stake that doesn't belong
    /// to them
    error StakeDoesNotBelongToUser();

    /// @notice Thrown when someone try to unstake a stake that doesn't exist
    error StakeDoesNotExist();

    /// @notice Thrown when someone try to unstake a amount that is greater than
    /// the stake amount belonging to the stake id
    error WithdrawAmountTooHigh();

    /// @notice Thrown when a keyper try to claim rewards but has no rewards to
    /// claim
    error NoRewardsToClaim();

    /// @notice Thrown when the argument is the zero address
    error AddressZero();

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

    /// @notice Initialize the contract
    /// @param _owner The owner of the contract, i.e. the DAO contract address
    /// @param _stakingToken The address of the staking token, i.e. SHU
    /// @param _rewardsDistributor The address of the rewards distributor
    /// contract
    /// @param _staking The address of the staking contract
    function initialize(
        address _owner,
        address _stakingToken,
        address _rewardsDistributor,
        address _staking
    ) public initializer {
        __ERC20_init("Delegated-staked SHU", "sdSHU");

        // Transfer ownership to the DAO contract
        _transferOwnership(_owner);

        stakingToken = IERC20(_staking);
        rewardsDistributor = IRewardsDistributor(_rewardsDistributor);

        nextStakeId = 1;
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

    function setStakingContract(address _stakingContract) external onlyOwner {
        require(_stakingContract != address(0), AddressZero());
        staking = IStaking(_stakingContract);

        emit NewStakingContract(_stakingContract);
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

    /// @notice Get the stake ids belonging to a user
    function getUserStakeIds(
        address keyper
    ) external view returns (uint256[] memory) {
        return userStakes[keyper].values();
    }

    function previewWithdraw(
        uint256 assets
    ) public view virtual returns (uint256) {
        // sum + 1 on both sides to prevent donation attack
        return assets.mulDivUp(totalSupply() + 1, _totalAssets() + 1);
    }

    /// @notice Get the total amount of shares the assets are worth
    /// @param assets The amount of assets
    function convertToShares(
        uint256 assets
    ) public view virtual returns (uint256) {
        // sum + 1 on both sides to prevent donation attack
        return assets.mulDivDown(totalSupply() + 1, _totalAssets() + 1);
    }

    /// @notice Get the total amount of assets the shares are worth
    /// @param shares The amount of shares
    function convertToAssets(
        uint256 shares
    ) public view virtual returns (uint256) {
        // sum + 1 on both sides to prevent donation attack
        return shares.mulDivDown(_totalAssets() + 1, totalSupply() + 1);
    }

    /// @notice Get the maximum amount of assets that a keyper can withdraw
    ////         - if the keyper has no shares, the function will revert
    ///          - if the keyper sSHU balance is less or equal than the minimum stake or the total
    ///            locked amount, the function will return 0
    /// @param keyper The keyper address
    /// @return amount The maximum amount of assets that a keyper can withdraw
    function maxWithdraw(address keyper) public view virtual returns (uint256) {
        uint256 shares = balanceOf(keyper);
        require(shares > 0, UserHasNoShares());

        return convertToAssets(shares);
    }

    /// @notice Get the amount of SHU staked for all keypers
    function _totalAssets() internal view virtual returns (uint256) {
        return stakingToken.balanceOf(address(this));
    }
}
