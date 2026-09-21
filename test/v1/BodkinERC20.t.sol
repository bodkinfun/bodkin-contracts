// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {BodkinERC20} from "../../src/launchpad/BodkinERC20.sol";

/// @notice The launched token itself: clone initialisation and the one-shot guard.
///
/// Ported out of the retired `test/SingleSidedMint.t.sol` when the V3 suites were
/// deleted. `BodkinERC20` is CURRENT-model code — `LauncherV1` clones it on every launch
/// — and this double-init guard was asserted nowhere else, so deleting that file without
/// moving these cases would have silently dropped the only coverage of it.
contract BodkinERC20Test is Test {
    uint256 internal constant SUPPLY = 1_000_000_000e18;

    address internal impl;

    function setUp() public {
        impl = address(new BodkinERC20());
    }

    function _newToken(string memory name_, string memory symbol_) internal returns (BodkinERC20 token) {
        token = BodkinERC20(Clones.clone(impl));
        token.initialize(name_, symbol_, SUPPLY, address(this), "ipfs://meta");
    }

    function test_CloneInitializesAndMintsTheWholeSupply() public {
        BodkinERC20 token = _newToken("Neko Inu", "NEKO");
        assertEq(token.name(), "Neko Inu", "clone name initialized");
        assertEq(token.symbol(), "NEKO", "clone symbol initialized");
        assertEq(token.decimals(), 18, "18 decimals");
        assertEq(token.totalSupply(), SUPPLY, "full supply minted");
        assertEq(token.balanceOf(address(this)), SUPPLY, "minted to caller");
        assertEq(token.tokenURI(), "ipfs://meta", "ERC-1046 pointer set at launch");
    }

    /// The guard that matters: a clone takes its identity exactly once. Without it a
    /// second `initialize` would rename the token and mint the supply again.
    function test_ACloneCanOnlyBeInitializedOnce() public {
        BodkinERC20 token = _newToken("Neko Inu", "NEKO");
        vm.expectRevert(bytes("BodkinERC20: initialized"));
        token.initialize("X", "X", SUPPLY, address(this), "ipfs://x");
        // And the original state survived the attempt.
        assertEq(token.name(), "Neko Inu");
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// The shared implementation must never be usable as a token itself — otherwise
    /// anyone could initialize it and mint a supply to themselves at the address every
    /// clone points at.
    function test_TheImplementationItselfCanNeverBeInitialized() public {
        vm.expectRevert(bytes("BodkinERC20: initialized"));
        BodkinERC20(impl).initialize("X", "X", SUPPLY, address(this), "ipfs://x");
    }

    function test_RejectsAZeroMintTargetAndAZeroSupply() public {
        BodkinERC20 a = BodkinERC20(Clones.clone(impl));
        vm.expectRevert(bytes("BodkinERC20: mint to zero"));
        a.initialize("N", "N", SUPPLY, address(0), "ipfs://x");

        BodkinERC20 b = BodkinERC20(Clones.clone(impl));
        vm.expectRevert(bytes("BodkinERC20: zero supply"));
        b.initialize("N", "N", 0, address(this), "ipfs://x");
    }
}
