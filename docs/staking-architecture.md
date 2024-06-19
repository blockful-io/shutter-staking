# Staking Contract Architecture

## Overview

Enables keypers to stake SHU tokens for a minimum period. In exchange, keypers receive rewards in the form of
any ERC20 token that the DAO chooses to distribute, such as SHU or WETH. SHU rewards are automatically compounded when the contract state is updated and can be withdraw at any time.

The architecture consists of two contracts:

1. Staking Contract: The main contract where keypers can stake SHU tokens and claim rewards.
2. Rewards Distribution Contract: A contract that distributes rewards to the
   staking contract.

The contracts are designed to be customizable, with adjustable parameters such as the lock period, minimum stake, and reward emission. Additionally, the contracts uses the Transparent Proxy pattern, where only the DAO has the permission to upgrade the contract and call the owner functions defined below.

## FAQ

1. Is there a deadline for distributing the rewards?
   No, the rewards distribution will continue until the rewards contract is depleted.

2. Can the stkSHU token be transferred?
   No, the stkSHU token is non-transferable. Keyper can only unstake the SHU tokens they have staked.

3. Is the lock period the same for all stakes?
   No, each stake has an individual lock period determined by the current lock period set by the DAO at the time of keyper's stake. The lock period can be updated by the DAO. If the new lock period is shorter than the current one for that stake, the new lock period will be honored. This allows keyper to trust that their tokens will not be locked for longer than the originally agreed-upon period when they staked, and also enables keyper to unstake their tokens in emergency situations.

4. Are the rewards distributed per second or per block?
   Per second.

5. Are the rewards automatically compounded?
   Yes, the rewards are automatically compounded when the contract state is updated, i.e., when anyone interacts with a non-view function.

6. Are the rewards calculated based on stake shares or the total amount of shares the keyper has?
   The rewards are calculated based on the total amount of shares the keyper has. This means that when the keyper claims rewards, they will receive the rewards for all the stakes they have.

7. When unstaking, are the rewards also transferred to the keyper?
   The keyper has the option to choose whether they want to claim the rewards when they unstake. This is the default behavior.
8. Is there a minimum stake amount?
   Yes, there is a minimum amount of SHU tokens that must be staked at the first
   stake. This amount can be set by the DAO. If the keyper unstake, for the next
   stake the amount plus the current stake amount must be greater than the minimum

## Requirements

1. Compound at each interaction
2. Unstake with individual lock period
3. Claim reward at any time
4. Minimum stake amount
5. Only keyper can stake

## Security Considerations

1. The staking contract uses the Ownable pattern where only the DAO has the
   permission to upgrade the contract and call the owner functions defined
   below.
2. The staking contracts follows the checks-effects-interactions pattern to
   prevent reentrancy attacks.
3. The staking contract has 100% unit test coverage
4. The staking contract has been deployed to the testnet and integration tests
   have been run against the testnet.
5. The staking contract has integration tests running against the mainnet fork
   to ensure the contract behaves as expected in a real environment.
6. The staking contract has been audited by a third-party security firm or audit contest platform.
7. An AST analyzer has been run on the staking contract.
8. There are CI checks in place to ensure the code is formatted correctly and
   the tests pass.

## Staking Contract

### Immutable Variables

-   `stakingToken`: the SHU token address

The staking token must be immutable. If the DAO changes the staking token, the
keypers will not be able to redeem their old stakes.
If the DAO upgrades the SHU token to a new contract, it must also redeploy the staking contract and ask the keypers to migrate their stakes to the new contract.

### Mutable Variables

-   `uint256 public lockPeriod`: the minimum amount of time a keyper must stake their SHU tokens
    before they can unstake
-   `uint256 public minimumStake`: the minimum amount of SHU tokens that must be
    staked at the first stake
-   `uint256 public totalSupply`: the amount of shares in circulation.

-   `uint256 public lastUpdateTimestamp`: the last time the contract rewards were
    compounded, i.e the rewards were withdrawn from the rewards distribution contract.

### Mappings

```solidity
struct Stake {
    uint256 amount;
    uint256t shares;
    uint256 timestamp;
    uint256 lockPeriod;
}
```

