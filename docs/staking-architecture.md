# Staking Contract Architecture

## Overview

The staking contract is a smart contract that allows keypers to stake SHU tokens
effectively locking them up for a period of time. In return, keypers receive rewards
in the form of any ERC20 token the DAO decides to distribute, such as SHU or WETH.
The staking contract is designed to be flexible and upgradable using the
Transparant Proxy pattern where only the DAO has the permission to upgrade.

### Security Considerations

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

### `stake(uint256 amount)`: stake `amount` of SHU tokens

* The caller must have approved the staking contract.
to transfer `amount` of SHU tokens on their behalf.
* Only keypers can call this function.
* A minimum amount of SHU tokens defined by the DAO must be staked.
* If the keyper has already staked, the lock period will be the same as the
first stake.

### `unstake(uint256 amount)`: unstake the amount of SHU tokens

* The caller must have staked for at least the stake `lockPeriod` before they
  can unstake
* The maximum amount of SHU tokens that can be unstaked is the amount staked
  plus the rewards accumulated until the current timestamp.

### `claimRewards(address rewardToken, uint256 amount)`: claim rewards

* Claim any other token rewards excluding the SHU tokens rewards as the SHU tokens
rewards are auto compounded. 
* Only the keyper can claim their rewards.
* The maximum amount of rewards that can be claimed can be calculated by calling
  the `calculateRewards` function.
* If amount is 0, the caller will claim all the rewards accumulated until the
  current timestamp.

## Owner Functions (DAO)

### `setLockPeriod(uint256 newLockPeriod)`: set the lock period

* The minimum amount of time a keyper must stake their SHU tokens before they can unstake
* Measured in seconds
* The new lock period will apply as follows:
    * If keyper has 0 SHU tokens staked, the new lock period will apply to the
      next stake.
    * If keyper has a staked balance greater than 0 and the lock period is
      greater than the current the keyper lock period will remain the same.
      This way the keyper can trust that their tokens will never be locked for
      more time than they agreed when they staked.
    * If a keyper has a staked balance greater than 0 and the new lock period is 
      less than the current, the new lock period will be considered and
      consequently the keyper will be allowed to unstake before. This is useful
      in emergency situations where the DAO needs to reduce the lock period to
      allow keypers to unstake their SHU tokens.

### `configureReward(address rewardToken,uint256 emissionRate)`: configure rewards

* Configure a reward token and the emission rate.
* The reward token must be ERC20 compliant. No native rewards are allowed.
* If the reward token already exists, the emission rate will be updated.
* If the reward token does not exist, a new reward token will be added.

### `setKeyper(address keyper,bool status)`: add or remove a keyper.

### `setMinimumStake(uint256 newMinimumStake)`

Set the new minimum amount of SHU tokens that must be staked. 

## View Functions

### `getStake(address keyper)`

Get the amount of SHU tokens staked by `keyper`, including the SHU rewards accumulated until the current timestamp.

### `getRewards(address keyper)`

Get the amount of ERC20 rewards accumulated by `keyper` until the current timestamp excluding the SHU tokens rewards.

### `getTotalStaked(address keyper)`

Get the total amount of SHU tokens staked by `keyper` including the SHU rewards
accumulated until the current timestamp. This function is useful for keypers to
know how much they have staked considering all their stakes and how much SHU
they have earned in rewards.

### `getTotalStaked()`

Get the total amount of SHU tokens staked for all the keyper, 
including the SHU rewards accumulated until the current timestamp as the SHU rewards are compounded.

### `getLockPeriod()`

Get the lock period.

### `getRewardsConfiguration()`

Get an array of reward tokens and their emission rates.

### `getUserStakes(address keyper)`

Get an array of stake IDs for a given keyper.

### `getUnlockedStakes(address keyper)`

Get an array of stake IDs for a given keyper that have passed the lock period.

## Contract Storage

### Immutable Variables

* `stakingToken`: the SHU token address

The staking token must be immutable because if we allow the DAO to change the
staking token, the keypers will not be able to redeem their old stakes if the
staking token has changed. If the DAO upgrades the SHU token to a new contract,
then the DAO also must to redeploy the staking contract and ask the keypers to
migrate their stakes to the new contract.

### Mutable Variables

* `uint256 public lockPeriod`: the minimum amount of time a keyper must stake their SHU tokens
  before they can unstake
  
