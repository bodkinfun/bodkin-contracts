// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {FeeHook} from "../src/launchpad/v1/FeeHook.sol";
import {LauncherV1} from "../src/launchpad/v1/LauncherV1.sol";
import {CreatorNFT} from "../src/launchpad/CreatorNFT.sol";

/// @title Post-deploy verification — reads the LIVE chain, not a simulation
///
/// @notice `forge script DeployV1 --broadcast` simulates the whole script first, records each call's
///         calldata, and only then sends the transactions one by one. Every `require` inside DeployV1
///         therefore runs against SIMULATED state and is never re-checked on chain: if anything landed
///         between the simulation and the broadcast — most sharply, a stranger's `launch()` shifting
///         which address the pre-recorded `setBodkinPool` carries — the deploy would finish "green"
///         with the wrong wiring, and the wiring is one-shot with the owner renounced right after.
///
///         This script closes that blind spot. It is READ-ONLY and runs as its own invocation AFTER the
///         broadcast, so its requires see the real, final state. Run it through bin/deploy.sh (which
///         does it for you) or by hand:
///
///           forge script script/VerifyV1.s.sol:VerifyV1 --rpc-url robinhood_mainnet
///
///         It reads the exports file the deploy just wrote (DEPLOY_LABEL, else the chain id), so it
///         also proves that file describes what is actually on chain — that is what every frontend,
///         the indexer and the resolver are configured from.
contract VerifyV1 is Script {
    using PoolIdLibrary for PoolKey;

    function run() external view {
        string memory label = vm.envOr("DEPLOY_LABEL", string(""));
        if (bytes(label).length == 0) label = vm.toString(block.chainid);
        string memory path = string.concat("./exports/v1.", label, ".json");
        string memory json = vm.readFile(path);
        console2.log("Verifying", path, "against chain", block.chainid);

        uint256 chainId = vm.parseJsonUint(json, ".chainId");
        address feeHook = vm.parseJsonAddress(json, ".feeHook");
        address launcher = vm.parseJsonAddress(json, ".launcher");
        address creatorNFT = vm.parseJsonAddress(json, ".creatorNFT");
        address bodkin = vm.parseJsonAddress(json, ".bodkin");
        address usdc = vm.parseJsonAddress(json, ".usdc");
        address weth = vm.parseJsonAddress(json, ".weth");
        address team = vm.parseJsonAddress(json, ".team");
        address positionManager = vm.parseJsonAddress(json, ".positionManager");

        require(chainId == block.chainid, "VerifyV1: exports file is for another chain");
        _hasCode(feeHook, "feeHook");
        _hasCode(launcher, "launcher");
        _hasCode(creatorNFT, "creatorNFT");
        _hasCode(bodkin, "bodkin");

        // 1. The hook's wiring, as it ended up on chain.
        FeeHook hook = FeeHook(payable(feeHook));
        require(hook.launcher() == launcher, "VerifyV1: hook.launcher != exports.launcher");
        require(hook.usdc() == usdc, "VerifyV1: hook.usdc != exports.usdc");
        require(hook.weth() == weth, "VerifyV1: hook.weth != exports.weth");
        require(hook.team() == team, "VerifyV1: hook.team != exports.team");
        require(hook.positionManager() == positionManager, "VerifyV1: hook.positionManager mismatch");
        require(hook.owner() == address(0), "VerifyV1: hook owner NOT renounced");
        require(Currency.unwrap(hook.usdcPool().currency1) == usdc, "VerifyV1: usdcPool is not the usdc pool");

        // 2. The buy&burn target — the one thing here that cannot be corrected later.
        //
        // The identity check that matters is the ADDRESS, and it is the only one a squatter cannot
        // forge: BODKIN is launched under a salt namespaced to the deploying key, so its address is
        // CREATE2 over (launcher, keccak(deployer, salt)). Someone who front-ran the launch could copy
        // the name, the symbol and even mint the fee NFT to the team wallet — they cannot land on this
        // address without this key. Everything else below is a sanity check on top of it.
        address launchTokenImpl = vm.parseJsonAddress(json, ".launchTokenImpl");
        address deployer = vm.parseJsonAddress(json, ".deployer");
        // The salt the deploy launched BODKIN under — mined for the platform suffix, so it is not a
        // constant anyone can assume. Both inputs to the address come from this file, and that is
        // enough: a squatter cannot produce an address derived from OUR deployer's key.
        bytes32 bodkinSalt = vm.parseJsonBytes32(json, ".bodkinSalt");
        require(bodkinSalt != bytes32(0), "VerifyV1: exports carry no BODKIN salt");
        _hasCode(launchTokenImpl, "launchTokenImpl");
        require(
            bodkin
                == Clones.predictDeterministicAddress(
                    launchTokenImpl, keccak256(abi.encodePacked(deployer, bodkinSalt)), launcher
                ),
            "VerifyV1: BODKIN is not the address this deployer's salt produces"
        );
        require(hook.bodkin() == bodkin, "VerifyV1: hook.bodkin != exports.bodkin");
        PoolKey memory bodkinKey = LauncherV1(payable(launcher)).poolKeyOf(bodkin);
        require(Currency.unwrap(bodkinKey.currency1) == bodkin, "VerifyV1: bodkin has no launch pool");
        require(address(bodkinKey.hooks) == feeHook, "VerifyV1: bodkin pool is not hooked to this hook");
        // And the venue the hook will actually spend every coin's burn slice on IS that pool. Without
        // this the script proved a pool exists, never that the hook was pointed at it.
        require(
            PoolId.unwrap(hook.bodkinPool().toId()) == PoolId.unwrap(bodkinKey.toId()),
            "VerifyV1: the wired burn venue is not BODKIN's own pool"
        );
        require(
            keccak256(bytes(IERC20Metadata(bodkin).symbol())) == keccak256(bytes(vm.envOr("BODKIN_SYMBOL", string("BODKIN")))),
            "VerifyV1: the wired burn target does not carry the BODKIN symbol"
        );

        // 3. The creator NFT: BODKIN is launch #0 and its fee stream sits with the team wallet.
        CreatorNFT nft = CreatorNFT(creatorNFT);
        require(nft.launchToken(0) == bodkin, "VerifyV1: BODKIN does not hold creator NFT #0");
        require(nft.creatorOf(bodkin) == team, "VerifyV1: BODKIN fee NFT is not on the team wallet");
        require(nft.owner() == address(0), "VerifyV1: creatorNFT owner NOT renounced");

        console2.log("  feeHook  ", feeHook);
        console2.log("  launcher ", launcher);
        console2.log("  bodkin   ", bodkin);
        console2.log("OK: every address this script checks matches the chain, and the burn venue is");
        console2.log("    BODKIN's own pool, at the address only this deploying key could produce.");
        console2.log("    Not checked here: the canonical Uniswap addresses in the exports file, which");
        console2.log("    are inputs to the deploy rather than results of it.");
    }

    function _hasCode(address a, string memory what) internal view {
        require(a != address(0), string.concat("VerifyV1: ", what, " is address(0)"));
        require(a.code.length > 0, string.concat("VerifyV1: ", what, " has no code on this chain"));
    }
}