-   `mapping(address keyper => bool) public keypers`: a mapping from keypers to
    their status. If the keyper is true, they are allowed to stake. If the keyper
    is false, they are not allowed to stake.
-   `mapping(address keyper => Stake[]) public stakes`: a mapping from keypers to
    their stakes. Each keyper can have multiple stakes with different lock periods.
-   `mapping(address keyper => uint256 balance) public balances`: a mapping from
    keypers to their balance of shares.

### Rewards Calculation Mechanismm

-   The rewards are withdrawn from the rewards distribution contract every time
    anyone interacts with state changes functions. This includes staking, unstaking, and claiming rewards.
    As the contract balance of SHU and other reward tokens increases, when the
    keyper decides to claim the rewards, they will get a better conversion rate from
    shares (stkSHU) to the reward token. As the staking token is SHU, when the rewards
    are claimed, the SHU balance of the contract increases, causing a coumpound effect.
-   For unstaking, the keyper also gets the SHU rewards accumulated.
-   The reward earned by a user is proportional to the amount they have
    staked. The more tokens a user stakes, the larger their share of the rewards.
-   As more users stake tokens, the total supply increases. Since the reward rate
    per second is constant, the reward per token decreases. This means each user earns a smaller share of the rewards if more tokens are staked by others. This creates a balance where the total rewards distributed per second remains steady, but the individual rewards depend on the user's share of the total staked amount and for how long they have staked. This way, early stakers are rewarded more than late stakers, incentivizing users to stake early.

### Keyper Functions

#### `stake(uint256 amount)`

-   When staking, the keyper receives shares in exchange for the SHU tokens they stake. The shares represent the keyper's ownership of the total staked amount and are used to calculate the rewards the keyper earns. The more shares a keyper has, the larger their share of the rewards.
-   The caller must have approved the staking contract to transfer `amount` of SHU tokens on their behalf.
-   Only keypers can call this function.
-   A minimum amount of SHU tokens defined by the DAO must be staked at the
    first stake. If the keyper unstakes, for the next stake the amount plus the
    current stake amount must be greater than the minimum.
-   Each stake has an individual lock period that must be respected before the
    keyper can unstake.

#### `unstake(uint256 amount, uint256 stakeId)`

TODO improve description of lockPeriod

-   The shares are burned when the keyper unstakes.
-   The caller must have staked for at least `lockPeriod` for the specific stake.
-   If amount is greater than the user balance, the contract will unstake the
    maximum amount possible.

#### `claimRewards(address rewardToken, uint256 amount)`

-   Claim rewards for a specific reward token.
-   The amount must be less than or equal to the rewards accumulated until the
    last update timestamp.
-   Only the keyper can claim their rewards.
-   The maximum amount of rewards that can be claimed can be calculated by calling
    the `getRewards` function.
-   If caller pass 0 in the `amount` paramater, the contract will claim all the
    caller rewards accumulated until the current timestamp for the specific reward
    token.
-   This function will call the `distributeRewards` function before claiming the
    rewards.
-   The rewardToken must exist in the rewards distribution contract

### `unstakeAndClaim(uint256 amount, uint256 stakeId)`

-   Unstake the SHU tokens to the specified stakeId and claim the SHU rewards.
-   The caller must have staked for at least `lockPeriod` for the specific stake.
-   If amount is greater than the user staked plus the rewards, the contract will unstake the
    maximum amount possible.

#### `claimAllRewards()`

-   Claim all the rewards accumulated until the last update timestamp for all the
    reward tokens.
-   This function will call the `distributeRewards` function before claiming the
    rewards.

### Permissioneless Functions

#### `distributeRewards()`

-   Withdraw the rewards from the rewards distribution contract and compound the
    SHU rewards into the staked amount. As this is beneficial for all keypers,
    this function can be called by anyone.

### Owner Functions (DAO)

#### `setLockPeriod(uint256 newLockPeriod)`

-   The minimum staking period for SHU tokens before they can be unstaked.
-   Measured in seconds.
-   New stakes will have the new lock period.
-   For existing stakes, the lock period will be considered only if the new lock
    period is lower than the current one for that stake. This ensures that the
    keyper can trust that their tokens will never be locked for longer than the
    agreed-upon period when they staked, while also allowing keyper to unstake
    their SHU tokens in emergency situations.
    **TODO: Validade this statement with the DAO**

