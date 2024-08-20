## Overview

Enables users to stake SHU tokens. In exchange, users receive rewards in the form of
SHU. The rewards can be claimed at any time.

The architecture consists of two contracts:

1. [Staking Architecture](docs/staking-architecture.md): A contract that keypers can stake SHU tokens and claim rewards.
2. [Delegate Architecture](docs/delegate-architecture.md): A contract that allows users to stake and delegate their SHU tokens to a keyper.
3. [Rewards Distributor Architecture](docs/rewards-distributor.md): A contract
   that distributes rewards to the staking and delegate contract at a fixed rate per second.

## Security Considerations

1. The contracts uses the Ownable pattern where only the DAO contract has the
   permission to call the owner functions.
2. The Staking and DelegateStaking contracts are TransparentUpgradeableProxy
   contracts, which means that the implementation can be upgraded by the proxy
   owner.
3. The contracts follows the checks-effects-interactions pattern to
   prevent reentrancy attacks.
4. The code has been tested with unit, integration and fuzzing tests.
5. The contracts has been audited by a independent auditor.
6. An AST analyzer has been run.
7. There are CI checks in place to ensure the code is formatted correctly and
   the tests pass.

## FAQ

1. Is there a deadline for distributing the rewards?
   No, the rewards distribution will continue until the rewards contract is depleted.

2. Can the sSHU/dSHU token be transferred?
   No, the sSHU token is non-transferable. Keyper can only unstake the SHU
   tokens which will burn the sSHU tokens.

3. Is the lock period the same for all stakes?
   No, each stake has an individual lock period determined by the current lock
   period set by the DAO at the time of user's stake. The lock period can be
   updated by the DAO. If the new lock period is shorter than the current one
   for that stake, the new lock period will be honored. This allows users to
   trust that their tokens will not be locked for longer than the originally
   agreed-upon period when they staked, and also enables them to unstake their tokens in emergency situations.

4. Are the rewards distributed per second or per block?
   Per second.

5. Are the rewards calculated based on individual stakes or the total amount of shares the user has?
   The rewards are calculated based on the total amount of shares the users
   has. This means that when the keyper claims rewards, they will receive the
   rewards for all their stakes.

6. Is there a minimum stake amount for keypers?
   Yes, there is a minimum amount of SHU tokens that must be staked at the first
   stake. An unstake can never result in a balance lower than the minimum stake amount.
   If the Owner is compromised, they could set the minimum stake amount very
   high, which would prevent keypers from unstaking their tokens. By staking SHU
   through the Staking contract, keypers trust that the DAO will not set the
   minimum stake amount to an unreasonable value.

## Protocol Invariants

1. On unstake, `keyperStake.timestamp + lockPeriod <= block.timestamp` if global `lockPeriod` is greater or equal to the stake lock period, otherwise `keyperStake.timestamp + keyperStake.lockPeriod <= block.timestamp`.
2. If `some(keyperStakes(keyper).length()) > 0` then `nextStakeId` != 0;
3. amount when staking is greater than 0.
4. staking never result in a depositor's zero sSHU balance.
5. withdraw must burn at least the minimim amount of sSHU needed to remove the
   SHU from the pool.
