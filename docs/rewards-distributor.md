# Rewards Distribution Contract

The rewards distribution contract is responsible for distributing rewards to the
staking and delegate contract. The rewards distribution contract is owned by the DAO and
contains the rewards emission rate for each receiver, i.e either the staking or
delegate contract.

## Storage Layout

-   `mapping(address receiver => RewardConfiguration configuration) public
rewardConfigurations`: a mapping from the receiver address to the reward configuration.

```solidity
struct RewardConfiguration {
    uint256 emissionRate; // emission per second
    uint256 lastUpdate; // last update timestamp
}
```

1. The `emissionRate` defines the number of rewards tokens distributed per
   second. This is a fixed rate and determines how many reward tokens the contract
   allocates every second to be distributed to all the stakers in the receiver contract.

2. The `lastUpdate` timestamp is the last time the rewards were distributed to the
   receiver contract. This timestamp is used to calculate the rewards accumulated
   since the last update.

## Owner Functions (DAO)

### `setRewardConfiguration(address receiver, uint256 emissionRate)`

Add, update or stop distributing rewards to a receiver. The emission rate is
the number of reward tokens distributed per second. This function can only be
called by the Owner (DAO). If the emission rate for the specified receiver is not 0,
the function will update the `emissionRate`. If the owner wants to stop
distributing rewards, they should set the emission rate to 0.

## Permissionless Functions

### `distributionRewards()`

Distribute all the rewards to the receiver contract accumulated until from the
`lastUpdate` timestamp to the current timestamp. If the msg.sender is not one of
the receivers, the function will revert.

## View Functions

### `getRewardConfiguration(address receiver)`

Get the reward configuration for a specific receiver.
