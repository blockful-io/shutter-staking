# Delegate Contract Architecture

## Overview

-   The contract is upgradable and utilizes the Transparent Proxy pattern. It
    inherits from OpenZeppelin's ERC20VotesUpgradeable and
    OwnableUpgradeable.
-   The contract overrides the `transfer` and
    `transferFrom` functions to prevent the sSHU token from being transferred. All
    the other inherited functions follow the OpenZeppelin implementation.
-   To avoid rounding errors, the contract uses the FixedPointMathLib from Solmate
    library.
-   The contract uses SafeTransferLib from solmate to interact with the SHU token.
-   The choosen mechanism for the rewards distribution is a ERC4626 vault implementation.

## Variables

### `IERC20 stakingToken`

The staking token must be immutable. If the DAO changes the staking token, the
keypers will not be able to withdrawn their old stakes, therefore, there is no
function to change the staking token. If the DAO upgrades the SHU token to a new contract, it must also redeploy the staking contract and ask the keypers to migrate their stakes to the new contract.

### `IRewardsDistributor rewardsDistributor`

The rewards distributor contract address. The rewards distributor contract is
responsible for distributing the rewards to the keypers. The rewards are
withdrawn from the rewards distribution contract every time a keyper stakes or
claim rewards.

### `IStaking staking`

The staking contract address. The staking contract is responsible for managing
the keypers stakes. The delegate contract interacts with the staking contract to
verify whether a address is a keyper or not.

### `uint256 internal nextStakeId`

Internal variable to keep track of the next stake id.

## Mappings

```solidity
struct Stake {
    address keyper; // the keyper who the stake is delegating to
    uint256 amount;
}
```

-   `mapping(uint256 id => Stake) public stakes`: a mapping from `stakeId` to
    the stake metadata. Id is a unique identifier for each stake and is
    incremented whenever a keyper stakes.
-   `mapping(address user => EnumerableSet.UintSet stakeIds) private
stakeIds`: a mapping from users to their stake ids. This mapping is used
    to iterate over the keyper stakes and to determine to which user the stake
    belongs.
-   `mapping(address keyper => uint256 totalDelegated) public totalDelegated`: a
    mapping from keypers to the total amount of SHU tokens delegated to them.

## Rewards Calculation Mechanismm

The rewards method choosen was a ERC4626 vault implementation. The
rewards are withdrawn from the rewards distribution contract every time a user
stakes or claim rewards. When the rewards are claimed, the SHU balance of the
contract increases. Therefore, when a user decides to claim their rewards,
they will get a better conversion rate from sSHU (shares) to SHU, as the total
amount of SHU tokens in the contract has increased. The new conversion rate
represents the rewards earned by the Keyper.

The reward earned by a user is proportional to the amount they have staked and
the time they have staked. The more and earlier a user stakes, the larger their
share of the pool and consequently more rewards they earn.

## Permissioneless Functions

### `delegateTo(address keyper, uint256 amount)`

-   When staking, the user receives shares (sSHU) in exchange for the SHU tokens. The shares represent the keyper's ownership of the total staked amount and are used to calculate the rewards the user earns.
-   The caller must have approved the staking contract to transfer `amount` of SHU tokens on their behalf.
-   Users need to specify the address of the keyper they want to delegate their
    stake to. The selected keyper must belongs to the keypers mapping in the staking contract. It's important to understand that this delegation is purely symbolic, and the keyper does not gain any control over the user's stake or voting rights. This symbolic delegation simply allows users to show support for their preferred keypers.

### `unstake(uint256 amount, uint256 stakeId)`

-   The shares are burned when the user unstakes.
-   If the caller passes 0 in the `amount` parameter, the contract will unstake
    all the SHU tokens staked for the specific stake.

### `claimRewards(uint256 amount)`

-   Claim rewards for a specific reward token.
-   If caller pass 0 in the `amount` paramater, the contract will claim all the
    caller rewards accumulated until the current timestamp.

## Owner Functions (DAO)

### `setRewardsDistributor(address newRewardsDistributor)`

Set the new rewards distribution contract address.

### `setStaking(address newStaking)`

Set the new staking contract address.

## View Functions

### `getUserStakeIds(address user, uint256 stakeId)`

Get a list of stake ids belonging to a user.

### `maxWithdraw(address user)`

Calculates the maximum amount of assets that a keyper can withdraw, which
represents the rewards accumulated and not claimed yet. This funciton will revert if the user has no shares.