* `uint256 public minimumStake`: the minimum amount of SHU tokens that must be
  staked
  
* `uint256 public totalStaked`: the total amount of SHU tokens staked from all
  keypers including the SHU rewards accumulated until the current timestamp
  
* `uint256 public lastUpdateTimestamp`: the last time the contract was updated
  and the rewards were calculated
  
### Mappings 

* `mapping(address keyper => bool) public keypers`: a mapping from keypers to
their status. If the keyper is true, they are allowed to stake. If the keyper
is false, they are not allowed to stake.
* `mapping(address keyper => uint256 balance) public staked`: a
mapping from keypers to the amount of SHU tokens they have staked including
* `mapping(address rewardToken => uint256 emissionRate) public rewardEmissionRate`: a
mapping from reward tokens to their emission rates.
* `mapping(address keyper => (address rewardToken => uint256 rewards)) public
unclaimedRewards`: a mapping from keypers to their rewards for each stake until the
`lastUpdateTimestamp` excluding the SHU tokens rewards as the SHU tokens
rewards are auto compounded. When a keyper claims rewards, the rewards claimed
are subtracted from this mapping.
* `mapping(address keyper => (address rewardToken => uint256 rewards)) public paidRewards`: a
mapping from keypers to their rewards for each already paid until the
`lastUpdateTimestamp`. Paid here does not mean the rewards were claimed, but
that the rewards were already calculated and added to the `unclaimedRewards`
* `mapping(address keyper => uint256 stakedTimestamp) public stakedTimestamp`: a
mapping from keypers to the timestamp when they staked their SHU tokens for
the first time. This is used to calculate the lock period.
* `mapping(address rewardToken => uint256 rewardPerToken) public
  currentRewardPerToken`: a mapping from reward tokens to the reward per token to
  distribute from the `lastUpdateTimestamp` until the current timestamp.
  
## Rewards Formula 

The rewards are recalculate and accrued every time the keyper interacts with the contract.
This includes staking, unstaking, and claiming rewards. 

The rewards are calculated using the following formula: 

First, we must calculate the reward per token for each reward token of the
current snapshot . The reward per token is calculated as follows:

```solidity
uint256 rewardPerToken = totalStaked != 0 ? currentRewardPerToken[rewatdToken] +
((block.timestamp - lastUpdateTimestamp) * rewardEmissionRate[rewardToken] *
1e18) / totalStaked : currentRewardPerToken[rewardToken];
```

Where `rewardEmissionRate[rewardToken]` is the emission rate of the reward token and `totalStaked` is the total amount of SHU tokens staked by all keypers.

Then, we calculate the keyper rewards for each reward token as follows:

```solidity
uint256 snapshotRewards = (staked[keyper] * (rewardPerToken - paidRewards[rewardToken])) / 1e18;
```

Where `paidRewards[rewardToken]` is the rewards already calculate to the keyper
for the reward token. For non-staking token rewards, the snapshot rewards are
added to the `unclaimedRewards` mapping. For staking token rewards, the snapshot
rewards are added to the `staked` mapping.
 
## Protocol Invariants

1. The total amount of SHU tokens staked by all keypers must be equal to the
total amount of SHU tokens staked by each keyper.
2. The rewards distributed across all keypers must be equal to the
total amount of rewards distributed to each keyper.
3. The total amount of rewards distributed to all keypers must be equal to the
total amount of rewards distributed to each reward token.
4. The rewards distributed across all keypers should equal the accumulated rewards per token times the staked amount.
5. The total amount of SHU tokens staked by all keypers must be equal to the total
amount of SHU tokens staked by each keyper plus the total amount of SHU
tokens distributed as rewards to each keyper until the `lastUpdateTimestamp`.
6. On unstake, `block.timestamp >= stakedTimestamp[msg.sender] + lockPeriod`.
7. On unstake, the withdrawn amount must be less than or equal to `staked[msg.sender]`.
8. `staked[keyper] >= minimumStake` for any keyper who has staked tokens.
9. `currentRewardPerToken` should accurately reflect the time-weighted reward
accumulation rate based on the `rewardEmissionRate`, `totalStaked`, and the
`lastUpdateTimestamp`.
9. Functions with access control (onlyOwner) should be callable only by the owner address.
10. `rewardToken` addresses in `rewardEmissionRate` mapping must be valid ERC20 tokens.


 





