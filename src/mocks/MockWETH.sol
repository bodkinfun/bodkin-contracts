// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockWETH
/// @notice Local/testnet stand-in for canonical WETH9: `deposit()` (and `receive`) mint WETH
///         1:1 for native ETH, `withdraw()` burns it back. Lets a deploy wire a WETH address
///         (the FeeHook constructor arg) and seed V4 (WETH, token) creator-payout pools where
///         mainnet has real ones. On mainnet/testnet the REAL WETH is used instead (env WETH).
contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "MockWETH: withdraw");
    }
}
