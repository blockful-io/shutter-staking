# Staking Contract Architecture

## Overview

The staking contract is a smart contract that allows keypers to stake SHU tokens
effectively locking them up for a period of time. In return, keypers receive rewards
in the form of any ERC20 token the DAO decides to distribute, such as SHU or WETH.
The staking contract is designed to be flexible and upgradable using the
Transparant Proxy pattern where only the DAO has the permission to upgrade.

### Rewards Formula 

The rewards are calculated using the following formula:

``` solidity
uint256 pendingRewards = (block.timestamp - userStake.lastStakedTime) * rewardRate * userStake.amount;
```

Where `lastStakedTime` is the last time the keyper staked, `rewardRate` is the
emission rate of the reward token and `amount` is the amount of SHU tokens staked.

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
keyper mapping can call this function. If a keyper call this function multiple
times, the new stake will be added to the existing stake and the rewards will be
accumulated from the last time the keyper staked. The tokens will be locked for
`lockPeriod` seconds.

### `unstake(uint256 amount)`

Unstake `amount` of SHU tokens. The caller will receive their staked SHU tokens
back and any rewards they have accumulated. The caller must have staked for at
least `lockPeriod` before they can unstake.

### `claimRewards()`

Claim any rewards the caller has accumulated. The contract uses auto compounding
and as a result the caller will only receive the rewards they have accumulated
after `lockPeriod` has passed.

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

### `getStake(address keyper)`

Get the amount of SHU tokens staked by `keyper`.

### `getRewards(address keyper)`

Get the amount of rewards accumulated by `keyper` until the current timestamp.

### `getTotalStaked()`

Get the total amount of SHU tokens staked.

### `getTotalRewards()`

Get the total amount of rewards accumulated.

### `getLockPeriod()`

Get the lock period.

### `getRewardsConfiguration()`

Get an array of reward tokens and their emission rates.






