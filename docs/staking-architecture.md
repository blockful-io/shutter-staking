# Staking Contract Architecture

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

### `uint256 public lockPeriod`

Represents the minimum amount of time a stake will be locked before the keyper
can unstake. This value can be changed by the DAO. If the new lock period is
lower than the current lock period for a specific stake, the new lock period
will be considered only for new stakes. This ensures that the keyper can trust
that their tokens will never be locked for longer than the agreed-upon period
when they staked, while also allowing keyper to unstake their SHU tokens in
emergency situations.

### `uint256 public minStake`

Represents the minimum amount of SHU tokens that must be staked at the first
keyper stake.

### `uint256 internal nextStakeId`

Internal variable to keep track of the next stake id.

## Mappings

```solidity
struct Stake {
    uint256 amount;
    uint256 timestamp;
    uint256 lockPeriod;
}
```

-   `mapping(address keyper => bool) public keypers`: a mapping from keypers to
    their status. If the keyper is true, they are allowed to stake. If the keyper
    is false, they are not allowed to stake.
-   `mapping(uint256 id => Stake) public stakes`: a mapping from `stakeId` to
    the stake metadata. Id is a unique identifier for each stake and is
    incremented whenever a keyper stakes.
-   `mapping(address keyper => EnumerableSet.UintSet stakeIds) private
stakeIds`: a mapping from keypers to their stake ids. This mapping is used
    to iterate over the keyper stakes and to determine to which keyper the stake
    belongs.
-   `mapping(address keyper => uint256 totalLocked) public totalLocked`: a
    mapping from keypers to the total amount of SHU tokens locked by the keyper.

## Rewards Calculation Mechanismm

The rewards method choosen was a ERC4626 vault implementation.
The rewards are withdrawn from the rewards distribution contract every time a keyper
stakes or claim rewards. When the rewards are claimed, the SHU balance of the
contract increases. Therefore, when a keyper decides to claim their rewards,
they will get a better conversion rate from sSHU (shares) to SHU, as the total
amount of SHU tokens in the contract has increased. The new conversion rate
represents the rewards earned by the Keyper.

The reward earned by a user is proportional to the amount they have staked and
the time they have staked. The more and earlier a user stakes, the larger their
share of the pool and consequently more rewards they earn.

## Keyper Functions

### `stake(uint256 amount)`

-   When staking, the keyper receives shares (sSHU) in exchange for the SHU tokens. The shares represent the keyper's ownership of the total staked amount and are used to calculate the rewards the keyper earns.
-   The caller must have approved the staking contract to transfer `amount` of SHU tokens on their behalf.
-   Only keypers can call this function.
-   A minimum amount of SHU tokens defined by the DAO must be staked at the
    first stake.
-   Each stake has an individual lock period that must be respected before the
    keyper can unstake.

### `unstake(address keyper, uint256 amount, uint256 stakeId)`

-   The shares are burned when the keyper unstakes.
-   The caller must have staked for at least `lockPeriod` for the specific stake.
-   The withdrawn can never result in a keyper stake balance lower than the
    minimum stake defined by the DAO.
-   If the caller passes 0 in the `amount` parameter, the contract will unstake
    all the SHU tokens staked for the specific stake.
-   If a keyper is not a keyper anymore, this function can be called by anyone
    and the SHU tokens will be sent to the keyper address. No lock period or
    minimum stake will be considered in this case.

### `claimRewards(uint256 amount)`

-   Claim rewards for a specific reward token.
-   The amount must be less than the keyper `totalLocked` amount.
-   Only the keyper can claim their rewards.
-   If caller pass 0 in the `amount` paramater, the contract will claim all the
    caller rewards accumulated until the current timestamp.

## Owner Functions (DAO)

### `setLockPeriod(uint256 newLockPeriod)`

-   The minimum staking period for SHU tokens before they can be unstaked.
-   Measured in seconds.
-   New stakes will have the new lock period.
-   For existing stakes, the lock period will be considered only if the new lock
    period is lower than the current one for that stake. This ensures that the
    keyper can trust that their tokens will never be locked for longer than the
    agreed-upon period when they staked, while also allowing keyper to unstake
    their SHU tokens in emergency situations.

### `setRewardsDistributor(address newRewardsDistributor)`

Set the new rewards distribution contract address.

### `setKeyper(address keyper,bool status)`

Add or remove a keyper.

### `setMinStake(uint256 newMinimumStake)`

Set the new minimum amount of SHU tokens that must be staked by keypers.

## View Functions

### `getKeyperStakeIds(address keyper, uint256 stakeId)`

Get a list of stake ids belonging to a keyper.

### `maxWithdraw(address keyper)`

Calculates the maximum amount of assets that a keyper can withdraw, which
represents the rewards accumulated and not claimed yet. This doesn't include
unlocked stakes.

-   if the keyper sSHU balance is less or equal than the total locked amount, the function will return 0.

## Security Considerations

-   The contract doesn't use the Ownable2Step pattern due to the 24KB contract
    size limit.
-   If the Owner address gets compromised, the attacker can increase the minimum
    stake to a very high value, preventing keypers from unstaking their SHU tokens.
