// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {V4Router} from "@uniswap/v4-periphery/src/V4Router.sol";
import {ReentrancyLock} from "@uniswap/v4-periphery/src/base/ReentrancyLock.sol";
import {IAllowanceTransfer} from "@uniswap/v4-periphery/src/interfaces/IPermit2Forwarder.sol";

/// @title LocalUniversalRouter
/// @notice A DEV-ONLY, minimal stand-in for Uniswap's Universal Router, for local anvil.
///
/// The real Universal Router (and Permit2) exist on Robinhood Chain and any fork of it, but NOT on a
/// bare anvil — its source is not vendored in this repo. Local dev + the simulator run on anvil, so
/// once the launchpad routes every swap through the Universal Router we need SOMETHING at the router
/// address that speaks the exact same calldata. This is that something.
///
/// It implements only the two Universal Router commands the launchpad's *regular* (ecosystem /
/// numeraire / coin↔coin) swaps ever emit:
///   • V4_SWAP        (0x10) — dispatched to the vendored `V4Router` action engine, so the on-chain
///                             swap behaviour is byte-for-byte the real router's for these routes.
///   • PERMIT2_PERMIT (0x0a) — forwards a signed `PermitSingle` to Permit2, exactly as the real
///                             router's Dispatcher does, so ERC-20 inputs are pulled through Permit2.
/// Bridge and external-token (Trading-API) routes are NOT exercised locally, so their commands
/// (WRAP/UNWRAP, V2/V3 swaps, SWEEP, …) are intentionally absent — an unsupported command reverts
/// loudly rather than silently misbehaving.
///
/// This contract must NEVER be deployed to a real network: DeployV1 (mainnet/testnet) points the
/// frontend at the canonical Universal Router; only DeployLocalV1 deploys this.
contract LocalUniversalRouter is V4Router, ReentrancyLock {
    /// @notice Permit2 — the canonical allowance hub ERC-20 inputs are pulled through.
    IAllowanceTransfer public immutable permit2;

    /// @notice `execute` was called after its deadline.
    error TransactionDeadlinePassed();
    /// @notice `commands` and `inputs` had different lengths.
    error LengthMismatch();
    /// @notice A command byte this dev router does not implement (see contract notice).
    error UnsupportedCommand(uint256 command);

    // Universal Router command bytes (universal-router `Commands.sol`). The high bit (0x80) is the
    // "allow revert" flag; the low 6 bits select the command — regular swaps never set the flag.
    uint256 private constant COMMAND_TYPE_MASK = 0x3f;
    uint256 private constant CMD_PERMIT2_PERMIT = 0x0a;
    uint256 private constant CMD_V4_SWAP = 0x10;

    constructor(IPoolManager _poolManager, IAllowanceTransfer _permit2) V4Router(_poolManager) {
        permit2 = _permit2;
    }

    /// @notice Mirror of `UniversalRouter.execute(bytes,bytes[],uint256)` — the only overload the
    ///         frontend encodes. `isNotLocked` records the caller so `msgSender()` (used by SETTLE /
    ///         TAKE and the permit) resolves to the swapping wallet across the PoolManager callback.
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline)
        external
        payable
        isNotLocked
    {
        if (block.timestamp > deadline) revert TransactionDeadlinePassed();
        uint256 numCommands = commands.length;
        if (inputs.length != numCommands) revert LengthMismatch();
        for (uint256 i = 0; i < numCommands; i++) {
            _dispatch(uint8(commands[i]) & COMMAND_TYPE_MASK, inputs[i]);
        }
    }

    function _dispatch(uint256 command, bytes calldata input) internal {
        if (command == CMD_V4_SWAP) {
            // input == abi.encode(bytes actions, bytes[] params) — the V4Router unlock payload.
            _executeActions(input);
        } else if (command == CMD_PERMIT2_PERMIT) {
            (IAllowanceTransfer.PermitSingle memory permitSingle, bytes memory signature) =
                abi.decode(input, (IAllowanceTransfer.PermitSingle, bytes));
            permit2.permit(msgSender(), permitSingle, signature);
        } else {
            revert UnsupportedCommand(command);
        }
    }

    /// @dev Settles ERC-20 inputs the same way the real router does: funds already held by the router
    ///      (an intermediate hop's take) are transferred directly; a user's tokens are pulled through
    ///      Permit2. Native currency never reaches here — `DeltaResolver._settle` pays it with `value`.
    function _pay(Currency token, address payer, uint256 amount) internal override {
        if (payer == address(this)) {
            token.transfer(address(poolManager), amount);
        } else {
            permit2.transferFrom(payer, address(poolManager), uint160(amount), Currency.unwrap(token));
        }
    }

    /// @dev The actions engine's notion of the swapping wallet — our reentrancy-lock caller.
    function msgSender() public view override returns (address) {
        return _getLocker();
    }

    /// @dev An intermediate `TAKE` of native ETH to this router (coin↔coin via ETH) lands here.
    receive() external payable {}
}
