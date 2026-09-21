// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDC
/// @notice Local/testnet stand-in for USD Coin: a plain 6-decimal ERC20 whose
///         entire supply is minted to the deployer at construction. Used only
///         to seed a WETH/mUSDC Uniswap V2 pool so frontends can derive an
///         on-chain ETH->USD price from getReserves(), exactly as they would
///         from a production WETH/USDC pool. No owner, no mint, no admin.
contract MockUSDC is ERC20 {
    constructor(uint256 initialSupply) ERC20("Mock USD Coin", "mUSDC") {
        _mint(msg.sender, initialSupply);
    }

    /// @dev Real USDC uses 6 decimals; mirror that so price math matches prod.
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}
