// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DelegateStaking} from "src/DelegateStaking.sol";

contract DelegateStakingHarness is DelegateStaking {
    function exposed_nextStakeId() external view returns (uint256) {
        return nextStakeId;
    }
}
