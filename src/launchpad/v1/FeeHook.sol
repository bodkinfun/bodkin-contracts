// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";

/// @dev Minimal wrapped-ETH surface the hook needs to convert a creator payout into a V4
///      (WETH, token) pool: turn native ETH into WETH before the swap.
interface IWETH {
    function deposit() external payable;
}

/// @dev Minimal ERC-20 metadata surface used only to sanity-check a fee-infra address before a
///      2-of-2 re-point ({setFeeToken} / {migrateUsdc}): a real token answers `decimals()`.
interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

/// @dev Minimal view into the CreatorNFT — resolves who currently owns a launch's
///      fee stream (the transferable creator NFT holder).
interface ICreatorNFT {
    function creatorOf(address token) external view returns (address);
}

/// @dev Minimal view into the Uniswap v4 PositionManager — resolves the CURRENT owner of a liquidity
///      position NFT. The hook keys external LP rewards on the position's NFT (its `salt` == the
///      tokenId), so an owner who added liquidity on Uniswap OR on our own site can always claim.
interface IPositionManagerMinimal {
    function ownerOf(uint256 tokenId) external view returns (address);
    /// The account driving the PositionManager's current unlock (owner or approved operator of the
    /// position being modified). Read during a BURN, when the NFT is already gone — see {_rememberLpOwner}.
    function msgSender() external view returns (address);
    /// The PoolManager this PositionManager is bound to (v4-periphery ImmutableState). Checked when a
    /// PositionManager is added to the list, so only one that can hold liquidity in OUR pools is accepted.
    function poolManager() external view returns (IPoolManager);
}

/// @title FeeHook (Uniswap V4)
/// @notice Takes the launchpad's 1% platform fee ON THE NUMERAIRE SIDE of every swap
///         — never in the launched token — so the meme leg is never touched (no dump,
///         no keeper bot). A launch pool is (numeraire = currency0, token = currency1)
///         where the numeraire is native ETH or USDC; the launcher guarantees
///         `token > numeraire` so the numeraire is always currency0. The pool's own LP
///         fee is 0 — this hook IS the fee. Every swap is exact-input; buys take the
///         fee in `beforeSwap` off the numeraire input, sells in `afterSwap` off the
///         numeraire output; exact-output is rejected.
///
///         The fee accrues in that pool's numeraire, split 35% creator / 25% LP / 10% burn /
///         10% autocompound / 20% team, and is pull-claimed — except that the team's slice for a token also
///         rides out on that token's creator claim, so it does not sit banked waiting
///         for a second transaction. On claim it is converted to the party's
///         PAYOUT TOKEN (USDC by default; ETH or any Uniswap-routable token can be
///         chosen once at launch) via a {Route} of 0, 1 or 2 hops built inside this
///         contract — never from calldata.
interface ILauncherHookView {
    function curvePositions(address token) external view returns (int24 tickLower, int24 tickUpper, uint128 liquidity, bool migrated);
    /// The pool the launcher opened for `token`. Read by {FeeHook.setBodkinPool} to prove a self-hooked
    /// burn venue really is that token's launch pool, and not a look-alike key.
    function poolKeyOf(address token) external view returns (PoolKey memory);
}

