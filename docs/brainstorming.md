# Separate Accounting Rewards from Staking

In order to allow keypers to claim before the `lockPeriod` has passed but yet
have the auto-compounding feature, we need to separate the rewards accounting
from the staking accounting. This way, keypers can claim their rewards at any
time while the initial staked amount remains locked for the `lockPeriod`.

## Modifications

- Include SHU tokens rewards to the `unclaimedRewards` mapping
- Modify claimRewards logic to allow claiming SHU rewards. When SHU
rewards are claimed this function must also decrease from the `staked`
accounting and `totalStaked`. The next snapshot will be calculated
based on the new `totalStaked` and new keyper staked amount.

