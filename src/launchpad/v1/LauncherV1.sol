// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {BodkinERC20} from "../BodkinERC20.sol";
import {CreatorNFT} from "../CreatorNFT.sol";
import {CanonicalTiers} from "./CanonicalTiers.sol";

/// @dev The fee hook's launch-time config setter (one-time, launcher-only) + the
///      canonical USDC address it converts through.
interface IFeeHookPayout {
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
    ) external;
    function usdc() external view returns (address);
    function weth() external view returns (address);
    function isNumeraire(address currency) external view returns (bool);
    /// Re-point the hook's team wallet — launcher-only; called from the 2-of-2 governance
    /// so the team's swap-fee slice follows the same wallet the create fee does.
    function setTeam(address newTeam) external;
    /// Re-point the hook's team PAYOUT token (ETH or an allowed token) — launcher-only, from the
    /// same 2-of-2 governance; the hook refuses unless all converted team fees are already claimed.
    function setTeamPayoutToken(address newToken) external;
    /// Re-point a fee-infrastructure address (1 = weth) — launcher-only, from the same 2-of-2
    /// governance. The emergency escape hatch for a deprecated WETH. (USDC uses {migrateUsdc}.)
    function setFeeToken(uint8 which, address newAddr) external;
    /// Atomically migrate the platform USDC (address + (ETH,usdc) pool + team payout token) —
    /// launcher-only, from the 2-of-2. USDC's dedicated path because it is load-bearing in more
    /// places than a bare fee address; see {FeeHook.migrateUsdc}.
    function migrateUsdc(address newUsdc, PoolKey calldata newPool) external;
    /// Add a further Uniswap PositionManager whose positions can claim LP rewards — launcher-only,
    /// from the 2-of-2. Add-only; see {FeeHook.addPositionManager}.
    function addPositionManager(address pm) external;
}

