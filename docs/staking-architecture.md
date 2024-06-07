# Staking Architecture

## Overview

The staking contract is a smart contract that enables keypers to stake SHU
tokens for a minimum period. In exchange, keypers receive rewards in the form of
any ERC20 token that the DAO chooses to distribute, such as SHU or WETH. SHU
rewards are automatically compounded when the keyper state is updated and
cannot be withdrawn, effectively increasing the rewards paid to the keyper due to the compounding effect.

The staking contract is designed to be customizable, with adjustable parameters that the DAO can change, such as the lock period, minimum stake, and reward emission. Additionally, the contract uses the Transparent Proxy pattern, with only the DAO having the authority to make upgrades.

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

## Keyper Functions

### `stake(uint256 amount)`

* The caller must have approved the staking contract to transfer `amount` of SHU tokens on their behalf.
* Only keypers can call this function.
* A minimum amount of SHU tokens defined by the DAO must be staked.
* If the keyper has already staked, the lock period will be the same as the
first stake.

### `unstake(uint256 amount)`

* The caller must have staked for at least `lockPeriod` before they
  can unstake
* The maximum amount of SHU tokens that can be unstaked is the amount staked
  plus the rewards accumulated until the current timestamp.

### `claimRewards(address rewardToken, uint256 amount)`

* Claim any other token rewards excluding the SHU tokens rewards as the SHU tokens
rewards are auto compounded. 
* Only the keyper can claim their rewards.
* The maximum amount of rewards that can be claimed can be calculated by calling
  the `calculateRewards` function.
* If caller pass 0 in the `amount` paramater, the contract will claim all the
  caller rewards accumulated until the current timestamp.

## Owner Functions (DAO)

### `setLockPeriod(uint256 newLockPeriod)`

* The minimum staking period for SHU tokens before they can be unstaked.
* Measured in seconds.
* If a keyper has 0 SHU tokens staked, the new lock period will apply to the next stake.
* If a keyper has a staked balance greater than 0 and the lock period is greater than the current period, the keyper's lock period will remain the same. This ensures that the keyper can trust that their tokens will never be locked for longer than the agreed-upon period when they staked.
*  If a keyper has a staked balance greater than 0 and the new lock period is less than the current one, the new lock period will be considered and the keyper will be allowed to unstake before. This is useful in emergency situations where the DAO needs to reduce the lock period to allow keypers to unstake their SHU tokens.

### `configureReward(address rewardToken,uint256 emissionRate)`ewards

* Configure a reward token and the respective emission rate.
* The reward token must be ERC20 compliant. No native rewards are allowed.
* If the reward token already exists, the emission rate will be updated.
* If the reward token does not exist, a new reward token will be added.

### `setKeyper(address keyper,bool status)`

Add or remove a keyper.

### `setMinimumStake(uint256 newMinimumStake)`

Set the new minimum amount of SHU tokens that must be staked by keypers.

## View Functions

### `getStake(address keyper)`

Get the amount of SHU tokens staked by `keyper`, this includes the SHU rewards
accumulated until the keyper last update timestamp.

### `getRewards(address keyper)`

Get the amount of ERC20 rewards accumulated by `keyper` until the last update
timestamp, excluding the SHU tokens rewards as they are auto compounded.

### `getTotalStaked()`

Get the total amount of SHU tokens staked for all the keyper, 
including the compounded SHU rewards.

### `getLockPeriod()`

Get the lock period.

### `getRewardsConfiguration()`

Get an array of reward tokens and their emission rates.

## Contract Storage

### Immutable Variables

* `stakingToken`: the SHU token address

The staking token must be immutable. If the DAO changes the staking token, the
keypers will not be able to redeem their old stakes. 
If the DAO upgrades the SHU token to a new contract, it must also redeploy the staking contract and ask the keypers to migrate their stakes to the new contract.

### Mutable Variables

* `uint256 public lockPeriod`: the minimum amount of time a keyper must stake their SHU tokens
  before they can unstake
  
* `uint256 public minimumStake`: the minimum amount of SHU tokens that must be
  staked at the first stake
  
* `uint256 public totalStaked`: the total amount of SHU tokens staked from all
  keypers including the compounded SHU rewards
  
* `uint256 public lastUpdateTimestamp`: the last time cumulativeRewards were updated
  
### Mappings 

```solidity
struct Stake {
    uint256 amount;
    uint256 stakedTimestamp;
    uint256 lockPeriod;
    uint256 lastUpdateTimestamp;
}
```