contract FeeHook is BaseHook, IUnlockCallback {
    using CurrencySettler for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant BPS = 10_000;
    uint16 public constant FEE_BPS = 100; // 1% platform fee (on the ETH side)
    uint16 public constant CREATOR_BPS = 3_500; // 35% -> creator (was 60%; 25% moved to LP)
    uint16 public constant LP_BPS = 2_500; // 25% -> external LP providers active at the price (any range; see _creditLp)
    uint16 public constant BURN_BPS = 1_000; // 10% -> BODKIN buy&burn
    uint16 public constant AUTOCOMPOUND_BPS = 1_000; // 10% -> back into THIS coin's OWN pool
    // team = remainder (2000 = 20%). Sum: 3500+2500+1000+1000+2000 = 10000.
    /// Max optional custom creator fee: 5% (500 bps), charged ON TOP of FEE_BPS and paid 100% to the
    /// creator. Set once per coin at launch. Bounds the extra a trader can ever be charged.
    uint16 public constant MAX_CREATOR_FEE_BPS = 500;
    /// Max optional custom LP fee: 5% (500 bps), charged ON TOP of FEE_BPS and paid 100% to external
    /// full-range LPs (folds to the creator when none). Set once per coin at launch.
    uint16 public constant MAX_LP_FEE_BPS = 500;
    /// Fee-per-liquidity accumulators are scaled by 2**128 so a tiny per-swap slice divided by a large
    /// liquidity does not truncate to zero. Same fixed-point Uniswap itself uses for fee growth.
    uint256 internal constant LP_FEE_GROWTH_Q128 = 1 << 128;

    /// Launch-pool geometry — every launch pool is created with this tick spacing and a 0 LP fee, and
    /// its migrated liquidity lives in ONE full-range position `[MIN_USABLE, MAX_USABLE]` (salt 0). These
    /// mirror {LauncherV1} exactly: `(MIN_TICK / 60) * 60 + 60` and `(MAX_TICK / 60) * 60 - 60`. The
    /// in-hook autocompound deepens THAT position, so it must add at the identical range. MIN_USABLE read
    /// -887220 until the tick-saturation fix below: one spacing WIDER than the launcher's migrated range,
    /// so autocompound added across a boundary the migration never used — a third protocol tick to defend,
    /// and one honest full-range providers do land on (a Uniswap UI's "full range" at spacing 60 is
    /// [-887220, 887220]). Both protocol positions now share the launcher's exact pair.
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant MIN_USABLE = -887160;
    int24 internal constant MAX_USABLE = 887160;

    /// v4-core caps the GROSS liquidity that may reference any single tick (`tickSpacingToMaxLiquidityPerTick`,
    /// ~type(uint128).max / 29576 at spacing 60) and reverts `TickLiquidityOverflow` on the add that would
    /// exceed it. Liquidity at the extreme ticks is almost free — the amount a given L needs shrinks towards
    /// the range ends — so for ~2e-6 ETH an outsider could saturate exactly the two ticks the protocol's own
    /// positions sit on, and from then on EVERY protocol add referencing them reverts for good: migrate()
    /// could never complete (and the pre-migration trading freeze lifts only on `migrated`, so the coin
    /// froze permanently), and post-migration autocompound could never deepen the position while its bank
    /// kept growing. Their own dust position is theirs; nobody can remove it. So these two ticks are
    /// RESERVED: {_afterAddLiquidity} rejects an outside add that uses either as a boundary. Honest ranges
    /// are untouched — including the UI full range, which sits one spacing outside on both sides.
    int24 internal constant RESERVED_TICK_LO = MIN_USABLE;
    int24 internal constant RESERVED_TICK_HI = MAX_USABLE;

    /// There is deliberately NO dust floor on the burn / conversion / autocompound steps: the per-block
    /// size cap and the price band already bound every step, and a small bucket converting sooner is
    /// preferred over waiting for it to grow.

    /// Tags the {unlockCallback} payload: a {Route} (burn / conversion) vs an autocompound on one pool.
    uint8 private constant _ACT_ROUTE = 0;
    uint8 private constant _ACT_COMPOUND = 1;

    /// @notice How far BODKIN may have got more expensive since the PREVIOUS BLOCK
    ///         before the buy & burn waits a block rather than buying into it. 2%.
    ///
    /// The size cap alone does not bound the loss. It bounds ONE block's forced buying
    /// at roughly the sandwich break-even, but an attacker need not close in one block:
    /// displace the price once, hold it, and let a chunk buy into it every block until
    /// the buckets are dry — the round-trip toll is paid once while the extraction
    /// accrues over the whole pot. Simulated on a 100-ETH pool against a pot of ten
    /// chunks, the attacker takes 80.6% of it with no band and 7.9% with this one.
    ///
    /// The band cannot be escaped by simply waiting, because the reference advances
    /// every block: the attacker can walk the price down by at most BURN_SLIPPAGE_BPS
    /// per block, and pays for every step of it. That ratchet is why this leaks more
    /// than a frozen reference would (1.8% at the same width) — and a frozen reference
    /// is not on the table, because a step that only refreshes when it SUCCEEDS can
    /// never recover once it has been blocked. That version stalled permanently under
    /// test: six blocks of ordinary trading with the bucket growing and nothing
    /// converting.
    ///
    /// 2% rather than 1% (which would leak 4.2%) to skip fewer blocks in ordinary
    /// volatility. Neither can deadlock; the tighter band only makes the burn wait more
    /// often. `constant`, like the fee split — the launchpad ships ownerless.
    /// Buy & burn / conversion GATE band: 2%. See the essay above.
    uint16 public constant BURN_SLIPPAGE_BPS = 200;
    /// sqrt(1 - 200/1e4) = 0.98995 and sqrt(1 + 200/1e4) = 1.00995, each rounded toward
    /// 1 so a clamped step can never exceed the band. Companions to the constant above:
    /// change one and both must move.
    uint256 internal constant BURN_SQRT_BAND_LO_BPS = 9_900;
    uint256 internal constant BURN_SQRT_BAND_HI_BPS = 10_099;

    /// Autocompound GATE band — SEPARATE from the buy & burn's (per-venue by design). The autocompound
    /// venue is the coin's OWN pool, not the shared BODKIN pool, so it gets its own reference walk + width
    /// and can be tuned independently. 2% by default (same validated sweet spot); tighten toward 1% to
    /// leak less at the cost of skipping more of a volatile coin's blocks.
    uint16 public constant COMPOUND_SLIPPAGE_BPS = 200;
    uint256 internal constant COMPOUND_SQRT_BAND_LO_BPS = 9_900;
    uint256 internal constant COMPOUND_SQRT_BAND_HI_BPS = 10_099;

    /// EXECUTION limit (the second, independent guard): each internal swap carries a hard
    /// `sqrtPriceLimitX96` derived ON-CHAIN from the pool's banded reference — never from a caller — so
    /// the swap PARTIAL-FILLS (→ the step reverts → it simply waits a block) rather than executing more
    /// than this far from the trusted price. It is a backstop ON TOP of the size cap + gate band: a
    /// front-run/thin pool that would push the fill past the limit gets no fill at all, killing the
    /// residual leak the gate alone allows. Sized LOOSER than each venue's own price impact so a healthy
    /// swap always clears: the burn chunk is `_safeBurnChunk` = poolFee·x (~0.3%·x on the 0.3% BODKIN
    /// pool → ~0.6% impact), the compound half is FEE_BPS·x (1%·x on the self-hooked own pool → ~2%
    /// impact), so compound's limit is the wider of the two. Values are sqrt-space bps (×1e4):
    /// burn ±4% price → sqrt(0.96)=9797.9, sqrt(1.04)=10198.0; compound ±6% → sqrt(0.94)=9695.4,
    /// sqrt(1.06)=10295.6, each rounded INWARD so the limit never exceeds the intended band.
    uint256 internal constant BURN_SWAP_LIMIT_LO_BPS = 9_798;
    uint256 internal constant BURN_SWAP_LIMIT_HI_BPS = 10_198;
    uint256 internal constant COMPOUND_SWAP_LIMIT_LO_BPS = 9_696;
    uint256 internal constant COMPOUND_SWAP_LIMIT_HI_BPS = 10_295;

    ICreatorNFT public immutable creatorNFT;
    /// @notice The team's fee wallet — receives the 20% team slice and is the only address
    ///         allowed to claim it. NOT immutable: the launcher's 2-of-2 governance
    ///         (deployer + the CURRENT team, each signing off-chain) re-points it via
    ///         {setTeam}. The hook owner cannot — {setTeam} is launcher-only — so the only
    ///         way to move a live team stream is with the current team's own consent. The
    ///         payout TOKEN ({teamPayoutToken}) stays immutable; only the wallet moves.
    address public team;
    /// @notice The platform's canonical USDC: the default creator/team payout token, an allowed
    ///         launch numeraire, and the bridge hub the fee routes convert through. NOT immutable —
    ///         the launcher's 2-of-2 governance ({LauncherV1.updateUsdc} -> {migrateUsdc}) can
    ///         re-point it to a migrated USDC contract in ONE atomic action that also re-wires the
    ///         (ETH, usdc) conversion pool, the team payout token and the allow-list. This is safe
    ///         only because banked fees are keyed by their ACTUAL currency address (creator slices by
    ///         the per-launch pinned {payoutTokenOf}; team slices per-currency in {teamOut}), so
    ///         already-banked OLD-usdc fees stay claimable in OLD usdc after the re-point — nothing is
    ///         re-denominated. Existing OLD-usdc-numeraire launches keep their pinned {numeraireOf}.
    address public usdc;

    /// @notice A deployer-controlled ops role that SURVIVES the {owner} renounce. It maintains ONLY the
    ///         team payout-token allow-list ({setTeamPayoutAllowed}) — and nothing else (it cannot touch
    ///         weth, usdc, the launcher, the BODKIN pool, fees, or the split; the fee-infra addresses are
    ///         governed by the launcher's 2-of-2, not this role). Set to the deployer at construction;
    ///         renounceable to address(0) via {setDeployer}. The blast radius of a compromised deployer key is
    ///         small — it can only widen/narrow the set of tokens the 2-of-2 may later choose to pay in.
    address public deployer;

    address public owner;
    /// @notice The launcher — the only address allowed to open pools on this hook or
    ///         record a launch's config.
    address public launcher;
    /// @notice (native ETH, USDC) V4 pool the hook swaps through to pay USDC.
    PoolKey internal _usdcPool;
    bool internal _usdcPoolSet;
    /// @notice (native ETH, BODKIN) V4 pool for the 10% burn bucket's buy&burn.
    PoolKey internal _bodkinPool;
    bool internal _bodkinPoolSet;
    address public bodkin;
    /// @notice Wrapped ETH, wired at construction and re-pointable ONLY via the launcher's 2-of-2
    ///         ({LauncherV1.updateFeeToken} -> {setFeeToken}(FEE_TOKEN_WETH)). A custom creator-payout
    ///         token whose liquidity is a V4 (WETH, token) pool converts through this: the
    ///         hook wraps native ETH -> WETH, then swaps. address(0) = WETH payouts disabled
    ///         (a chain or test with no WETH); such a payout choice is rejected at launch.
    ///         Only V4 WETH pools — V2/V3 WETH liquidity is out of scope (numeraire fallback).
    address public weth;

    /// @notice {setFeeToken} selectors. Kept as a small uint8 set (not a Solidity enum) so the
    ///         launcher interface can forward the raw value and the EIP-712 payload can hash a `uint8`.
    uint8 public constant FEE_TOKEN_USDC = 0;
    uint8 public constant FEE_TOKEN_WETH = 1;
    /// @notice Team payout currency — USDC at deploy, re-pointable through the launcher's 2-of-2
    ///         governance ({setTeamPayoutToken}: native ETH or an allowed token; and swung to the new
    ///         USDC atomically by {migrateUsdc}). Safe to flip FREELY: team fees are banked PER
    ///         CURRENCY in {teamOut}, so a converted slice always stays keyed to the currency it was
    ///         banked in and is delivered in that same currency regardless of a later flip — no
    ///         drain-first guard is needed. `teamWei` (still the pool numeraire, unconverted) simply
    ///         converts into the new token on its next step.
    address public teamPayoutToken;
    /// @notice The set of ERC-20s the team may choose as its payout token ({setTeamPayoutToken}),
    ///         besides native ETH (always allowed). Seeded with `usdc` at deploy; deployer-extendable
    ///         so a migrated USDC contract can be added without a redeploy — the choice is never
    ///         frozen to one hardcoded address.
    mapping(address => bool) public teamPayoutAllowed;

    /// @notice Every currency team fees have EVER been banked in, across all launches — the iteration
    ///         set for the multi-currency team claim ({claimTeam}). A permissionless swap only ever
    ///         banks into the CURRENT {teamPayoutToken}, so this set grows ONLY when governance points
    ///         teamPayoutToken at a new currency ({setTeamPayoutToken}/{migrateUsdc}) or at
    ///         construction — never on the hot swap path. Native ETH is address(0). Bounded by
    ///         {MAX_TEAM_CURRENCIES} so a claim can never iterate unboundedly (an anti-grief cap on the
    ///         2-of-2 itself). {teamOut} is keyed (token => currency => amount).
    address[] public teamBankedCurrencies;
    mapping(address => bool) public teamCurrencyKnown;
    uint8 public constant MAX_TEAM_CURRENCIES = 8;

    /// @notice A launch's creator-fee payout settings, chosen ONCE at creation and
    ///         immutable thereafter (see {setLaunchConfig}).
    /// @param token     payout currency: address(0) = ETH, `usdc`, or any custom token.
    /// @param viaHub    custom token only: reach the payout token by bridging through
    ///                  the OTHER canonical currency (numeraire→hub→token, 2 hops)
    ///                  instead of a direct (numeraire, token) pool. Set when the
    ///                  token's liquidity is against the hub, not this numeraire.
    /// @param fee       fee tier of the custom leg's pool (canonical tiers only).
    /// @param tickSpacing tick spacing of that pool.
    /// @param numeraire the launch pool's quote currency — address(0) = native ETH,
    ///                  or `usdc`. ALWAYS the pool's currency0 (the launcher enforces
    ///                  token > numeraire), so this is also the currency the fee
    ///                  buckets below accrue in.
    /// @param set       true once configured — the one-time latch.
    struct PayoutConfig {
        address token;
        bool viaHub;
        /// Custom token only: its liquidity is a V4 (WETH, token) pool, so the hook wraps
        /// native ETH -> WETH to convert into it. Takes precedence over {viaHub}. Converted
        /// ONLY on the permissionless {processConvert} path (the wrap must not ride a
        /// stranger's swap); a swap-time step leaves the slice pending instead.
        bool wethPaired;
        uint24 fee;
        int24 tickSpacing;
        address numeraire;
        /// Creator's choice at launch: if true, the coin does NOT autocompound — its 10%
        /// autocompound slice rolls into the creator cut instead (see _accrue). Default false = on.
        bool autocompoundOff;
        /// Optional custom creator fee, 0..500 bps (0..5%), charged ON TOP of the 1% platform fee and
        /// paid 100% to the creator. 0 = none. Validated by the launcher.
        uint16 creatorFeeBps;
        /// Optional custom LP fee, 0..500 bps (0..5%), charged ON TOP of the 1% platform fee and paid
        /// 100% to external full-range LPs (folds to the creator when none). 0 = none. Validated by the launcher.
        uint16 lpFeeBps;
        /// Creator's choice at launch: if true, this coin has NO LP-reward program — the base 25% LP
        /// slice (and any custom LP fee) all go to the creator instead of external LPs (see _creditLp).
        /// Default false = LP rewards on.
        bool lpRewardsOff;
        /// The {weth} / {usdc} this launch's route was CHOSEN against, snapshotted at {setLaunchConfig}
        /// (each set only when the route actually uses it, else address(0)). The 2-of-2 can re-point both
        /// — that is the escape hatch for a deprecated numeraire — but a re-point must never RETARGET an
        /// existing launch: `weth` is the contract the hook wraps real ETH into, and the hub is the pool a
        /// viaHub conversion's first leg crosses, so a new address silently moved a creator's already
        /// banked fees into whatever the new address does. Validation cannot save this (the checks are
        /// "has code", "18 decimals", "an initialised plain pool" — a hostile contract passes all three),
        /// so the route is pinned instead: when the live address no longer matches its snapshot, the
        /// conversion takes the existing dry-route path and the slice is handed over in the numeraire.
        /// Nothing is lost, and launches created after the re-point simply snapshot the new address.
        address wethAt;
        address usdcAt;
        bool set;
    }

    /// @notice Per-launch payout config; unset = default (USDC to the NFT holder).
    mapping(address => PayoutConfig) internal _payoutCfg;

    // Accrued fees per launch token, per bucket, denominated in THAT launch's
    // numeraire (wei for an ETH pool, micro-USDC for a USDC pool).
    // Pull-claimed by each party.
    mapping(address => uint256) public creatorWei;
    mapping(address => uint256) public burnWei;
    mapping(address => uint256) public teamWei;
    /// @notice Per-coin autocompound bank: the 10% slice of each coin's fee, held in the coin's
    ///         numeraire (as ERC-6909 claims this hook already owns), waiting to be folded back into THAT
    ///         coin's OWN locked full-range position by the in-hook {compoundStep}. Strictly per-coin — a
    ///         coin's fees only ever deepen its own pool, never BODKIN's or any other's.
    mapping(address => uint256) public autocompoundWei;
    /// @notice Per-coin autocompound pacing marker: one compound per token per block (mirrors
    ///         {lastBurnBlock}), so a whale swap does not force many compounds in one block.
    mapping(address => uint256) public lastCompoundBlock;
    /// @notice Token-side remainder carried between compounds. A full-range add deploys the LIMITING side
    ///         fully and leaves a sub-percent dust of the other; when that is the token side, the claims
    ///         are parked here and folded into the NEXT compound's token input rather than stranded.
    mapping(address => uint256) internal compoundTokenDust;

    // ── External LP-provider rewards (the 25% LP slice) ───────────────────────────────────────────
    /// @notice The PRIMARY Uniswap v4 PositionManager (the canonical one at deploy). Resolves the current
    ///         owner of a position NFT on claim, so rewards reach whoever holds the liquidity — added on
    ///         Uniswap or on our site alike. One-shot ({setPositionManager}); until set, LP rewards accrue
    ///         but cannot be claimed. The two-argument claim/view functions use it.
    address public positionManager;
    bool internal _positionManagerSet;
    /// @notice Every PositionManager whose positions can claim LP rewards: the primary plus any added
    ///         later by the launcher's 2-of-2 ({addPositionManager}) — e.g. when Uniswap ships a new
    ///         PositionManager and LPs start minting through it. ADD-ONLY: a listed PositionManager is
    ///         never removed, because its positions' rewards are keyed under its address.
    mapping(address => bool) public isPositionManager;
    address[] internal _positionManagerList;
    /// @notice Numeraire-per-unit-of-ACTIVE-liquidity accumulator (Q128), per coin. A swap's LP slice
    ///         divided by the external liquidity active at the current tick is added here. Together
    ///         with per-tick `feeGrowthOutside` snapshots ({_lpTicks}) this is Uniswap v3's own
    ///         fee-growth accounting, re-implemented for the hook's numeraire slice — so a position
    ///         earns exactly while the price is inside its range, whatever that range is.
    mapping(address => uint256) public lpFeeGrowthGlobalX128;
    /// @notice External liquidity ACTIVE at the current tick, per coin — the accumulator's denominator.
    ///         Excludes the coin's own locked positions (launcher + this hook's autocompound adds), so the
    ///         LP slice goes UNDILUTED to real providers. Kept in step with the price by {_syncLpTick}
    ///         (tick crossings on every swap) and by adds/removes whose range contains the tick.
    mapping(address => uint256) public lpLiquidity;
    /// @notice Numeraire (as ERC-6909 claims the hook already holds) set aside for LP payouts, per coin.
    mapping(address => uint256) public lpBankWei;
    /// @dev One initialized tick of the external-LP book (Uniswap's `Tick.Info`, numeraire-only):
    ///      gross liquidity referencing it (0 = uninitialized), net liquidity change when crossed
    ///      upward, and the fee growth on the OTHER side of it relative to the current tick.
    ///
    ///      `feeGrowthOutsideX128` is stored BIASED BY ONE so the slot is never zero while the tick
    ///      exists, and the reason is gas, not arithmetic. Crossing a tick rewrites this slot; a write
    ///      that takes a slot from zero to non-zero costs 20,000 gas, a write between two non-zero
    ///      values ~2,900. Unbiased, the common case (a tick above the price, initialized to 0) put that
    ///      20,000 on the first TRADER to cross it — and an attacker could reinstate it at will by
    ///      removing and re-adding the position. Biased, the expensive write happens once, when the tick
    ///      is created, and is paid by whoever created it. Only differences of these values are ever
    ///      meaningful, so the bias cancels; every read subtracts it and every write adds it back.
    struct LpTick {
        uint128 liquidityGross;
        int128 liquidityNet;
        uint256 feeGrowthOutsideX128;
    }
    mapping(address => mapping(int24 => LpTick)) internal _lpTicks;
    /// @dev Which ticks of the external-LP book are initialized, per coin — Uniswap's own packed layout
    ///      (one bit per tick-spacing step, 256 steps to a word), walked with v4-core's {TickBitmap} the
    ///      same way the PoolManager walks its own. It replaced a sorted array that every swap scanned
    ///      end to end, which forced a cap of 64 distinct boundaries: 32 dust positions could take every
    ///      slot for nothing and lock out every later range. Finding the next initialized tick is now a
    ///      single word read whatever the book holds, so the cap is gone, and an add no longer pays for an
    ///      insertion sort. A swap's cost follows how FAR the price moved (one word ≈ a 4.6x price span),
    ///      not how many ticks exist — and the PoolManager has already walked the same distance over its
    ///      own bitmap before this hook is called.
    mapping(address => mapping(int16 => uint256)) internal _lpBitmap;
    /// @dev How many ticks that bitmap holds. Only so a coin with NO external LP — the common case, and
    ///      every coin until someone adds one — skips the walk entirely instead of reading a word to
    ///      learn it is empty. Maintained by the same two calls that flip a bit.
    mapping(address => uint32) internal _lpTickCount;
    /// @dev The tick the LP book was last synced to (== the pool's tick after every swap) and whether
    ///      it has been initialized at all (lazily, on the first external add or swap).
    mapping(address => int24) internal _lpTick;
    mapping(address => bool) internal _lpTickInit;
    /// @dev Gas cap for one owner read (`ownerOf` / `msgSender`) on the contract that added liquidity —
    ///      ample for a real PositionManager (a couple of storage reads), and it bounds what any adder can
    ///      make an add/remove or a claim spend. See {_readAddr}.
    uint256 internal constant LP_OWNER_READ_GAS = 50_000;
    /// @dev One tracked external position (posKey = keccak(token, sender, salt)): its range, liquidity,
    ///      fee-growth-inside snapshot at the last checkpoint, and numeraire already checkpointed as
    ///      owed (claimable by the position NFT's owner).
    struct LpPosition {
        uint128 liquidity;
        int24 tickLower;
        int24 tickUpper;
        uint256 growthInsideLastX128;
        uint256 owedWei;
        /// The position NFT's owner as last seen by this hook (refreshed on every add/remove through
        /// the PositionManager). What {claimLpRewards} pays once the NFT no longer exists: the
        /// PositionManager BURNS the NFT before it removes the liquidity, so without this a position
        /// closed on Uniswap would leave its unclaimed reward unreachable forever.
        address lastOwner;
    }
    mapping(bytes32 => LpPosition) internal _lpPos;

    error ExactOutputUnsupported();
    error TradingFrozen();
    error NotCreator();
    error NotTeam();
    error NotOwner();
    error NotDeployer();
    error NotManager();
    error UsdcPoolUnset();
    error Slippage();
    error PartialFill();
    error NotLauncher();
    error PayoutAlreadySet();
    error CreatorFeeTooHigh();
    error LpFeeTooHigh();
    error BadNumeraire();
    error NumeraireMismatch();
    error UnknownFeeToken();
    error UsdcUsesDedicatedPath();
    error FeeTokenHasNoCode();
    error FeeTokenNotErc20();
    error FeeTokenBadDecimals();
    error BadUsdcMigration();
    error BadPositionManager();
    error UnknownPositionManager();
    error ReservedBoundaryTick();
    error BadTickSpacing();

    event CurveCompleted(address indexed token);
    event FeeAccrued(address indexed token, bool isBuy, uint256 feeWei);
    /// The ACTUAL split of one swap's whole fee (base 1% + any custom creator/LP fee), in the numeraire,
    /// after every per-coin rule has been applied: autocompound off → its slice to the creator, LP
    /// rewards off or no active external LP → that slice to the creator, BODKIN → its burn slice to
    /// the creator, custom creator fee → creator, custom LP fee → LPs (or folded to the creator).
    /// `creator + lp + burn + autocompound + team` is the total fee taken. Indexed per swap so the
    /// analytics can sum what each party really received instead of applying a nominal split.
    event FeeSplit(
        address indexed token, bool isBuy, uint256 creator, uint256 lp, uint256 burn, uint256 autocompound, uint256 team
    );
    event PositionManagerSet(address positionManager);
    /// A further PositionManager was added to the claimable list ({addPositionManager}).
    event PositionManagerAdded(address indexed positionManager);
    /// Per-coin fee options chosen at launch: autocompound off (10% slice → creator) + a custom
    /// creator fee (bps, on top of the 1%, 100% → creator).
    event LaunchFeeConfig(
        address indexed token, bool autocompoundOff, uint16 creatorFeeBps, uint16 lpFeeBps, bool lpRewardsOff
    );
    /// Emitted when a full-range LP position's accrued numeraire rewards are paid to its NFT owner.
    event LpRewardsClaimed(address indexed token, uint256 indexed tokenId, address indexed to, uint256 amount);
    /// The same payout for a position held in an ADDED PositionManager (not the primary). A separate event
    /// so a reader keyed on (token, tokenId) of the primary never mixes in another PositionManager's ids.
    event LpRewardsClaimedVia(
        address indexed token, address indexed positionManager, uint256 indexed tokenId, address to, uint256 amount
    );
    event CreatorClaimed(address indexed token, address indexed to, address payoutToken, uint256 ethIn, uint256 paidOut);
    /// The numeraire (fallback) leg of a creator claim — fees that were never converted to
    /// the payout token because its pool was dry, paid out in `numeraire`.
    event CreatorClaimedFallback(address indexed token, address indexed to, address numeraire, uint256 amount);
    /// Emitted per CURRENCY delivered by a team claim (a claim may settle several — old USDC, new
    /// USDC, ETH — one event each). `currency` is the actual settled currency, address(0) = ETH.
    event TeamClaimed(address indexed token, address currency, uint256 ethIn, uint256 paidOut);
    /// A USDC contract migration: `usdc`, its (ETH,usdc) conversion pool and (when it followed usdc)
    /// the team payout token all swung to `newUsdc` in one 2-of-2 action.
    event UsdcMigrated(address indexed oldUsdc, address indexed newUsdc);
    event PayoutSet(
        address indexed token,
        address payoutToken,
        bool viaHub,
        bool wethPaired,
        uint24 fee,
        int24 tickSpacing,
        address numeraire
    );
    event BurnProcessed(address indexed token, uint256 ethIn, uint256 bodkinBurned);
    event TeamChanged(address indexed oldTeam, address indexed newTeam);
    event TeamPayoutTokenChanged(address indexed oldToken, address indexed newToken);
    event TeamPayoutAllowedSet(address indexed token, bool allowed);
    /// @notice The WETH address (payout-conversion wrap target) was re-pointed by the deployer.
    event WethChanged(address indexed oldWeth, address indexed newWeth);
    /// @notice The deployer role was transferred or renounced (to address(0)).
    event DeployerChanged(address indexed oldDeployer, address indexed newDeployer);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev The deployer-controlled ops role — see {deployer}. Survives the {owner} renounce.
    modifier onlyDeployer() {
        if (msg.sender != deployer) revert NotDeployer();
        _;
    }

    constructor(
        IPoolManager manager_,
        ICreatorNFT creatorNFT_,
        address team_,
        address usdc_,
        address weth_,
        address owner_
    ) BaseHook(manager_) {
        require(
            address(creatorNFT_) != address(0) && team_ != address(0) && usdc_ != address(0) && owner_ != address(0),
            "FeeHook: zero"
        );
        creatorNFT = creatorNFT_;
        team = team_;
        usdc = usdc_;
        // Initial WETH wire (0 = a chain/test with no WETH; wethPaired payouts then disabled). No
        // longer a post-deploy deployer call — set here, re-pointable ONLY via the launcher's 2-of-2
        // {LauncherV1.updateFeeToken} → {setFeeToken}, same governance as the team wallet.
        weth = weth_;
        teamPayoutToken = usdc_; // default; re-pointable via the launcher's 2-of-2 (ETH or an allowed token)
        teamPayoutAllowed[usdc_] = true; // USDC allowed out of the box; more can be added on migration
        _registerTeamCurrency(usdc_); // the initial team payout currency must be claimable
        // Native ETH too: the other possible launch numeraire. A team slice that cannot route out of
        // its numeraire (a dry / unroutable payout pool, see {_convertChunk}) falls back INTO that
        // numeraire, and a fallback into an unregistered currency would strand it out of {claimTeam}.
        _registerTeamCurrency(address(0));
        // Explicit owner — the hook is deployed via the CREATE2 factory, so
        // msg.sender at construction is the factory, not the real deployer.
        owner = owner_;
        // The ops deployer role (payout-token allow-list) is the deployer, and survives the owner renounce.
        deployer = owner_;
    }

    /// @dev Add `cur` to the iterable set of currencies team fees may be banked in, if new. Called
    ///      only from the constructor and the 2-of-2 governance paths that point {teamPayoutToken}
    ///      at a currency ({setTeamPayoutToken}, {migrateUsdc}) — NEVER from a swap — so the set is
    ///      governance-bounded. The cap makes {claimTeam}'s per-currency loop provably finite even
    ///      against a compromised 2-of-2. Registering a currency is the invariant that keeps every
    ///      value {teamPayoutToken} can take claimable — banking into an unregistered currency would
    ///      strand it, so registration MUST precede any change to teamPayoutToken.
    function _registerTeamCurrency(address cur) internal {
        if (teamCurrencyKnown[cur]) return;
        require(teamBankedCurrencies.length < MAX_TEAM_CURRENCIES, "FeeHook: too many team currencies");
        teamCurrencyKnown[cur] = true;
        teamBankedCurrencies.push(cur);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true, // enforce launcher-only + allowlisted numeraire
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true, // track external LP positions (any range) for the LP-fee slice
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true, // checkpoint + untrack on withdraw
            beforeSwap: true, // fee on buys (numeraire input) + reject exact-output
            afterSwap: true, // fee on sells (numeraire output)
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // --- one-shot owner wiring + the deployer role ---

    /// @notice Wire the PRIMARY Uniswap v4 PositionManager, so LP-reward claims can resolve a position
    ///         NFT's owner. One-shot, owner-only (mirrors {setUsdcPool}): the primary can never be replaced.
    ///         Further PositionManagers can only be ADDED next to it, through the launcher's 2-of-2
    ///         ({addPositionManager}); their positions claim through the three-argument {claimLpRewards}.
    function setPositionManager(address pm) external onlyOwner {
        require(!_positionManagerSet, "FeeHook: pm set");
        require(pm != address(0), "FeeHook: pm zero");
        positionManager = pm;
        _positionManagerSet = true;
        if (!isPositionManager[pm]) {
            isPositionManager[pm] = true;
            _positionManagerList.push(pm);
        }
        emit PositionManagerSet(pm);
    }

    /// @notice Add a further PositionManager whose positions can claim LP rewards — for when Uniswap
    ///         ships a new PositionManager (new address; the old one keeps working). Callable ONLY by the
    ///         launcher, which gates it behind the 2-of-2 (deployer + current team) in
    ///         {LauncherV1.addPositionManager}. ADD-ONLY: nothing is ever removed or re-pointed.
    /// @dev   Why the trust cost is small: rewards are booked per (token, adder, salt), where the adder
    ///        is the contract that actually called the PoolManager. Listing a contract only lets
    ///        {claimLpRewards} pay out the rewards of liquidity THAT contract itself provided, to whoever
    ///        its `ownerOf` names (or the owner the hook remembered for it) — it cannot reach any other
    ///        position, and it changes nothing about how the hook treats that contract's adds and removes
    ///        (owners are recorded for every adder, with reads that can never revert — {_readAddr}).
    ///        Checks: code, and bound to OUR PoolManager (a PositionManager for another PoolManager can
    ///        never hold liquidity here). Listing it before its LPs start closing positions is not needed:
    ///        the owner of a position closed earlier was already recorded.
    function addPositionManager(address pm) external {
        if (msg.sender != launcher) revert NotLauncher();
        if (pm == address(0) || pm.code.length == 0 || isPositionManager[pm]) revert BadPositionManager();
        try IPositionManagerMinimal(pm).poolManager() returns (IPoolManager boundTo) {
            if (address(boundTo) != address(poolManager)) revert BadPositionManager();
        } catch {
            revert BadPositionManager();
        }
        isPositionManager[pm] = true;
        _positionManagerList.push(pm);
        emit PositionManagerAdded(pm);
    }

    /// @notice View: every PositionManager whose positions can claim, the primary first.
    function positionManagers() external view returns (address[] memory) {
        return _positionManagerList;
    }

    /// @notice Wire the (native ETH, USDC) pool used to convert fees to USDC.
    /// @dev One-shot: once wired the pool can NEVER be re-pointed — not even by the
    ///      owner — so a compromised deployer key cannot swap in a hostile thin-LP pool
    ///      to drain fee conversions. Mirrors {setLauncher}.
    function setUsdcPool(PoolKey calldata key) external onlyOwner {
        require(!_usdcPoolSet, "FeeHook: usdc pool set");
        require(Currency.unwrap(key.currency0) == address(0) && Currency.unwrap(key.currency1) == usdc, "FeeHook: bad usdc pool");
        // Same rule as the BODKIN pool, and for the same reason: the conversion steps
        // size each chunk as `fee x depth`, so a fee-free pool has NO safe chunk size —
        // `_safeBurnChunk` correctly returns 0 and every conversion through it would
        // silently do nothing forever. One-shot setter, renounced owner: caught here or
        // never. Canonical tiers are 100/500/3000/10000, so 0 was never a valid pool.
        require(key.fee > 0 && key.fee & 0x800000 == 0, "FeeHook: usdc pool needs a static fee");
        _usdcPool = key;
        _usdcPoolSet = true;
    }

    /// @notice Wire the (native ETH, BODKIN) pool for the burn bucket's buy&burn.
    /// @dev One-shot — see {setUsdcPool}. Set once when the BODKIN pool exists.
    function setBodkinPool(PoolKey calldata key) external onlyOwner {
        require(!_bodkinPoolSet, "FeeHook: bodkin pool set");
        require(
            Currency.unwrap(key.currency0) == address(0) && Currency.unwrap(key.currency1) != address(0),
            "FeeHook: bad bodkin pool"
        );
        // A venue with NO round-trip cost must never be wired here, and this is the only
        // moment it can ever be refused: the setter is one-shot and the owner is
        // renounced right after deploy, so a costless venue would be permanent and
        // unfixable.
        //
        // The cost is not incidental — it IS the buy & burn's protection. A sandwich
        // round trip has to pay it twice, which is what makes a bounded burn chunk
        // unprofitable to attack; when the round trip is free no safe chunk size exists
        // (`_safeBurnChunk` correctly returns 0) and the burn would never run. Two
        // venues qualify:
        //
        //   * a PLAIN pool with a static nonzero LP fee (dynamic fees rejected — the
        //     size math needs a number it can read now, not one decided per swap), or
        //   * one of THIS HOOK's own launch pools: its pool fee is 0 by design, but the
        //     hook skims FEE_BPS off the numeraire side of every swap, buys and sells
        //     alike — the sandwich pays exactly the same toll, just to the hook instead
        //     of the LPs. `_safeBurnChunk` prices such a venue at FEE_BPS. This is what
        //     lets BODKIN itself be a real launch (creator fee, NFT, burn) and still be
        //     the burn venue. There is no recursion at all: v4-core skips a hook's
        //     callbacks when the hook itself initiates the swap (Hooks.afterSwap
        //     early-returns on `msg.sender == address(self)`), so a burn's own buy
        //     never re-enters `_afterSwap`. The per-block markers still matter — they
        //     pace burns across USER swaps — they are just not what stops recursion.
        bool selfHooked = address(key.hooks) == address(this);
        require(
            selfHooked || (key.fee > 0 && key.fee & 0x800000 == 0),
            "FeeHook: bodkin pool needs a fee"
        );
        // A self-hooked venue must be the launcher's OWN pool for that token, proven against the launcher
        // now, on chain. The deploy script's equivalent checks run only in forge's SIMULATION — it records
        // each call's calldata there and broadcasts them afterwards — so a launch landing in between could
        // shift which address this call carries, and the token wired here as the burn target is permanent
        // (one-shot setter, owner renounced straight after). The deploy also pins BODKIN's address with a
        // per-deployer CREATE2 salt; this is the on-chain half of that, and it catches a mistyped key too.
        if (selfHooked && launcher != address(0)) {
            address venueToken = Currency.unwrap(key.currency1);
            try ILauncherHookView(launcher).poolKeyOf(venueToken) returns (PoolKey memory own) {
                // The launcher derives this key from its own record of the token, so for anything it has
                // ever launched the comparison is exact. A launcher that cannot answer at all — a test
                // double, or some future launcher without this view — leaves the key as the caller gave
                // it, which is the pre-existing behaviour and why the call is in a try/catch.
                if (Currency.unwrap(own.currency1) == venueToken) {
                    require(PoolId.unwrap(own.toId()) == PoolId.unwrap(key.toId()), "FeeHook: not the launch pool");
                }
            } catch {}
        }
        _bodkinPool = key;
        bodkin = Currency.unwrap(key.currency1);
        _bodkinPoolSet = true;
    }

    /// @notice Wire the launcher once (it may set a token's payout token at launch).
    function setLauncher(address launcher_) external onlyOwner {
        require(launcher == address(0) && launcher_ != address(0), "FeeHook: launcher set");
        launcher = launcher_;
    }

    /// @notice Re-point one of the hook's fee-infrastructure addresses. Callable ONLY by the launcher,
    ///         which gates it behind the SAME 2-of-2 (deployer + current team) off-chain signature check
    ///         as the team wallet — see {LauncherV1.updateFeeToken}. This is the emergency escape hatch
    ///         for a deprecated numeraire: if e.g. WETH or USDC ever migrates to a new contract and the
    ///         old address loses its liquid pools, the fee route can be re-pointed rather than left to
    ///         die. Neither the owner nor the deployer can call it — after the owner is renounced the only
    ///         path is still the launcher's 2-of-2.
    ///
    ///         `which`: {FEE_TOKEN_WETH} re-points {weth} (only affects `wethPaired` payout conversions;
    ///         address(0) disables them safely — the wrap reverts before moving value and
    ///         `_validatePayout` rejects new wethPaired launches). A nonzero WETH is coin-validated
    ///         (has code + is an 18-decimal ERC-20) as a fat-finger guard on top of the 2-of-2.
    ///         {FEE_TOKEN_USDC} is NOT accepted here: USDC also re-wires the (ETH,usdc) conversion
    ///         pool, the team payout token and the launcher's FDV, so it has its own atomic path
    ///         {migrateUsdc} (via {LauncherV1.updateUsdc}); this bare-address setter would leave it
    ///         half-migrated, so it reverts and points there.
    function setFeeToken(uint8 which, address newAddr) external {
        if (msg.sender != launcher) revert NotLauncher();
        if (which == FEE_TOKEN_WETH) {
            // address(0) is deliberately allowed (disables wethPaired payouts). A nonzero WETH must be
            // a real 18-decimal ERC-20 — the ETH->WETH wrap and conversion math assume 1:1 at 18 dp.
            if (newAddr != address(0)) _validateFeeErc20(newAddr, 18);
            emit WethChanged(weth, newAddr);
            weth = newAddr;
        } else if (which == FEE_TOKEN_USDC) {
            revert UsdcUsesDedicatedPath();
        } else {
            revert UnknownFeeToken();
        }
    }

    /// @dev Fat-finger validation of a fee-infra ERC-20 before a 2-of-2 re-point. Proves the address
    ///      has CODE and answers `decimals()` with EXACTLY `expectedDecimals` — the decimals invariant
    ///      is the load-bearing check: the whole fee pipeline is scaled to a fixed decimal count
    ///      (USDC 6, WETH 18), and a wrong-decimals token would silently corrupt every conversion.
    ///      It does NOT prove the address is the genuine canonical coin — that trust stays with the
    ///      two human signers; this only stops a typo/EOA/wrong-decimals mistake. Behind the 2-of-2,
    ///      so a griefing token that burns gas in `decimals()` only wastes the signers' own call.
    function _validateFeeErc20(address addr, uint8 expectedDecimals) internal view {
        if (addr.code.length == 0) revert FeeTokenHasNoCode();
        try IERC20Decimals(addr).decimals() returns (uint8 d) {
            if (d != expectedDecimals) revert FeeTokenBadDecimals();
        } catch {
            revert FeeTokenNotErc20();
        }
    }

    /// @notice Atomically migrate the platform USDC to a new contract — the emergency escape hatch for
    ///         a deprecated USDC whose pools have gone dry. Callable ONLY by the launcher, which gates
    ///         it behind the 2-of-2 (deployer + current team) in {LauncherV1.updateUsdc}. In ONE action
    ///         it re-points `usdc`, re-wires the (ETH, newUsdc) conversion pool `_usdcPool`, adds the new
    ///         coin to the payout allow-list + team currency set, and — when the team payout token was
    ///         still the OLD usdc — swings it to the new one so future ETH-numeraire team conversions
    ///         route through the fresh pool instead of stalling on the dead old route. Already-banked fees
    ///         are NOT touched: team slices stay under `teamOut[token][oldUsdc]` (claimable in old USDC via
    ///         the multi-currency {claimTeam}); creator slices keep their per-launch pinned {payoutTokenOf}.
    ///         Existing OLD-usdc-NUMERAIRE launches keep their pinned {numeraireOf} and keep trading; their
    ///         ONGOING fees, which can no longer route out of the deprecated numeraire, fall back into that
    ///         old numeraire ({_convertChunk}'s stale-numeraire branch: creator -> {creatorOutNum}, team ->
    ///         `teamOut[token][oldUsdc]`), so nothing strands — it is just paid in the old USDC.
    /// @dev The new coin is coin-validated (has code + is a same-decimals ERC-20 as the old usdc), and
    ///      the new pool re-derives EVERY {setUsdcPool} anti-drain check against the new usdc PLUS the
    ///      two the one-shot omits (no hostile hook; pool actually initialised). The one-shot pool's
    ///      guarantee is thus preserved by RE-VALIDATION under the 2-of-2, not by immutability — a
    ///      single compromised key still cannot swap in a hostile thin-LP pool.
    function migrateUsdc(address newUsdc, PoolKey calldata newPool) external {
        if (msg.sender != launcher) revert NotLauncher();
        address old = usdc;
        // Coin validation: real, distinct, SAME-decimals ERC-20 (USDC is 6dp) — a wrong-decimals coin
        // would silently corrupt every micro-USDC conversion.
        if (newUsdc == address(0) || newUsdc == old) revert BadUsdcMigration();
        _validateFeeErc20(newUsdc, IERC20Decimals(old).decimals());
        // Pool validation: currency0 == ETH, currency1 == the NEW usdc (bound atomically), a static
        // non-zero LP fee (a dynamic-fee flag or fee==0 yields no safe conversion chunk and stalls
        // forever), a PLAIN pool (no hostile hook that could re-enter/steal during a conversion), and
        // an INITIALISED pool (so the new route actually works, rejecting a typo'd key up front).
        if (Currency.unwrap(newPool.currency0) != address(0) || Currency.unwrap(newPool.currency1) != newUsdc) {
            revert BadUsdcMigration();
        }
        if (!(newPool.fee > 0 && newPool.fee & 0x800000 == 0)) revert BadUsdcMigration();
        if (address(newPool.hooks) != address(0)) revert BadUsdcMigration();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(newPool.toId());
        if (sqrtPriceX96 == 0) revert BadUsdcMigration();

        usdc = newUsdc;
        _usdcPool = newPool;
        _usdcPoolSet = true;
        teamPayoutAllowed[newUsdc] = true;
        _registerTeamCurrency(newUsdc); // future team conversions into the new USDC must be claimable
        // Swing the team payout token ONLY if it was still tracking the old usdc; an explicit ETH/other
        // choice is left untouched.
        if (teamPayoutToken == old) teamPayoutToken = newUsdc;
        emit UsdcMigrated(old, newUsdc);
    }

    /// @notice Transfer or RENOUNCE (to address(0)) the ops deployer role. The deployer now only maintains the
    ///         team payout-token allow-list ({setTeamPayoutAllowed}); the fee-infra addresses ({weth},
    ///         {usdc}) are governed by the launcher's 2-of-2, NOT the deployer. Renouncing gives up the
    ///         allow-list, leaving the contract with neither an owner nor a deployer.
    function setDeployer(address newDeployer) external onlyDeployer {
        emit DeployerChanged(deployer, newDeployer);
        deployer = newDeployer;
    }

    function renounceOwnership() external onlyOwner {
        owner = address(0);
    }

    /// @notice Re-point the team fee wallet. Callable ONLY by the launcher, which gates it
    ///         behind a 2-of-2 (deployer + the CURRENT team) off-chain signature check in
    ///         {LauncherV1.updateTeamWallet}. Pointing `team` here makes BOTH the already-
    ///         banked team slices and all future ones follow the new wallet, in lockstep
    ///         with the create fee. The hook owner cannot call this — and after the owner is
    ///         renounced there is still exactly one path (the launcher's 2-of-2) to move it.
    function setTeam(address newTeam) external {
        if (msg.sender != launcher) revert NotLauncher();
        require(newTeam != address(0), "FeeHook: zero team");
        address old = team;
        team = newTeam;
        emit TeamChanged(old, newTeam);
    }

    /// @notice Change the team's PAYOUT token (the currency its slice settles in). Callable ONLY by
    ///         the launcher, which gates it behind the SAME 2-of-2 (deployer + current team) as the
    ///         team wallet — see {LauncherV1.updateTeamPayoutToken}. Scope: native ETH, or an
    ///         deployer-allowed token ({teamPayoutAllowed}) — USDC at deploy, but because USDC can
    ///         migrate to a new contract the set is extendable, so the choice is never frozen to a
    ///         single hardcoded address. NO drain-first guard: team fees are banked PER CURRENCY
    ///         ({teamOut}), so already-banked slices stay keyed to — and are claimed in — the currency
    ///         they were banked in; a flip only changes what FUTURE conversions bank into. The new
    ///         currency is REGISTERED first, so {claimTeam}'s sweep always covers it.
    function setTeamPayoutToken(address newToken) external {
        if (msg.sender != launcher) revert NotLauncher();
        require(newToken == address(0) || teamPayoutAllowed[newToken], "FeeHook: team token not allowed");
        // MUST precede the flip: a conversion could bank into `newToken` before the next governance
        // call, and banking into an unregistered currency would strand it out of {claimTeam}'s loop.
        _registerTeamCurrency(newToken);
        address old = teamPayoutToken;
        teamPayoutToken = newToken;
        emit TeamPayoutTokenChanged(old, newToken);
    }

    /// @notice Add or remove a token from the set the team may be paid in ({setTeamPayoutToken}).
    ///         Admin-only — the same chain-config role that maintains {weth}: a USDC that migrates
    ///         to a new contract is exactly the kind of address that legitimately changes after
    ///         deploy. Native ETH is always allowed and is not tracked here. Toggling the set cannot
    ///         move funds by itself — the 2-of-2 {setTeamPayoutToken} still makes the choice. A
    ///         newly-allowed token also needs its conversion pool reachable by the default route
    ///         before fees can actually settle into it.
    function setTeamPayoutAllowed(address token, bool allowed) external onlyDeployer {
        require(token != address(0), "FeeHook: ETH always allowed");
        teamPayoutAllowed[token] = allowed;
        emit TeamPayoutAllowedSet(token, allowed);
    }

    // --- per-launch creator payout choice (default USDC), set ONCE at creation ---

    /// @notice Configure a launch's creator-fee payout. Callable ONLY by the launcher
    ///         and ONLY once, at creation — there is deliberately no path to change it
    ///         afterwards, so buyers can rely on a launch's fee terms being immutable.
    /// @dev The launcher validates the custom pool exists and uses a canonical tier
    ///      before calling; this contract enforces the one-time + launcher-only latch.
    /// @param numeraire The launch pool's quote currency (address(0) = ETH, or usdc).
    ///        Recorded BEFORE the pool is opened so {_beforeInitialize} can verify the
    ///        key it is handed. Also determines which currency the fee buckets accrue
    ///        in, and therefore where every payout conversion starts.
    function setLaunchConfig(
        address token,
        address payoutToken,
        bool viaHub,
        bool wethPaired,
        uint24 fee,
        int24 tickSpacing,
        address numeraire,
        bool autocompoundOff,
        uint16 creatorFeeBps,
        uint16 lpFeeBps,
        bool lpRewardsOff
    ) external {
        if (msg.sender != launcher) revert NotLauncher();
        if (!isNumeraire(numeraire)) revert BadNumeraire();
        if (creatorFeeBps > MAX_CREATOR_FEE_BPS) revert CreatorFeeTooHigh(); // ≤ 5%, defence-in-depth
        if (lpFeeBps > MAX_LP_FEE_BPS) revert LpFeeTooHigh(); // ≤ 5%, defence-in-depth
        PayoutConfig storage c = _payoutCfg[token];
        if (c.set) revert PayoutAlreadySet();
        c.token = payoutToken;
        c.viaHub = viaHub;
        c.wethPaired = wethPaired;
        c.fee = fee;
        c.tickSpacing = tickSpacing;
        c.numeraire = numeraire;
        c.autocompoundOff = autocompoundOff;
        c.creatorFeeBps = creatorFeeBps;
        c.lpFeeBps = lpFeeBps;
        c.lpRewardsOff = lpRewardsOff;
        // Pin the infra this route depends on (see {PayoutConfig}); only what it actually uses.
        if (wethPaired) c.wethAt = weth;
        if (viaHub) c.usdcAt = usdc;
        c.set = true;
        emit PayoutSet(token, payoutToken, viaHub, wethPaired, fee, tickSpacing, numeraire);
        emit LaunchFeeConfig(token, autocompoundOff, creatorFeeBps, lpFeeBps, lpRewardsOff);
    }

    /// @notice The quote currency of `token`'s launch pool (address(0) = native ETH).
    ///         Also the currency its fee buckets accrue in.
    function numeraireOf(address token) public view returns (address) {
        return _payoutCfg[token].numeraire;
    }

    /// @notice The wired (native ETH, USDC) conversion pool — the single canonical
    ///         ETH↔USDC key in the system. The swap router reads this so it never has
    ///         to be told the key by a caller.
    function usdcPool() external view returns (PoolKey memory) {
        return _usdcPool;
    }

    /// @notice The wired buy&burn venue. Read by the post-deploy verification, which has to prove the
    ///         pool this hook will spend every coin's burn slice on is the one it was meant to be.
    function bodkinPool() external view returns (PoolKey memory) {
        return _bodkinPool;
    }

    /// @notice Resolved creator payout currency for `token` — USDC by default.
    function payoutTokenOf(address token) public view returns (address) {
        PayoutConfig storage c = _payoutCfg[token];
        return c.set ? c.token : usdc;
    }

    /// @notice Where a launch's creator fee is delivered: ALWAYS the current holder of
    ///         its fee NFT. There is deliberately no override — the fee stream and the
    ///         NFT are the same thing, so it stays transferable (and sellable) by
    ///         construction. A creator who wants the fees elsewhere chooses that wallet
    ///         at launch, and the launcher MINTS THE NFT there.
    function payoutRecipientOf(address token) public view returns (address) {
        return creatorNFT.creatorOf(token);
    }

    /// @notice Full payout config for `token` (for UIs/indexers).
    function payoutConfigOf(address token) external view returns (PayoutConfig memory) {
        return _payoutCfg[token];
    }

    // --- swap hooks: skim the 1% fee on the numeraire side ---

    /// @dev Only the launcher may open a pool on this hook, and only with an
    ///      allowlisted numeraire as currency0 — matching what the launcher already
    ///      recorded for this token, so the hook is self-consistent even against a
    ///      buggy launcher rather than trusting the key it is handed.
    ///
    ///      The `sender` check is load-bearing, not defensive: PoolManager.initialize
    ///      is permissionless, so without it ANYONE could (a) front-run a pending
    ///      launch() by initializing its pool first — the launch then reverts and the
    ///      creator loses the gas, the pinned metadata and the mined salt, repeatably —
    ///      or (b) open a second hooked pool for an already-launched token, whose
    ///      swaps would accrue into that token's fee buckets from a pool the
    ///      launchpad never sanctioned.
    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        if (sender != launcher) revert NotLauncher();
        address numeraire = Currency.unwrap(key.currency0);
        if (!isNumeraire(numeraire)) revert BadNumeraire();
        // The launcher records the launch config BEFORE opening the pool, so we can
        // insist the key it passes matches: currency0 must be exactly the numeraire
        // this token was configured with.
        PayoutConfig storage c = _payoutCfg[Currency.unwrap(key.currency1)];
        if (!c.set || c.numeraire != numeraire) revert NumeraireMismatch();
        // The LP book indexes ticks against {TICK_SPACING} — the bitmap packs one bit per step of it,
        // and every boundary the hook stores or reserves is a multiple of it. A pool opened at another
        // spacing would have the book reading a different grid than the pool it describes. The launcher
        // only ever opens pools at this spacing; this makes that an invariant of the hook rather than a
        // habit of its caller.
        if (key.tickSpacing != TICK_SPACING) revert BadTickSpacing();
        return BaseHook.beforeInitialize.selector;
    }

    /// @notice The closed set of quote currencies a launch pool may use: native ETH
    ///         or the platform USDC. Anything else would accrue fees this hook has
    ///         no conversion route for.
    function isNumeraire(address currency) public view returns (bool) {
        return currency == address(0) || currency == usdc;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (params.amountSpecified > 0) revert ExactOutputUnsupported(); // exact-input only

        address launchToken = Currency.unwrap(key.currency1);
        (int24 tickLower, , , bool migrated) = ILauncherHookView(launcher).curvePositions(launchToken);
        if (tickLower != 0 && !migrated) { // if the launch token has a curve and is NOT migrated
            (, int24 curTick, , ) = poolManager.getSlot0(key.toId());
            if (curTick <= tickLower + 60) revert TradingFrozen();
        }

        // BUY (numeraire->token): the numeraire is the specified input → fee here.
        if (params.zeroForOne) {
            // base 1% + the coin's optional custom creator fee, all off the numeraire input.
            uint256 fee = _skimFee(launchToken, uint256(-params.amountSpecified), true);
            if (fee > 0) {
                // Take as ERC-6909 claims (accounting only): the buyer's numeraire
                // isn't in the manager yet at beforeSwap, so a transfer would revert.
                key.currency0.take(poolManager, address(this), fee, true);
                return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
            }
        }
        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(int128(0), int128(0)), 0);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        // The launch token is always currency1 — the launcher enforces token > numeraire.
        address launchToken = Currency.unwrap(key.currency1);

        // Bring the external-LP book to the post-swap tick FIRST (apply every tick the swap crossed),
        // so the sell fee below is credited to the liquidity that is active now. (A buy's fee was
        // credited in beforeSwap, to the liquidity active before the swap — the book was already in
        // step there, since only swaps move the tick.)
        _syncLpTick(launchToken, key);

        // BUY: the fee was skimmed in `beforeSwap` off the FULL requested input,
        // before the pool revealed how much it could actually absorb. On a full fill
        // those are the same number; on a price-limited partial fill they are not, and
        // the swapper would pay FEE_BPS of what they ASKED to swap while only part of
        // it swapped. No refund is possible from here — the fee sits on the specified
        // side and afterSwap can only return a delta on the unspecified one — so the
        // honest answer is the quoter's: refuse the fill. V4Quoter already reverts on
        // partial fills (the UI cannot even produce such a quote); this closes the
        // manual-router path, and it keeps the overcharge unreachable no matter how
        // low a FUTURE deployment sets startFdvOf (range capacity scales with it, and
        // it is constructor-only on an ownerless launcher — not fixable later).
        //
        // `delta` here is the POOL's principal delta (v4-core subtracts the hook's
        // beforeSwap fee from the caller's delta only after this callback returns), so
        // a full fill satisfies consumed == requested - fee exactly.
        if (params.zeroForOne) {
            uint256 requested = uint256(-params.amountSpecified);
            // mirrors _beforeSwap exactly: the FULL per-coin rate (base + custom creator + custom LP)
            // was skimmed there.
            PayoutConfig storage pc = _payoutCfg[launchToken];
            uint256 fee = (requested * (uint256(FEE_BPS) + pc.creatorFeeBps + pc.lpFeeBps)) / BPS;
            int128 a0 = delta.amount0();
            uint256 consumed = a0 < 0 ? uint256(uint128(-a0)) : 0;
            if (consumed + fee < requested) revert PartialFill();
        }

        // SELL (token->numeraire): the numeraire is the unspecified output → fee here.
        // (A BUY takes its fee in `beforeSwap`, off the numeraire input.)
        int128 hookDelta = 0;
        if (!params.zeroForOne) {
            int128 numOut = delta.amount0(); // numeraire the swapper received (positive)
            if (numOut > 0) {
                // base 1% + the coin's optional custom creator fee, all off the numeraire output.
                uint256 fee = _skimFee(launchToken, uint256(uint128(numOut)), false);
                if (fee > 0) {
                    key.currency0.take(poolManager, address(this), fee, true); // ERC-6909 claims
                    hookDelta = int128(int256(fee));
                }
            }
        }

        // Advance the whole fee pipeline on EVERY swap, buys included — the buckets fill
        // from both directions, so draining them from only one would let a buy-heavy token
        // accumulate indefinitely. None of this can revert; see {_tryBurnStep}.
        _tryBurnStep(launchToken);
        _tryConvertSteps(launchToken);
        _tryCompoundStep(launchToken);

        (int24 tickLower, , , bool migrated) = ILauncherHookView(launcher).curvePositions(launchToken);
        if (tickLower != 0 && !migrated) {
            (, int24 curTick, , ) = poolManager.getSlot0(key.toId());
            if (curTick <= tickLower + 60) {
                emit CurveCompleted(launchToken);
            }
        }

        return (BaseHook.afterSwap.selector, hookDelta);
    }

    /// @dev Advance the buy & burn, and make it IMPOSSIBLE for that to cost anyone a
    ///      trade. The try/catch is the whole mechanism: a revert inside an external
    ///      call is caught here, and everything the failed attempt touched — the
    ///      bucket, the block marker, its pool deltas — rolls back with it. So the
    ///      worst case is that this swap simply burned nothing and the next one tries
    ///      again with the bucket intact.
    ///
    ///      Deliberately NOT `if (canBurn) burnStep()`: a precondition check is only as
    ///      good as its own completeness, and this needs to hold for failures nobody
    ///      predicted. Catching everything is the only version that is true by
    ///      construction rather than by inspection.
    function _tryBurnStep(address token) internal {
        try this.burnStep(token) {} catch {}
    }

    /// @dev Credit `amount` (numeraire) to the coin's EXTERNAL LPs active at the current tick via the
    ///      fee-growth accumulator, UNDILUTED by the coin's own locked positions (excluded from `lpLiquidity`).
    ///      With NONE tracked it is NOT banked — returned as `folded` for the caller to route (to the
    ///      creator, matching the base LP slice's no-provider behaviour). Never strands the slice.
    function _creditLp(address token, uint256 amount) internal returns (uint256 banked, uint256 folded) {
        if (amount == 0) return (0, 0);
        // LP rewards disabled at launch → the whole slice (base + any custom LP fee) folds to the
        // creator, regardless of whether external LPs exist.
        if (_payoutCfg[token].lpRewardsOff) return (0, amount);
        uint256 L = lpLiquidity[token];
        if (L > 0) {
            lpFeeGrowthGlobalX128[token] += FullMath.mulDiv(amount, LP_FEE_GROWTH_Q128, L);
            lpBankWei[token] += amount;
            return (amount, 0);
        }
        return (0, amount);
    }

    /// @dev The numeraire fee a swap owes = the base 1% (`FEE_BPS`) run through the full `_accrue`
    ///      split, PLUS the coin's optional custom creator fee (`creatorFeeBps`, ≤ 5%, 100% to the
    ///      creator) AND its optional custom LP fee (`lpFeeBps`, ≤ 5%, 100% to external LPs — folds to
    ///      the creator when none, like the base LP slice), both charged ON TOP. Returns the TOTAL to
    ///      skim off the numeraire side (all slices taken in ONE `take` by the caller). The custom
    ///      slices accrue silently (to `creatorWei` / the LP accumulator) — they surface on-chain
    ///      through the downstream payout events, never a per-swap firehose log. CUMULATIVE floors
    ///      (base ≤ +creator ≤ +creator+lp) so each slice is the difference and the grand total is a
    ///      single floor-div: `total == floor(gross·(FEE_BPS+creator+lp)/BPS)`, dust-exact.
    function _skimFee(address token, uint256 gross, bool isBuy) internal returns (uint256 total) {
        uint256 baseFee = (gross * FEE_BPS) / BPS;
        FeeSplitAmounts memory sp;
        if (baseFee > 0) sp = _accrue(token, baseFee, isBuy);
        PayoutConfig storage cfg = _payoutCfg[token];
        uint256 afterCreator = (gross * (uint256(FEE_BPS) + cfg.creatorFeeBps)) / BPS;
        total = (gross * (uint256(FEE_BPS) + cfg.creatorFeeBps + cfg.lpFeeBps)) / BPS;
        uint256 customCreator = afterCreator - baseFee;
        if (customCreator > 0) {
            creatorWei[token] += customCreator; // custom creator fee → 100% creator
            sp.creator += customCreator;
        }
        uint256 customLp = total - afterCreator;
        if (customLp > 0) {
            (uint256 banked, uint256 folded) = _creditLp(token, customLp); // custom LP fee → external LPs (folds to creator)
            if (folded > 0) creatorWei[token] += folded;
            sp.lp += banked;
            sp.creator += folded;
        }
        if (total > 0) emit FeeSplit(token, isBuy, sp.creator, sp.lp, sp.burn, sp.autocompound, sp.team);
    }

    /// @dev What one fee split actually handed to each party (numeraire) — see {FeeSplit}.
    struct FeeSplitAmounts {
        uint256 creator;
        uint256 lp;
        uint256 burn;
        uint256 autocompound;
        uint256 team;
    }

    /// @dev Split the BASE 1% fee into its buckets. Any per-coin CUSTOM creator/LP fee is handled by
    ///      {_skimFee} (added on top) — it never reaches here.
    function _accrue(address token, uint256 fee, bool isBuy) internal returns (FeeSplitAmounts memory sp) {
        uint256 c = (fee * CREATOR_BPS) / BPS;
        uint256 lp = (fee * LP_BPS) / BPS;
        uint256 b;
        // BODKIN never buys-and-burns ITSELF: a self-buyback out of its own pool is circular (it would
        // pump its own price with its own fee), and BODKIN's deflation is meant to ride on the WHOLE
        // ecosystem's fees — every OTHER coin's 10% burn slice funds the BODKIN buy&burn. So on the
        // BODKIN launch that 10% rolls into the creator/platform cut instead, and its burn bucket
        // stays empty.
        //
        // `bodkin == address(0)` is the same case seen one step earlier: the burn venue is wired by
        // {setBodkinPool} only AFTER the BODKIN launch (it needs BODKIN's own pool key), so the dev
        // buy INSIDE that launch is the one swap that runs before the hook can recognise BODKIN by
        // address. Without this clause that dev buy's 10% sat in BODKIN's burn bucket and was bought
        // and burned out of BODKIN's own pool on the next trade — a self-burn, small but exactly the
        // thing ruled out above. With no venue there is nothing any burn slice could ever be spent
        // on anyway (the bucket would just strand ETH in the hook), so it rolls to the creator too.
        if (token == bodkin || bodkin == address(0)) {
            c += (fee * BURN_BPS) / BPS;
        } else {
            b = (fee * BURN_BPS) / BPS;
        }
        // Autocompound OFF: the 10% slice rolls into the creator cut instead of compounding this coin's
        // own pool. Off only when the creator chose so at launch (per-coin `autocompoundOff`). BODKIN
        // follows its own launch config like every other coin — the deploy scripts launch it with
        // autocompound OFF, so its slice rolls to the team cut. (The burn exemption above is the only
        // BODKIN-specific rule in this hook.)
        bool acOn = !_payoutCfg[token].autocompoundOff;
        uint256 a = acOn ? (fee * AUTOCOMPOUND_BPS) / BPS : 0;
        if (!acOn) c += (fee * AUTOCOMPOUND_BPS) / BPS;
        // LP slice → external full-range providers via the fee-growth accumulator (paid in numeraire on
        // claim). With NONE tracked it is never stranded — it goes to the CREATOR cut (her choice:
        // reward the creator when there is no third-party liquidity to reward, not autocompound).
        (uint256 lpBanked, uint256 lpFolded) = _creditLp(token, lp);
        c += lpFolded;
        uint256 t = fee - c - b - a - lpBanked; // remainder = team (no rounding dust loss)
        creatorWei[token] += c;
        burnWei[token] += b;
        autocompoundWei[token] += a;
        teamWei[token] += t;
        emit FeeAccrued(token, isBuy, fee);
        sp = FeeSplitAmounts({creator: c, lp: lpBanked, burn: b, autocompound: a, team: t});
    }

    // ── LP-position tracking (external, ANY range) ───────────────────────────────────────────────
    // Uniswap v3's fee-growth bookkeeping, kept by the hook for its numeraire LP slice: a global
    // accumulator per unit of ACTIVE liquidity, `feeGrowthOutside` per initialized tick, crossings
    // applied on every swap, and per-position `feeGrowthInside` snapshots. A position therefore earns
    // exactly while the price is inside its range — full-range positions always, concentrated ones
    // only in range — with no per-position loop on the swap path.

    /// @dev Fires on every liquidity ADD. Pure arithmetic + storage; the one revert is the reserved-tick
    ///      guard below. There is no longer a cap on how many distinct boundaries a coin's book may hold —
    ///      see {_lpBitmap} for why one was needed and why it is not any more.
    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        // Reserved boundary ticks (see {RESERVED_TICK_LO}): an outside add may not reference either, so no
        // one can saturate a tick the protocol's own migration and autocompound positions must keep adding
        // to. Reverting here reverts the whole modifyLiquidity, which is why the `beforeAddLiquidity`
        // permission is still off (turning it on would change the hook's address flags and force the
        // CREATE2 salt to be re-mined). The launcher's own seeding and the hook's own compound are exempt.
        if (sender != launcher && sender != address(this)) {
            if (
                params.tickLower == RESERVED_TICK_LO || params.tickLower == RESERVED_TICK_HI
                    || params.tickUpper == RESERVED_TICK_LO || params.tickUpper == RESERVED_TICK_HI
            ) revert ReservedBoundaryTick();
        }
        _trackLiquidity(sender, key, params);
        return (BaseHook.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    /// @dev Fires on every liquidity REMOVE — checkpoints the position's earned rewards and lowers the
    ///      tracked liquidity before it leaves.
    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        _trackLiquidity(sender, key, params);
        return (BaseHook.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    /// @dev Move the LP book from the tick it was last synced to, to the pool's current tick, applying
    ///      every initialized tick crossed in between (flip its `feeGrowthOutside`, apply its net
    ///      liquidity to the active total). Lazily initializes the book on first use.
    function _syncLpTick(address token, PoolKey memory key) internal {
        (, int24 tc,,) = poolManager.getSlot0(key.toId());
        if (!_lpTickInit[token]) {
            _lpTickInit[token] = true;
            _lpTick[token] = tc;
            return;
        }
        int24 prev = _lpTick[token];
        if (tc == prev) return;
        if (_lpTickCount[token] == 0) {
            _lpTick[token] = tc; // nothing external to cross; don't touch the bitmap at all
            return;
        }
        // Replay the crossings the swap made, in order, over this coin's book — the same SEARCH v4-core's
        // swap uses (its bitmap, its library), only after the fact: a hook sees the start and end tick,
        // never the steps, so `g` is the accumulator as it stands AFTER the swap and every tick this
        // replay crosses is flipped against that one value. v4's own loop interleaves crossing with
        // filling and so splits a swap's fees across the ranges it passes; this does not, and a range
        // swept end to end in one swap therefore earns nothing from it. That is unchanged from the
        // sorted-array version this replaced — as are the bounds: upward crosses every initialized t
        // with prev < t <= tc, downward every tc < t <= prev.
        mapping(int16 => uint256) storage bitmap = _lpBitmap[token];
        uint256 g = lpFeeGrowthGlobalX128[token];
        uint256 L = lpLiquidity[token];
        bool crossed;
        if (tc > prev) {
            int24 cursor = prev;
            while (cursor < tc) {
                // lte = false searches strictly ABOVE `cursor`; when the word holds nothing it returns
                // that word's last tick, which is what walks us into the next word.
                (int24 next, bool init) = TickBitmap.nextInitializedTickWithinOneWord(bitmap, cursor, TICK_SPACING, false);
                if (next > tc) break;
                if (init) {
                    LpTick storage ti = _lpTicks[token][next];
                    unchecked {
                        // (g - outside) written back with the bias: g - (stored - 1) + 1.
                        ti.feeGrowthOutsideX128 = g - ti.feeGrowthOutsideX128 + 2;
                    }
                    L = _applyNet(L, int256(ti.liquidityNet));
                    crossed = true;
                }
                cursor = next;
            }
        } else {
            int24 cursor = prev;
            while (cursor > tc) {
                // lte = true searches AT or below `cursor`, so the first step can cross a tick sitting
                // exactly on `prev`; stepping to next - 1 afterwards is how v4-core continues downward.
                (int24 next, bool init) = TickBitmap.nextInitializedTickWithinOneWord(bitmap, cursor, TICK_SPACING, true);
                if (next <= tc) break;
                if (init) {
                    LpTick storage ti = _lpTicks[token][next];
                    unchecked {
                        // (g - outside) written back with the bias: g - (stored - 1) + 1.
                        ti.feeGrowthOutsideX128 = g - ti.feeGrowthOutsideX128 + 2;
                    }
                    L = _applyNet(L, -int256(ti.liquidityNet));
                    crossed = true;
                }
                cursor = next - 1;
            }
        }
        if (crossed) lpLiquidity[token] = L;
        _lpTick[token] = tc;
    }

    /// @dev `L + net`, saturating at zero (the book only ever removes liquidity it added).
    function _applyNet(uint256 L, int256 net) internal pure returns (uint256) {
        if (net >= 0) return L + uint256(net);
        uint256 dec = uint256(-net);
        return dec >= L ? 0 : L - dec;
    }

    /// @dev Uniswap's `getFeeGrowthInside` for [lower, upper] at the synced tick (unchecked wrapping,
    ///      exactly as v3 does — only differences of these values are meaningful).
    function _lpGrowthInside(address token, int24 lower, int24 upper) internal view returns (uint256) {
        int24 tc = _lpTick[token];
        uint256 g = lpFeeGrowthGlobalX128[token];
        uint256 rawLo = _lpTicks[token][lower].feeGrowthOutsideX128;
        uint256 rawHi = _lpTicks[token][upper].feeGrowthOutsideX128;
        unchecked {
            // Both ticks belong to a tracked position, so both are initialized and carry the bias (see
            // {LpTick}). The zero check is not for today — it cannot happen today — it is for the day
            // someone adds a path that clears a tick while a position still references it. Unbiasing a
            // raw zero would read as "all the growth there has ever been", which on one side of the
            // range wraps the position's accrual to ~2**256 and pays out the coin's whole LP bank to
            // the first claimer. Treating it as zero degrades to a wrong-by-a-sliver answer instead.
            uint256 lo = rawLo == 0 ? 0 : rawLo - 1;
            uint256 hi = rawHi == 0 ? 0 : rawHi - 1;
            uint256 below = tc >= lower ? lo : g - lo;
            uint256 above = tc < upper ? hi : g - hi;
            return g - below - above;
        }
    }

    /// @dev Apply a liquidity change to one boundary tick (Uniswap's `Tick.update`): initialize it (by
    ///      convention all growth so far is "below" a tick at/under the current one) when its gross
    ///      liquidity goes 0 → >0. Returns true when it went >0 → 0 — the CALLER clears it, and only
    ///      after the position's checkpoint has read its `feeGrowthOutside` (v3's `ticks.clear` order).
    function _lpUpdateTick(address token, int24 t, int256 delta, bool isUpper) internal returns (bool emptied) {
        LpTick storage ti = _lpTicks[token][t];
        uint256 grossBefore = ti.liquidityGross;
        uint256 grossAfter = delta >= 0
            ? grossBefore + uint256(delta)
            : (uint256(-delta) >= grossBefore ? 0 : grossBefore - uint256(-delta));
        if (grossBefore == 0 && grossAfter > 0) {
            unchecked {
                ti.feeGrowthOutsideX128 = (t <= _lpTick[token] ? lpFeeGrowthGlobalX128[token] : 0) + 1;
            }
            _lpInsertTick(token, t);
        }
        int256 net = isUpper ? int256(ti.liquidityNet) - delta : int256(ti.liquidityNet) + delta;
        ti.liquidityGross = uint128(grossAfter);
        ti.liquidityNet = int128(net);
        return grossBefore > 0 && grossAfter == 0;
    }

    /// @dev Forget an emptied boundary tick (its snapshot is meaningless once nothing references it).
    function _lpClearTick(address token, int24 t) internal {
        _lpRemoveTick(token, t);
        delete _lpTicks[token][t];
    }

    /// @dev Mark a boundary tick initialized / uninitialized in this coin's book. Both are called
    ///      exactly once per transition by {_lpUpdateTick} / {_lpClearTick} (gross 0 -> >0 and back), which
    ///      is what `flipTick` needs: it toggles, so a double call would silently unset a live tick.
    function _lpInsertTick(address token, int24 t) internal {
        TickBitmap.flipTick(_lpBitmap[token], t, TICK_SPACING);
        unchecked {
            _lpTickCount[token] += 1;
        }
    }

    function _lpRemoveTick(address token, int24 t) internal {
        TickBitmap.flipTick(_lpBitmap[token], t, TICK_SPACING);
        unchecked {
            _lpTickCount[token] -= 1;
        }
    }

    /// @dev Checkpoint a position's earned LP rewards, then apply the liquidity change to its two
    ///      boundary ticks, to the active total when the range contains the tick, and to the position.
    function _trackLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata params) internal {
        // The coin's OWN locked liquidity earns no LP slice: the launcher seeds it (curve, walls, rungs,
        // the migrated full-range) and this hook deepens it via autocompound — both excluded so external
        // providers get the slice undiluted.
        if (sender == launcher || sender == address(this)) return;
        address token = Currency.unwrap(key.currency1);
        _syncLpTick(token, key);

        bytes32 posKey = keccak256(abi.encode(token, sender, params.salt));
        LpPosition storage pos = _lpPos[posKey];
        // Recorded for EVERY adder, not only listed PositionManagers: a PositionManager Uniswap ships later
        // and the 2-of-2 lists afterwards must still find the owner of a position closed before the
        // listing. It is only ever READ for a listed one, so the answer carries the listing's own trust.
        _rememberLpOwner(pos, sender, uint256(params.salt));
        int24 lower = params.tickLower;
        int24 upper = params.tickUpper;
        if (pos.liquidity == 0) {
            pos.tickLower = lower;
            pos.tickUpper = upper;
        } else if (pos.tickLower != lower || pos.tickUpper != upper) {
            // A salt reused on a DIFFERENT range: the PositionManager never does this (one tokenId, one
            // range), so this is a foreign caller's own accounting — leave the book alone.
            return;
        }
        int256 d = params.liquidityDelta;
        // Only liquidity this book has seen can leave it (a foreign remove can't push us negative).
        if (d < 0 && uint256(-d) > pos.liquidity) d = -int256(uint256(pos.liquidity));
        if (d == 0) return;

        bool lowerEmptied = _lpUpdateTick(token, lower, d, false);
        bool upperEmptied = _lpUpdateTick(token, upper, d, true);
        uint256 inside = _lpGrowthInside(token, lower, upper);
        if (pos.liquidity > 0) {
            unchecked {
                pos.owedWei += FullMath.mulDiv(inside - pos.growthInsideLastX128, pos.liquidity, LP_FEE_GROWTH_Q128);
            }
        }
        pos.growthInsideLastX128 = inside;
        int24 tc = _lpTick[token];
        if (lower <= tc && tc < upper) lpLiquidity[token] = _applyNet(lpLiquidity[token], d);
        pos.liquidity = d >= 0 ? pos.liquidity + uint128(uint256(d)) : pos.liquidity - uint128(uint256(-d));
        // Clear emptied boundaries LAST — the checkpoint above still needed their snapshots.
        if (lowerEmptied) _lpClearTick(token, lower);
        if (upperEmptied) _lpClearTick(token, upper);
    }

    /// @dev Record who owns position `tokenId` right now. Normally `ownerOf`; during a BURN the
    ///      PositionManager has already burned the NFT when our remove hook runs, so `ownerOf` reverts
    ///      and the only identity left is the account driving the burn (`msgSender()`, the owner or an
    ///      operator it approved) — recorded so the reward stays claimable after the position is gone.
    ///      Both reads go through {_readAddr}, which cannot revert: no adder can make an add/remove fail.
    function _rememberLpOwner(LpPosition storage pos, address pm, uint256 tokenId) internal {
        address o = _readAddr(pm, abi.encodeCall(IPositionManagerMinimal.ownerOf, (tokenId)));
        if (o == address(0)) o = _readAddr(pm, abi.encodeCall(IPositionManagerMinimal.msgSender, ()));
        if (o != address(0)) pos.lastOwner = o;
    }

    /// @dev Read one address from `target` WITHOUT ever reverting: a gas-capped staticcall that copies at
    ///      most one word back, where a failed call, an answer shorter than 32 bytes, or a word that is not
    ///      a clean address all read as "no answer" (address(0)). A high-level try/catch is not enough
    ///      here: it cannot catch a failure to DECODE the return data, so a contract answering with empty
    ///      or malformed data would make every add/remove it drives revert inside our hook.
    function _readAddr(address target, bytes memory callData) internal view returns (address a) {
        uint256 g = LP_OWNER_READ_GAS;
        assembly ("memory-safe") {
            // Scratch space 0x00-0x1f receives at most one word, so a huge answer costs nothing here.
            let ok := staticcall(g, target, add(callData, 0x20), mload(callData), 0x00, 0x20)
            if and(ok, iszero(lt(returndatasize(), 0x20))) {
                let w := mload(0x00)
                if iszero(shr(160, w)) { a := w }
            }
        }
    }

    /// @dev The numeraire a tracked position could claim right now: checkpointed + accrued since.
    function _lpOwed(bytes32 posKey, address token) internal view returns (uint256 owed) {
        LpPosition storage pos = _lpPos[posKey];
        owed = pos.owedWei;
        if (pos.liquidity > 0) {
            uint256 inside = _lpGrowthInside(token, pos.tickLower, pos.tickUpper);
            unchecked {
                owed += FullMath.mulDiv(inside - pos.growthInsideLastX128, pos.liquidity, LP_FEE_GROWTH_Q128);
            }
        }
    }

    /// @notice Pay an LP position's accrued rewards, in the coin's numeraire, to the CURRENT owner of
    ///         its Uniswap position NFT (`tokenId`) in the PRIMARY PositionManager. Any range; added on
    ///         Uniswap or on our site alike. Permissionless to trigger; the money always goes to the owner.
    function claimLpRewards(address token, uint256 tokenId) external returns (uint256 paid) {
        address pm = positionManager;
        require(pm != address(0), "FeeHook: pm unset");
        paid = _claimLp(token, pm, tokenId);
    }

    /// @notice The same claim for a position NFT held in ANY listed PositionManager ({positionManagers}),
    ///         e.g. a newer Uniswap PositionManager added after deploy. Reverts for an unlisted one.
    function claimLpRewards(address token, address pm, uint256 tokenId) external returns (uint256 paid) {
        if (!isPositionManager[pm]) revert UnknownPositionManager();
        paid = _claimLp(token, pm, tokenId);
    }

    function _claimLp(address token, address pm, uint256 tokenId) internal returns (uint256 paid) {
        bytes32 posKey = keccak256(abi.encode(token, pm, bytes32(tokenId)));
        LpPosition storage pos = _lpPos[posKey];
        // The CURRENT owner while the NFT exists; after a burn (closed on Uniswap, unclaimed), the
        // last owner this hook saw — the reward is never stranded by closing the position first. A burned
        // id may make `ownerOf` revert (solmate, the canonical PositionManager) or answer address(0) (other
        // ERC-721s): both fall back to the remembered owner.
        address nftOwner = _readAddr(pm, abi.encodeCall(IPositionManagerMinimal.ownerOf, (tokenId)));
        if (nftOwner == address(0)) nftOwner = pos.lastOwner;
        require(nftOwner != address(0), "FeeHook: unknown position");
        paid = _lpOwed(posKey, token);
        // Fold the accrued growth into the owed bucket and reset the snapshot.
        if (pos.liquidity > 0) pos.growthInsideLastX128 = _lpGrowthInside(token, pos.tickLower, pos.tickUpper);
        if (paid == 0) {
            pos.owedWei = 0;
            return 0;
        }
        // Never pay out more numeraire than is actually banked (rounding dust safety).
        uint256 bank = lpBankWei[token];
        if (paid > bank) paid = bank;
        pos.owedWei = 0; // zero BEFORE delivery (re-entrancy), atomic with a reverting transfer
        lpBankWei[token] = bank - paid;
        _deliver(numeraireOf(token), nftOwner, paid);
        if (pm == positionManager) emit LpRewardsClaimed(token, tokenId, nftOwner, paid);
        else emit LpRewardsClaimedVia(token, pm, tokenId, nftOwner, paid);
    }

    /// @notice View: the owner {claimLpRewards} would pay for `tokenId` (primary PositionManager) right
    ///         now — the NFT's current owner, or the last owner this hook saw once the NFT has been
    ///         burned. address(0) = unknown.
    function lpRewardRecipient(address token, uint256 tokenId) external view returns (address) {
        return _lpRecipient(token, positionManager, tokenId);
    }

    /// @notice View: the same for a position in any listed PositionManager. address(0) for an unlisted one.
    function lpRewardRecipient(address token, address pm, uint256 tokenId) external view returns (address) {
        return isPositionManager[pm] ? _lpRecipient(token, pm, tokenId) : address(0);
    }

    function _lpRecipient(address token, address pm, uint256 tokenId) internal view returns (address) {
        if (pm == address(0)) return address(0);
        address o = _readAddr(pm, abi.encodeCall(IPositionManagerMinimal.ownerOf, (tokenId)));
        return o != address(0) ? o : _lpPos[keccak256(abi.encode(token, pm, bytes32(tokenId)))].lastOwner;
    }

    /// @notice View: numeraire currently claimable by an LP position in the primary PositionManager
    ///         (checkpointed + accrued).
    function lpRewardsOwed(address token, uint256 tokenId) external view returns (uint256) {
        return _lpOwedCapped(token, positionManager, tokenId);
    }

    /// @notice View: the same for a position in any listed PositionManager. 0 for an unlisted one.
    function lpRewardsOwed(address token, address pm, uint256 tokenId) external view returns (uint256) {
        return isPositionManager[pm] ? _lpOwedCapped(token, pm, tokenId) : 0;
    }

    function _lpOwedCapped(address token, address pm, uint256 tokenId) internal view returns (uint256) {
        uint256 owed = _lpOwed(keccak256(abi.encode(token, pm, bytes32(tokenId))), token);
        uint256 bank = lpBankWei[token];
        return owed > bank ? bank : owed;
    }

    /// @notice View: one boundary tick of a coin's external-LP book. `growthOutsideBiased` is the raw
    ///         stored value, which carries the +1 bias described on {LpTick} and is therefore never zero
    ///         while the tick is initialized — a zero here means the tick does not exist.
    function lpTick(address token, int24 tick)
        external
        view
        returns (uint128 liquidityGross, int128 liquidityNet, uint256 growthOutsideBiased)
    {
        LpTick storage t = _lpTicks[token][tick];
        return (t.liquidityGross, t.liquidityNet, t.feeGrowthOutsideX128);
    }

    /// @notice View: what the book holds for a position keyed by its adder + salt (the PositionManager
    ///         uses the tokenId as salt) — range, liquidity and claimable numeraire.
    function lpPosition(address token, address sender, bytes32 salt)
        external
        view
        returns (int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 owed)
    {
        bytes32 posKey = keccak256(abi.encode(token, sender, salt));
        LpPosition storage pos = _lpPos[posKey];
        return (pos.tickLower, pos.tickUpper, pos.liquidity, _lpOwed(posKey, token));
    }

    /// @notice A coin's autocompound slice was folded back into ITS OWN migrated full-range position:
    ///         `numeraireIn` of its numeraire (this chunk, some swapped to the token) deepened liquidity
    ///         by `liquidityAdded`. Emitted by the hook itself — the indexer tracks the coin's position L
    ///         from these. See {compoundStep}.
    event Compounded(address indexed token, uint256 numeraireIn, uint128 liquidityAdded);

    // --- claims → already in the party's payout token (USDC by default) ---

    /// @notice Withdraw this launch's creator fees, ALREADY denominated in the payout
    ///         token — no swap happens here, so there is no slippage and no `minOut`.
    ///         The conversion was done incrementally by the swaps that earned the fee.
    /// @dev Claimable ONLY by the current holder of the fee NFT, and paid to that same
    ///      holder. One address, no override: the fee stream is the NFT, so transferring
    ///      the NFT transfers the income. A creator who wants the fees at a different
    ///      wallet picks it at launch and the launcher mints the NFT there.
    ///
    ///      The team's banked slice for the SAME token is pushed out in the same
    ///      transaction — see {_tryPushTeam}. It rides along strictly AFTER the
    ///      creator's own delivery has settled, so the creator's money is never in
    ///      flight while the team's leg runs.
    /// @dev A launch's creator fees can be split across two currencies — the chosen payout
    ///      token ({creatorOut}) and the numeraire fallback ({creatorOutNum}, banked when the
    ///      payout route stayed dry). Each leg is delivered behind its OWN self-only
    ///      try/catch step, exactly like the team leg, so a delivery that reverts — a dead
    ///      payout token whose transfers fail, or a contract holder that rejects ETH — rolls
    ///      back only its own zeroing, leaving that bucket banked and independently
    ///      reclaimable, and can NEVER strand or reverse the other leg. This isolation is
    ///      load-bearing for the fallback: a payout pool goes dry precisely when its token is
    ///      dying, which is exactly when its transfers start to revert — so the numeraire the
    ///      creator is owed must not ride on the payout token's delivery succeeding. `paid` is
    ///      the payout-token leg actually delivered; the fallback leg is reported by
    ///      {CreatorClaimedFallback} and readable via `creatorOutNum`.
    function claimCreator(address token) external returns (uint256 paid) {
        address holder = creatorNFT.creatorOf(token);
        if (msg.sender != holder) revert NotCreator();
        paid = _tryPushCreatorToken(token, holder);
        _tryPushCreatorNum(token, holder);
        _tryPushTeam(token);
    }

    /// @dev Deliver the creator's payout-token leg, isolated so a reverting transfer leaves
    ///      the balance banked for a later claim rather than taking the whole call down.
    function _tryPushCreatorToken(address token, address holder) internal returns (uint256 paid) {
        try this.pushCreatorTokenStep(token, holder) returns (uint256 p) {
            paid = p;
        } catch {}
    }

    /// @dev The payout-token delivery body. `external` + self-only so {_tryPushCreatorToken}
    ///      can wrap it in try/catch. Zeroes BEFORE delivery: a re-entrant claim finds 0, and
    ///      a reverting transfer rolls that zeroing back with it (atomic in both directions).
    function pushCreatorTokenStep(address token, address holder) external returns (uint256 paid) {
        if (msg.sender != address(this)) revert NotManager();
        paid = creatorOut[token];
        if (paid == 0) return 0;
        creatorOut[token] = 0;
        address pt = payoutTokenOf(token);
        _deliver(pt, holder, paid);
        emit CreatorClaimed(token, holder, pt, paid, paid);
    }

    /// @dev Deliver the creator's numeraire fallback leg, isolated the same way — so a dead
    ///      payout token's failing transfer can never strand the numeraire the creator is owed.
    function _tryPushCreatorNum(address token, address holder) internal {
        try this.pushCreatorNumStep(token, holder) {} catch {}
    }

    function pushCreatorNumStep(address token, address holder) external {
        if (msg.sender != address(this)) revert NotManager();
        uint256 owed = creatorOutNum[token];
        if (owed == 0) return;
        creatorOutNum[token] = 0;
        address num = numeraireOf(token);
        _deliver(num, holder, owed);
        emit CreatorClaimedFallback(token, holder, num, owed);
    }

    /// @dev Push ALL of the team's banked currencies alongside a creator claim, each isolated so it
    ///      is IMPOSSIBLE for a team leg to cost the creator their own claim. Same construction as
    ///      {_tryBurnStep}: a revert inside the external call is caught here, and everything the
    ///      failed attempt touched — the zeroed `teamOut[token][cur]`, the pool deltas, the unlock —
    ///      rolls back with it. So a broken leg (e.g. a dead OLD-USDC whose transfers now revert)
    ///      leaves that balance banked for {claimTeam}, and can never strand or reverse the creator's
    ///      payment OR the team's other, healthy currencies. Iterates the bounded
    ///      {teamBankedCurrencies}; a currency with nothing banked is one short-circuiting SLOAD.
    ///      `_deliver` is `internal` and Solidity cannot try/catch an internal call, which is why the
    ///      per-currency body lives behind a self-only external entrypoint.
    function _tryPushTeam(address token) internal {
        address[] memory curs = teamBankedCurrencies;
        for (uint256 i = 0; i < curs.length; i++) {
            try this.pushTeamCurrencyStep(token, curs[i]) returns (uint256) {} catch {}
        }
    }

    /// @dev Deliver ONE currency's banked team slice for `token`. `external` ONLY so the try/catch
    ///      wrappers can reach it through `this` — that boundary is the entire point; callable by
    ///      nobody else, since it moves money and a stranger could otherwise choose the moment a
    ///      team leg runs.
    ///
    ///      Zeroing BEFORE {_deliver} is load-bearing, not habit: delivery settles through
    ///      `poolManager.unlock`, which hands control to the currency's own transfer code mid-call,
    ///      and `usdc` is now RE-POINTABLE — a migrated USDC could carry transfer hooks — so a
    ///      re-entrant claim must find 0 here, or the same slice pays out twice. The write and the
    ///      transfer are in ONE frame, so the pair is atomic in both directions: either the team was
    ///      paid and `teamOut[token][cur]` is 0, or neither happened. Each `cur` addresses only ITS
    ///      OWN banked amount, so a per-currency claim can never reach the ERC-6909 claims backing a
    ///      different launch or a different currency.
    function pushTeamCurrencyStep(address token, address cur) external returns (uint256 owed) {
        if (msg.sender != address(this)) revert NotManager();
        owed = teamOut[token][cur];
        if (owed == 0) return 0; // nothing banked in this currency: no unlock, no transfer, no cost
        teamOut[token][cur] = 0;
        _deliver(cur, team, owed);
        emit TeamClaimed(token, cur, owed, owed);
    }

    /// @notice Withdraw the team's slice for `token` in EVERY currency it was banked in at once —
    ///         old USDC, new USDC and native ETH together — each already converted: transfers, not
    ///         conversions. This is the multi-currency claim that makes a USDC re-point safe: fees
    ///         banked in the old USDC never strand, they are simply another currency in the sweep.
    /// @dev KEPT despite the automatic push on every creator claim: the escape hatch for a launch
    ///      whose creator never claims, and for a currency whose pushed delivery once failed and left
    ///      the balance banked. Each currency is an isolated self-only step, so one dead currency
    ///      never blocks the live ones. Returns the raw summed amount across currencies (exact in the
    ///      usual single-currency case; a bare sum when several settled).
    function claimTeam(address token) external returns (uint256 paid) {
        if (msg.sender != team) revert NotTeam();
        address[] memory curs = teamBankedCurrencies;
        for (uint256 i = 0; i < curs.length; i++) {
            try this.pushTeamCurrencyStep(token, curs[i]) returns (uint256 p) {
                paid += p;
            } catch {}
        }
    }

    /// @dev Hand `amount` of `currency` to `to`: burn the hook's ERC-6909 claims and let
    ///      the manager transfer the real tokens out. A zero-leg {Route} does exactly
    ///      this, so the settlement pattern lives in one place.
    function _deliver(address currency, address to, uint256 amount) internal {
        Route memory r;
        r.src = Currency.wrap(currency);
        r.amountIn = amount;
        r.to = to;
        r.legCount = 0;
        poolManager.unlock(abi.encode(_ACT_ROUTE, r));
    }

    /// @dev A config describing the protocol-default route from `numeraire` to
    ///      `payoutToken` (no swap when they match, else the canonical `_usdcPool`).
    /// @dev The protocol-default route config. Only `numeraire` is ever read from it —
    ///      {_routeTo} takes the payout token as its own argument and looks at
    ///      `viaHub`/`fee`/`tickSpacing` (all zero here, which is what "default" means).
    ///      Setting `token`/`set` as well were dead stores.
    function _defaultCfg(address, address numeraire) internal pure returns (PayoutConfig memory c) {
        c.numeraire = numeraire;
    }

    // ── buy & burn ──────────────────────────────────────────────────────────
    //
    // The 10% burn bucket is converted to BODKIN and burned WITHOUT a keeper, and
    // without the conversion ever being able to fail a user's swap. Three properties
    // carry that, and they are worth stating because each one is load-bearing:
    //
    // 1. SIZE, not slippage, is what makes this safe. The floor on a permissionless
    //    conversion cannot come from its caller — an attacker calls it with 0. So the
    //    hook instead spends at most `_safeBurnChunk`: the largest amount that cannot
    //    be sandwiched at a PROFIT, derived from the pool's own liquidity and fee.
    //    Sandwiching a spend of `v` against depth `x` at fee `f` nets
    //    `(√v − √(2·f·x))²` before costs, i.e. nothing at all while `v ≤ 2·f·x`.
    //    The cap here is `f·x`, half of break-even, so the margin absorbs the fact
    //    that concentrated liquidity makes `x` an approximation.
    //
    // 2. The remainder is KEPT. A chunk that does not fit stays in `burnWei` and the
    //    next swap converts more. That is the retry mechanism: no queue, no keeper,
    //    no cron — trading itself paces the buyback, one chunk per block, which is
    //    the same time-averaging a TWAP keeper would do, minus the keeper.
    //
    // 3. Nothing here can revert a swap. `_afterSwap` invokes the step through an
    //    external self-call wrapped in try/catch, so ANY failure — an uninitialised
    //    pool, a partial fill, thin liquidity — rolls that call back and leaves the
    //    bucket exactly as it was. A failed burn is a no-op, never a failed trade.

    /// One chunk per token per block. Prevents draining the bucket by calling this
    /// repeatedly inside one sandwich: the per-call cap only bounds an attacker if it
    /// also bounds how many calls fit in a transaction.
    mapping(address => uint256) public lastBurnBlock;

    /// Per-VENUE spend already made this block, in BODKIN-pool terms, and the block it
    /// belongs to.
    ///
    /// `lastBurnBlock` is keyed on the LAUNCH TOKEN, but every ETH launch's burn buys
    /// through the SAME pool, and `processBurn` is permissionless. So N tokens with
    /// filled buckets meant N independent per-token caps landing in ONE transaction:
    /// buy, `processBurn(t1..tN)`, sell. The per-token cap is half of the 2·f·x
    /// sandwich break-even, so THREE tokens already crossed it; a measured proof-of-
    /// concept on 8 launches forced 0.90 ETH of buying against a 0.108 ETH cap (4.1x
    /// break-even, ~15% price move) and cleared ~0.14 ETH per pass, every block.
    ///
    /// The invariant the design always claimed — "no more than one safe chunk of
    /// forced buying per block" — has to be enforced where the forcing happens: the
    /// venue. This pair is that budget. It is NOT redundant with `lastBurnBlock`,
    /// which still stops one token being drained by repeated calls.
    /// The BODKIN pool's price, as a two-stage shift register.
    ///
    /// `_bodkinRefPrev` is what the band is measured against and is ALWAYS from a
    /// strictly earlier block; `_bodkinRefCur` is this block's observation, waiting to
    /// become the next one's reference. Two slots, not one, precisely so an attacker
    /// who lands FIRST in a block cannot set the price their own burn is judged
    /// against — with a single slot, being top-of-block is enough to defeat the band.
    ///
    /// Advanced on EVERY swap and every manual trigger, not only when a burn succeeds.
    /// That is the difference between a band that recovers and one that stalls forever:
    /// a reference which only moves on success has no way back once it has said no.
    mapping(bytes32 => uint160) internal _refPrev;
    mapping(bytes32 => uint160) internal _refCur;
    mapping(bytes32 => uint256) internal _refBlock;

    uint256 internal _venueBurnBlock;
    uint256 internal _venueBurnSpent;
    /// The budget itself, FROZEN when the block's first burn books its spend.
    ///
    /// Recomputing `f·x` per call would let the block's own burning inflate the
    /// allowance: each chunk pushes ETH into the venue, growing the reserve `x` and
    /// therefore the cap, so N chunks could still exceed the single-chunk bound
    /// (measured: 8 chunks totalled 1.01x the cap even with the aggregate check).
    /// One measurement per block is what "one safe chunk per block" actually means.
    uint256 internal _venueBurnCap;

    /// The SAME per-block aggregate budget, for the fee CONVERSION venue: the one canonical
    /// `_usdcPool` (ETH<->USDC) that every ETH-numeraire creator/team conversion routes its bridge
    /// leg through. Without it the per-token per-block guards (`lastCreatorConvertBlock` /
    /// `lastTeamConvertBlock`) bound only ONE token at a time, so N tokens' conversions could be
    /// batched into a single sandwiched tx on that shared pool. Booked and frozen exactly like the
    /// burn venue above (see {_bookConvVenueSpend}); kept SEPARATE from the burn budget because the
    /// venues differ (`_usdcPool` vs `_bodkinPool`) and each is bounded to its own single safe chunk.
    uint256 internal _venueConvBlock;
    uint256 internal _venueConvSpent;
    uint256 internal _venueConvCap;

    // ── fees banked in the PAYOUT token ─────────────────────────────────────
    //
    // The 1% is skimmed in the pool's numeraire because that is the only currency the
    // swap actually touches. It does NOT stay there: the same swap-driven, chunked,
    // try/catch-protected mechanism that runs the buy & burn also converts each party's
    // slice into the token they chose, and banks it here as ERC-6909 claims.
    //
    // So `creatorWei` is a WAITING ROOM, not the balance — it drains into `creatorOut`,
    // which is denominated in that launch's payout token and is what a claim pays out.
    // The consequence worth stating: claiming no longer performs a swap, so it has no
    // slippage, needs no `minOut`, and cannot revert on price. The creator's holdings
    // stopped being exposed to the numeraire the moment the fee was earned, instead of
    // whenever they got round to clicking claim.
    mapping(address => uint256) public creatorOut;
    /// @notice Team fees converted and banked, keyed (launch token => currency => amount). Nested by
    ///         CURRENCY so a USDC migration never strands the team's already-banked slices: fees banked
    ///         in the old USDC stay under `teamOut[token][oldUsdc]` and are claimed in old USDC, while
    ///         new fees bank under the new currency. address(0) = native ETH. The set of currencies
    ///         with any balance is a subset of {teamBankedCurrencies}, which {claimTeam} iterates.
    mapping(address => mapping(address => uint256)) public teamOut;
    mapping(address => uint256) public lastCreatorConvertBlock;
    mapping(address => uint256) public lastTeamConvertBlock;

    /// Creator fees that could NOT be converted to the chosen payout token because there was
    /// no healthy route this swap — banked in the launch NUMERAIRE instead of stranding, and
    /// claimable directly (no swap) via {claimCreator}. Decided per swap and stateless: a
    /// swap with no route sends that slice here; the next swap converts to the chosen token
    /// again the moment a route is back. A launch's fees can therefore end up split — part in
    /// the payout token ({creatorOut}), part in the numeraire (here). The team's slice falls back
    /// the same way, but per-currency into `teamOut[token][numeraire]` (see {_convertChunk}).
    mapping(address => uint256) public creatorOutNum;

    event FeesConverted(address indexed token, bool creator, address payoutToken, uint256 amountIn, uint256 banked);
    /// A creator conversion fell back to the numeraire because there was no healthy route this
    /// swap. `amount` is in the launch numeraire (`numeraireOf(token)`).
    event CreatorFellBackToNumeraire(address indexed token, address numeraire, uint256 amount);
    /// The team slice of a launch whose numeraire is a DEPRECATED USDC (a later {migrateUsdc} moved
    /// the canonical pool off it) is banked in that old numeraire — still a claimable team currency —
    /// instead of stalling, since there is no route out of it. Mirrors {CreatorFellBackToNumeraire}.
    event TeamFellBackToNumeraire(address indexed token, address numeraire, uint256 amount);

    /// @dev The largest spend through `k` that a sandwich cannot profit from,
    ///      denominated in the currency being spent. Returns 0 when the pool is
    ///      uninitialised, has no liquidity in range, or is fee-free — all cases where
    ///      no safe size exists and the honest answer is to burn nothing this block.
    /// @dev Per-venue band parameters: the gate width (`slipBps`, price space) + its sqrt-space clamp
    ///      bounds. `_burnBand` serves the buy & burn + conversions (shared BODKIN venue); `_compoundBand`
    ///      serves the autocompound (each coin's OWN pool). Separate so the two can be tuned apart — the
    ///      reference state itself is already per-pool (keyed by poolId in `_refPrev`/`_refCur`).
    struct Band {
        uint256 slipBps;
        uint256 sqrtLoBps;
        uint256 sqrtHiBps;
    }

    function _burnBand() internal pure returns (Band memory) {
        return Band(BURN_SLIPPAGE_BPS, BURN_SQRT_BAND_LO_BPS, BURN_SQRT_BAND_HI_BPS);
    }

    function _compoundBand() internal pure returns (Band memory) {
        return Band(COMPOUND_SLIPPAGE_BPS, COMPOUND_SQRT_BAND_LO_BPS, COMPOUND_SQRT_BAND_HI_BPS);
    }

    /// @dev True when the pool has not moved more than `b.slipBps` against the spender since an EARLIER
    ///      block. For the BODKIN venue: ETH is `currency0` by construction ({setBodkinPool}), so the pool
    ///      price (currency1 per currency0) IS "BODKIN per ETH" and FALLS as BODKIN gets dearer — the
    ///      direction a front-run pushes it, hence a floor when spending currency0, a cap when spending
    ///      currency1. Compared in PRICE space (two `mulDiv`s, no uint160 squaring overflow).
    function _withinBand(PoolKey memory k, bool inIsZero, Band memory b) internal view returns (bool) {
        uint160 refSqrt = _refPrev[PoolId.unwrap(k.toId())];
        if (refSqrt == 0) return true; // nothing observed yet: the size cap still applies
        (uint160 nowSqrt,,,) = poolManager.getSlot0(k.toId());
        if (nowSqrt == 0) return false;
        uint256 nowP = FullMath.mulDiv(nowSqrt, nowSqrt, FixedPoint96.Q96);
        uint256 refP = FullMath.mulDiv(refSqrt, refSqrt, FixedPoint96.Q96);
        return inIsZero
            ? nowP >= FullMath.mulDiv(refP, BPS - b.slipBps, BPS)
            : nowP <= FullMath.mulDiv(refP, BPS + b.slipBps, BPS);
    }

    /// @dev Every pool a route spends through, still within the band. Routes are burn/conversion only.
    function _withinRouteBand(Route memory r, Band memory b) internal view returns (bool) {
        address src = Currency.unwrap(r.src);
        address l1c0 = Currency.unwrap(r.leg1.currency0);
        bool srcIsZero = l1c0 == src;
        if (!_withinBand(r.leg1, srcIsZero, b)) return false;
        if (r.legCount < 2) return true;
        // Leg 2 spends whatever leg 1 produced — the OTHER side of leg 1.
        address mid = srcIsZero ? Currency.unwrap(r.leg1.currency1) : l1c0;
        return _withinBand(r.leg2, Currency.unwrap(r.leg2.currency0) == mid, b);
    }

    /// @dev Shift every pool the route touches, and the same for a single pool.
    function _advanceRouteRefs(Route memory r, Band memory b) internal {
        _advanceRef(r.leg1, b);
        if (r.legCount >= 2) _advanceRef(r.leg2, b);
    }

    /// @dev Shift the reference on once per block. Called on every ATTEMPT, not only on success — a
    ///      reference that advances only when the step succeeds can never recover once the band has said
    ///      no, which under test stalled the pipeline permanently.
    function _advanceRef(PoolKey memory k, Band memory b) internal {
        bytes32 id = PoolId.unwrap(k.toId());
        if (_refBlock[id] == block.number) return;
        (uint160 sqrtNow,,,) = poolManager.getSlot0(k.toId());
        if (sqrtNow == 0) return;
        uint160 prev = _refCur[id];
        _refPrev[id] = prev; // always from a strictly earlier block
        // CLAMPED to one band-width per block, so the reference is a RATE LIMIT, not just a test: an
        // attacker can move the price into the next block's reference by at most one band-width, and pays
        // the round-trip toll for every step of the walk instead of displacing it once for free.
        _refCur[id] = prev == 0 ? sqrtNow : _clampStep(prev, sqrtNow, b);
        _refBlock[id] = block.number;
    }

    /// @dev `sqrtNow` limited to one `b.slipBps` step away from `prev`. Bounds are in SQRT space (the
    ///      square roots of the price band), each rounded INWARD so the clamp is never looser than the
    ///      band it enforces.
    function _clampStep(uint160 prev, uint160 sqrtNow, Band memory b) internal pure returns (uint160) {
        uint256 lo = FullMath.mulDiv(prev, b.sqrtLoBps, BPS);
        uint256 hi = FullMath.mulDiv(prev, b.sqrtHiBps, BPS);
        if (sqrtNow < lo) return uint160(lo);
        if (sqrtNow > hi) return uint160(hi);
        return sqrtNow;
    }

    /// @dev The hard `sqrtPriceLimitX96` for ONE internal swap on `k`, spending `inIsZero`'s side, derived
    ///      ON-CHAIN from THIS pool's banded reference (`_refPrev`) — never from a caller. The swap may
    ///      push the price at most `loBps`/`hiBps` (sqrt space) from that reference before it stops; the
    ///      resulting partial fill makes {_swapLeg} revert, which the step turns into a wait-a-block skip.
    ///      This is the SECOND guard (execution price) on top of the size cap + gate band: a displaced or
    ///      thin pool that would fill past the limit gets no fill at all. `loBps == 0`, or no reference
    ///      observed yet, ⇒ no limit (size cap governs). Because every caller's GATE band is TIGHTER than
    ///      its limit band, a passed gate guarantees the current price is on the fillable side of the
    ///      limit, so a healthy chunk (impact < limit) always clears.
    function _swapLimit(PoolKey memory k, bool inIsZero, uint256 loBps, uint256 hiBps)
        internal
        view
        returns (uint160)
    {
        uint160 unlimited = inIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        if (loBps == 0) return unlimited;
        uint160 refSqrt = _refPrev[PoolId.unwrap(k.toId())];
        if (refSqrt == 0) return unlimited;
        uint256 lim = FullMath.mulDiv(refSqrt, inIsZero ? loBps : hiBps, BPS);
        uint256 minP = uint256(TickMath.MIN_SQRT_PRICE) + 1;
        uint256 maxP = uint256(TickMath.MAX_SQRT_PRICE) - 1;
        if (lim < minP) return uint160(minP);
        if (lim > maxP) return uint160(maxP);
        return uint160(lim);
    }

    function _safeBurnChunk(PoolKey memory k, bool inIsZero) internal view returns (uint256) {
        PoolId id = k.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        if (sqrtPriceX96 == 0) return 0;
        uint128 liquidity = poolManager.getLiquidity(id);
        if (liquidity == 0) return 0;
        // Virtual reserve of the spent side at the current price: x = L/√P for
        // currency0, y = L·√P for currency1.
        uint256 reserveIn = inIsZero
            ? FullMath.mulDiv(liquidity, FixedPoint96.Q96, sqrtPriceX96)
            : FullMath.mulDiv(liquidity, sqrtPriceX96, FixedPoint96.Q96);
        // f·x, with the V4 fee in hundredths of a bip (1e6 == 100%). A zero-fee pool
        // yields zero: there is genuinely no unprofitable size when the round trip is
        // free, which is why `setBodkinPool` refuses one outright.
        //
        // On one of OUR OWN pools the pool fee is 0 but the round trip is not free:
        // this hook skims FEE_BPS of the numeraire side in `_beforeSwap`/`_afterSwap`,
        // so the sandwicher's toll — and therefore the safe chunk — prices at FEE_BPS,
        // converted to the pool-fee scale (bps of 1e4 → hundredths-of-bip of 1e6).
        uint24 fee = address(k.hooks) == address(this) ? uint24(FEE_BPS * 100) : k.fee;
        return FullMath.mulDiv(reserveIn, fee, 1e6);
    }

    /// @dev Value of `amountIn` of one side of `k` in the OTHER side, at spot.
    ///      Approximate (ignores depth) and only ever used to compare two caps, never to
    ///      price a trade.
    function _valueAcross(PoolKey memory k, bool inIsZero, uint256 amountIn) internal view returns (uint256) {
        (uint160 sp,,,) = poolManager.getSlot0(k.toId());
        if (sp == 0 || amountIn == 0) return 0;
        // price = (√P)² = currency1 per currency0.
        return inIsZero
            ? FullMath.mulDiv(FullMath.mulDiv(amountIn, sp, FixedPoint96.Q96), sp, FixedPoint96.Q96)
            : FullMath.mulDiv(FullMath.mulDiv(amountIn, FixedPoint96.Q96, sp), FixedPoint96.Q96, sp);
    }

    /// @dev The safe input size for a whole route, in the SOURCE currency.
    ///
    /// Both hops are sandwichable, so the bound is the tighter of the two — and a
    /// two-hop route bounded only by its first leg is worse than unbounded: a thin second
    /// leg then rejects every attempt (partial fill), and the bucket never drains at all.
    /// The second leg's cap is carried back through the first leg's spot price so the two
    /// are comparable.
    function _routeCap(Route memory r) internal view returns (uint256) {
        bool srcIsZero1 = Currency.unwrap(r.src) == Currency.unwrap(r.leg1.currency0);
        uint256 cap1 = _safeBurnChunk(r.leg1, srcIsZero1);
        if (r.legCount == 1 || cap1 == 0) return cap1;

        // The intermediate is whatever leg1 pays out — the other side of leg1.
        Currency mid = srcIsZero1 ? r.leg1.currency1 : r.leg1.currency0;
        bool midIsZero2 = Currency.unwrap(mid) == Currency.unwrap(r.leg2.currency0);
        uint256 cap2Mid = _safeBurnChunk(r.leg2, midIsZero2);
        if (cap2Mid == 0) return 0;
        uint256 cap2InSrc = _valueAcross(r.leg1, !srcIsZero1, cap2Mid);
        return cap1 < cap2InSrc ? cap1 : cap2InSrc;
    }

    /// @dev Build this block's burn chunk for `token`, or `amount == 0` when there is
    ///      nothing safe to do. Pure decision-making — no state written, no swap made —
    ///      so both the swap-path trigger and the external entrypoint agree exactly.
    function _burnChunk(address token) internal view returns (Route memory r, uint256 amount) {
        if (!_bodkinPoolSet) return (r, 0);
        uint256 bucket = burnWei[token];
        if (bucket == 0) return (r, 0);
        if (block.number <= lastBurnBlock[token]) return (r, 0);

        address src = numeraireOf(token);
        // Stale numeraire: a deprecated-USDC-numeraire launch (a later {migrateUsdc} moved the canonical
        // ETH<->USDC pool off it) has no route from its numeraire to BODKIN — the USDC->ETH bridge would
        // run through the re-pointed `_usdcPool` and leave the stale-USDC leg unsettled, reverting the
        // whole swap it rides on. Skip the burn (the buy&burn is deflationary, not a claim owed to
        // anyone, so leaving `burnWei` unspent strands nothing) rather than attempt a broken route.
        if (src != address(0) && src != usdc) return (r, 0);
        r.src = Currency.wrap(src);
        r.to = DEAD;
        // No caller-facing slippage FLOOR (minOut): a floor on a permissionless call is a griefing lever,
        // not protection. Price protection is SIZE + gate band + the reference-derived EXECUTION LIMIT
        // below (applied per-leg in _runRoute). On the swap-path the limit's partial-fill reverts inside
        // the try/catch (skip); on the manual path it reverts the call (retry next block) — never strands.
        r.minOut = 0;
        r.limitLoBps = BURN_SWAP_LIMIT_LO_BPS;
        r.limitHiBps = BURN_SWAP_LIMIT_HI_BPS;

        uint256 cap;
        // Frozen for the rest of a block once that block's first burn has booked.
        uint256 venueCap =
            block.number == _venueBurnBlock ? _venueBurnCap : _safeBurnChunk(_bodkinPool, true);
        if (src == address(0)) {
            // ETH -> BODKIN, one hop. ETH is currency0 of the BODKIN pool by construction
            // (setBodkinPool requires it), so the spent side is token0.
            r.leg1 = _bodkinPool;
            r.legCount = 1;
            cap = venueCap;
        } else {
            // BODKIN only pairs with ETH, so a USDC bucket bridges: USDC -> ETH -> BODKIN.
            // (Deliberately no (USDC, BODKIN) pool — it would fragment BODKIN liquidity.)
            if (!_usdcPoolSet) return (r, 0);
            r.leg1 = _usdcPool;
            r.leg2 = _bodkinPool;
            r.legCount = 2;
            // Both hops are sandwichable, so the same whole-route bound applies here.
            cap = _routeCap(r);
        }
        if (cap == 0) return (r, 0);

        // Spend it against the VENUE's budget for this block, not just this token's.
        // Both hops of a USDC route are bounded by `_routeCap`, but what has to be
        // aggregated is the ETH actually hitting the BODKIN pool, so the remaining
        // budget is carried back into the source currency the same way `_routeCap`
        // carries leg 2's cap back through leg 1.
        uint256 spent = block.number == _venueBurnBlock ? _venueBurnSpent : 0;
        if (spent >= venueCap) return (r, 0);
        uint256 leftAtVenue = venueCap - spent;
        // `leftAtVenue` is ETH — currency0 of `_usdcPool` (setUsdcPool pins it) — so the
        // conversion to USDC is the currency0 direction: `true`. It said `false`, which
        // DIVIDED by the price instead of multiplying and made the remaining budget come
        // out ~1e17x too large, so `cap > leftInSrc` never clipped anything.
        uint256 leftInSrc =
            src == address(0) ? leftAtVenue : _valueAcross(_usdcPool, true, leftAtVenue);
        if (leftInSrc == 0) return (r, 0);
        if (cap > leftInSrc) cap = leftInSrc;

        amount = bucket < cap ? bucket : cap;
        r.amountIn = amount;
    }

    /// @notice The venue's safe burn chunk right now, in ETH — the whole block's budget
    ///         for forced buying, shared by every launch. Exposed for tests/monitoring.
    function safeBurnChunkView() external view returns (uint256) {
        if (!_bodkinPoolSet) return 0;
        return _safeBurnChunk(_bodkinPool, true);
    }

    /// @dev Book `amount` (in `token`'s numeraire) against the venue's per-block budget.
    ///      Called by BOTH burn entrypoints, right where they stamp `lastBurnBlock`, so
    ///      the swap path and the permissionless path share one budget.
    function _bookVenueSpend(address token, uint256 amount) internal {
        if (block.number != _venueBurnBlock) {
            _venueBurnBlock = block.number;
            _venueBurnSpent = 0;
            // Booking runs BEFORE the route swaps, so this reads the venue as it was
            // before any of this block's forced buying.
            _venueBurnCap = _safeBurnChunk(_bodkinPool, true);
        }
        // Convert a USDC spend into what it will push through the BODKIN pool, so one
        // budget covers both route shapes.
        // `amount` is USDC — currency1 — so booking it against an ETH-denominated budget
        // is the currency1 direction: `false`. It said `true`, which MULTIPLIED micro-USDC
        // by a ~3e-9 raw price: a $300 chunk booked 0 wei (it truncates), so
        // `_venueBurnSpent` never grew and `spent >= venueCap` never tripped. The whole
        // per-block venue budget was inert for every USDC-quoted launch — the exact
        // aggregation attack it was added to stop. `_routeCap` had it right all along.
        _venueBurnSpent +=
            numeraireOf(token) == address(0) ? amount : _valueAcross(_usdcPool, false, amount);
    }

    /// @notice How much of THIS block's shared venue budget the buy & burn has spent,
    ///         in the venue's own currency (ETH). Zero once the block rolls over.
    ///
    /// Exposed because the number is otherwise unobservable, and an inverted unit here
    /// silently disables the aggregate cap rather than failing: a USDC-quoted burn
    /// booked through the wrong side of the price came out as 0 wei and the budget
    /// never bound. A view is what lets a test say so.
    function venueBurnSpent() external view returns (uint256) {
        return block.number == _venueBurnBlock ? _venueBurnSpent : 0;
    }

    /// @dev Whether a conversion route pushes through the SHARED `_usdcPool` (ETH<->USDC): the 1-leg
    ///      canonical ETH<->USDC route, or the leg-1 bridge of a viaHub custom payout. Direct
    ///      (numeraire, token) pairs and the WETH-paired path use PER-LAUNCH pools, so they never
    ///      contend on the shared venue and are exempt.
    function _routeUsesUsdcPool(Route memory r) internal view returns (bool) {
        if (!_usdcPoolSet || r.legCount == 0 || r.wrapToWeth) return false;
        return PoolId.unwrap(r.leg1.toId()) == PoolId.unwrap(_usdcPool.toId());
    }

    /// @dev Book `amount` (in `token`'s numeraire) against the CONVERSION venue's per-block budget,
    ///      mirroring {_bookVenueSpend}: only for routes that traverse `_usdcPool`, the budget frozen
    ///      on the block's first booking, ETH-denominated — an ETH-numeraire spend books 1:1, a
    ///      USDC-numeraire spend converts to its ETH displacement through the pool price (currency1
    ///      direction, `false`). Called by BOTH conversion entrypoints right where they stamp
    ///      `lastXConvertBlock`, so the swap path and the permissionless path share one budget.
    function _bookConvVenueSpend(Route memory r, uint256 amount, address numeraire) internal {
        if (!_routeUsesUsdcPool(r)) return;
        if (block.number != _venueConvBlock) {
            _venueConvBlock = block.number;
            _venueConvSpent = 0;
            _venueConvCap = _safeBurnChunk(_usdcPool, true); // ETH side (currency0), read before this block's conversions
        }
        _venueConvSpent += numeraire == address(0) ? amount : _valueAcross(_usdcPool, false, amount);
    }

    /// @notice How much of this block's shared CONVERSION venue budget has been spent, in ETH. Zero
    ///         once the block rolls over. Exposed for tests/monitoring, like {venueBurnSpent}.
    function venueConvSpent() external view returns (uint256) {
        return block.number == _venueConvBlock ? _venueConvSpent : 0;
    }

    /// @notice The conversion venue's safe chunk right now, in ETH — this block's budget for forced
    ///         ETH<->USDC conversion volume, shared by every launch. Exposed for tests/monitoring.
    function convVenueChunkView() external view returns (uint256) {
        if (!_usdcPoolSet) return 0;
        return _safeBurnChunk(_usdcPool, true);
    }

    /// @notice Permissionless manual trigger for the buy & burn. Not required — every
    ///         swap already advances it — but available so anyone can push a bucket
    ///         along, and so the flow is testable in isolation.
    /// @dev Returns 0 rather than reverting whenever there is nothing safe to do this
    ///      block, so a bot calling it in a loop is never punished for being early.
    function processBurn(address token) external returns (uint256 bodkinBurned) {
        (Route memory r, uint256 amount) = _burnChunk(token);
        if (amount == 0) return 0;
        if (!_gateBurn(r)) return 0; // displaced venue: wait a block
        lastBurnBlock[token] = block.number;
        _bookVenueSpend(token, amount);
        burnWei[token] -= amount; // remainder stays: the next swap continues the buyback
        bodkinBurned = abi.decode(poolManager.unlock(abi.encode(_ACT_ROUTE, r)), (uint256));
        emit BurnProcessed(token, amount, bodkinBurned);
    }

    /// @dev One party's pending conversion for this block, or `amount == 0` when there is
    ///      nothing safe to do. `noSwap` marks the case where the payout token already IS
    ///      the numeraire: then the whole bucket moves at once, because a 1:1 reclassify
    ///      touches no pool and there is nothing for anyone to sandwich.
    /// @dev `routeDry` is set (creator only) when there is no healthy conversion route this
    ///      swap (cap==0): {convertStep} then hands the bucket over in the numeraire instead
    ///      of stranding it. Decided fresh each swap — no stored state. When `routeDry` is
    ///      set, `amount` is the WHOLE bucket.
    function _convertChunk(address token, bool forCreator)
        internal
        view
        returns (Route memory r, uint256 amount, bool noSwap, address payoutToken, bool routeDry, bool wethConvert)
    {
        uint256 bucket = forCreator ? creatorWei[token] : teamWei[token];
        if (bucket == 0) return (r, 0, false, address(0), false, false);
        uint256 last = forCreator ? lastCreatorConvertBlock[token] : lastTeamConvertBlock[token];
        if (block.number <= last) return (r, 0, false, address(0), false, false);

        address numeraire = numeraireOf(token);
        PayoutConfig memory c;
        if (forCreator) {
            c = _payoutCfg[token];
            payoutToken = c.set ? c.token : usdc;
            if (!c.set) c = _defaultCfg(payoutToken, numeraire);
        } else {
            payoutToken = teamPayoutToken;
            c = _defaultCfg(payoutToken, numeraire);
        }

        if (payoutToken == numeraire) return (r, bucket, true, payoutToken, false, false);

        // Stale numeraire: this launch was quoted in a USDC that a later {migrateUsdc} DEPRECATED, so
        // the canonical ETH<->USDC pool no longer matches it and there is no route OUT of the bucket
        // currency. Routing it through the re-pointed `_usdcPool` would try to spend stale-USDC claims
        // against a (ETH, newUSDC) pool and revert on unnettable deltas — a swallowed stall, strictly
        // worse than a fallback (the healthy new pool means cap>0, so the dry-route rescue below never
        // fires). Instead reclassify into the numeraire, exactly like a dry payout route: the creator
        // keeps the bucket in the still-claimable old numeraire ({creatorOutNum}), and the team banks
        // it per-currency under that same old numeraire (a former usdc, still a registered claimable
        // team currency). If the payout already IS the numeraire we never reach here (noSwap above).
        if (numeraire != address(0) && numeraire != usdc) {
            if (forCreator) return (r, bucket, true, numeraire, true, false);
            // Team falls back only when the old numeraire is a claimable team currency (a former usdc
            // always is, registered at its own migration); otherwise wait rather than strand it.
            if (teamCurrencyKnown[numeraire]) return (r, bucket, true, numeraire, true, false);
            return (r, 0, false, payoutToken, false, false);
        }

        // Custom payout token whose liquidity is a V4 (WETH, token) pool. Converting into it
        // needs a native-ETH -> WETH wrap (real ETH + an external call), so a HEALTHY conversion runs
        // ONLY on the permissionless {processConvert} path (its own unlock, may revert), never riding a
        // stranger's swap — `wethConvert` tells {convertStep} to SKIP so the chosen token is honoured
        // whenever its pool can absorb a chunk. But when that (WETH, token) pool is DRY (uninitialised
        // or no in-range liquidity), we DON'T strand the slice pending indefinitely: we fall back to the
        // numeraire exactly like every other creator route below — a pure storage reclassify (no wrap,
        // no pool, un-sandwichable, can't revert), so it is safe on the swap path too and fires per swap.
        // ETH-numeraire only (enforced at launch), so the ETH bucket sizes 1:1 against the WETH pool's cap.
        if (forCreator && c.wethPaired) {
            // No wrap this launch consented to — WETH disabled (re-pointed to address(0)) or re-pointed
            // to a contract this launch never chose — so the slice takes the same fallback as any dry
            // route. Without the check, a plain (ETH, token) pool at the same tier would read as a
            // healthy "(WETH, token)" leg and the slice would sit pending forever behind a wrap that can
            // only revert.
            if (weth == address(0) || weth != c.wethAt) return (r, bucket, true, payoutToken, true, false);
            r.leg1 = _pairKey(weth, payoutToken, c.fee, c.tickSpacing);
            r.legCount = 1;
            r.wrapToWeth = true;
            r.to = address(this);
            r.toClaims = true;
            r.minOut = 0;
            // Reference-derived execution limit on the (WETH, token) leg too — a MEV bot watching the
            // manual processConvert tx can't sandwich the wrap-and-swap past the band.
            r.limitLoBps = BURN_SWAP_LIMIT_LO_BPS;
            r.limitHiBps = BURN_SWAP_LIMIT_HI_BPS;
            uint256 wcap = _safeBurnChunk(r.leg1, weth == Currency.unwrap(r.leg1.currency0));
            if (wcap == 0) return (r, bucket, true, payoutToken, true, false); // WETH pool dry → numeraire fallback
            amount = bucket < wcap ? bucket : wcap;
            r.amountIn = amount;
            return (r, amount, false, payoutToken, false, true);
        }

        // A viaHub route's first leg crosses the canonical ETH<->USDC pool, which {migrateUsdc} re-points
        // atomically. That migration is for the TEAM route and for future launches; an existing launch
        // keeps the hub it chose, and when that is no longer the live one its slice falls back to the
        // numeraire rather than crossing a pool the creator never picked. (A team conversion builds its
        // config from {_defaultCfg}, where viaHub is false, so the team route still follows the migration.)
        if (c.viaHub && usdc != c.usdcAt) return (r, bucket, true, payoutToken, true, false);
        r = _routeTo(payoutToken, c);
        if (r.legCount == 0) return (r, bucket, true, payoutToken, false, false);
        // Bank the output inside the hook rather than sending it anywhere: this is an
        // accrual, not a payment.
        r.to = address(this);
        r.toClaims = true;
        // Still no `minOut`: a step that can REVERT on price cannot ride along on a
        // stranger's swap. The price protection is the band applied by the callers
        // below, which SKIPS the block instead of reverting — same effect on the
        // attacker, none on the user carrying it.
        r.minOut = 0;
        // Plus the SAME reference-derived EXECUTION LIMIT the buy&burn uses (guard #2), so a custom
        // payout pool with narrow / adversarial liquidity can no longer make a conversion execute several
        // percent past spot: a chunk that would breach the band partial-fills and the step skips (swap
        // path: reverts inside the try/catch; manual path: reverts, retry next block). The gate band is
        // still tighter than this limit, so a healthy conversion always clears.
        r.limitLoBps = BURN_SWAP_LIMIT_LO_BPS;
        r.limitHiBps = BURN_SWAP_LIMIT_HI_BPS;

        // Cap by the WHOLE route, not just its first hop — see {_routeCap}.
        uint256 cap = _routeCap(r);
        if (cap == 0) {
            // No healthy route this swap (pool uninitialised, or no live in-range liquidity).
            // Report it as `routeDry` with the WHOLE bucket; convertStep hands it over in the
            // numeraire — a pure move that trades on no pool, so it is un-sandwichable and can
            // never revert. The team falls back the same way, banked per-currency under the
            // numeraire (ETH and the canonical USDC are registered team currencies), so a payout
            // token with no reachable pool — the default route carries no tier, so ANY custom
            // team token is unroutable — pauses nothing and strands nothing: the slice is simply
            // claimable in the numeraire until governance points at ETH/USDC again.
            if (forCreator) return (r, bucket, true, payoutToken, true, false);
            if (teamCurrencyKnown[numeraire]) return (r, bucket, true, numeraire, true, false);
            return (r, 0, false, payoutToken, false, false);
        }

        // Shared-venue aggregate budget: a route through `_usdcPool` (ETH<->USDC bridge leg) must also
        // fit the venue's ONE safe chunk for this block, across ALL tokens — not just this token's
        // per-block guard — or N tokens' conversions batch into one sandwich on that shared pool.
        // Carry the remaining ETH budget back into the SOURCE currency the same way {_burnChunk} does,
        // then clip. A busy venue makes the chunk WAIT (amount 0, bucket kept), it is NOT a dry route:
        // the fee still converts to the chosen token next block, so no numeraire fallback here.
        if (_routeUsesUsdcPool(r)) {
            uint256 venueCap = block.number == _venueConvBlock ? _venueConvCap : _safeBurnChunk(_usdcPool, true);
            uint256 spent = block.number == _venueConvBlock ? _venueConvSpent : 0;
            if (spent >= venueCap) return (r, 0, false, payoutToken, false, false); // venue budget spent — wait a block
            uint256 leftAtVenue = venueCap - spent;
            // `leftAtVenue` is ETH (currency0 of `_usdcPool`); an ETH numeraire spends it 1:1, a USDC
            // numeraire spends the USDC that displaces it (currency0 direction, `true`) — mirrors {_burnChunk}.
            uint256 leftInSrc = numeraire == address(0) ? leftAtVenue : _valueAcross(_usdcPool, true, leftAtVenue);
            if (leftInSrc == 0) return (r, 0, false, payoutToken, false, false);
            if (cap > leftInSrc) cap = leftInSrc;
        }

        amount = bucket < cap ? bucket : cap;
        r.amountIn = amount;
    }

    /// @dev Advance this route's price references and report whether it may trade.
    ///
    /// Split out of {_convertChunk} because that function is a `view` and the shift
    /// register has to be WRITTEN on every attempt, not only on the ones that succeed.
    /// A reference that moves only on success can never recover once the band has said
    /// no — that version stalled the pipeline permanently under test.
    ///
    /// `noSwap` routes need no gate: nothing is traded, so there is nothing to sandwich.
    /// @dev Advance this burn route's references and report whether it may trade.
    ///
    /// Checks the WHOLE route, not just the BODKIN venue. A USDC-quoted launch burns
    /// USDC -> ETH -> BODKIN, and only the second leg used to be gated: the bridge hop
    /// through `_usdcPool` was exposed to exactly the displacement the band exists to
    /// refuse, on the same shared pool every USDC launch converts through.
    ///
    /// Out of band = skip the block, never revert — the burn must never fail the swap
    /// carrying it.
    function _gateBurn(Route memory r) internal returns (bool) {
        if (r.legCount == 0) return true;
        Band memory b = _burnBand();
        _advanceRouteRefs(r, b);
        return _withinRouteBand(r, b);
    }

    function _gateConvert(Route memory r, bool noSwap) internal returns (bool) {
        if (noSwap) return true;
        Band memory b = _burnBand();
        _advanceRouteRefs(r, b);
        return _withinRouteBand(r, b);
    }

    /// @dev Convert one party's pending fees into their payout token. Self-only and
    ///      revert-isolated, exactly like {burnStep} — see {_tryBurnStep}.
    function convertStep(address token, bool forCreator) external {
        if (msg.sender != address(this)) revert NotManager();
        (Route memory r, uint256 amount, bool noSwap, address pt, bool routeDry, bool wethConvert) =
            _convertChunk(token, forCreator);
        if (amount == 0) return;
        // WETH-paired payout: never wrap+swap while riding a stranger's swap. Leave the slice
        // pending; the permissionless {processConvert} converts it in its own tx.
        if (wethConvert) return;

        // No healthy route for this slice this swap: hand it over in the numeraire instead of
        // stranding it. A pure reclassify (no pool, un-sandwichable, can't revert), decided PER SWAP —
        // the next swap converts to the chosen token again the moment a route is back. `amount` is the
        // whole bucket. Two cases produce `routeDry`: a dry CREATOR payout route (creator-only), and a
        // STALE NUMERAIRE (either party — a deprecated-USDC-numeraire launch, see {_convertChunk}).
        if (routeDry) {
            if (forCreator) {
                lastCreatorConvertBlock[token] = block.number;
                creatorWei[token] -= amount;
                creatorOutNum[token] += amount;
                emit CreatorFellBackToNumeraire(token, numeraireOf(token), amount);
            } else {
                lastTeamConvertBlock[token] = block.number;
                teamWei[token] -= amount;
                teamOut[token][numeraireOf(token)] += amount; // numeraire is a registered team currency
                emit TeamFellBackToNumeraire(token, numeraireOf(token), amount);
            }
            return;
        }

        if (!_gateConvert(r, noSwap)) return; // displaced venue: wait a block

        if (forCreator) {
            lastCreatorConvertBlock[token] = block.number;
            creatorWei[token] -= amount;
        } else {
            lastTeamConvertBlock[token] = block.number;
            teamWei[token] -= amount;
        }

        _bookConvVenueSpend(r, amount, numeraireOf(token)); // charge the shared _usdcPool budget (no-op off it)

        // Already the right currency: reclassify the claims we hold, no pool involved.
        uint256 banked = noSwap ? amount : _runRoute(r);
        // Bank keyed by the ACTUAL currency of the claims just minted (`pt`, == teamPayoutToken for
        // the team), so a later USDC re-point never re-denominates it. `pt` is always a registered
        // team currency: it equals teamPayoutToken, which the governance write points (constructor,
        // setTeamPayoutToken, migrateUsdc) register BEFORE it can be selected — so {claimTeam}'s
        // iteration always covers it.
        if (forCreator) creatorOut[token] += banked;
        else teamOut[token][pt] += banked;
        emit FeesConverted(token, forCreator, pt, amount, banked);
    }

    /// @dev Advance both conversions, each isolated from the other. Separate try blocks
    ///      on purpose: one launch's broken payout pool must not be able to stall the
    ///      team's slice, or vice versa.
    function _tryConvertSteps(address token) internal {
        try this.convertStep(token, true) {} catch {}
        try this.convertStep(token, false) {} catch {}
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // Autocompound — the 10% slice, folded back into the coin's OWN migrated pool, on the coin's OWN
    // swaps. No keeper: it rides every swap best-effort, exactly like the buy & burn, and is chunked
    // + banded so the forced buy is never a profitable sandwich. See {compoundStep}/{_doCompound}.
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev The autocompound analogue of {_tryBurnStep}: revert-isolated so it can never cost the swap it
    ///      rides on. Runs INSIDE the user's unlock (like {burnStep}), so it drives the pool directly —
    ///      v4-core skips THIS hook's own before/after callbacks for a self-initiated swap or
    ///      modifyLiquidity, so there is no recursion and no fee-on-fee.
    function _tryCompoundStep(address token) internal {
        try this.compoundStep(token) {} catch {}
    }

    /// @dev Swap-path entrypoint (self-only, wrapped in try/catch by {_tryCompoundStep}). Runs within the
    ///      swap's existing unlock, so it calls the pool directly rather than opening a second one.
    function compoundStep(address token) external {
        if (msg.sender != address(this)) revert NotManager();
        _doCompound(_launchPoolKey(token), token);
    }

    /// @notice Permissionless manual trigger for one coin's autocompound. Never required — every swap on
    ///         the coin already advances it — but available so anyone can push a bucket along, and so the
    ///         flow is testable in isolation and recoverable if the swap-path is ever griefed. Returns 0
    ///         when there is nothing safe to do this block. Opens its own unlock (an outside caller has
    ///         not established one), mirroring {processBurn}.
    function processCompound(address token) external returns (uint128 liquidityAdded) {
        PoolKey memory key = _launchPoolKey(token);
        liquidityAdded = abi.decode(poolManager.unlock(abi.encode(_ACT_COMPOUND, key, token)), (uint128));
    }

    /// @dev The coin's own launch pool key, rebuilt from immutable launch config: numeraire = currency0
    ///      (the launcher guarantees token > numeraire), 0 LP fee, {TICK_SPACING}, this hook. The same
    ///      key a swap on the coin carries, so both compound paths act on exactly one pool.
    function _launchPoolKey(address token) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(numeraireOf(token)),
            currency1: Currency.wrap(token),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(this))
        });
    }

    /// @dev This block's autocompound chunk for `token`, or 0 when there is nothing safe/worthwhile.
    ///      Pure decision (no writes, no swap) so the swap-path and the manual path agree exactly —
    ///      mirrors {_burnChunk}. Only a MIGRATED coin has the full-range position to deepen. Bounded
    ///      ABOVE so the HALF that gets swapped stays within {_safeBurnChunk} on the coin's OWN pool
    ///      (un-sandwichable at profit); no lower bound — every non-zero bucket is worth folding in.
    function _compoundChunk(PoolKey memory key, address token) internal view returns (uint256 amount) {
        (, , , bool migrated) = ILauncherHookView(launcher).curvePositions(token);
        if (!migrated) return 0; // pre-migration: no full-range position yet
        uint256 bucket = autocompoundWei[token];
        if (bucket == 0) return 0;
        if (block.number <= lastCompoundBlock[token]) return 0;
        // Only HALF of `amount` is swapped (numeraire -> token) — that is the sandwichable action — so the
        // cap on `amount` is twice the safe swap size on this pool. numeraire is currency0.
        uint256 safe = _safeBurnChunk(key, true);
        if (safe == 0) return 0;
        uint256 cap = safe * 2;
        amount = bucket < cap ? bucket : cap;
    }

    /// @dev Held amount after the add's delta: `d < 0` means the add SPENT `-d` of this side; `d > 0`
    ///      means it CREDITED `d`. Saturating on the spend side so a 1-wei add rounding can never
    ///      underflow (and revert the swap this rides on).
    function _applyDelta(uint256 held, int128 d) internal pure returns (uint256) {
        if (d < 0) {
            uint256 s = uint256(uint128(-d));
            return held > s ? held - s : 0;
        }
        return held + uint256(uint128(d));
    }

    /// @dev Execute one autocompound chunk on `key` (numeraire = currency0, token = currency1). Every
    ///      caller must already hold the unlock. Swaps HALF the chunk to the token, then adds BOTH to the
    ///      coin's OWN [MIN_USABLE, MAX_USABLE] salt-0 position — the same one migration seeded, so it
    ///      just deepens in place. Settles BOTH signs of BOTH currencies with claims, so the deltas ALWAYS
    ///      net to zero (never leaving a stray delta that would revert the user's swap at unlock close),
    ///      regardless of any accrued fees. Leftover numeraire returns to the bucket, leftover token is
    ///      carried to the next compound — nothing is stranded.
    function _doCompound(PoolKey memory key, address token) internal returns (uint128 liq) {
        uint256 amount = _compoundChunk(key, token);
        if (amount == 0) return 0;
        // GATE band on the numeraire-spend direction (buying the token moves its price the way a
        // front-run would): refuse — and wait a block — if the pool was displaced past the COMPOUND band,
        // like the buy & burn but on its own per-venue width. SKIPS, never reverts on the swap it rides on.
        Band memory cb = _compoundBand();
        _advanceRef(key, cb);
        if (!_withinBand(key, true, cb)) return 0;

        lastCompoundBlock[token] = block.number;
        autocompoundWei[token] -= amount; // remainder stays; the next block continues (keep-and-retry)

        uint256 have0 = amount;
        uint256 have1 = compoundTokenDust[token]; // fold in token dust carried from earlier compounds
        compoundTokenDust[token] = 0;
        uint256 half = amount / 2;
        if (half > 0) {
            // EXECUTION limit (guard #2): {_swapLeg} derives a reference-based sqrtPriceLimit from the
            // COMPOUND limit band, so this half-swap can't fill more than that far from the trusted price —
            // a displaced/thin pool partial-fills, {_swapLeg} reverts, and the try/catch turns it into a skip.
            (Currency outCur, uint256 got) =
                _swapLeg(key, key.currency0, half, COMPOUND_SWAP_LIMIT_LO_BPS, COMPOUND_SWAP_LIMIT_HI_BPS);
            key.currency0.settle(poolManager, address(this), half, true); // burn numeraire claims
            have0 = amount - half;
            have1 += got;
            outCur.take(poolManager, address(this), got, true); // take token as claims
        }

        (uint160 sqrtP,,,) = poolManager.getSlot0(key.toId());
        liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtPriceAtTick(MIN_USABLE), TickMath.getSqrtPriceAtTick(MAX_USABLE), have0, have1
        );
        if (liq > 0) {
            (BalanceDelta md,) = poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: MIN_USABLE,
                    tickUpper: MAX_USABLE,
                    liquidityDelta: int256(uint256(liq)),
                    salt: 0
                }),
                ""
            );
            // Settle BOTH signs: a negative delta is owed to the pool (pay with claims), a positive one is
            // a credit (take as claims). A fee:0 pool only ever owes, but closing both signs makes the
            // zero-delta invariant hold BY CONSTRUCTION, not by assumption (LENS 1/2).
            int128 a0 = md.amount0();
            if (a0 < 0) key.currency0.settle(poolManager, address(this), uint256(uint128(-a0)), true);
            else if (a0 > 0) key.currency0.take(poolManager, address(this), uint256(uint128(a0)), true);
            int128 a1 = md.amount1();
            if (a1 < 0) key.currency1.settle(poolManager, address(this), uint256(uint128(-a1)), true);
            else if (a1 > 0) key.currency1.take(poolManager, address(this), uint256(uint128(a1)), true);
            have0 = _applyDelta(have0, a0);
            have1 = _applyDelta(have1, a1);
        }
        // Nothing stranded: unspent numeraire back to the coin's bucket, unspent token to the next compound.
        if (have0 > 0) autocompoundWei[token] += have0;
        compoundTokenDust[token] = have1;
        emit Compounded(token, amount, liq);
    }

    /// @notice Permissionless manual conversion of one party's pending fees.
    /// @dev The EXTERNAL counterpart of {convertStep}: opens its own unlock, because a caller
    ///      from outside has not established one. Returns 0 rather than reverting when
    ///      there is nothing to do this block.
    function processConvert(address token, bool forCreator) external returns (uint256 banked) {
        (Route memory r, uint256 amount, bool noSwap, address pt, bool routeDry, bool wethConvert) =
            _convertChunk(token, forCreator);
        if (amount == 0) return 0;

        // WETH-paired payout: gate the (WETH, token) pool on the WETH input side (the route src
        // is ETH, so the generic route gate would read the wrong direction), then run the shared
        // unlock — {_runRoute}'s wrapToWeth branch does the wrap+swap. Own tx: may revert safely.
        if (wethConvert) {
            bool wethIsZero = weth == Currency.unwrap(r.leg1.currency0);
            Band memory wb = _burnBand();
            _advanceRef(r.leg1, wb);
            if (!_withinBand(r.leg1, wethIsZero, wb)) return 0; // displaced WETH pool: wait a block
            lastCreatorConvertBlock[token] = block.number;
            creatorWei[token] -= amount;
            banked = abi.decode(poolManager.unlock(abi.encode(_ACT_ROUTE, r)), (uint256));
            creatorOut[token] += banked;
            emit FeesConverted(token, true, pt, amount, banked);
            return banked;
        }

        // Same per-swap fallback as convertStep: no healthy route → hand the slice over in the
        // numeraire instead of stranding it. Creator dry-route OR stale numeraire (either party).
        if (routeDry) {
            if (forCreator) {
                lastCreatorConvertBlock[token] = block.number;
                creatorWei[token] -= amount;
                creatorOutNum[token] += amount;
                emit CreatorFellBackToNumeraire(token, numeraireOf(token), amount);
            } else {
                lastTeamConvertBlock[token] = block.number;
                teamWei[token] -= amount;
                teamOut[token][numeraireOf(token)] += amount; // numeraire is a registered team currency
                emit TeamFellBackToNumeraire(token, numeraireOf(token), amount);
            }
            // The fallback banks numeraire, not the payout token, so this reports 0 (the numeraire
            // amount is in the event and readable via creatorOutNum / teamOut[token][numeraire]).
            return 0;
        }

        if (!_gateConvert(r, noSwap)) return 0; // displaced venue: wait a block
        if (forCreator) {
            lastCreatorConvertBlock[token] = block.number;
            creatorWei[token] -= amount;
        } else {
            lastTeamConvertBlock[token] = block.number;
            teamWei[token] -= amount;
        }
        _bookConvVenueSpend(r, amount, numeraireOf(token)); // charge the shared _usdcPool budget (no-op off it)
        banked = noSwap ? amount : abi.decode(poolManager.unlock(abi.encode(_ACT_ROUTE, r)), (uint256));
        // Bank keyed by the actual banked currency `pt` (== teamPayoutToken for the team), always a
        // registered team currency — see the matching note in {convertStep}.
        if (forCreator) creatorOut[token] += banked;
        else teamOut[token][pt] += banked;
        emit FeesConverted(token, forCreator, pt, amount, banked);
    }

    /// @notice Permissionless manual trigger for the whole fee pipeline of one token —
    ///         burn, creator conversion, team conversion. Not required (every swap
    ///         advances all three); available so a quiet token can still be pushed along.
    /// @dev Each leg is a separate external call with its own unlock AND its own
    ///      try/catch, so one broken pool cannot stall the other two.
    function processFees(address token) external {
        try this.processBurn(token) returns (uint256) {} catch {}
        try this.processConvert(token, true) returns (uint256) {} catch {}
        try this.processConvert(token, false) returns (uint256) {} catch {}
    }

    /// @dev The swap-path entrypoint. `external` ONLY so `_afterSwap` can call it
    ///      through `this` and wrap it in try/catch — that boundary is the entire
    ///      point, because a revert inside an external call is caught, while a revert
    ///      inside an internal one would take the user's swap down with it.
    ///
    ///      Callable by nobody else. It does pool operations directly instead of going
    ///      through `poolManager.unlock`, because it runs INSIDE the swap's existing
    ///      unlock — asking for a second one would revert with AlreadyUnlocked.
    function burnStep(address token) external {
        if (msg.sender != address(this)) revert NotManager();
        (Route memory r, uint256 amount) = _burnChunk(token);
        if (amount == 0) return;
        if (!_gateBurn(r)) return; // displaced venue: wait a block
        lastBurnBlock[token] = block.number;
        _bookVenueSpend(token, amount);
        burnWei[token] -= amount;
        emit BurnProcessed(token, amount, _runRoute(r));
    }

    /// @dev A conversion route: spend `amountIn` of `src` (held as ERC-6909 claims)
    ///      through 0, 1 or 2 pools and deliver the result to `to`. Every key is built
    ///      inside this contract from the immutable launch config — never taken from
    ///      calldata — and the custom legs are always plain pools (hooks = 0).
    /// NOTE on `minOut`: every route this contract builds today sets it to 0 on
    /// purpose — the burn and conversion steps are protected by their SIZE (a cap no
    /// caller can influence), not by a floor, and a floor on a permissionless call
    /// would only give an attacker a way to make the step revert. The field and the
    /// `Slippage()` guards in `_runRoute` are kept anyway: they are the safety rail
    /// for any future route that IS caller-influenced, and three comparisons are a
    /// cheap price for not having to remember this invariant.
    struct Route {
        Currency src;
        uint256 amountIn;
        address to;
        uint256 minOut;
        PoolKey leg1;
        PoolKey leg2;
        uint8 legCount;
        /// Keep the output as ERC-6909 claims held by this hook instead of transferring
        /// real tokens to `to`. What lets a conversion ACCRUE inside the hook — the fee
        /// is banked in the payout currency and paid out later with no swap involved.
        bool toClaims;
        /// Set ONLY by {_convertChunk} for a WETH-paired creator payout: {_runRoute} wraps
        /// native ETH -> WETH before leg1 (a V4 (WETH, token) pool). Never set on a swap-time
        /// route — the wrap is an external call that must not ride a stranger's swap.
        bool wrapToWeth;
        /// EXECUTION-limit band (sqrt-space bps) for each leg's swap, applied via {_swapLimit} in
        /// {_runRoute}. Both the BUY & BURN and the fee CONVERSIONS set these ({BURN_SWAP_LIMIT_LO/HI_BPS})
        /// so a displaced/thin venue — including a custom payout pool with adversarial liquidity — can't
        /// fill past the reference: a chunk that would breach the band partial-fills and the step skips.
        /// (`noSwap` / routeDry moves that trade on no pool leave them 0 = unlimited; nothing to bound.)
        uint256 limitLoBps;
        uint256 limitHiBps;
    }

    /// @dev The hops from a launch's numeraire to `payoutToken`, with `amountIn`, `to`,
    ///      `minOut` and `toClaims` left for the caller to fill in.
    ///
    /// Kept separate from its callers so the CONVERSION steps below and the claim path derive the
    /// route from exactly the same code. Two places computing "which pools reach the
    /// payout token" would be two places to get it wrong, and they would disagree
    /// silently — the accrual would bank one currency while the claim redeemed another.
    function _routeTo(address payoutToken, PayoutConfig memory c) internal view returns (Route memory r) {
        address src = c.numeraire;
        r.src = Currency.wrap(src);

        if (payoutToken == src) {
            // Already in the right currency — nothing to swap.
            r.legCount = 0;
        } else if (payoutToken == address(0) || payoutToken == usdc) {
            // ETH <-> USDC, either direction, through the one canonical pool.
            if (!_usdcPoolSet) revert UsdcPoolUnset();
            r.leg1 = _usdcPool;
            r.legCount = 1;
        } else {
            // Custom token: pair it with the numeraire, or bridge via the other
            // canonical currency first when that's where its liquidity is.
            address partner = _customPartner(src, c.viaHub);
            if (partner == src) {
                r.leg1 = _pairKey(src, payoutToken, c.fee, c.tickSpacing);
                r.legCount = 1;
            } else {
                if (!_usdcPoolSet) revert UsdcPoolUnset();
                r.leg1 = _usdcPool; // src -> partner (ETH<->USDC)
                r.leg2 = _pairKey(partner, payoutToken, c.fee, c.tickSpacing);
                r.legCount = 2;
            }
        }
    }

    /// @dev Which currency a custom payout token is paired with: the launch's own
    ///      numeraire, or — when `viaHub` — the other canonical currency (so an
    ///      ETH-numeraire launch can pay a USDC-paired token, and vice versa).
    function _customPartner(address numeraire, bool viaHub) internal view returns (address) {
        if (!viaHub) return numeraire;
        return numeraire == address(0) ? usdc : address(0);
    }

    /// @dev A plain (hook-less) pool key for `a`/`b`, currencies sorted as V4 requires.
    function _pairKey(address a, address b, uint24 fee, int24 tickSpacing) internal pure returns (PoolKey memory) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });
    }

    /// PoolManager unlock callback. Executes a {Route}: 0 legs = redeem the source
    /// claims as-is; 1 leg = one swap; 2 legs = bridge through an intermediate that
    /// nets to exactly zero inside this unlock. Direction is DERIVED from each key's
    /// sort order, never assumed — that's what lets the same code serve an ETH
    /// numeraire and a USDC one.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotManager();
        // Peek the leading tag, then decode the rest per action (both payloads begin with the uint8).
        uint8 action = abi.decode(data[0:32], (uint8));
        if (action == _ACT_COMPOUND) {
            (, PoolKey memory key, address token) = abi.decode(data, (uint8, PoolKey, address));
            return abi.encode(_doCompound(key, token));
        }
        (, Route memory r) = abi.decode(data, (uint8, Route));
        return abi.encode(_runRoute(r));
    }

    /// @dev The route body, split out of `unlockCallback` so it can also be driven from
    ///      code that is ALREADY inside an unlock — namely `burnStep`, which runs within
    ///      the user's own swap and therefore cannot open a second one.
    ///
    ///      Every caller must have established the unlock; this does no authorisation of
    ///      its own and is `internal` for exactly that reason.
    function _runRoute(Route memory r) internal returns (uint256) {
        if (r.wrapToWeth) {
            // ETH-numeraire creator payout into a V4 (WETH, token) pool. Turn our native-ETH
            // claims into real WETH, then swap WETH -> payout. Only ever reached from
            // processConvert's OWN unlock (see {_convertChunk}); the deposit is an external
            // call and must never ride a stranger's swap. Deltas net to zero: ETH (take real,
            // settle claims), WETH (swap spends it, we settle it in), payout (swap credits it,
            // we take it out).
            r.src.take(poolManager, address(this), r.amountIn, false); // native ETH to us (debt)
            r.src.settle(poolManager, address(this), r.amountIn, true); // burn ETH claims (credit) -> net 0
            IWETH(weth).deposit{value: r.amountIn}(); // ETH -> WETH, now held by this hook
            (Currency payoutCur, uint256 gotWeth) =
                _swapLeg(r.leg1, Currency.wrap(weth), r.amountIn, r.limitLoBps, r.limitHiBps);
            Currency.wrap(weth).settle(poolManager, address(this), r.amountIn, false); // pay WETH from balance
            if (gotWeth < r.minOut) revert Slippage();
            payoutCur.take(poolManager, r.to, gotWeth, r.toClaims);
            return gotWeth;
        }
        if (r.legCount == 0) {
            // Already the payout currency — hand it over 1:1 by burning our claims.
            // The floor is only a sanity guard here (no swap, no slippage).
            if (r.amountIn < r.minOut) revert Slippage();
            r.src.take(poolManager, r.to, r.amountIn, false);
            r.src.settle(poolManager, address(this), r.amountIn, true);
            return r.amountIn;
        }

        // Leg 1 — spend the source. Its debt is settled by burning our claims; the
        // output stays a manager credit, either taken now or spent on leg 2.
        (Currency mid, uint256 got1) = _swapLeg(r.leg1, r.src, r.amountIn, r.limitLoBps, r.limitHiBps);
        r.src.settle(poolManager, address(this), r.amountIn, true);

        if (r.legCount == 1) {
            if (got1 < r.minOut) revert Slippage();
            mid.take(poolManager, r.to, got1, r.toClaims);
            return got1;
        }

        // Leg 2 — spend ALL of leg 1's credit. No settle/take for the intermediate:
        // the +got1 credit and the -got1 debt cancel, so only the payout leaves.
        (Currency outCur, uint256 got2) = _swapLeg(r.leg2, mid, got1, r.limitLoBps, r.limitHiBps);
        if (got2 < r.minOut) revert Slippage();
        outCur.take(poolManager, r.to, got2, r.toClaims);
        return got2;
    }

    /// @dev One exact-input hop of `amountIn` of `currencyIn` through `k`. Derives the direction from
    ///      which side `currencyIn` sorts on, and the hard `sqrtPriceLimitX96` from `(loBps, hiBps)` via
    ///      {_swapLimit} (0 = unlimited). Reverts unless the pool absorbs the WHOLE input — a partial fill
    ///      (whether from thin liquidity or from hitting the reference-derived limit) would strand the
    ///      already-zeroed bucket, so the caller's try/catch turns it into a wait-a-block skip. Neither
    ///      settles nor takes: the caller decides how each side is resolved.
    function _swapLeg(PoolKey memory k, Currency currencyIn, uint256 amountIn, uint256 loBps, uint256 hiBps)
        internal
        returns (Currency currencyOut, uint256 amountOut)
    {
        bool inIsZero = Currency.unwrap(currencyIn) == Currency.unwrap(k.currency0);
        BalanceDelta d = poolManager.swap(
            k,
            SwapParams({
                zeroForOne: inIsZero,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: _swapLimit(k, inIsZero, loBps, hiBps)
            }),
            ""
        );
        // What we pay is negative; what we receive is positive.
        uint256 spent = inIsZero ? uint256(uint128(-d.amount0())) : uint256(uint128(-d.amount1()));
        amountOut = inIsZero ? uint256(uint128(d.amount1())) : uint256(uint128(d.amount0()));
        if (spent != amountIn) revert PartialFill();
        currencyOut = inIsZero ? k.currency1 : k.currency0;
    }

    /// Kept for completeness (the hook holds ERC-6909 claims, not native ETH).
    receive() external payable {}
}
