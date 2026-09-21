// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {FeeHook, ICreatorNFT} from "../src/launchpad/v1/FeeHook.sol";
import {LauncherV1} from "../src/launchpad/v1/LauncherV1.sol";
import {LocalUniversalRouter} from "../src/dev/LocalUniversalRouter.sol";
import {Permit2Runtime} from "../src/dev/Permit2Deployer.sol";
import {IAllowanceTransfer} from "@uniswap/v4-periphery/src/interfaces/IPermit2Forwarder.sol";
import {V4Quoter} from "@uniswap/v4-periphery/src/lens/V4Quoter.sol";
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {CreatorNFT} from "../src/launchpad/CreatorNFT.sol";
import {BodkinERC20} from "../src/launchpad/BodkinERC20.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";

/// @notice Local (anvil, 31337) deploy of the SINGLE-DEX bodkin v1 model on Uniswap V4: a V4
///         PoolManager + the FeeHook (deployed at a flag-encoded address via the
///         CREATE2 factory) + CreatorNFT + LauncherV1, plus a MockUSDC and an
///         (ETH, USDC) pool so fee claims can convert to USDC. Then one demo token
///         is launched onto a single-sided, permanently-locked V4 position.
contract DeployLocalV1 is Script {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant ANVIL_PK0 = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address internal constant TEAM = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address internal constant RESOLVER = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    /// Deterministic CREATE2 factory present on anvil + most chains.
    address internal constant CREATE2 = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    /// (ETH 18-dec = currency0, USDC 6-dec = currency1) at EXACTLY $2,500 per ETH — the rate every
    /// pricing figure in the docs assumes (fdvRaw 1 ETH == $2,500 start; 12 ETH == $30,000 migration),
    /// so the USD figures on the local site read the way the ETH-denominated targets are meant to.
    /// price = 2500e6/1e18 = 2.5e-9, sqrtPriceX96 = floor(sqrt(price) * 2^96) = 5e-5 * 2^96.
    uint160 internal constant SQRT_PRICE_ETH_USDC = 3961408125713216879677197;
    /// The dev buy BODKIN opens with. Its supply is the protocol-fixed `LauncherV1.TOTAL_SUPPLY`
    /// (one billion), and its starting FDV is the same one the launcher uses for every
    /// ETH-quoted launch — so BODKIN's chart starts where a launched token's would.
    uint256 internal constant BODKIN_DEV_BUY = 0.069 ether; // local only: half the mainnet default (0.138), enough to open the chart

    /// @dev Everything the frontend/indexer needs, kept in STORAGE rather than as
    ///      `run()` locals — with via-IR the deploy would otherwise blow the stack.
    struct Exports {
        address poolManager;
        address feeHook;
        address launcher;
        address universalRouter;
        address permit2;
        address positionManager;
        address v4Quoter;
        address stateView;
        bytes32 usdcPoolId;
        address creatorNFT;
        address launchTokenImpl;
        address usdc;
        address weth;
        address bodkin;
        address demoToken;
        address demoRwa;
        address demoUsdcToken;
        address deployer;
    }

    Exports internal ex;

    function run() external {
        deploy();
        // 7. Export addresses for the frontend/indexer.
        _writeExports();
    }

    /// @dev The deploy itself, with NO file writes.
    ///
    /// Split from `run()` so tests can exercise the real deploy path — the same code an
    /// operator runs — without `vm.writeJson` clobbering `exports/v1.local.json` with
    /// throwaway test addresses. It also keeps each half inside the via-IR stack limit.
    function deploy() public {
        uint256 pk = vm.envOr("PRIVATE_KEY", ANVIL_PK0);
        address deployer = vm.addr(pk);
        // Simulation-only top-up (no-op on anvil, where account 0 already holds ETH) so `forge script`
        // without --broadcast can run the value-bearing steps — now incl. the ~7,500 ETH deep (ETH,USDC)
        // seed. On a real anvil, account 0's 10,000 ETH covers the deep pool + the demo launches.
        if (deployer.balance < 100_000 ether) vm.deal(deployer, 1_000_000 ether);

        vm.startBroadcast(pk);

        // 1. V4 core + peripherals.
        PoolManager manager = new PoolManager(deployer);
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        // FEE_NFT_BASE_URI — EMPTY locally (no server to point at): tokenURI is then the coin's
        // own pinned IPFS document (ipfs://<cid>/metadata.json). Testnet and mainnet SET it to
        // their API origin + "/api/fee-nft/" (see .env.example): wallets resolve ipfs:// only
        // through public gateways, which no longer serve it reliably, so the API-composed
        // document (https image through our own proxy) is what makes the NFT render in wallets.
        // Frozen at deploy: CreatorNFT has no setter, because the launchpad ships with no admin.
        CreatorNFT nft = new CreatorNFT(vm.envOr("FEE_NFT_BASE_URI", string("")));
        // Large supply so the (ETH,USDC) conversion pool has deep liquidity locally.
        MockUSDC usdc = new MockUSDC(1e30);
        address impl = address(new BodkinERC20());
        ex.deployer = deployer;
        ex.poolManager = address(manager);
        ex.creatorNFT = address(nft);
        ex.usdc = address(usdc);
        ex.launchTokenImpl = impl;

        // Wrapped-ETH mock, passed INTO the hook (constructor arg) so a creator can pay out a token
        // whose liquidity is a V4 (WETH, token) pool — the hook wraps native ETH -> WETH to convert.
        // On mainnet/testnet the REAL WETH is used instead (DeployV1 reads env WETH). Re-pointable
        // post-deploy ONLY via the launcher's 2-of-2 (LauncherV1.updateFeeToken) — no admin setter.
        MockWETH weth = new MockWETH();
        ex.weth = address(weth);

        // 2. FeeHook at a flag-encoded address (beforeInit + before/after swap + deltas).
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                // LP-provider reward tracking hooks (see FeeHook.getHookPermissions).
                | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );
        bytes memory hookArgs = abi.encode(
            IPoolManager(address(manager)),
            ICreatorNFT(address(nft)),
            TEAM,
            address(usdc),
            address(weth),
            deployer
        );
        (address hookAddr, bytes32 salt) = HookMiner.find(CREATE2, flags, type(FeeHook).creationCode, hookArgs);
        (bool ok,) = CREATE2.call(abi.encodePacked(salt, type(FeeHook).creationCode, hookArgs));
        require(ok && hookAddr.code.length > 0, "hook deploy failed");
        FeeHook hook = FeeHook(payable(hookAddr));
        ex.feeHook = hookAddr;

        // 3. Launcher + wire the fee-stream NFT to it.
        // Starting FDV per numeraire, in RAW units: 1.5 ETH for an ETH-quoted launch, $4,000 for a
        // USDC-quoted one (~$4k either way at $2,500/ETH). Fixed at deploy.
        // Migration at a fixed cap: ETH 1.5 → 12 ETH, USDC $4,000 → $30,000 (the ~$30k cap). Matches
        // DeployV1's defaults. The cap only sets the graduation mcap; depth comes from the 600M above the
        // curve that is KEPT (not stranded) at migration — see LauncherV1.CURVE_SUPPLY.
        LauncherV1.StartFdv[] memory fdvs = new LauncherV1.StartFdv[](2);
        fdvs[0] = LauncherV1.StartFdv({numeraire: address(0), fdvRaw: 1.5 ether, migrationTargetRaw: 12 ether});
        fdvs[1] = LauncherV1.StartFdv({numeraire: address(usdc), fdvRaw: 4_000e6, migrationTargetRaw: 30_000e6});
        // TEAM = the team wallet (the hook's 20% slice + BODKIN's fee NFT); the create fee goes to
        // RESOLVER (funds the migration bot's gas). The deployer is only the SECOND signer of the 2-of-2 that can re-point that wallet
        // (see LauncherV1.updateTeamWallet) — never a recipient or a unilateral admin.
        // TEAM (anvil acct 1) and deployer (anvil acct 0) are distinct, so the local sim
        // exercises a real 2-of-2 with two known keys.
        LauncherV1 launcher =
            new LauncherV1(IPoolManager(address(manager)), IHooks(hookAddr), nft, impl, TEAM, RESOLVER, deployer, fdvs);
        nft.setLaunchpad(address(launcher));
        hook.setLauncher(address(launcher)); // lets the launcher set a token's payout at launch
        ex.launcher = address(launcher);

        // 4. (ETH, USDC) conversion pool + liquidity + wire it into the hook. Priced at $2,500/ETH; this
        //    is the indexer's ETH/USD reference (eth_usd:{chain}), so EVERY USD figure on the site derives
        //    from it. Seeded DEEP (~4,550 ETH + ~9.1M USDC, 50x the old ~91 ETH) ON PURPOSE: this same pool
        //    is also the fee-conversion venue (creator/team payouts swap through it), so a shallow pool
        //    DRIFTED the ETH/USD rate as fees converted — which made frozen candle USD wander over time and
        //    e.g. a $30k migration render as ~$58k once the rate had ~doubled. A deep pool holds the rate
        //    steady like a real chain's (ETH,USDC) pool. (Fund from the 1M-ETH deal above.)
        {
            PoolKey memory usdcKey = _openPricedPool(
                manager, lp, address(usdc), 10000, 200, SQRT_PRICE_ETH_USDC, 25e16, 7500 ether
            );
            hook.setUsdcPool(usdcKey);
            ex.usdcPoolId = PoolId.unwrap(usdcKey.toId()); // ETH/USD ref for the indexer
        }

        // 4b. BODKIN — a REAL LAUNCH, and the burn venue.
        //
        // BODKIN goes through `launcher.launch` like any token: hook pool (the 1%
        // platform fee, split 70/10/20), single-sided locked position, creator NFT to
        // the deployer, USDC payout, and the standard dev buy as its first trade. So
        // the team's BODKIN fee stream claims exactly like every launch's.
        //
        // The same launch pool is then wired as the buy & burn venue. Its POOL fee is
        // 0 (the hook is the fee), which `setBodkinPool` accepts specifically for the
        // hook's own pools: the sandwich toll that makes bounded burn chunks safe is
        // the hook's FEE_BPS skim — same 1%, paid to the protocol instead of LPs —
        // and `_safeBurnChunk` prices the venue accordingly. Every BODKIN trade
        // (including the burn's own buys) therefore ALSO feeds the fee pipeline:
        // BODKIN burns BODKIN.
        //
        // This remains the single most irreversible line in the deploy: `setBodkinPool`
        // is one-shot and `renounceOwnership()` follows below.
        {
            address bodkinToken = launcher.launch{value: 0.0005 ether + BODKIN_DEV_BUY}(
                "Bodkin",
                "BODKIN",
                _pinAvatar("Bodkin", "BODKIN", "bodkin"),
                _mineVanitySalt(address(0)), // b0d41 vanity ending (ETH → no sort constraint)
                address(0), // ETH-quoted pool (the default)
                BODKIN_DEV_BUY,
                LauncherV1.PayoutParams({
                    token: address(usdc),
                    viaHub: false, wethPaired: false,
                    fee: 0,
                    tickSpacing: 0,
                    // Autocompound OFF for BODKIN: its 10% slice rolls into the creator (team) cut instead of
                    // self-compounding its own pool. Per-coin launch config, so no hook special case.
                    feeRecipient: TEAM, autocompoundOff: true, creatorFeeBps: 0, lpFeeBps: 0, lpRewardsOff: false // NFT #0 (BODKIN's fee stream) to the TEAM wallet, as on mainnet
                })
            );
            ex.bodkin = bodkinToken;
            // BODKIN is launched FIRST so it holds creator-NFT #0 — the platform's own
            // token at the head of its own collection. Asserted, not assumed: reorder
            // this block and the deploy stops here instead of quietly handing #0 to a
            // demo token.
            require(nft.nftOf(bodkinToken) == 0, "deploy: BODKIN must be the first launch");
            PoolKey memory bodkinKey = launcher.poolKeyOf(bodkinToken);
            hook.setBodkinPool(bodkinKey);
        }

        // 4b-2. A demo "RWA" token with a CANONICAL-tier (ETH, RWA) pool (1% / 200),
        //       so custom fee-payout tokens can be exercised locally: the launcher
        //       only accepts canonical tiers, and the frontend's tier scan finds this.
        MockUSDC rwa = new MockUSDC(1e30);
        ex.demoRwa = address(rwa);
        _openEthPool(manager, lp, address(rwa), 10000, 200);

        // 4c. The Universal Router + Permit2, deployed LOCALLY — neither exists on a bare anvil, but
        //     on Robinhood both are canonical and pre-deployed. We stand them up here so the frontend
        //     routes EVERY swap through the Universal Router locally, exactly as it does in prod (there
        //     is no SwapZap any more — the router replaced it). `LocalUniversalRouter` is a dev-only,
        //     minimal UR that speaks the same `execute(commands,inputs,deadline)` calldata for the
        //     V4_SWAP + PERMIT2_PERMIT commands the launchpad's swaps emit; external (Trading-API)
        //     routes aren't exercised locally, so those commands are intentionally unimplemented.
        //     Permit2 is the REAL canonical runtime (deployed via `Permit2Runtime`, a real tx — NOT
        //     `vm.etch`, which would not persist to anvil through `forge script --broadcast`), so
        //     ERC-20 inputs pull for real. Both get normal CREATE addresses, exported for the frontend.
        ex.permit2 = address(new Permit2Runtime());
        ex.universalRouter =
            address(new LocalUniversalRouter(IPoolManager(address(manager)), IAllowanceTransfer(ex.permit2)));
        // v4 PositionManager: a POSITION_MANAGER env override wins (point at a real deployment); otherwise
        // deploy a REAL v4-periphery PositionManager here so external LPs — and the activity simulator —
        // can MINT/BURN full-range positions locally, exactly as on Robinhood. Wired into the hook (before
        // the renounce below) so LP-reward claims resolve a position NFT's owner, and so the indexer's
        // ModifyLiquidity/Transfer ingestion (gated on sender == PositionManager) records the positions.
        // Its tokenDescriptor is only read by tokenURI (never called on-chain here) → address(0) is safe.
        ex.positionManager = vm.envOr("POSITION_MANAGER", address(0));
        if (ex.positionManager == address(0)) {
            ex.positionManager = address(
                new PositionManager(
                    IPoolManager(address(manager)),
                    IAllowanceTransfer(ex.permit2),
                    100_000, // unsubscribeGasLimit — unused (no subscribers), a safe non-zero default
                    IPositionDescriptor(address(0)),
                    IWETH9(ex.weth)
                )
            );
        }
        hook.setPositionManager(ex.positionManager);

        // 4d. Read-only lenses the frontend route-finder needs: V4Quoter (exact
        //     multihop quotes via eth_call) + StateView (pool existence via getSlot0).
        ex.v4Quoter = address(new V4Quoter(IPoolManager(address(manager))));
        ex.stateView = address(new StateView(IPoolManager(address(manager))));

        // 4e. Fund the simulator's traders (anvil accounts #2..#9) with USDC, so
        //     USDC-quoted launches and USDC-side buys actually execute locally —
        //     without this the launcher's transferFrom for a USDC dev buy reverts.
        _fundTraders(usdc);

        // 5. Demo launches (single-sided, permanently locked): one ETH-quoted (the
        //    default) and one USDC-quoted, so the feed shows both kinds locally.
        ex.demoToken = _demoLaunch(launcher, address(usdc));
        ex.demoUsdcToken = _demoUsdcLaunch(launcher, usdc);

        // 6. RENOUNCE. Every admin setter on the hook and the NFT exists only for the
        //    one-time wiring above — setLauncher/setUsdcPool/setBodkinPool (steps 3-4b)
        //    and setLaunchpad (step 3). Once they are set, an owner is pure downside:
        //    it could re-point setLauncher at a hostile contract and thereby choose who
        //    may open a pool, or swap setUsdcPool for a thin-LP pool the fee
        //    conversions would then be routed through.
        //
        //    LauncherV1 needs no equivalent — it ships ownerless by construction. Its one
        //    mutable parameter, the team wallet, has no admin either: it moves only via a
        //    2-of-2 (deployer + current team) off-chain-signature call (updateTeamWallet),
        //    which also re-points the hook's team slice in the same tx.
        //
        //    This is permanent and it is the point: after this, the USDC + BODKIN conversion pools,
        //    the launcher wiring and the fee split can NEVER be changed. The ONE exception is the
        //    deployer-only ops admin (FeeHook.admin, set to the deployer at construction), which
        //    SURVIVES this renounce and can re-point only `weth` (the wethPaired-payout wrap target)
        //    — a small ops lever for a wrong/chain-specific WETH. Renounce it too
        //    (hook.setDeployer(address(0))) to freeze weth for good. USDC is immutable by design.
        hook.renounceOwnership();
        nft.renounceOwnership();

        vm.stopBroadcast();
    }

    /// @dev Serialize {ex} to exports/v1.local.json (own frame: keeps `run()` within
    ///      the via-IR stack limit).
    function _writeExports() internal {
        string memory obj = "v4";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "poolManager", ex.poolManager);
        vm.serializeAddress(obj, "feeHook", ex.feeHook);
        vm.serializeAddress(obj, "launcher", ex.launcher);
        vm.serializeAddress(obj, "universalRouter", ex.universalRouter); // local dev UR (Robinhood-canonical in prod)
        vm.serializeAddress(obj, "permit2", ex.permit2); // local Permit2 (canonical in prod)
        vm.serializeAddress(obj, "positionManager", ex.positionManager); // v4 PositionManager (env; 0 on bare anvil)
        vm.serializeAddress(obj, "v4Quoter", ex.v4Quoter);
        vm.serializeAddress(obj, "stateView", ex.stateView);
        vm.serializeBytes32(obj, "usdcPoolId", ex.usdcPoolId); // ETH/USD ref for the indexer
        vm.serializeAddress(obj, "creatorNFT", ex.creatorNFT);
        vm.serializeAddress(obj, "launchTokenImpl", ex.launchTokenImpl);
        vm.serializeAddress(obj, "usdc", ex.usdc);
        vm.serializeAddress(obj, "weth", ex.weth);
        vm.serializeAddress(obj, "bodkin", ex.bodkin);
        vm.serializeAddress(obj, "demoToken", ex.demoToken);
        vm.serializeAddress(obj, "demoRwa", ex.demoRwa); // custom fee-payout demo (canonical 1% ETH pool)
        vm.serializeAddress(obj, "demoUsdcToken", ex.demoUsdcToken); // USDC-quoted launch demo
        vm.serializeAddress(obj, "deployer", ex.deployer);
        string memory json = vm.serializeString(obj, "deployBlock", vm.toString(block.number));
        vm.writeJson(json, "./exports/v1.local.json");

        console2.log("v1 deploy complete. launcher:", ex.launcher);
        console2.log("feeHook:", ex.feeHook, " demoToken:", ex.demoToken);
        // The block to start the indexer from (also in exports/v1.local.json as deployBlock).
        console2.log("deployBlock (set START_BLOCK to this):", block.number);
    }

    /// @notice How many simulator trader wallets the local deploy funds: anvil accounts #2..#65
    ///         (#0 = deployer, #1 = the sim's BODKIN ramp driver). `anvil-local.sh` starts anvil with
    ///         `--accounts 66` so every one of them holds ETH; the sim's TRADES_PER_TICK default (64)
    ///         needs one wallet per concurrent trade (two txs from one wallet race on the nonce).
    uint256 internal constant TRADER_WALLETS = 64;
    string internal constant ANVIL_MNEMONIC = "test test test test test test test test test test test junk";

    /// @dev Anvil's well-known accounts #2..#(TRADER_WALLETS+1) — the simulator's traders, derived
    ///      from anvil's default mnemonic instead of a hardcoded list. Local only.
    function _fundTraders(MockUSDC usdc) internal {
        for (uint32 i = 2; i < 2 + TRADER_WALLETS; i++) {
            address trader = vm.addr(vm.deriveKey(ANVIL_MNEMONIC, i));
            usdc.transfer(trader, 500_000e6); // 500k USDC each — plenty for a long sim run
        }
    }

    /// @dev A USDC-QUOTED demo launch: the pool is (USDC, token), and the salt is mined so
    ///      token > USDC. NO dev buy — deliberately. A USDC-quoted first trade's fee accrues a
    ///      BURN slice whose buy&burn converts USDC -> ETH -> BODKIN (a TWO-hop route), and that
    ///      afterSwap burn runs at launch time here. Under `forge script --broadcast` the per-tx
    ///      gas limit is fixed from the SIMULATION, where the same-block burn is skipped — so on the
    ///      real (block-advancing) broadcast the extra 2-hop burn can tip this one launch over its
    ///      limit and abort the whole deploy (an OOG that never happens on a real chain, where each
    ///      tx is estimated fresh). The ETH demo already launches with no dev buy, and the simulator
    ///      supplies all the trading activity, so the demo loses nothing by opening un-traded.
    function _demoUsdcLaunch(LauncherV1 launcher, MockUSDC usdc) internal returns (address) {
        return launcher.launch{value: 0.0005 ether}(
            "Yen Neko",
            "YNEKO",
            _pinAvatar("Yen Neko", "YNEKO", "yneko"),
            _mineVanitySalt(address(usdc)), // b0d41 vanity AND sorts above USDC
            address(usdc), // USDC-quoted pool
            0, // no dev buy — see the note above
            LauncherV1.PayoutParams({
                token: address(usdc), // fees already accrue in USDC - no conversion
                viaHub: false, wethPaired: false,
                fee: 0,
                tickSpacing: 0,
                feeRecipient: address(0), autocompoundOff: false, creatorFeeBps: 0, lpFeeBps: 0, lpRewardsOff: false
            })
        );
    }

    /// @dev Generate + pin a demo avatar and its ERC-1046 document, returning the
    ///      `ipfs://…/metadata.json` URI (empty when the IPFS node is not running).
    ///
    ///      The deploy's own tokens used to carry a hardcoded `ipfs://demo-yneko`, which
    ///      is not a CID: nothing resolves it, so the indexer stored no image and the feed
    ///      drew its placeholder for them forever while simulator-launched tokens showed
    ///      real art. This closes that gap by using the same generator the simulator does.
    ///
    ///      Requires `ffi = true` (already set in foundry.toml) and the local kubo node.
    ///      Empty output is handled, not fatal — see the script's FAILS SOFT note.
    function _pinAvatar(string memory name_, string memory symbol_, string memory seed)
        internal
        returns (string memory)
    {
        string[] memory cmd = new string[](5);
        cmd[0] = "node";
        cmd[1] = "scripts/pin-demo-avatar.mjs";
        cmd[2] = name_;
        cmd[3] = symbol_;
        cmd[4] = seed;
        return string(vm.ffi(cmd));
    }

    /// @dev Mine (off-chain, via node) a salt whose LauncherV1 clone address ends in the
    ///      platform vanity suffix `b0d41` — and, for a USDC pool, sorts ABOVE `numeraire`.
    ///      Same suffix as every create-form and simulated launch, so the deploy's OWN
    ///      tokens (BODKIN and the demos) carry it too. The ~1/1e6 search is off-chain
    ///      because a million-keccak loop in the Solidity script is not viable; the launch
    ///      caller is `ex.deployer` (the salt is namespaced to it). Requires `ffi = true`.
    function _mineVanitySalt(address numeraire) internal returns (bytes32) {
        string[] memory cmd = new string[](6);
        cmd[0] = "node";
        cmd[1] = "scripts/mine-vanity-salt.mjs";
        cmd[2] = vm.toString(ex.deployer);
        cmd[3] = vm.toString(ex.launcher);
        cmd[4] = vm.toString(ex.launchTokenImpl);
        cmd[5] = vm.toString(numeraire);
        bytes memory out = vm.ffi(cmd);
        require(out.length == 32, "mine-vanity-salt: expected a 32-byte salt");
        bytes32 salt;
        assembly {
            salt := mload(add(out, 0x20))
        }
        return salt;
    }

    /// @dev Open a PLAIN (hook-less) full-range (native ETH, `token`) pool at 1:1 and
    ///      seed it with liquidity. Fine for the 18-decimal mocks; the real ETH/USDC
    ///      pool needs {_openPricedPool} instead.
    function _openEthPool(PoolManager manager, PoolModifyLiquidityTest lp, address token, uint24 fee, int24 spacing)
        internal
        returns (PoolKey memory key)
    {
        return _openPricedPool(manager, lp, token, fee, spacing, SQRT_PRICE_1_1, 10e18, 100 ether);
    }

    /// @dev Open a PLAIN (native ETH, `token`) pool at an explicit price and seed it.
    ///      Needed because USDC is 6-decimal: at SQRT_PRICE_1_1 one wei would trade for
    ///      one micro-USDC, i.e. ETH ≈ $1e12, which would poison every USDC-denominated
    ///      price the indexer and the fee hook derive from this pool.
    function _openPricedPool(
        PoolManager manager,
        PoolModifyLiquidityTest lp,
        address token,
        uint24 fee,
        int24 spacing,
        uint160 sqrtPriceX96,
        int256 liquidity,
        uint256 ethValue
    ) internal returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: fee,
            tickSpacing: spacing,
            hooks: IHooks(address(0))
        });
        manager.initialize(key, sqrtPriceX96);
        MockUSDC(token).approve(address(lp), type(uint256).max);
        lp.modifyLiquidity{value: ethValue}(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(spacing),
                tickUpper: TickMath.maxUsableTick(spacing),
                liquidityDelta: liquidity,
                salt: 0
            }),
            ""
        );
    }

    /// @dev Its own frame purely to keep `run()` under the via-IR stack limit.
    ///      Default fee payout: USDC, to whoever holds the creator NFT.
    function _demoLaunch(LauncherV1 launcher, address usdc_) internal returns (address) {
        return launcher.launch{value: 0.0005 ether}(
            "Neko Inu",
            "NEKO",
            _pinAvatar("Neko Inu", "NEKO", "neko"),
            _mineVanitySalt(address(0)), // b0d41 vanity ending
            address(0), // ETH-quoted pool (the default)
            0,
            LauncherV1.PayoutParams({token: usdc_, viaHub: false, wethPaired: false, fee: 0, tickSpacing: 0, feeRecipient: address(0), autocompoundOff: false, creatorFeeBps: 0, lpFeeBps: 0, lpRewardsOff: false})
        );
    }
}
