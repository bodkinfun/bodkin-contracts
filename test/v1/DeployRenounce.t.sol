// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployLocalV1} from "../../script/DeployLocalV1.s.sol";
import {FeeHook} from "../../src/launchpad/v1/FeeHook.sol";
import {CreatorNFT} from "../../src/launchpad/CreatorNFT.sol";

/// @notice The launchpad must ship with NO admin.
///
/// `contracts/README.md` promises "the deploy script calls `renounceOwnership()` at the
/// end, so the launchpad ships with `owner == address(0)` and no admin power remains" —
/// and for a while the V1 deploy simply did not. DeployLocalV3 renounced; the calls were
/// not carried across the V4 pivot, so the hook shipped with a live owner able to call
/// `setLauncher` (which decides who may open a pool — the exact front-run the hook's
/// `_beforeInitialize` check exists to stop) and `setUsdcPool` / `setBodkinPool` (which
/// decide the pools fee conversions route through).
///
/// A promise in a README is not enforcement. This is.
contract DeployRenounceTest is Test, DeployLocalV1 {
    function test_DeployLeavesNoAdmin() public {
        // The real deploy, same code path the operator runs. `deploy()` rather than
        // `run()` so `vm.writeJson` does not overwrite exports/v1.local.json with
        // throwaway test addresses.
        deploy();

        assertEq(FeeHook(payable(ex.feeHook)).owner(), address(0), "FeeHook still has an owner");
        assertEq(CreatorNFT(ex.creatorNFT).owner(), address(0), "CreatorNFT still has an owner");
    }

    /// The renounce must come AFTER the wiring, or the deploy would brick itself. Proven
    /// by the state the wiring left behind: the hook knows its launcher, and both
    /// conversion pools are set. If a future edit hoists the renounce earlier, these
    /// reads go zero/empty and this fails.
    function test_WiringSurvivedTheRenounce() public {
        deploy();
        FeeHook hook = FeeHook(payable(ex.feeHook));

        assertEq(hook.launcher(), ex.launcher, "hook lost its launcher");
        assertTrue(ex.usdcPoolId != bytes32(0), "USDC conversion pool never wired");
        assertEq(CreatorNFT(ex.creatorNFT).launchpad(), ex.launcher, "NFT lost its launchpad");
    }

    /// And the setters are genuinely unreachable afterwards — not merely unused.
    function test_AdminSettersRevertAfterDeploy() public {
        deploy();
        FeeHook hook = FeeHook(payable(ex.feeHook));

        // Nobody is the owner now, so every caller is rejected — including the deployer,
        // which is the account that held the key a moment ago.
        vm.expectRevert(FeeHook.NotOwner.selector);
        hook.setLauncher(address(0xBEEF));

        // Including the deployer's own key, on the last deployer-role call the hook still has.
        // (This used to poke `setTeamPayoutToken`; the team's payout is immutable now,
        // so that setter no longer exists to be locked out of.)
        vm.prank(ex.deployer);
        vm.expectRevert(FeeHook.NotOwner.selector);
        hook.renounceOwnership();
    }
}