* `mapping(address keyper => bool) public keypers`: a mapping from keypers to
their status. If the keyper is true, they are allowed to stake. If the keyper
is false, they are not allowed to stake.
* `mapping(address keyper => Stake staked) public stakes`: a
mapping from keypers to the amount of SHU tokens they have staked and the
accumulated rewards until the `lastUpdateTimestamp`.
* `mapping(address rewardToken => uint256 emissionRate) public rewardEmissionRate`: a
mapping from reward tokens to their emission rates.
* `mapping(address keyper => (address rewardToken => uint256 rewards)) public
unclaimedRewards`: a mapping from keypers to their rewards until the
`stakes[keyper].lastUpdateTimestamp` excluding the SHU tokens rewards.
When a keyper claims rewards, the rewards claimed are subtracted from this mapping.
* `mapping(address rewardToken => uint256 rewardPerToken) public
  cumulativeRewards`: a mapping from reward tokens to the accumulated rewards
  per token from the beginning of the contract until the `lastUpdateTimestamp`.
  By maintaining a cumulative reward per token, the contract can easily
  calculate how much reward each staked token has earned over time. This is
  essential for fairly distributing rewards to users based on how long and how
  much they have staked.
* `mapping(address keyper => (address rewardToken => uint256)) public
  keyperLastCumulativeRewards`: a mapping from keypers to the cumulative
  rewards per token at the time of their last update.
  
## Rewards Calculation Mechanismm

* The rewards are recalculate and accrued every time the keyper interacts with
state changes functions. This includes staking, unstaking, and claiming rewards. 
* The `rewardEmissionRate` defines the number of rewards tokens distributed per
second. This is a fixed rate and determines how many reward tokens the
contract allocates every second to be distributed to all the keypers.
* The reward earned by a user is proportional to the amount they have
staked. The more tokens a user stakes, the larger their share of the rewards.
* As more users stake tokens, the total supply increases. Since the reward rate
per second is constant, the reward per token decreases. This means each user earns a smaller share of the rewards if more tokens are staked by others. This creates a balance where the total rewards distributed per
second remains steady, but the individual rewards depend on the user's share
of the total staked amount and for how long they have staked. This way, early stakers are rewarded more than
late stakers, incentivizing users to stake early.

Rewards are calculated using the following formula: 

1. First, we must calculate the reward per token for each reward token of the
current snapshot, i.e how much reward each staked token has earned since the
last update. This is done by taking the elapsed time since the last update, multiplying it by the reward rate, and then dividing by the total supply of staked tokens.

```solidity
uint256 rewardPerToken = totalStaked != 0 ? (cumulativeRewards[rewardToken] +
((block.timestamp - lastUpdateTimestamp) * rewardEmissionRate[rewardToken] *
10***rewardToken.decimals()) / totalStaked) : cumulativeRewards[rewardToken];
```

Where `rewardEmissionRate[rewardToken]` is the emission rate of the reward token
and `totalStaked` is the total amount of SHU tokens staked by all keypers.
If the total staked amount is 0, no new rewards are distributed.

2. Then, we calculate the current keyper rewards, i.e how much reward a
   keyper has earned since their last update, for each reward token as follows:

```solidity
uint256 snapshotRewards = (stakes[keyper].amount * (rewardPerToken - keyperLastCumulativeRewards[keyper][rewardToken])) / (10**rewardToken.decimals());
```

For non-staking token rewards, the snapshot rewards are
added to the `unclaimedRewards` mapping. For staking token rewards, the snapshot
rewards are added to the `staked` mapping and `totalStaked` is increased.
 
## Protocol Invariants

1. The total amount of SHU tokens staked in the contract must be equal to the
total amount of SHU tokens staked by each keyper: `totalStaked = sum(stakes[keyper])`.
2. The total amount of rewards distributed to keypers must be equal or less to
   the cumulative rewards per token times the total staked amount: `sum(unclaimedRewards[keyper]) <= sum(stakes[keyper] * rewardPerToken)`.
3. On unstake, `block.timestamp >= stakes[msg.sender].stakedTimestamp +
   stakes[msg.sender].lockPeriod` if global `lockPeriod` is greater or equal to
    the stake lock period, otherwise `block.timestamp >= stakes[msg.sender].stakedTimestamp + lockPeriod`.
4. On unstake, the withdrawn amount must be less than or equal to `stakes[msg.sender].amount`.
5. `staked[keyper] >= minimumStake` for any keyper who has staked tokens.
6. `cumulativeRewards` should accurately reflect the time-weighted rewards
   accrued since the beginning of the contract.
7. Functions with access control (onlyOwner) should be callable only by the owner address.
8. `rewardToken` addresses in `rewardEmissionRate` mapping must be valid ERC20 tokens.
12. If `block.timestamp` is equal to `lastUpdateTimestamp`, then
    `rewardsPerToken(rewardToken) == cumulativeRewards[rewardToken]`.


