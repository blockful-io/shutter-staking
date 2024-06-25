## Overview

Enables keypers to stake SHU tokens for a minimum period. In exchange, keypers receive rewards in the form of
SHU. Rewards are automatically compounded when the contract state is updated and can be withdraw at any time.

The architecture consists of two contracts:

1. [Staking Contract](docs/staking-contract.md): The main contract where keypers can stake SHU tokens and claim rewards.
2. [Rewards Distributor Contract](docs/rewards-distributor.md): A contract that distributes rewards to the
   staking contract at a fixed rate per second.

The contracts are designed to be customizable, with adjustable parameters such as the lock period, minimum stake, and reward emission. Additionally, the contracts uses the Transparent Proxy pattern, where only the DAO has the permission to upgrade the contract and call the owner functions defined below.

## Security Considerations

1. The contracts uses the Ownable2Step pattern where only the DAO has the
   permission to upgrade the contract and call the owner functions.
2. The contracts follows the checks-effects-interactions pattern to
   prevent reentrancy attacks.
3. The contracts has 100% unit test coverage
4. The contracts has been deployed to the testnet and integration tests
   have been run.
5. The contracts has integration tests running against the mainnet fork
   to ensure the contract behaves as expected in a real environment.
6. The contracts has been audited by a third-party security firm or audit contest platform.
7. An AST analyzer has been run on the staking contract.
8. There are CI checks in place to ensure the code is formatted correctly and
   the tests pass.

## FAQ

1. Is there a deadline for distributing the rewards?
   No, the rewards distribution will continue until the rewards contract is depleted.

2. Can the stkSHU token be transferred?
   No, the stkSHU token is non-transferable. Keyper can only unstake the SHU
   tokens which will burn the stkSHU tokens.

3. Is the lock period the same for all stakes?
   No, each stake has an individual lock period determined by the current lock period set by the DAO at the time of keyper's stake. The lock period can be updated by the DAO. If the new lock period is shorter than the current one for that stake, the new lock period will be honored. This allows keyper to trust that their tokens will not be locked for longer than the originally agreed-upon period when they staked, and also enables keyper to unstake their tokens in emergency situations.

4. Are the rewards distributed per second or per block?
   Per second.

5. Are the rewards automatically compounded?
   Yes, the rewards are automatically compounded when the contract state is updated, i.e., when anyone interacts with a non-view function.

6. Are the rewards calculated based on individual stakes or the total amount of shares the keyper has?
   The rewards are calculated based on the total amount of shares the keyper
   has. This means that when the keyper claims rewards, they will receive the
   rewards for all their stakes.

7. When unstaking, are the rewards also transferred to the keyper?
   The keyper has the option to choose whether they want to claim the rewards when they unstake. This is the default behavior.

8. Is there a minimum stake amount?
   Yes, there is a minimum amount of SHU tokens that must be staked at the first
   stake. This amount can be set by the DAO. An unstake can never result in a
   balance lower than the minimum stake amount.

## Protocol Invariants [TBD]

1. The total amount of SHU tokens staked in the contract must be equal to the
   total amount of SHU tokens staked by each keyper: `totalStaked = sum(stakes[keyper].amount)`.
2. On unstake, `keyperStake.timestamp + lockPeriod <= block.timestamp` if global `lockPeriod` is greater or equal to the stake lock period, otherwise `keyperStake.timestamp + keyperStake.lockPeriod <= block.timestamp`.
