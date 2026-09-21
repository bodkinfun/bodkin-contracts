// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

/// Calls `poolManager.unlock` from its OWN CONSTRUCTOR.
contract UnlocksInConstructor is IUnlockCallback {
    constructor(IPoolManager manager) {
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external pure returns (bytes memory) {
        return "";
    }
}

/// @notice WHY LauncherV1 CANNOT LAUNCH A TOKEN IN ITS CONSTRUCTOR.
///
/// This looks like a natural idea — have the launcher create the protocol token
/// (BODKIN) as it is deployed, so the burn target is set from block one and can never
/// be mis-wired by a deploy script. It cannot work, and this test is here so nobody
/// spends a day rediscovering that.
///
/// Every step of a launch that touches the pool — adding the single-sided liquidity,
/// running the dev buy — goes through `poolManager.unlock(...)`, and the manager
/// performs that work by CALLING BACK into the caller (`unlockCallback`). During a
/// constructor the contract's code is not deployed yet, so the manager's call lands on
/// an address with no code: it returns empty data, the manager tries to decode
/// `bytes memory` from it, and the whole thing reverts.
///
/// The failure is at least LOUD (the deploy dies rather than producing a launcher with
/// an empty pool), but it is absolute: no amount of CREATE2 pre-wiring of the NFT and
/// the hook changes it, because the blocker is the caller's own missing code.
///
/// The workable shape, if this is ever wanted again: keep the parameters in the
/// constructor, and do the launch in a one-shot `launchProtocolToken()` that runs in a
/// second transaction, with `launch()` refusing to work until it has. That gives the
/// same guarantee — the protocol token is provably the first launch, enforced in code
/// rather than by script ordering — without asking a constructor to do what a
/// constructor cannot.
contract ConstructorUnlockTest is Test {
    function test_PoolWorkInAConstructorReverts() public {
        PoolManager manager = new PoolManager(address(this));
        vm.expectRevert();
        new UnlocksInConstructor(IPoolManager(address(manager)));
    }
}
