# Auto-compounding feature with rewards claimable at any time

What must be done in order to allow keypers to claim before the `lockPeriod` has passed but yet
have the auto-compounding feature? Effectively allowing keypers to claim their rewards at any
time while the initial staked amount remains locked for the `lockPeriod`.

## Storage Modifications

Include SHU tokens rewards to the `unclaimedRewards` mapping.

## Functions Modifications

Modify `claimRewards` logic to allow claiming SHU rewards. When SHU
rewards are claimed this function must also decrease from the `staked`
accounting and `totalStaked`. The next snapshot will be calculated
based on the new `totalStaked` and new keyper staked amount.

# Individual lock periods for each stake

What must be done in order to allow keypers to have individual lock periods for
each stake?

The following modifications are required:

## Storage Modifications

Currently, the stake mapping is as follows:

```solidity
struct Stake {
    uint256 amount;
    uint256 stakedTimestamp;
    uint256 lockPeriod;
    uint256 lastUpdateTimestamp;
}

mapping(address keyper => Stake staked) public stakes
```

The stake mapping must be modified to have an array of stakes for each keyper:

```solidity
mapping(address keyper => Stake[] stakes)) public stakes
```

Additionaly, a new mapping must be included to keep track of `stakeIds` to their
respective owners.

```solidity
mapping(uint256 stakeId => address keyper) public stakeOwners
```

Futhermore, the `unclaimedRewards` mapping must be modified to include the
`stakeId` as a parameter.

```solidity
mapping(address keyper => mapping(uint256 stakeId => uint256 rewards)) public unclaimedRewards
```

## Functions Modifications

1. `stake`: include a `stakeId` parameter. If the `stakeId` 0, a new stake will be appended to the keyper's stakes array, otherwise, the provided `stakeId` must be used and the `amount` increased. If the `stakeId` does not exist, the function must revert.

2. `unstake`: include a `stakeId` parameter. If the `stakeId` does not exist, the function must revert.

3. `unstakeAll`: new function to unstake all stakes for a keyper. 

4. `claimRewards`: include a `stakeId` parameter. If the `stakeId` does not
   exist, the function must revert. The rewards must be calculated based on the
    `stakeId` provided.
   











