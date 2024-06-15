// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockShu is ERC20 {
    constructor() ERC20("Shu", "SHU") {
        _mint(msg.sender, 5_000_000 * 1e18);
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}
