// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {V4Quoter} from "@uniswap/v4-periphery/src/lens/V4Quoter.sol";
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";

import {FeeHook, ICreatorNFT} from "../src/launchpad/v1/FeeHook.sol";
import {LauncherV1} from "../src/launchpad/v1/LauncherV1.sol";
import {CreatorNFT} from "../src/launchpad/CreatorNFT.sol";
import {BodkinERC20} from "../src/launchpad/BodkinERC20.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

/// @dev The salt BODKIN falls back to when none is mined and none is given: any NONZERO value will do.
///      Zero is the one value that must never be used — the launcher mints a zero-salt clone with a
///      plain CREATE, whose address follows the LAUNCHER'S NONCE, and forge broadcasts this script as
///      separate transactions after simulating it. A stranger's launch() landing in between would shift
///      that nonce, take the address the simulation predicted, and the already-recorded setBodkinPool
///      would wire THEIR token as the platform's buy&burn target, permanently. A nonzero salt makes the
///      address CREATE2 over keccak256(deployer, salt) — namespaced to whoever calls launch, so nobody
///      else can occupy it, and a squatted address reverts the deploy loudly.
bytes32 constant BODKIN_SALT_FALLBACK = keccak256("bodkin.fun/v1/BODKIN");

/// @title Production deploy of the Bodkin v1 launchpad — Robinhood Chain (testnet + mainnet)
///
/// @notice One env-driven, all-in-one deploy: it points at an ALREADY-DEPLOYED canonical
///         Uniswap V4 PoolManager (never deploys its own), deploys CreatorNFT + the
///         BodkinERC20 clone implementation + the FeeHook (at a flag-encoded CREATE2 address)
///         + LauncherV1 + the V4Quoter/StateView lenses, wires the real
///         (native-ETH, USDC) conversion pool into the hook (creating + seeding it only if it
///         does not already exist), launches $BODKIN as the first token (creator NFT #0, wired
///         as the buy&burn venue), and finally RENOUNCES hook + NFT ownership. After that the
///         only tunable parameter left in the whole system is the team/fee-recipient wallet,
///         moved solely by the 2-of-2 in {LauncherV1.updateTeamWallet}.
///
/// @dev Unlike {DeployLocalV1} this deploys NO mocks, NO demo tokens, funds NO traders, and
///      uses NO FFI — it moves REAL value (the launch fee + the BODKIN dev buy + any USDC-pool
///      seeding), so the deployer must be funded for real; there is no vm.deal. EVERYTHING
///      network-specific is read from the environment (.env) — see .env.example. The deployer
///      key is PRIVATE_KEY, or derived from MNEMONIC (+ optional MNEMONIC_INDEX).
///
///      Run it through `forge script` with `--rpc-url robinhood_testnet|robinhood_mainnet`
///      (see foundry.toml [rpc_endpoints]) — or the bin/deploy.sh wrapper. ALWAYS dry-run first
///      (no --broadcast): the simulation reverts if a required env var is missing or the deployer
///      can't cover the VALUE legs, and logs the wired USDC pool + price for you to eyeball. It
///      does NOT prove gas sufficiency, and the deploy is not atomic — a mid-broadcast failure
///      (out of gas, or someone initialising the (ETH,USDC) pool between simulation and
///      broadcast) can leave core contracts live but unwired, recoverable only by a fresh
///      redeploy. Fund the deployer well above value+gas, and re-check right before broadcasting.
contract DeployV1 is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// Deterministic CREATE2 factory — present at the same address on every EVM chain that has
    /// run the standard presigned deployment; the FeeHook must be mined to a flag-encoded
    /// address, which requires CREATE2. If it is absent on the target chain the hook deploy
    /// reverts (caught below) and you must deploy the factory first.
    address internal constant CREATE2 = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// Everything the frontend/indexer needs, kept in STORAGE (via-IR would otherwise blow the
    /// stack) — the deployed addresses, written to exports/v1.<label>.json at the end.
    struct Exports {
        uint256 chainId;
        /// The salt BODKIN was launched under. Exported because {VerifyV1} recomputes the token's
        /// address from it — and because a deploy should be able to say how it got the address it got.
        bytes32 bodkinSalt;
        address poolManager;
        address feeHook;
        address launcher;
        address universalRouter;
        address permit2;
        address positionManager;
        address v4Quoter;
        address stateView;
        bytes32 usdcPoolId;
        uint24 usdcPoolFee; // the wired (ETH, USD) pool's tier — the frontend's bridge hop uses it
        int24 usdcPoolTickSpacing;
        address creatorNFT;
        address launchTokenImpl;
        address usdc;
        address weth;
        address bodkin;
        address team;
        address deployerWallet; // the launcher's `deployer` co-signer (defaults to `deployer` above)
        address deployer;
    }

    Exports internal ex;

    // ── configuration lookup ────────────────────────────────────────────────────────────
    // Every operator input goes through these, so a test can vary the config PER TEST with
    // {_set} instead of `vm.setEnv` — which is process-wide and leaks between tests running in
    // parallel (forge runs a contract's tests concurrently). An override wins over the process
    // env; an empty value counts as unset in both.
    mapping(string => string) internal cfgOverride;
    mapping(string => bool) internal cfgOverridden;

    function _set(string memory key, string memory value) internal {
        cfgOverride[key] = value;
        cfgOverridden[key] = true;
    }

    function _raw(string memory key) internal view returns (bool ok, string memory v) {
        v = cfgOverridden[key] ? cfgOverride[key] : vm.envOr(key, string(""));
        ok = bytes(v).length != 0;
    }

    function _str(string memory key, string memory def) internal view returns (string memory) {
        (bool ok, string memory v) = _raw(key);
        return ok ? v : def;
    }

    function _strReq(string memory key) internal view returns (string memory) {
        (bool ok, string memory v) = _raw(key);
        require(ok, string.concat("DeployV1: ", key, " is required (see .env.example)"));
        return v;
    }

    function _addr(string memory key) internal view returns (address) {
        return vm.parseAddress(_strReq(key));
    }

    function _addrOr(string memory key, address def) internal view returns (address) {
        (bool ok, string memory v) = _raw(key);
        return ok ? vm.parseAddress(v) : def;
    }

    /// Decimal or 0x-hex, like forge's own envUint.
    function _parseUint(string memory v) internal pure returns (uint256) {
        bytes memory b = bytes(v);
        if (b.length > 2 && b[0] == "0" && (b[1] == "x" || b[1] == "X")) return uint256(vm.parseBytes32(v));
        return vm.parseUint(v);
    }

    function _uint(string memory key) internal view returns (uint256) {
        return _parseUint(_strReq(key));
    }

    function _uintOr(string memory key, uint256 def) internal view returns (uint256) {
        (bool ok, string memory v) = _raw(key);
        return ok ? _parseUint(v) : def;
    }

    function _bool(string memory key, bool def) internal view returns (bool) {
        (bool ok, string memory v) = _raw(key);
        return ok ? vm.parseBool(v) : def;
    }

    function run() external {
        deploy();
        _writeExports();
    }

    /// @dev The deploy proper, with NO file writes — split from run() so it fits the via-IR
    ///      stack limit and so a fork test can exercise the exact operator path.
    function deploy() public {
        uint256 pk = _deployerKey();
        address deployer = vm.addr(pk);

        // ── required configuration (revert early, with a clear message, if missing) ──
        IPoolManager manager = IPoolManager(_addr("POOL_MANAGER")); // canonical Uniswap V4
        address usdc = _usdc(); // the chain's REAL dollar token — or, TESTNET ONLY, a mock we mint ourselves
        _networkGuards(usdc);
        address team = _addr("TEAM_WALLET");
        // The migration bot's wallet, recorded on the launcher (re-pointable by the same 2-of-2 as the
        // team wallet). Every launch's flat 0.0005 ETH create fee is sent HERE — that is what keeps the
        // bot funded for migrate() gas. The 20% swap-fee slice goes to TEAM_WALLET.
        address resolver = _addr("RESOLVER_WALLET");
        // Second signer of the 2-of-2 that can later re-point the team wallet. It is ONLY a
        // co-signer, never a recipient or a unilateral admin, and it MUST differ from the team
        // wallet or the multisig would collapse to one key. Defaults to the deployer.
        address deployerWallet = _addrOr("DEPLOYER_WALLET", deployer);
        require(deployerWallet != team, "DeployV1: DEPLOYER_WALLET must differ from TEAM_WALLET (2-of-2)");

        ex.chainId = block.chainid;
        ex.deployer = deployer;
        ex.poolManager = address(manager);
        ex.usdc = usdc;
        ex.team = team;
        ex.deployerWallet = deployerWallet;

        vm.startBroadcast(pk);

        // 1. Fee-stream NFT + the immutable clone implementation.
        CreatorNFT nft = new CreatorNFT(_str("FEE_NFT_BASE_URI", ""));
        address impl = address(new BodkinERC20());
        ex.creatorNFT = address(nft);
        ex.launchTokenImpl = impl;

        // 2. FeeHook at a flag-encoded address (beforeInit + before/after swap + deltas), via
        //    the CREATE2 factory. Team, USDC and WETH are baked in at construction; the deployer is
        //    the one-time owner (renounced at the end) AND the `deployer` role (survives the renounce; now
        //    only maintains the team payout-token allow-list). WETH/USDC re-points are the launcher's
        //    2-of-2, not the deployer role.
        // WETH is a constructor arg now (no post-deploy setter): unset (address 0) simply disables
        // WETH-paired creator payouts on this hook, no revert. Re-pointable later only via the
        // launcher's 2-of-2 (LauncherV1.updateFeeToken).
        address weth = _addrOr("WETH", address(0));
        ex.weth = weth;
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                // LP-provider reward tracking hooks (see FeeHook.getHookPermissions).
                | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );
        bytes memory hookArgs = abi.encode(manager, ICreatorNFT(address(nft)), team, usdc, weth, deployer);
        (address hookAddr, bytes32 salt) = HookMiner.find(CREATE2, flags, type(FeeHook).creationCode, hookArgs);
        (bool ok,) = CREATE2.call(abi.encodePacked(salt, type(FeeHook).creationCode, hookArgs));
        require(ok && hookAddr.code.length > 0, "DeployV1: hook deploy failed (CREATE2 factory present?)");
        FeeHook hook = FeeHook(payable(hookAddr));
        ex.feeHook = hookAddr;

        // 3. Launcher + wire the fee-stream NFT and the launcher to the hook. Launch pricing per
        //    numeraire is fixed at deploy (ETH re-settable via updateEthConfig), all four from env with
        //    these defaults: a launch OPENS at 1.5 ETH / $4,000 FDV (~$4k at $2,500/ETH) and GRADUATES
        //    at 12 ETH / $30,000 (~$30k) — an 8x climb over the 400M curve, which collects
        //    0.4·√(start·cap) = ~1.7 ETH by graduation. The cap only sets the graduation mcap; depth
        //    afterwards comes from the 600M above the curve (the wall's remainder is KEPT at migration,
        //    the two rungs sit at fixed multiples of the cap): ~300 ETH in the pool at $7M FDV and
        //    ~2,700 ETH at $500M (see LauncherV1.CURVE_SUPPLY).
        LauncherV1.StartFdv[] memory fdvs = new LauncherV1.StartFdv[](2);
        fdvs[0] = LauncherV1.StartFdv({
            numeraire: address(0),
            fdvRaw: _uintOr("FDV_ETH_RAW", 1.5 ether),
            migrationTargetRaw: _uintOr("MIGRATION_ETH_RAW", 12 ether)
        });
        fdvs[1] = LauncherV1.StartFdv({
            numeraire: usdc,
            fdvRaw: _uintOr("FDV_USDC_RAW", 4_000e6),
            migrationTargetRaw: _uintOr("MIGRATION_USDC_RAW", 30_000e6)
        });
        LauncherV1 launcher = new LauncherV1(manager, IHooks(hookAddr), nft, impl, team, resolver, deployerWallet, fdvs);
        nft.setLaunchpad(address(launcher));
        hook.setLauncher(address(launcher));
        ex.launcher = address(launcher);

        // 4. The (native-ETH, USDC) conversion pool the fee hook routes ETH<->USDC through.
        //    On a chain whose canonical V4 already has this pool it is simply WIRED; on a fresh
        //    network it is created + seeded from the USDC_POOL_* env (see the helper).
        _wireOrSeedUsdcPool(manager, hook, usdc);

        // 5. $BODKIN — a real launch (first, so it holds creator NFT #0) + the buy&burn venue.
        _launchBodkin(launcher, nft, hook, usdc);

        // 6. The Universal Router + Permit2 — CANONICAL, pre-deployed contracts on Robinhood, so we
        //    only RECORD their addresses for the frontend (unlike the local deploy, which stands up a
        //    dev router because a bare anvil has neither). Defaults are the verified Robinhood mainnet
        //    Universal Router + the chain-agnostic canonical Permit2; override via env for testnet.
        ex.universalRouter = _addrOr("UNIVERSAL_ROUTER", 0x8876789976dEcBfCbBbe364623C63652db8C0904);
        ex.permit2 = _addrOr("PERMIT2", 0x000000000022D473030F116dDEE9F6B43aC78BA3);

        // 6b. The canonical v4 PositionManager — recorded for the frontend AND wired into the hook as its
        //     PRIMARY, so LP-reward claims can resolve a position NFT's owner. MUST happen before the
        //     renounce below: {setPositionManager} is one-shot + owner-only and the primary can never be
        //     replaced (further ones can only be ADDED later, by the launcher's 2-of-2). Required and
        //     checked against POOL_MANAGER on Robinhood ({_requirePositionManager}); unset elsewhere
        //     (local/bare chains) leaves claims inert until the 2-of-2 adds one.
        ex.positionManager = _addrOr("POSITION_MANAGER", address(0));
        _requirePositionManager(ex.positionManager, address(manager));
        if (ex.positionManager != address(0)) hook.setPositionManager(ex.positionManager);

        // The read-only lenses the frontend route-finder needs.
        // Lazy fallback: deploy a fresh lens ONLY when the operator hasn't supplied a canonical
        // one. Passing `new V4Quoter(...)` as a function argument would deploy it eagerly —
        // spending real ETH even when the override is set, which is exactly what it exists to avoid.
        address quoter = _addrOr("V4_QUOTER", address(0));
        ex.v4Quoter = quoter == address(0) ? address(new V4Quoter(manager)) : quoter;
        address stateViewAddr = _addrOr("STATE_VIEW", address(0));
        ex.stateView = stateViewAddr == address(0) ? address(new StateView(manager)) : stateViewAddr;

        // 7. RENOUNCE. Every hook/NFT setter existed only for the wiring above; after this the
        //    USDC + BODKIN pools can NEVER be re-pointed, and the launchpad has no admin. The
        //    one remaining tunable — the team wallet — moves only via the 2-of-2 in
        //    LauncherV1.updateTeamWallet, which has no admin either.
        hook.renounceOwnership();
        nft.renounceOwnership();

        vm.stopBroadcast();
    }

    // ── helpers ──────────────────────────────────────────────────────────────────────────

    /// @dev The deployer key: an explicit PRIVATE_KEY, or derived from a MNEMONIC (+ optional
    ///      MNEMONIC_INDEX, default 0). PRIVATE_KEY wins when both are set.
    function _deployerKey() internal view returns (uint256 pk) {
        // An empty-but-set PRIVATE_KEY= (the usual copy of .env.example next to a mnemonic) counts as
        // unset and falls through to the mnemonic instead of failing to parse.
        (bool ok, string memory pkStr) = _raw("PRIVATE_KEY");
        if (ok) return _parseUint(pkStr);
        string memory mnemonic = _str("MNEMONIC", "");
        require(bytes(mnemonic).length != 0, "DeployV1: set PRIVATE_KEY or MNEMONIC in .env");
        uint32 index = uint32(_uintOr("MNEMONIC_INDEX", 0));
        pk = vm.deriveKey(mnemonic, index);
    }

    /// @dev The dollar token the hook converts into and pays out by default. Normally the chain's
    ///      REAL one from env USDC (on Robinhood mainnet that is USDG, the Global Dollar — there is no
    ///      canonical USDC there, and the deep (ETH, USDG) V4 pools are what fee conversion routes
    ///      through). TESTNET ONLY: `USDC_DEPLOY_MOCK=true` deploys a fresh {MockUSDC} (6 decimals, the
    ///      whole 1e30 supply minted to the deployer) so the operator can seed an (ETH, mock) pool
    ///      without depending on somebody else's test token — refused on mainnet (4663) outright,
    ///      because `setUsdcPool` is one-shot + renounced and a mock there would be permanent.
    function _usdc() internal returns (address usdc) {
        if (_bool("USDC_DEPLOY_MOCK", false)) {
            require(block.chainid != 4663, "DeployV1: USDC_DEPLOY_MOCK is testnet-only (refused on Robinhood mainnet)");
            require(_bool("USDC_POOL_SEED", false), "DeployV1: a mock USDC has no pool yet - set USDC_POOL_SEED=true");
            vm.startBroadcast(_deployerKey());
            usdc = address(new MockUSDC(1e30));
            vm.stopBroadcast();
            console2.log("USDC: deployed a TESTNET MOCK (mUSDC, 6 dec) at", usdc);
            return usdc;
        }
        usdc = _addr("USDC");
    }

    /// Canonical L2 WETH on Robinhood mainnet (docs.robinhood.com) — also what the canonical Universal
    /// Router and PositionManager unwrap/wrap through on BOTH networks.
    address internal constant CANONICAL_WETH_MAINNET = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    /// @dev Guardrails for the two real networks. WETH is baked into the hook, the USD pool wiring is
    ///      one-shot and then renounced, and DEPLOY_LABEL decides which exports file the apps load — a
    ///      testnet value that slips into a mainnet deploy is PERMANENT, so refuse it before anything is
    ///      sent. Local anvil (31337) and unit tests are untouched.
    function _networkGuards(address usdc) internal view {
        address weth = _addrOr("WETH", address(0));
        if (block.chainid == 4663) {
            require(
                weth == CANONICAL_WETH_MAINNET,
                "DeployV1: on Robinhood mainnet WETH must be the canonical L2 WETH 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73"
            );
            require(usdc.code.length > 0, "DeployV1: USDC has no code on Robinhood mainnet");
            require(IERC20Metadata(usdc).decimals() == 6, "DeployV1: USDC must have 6 decimals");
            require(
                keccak256(bytes(_str("DEPLOY_LABEL", ""))) == keccak256("mainnet"),
                "DeployV1: a Robinhood mainnet deploy must use DEPLOY_LABEL=mainnet (the exports file the apps load)"
            );
        }
        if (block.chainid == 4663 || block.chainid == 46630) {
            require(
                weth == address(0) || weth.code.length > 0,
                "DeployV1: WETH has no code on this chain (a testnet address on mainnet, or the reverse?)"
            );
        }
    }

    /// @dev On the two real networks the primary PositionManager is REQUIRED and must be the real thing:
    ///      {FeeHook.setPositionManager} is one-shot and the hook is renounced right after, so an unset or
    ///      wrong value would leave every Uniswap LP position's rewards unclaimable (a further one can
    ///      only be ADDED later through the launcher's 2-of-2, never replace this). Checks: set, has code,
    ///      and bound to the same PoolManager as the hook. Local anvil and unit tests are untouched.
    function _requirePositionManager(address pm, address manager) internal view {
        if (block.chainid != 4663 && block.chainid != 46630) return;
        require(pm != address(0), "DeployV1: POSITION_MANAGER is required on Robinhood (LP rewards would be unclaimable)");
        require(pm.code.length > 0, "DeployV1: POSITION_MANAGER has no code on this chain");
        (bool ok, bytes memory ret) = pm.staticcall(abi.encodeWithSignature("poolManager()"));
        require(
            ok && ret.length >= 32 && abi.decode(ret, (address)) == manager,
            "DeployV1: POSITION_MANAGER is not bound to POOL_MANAGER"
        );
    }

    /// @dev On a chain where the (ETH, USD) pool already exists, refuse to wire a tier that is not the
    ///      DEEPEST of the canonical hookless tiers: setUsdcPool is one-shot, and every fee conversion
    ///      and bridged USD route would pay for a shallow choice forever. USDC_POOL_ALLOW_SHALLOW=true
    ///      overrides it deliberately.
    function _requireDeepestUsdcTier(IPoolManager manager, address usdc, PoolKey memory chosen) internal view {
        if (_bool("USDC_POOL_ALLOW_SHALLOW", false)) return;
        uint128 chosenL = manager.getLiquidity(chosen.toId());
        uint24[4] memory fees = [uint24(100), 500, 3000, 10000];
        int24[4] memory spacings = [int24(1), 10, 60, 200];
        for (uint256 i = 0; i < 4; i++) {
            PoolKey memory k = PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(usdc),
                fee: fees[i],
                tickSpacing: spacings[i],
                hooks: IHooks(address(0))
            });
            uint128 l = manager.getLiquidity(k.toId());
            if (l > chosenL) {
                console2.log("USDC pool: a deeper tier exists - fee / in-range liquidity", uint256(fees[i]), uint256(l));
                revert(
                    "DeployV1: USDC_POOL_FEE/TICK_SPACING is not the deepest (ETH,USDC) tier on this chain. Pick the deepest, or set USDC_POOL_ALLOW_SHALLOW=true on purpose."
                );
            }
        }
    }

    /// @dev Wire the hook's (native-ETH, USDC) conversion pool. The pool KEY is native ETH as
    ///      currency0, USDC as currency1, hook-less, at the tier given by USDC_POOL_FEE /
    ///      USDC_POOL_TICK_SPACING — those must match a real canonical pool if one exists. If
    ///      that pool is already initialised (canonical V4), it is wired as-is; otherwise it is
    ///      created at USDC_POOL_SQRT_PRICE and seeded with USDC_POOL_LIQUIDITY over a
    ///      throwaway liquidity router funded with USDC_POOL_ETH_VALUE of ETH.
    function _wireOrSeedUsdcPool(IPoolManager manager, FeeHook hook, address usdc) internal {
        uint24 fee = uint24(_uint("USDC_POOL_FEE"));
        int24 spacing = int24(int256(_uint("USDC_POOL_TICK_SPACING")));
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(usdc),
            fee: fee,
            tickSpacing: spacing,
            hooks: IHooks(address(0))
        });

        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        if (sqrtPriceX96 == 0) {
            // No pool at THIS exact tier/pairing. On a chain whose canonical V4 already lists
            // (ETH, USDC) this almost always means USDC_POOL_FEE/USDC_POOL_TICK_SPACING don't
            // match the real tier — so refuse to silently create a shallow, operator-priced
            // pool (setUsdcPool is one-shot and is renounced below, so a wrong pool is permanent)
            // unless the operator EXPLICITLY opts into seeding a brand-new one.
            require(
                _bool("USDC_POOL_SEED", false),
                "DeployV1: no (ETH,USDC) pool at USDC_POOL_FEE/TICK_SPACING. Fix the tier to match the canonical pool, or set USDC_POOL_SEED=true to create + seed a new one."
            );
            uint160 sqrtPrice = uint160(_uint("USDC_POOL_SQRT_PRICE"));
            uint256 ethValue = _uint("USDC_POOL_ETH_VALUE");
            require(sqrtPrice != 0 && ethValue != 0, "DeployV1: USDC_POOL_SQRT_PRICE and USDC_POOL_ETH_VALUE are required to seed");
            // Full-range liquidity from the ETH leg alone when USDC_POOL_LIQUIDITY is unset/0: over the
            // whole range L = amount0 * sqrtP / 2^96 (ETH is currency0), and the USDC leg that goes with
            // it is amount1 = L * sqrtP / 2^96 = ethValue * price. Saves the operator a hand calculation.
            int256 liquidity = int256(_uintOr("USDC_POOL_LIQUIDITY", 0));
            if (liquidity == 0) liquidity = int256(FullMath.mulDiv(ethValue, sqrtPrice, FixedPoint96.Q96));
            uint256 usdcNeeded = FullMath.mulDiv(uint256(liquidity), sqrtPrice, FixedPoint96.Q96) + 1;
            require(
                IERC20(usdc).balanceOf(vm.addr(_deployerKey())) >= usdcNeeded,
                "DeployV1: deployer holds less USDC than the seed needs (USDC_POOL_ETH_VALUE x price)"
            );
            console2.log("USDC pool: seeding with liquidity", uint256(liquidity));
            console2.log("USDC pool: ETH leg (wei) / USDC leg (raw)", ethValue, usdcNeeded);
            manager.initialize(key, sqrtPrice);
            PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
            IERC20(usdc).approve(address(lp), type(uint256).max);
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
            console2.log("USDC pool: SEEDED a NEW (ETH,USDC) pool at fee/spacing", fee, uint256(int256(spacing)));
        } else {
            _requireDeepestUsdcTier(manager, usdc, key);
            console2.log("USDC pool: WIRED the existing (ETH,USDC) pool; sqrtPriceX96 =", uint256(sqrtPriceX96));
        }
        hook.setUsdcPool(key);
        ex.usdcPoolId = PoolId.unwrap(key.toId()); // ETH/USD reference for the indexer
        ex.usdcPoolFee = fee;
        ex.usdcPoolTickSpacing = spacing;
        // Surface the in-range liquidity so a dry-run operator can sanity-check the wired pool
        // before broadcasting — a near-zero value here means fee conversions would barely route.
        console2.log("USDC pool: in-range liquidity =", uint256(manager.getLiquidity(key.toId())));
    }


    /// @dev BODKIN's launch salt. Every coin created through the site is launched under a salt mined
    ///      so its address ends in the platform suffix `b0d41`, and the local deploy does the same for
    ///      its own tokens — the production BODKIN was the one coin that did not, which is exactly
    ///      backwards for the flagship. It is mined here the same way, off-chain via node because a
    ///      million-keccak search in Solidity is not viable, and namespaced to this deployer by the
    ///      launcher itself (it hashes msg.sender into the salt).
    ///
    ///      `BODKIN_SALT` pins it instead when set, as a 0x-prefixed 32-byte value: an escape hatch for
    ///      a box without node, and what the tests use so they do not shell out on every deploy. The
    ///      address depends on the launcher, which this script creates, so a pinned salt has to come
    ///      from a dry run of THIS deploy — not from thin air. Whatever the source, it must be nonzero;
    ///      see {BODKIN_SALT_FALLBACK} for what a zero salt would expose.
    function _bodkinSalt() internal returns (bytes32 salt) {
        string memory pinned = _str("BODKIN_SALT", "");
        if (bytes(pinned).length > 0) {
            salt = vm.parseBytes32(pinned);
            require(salt != bytes32(0), "DeployV1: BODKIN_SALT must not be zero");
            return salt;
        }
        string[] memory cmd = new string[](6);
        cmd[0] = "node";
        cmd[1] = "scripts/mine-vanity-salt.mjs";
        cmd[2] = vm.toString(ex.deployer);
        cmd[3] = vm.toString(ex.launcher);
        cmd[4] = vm.toString(ex.launchTokenImpl);
        cmd[5] = vm.toString(address(0)); // ETH-quoted: no sort constraint against a numeraire
        bytes memory out = vm.ffi(cmd);
        require(out.length == 32, "DeployV1: mine-vanity-salt did not return a 32-byte salt");
        assembly {
            salt := mload(add(out, 0x20))
        }
        require(salt != bytes32(0), "DeployV1: mined salt must not be zero");
    }

    /// @dev Launch $BODKIN like any token — hooked pool, single-sided locked position, USDC
    ///      payout, creator NFT to the deployer, the standard dev buy as its first trade — then
    ///      wire its pool as the buy&burn venue. BODKIN MUST be the first launch so it holds
    ///      creator NFT #0 (asserted).
    function _launchBodkin(LauncherV1 launcher, CreatorNFT nft, FeeHook hook, address usdc) internal {
        // The standard BODKIN dev buy (same on local, testnet and mainnet); env overrides it.
        uint256 devBuy = _uintOr("BODKIN_DEV_BUY", 0.138 ether);
        bytes32 bodkinSalt = _bodkinSalt();
        ex.bodkinSalt = bodkinSalt;
        address bodkin = launcher.launch{value: 0.0005 ether + devBuy}(
            _str("BODKIN_NAME", "Bodkin"),
            _str("BODKIN_SYMBOL", "BODKIN"),
            _strReq("BODKIN_METADATA_URI"), // required: a pre-pinned ipfs://…/metadata.json
            bodkinSalt, // mined for the platform suffix; always nonzero, which is what pins the address
            address(0), // ETH-quoted pool (the default)
            devBuy,
            LauncherV1.PayoutParams({
                token: usdc, // team/creator BODKIN fees paid in USDC
                viaHub: false, wethPaired: false,
                fee: 0,
                tickSpacing: 0,
                // Autocompound OFF for BODKIN: its 10% slice rolls into the creator (team) cut instead of
                // self-compounding its own pool. Per-coin launch config, so no hook special case.
                feeRecipient: ex.team, autocompoundOff: true, creatorFeeBps: 0, lpFeeBps: 0, lpRewardsOff: false // NFT #0 (BODKIN's fee stream) to the TEAM wallet
            })
        );
        // On the real networks BODKIN must carry the platform suffix, like every launch from the site.
        // A MINED salt always delivers it; a pinned BODKIN_SALT only does so for the addresses THIS run
        // produces, and the launcher is created from the deployer's NONCE — so one stray transaction
        // from that wallet between the mining and the deploy shifts it, and the same salt then yields an
        // ordinary address. Nothing else in the deploy looks at the suffix and the token is immutable,
        // so the miss would be silent and permanent. Local anvil and unit tests are untouched.
        if (block.chainid == 4663 || block.chainid == 46630) {
            require(
                uint160(bodkin) & 0xFFFFF == 0xB0D41,
                "DeployV1: BODKIN lost the b0d41 suffix - a pinned BODKIN_SALT is stale for this deployer/nonce"
            );
        }
        require(nft.nftOf(bodkin) == 0, "DeployV1: BODKIN must be the first launch (creator NFT #0)");
        require(nft.creatorOf(bodkin) == ex.team, "DeployV1: BODKIN fee NFT must sit with the team wallet");
        hook.setBodkinPool(launcher.poolKeyOf(bodkin));
        ex.bodkin = bodkin;
    }

    /// @dev Serialize {ex} to exports/v1.<label>.json (own frame — via-IR stack limit). The
    ///      label is DEPLOY_LABEL, or the chain id when unset.
    function _writeExports() internal {
        string memory obj = "v1";
        vm.serializeUint(obj, "chainId", ex.chainId);
        vm.serializeAddress(obj, "poolManager", ex.poolManager);
        vm.serializeAddress(obj, "feeHook", ex.feeHook);
        vm.serializeAddress(obj, "launcher", ex.launcher);
        vm.serializeAddress(obj, "universalRouter", ex.universalRouter); // canonical Robinhood UR
        vm.serializeAddress(obj, "permit2", ex.permit2); // canonical Permit2
        vm.serializeAddress(obj, "positionManager", ex.positionManager); // canonical v4 PositionManager
        vm.serializeAddress(obj, "v4Quoter", ex.v4Quoter);
        vm.serializeAddress(obj, "stateView", ex.stateView);
        vm.serializeBytes32(obj, "usdcPoolId", ex.usdcPoolId);
        vm.serializeBytes32(obj, "bodkinSalt", ex.bodkinSalt);
        vm.serializeUint(obj, "usdcPoolFee", uint256(ex.usdcPoolFee));
        vm.serializeInt(obj, "usdcPoolTickSpacing", int256(ex.usdcPoolTickSpacing));
        vm.serializeAddress(obj, "creatorNFT", ex.creatorNFT);
        vm.serializeAddress(obj, "launchTokenImpl", ex.launchTokenImpl);
        vm.serializeAddress(obj, "usdc", ex.usdc);
        vm.serializeAddress(obj, "weth", ex.weth); // address(0) = WETH-paired payouts disabled
        vm.serializeAddress(obj, "bodkin", ex.bodkin);
        vm.serializeAddress(obj, "team", ex.team);
        vm.serializeAddress(obj, "deployerWallet", ex.deployerWallet);
        vm.serializeAddress(obj, "deployer", ex.deployer);
        // The L2 block to start the indexer/resolver from. NOT `block.number`: on an Arbitrum-family
        // chain forge mirrors the chain's own semantics, where block.number is the PARENT (L1) block
        // — on Robinhood testnet that wrote 11.7M (Sepolia) instead of 120.9M (L2), and an indexer
        // started there would replay 109M empty blocks. eth_blockNumber on the fork URL is the L2 head.
        uint256 deployBlock = _l2BlockNumber();
        string memory json = vm.serializeString(obj, "deployBlock", vm.toString(deployBlock));

        // Length-guard like _deployerKey: a set-but-empty DEPLOY_LABEL= (the usual copy from
        // .env.example) must fall back to the chain id, not write the misnamed "v1..json".
        string memory label = _str("DEPLOY_LABEL", "");
        if (bytes(label).length == 0) label = vm.toString(ex.chainId);
        vm.writeJson(json, string.concat("./exports/v1.", label, ".json"));

        console2.log("Bodkin v1 deployed on chain", ex.chainId);
        console2.log("  launcher:", ex.launcher);
        console2.log("  feeHook: ", ex.feeHook);
        console2.log("  bodkin:  ", ex.bodkin);
        // The block to start the indexer from. Everything above is deployed at or after this
        // height, so START_BLOCK = deployBlock catches every launch/swap/fee from the first one
        // (the indexer is idempotent + a launcher emits nothing before it exists, so starting a
        // little early is always safe, never lossy). Also written to exports/v1.<label>.json.
        console2.log("  deployBlock:", deployBlock);
        console2.log(">> Start the indexer here: set START_BLOCK to the deployBlock above.");
        console2.log(">> Then: node scripts/export-abis.mjs, and in each frontend: npm run sync-contracts -- --label", label);
    }

    /// The chain's own latest block via `eth_blockNumber` on the fork URL (the L2 height on an
    /// Arbitrum-family chain). Falls back to `block.number` when there is no fork (unit tests).
    function _l2BlockNumber() internal returns (uint256) {
        try vm.rpc("eth_blockNumber", "[]") returns (bytes memory raw) {
            uint256 n;
            for (uint256 i = 0; i < raw.length; i++) n = (n << 8) | uint8(raw[i]);
            return n == 0 ? block.number : n;
        } catch {
            return block.number;
        }
    }
}