/// @title LauncherV1
/// @notice Single-sided launchpad on Uniswap V4 (single DEX — no multi-DEX/SushiSwap).
///         A launch: deploys a plain ERC-20, opens a (numeraire, token) V4 pool wired
///         to the FeeHook (which takes the 1% fee on the numeraire side), seeds 100% of
///         supply as a single-sided token-only position in a range BELOW spot (buyers
///         bring the numeraire), and permanently locks it — the position is owned by
///         this launcher, which has NO code path to remove liquidity, so it can never
///         be pulled. The creator gets a transferable CreatorNFT (the fee stream).
///
///         The numeraire is chosen per launch: native ETH (default) or USDC. THE
///         LOAD-BEARING INVARIANT is `token > numeraire`, so the numeraire is always
///         `currency0` — that keeps one set of range/direction/fee math correct for
///         both. ETH (address 0) satisfies it for free; a USDC launch satisfies it via
///         the mined CREATE2 salt, and is rejected outright if it doesn't.
contract LauncherV1 is ReentrancyGuard, IUnlockCallback, EIP712 {
    using SafeERC20 for IERC20;
    using CurrencySettler for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IPoolManager public immutable poolManager;
    IHooks public immutable feeHook;
    CreatorNFT public immutable creatorNFT;
    address public immutable launchTokenImpl;

    int24 public constant TICK_SPACING = 60;
    /// @notice Starting FDV per numeraire, in that numeraire's RAW units (wei for ETH,
    ///         micro-USDC for USDC). Set once in the constructor — this launcher has no
    ///         owner and no pricing setter, so launch pricing can never be changed under
    ///         creators (the sole mutable parameter is the team wallet, and only via the
    ///         2-of-2 {updateTeamWallet}). Deliberately NOT derived from a live oracle: that would make
    ///         launch pricing manipulable through the very pool the hook swaps in.
    mapping(address => uint256) public startFdvOf;
    mapping(address => uint256) public migrationTargetOf;

    struct CurvePosition {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        bool migrated;
    }
    mapping(address => CurvePosition) public curvePositions;
    /// @notice The single-sided token wall a graduated coin KEEPS after migration: the part of
    ///         MIGRATION_SUPPLY the full-range position could not absorb (it is numeraire-limited),
    ///         re-minted over [minUsable, tickUpper] just below the graduation price. Zero liquidity
    ///         = not migrated yet, or nothing was left over.
    struct WallPosition {
        int24 tickUpper;
        uint128 liquidity;
        uint256 tokens;
    }
    mapping(address => WallPosition) public wallPositions;
    /// @notice One rung: a single-sided token position over [tickLower, tickUpper] holding `tokens`.
    ///         A rung with tickLower == minUsable is open-ended (sells all the way up).
    struct RungPosition {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 tokens;
    }
    mapping(address => RungPosition[2]) internal _rungs;
    /// @dev Everything the launch-time unlock callback mints, in one struct (keeps `launch` off the
    ///      stack limit and the payload self-describing).
    struct SeedParams {
        int24 tickLower;
        int24 tickUpper;
        uint128 liqCurve;
        int24 minUsable;
        uint128 liqWall;
        int24[2] rungLower;
        int24[2] rungUpper;
        uint128[2] rungLiqs;
    }
    /// @dev Guards `_initialSqrtPriceX96`'s integer sqrt from losing precision on a
    ///      small raw FDV (more of a risk on a 6-decimal numeraire).
    uint256 internal constant MIN_START_FDV_RAW = 1e8;
    /// @notice Every token launches with EXACTLY this supply — one billion, minted in full
    ///         at creation and never again. It is a protocol constant, not a per-launch
    ///         choice, so every Bodkin token has an identical, predictable float.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    /// @dev 400M / 600M split. CURVE_SUPPLY is the slice sold cheaply on the concentrated curve
    ///      [startFdv, migrationTarget]; the rest sits from launch as a single-sided token WALL above
    ///      the migration price (the pools.trade shape). At graduation the wall is only partially
    ///      consumed: the numeraire the curve collected is paired with just enough wall tokens for ONE
    ///      full-range two-sided position, and the REMAINDER of the wall is re-minted single-sided above
    ///      the graduation price — nothing strands, and the wall keeps converting into numeraire as the
    ///      price climbs. Depth at high market caps is set by how many tokens are sold expensively (the
    ///      wall), so a SMALLER curve slice = a DEEPER pool later. With the deploy's 1 ETH start and
    ///      12 ETH graduation (~$2.5k → ~$30k), this split plus the two rungs targets ~2.6 ETH in the pool
    ///      at $50k, ~300 ETH at $7M, ~2,700 ETH at $500M and ~4,800 ETH at $1.5B FDV (the start moves
    ///      the opening price, not the depth).
    uint256 public constant CURVE_SUPPLY = 400_000_000e18;
    /// @notice Everything not on the curve: the base wall plus the two rungs below.
    uint256 public constant MIGRATION_SUPPLY = TOTAL_SUPPLY - CURVE_SUPPLY;
    /// @notice The two RUNGS: extra single-sided token positions that only come into range far above the
    ///         graduation price, at RUNG_*_X times the migration-target FDV. Tokens parked there sell only
    ///         at those prices, so at a high market cap the pool holds several times the numeraire a single
    ///         flat wall would; nothing is added or moved when the price crosses one — the positions exist
    ///         from the launch block, out of range. Minted at launch, never touched by migration.
    ///         Rung A is BOUNDED: [50x, 250x] the cap (~$1.5M–$7.5M at the ~$30k cap) — it sells out by
    ///         250x, which is what puts ~300 ETH in the pool at a $7M FDV without dragging the top end up.
    ///         Rung B is open-ended from 500x (~$15M): it sets the depth at $1B+ (~4,800 ETH at $1.5B).
    uint256 public constant RUNG_COUNT = 2;
    uint256 public constant RUNG_A_SUPPLY = 189_000_000e18;
    uint256 public constant RUNG_A_LO_X = 50;
    uint256 public constant RUNG_A_HI_X = 250;
    uint256 public constant RUNG_B_SUPPLY = 67_000_000e18;
    uint256 public constant RUNG_B_LO_X = 500;
    uint256 public constant RUNG_B_HI_X = 0; // 0 = open-ended (up to the usable maximum price)
    /// @notice The base wall minted right above the curve at launch (MIGRATION_SUPPLY less the rungs).
    ///         At migration the full-range position absorbs part of it and the rest is re-minted.
    uint256 public constant WALL_SUPPLY = MIGRATION_SUPPLY - RUNG_A_SUPPLY - RUNG_B_SUPPLY; // 344M
    uint256 public constant launchFeeWei = 0.0005 ether;
    /// @notice Cap on the optional custom creator fee: 5% (500 bps), charged ON TOP of the 1% platform
    ///         fee. Mirrors {FeeHook.MAX_CREATOR_FEE_BPS}; validated here at launch for an early revert.
    uint16 public constant MAX_CREATOR_FEE_BPS = 500;
    /// @notice Cap on the optional custom LP fee: 5% (500 bps), ON TOP of the 1% platform fee, to
    ///         external LPs. Mirrors {FeeHook.MAX_LP_FEE_BPS}; validated here at launch for an early revert.
    uint16 public constant MAX_LP_FEE_BPS = 500;
    /// @notice The on-chain metadata URI is ALWAYS an IPFS pointer the launchpad pinned
    ///         (`ipfs://<cid>/<file>`). The `ipfs://` scheme is fixed; the length is NOT (the CID and
    ///         filename vary), so we bound a RANGE, not an exact size. MIN clears "ipfs://" plus a CID
    ///         (a v0 CID alone is 46 bytes, so a real URI is ≥ 53); MAX bounds token storage + gas.
    uint256 internal constant MIN_METADATA_URI_BYTES = 46;
    uint256 internal constant MAX_METADATA_URI_BYTES = 256;
    /// @notice The team wallet: the hook's 20% swap-fee slice follows it (kept in lockstep via
    ///         {updateTeamWallet}), it is the CURRENT-TEAM signer of every 2-of-2 here, and it is the
    ///         only wallet that may call {withdraw} to take the create fees a launch books. Re-pointable
    ///         ONLY through {updateTeamWallet}'s 2-of-2 governance; it is never a unilateral admin.
    ///         Everything that follows it reads it from storage, so a rotation moves all of it at once.
    address public launchFeeRecipient;
    /// @notice The migration bot's wallet — the account that pays gas for {migrate} calls. It used to
    ///         receive the flat create fee of every launch, which is how it stayed funded; that fee is
    ///         now booked for the team instead ({createFeesOwed}, {withdraw}), because sending it
    ///         DURING a launch handed this hot key's code a turn in the middle of someone else's
    ///         transaction. So the bot is topped up like any other bot now. Re-pointable by the same
    ///         2-of-2 ({updateResolverWallet}); it is still a hot key, so keep its balance low.
    address public resolverWallet;
    uint256 public resolverWalletNonce;
    /// @notice Create fees collected by launches and not yet withdrawn, in wei. `launch()` ACCRUES the
    ///         fee here instead of sending it anywhere, and {withdraw} — callable only by the team
    ///         wallet — takes it out. Accruing rather than sending is a security property, not
    ///         bookkeeping: sending ETH runs the recipient's code, and doing that inside `launch()`
    ///         handed outside code a turn in the middle of someone's launch, with a freshly seeded pool
    ///         in front of it. Now nothing outside our own contracts runs there at all.
    uint256 public createFeesOwed;
    /// @notice The deployer: the second signer of every 2-of-2 here, next to the team wallet. Only
    ///         ever a co-signer — it can neither take a fee nor change anything on its own. Re-pointable
    ///         by the same 2-of-2 ({updateDeployer}), so a compromised or lost deployer key can be
    ///         rotated out while the team key is still intact — and vice versa via {updateTeamWallet}.
    ///         Lose BOTH and governance is frozen for good (deliberate: no unilateral escape hatch).
    address public deployer;
    /// @notice The independent single-use counter for {updateDeployer}.
    uint256 public deployerNonce;
    /// @notice The independent single-use counter for {updateEthConfig}.
    uint256 public ethConfigNonce;
    /// @notice Bumped on every applied change, so each pair of signatures authorises
    ///         exactly one {updateTeamWallet} and can never be replayed.
    uint256 public teamWalletNonce;
    /// @notice The independent single-use counter for {updateTeamPayoutToken}, so a wallet-move
    ///         signature can never authorise a payout-token change or vice versa.
    uint256 public teamPayoutTokenNonce;
    /// @notice The independent single-use counter for {updateFeeToken} (fee-infra address re-point),
    ///         so its signatures can never be replayed against another governance action or reused.
    uint256 public feeTokenNonce;
    /// @notice The independent single-use counter for {updateUsdc} (the atomic USDC migration), so its
    ///         signatures can never be replayed against another governance action or reused.
    uint256 public usdcNonce;
    /// @notice The independent single-use counter for {addPositionManager}.
    uint256 public positionManagerNonce;

    /// EIP-712 struct hash for the payload BOTH signers sign off-chain, independently.
    bytes32 private constant _UPDATE_TEAM_TYPEHASH = keccak256("UpdateTeamWallet(address newWallet,uint256 nonce)");
    bytes32 private constant _UPDATE_RESOLVER_WALLET_TYPEHASH = keccak256("UpdateResolverWallet(address newWallet,uint256 nonce)");
    /// EIP-712 struct hash for the team payout-token change (same 2-of-2 signers, separate nonce).
    bytes32 private constant _UPDATE_TEAM_PAYOUT_TYPEHASH =
        keccak256("UpdateTeamPayoutToken(address newToken,uint256 nonce)");
    /// EIP-712 struct hash for the fee-infra address re-point (same 2-of-2 signers, separate nonce).
    bytes32 private constant _UPDATE_FEE_TOKEN_TYPEHASH =
        keccak256("UpdateFeeToken(uint8 which,address newAddr,uint256 nonce)");
    /// EIP-712 struct hash for the atomic USDC re-point in the fee hook. The (ETH,usdc) pool is signed
    /// over by the hash of its ABI-encoding (`poolHash`), keeping the typed payload flat.
    bytes32 private constant _UPDATE_USDC_TYPEHASH =
        keccak256("UpdateUsdc(address newUsdc,bytes32 poolHash,uint256 nonce)");
    /// EIP-712 struct hash for rotating the deployer signer (same 2-of-2 signers, separate nonce).
    bytes32 private constant _UPDATE_DEPLOYER_TYPEHASH =
        keccak256("UpdateDeployer(address newDeployer,uint256 nonce)");
    /// EIP-712 struct hash for re-setting the ETH launch pricing (same 2-of-2 signers, separate nonce).
    bytes32 private constant _UPDATE_ETH_CONFIG_TYPEHASH =
        keccak256("UpdateEthConfig(uint256 fdvRaw,uint256 migrationTargetRaw,uint256 nonce)");
    /// EIP-712 struct hash for adding a PositionManager to the hook's LP-claim list (same 2-of-2
    /// signers, separate nonce).
    bytes32 private constant _ADD_POSITION_MANAGER_TYPEHASH =
        keccak256("AddPositionManager(address positionManager,uint256 nonce)");

    event ResolverWalletUpdated(address indexed oldWallet, address indexed newWallet, uint256 nonce);
    /// @notice The team wallet withdrew the create fees booked by launches. See {createFeesOwed}.
    event CreateFeesWithdrawn(address indexed team, uint256 amount);
    event TeamWalletUpdated(address indexed oldRecipient, address indexed newRecipient, uint256 nonce);
    event TeamPayoutTokenUpdated(address indexed newToken, uint256 nonce);
    event FeeTokenUpdated(uint8 indexed which, address indexed newAddr, uint256 nonce);
    event UsdcUpdated(address indexed newUsdc, uint256 nonce);
    event DeployerUpdated(address indexed oldDeployer, address indexed newDeployer, uint256 nonce);
    /// @notice The ETH launch pricing was re-set (see {updateEthConfig}); applies to launches after this.
    event EthConfigUpdated(uint256 fdvRaw, uint256 migrationTargetRaw, uint256 nonce);
    /// @notice A PositionManager was added to the hook's LP-claim list (see {addPositionManager}).
    event PositionManagerAdded(address indexed positionManager, uint256 nonce);

    struct Launch {
        address token;
        int24 tickLower;
        int24 tickUpper;
        address creator;
        /// The pool's quote currency (address(0) = native ETH). Always currency0.
        address numeraire;
    }

    /// @notice The creator's fee-payout choice, made ONCE at launch and immutable
    ///         after (the fee hook has no path to change it).
    /// @param token      payout currency: address(0) = ETH, the platform USDC, or any
    ///                   custom token that has an ETH or USDC pool on Uniswap V4.
    ///                   Leave as USDC (or pass usdc explicitly) for the default.
    /// @param viaHub     custom token only: reach it by bridging through the other
    ///                   canonical currency (numeraire→hub→token) because its liquidity
    ///                   isn't against this launch's numeraire. Ignored for ETH/USDC.
    /// @param fee        fee tier of the custom leg's pool (canonical tiers only).
    /// @param tickSpacing tick spacing of that pool.
    /// @param feeRecipient optional wallet to MINT THE FEE NFT to (fees follow it);
    ///                   address(0) = pay whoever holds the creator NFT (default).
    struct PayoutParams {
        address token;
        bool viaHub;
        /// The payout token's liquidity is a V4 (WETH, token) pool — the hook wraps native
        /// ETH -> WETH to convert into it. Takes precedence over {viaHub}. Requires the hook
        /// to have WETH wired (constructor arg, re-pointable via {updateFeeToken}); rejected otherwise.
        bool wethPaired;
        uint24 fee;
        int24 tickSpacing;
        /// Wallet the fee NFT is MINTED to; address(0) = the caller. This is how a
        /// creator directs their fee stream elsewhere — not by overriding the payout
        /// address in the hook, which would decouple the income from the NFT and break
        /// the transferable-stream property. Mint it where the money should land.
        address feeRecipient;
        /// Creator's choice: true = do NOT autocompound this coin's pool; its 10% autocompound
        /// slice rolls into the creator cut instead. Default false = autocompound on.
        bool autocompoundOff;
        /// Optional custom creator fee in bps (0..500 = 0..5%), charged ON TOP of the 1% platform
        /// fee and paid 100% to the creator on every buy and sell. 0 = none. Validated ≤ 500.
        uint16 creatorFeeBps;
        /// Optional custom LP fee in bps (0..500 = 0..5%), charged ON TOP of the 1% platform fee and
        /// paid 100% to external full-range LPs (folds to the creator when none). 0 = none. Validated ≤ 500.
        uint16 lpFeeBps;
        /// Creator's choice: true = NO LP-reward program — the base 25% LP slice (and any custom LP
        /// fee) all go to the creator instead of external LPs. Default false = LP rewards on.
        bool lpRewardsOff;
    }

    error BadPayoutTier();
    error PayoutPoolMissing();
    /// @dev The optional custom creator fee exceeded the 5% (500 bps) cap.
    error CreatorFeeTooHigh();
    /// @dev The optional custom LP fee exceeded the 5% (500 bps) cap.
    error LpFeeTooHigh();
    /// A WETH-paired payout was chosen on a launch whose numeraire is not native ETH. The hook
    /// wraps native ETH -> WETH to convert, so the fee bucket must already be ETH (v1 scope).
    error WethPayoutNeedsEthNumeraire();
    error BadNumeraire();
    /// @dev The mined token address must sort above the numeraire (see the contract
    ///      docs) — a USDC launch whose salt doesn't achieve that is rejected.
    error TokenBelowNumeraire();
    /// @dev A non-ETH numeraire needs a mined CREATE2 salt; the non-deterministic
    ///      `Clones.clone` fallback can't guarantee the ordering above.
    error SaltRequired();

    mapping(address => Launch) public launchOf;
    address[] public tokens;

    /// @param numeraire The pool's quote currency (address(0) = native ETH) — indexers
    ///        need it to know which currency this token's prices are denominated in.
    event Launched(
        address indexed token,
        PoolId indexed poolId,
        address indexed creator,
        int24 tickLower,
        int24 tickUpper,
        address numeraire
    );
    /// @notice The two rungs minted for `token` at launch: rung i is `tokens[i]` tokens over
    ///         [tickLowers[i], tickUppers[i]] (tickLower == usable minimum = open-ended). Indexers price
    ///         the pool's numeraire from these.
    event RungsMinted(
        address indexed token, int24[2] tickLowers, int24[2] tickUppers, uint128[2] liquidities, uint256[2] tokens
    );

    /// @param startFdvs Starting FDV per numeraire, in that numeraire's RAW units —
    ///        the deploy sets {ETH: 1e18, USDC: 2_500e6} — the SAME starting valuation
    ///        either way, so a launch opens at ~$2,500 whichever currency quotes it.
    ///        Fixed at deploy: no owner, no pricing setter. (This example said 1.1e18/
    ///        3_300e6, which no deploy has ever used.)
    /// @param launchFeeRecipient_ The initial team wallet (create fee + hook team slice).
    /// @param deployer_ The deployer: the fixed second signer of the team-wallet 2-of-2.
    ///        MUST differ from `launchFeeRecipient_` so the multisig is a real 2-of-2.
    constructor(
        IPoolManager poolManager_,
        IHooks feeHook_,
        CreatorNFT creatorNFT_,
        address launchTokenImpl_,
        address launchFeeRecipient_,
        address resolverWallet_,
        address deployer_,
        StartFdv[] memory startFdvs
    ) EIP712("BodkinLauncher", "1") {
        require(
            address(poolManager_) != address(0) && address(feeHook_) != address(0)
                && address(creatorNFT_) != address(0) && launchTokenImpl_ != address(0)
                && launchFeeRecipient_ != address(0) && deployer_ != address(0) && resolverWallet_ != address(0),
            "Launcher: zero"
        );
        require(deployer_ != launchFeeRecipient_, "Launcher: signers equal");
        poolManager = poolManager_;
        feeHook = feeHook_;
        creatorNFT = creatorNFT_;
        launchTokenImpl = launchTokenImpl_;
        launchFeeRecipient = launchFeeRecipient_;
        resolverWallet = resolverWallet_;
        deployer = deployer_;
        for (uint256 i = 0; i < startFdvs.length; i++) {
            require(startFdvs[i].fdvRaw >= MIN_START_FDV_RAW, "Launcher: fdv too low");
            startFdvOf[startFdvs[i].numeraire] = startFdvs[i].fdvRaw;
            migrationTargetOf[startFdvs[i].numeraire] = startFdvs[i].migrationTargetRaw;
        }
        require(startFdvOf[address(0)] != 0, "Launcher: eth fdv required");
    }

    // ─── team-wallet 2-of-2 governance ──────────────────────────────────────────────
    // The ONE mutable parameter on this otherwise-immutable launcher: the team wallet.
    // Moving it needs BOTH the deployer (`deployer`) and the CURRENT team
    // (`launchFeeRecipient`) to sign the same payload off-chain — independently, on
    // separate machines — after which either of them submits the single settling call.
    // No party can move the wallet alone, and the current team must consent to its own
    // replacement. The change re-points the hook's team slice in the same call. (The create
    // fee is NOT the team's — it funds the resolver wallet; see {updateResolverWallet}.)

    /// @notice The EIP-712 digest each signer signs off-chain to authorise a move to
    ///         `newRecipient`. Bound to this contract + chainId (the domain) and to
    ///         `nonce` — pass the current {teamWalletNonce}. A wallet signs this exact
    ///         digest; `cast wallet sign` / eth_signTypedData produce the two signatures.
    function teamWalletUpdateDigest(address newRecipient, uint256 nonce) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(_UPDATE_TEAM_TYPEHASH, newRecipient, nonce)));
    }

    /// @notice Re-point the team wallet to `newRecipient`, redirecting the hook's 20% swap-fee
    ///         slice ({FeeHook.setTeam}) — pending banked amounts included — and the team's
    ///         signer role in every 2-of-2 here. The create fee is unaffected (resolver wallet). Requires a 2-of-2: `sigDeployer` from
    ///         `deployer` and `sigTeam` from the CURRENT `launchFeeRecipient`, each over
    ///         {teamWalletUpdateDigest}(newRecipient, {teamWalletNonce}). Either signer may
    ///         be the caller. The nonce is consumed on success, so the pair is single-use.
    /// @dev `newRecipient` may not be `deployer` — that would fold the 2-of-2 into a 1-of-1
    ///      on the next change (both signer roles held by one key).
    function updateTeamWallet(address newRecipient, bytes calldata sigDeployer, bytes calldata sigTeam) external {
        require(msg.sender == deployer || msg.sender == launchFeeRecipient, "Launcher: not a signer");
        require(newRecipient != address(0) && newRecipient != deployer, "Launcher: bad recipient");
        bytes32 digest = teamWalletUpdateDigest(newRecipient, teamWalletNonce);
        require(ECDSA.recover(digest, sigDeployer) == deployer, "Launcher: bad deployer sig");
        require(ECDSA.recover(digest, sigTeam) == launchFeeRecipient, "Launcher: bad team sig");
        address old = launchFeeRecipient;
        launchFeeRecipient = newRecipient;
        unchecked {
            ++teamWalletNonce;
        }
        // Keep the hook's team wallet in lockstep so the swap-fee slice follows too.
        IFeeHookPayout(address(feeHook)).setTeam(newRecipient);
        emit TeamWalletUpdated(old, newRecipient, teamWalletNonce);
    }

    function resolverWalletUpdateDigest(address newRecipient, uint256 nonce) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(_UPDATE_RESOLVER_WALLET_TYPEHASH, newRecipient, nonce)));
    }

    function updateResolverWallet(address newRecipient, bytes calldata sigDeployer, bytes calldata sigTeam) external {
        require(msg.sender == deployer || msg.sender == launchFeeRecipient, "Launcher: not a signer");
        require(newRecipient != address(0) && newRecipient != deployer, "Launcher: bad recipient");
        bytes32 digest = resolverWalletUpdateDigest(newRecipient, resolverWalletNonce);
        require(ECDSA.recover(digest, sigDeployer) == deployer, "Launcher: bad deployer sig");
        require(ECDSA.recover(digest, sigTeam) == launchFeeRecipient, "Launcher: bad team sig");
        address old = resolverWallet;
        resolverWallet = newRecipient;
        unchecked { ++resolverWalletNonce; }
        emit ResolverWalletUpdated(old, newRecipient, resolverWalletNonce);
    }


    /// @notice The EIP-712 digest each signer signs off-chain to authorise changing the team's
    ///         payout token to `newToken` — pass the current {teamPayoutTokenNonce}. Same domain +
    ///         2-of-2 signers as {teamWalletUpdateDigest}; a distinct typehash + nonce.
    function teamPayoutTokenUpdateDigest(address newToken, uint256 nonce) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(_UPDATE_TEAM_PAYOUT_TYPEHASH, newToken, nonce)));
    }

    /// @notice Change the currency the team's 20% swap-fee slice is paid in
    ///         ({FeeHook.teamPayoutToken} — native ETH or an allowed token, e.g. a migrated USDC).
    ///         Requires the SAME 2-of-2 as {updateTeamWallet}: `sigDeployer` from `deployer` and
    ///         `sigTeam` from the current `launchFeeRecipient`, each over
    ///         {teamPayoutTokenUpdateDigest}(newToken, {teamPayoutTokenNonce}). Either signer may be
    ///         the caller; the nonce is consumed on success. The hook enforces the allowed-token set
    ///         AND that all converted team fees are already claimed, so a flip never mis-delivers a
    ///         banked balance.
    function updateTeamPayoutToken(address newToken, bytes calldata sigDeployer, bytes calldata sigTeam) external {
        require(msg.sender == deployer || msg.sender == launchFeeRecipient, "Launcher: not a signer");
        bytes32 digest = teamPayoutTokenUpdateDigest(newToken, teamPayoutTokenNonce);
        require(ECDSA.recover(digest, sigDeployer) == deployer, "Launcher: bad deployer sig");
        require(ECDSA.recover(digest, sigTeam) == launchFeeRecipient, "Launcher: bad team sig");
        unchecked {
            ++teamPayoutTokenNonce;
        }
        IFeeHookPayout(address(feeHook)).setTeamPayoutToken(newToken);
        emit TeamPayoutTokenUpdated(newToken, teamPayoutTokenNonce);
    }

    /// @notice The EIP-712 digest each signer signs off-chain to authorise re-pointing a
    ///         fee-infrastructure address — pass `which` (0 = usdc, 1 = weth), the new address, and
    ///         the current {feeTokenNonce}. Same domain + 2-of-2 signers as {teamWalletUpdateDigest};
    ///         a distinct typehash + nonce.
    function feeTokenUpdateDigest(uint8 which, address newAddr, uint256 nonce) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(_UPDATE_FEE_TOKEN_TYPEHASH, which, newAddr, nonce)));
    }

    /// @notice Re-point one of the hook's fee-infrastructure addresses ({FeeHook.setFeeToken}) — the
    ///         emergency escape hatch for a deprecated numeraire contract (e.g. WETH or USDC migrates
    ///         to a new address whose old pools have gone dry). `which`: 0 = usdc, 1 = weth. Requires
    ///         the SAME 2-of-2 as {updateTeamWallet}: `sigDeployer` from `deployer` and `sigTeam` from the
    ///         current `launchFeeRecipient`, each over {feeTokenUpdateDigest}(which, newAddr,
    ///         {feeTokenNonce}). Either signer may be the caller; the nonce is consumed on success, so
    ///         the pair is single-use. The hook itself enforces which selectors are live — a USDC
    ///         re-point currently reverts there (banked per-currency fees), leaving WETH as the only
    ///         enabled target until the multi-currency claim lands.
    function updateFeeToken(uint8 which, address newAddr, bytes calldata sigDeployer, bytes calldata sigTeam)
        external
    {
        require(msg.sender == deployer || msg.sender == launchFeeRecipient, "Launcher: not a signer");
        bytes32 digest = feeTokenUpdateDigest(which, newAddr, feeTokenNonce);
        require(ECDSA.recover(digest, sigDeployer) == deployer, "Launcher: bad deployer sig");
        require(ECDSA.recover(digest, sigTeam) == launchFeeRecipient, "Launcher: bad team sig");
        unchecked {
            ++feeTokenNonce;
        }
        // Forwards to the hook, which is the authority on which selectors are enabled and on any
        // per-address shape checks; an unknown/disabled selector reverts there and rolls this back.
        IFeeHookPayout(address(feeHook)).setFeeToken(which, newAddr);
        emit FeeTokenUpdated(which, newAddr, feeTokenNonce);
    }

    /// @notice The EIP-712 digest each signer signs off-chain to authorise adding `pm` to the fee hook's
    ///         LP-claim PositionManager list — pass the current {positionManagerNonce}. Same domain +
    ///         2-of-2 signers as {teamWalletUpdateDigest}; a distinct typehash + nonce.
    function positionManagerAddDigest(address pm, uint256 nonce) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(_ADD_POSITION_MANAGER_TYPEHASH, pm, nonce)));
    }

    /// @notice Add a Uniswap PositionManager to the fee hook's LP-claim list ({FeeHook.addPositionManager})
    ///         — for when Uniswap ships a new PositionManager and LPs mint positions through it; without
    ///         this their share of the LP slice would accrue with no way to claim it. ADD-ONLY: nothing
    ///         can be removed or re-pointed, and a listed contract can only pay out the rewards of
    ///         liquidity it provided itself. Requires the SAME 2-of-2 as {updateTeamWallet}: `sigDeployer`
    ///         from `deployer` and `sigTeam` from the current `launchFeeRecipient`, each over
    ///         {positionManagerAddDigest}(pm, {positionManagerNonce}). Either signer may be the caller;
    ///         the nonce is consumed on success, so the pair is single-use. The hook checks that `pm` has
    ///         code, is not listed yet, and is bound to this PoolManager.
    function addPositionManager(address pm, bytes calldata sigDeployer, bytes calldata sigTeam) external {
        require(msg.sender == deployer || msg.sender == launchFeeRecipient, "Launcher: not a signer");
        bytes32 digest = positionManagerAddDigest(pm, positionManagerNonce);
        require(ECDSA.recover(digest, sigDeployer) == deployer, "Launcher: bad deployer sig");
        require(ECDSA.recover(digest, sigTeam) == launchFeeRecipient, "Launcher: bad team sig");
        unchecked {
            ++positionManagerNonce;
        }
        IFeeHookPayout(address(feeHook)).addPositionManager(pm);
        emit PositionManagerAdded(pm, positionManagerNonce);
    }

    /// @notice The EIP-712 digest each signer signs off-chain to authorise re-pointing the fee hook's
    ///         USDC — pass the new USDC, its new (ETH,usdc) conversion pool, and the current
    ///         {usdcNonce}. Same domain + 2-of-2 signers as {teamWalletUpdateDigest}; the pool is bound
    ///         via the hash of its ABI-encoding, so the exact key is authorised, not just the address.
    function usdcUpdateDigest(address newUsdc, PoolKey calldata newPool, uint256 nonce)
        public
        view
        returns (bytes32)
    {
        bytes32 poolHash = keccak256(abi.encode(newPool));
        return _hashTypedDataV4(keccak256(abi.encode(_UPDATE_USDC_TYPEHASH, newUsdc, poolHash, nonce)));
    }

    /// @notice Re-point the fee hook's USDC to `newUsdc` — the escape hatch that keeps ALREADY-LAUNCHED
    ///         tokens' fee conversions working after a USDC contract migration. One 2-of-2 action moves
    ///         everything USDC is load-bearing in FOR FEE ROUTING: the hook's `usdc` address, its
    ///         (ETH,usdc) conversion pool, and its team payout token + allow-list ({FeeHook.migrateUsdc}).
    ///         It deliberately does NOT touch this launcher's per-numeraire {startFdvOf}: launching NEW
    ///         USDC-quoted tokens against a migrated USDC is done by deploying a fresh launcher, not by
    ///         mutating this one. Requires the SAME 2-of-2 as {updateTeamWallet}: `sigDeployer` from
    ///         `deployer` and `sigTeam` from the current `launchFeeRecipient`, each over
    ///         {usdcUpdateDigest}(newUsdc, newPool, {usdcNonce}). Either signer may submit; the nonce is
    ///         consumed on success. The hook coin-validates `newUsdc` and re-derives every anti-drain
    ///         pool check, reverting (and rolling this whole call back) on a bad coin or pool.
    function updateUsdc(address newUsdc, PoolKey calldata newPool, bytes calldata sigDeployer, bytes calldata sigTeam)
        external
    {
        require(msg.sender == deployer || msg.sender == launchFeeRecipient, "Launcher: not a signer");
        bytes32 digest = usdcUpdateDigest(newUsdc, newPool, usdcNonce);
        require(ECDSA.recover(digest, sigDeployer) == deployer, "Launcher: bad deployer sig");
        require(ECDSA.recover(digest, sigTeam) == launchFeeRecipient, "Launcher: bad team sig");
        unchecked {
            ++usdcNonce;
        }
        IFeeHookPayout(address(feeHook)).migrateUsdc(newUsdc, newPool);
        emit UsdcUpdated(newUsdc, usdcNonce);
    }

    struct StartFdv {
        address numeraire;
        uint256 fdvRaw;
        uint256 migrationTargetRaw;
    }


    /// @param numeraireCollected numeraire the curve collected, all of it paired into the full-range position.
    /// @param tokensAdded        tokens the full-range position absorbed at the graduation price.
    /// @param wallTokens         leftover tokens re-minted as the single-sided wall (0 = none left).
    /// @param wallTickUpper      the wall's upper tick (its lower tick is always the usable minimum).
    event Migrated(
        address indexed token, uint256 numeraireCollected, uint256 tokensAdded, uint256 wallTokens, int24 wallTickUpper
    );

    /// @notice The EIP-712 digest each signer signs off-chain to authorise re-setting the ETH launch
    ///         pricing — pass the current {ethConfigNonce}.
    function ethConfigUpdateDigest(uint256 fdvRaw, uint256 migrationTargetRaw, uint256 nonce)
        public
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(keccak256(abi.encode(_UPDATE_ETH_CONFIG_TYPEHASH, fdvRaw, migrationTargetRaw, nonce)));
    }

    /// @notice The ONE deliberate escape hatch in launch pricing: re-set the ETH-quoted start FDV and
    ///         migration target for FUTURE launches. ETH launches are priced in wei, so a large move in
    ///         ETH/USD (say ETH at $20k) would otherwise open every new coin at a very different dollar
    ///         valuation than the ~$2.5k the launchpad advertises; this keeps the dollar figure where it
    ///         belongs. USDC-quoted launches need no such knob — a dollar stays a dollar. Only NEW launches
    ///         are affected: a launched coin's curve, wall and rungs are already minted and never move.
    ///         Requires the SAME 2-of-2 as {updateTeamWallet} (`sigDeployer` from `deployer`, `sigTeam`
    ///         from the current `launchFeeRecipient`, each over {ethConfigUpdateDigest}), so a single
    ///         compromised key cannot re-price launches; bounded so a fat-finger can't mint a collapsed
    ///         curve, and logged so every change is visible on-chain.
    function updateEthConfig(
        uint256 newFdvRaw,
        uint256 newMigrationTargetRaw,
        bytes calldata sigDeployer,
        bytes calldata sigTeam
    ) external {
        require(msg.sender == deployer || msg.sender == launchFeeRecipient, "Launcher: not a signer");
        require(newFdvRaw >= MIN_START_FDV_RAW, "Launcher: fdv too low");
        // The curve must have room to climb: the target sets the graduation price ABOVE the start.
        require(newMigrationTargetRaw > newFdvRaw, "Launcher: target must exceed fdv");
        bytes32 digest = ethConfigUpdateDigest(newFdvRaw, newMigrationTargetRaw, ethConfigNonce);
        require(ECDSA.recover(digest, sigDeployer) == deployer, "Launcher: bad deployer sig");
        require(ECDSA.recover(digest, sigTeam) == launchFeeRecipient, "Launcher: bad team sig");
        startFdvOf[address(0)] = newFdvRaw;
        migrationTargetOf[address(0)] = newMigrationTargetRaw;
        unchecked {
            ++ethConfigNonce;
        }
        emit EthConfigUpdated(newFdvRaw, newMigrationTargetRaw, ethConfigNonce);
    }

    /// @notice The EIP-712 digest each signer signs off-chain to authorise rotating the deployer signer
    ///         to `newDeployer` — pass the current {deployerNonce}.
    function deployerUpdateDigest(address newDeployer, uint256 nonce) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(_UPDATE_DEPLOYER_TYPEHASH, newDeployer, nonce)));
    }

    /// @notice Rotate the deployer signer. The point is key hygiene: if the deployer key is exposed
    ///         (or should move to colder storage) the team and the CURRENT deployer sign it out and a
    ///         fresh key in; the exposed key alone can do nothing meanwhile, since every action here
    ///         needs the team's signature too. Requires the SAME 2-of-2 as {updateTeamWallet}:
    ///         `sigDeployer` from the current `deployer` and `sigTeam` from `launchFeeRecipient`, each
    ///         over {deployerUpdateDigest}(newDeployer, {deployerNonce}). Either signer may submit.
    /// @dev `newDeployer` may not be the team wallet — that would fold the 2-of-2 into a 1-of-1.
    function updateDeployer(address newDeployer, bytes calldata sigDeployer, bytes calldata sigTeam) external {
        require(msg.sender == deployer || msg.sender == launchFeeRecipient, "Launcher: not a signer");
        require(newDeployer != address(0) && newDeployer != launchFeeRecipient, "Launcher: bad deployer");
        bytes32 digest = deployerUpdateDigest(newDeployer, deployerNonce);
        require(ECDSA.recover(digest, sigDeployer) == deployer, "Launcher: bad deployer sig");
        require(ECDSA.recover(digest, sigTeam) == launchFeeRecipient, "Launcher: bad team sig");
        address old = deployer;
        deployer = newDeployer;
        unchecked {
            ++deployerNonce;
        }
        emit DeployerUpdated(old, newDeployer, deployerNonce);
    }

    function migrate(address token) external nonReentrant {
        CurvePosition storage pos = curvePositions[token];
        require(pos.liquidity > 0 && !pos.migrated, "Launcher: invalid or already migrated");
        
        Launch memory l = launchOf[token];
        PoolKey memory key = _poolKey(token, l.numeraire);
        (, int24 curTick,,) = poolManager.getSlot0(key.toId());
        
        // Ensure price has crossed the tickLower
        require(curTick <= pos.tickLower + 60, "Launcher: curve not completed");
        
        pos.migrated = true;
        
        poolManager.unlock(abi.encode(uint8(2), key, pos.tickLower, pos.tickUpper, pos.liquidity, token));
    }

    function tokensCount() external view returns (uint256) {
        return tokens.length;
    }

    /// @dev Reject a custom payout token whose conversion pool doesn't actually exist
    ///      (or uses an off-spec tier) — otherwise the creator's fees would accrue but
    ///      every claim would revert. ETH and USDC payouts need no check: ETH is paid
    ///      directly and USDC goes through the hook's own wired pool.
    function _validatePayout(PayoutParams calldata payout, address numeraire) internal view {
        // The optional custom creator + LP fees are each capped at 5% (500 bps) — checked here (before
        // the ETH/USDC early-return) so they hold for EVERY payout token, not only custom ones.
        if (payout.creatorFeeBps > MAX_CREATOR_FEE_BPS) revert CreatorFeeTooHigh();
        if (payout.lpFeeBps > MAX_LP_FEE_BPS) revert LpFeeTooHigh();
        address pt = payout.token;
        if (pt == address(0) || pt == IFeeHookPayout(address(feeHook)).usdc()) return;
        if (!CanonicalTiers.isCanonical(payout.fee, payout.tickSpacing)) revert BadPayoutTier();
        // The leg the hook will swap through: paired with this launch's numeraire, or
        // — when bridging — with the other canonical currency. Plain pool, no hooks.
        // The currency the hook pairs the payout token with when converting fees:
        //   wethPaired: a V4 (WETH, token) pool — the hook wraps ETH->WETH to reach it;
        //   viaHub:     the OTHER canonical currency (USDC for an ETH launch, vice versa);
        //   else:       this launch's own numeraire.
        address other;
        if (payout.wethPaired) {
            // ETH-numeraire only (v1): the hook wraps native ETH -> WETH, so the fee bucket must
            // already be ETH. A USDC launch would need an extra USDC -> ETH bridge first.
            if (numeraire != address(0)) revert WethPayoutNeedsEthNumeraire();
            other = IFeeHookPayout(address(feeHook)).weth();
            if (other == address(0)) revert PayoutPoolMissing(); // WETH payouts disabled on this hook
        } else {
            address hub = numeraire == address(0) ? IFeeHookPayout(address(feeHook)).usdc() : address(0);
            other = payout.viaHub ? hub : numeraire;
        }
        (address c0, address c1) = other < pt ? (other, pt) : (pt, other);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: payout.fee,
            tickSpacing: payout.tickSpacing,
            hooks: IHooks(address(0))
        });
        // Existence only — NOT live liquidity. A pool exists (sqrtPriceX96 != 0) or it does
        // not, which nobody can toggle; requiring in-range liquidity here instead would be
        // front-runnable (empty the pool in the same block to block a launch) and would
        // false-reject a funded pool whose liquidity is momentarily out of range. Dry or
        // out-of-range payout pools are handled at runtime by the hook's numeraire fallback,
        // so this gate stays a pure, un-griefable existence check.
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        if (sqrtPriceX96 == 0) revert PayoutPoolMissing();
    }

    /// @notice The launch pool for `token`: (its numeraire, token) on our fee hook.
    ///         The numeraire is always currency0 — see the contract-level invariant.
    function poolKeyOf(address token) public view returns (PoolKey memory) {
        return _poolKey(token, launchOf[token].numeraire);
    }

    function _poolKey(address token, address numeraire) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(numeraire),
            currency1: Currency.wrap(token),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: feeHook
        });
    }

    /// @notice Launch a token. `msg.value` must cover the flat launch fee (always ETH).
    /// @param numeraire The pool's quote currency: address(0) for native ETH (the
    ///        default) or the platform USDC. Must be allowlisted by the fee hook, and
    ///        the resulting token address must sort ABOVE it — pass a mined salt.
    /// @param devBuyAmount For a USDC launch, the optional first buy in USDC, pulled
    ///        from the creator (approve first). IGNORED for an ETH launch, where the
    ///        dev buy is whatever `msg.value` exceeds the launch fee.
    /// @param payout The creator's fee-payout choice — currency and (optionally) a
    ///        fixed recipient wallet. Chosen ONCE here and immutable afterwards.
    function launch(
        string calldata name,
        string calldata symbol,
        string calldata metadataURI,
        bytes32 salt,
        address numeraire,
        uint256 devBuyAmount,
        PayoutParams calldata payout
    )
        external
        payable
        nonReentrant
        returns (address token)
    {
        bool ethNumeraire = numeraire == address(0);
        if (!IFeeHookPayout(address(feeHook)).isNumeraire(numeraire)) revert BadNumeraire();
        if (startFdvOf[numeraire] == 0) revert BadNumeraire();
        // Only a mined salt can guarantee token > numeraire (see the invariant).
        if (!ethNumeraire && salt == bytes32(0)) revert SaltRequired();
        _validatePayout(payout, numeraire);
        // The avatar is REQUIRED, and it is always an IPFS URI the launchpad pinned. Enforce that
        // SHAPE on-chain — non-empty is not enough — so a malformed, foreign-scheme or truncated
        // pointer can never reach the token's tokenURI or the indexer (a ghost coin with no avatar).
        {
            bytes memory uri = bytes(metadataURI);
            require(
                uri.length >= MIN_METADATA_URI_BYTES && uri.length <= MAX_METADATA_URI_BYTES,
                "Launcher: bad metadata URI length"
            );
            require(
                uri[0] == 0x69 && uri[1] == 0x70 && uri[2] == 0x66 && uri[3] == 0x73 // "ipfs"
                    && uri[4] == 0x3a && uri[5] == 0x2f && uri[6] == 0x2f, // "://"
                "Launcher: metadata must be ipfs://"
            );
        }
        require(msg.value >= launchFeeWei, "Launcher: launch fee required");
        // ETH launch: the dev buy is the ETH sent above the fee. USDC launch: the fee
        // is the ONLY ETH accepted, and the dev buy is pulled as USDC below.
        uint256 devBuy;
        if (ethNumeraire) {
            devBuy = msg.value - launchFeeWei;
        } else {
            require(msg.value == launchFeeWei, "Launcher: send only the fee");
            devBuy = devBuyAmount;
        }
        // Any balance already sitting here (e.g. force-fed) isn't part of this launch.
        uint256 preBal = address(this).balance - msg.value;

        // 1. Plain ERC-20 (EIP-1167 clone), full supply minted to this launcher.
        //    Namespace the vanity salt to the creator so nobody can front-run their
        //    mined address by replaying the same salt from another account (the
        //    CREATE2 address then depends on msg.sender, not the raw salt alone).
        bytes32 vanitySalt = keccak256(abi.encodePacked(msg.sender, salt));
        BodkinERC20 t = BodkinERC20(
            salt == bytes32(0) ? Clones.clone(launchTokenImpl) : Clones.cloneDeterministic(launchTokenImpl, vanitySalt)
        );
        t.initialize(name, symbol, TOTAL_SUPPLY, address(this), metadataURI);
        token = address(t);
        // THE INVARIANT: the numeraire must sort as currency0. Free for ETH; for USDC
        // the creator's mined salt has to deliver it, else we refuse the launch rather
        // than open a pool with mirrored (and untested) range/direction semantics.
        if (token <= numeraire) revert TokenBelowNumeraire();

        // 2. Record the launch config BEFORE opening the pool, so the fee hook can
        //    verify the key we hand it matches this token's numeraire.
        // The fee NFT IS the fee stream, so minting it to `feeRecipient` is what
        // directs the income there — and it stays transferable from that wallet.
        creatorNFT.mint(payout.feeRecipient != address(0) ? payout.feeRecipient : msg.sender, token);
        IFeeHookPayout(address(feeHook)).setLaunchConfig(
            token,
            payout.token,
            payout.viaHub,
            payout.wethPaired,
            payout.fee,
            payout.tickSpacing,
            numeraire,
            payout.autocompoundOff,
            payout.creatorFeeBps,
            payout.lpFeeBps,
            payout.lpRewardsOff
        );

        // 2b. An ERC-20 numeraire dev buy is pulled NOW, while there is still no pool. `transferFrom` is
        //     the token's own code — and on this chain the canonical dollar is an upgradeable proxy —
        //     so it is outside code, and outside code has no business running with a freshly seeded pool
        //     in front of it. Same reason the create fee left the launch transaction entirely. Measured
        //     as a DELTA so a stranger's balance stuck here is never swept into this launch's refund.
        uint256 preNum;
        if (devBuy > 0 && !ethNumeraire) {
            preNum = IERC20(numeraire).balanceOf(address(this));
            IERC20(numeraire).safeTransferFrom(msg.sender, address(this), devBuy);
        }

        // 3. Open the (numeraire, token) V4 pool at the FDV-derived price. startFdvOf
        //    is in the numeraire's RAW units, which is exactly what the price formula
        //    wants — so no decimals term is needed here.
        PoolKey memory key = _poolKey(token, numeraire);
        uint160 sqrtPriceX96 = _initialSqrtPriceX96(TOTAL_SUPPLY, startFdvOf[numeraire]);
        poolManager.initialize(key, sqrtPriceX96);

        // 4. Calculate exact tickLower to meet migration target
        uint256 targetFdv = migrationTargetOf[numeraire];
        require(targetFdv > 0, "Launcher: no migration target");
        
        uint160 sqrtPriceX96Lower = _initialSqrtPriceX96(TOTAL_SUPPLY, targetFdv);
        int24 exactTickLower = TickMath.getTickAtSqrtPrice(sqrtPriceX96Lower);
        
        (, int24 curTick,,) = poolManager.getSlot0(key.toId());
        int24 rounded = _floorToSpacing(curTick);
        
        
        int24 tickUpper = rounded - TICK_SPACING;
        int24 tickLower = _floorToSpacing(exactTickLower);
        // The SAME lower bound the wall below the curve and the migrated position use (p.minUsable, and
        // FeeHook.MIN_USABLE). It used to clamp one spacing further out, to -887220: had the clamp ever
        // bitten, the curve would have started below the wall that is seeded at -887160 and the launch
        // would have reverted on its own seeding. Only reachable with an absurd start price, but the two
        // numbers describe the same edge and there is no reason for them to differ.
        int24 minUsable = (TickMath.MIN_TICK / TICK_SPACING) * TICK_SPACING + TICK_SPACING;
        if (tickLower < minUsable) tickLower = minUsable;
        if (tickLower >= tickUpper) tickLower = tickUpper - TICK_SPACING;

        // 5. Seed the pool: CURVE_SUPPLY on the curve, WALL_SUPPLY as the base wall right above it, and
        //    the three rungs far above (all single-sided token positions below the current tick).
        uint128 liqCurve = _seedPool(token, key, tickLower, tickUpper, targetFdv);

        // 6. Sweep any mint/round dust so the launcher never lingers as a holder.
        uint256 dust = IERC20(token).balanceOf(address(this));
        if (dust > 0) IERC20(token).transfer(DEAD, dust);

        launchOf[token] =
            Launch({token: token, tickLower: tickLower, tickUpper: tickUpper, creator: msg.sender, numeraire: numeraire});
        tokens.push(token);
        emit Launched(token, key.toId(), msg.sender, tickLower, tickUpper, numeraire);

        // 7. Optional dev buy — numeraire -> token to the creator, routed through the
        //    pool so it's fee'd like any other trade. Runs after the launch is recorded.
        //    A USDC dev buy is pulled from the creator's approval first.
        //
        //    NOTHING outside our own contracts runs between seeding the pool and this trade, and that is
        //    what protects a dev buy carrying no minimum output — atomicity, not a slippage bound. The
        //    token is our own clone, the creator NFT is minted with `_mint` (no receiver hook), and
        //    everything else is the PoolManager and our own hook. The create fee used to be SENT here,
        //    before this buy, with a plain `call` carrying all the gas — handing the resolver's key, a
        //    hot bot key that EIP-7702 lets anyone delegate to a contract, a turn in front of the dev
        //    buy. It is now booked and withdrawn in its own transaction ({createFeesOwed}).
        if (devBuy > 0) {
            if (ethNumeraire) {
                poolManager.unlock(abi.encode(uint8(1), key, devBuy, msg.sender));
            } else {
                // Already pulled in step 2b; what the swap did not spend goes back, measured against the
                // balance from before that pull so a stranger's stuck balance is never handed out here.
                poolManager.unlock(abi.encode(uint8(1), key, devBuy, msg.sender));
                uint256 nowNum = IERC20(numeraire).balanceOf(address(this));
                uint256 leftover = nowNum > preNum ? nowNum - preNum : 0;
                if (leftover > 0) IERC20(numeraire).safeTransfer(msg.sender, leftover);
            }
        }
        // 8. Book the flat launch fee (always ETH, whatever the numeraire). Booked, not sent — see
        //    {createFeesOwed} — and withdrawn later by the team wallet through {withdraw}.
        if (launchFeeWei > 0) createFeesOwed += launchFeeWei;
        // 9. Refund only THIS launch's unspent ETH to the creator — never the pre-existing/force-fed
        //    balance measured above, and never the fee just booked, which stays here until it is pushed.
        uint256 extra = address(this).balance - preBal - launchFeeWei;
        if (extra > 0) _sendEth(msg.sender, extra);
    }

    /// @dev Compute every launch-time position, record them, and mint them in one unlock.
    function _seedPool(address token, PoolKey memory key, int24 tickLower, int24 tickUpper, uint256 targetFdv)
        internal
        returns (uint128 liqCurve)
    {
        SeedParams memory p;
        p.tickLower = tickLower;
        p.tickUpper = tickUpper;
        p.minUsable = (TickMath.MIN_TICK / TICK_SPACING) * TICK_SPACING + TICK_SPACING;
        p.liqCurve = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), CURVE_SUPPLY
        );
        p.liqWall = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(p.minUsable), TickMath.getSqrtPriceAtTick(tickLower), WALL_SUPPLY
        );
        // Rungs: a rung spanning [LO_X, HI_X] times the target FDV lives at ticks [tick(HI_X), tick(LO_X)]
        // (a HIGHER FDV is a LOWER tick, since the token is currency1), floored to spacing; HI_X == 0 is
        // open-ended down to the usable minimum. Each top must sit strictly below the migration tick so
        // the rung is fully out of range at launch; the clamps only ever bite on an absurd target.
        uint256[2] memory supplies = [RUNG_A_SUPPLY, RUNG_B_SUPPLY];
        uint256[2] memory los = [RUNG_A_LO_X, RUNG_B_LO_X];
        uint256[2] memory his = [RUNG_A_HI_X, RUNG_B_HI_X];
        for (uint256 i = 0; i < RUNG_COUNT; i++) {
            int24 upper = _rungTick(targetFdv * los[i]);
            if (upper >= tickLower) upper = tickLower - TICK_SPACING;
            int24 lower = his[i] == 0 ? p.minUsable : _rungTick(targetFdv * his[i]);
            if (lower < p.minUsable) lower = p.minUsable;
            if (lower >= upper) lower = upper - TICK_SPACING;
            require(lower >= p.minUsable && lower < upper, "Launcher: rung range collapsed");
            p.rungLower[i] = lower;
            p.rungUpper[i] = upper;
            p.rungLiqs[i] = LiquidityAmounts.getLiquidityForAmount1(
                TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), supplies[i]
            );
            _rungs[token][i] = RungPosition({tickLower: lower, tickUpper: upper, liquidity: p.rungLiqs[i], tokens: supplies[i]});
        }
        curvePositions[token] = CurvePosition({tickLower: tickLower, tickUpper: tickUpper, liquidity: p.liqCurve, migrated: false});
        poolManager.unlock(abi.encode(uint8(0), key, p));
        emit RungsMinted(token, p.rungLower, p.rungUpper, p.rungLiqs, supplies);
        return p.liqCurve;
    }

    /// @dev The spacing-floored tick of an FDV (raw numeraire units) for a launch of TOTAL_SUPPLY.
    function _rungTick(uint256 fdvRaw) internal pure returns (int24) {
        return _floorToSpacing(TickMath.getTickAtSqrtPrice(_initialSqrtPriceX96(TOTAL_SUPPLY, fdvRaw)));
    }

    /// @notice The two rungs minted for `token` at launch (range, liquidity and tokens each). Zeroed for
    ///         an unknown token.
    function rungsOf(address token) external view returns (RungPosition[2] memory) {
        return _rungs[token];
    }

    /// PoolManager unlock callback. kind 0 = add the single-sided liquidity + settle
    /// the token; kind 1 = dev buy (ETH -> token to the creator, through the pool).
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "Launcher: not manager");
        uint8 kind = abi.decode(data, (uint8));

        if (kind == 0) {
            (, PoolKey memory key, SeedParams memory p) = abi.decode(data, (uint8, PoolKey, SeedParams));
            int128 owed0;
            int128 owed1;
            BalanceDelta d;
            // Curve, base wall, then the three rungs — all token-only (below the current tick).
            (d,) = poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({tickLower: p.tickLower, tickUpper: p.tickUpper, liquidityDelta: int256(uint256(p.liqCurve)), salt: 0}),
                ""
            );
            owed0 += d.amount0();
            owed1 += d.amount1();
            (d,) = poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({tickLower: p.minUsable, tickUpper: p.tickLower, liquidityDelta: int256(uint256(p.liqWall)), salt: 0}),
                ""
            );
            owed0 += d.amount0();
            owed1 += d.amount1();
            for (uint256 i = 0; i < RUNG_COUNT; i++) {
                (d,) = poolManager.modifyLiquidity(
                    key,
                    ModifyLiquidityParams({tickLower: p.rungLower[i], tickUpper: p.rungUpper[i], liquidityDelta: int256(uint256(p.rungLiqs[i])), salt: 0}),
                    ""
                );
                owed0 += d.amount0();
                owed1 += d.amount1();
            }
            if (owed1 < 0) key.currency1.settle(poolManager, address(this), uint256(uint128(-owed1)), false);
            if (owed0 < 0) key.currency0.settle(poolManager, address(this), uint256(uint128(-owed0)), false);
            return "";
        }

        if (kind == 2) {
            (, PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liqCurve, address token) =
                abi.decode(data, (uint8, PoolKey, int24, int24, uint128, address));
                
            int24 minUsable = (TickMath.MIN_TICK / TICK_SPACING) * TICK_SPACING + TICK_SPACING;
            int24 maxUsable = (TickMath.MAX_TICK / TICK_SPACING) * TICK_SPACING - TICK_SPACING;
            uint128 liqWall = LiquidityAmounts.getLiquidityForAmount1(
                TickMath.getSqrtPriceAtTick(minUsable), TickMath.getSqrtPriceAtTick(tickLower), WALL_SUPPLY
            );

            // 1. Remove the completed curve + the BASE token wall (the rungs far above are never touched).
            //    Both burn into balances the launcher now holds: bal0 = all numeraire the curve collected,
            //    bal1 = the ~WALL_SUPPLY tokens.
            (BalanceDelta deltaCurve,) = poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: -int256(uint256(liqCurve)), salt: 0}),
                ""
            );
            (BalanceDelta deltaWall,) = poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({tickLower: minUsable, tickUpper: tickLower, liquidityDelta: -int256(uint256(liqWall)), salt: 0}),
                ""
            );
            int128 amt0 = deltaCurve.amount0() + deltaWall.amount0();
            int128 amt1 = deltaCurve.amount1() + deltaWall.amount1();
            if (amt0 > 0) key.currency0.take(poolManager, address(this), uint256(uint128(amt0)), false);
            if (amt1 > 0) key.currency1.take(poolManager, address(this), uint256(uint128(amt1)), false);

            // 2. Re-seed ONE full-range two-sided position [minUsable, maxUsable] from the collected
            //    numeraire. getLiquidityForAmounts returns min(L0,L1): the numeraire is the limiting side,
            //    so ALL of it is deployed and only the matching share of the wall's tokens goes with it.
            //    This is the position {compound} later deepens (same range + salt=0) and the indexer reads.
            uint256 bal0 = Currency.unwrap(key.currency0) == address(0)
                ? address(this).balance
                : IERC20(Currency.unwrap(key.currency0)).balanceOf(address(this));
            uint256 bal1 = IERC20(token).balanceOf(address(this));
            if (bal0 > 100) bal0 -= 100; // dust buffer so settle can never exceed the held balance

            (uint160 sqrtP, , , ) = poolManager.getSlot0(key.toId());
            uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
                sqrtP, TickMath.getSqrtPriceAtTick(minUsable), TickMath.getSqrtPriceAtTick(maxUsable), bal0, bal1
            );

            (BalanceDelta newDelta,) = poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({tickLower: minUsable, tickUpper: maxUsable, liquidityDelta: int256(uint256(liq)), salt: 0}),
                ""
            );
            if (newDelta.amount0() < 0) key.currency0.settle(poolManager, address(this), uint256(uint128(-newDelta.amount0())), false);
            uint256 tokensAdded;
            if (newDelta.amount1() < 0) {
                tokensAdded = uint256(uint128(-newDelta.amount1()));
                key.currency1.settle(poolManager, address(this), tokensAdded, false);
            }

            // 3. The full-range mint is numeraire-limited, so most of the wall's tokens are still here.
            //    Re-mint them as a single-sided wall [minUsable, wallUpper] just below the current price
            //    (a range entirely below the current tick holds only currency1 = the token). This is the
            //    pools.trade shape for the un-sold supply: it keeps turning into numeraire as the price
            //    climbs, instead of stranding in this contract. wallUpper = the current tick floored to
            //    spacing — never above the price (else the mint would demand numeraire we don't have).
            uint256 wallTokens = IERC20(token).balanceOf(address(this));
            (, int24 curTick,,) = poolManager.getSlot0(key.toId());
            int24 wallUpper = _floorToSpacing(curTick);
            if (wallUpper > maxUsable) wallUpper = maxUsable;
            uint128 liqWall2;
            if (wallTokens > 0 && wallUpper > minUsable) {
                liqWall2 = LiquidityAmounts.getLiquidityForAmount1(
                    TickMath.getSqrtPriceAtTick(minUsable), TickMath.getSqrtPriceAtTick(wallUpper), wallTokens
                );
                if (liqWall2 > 0) {
                    (BalanceDelta wd,) = poolManager.modifyLiquidity(
                        key,
                        ModifyLiquidityParams({tickLower: minUsable, tickUpper: wallUpper, liquidityDelta: int256(uint256(liqWall2)), salt: 0}),
                        ""
                    );
                    // Out of range on the token side only: the add can never owe numeraire.
                    require(wd.amount0() >= 0, "Launcher: wall in range");
                    uint256 wallIn = wd.amount1() < 0 ? uint256(uint128(-wd.amount1())) : 0;
                    if (wallIn > 0) key.currency1.settle(poolManager, address(this), wallIn, false);
                    wallTokens = wallIn;
                }
            }
            if (liqWall2 == 0) wallTokens = 0;
            wallPositions[token] = WallPosition({tickUpper: wallUpper, liquidity: liqWall2, tokens: wallTokens});
            // Rounding dust from the two mints never lingers here as a holding.
            uint256 tokenDust = IERC20(token).balanceOf(address(this));
            if (tokenDust > 0) IERC20(token).transfer(DEAD, tokenDust);

            emit Migrated(token, bal0, tokensAdded, wallTokens, wallUpper);
            return "";
        }

        // kind 1: dev buy. The numeraire is currency0, so this is always zeroForOne —
        // and settling currency0 works for native ETH (sends value) or an ERC20
        // numeraire (plain transfer, since the launcher is the payer) alike.
        (, PoolKey memory dkey, uint256 numIn, address recipient) = abi.decode(data, (uint8, PoolKey, uint256, address));
        BalanceDelta d = poolManager.swap(
            dkey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(numIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ""
        );
        int128 numLeg = d.amount0(); // negative: numeraire the launcher owes
        int128 tokLeg = d.amount1(); // positive: token out
        if (numLeg < 0) dkey.currency0.settle(poolManager, address(this), uint256(uint128(-numLeg)), false);
        if (tokLeg > 0) dkey.currency1.take(poolManager, recipient, uint256(uint128(tokLeg)), false);
        return "";
    }

    // --- price / range math (ported from the V3 launcher) ---

    function _initialSqrtPriceX96(uint256 supply, uint256 startFdv) internal pure returns (uint160) {
        // token = currency1 → price(token1/token0) = supply/startFdv.
        uint256 s = (_sqrt(supply) << 96) / _sqrt(startFdv);
        require(s >= TickMath.MIN_SQRT_PRICE && s <= TickMath.MAX_SQRT_PRICE, "Launcher: price out of range");
        return uint160(s);
    }

    function _floorToSpacing(int24 tick) internal pure returns (int24) {
        int24 r = (tick / TICK_SPACING) * TICK_SPACING;
        if (tick < 0 && tick % TICK_SPACING != 0) r -= TICK_SPACING;
        return r;
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    /// @notice Withdraw the create fees booked so far. Only the TEAM wallet may call it, and the money
    ///         goes to that same wallet — read from storage on every call, so rotating it through the
    ///         2-of-2 ({updateTeamWallet}) moves this with it and never strands what has accrued.
    ///         Its own transaction on purpose: sending ETH runs the recipient's code, which is exactly
    ///         what must not happen inside a launch (see {createFeesOwed}).
    function withdraw() external returns (uint256 paid) {
        address team = launchFeeRecipient;
        require(msg.sender == team, "Launcher: not the team wallet");
        paid = createFeesOwed;
        if (paid == 0) return 0;
        createFeesOwed = 0; // zeroed BEFORE the send: a re-entrant team wallet finds nothing left
        _sendEth(team, paid);
        emit CreateFeesWithdrawn(team, paid);
    }

    function _sendEth(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = payable(to).call{value: amount}("");
        require(ok, "Launcher: eth send failed");
    }

    // Required for poolManager.take() during migration to send ETH here (`launch()` is payable and
    // settles the manager out of its own msg.value). With no owner and no sweep, an accepted STRAY
    // transfer would be burned forever — so accept ONLY from the PoolManager and revert everything
    // else at the door, matching the intent this comment always described.
    receive() external payable {
        if (msg.sender != address(poolManager)) revert("Launcher: no bare ETH");
    }
}