#### `setRewardsDistribution(address newRewardsDistribution)`

Set the new rewards distribution contract address.

#### `setKeyper(address keyper,bool status)`

Add or remove a keyper.

#### `setMinimumStake(uint256 newMinimumStake)`

Set the new minimum amount of SHU tokens that must be staked by keypers.

### Only callable by the Distribution Contract

#### `addRewardToken(address rewardToken)`

Add a new reward token to the list of reward tokens.

#### `removeRewardToken(uint256 index)`

Remove a reward token from the list of reward tokens.

### View Functions

#### `getStake(address keyper, uint256 stakeId)`

Get the stake info, including:

1. The amount of SHU tokens staked
2. The total of shares for the stake
3. When the keyper can unstake

#### `getStakes(address keyper)`

Get a list of stakes info for a keyper, including:

1. The amount of SHU tokens staked
2. The total of shares for each stake
3. When the keyper can unstake

#### `getRewards(address keyper, address rewardToken)`

Get the amount of the reward token accumulated by `keyper` until the last update
timestamp that the keyper has not claimed yet.

#### `getTotalRewards(address keyper)`

Get a list of all the reward tokens and the amount accumulated by `keyper` until
the last update timestamp that the keyper has not claimed yet.

#### `totalSupply()`

Get the shares supply.

#### `getBalanceOf(address keyper)`

Get the shares balance of a keyper.

#### `getLockPeriod()`

Get the lock period that will be applied to new stakes.

## Rewards Distribution Contract

The rewards distribution contract is responsible for distributing rewards to the
staking contract. The rewards distribution contract is owned by the DAO and
contains the rewards configuration for each reward token.

### Storage Layout

-   `mapping(address rewardToken => RewardConfiguration[] rewardsConfiguration) public rewards`: a
    mapping from reward tokens to the reward configuration.

```solidity
struct RewardConfiguration {
    uint256 emissionRate;
    uint256 finishTimestamp;
}
```

1. The `emissionRate` defines the number of rewards tokens distributed per
   second. This is a fixed rate and determines how many reward tokens the contract
   allocates every second to be distributed to all the keypers.

2. The `finishTimestamp` defines the timestamp when the rewards distribution will stop.

-   `uint256[] public rewardsTokenIndex`: an array of reward tokens index to be
    used to iterate over the reward tokens.

### Owner Functions (DAO)

#### `configureReward(address rewardToken,uint256 emissionRate, uint256 finishTimestamp)`

-   Configure a reward token and the respective emission rate.
-   The reward token must be ERC20 compliant. No native rewards are allowed.
-   If the reward token already exists, the emission rate will be updated.
-   If the reward token does not exist, a new reward token will be added.
-   This function calls the `setRewardToken` function in the staking contract to
    add the reward token to the list of reward tokens.

### Only callable by the Staking Contract

#### `distributionRewards()`

Distribute all the rewards to the staking contract accumulated until `rewardsConfiguration[rewardToken].finishTimestamp`.

#### `distributionRewards(address rewardToken)`

Distribute the rewards for a specific reward token to the staking contract accumulated until `rewardsConfiguration[rewardToken].finishTimestamp`.

### View Functions

#### `getRewardsConfiguration()`

Get an array of reward tokens and their emission rates.

#### `getRewardConfiguration(address rewardToken)`

Get the reward configuration for a specific reward token.

## Protocol Invariants

1. The total amount of SHU tokens staked in the contract must be equal to the
   total amount of SHU tokens staked by each keyper: `totalStaked = sum(stakes[keyper].amount)`.
2. On unstake, `block.timestamp >= stakes[msg.sender].timestamp +
stakes[msg.sender].lockPeriod` if global `lockPeriod` is greater or equal to
   the stake lock period, otherwise `block.timestamp >=
stakes[msg.sender].timestamp + lockPeriod`.
3. On unstake, the withdrawn amount must be less than or equal to `stakes[msg.sender].amount`.
4. `stakes[keyper].amount >= minimumStake` for any keyper who has staked tokens.
5. Functions with access control (onlyOwner) should be callable only by the owner address.
6. `rewardToken` addresses in `rewardEmissionRate` mapping must be valid ERC20 tokens.
