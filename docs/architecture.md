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

### `stake(uint256 amount)`

Stake `amount` of SHU tokens. The caller must have approved the staking contract
to transfer `amount` of SHU tokens on their behalf. Only addresses beloging to the 
keyper mapping can call this function. Each call to this function will create a
new stake with its own lock period.

### `unstake(uint256 stakeId)`

Unstake the SHU tokens associated with `stakeId`. The caller will receive their
staked SHU tokens back and any rewards they have accumulated for that specific
stake. The caller must have staked for at least the stake `lockPeriod` before 
they can unstake.

### `claimRewards(uint256 stakeId)`

Claim any other token rewards excluding the SHU tokens rewards for the stake
`stakeId`. Only the keypeir can claim their rewards.

## Owner Functions (DAO)

### `setLockPeriod(uint256 newLockPeriod)`

Set the new lock period. The lock period is the minimum amount of time a keyper 
must stake their SHU tokens before they can unstake. The lock period is measured 
in seconds. If the DAO decides to change the lock period, the new lock period
will only apply to new stakes.

### `setRewardToken(address newRewardToken,uint256 emissionPerSecond)`

Set the new reward token and the emission rate. The reward token must be ERC20 compliant.
If the reward token already exists, the emission rate will be updated. If the
reward token does not exist, a new reward token will be added.

### `setKeyper(address keyper,bool status)`

Add or remove a keyper.

### `setStakingToken(address newStakingToken)`

Set the staking token. The staking token must be ERC20 compliant.
If the DAO upgrades the SHU token to a new contract, the DAO can update the
staking token calling this function.

## View Functions

### `getStake(address keyper, uint256 stakeId)`

Get the amount of SHU tokens staked by `keyper` for the specified `stakeId`. 

### `getRewards(address keyper, uint256 stakeId)`

Get the amount of ERC20 rewards accumulated by `keyper`  for the specified `stakeId`
until the current timestamp excluding the SHU tokens rewards.

### `getTotalStaked(address keyper)`

Get the total amount of SHU tokens staked by `keyper` including the SHU rewards
accumulated until the current timestamp. This function is useful for keypers to
know how much they have staked considering all their stakes and how much SHU
they have earned in rewards.

### `getTotalStaked()`

Get the total amount of SHU tokens staked including the SHU rewards accumulated
until the current timestamp as the SHU rewards are compounded.

### `getLockPeriod()`

Get the lock period.

### `getRewardsConfiguration()`

Get an array of reward tokens and their emission rates.

### `getUserStakes(address keyper)`

Get an array of stake IDs for a given keyper.

### `getUnlockedStakes(address keyper)`

Get an array of stake IDs for a given keyper that have passed the lock period.

## Implementation Details

### Storage

Each user will have multiple stakes, each with a unique identifier (stakeId).
The contract will maintain a mapping from user addresses to an array of stakes,
where each stake includes the amount, lock period and the staked time.
When a user stakes, a new stake is created and appended to their array of stakes.
When a user unstakes or claims rewards, they must specify the stakeId to
identify the stake they want to unstake or claim rewards from.

```solidity
struct Stake {
    uint256 amount;
    uint256 stakedTime;
    uint256 lockPeriod;
}

mapping(address keypeir => Stake[]) public userStakes;
```

### Rewards Formula 

The rewards are calculated using the following formula:

``` solidity
uint256 currentRewards = (block.timestamp - userStake.stakedTime) * rewardRate * userStake.amount;
```

Where `rewardRate` is the emission rate of the reward token. Each reward token
will have its own emission rate. The rewards are calculated for each stake
individually. The rewards for other ERC20 tokens are not compounded, meaning the
meaning the rewards are calculated from the time the stake was created until the
current timestamp.
 








