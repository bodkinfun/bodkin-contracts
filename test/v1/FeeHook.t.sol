// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {FeeHook, ICreatorNFT} from "../../src/launchpad/v1/FeeHook.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Meme", "MEME") {
        _mint(msg.sender, 1_000_000_000e18);
    }
}

/// A custom-payout token that can be frozen mid-test: once `reverting` is set, every
/// transfer reverts — a stand-in for a rugged/paused token whose pool has also died.
/// Used to prove the numeraire fallback leg still delivers when the payout-token leg can't.
contract RevertOnFlagToken is ERC20 {
    bool public reverting;

    constructor() ERC20("Rug", "RUG") {
        _mint(msg.sender, 1_000_000_000e18);
    }

    function setReverting(bool on) external {
        reverting = on;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!reverting, "RUG: transfers frozen");
        super._update(from, to, value);
    }
}

contract MockUSDC is ERC20 {
    /// Opt-in per-recipient transfer failure.
    ///
    /// The ONLY way to make a payout leg fail now that both parties are paid in an
    /// ERC20: `_deliver` settles through `PoolManager.take`, which is a plain token
    /// transfer with no callback, so a "rejecting" RECIPIENT contract cannot refuse
    /// anything. The refusal has to live in the token. Real ones do this too — every
    /// blocklisting stablecoin, USDC included.
    mapping(address => bool) public rejects;

    constructor() ERC20("Mock USD Coin", "mUSDC") {
        _mint(msg.sender, 1e30);
    }

    function setRejects(address who, bool on) external {
        rejects[who] = on;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!rejects[to], "mUSDC: recipient blocked");
        super._update(from, to, value);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @dev Minimal WETH9 for the suite: `deposit()` (and `receive`) mint WETH 1:1 for native ETH,
///      `withdraw` burns it back. Lets a test stand up a V4 (WETH, token) payout pool.
contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amt) external {
        _burn(msg.sender, amt);
        (bool ok,) = msg.sender.call{value: amt}("");
        require(ok, "weth: withdraw");
    }
}

contract MockCreatorNFT is ICreatorNFT {
    mapping(address => address) internal _owner;

    function set(address token, address who) external {
        _owner[token] = who;
    }

    function creatorOf(address token) external view returns (address) {
        return _owner[token];
    }
}

/// @notice A liquidity router that ALSO answers `curvePositions`, so it can stand in as a launch's
///         launcher. Liquidity it adds is therefore seen by the hook with `sender == launcher` and is
///         excluded from external-LP tracking — exactly like the coin's own locked curve position in
///         production. Used to exercise the "no external LP" fee-fold path.
contract MockLauncherLP is PoolModifyLiquidityTest {
    constructor(IPoolManager _manager) PoolModifyLiquidityTest(_manager) {}

    function curvePositions(address) external pure returns (int24, int24, uint128, bool) {
        return (0, 0, 0, false); // tickLower == 0 → trading never frozen
    }
}

/// @notice A liquidity router standing in for the v4 PositionManager: liquidity it adds is tracked by
///         the hook under (token, this, salt = tokenId), and `ownerOf` answers who a position's reward
///         is paid to — the two things {claimLpRewards} needs from the real one.
contract MockPositionManager is PoolModifyLiquidityTest {
    mapping(uint256 => address) public owners;

    constructor(IPoolManager _manager) PoolModifyLiquidityTest(_manager) {}

    /// The PoolManager it is bound to — what the real one exposes through ImmutableState.
    function poolManager() external view returns (IPoolManager) {
        return manager;
    }

    function setOwner(uint256 id, address who) external {
        owners[id] = who;
    }

    /// Some ERC-721s answer address(0) for a burned id instead of reverting (solmate, the canonical
    /// PositionManager, reverts). Off by default.
    bool public zeroOnMissing;

    function setZeroOnMissing(bool on) external {
        zeroOnMissing = on;
    }

    function ownerOf(uint256 id) external view returns (address) {
        if (owners[id] == address(0) && zeroOnMissing) return address(0);
        require(owners[id] != address(0), "no such position");
        return owners[id];
    }

    /// The account driving the current action (the real PositionManager's locker).
    address public msgSender;

    /// Burn exactly like v4-periphery's PositionManager: the NFT is burned FIRST, the liquidity is
    /// removed AFTER — so the hook's remove callback runs when `ownerOf` already reverts.
    function burn(uint256 id, PoolKey calldata key, int24 tickLower, int24 tickUpper, uint128 liquidity) external {
        require(owners[id] == msg.sender, "not owner");
        msgSender = msg.sender;
        delete owners[id];
        this.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: -int256(uint256(liquidity)), salt: bytes32(id)}),
            ""
        );
        msgSender = address(0);
    }
}

/// @notice A contract bound to our PoolManager whose owner reads are MALFORMED: `ownerOf` always reverts
///         and every other selector (so `msgSender()`) hits a fallback that "succeeds" with empty data, or
///         with a word that is not a clean address. A high-level try/catch cannot catch the resulting
///         decode failure, so the hook must read owners without ever reverting.
contract MalformedPositionManager is PoolModifyLiquidityTest {
    bool public dirtyWord;

    constructor(IPoolManager _manager) PoolModifyLiquidityTest(_manager) {}

    function poolManager() external view returns (IPoolManager) {
        return manager;
    }

    function setDirtyWord(bool on) external {
        dirtyWord = on;
    }

    function ownerOf(uint256) external pure returns (address) {
        revert("gone");
    }

    fallback() external {
        if (dirtyWord) {
            assembly {
                mstore(0x00, not(0))
                return(0x00, 0x20)
            }
        }
        assembly {
            return(0x00, 0x00)
        }
    }
}

/// @notice FeeHook: the 1% platform fee must always land in ETH (never the meme
///         token) on buys and sells, split 70/10/20, and be pull-claimed — paid in
///         USDC by default (creator may opt into ETH).
contract FeeHookTest is Test {
    PoolManager manager;
    PoolModifyLiquidityTest lp;
    PoolSwapTest swapRouter;
    FeeHook hook;
    MockToken token;
    MockToken bodkin;
    PoolKey bodkinPoolKey;
    MockUSDC usdc;
    MockWETH weth9;
    MockCreatorNFT creatorNFT;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address creator = address(0xC0FFEE);
    address team = address(0x7EA);

    PoolKey key; // (ETH, meme) with our hook
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    int24 constant TICK_SPACING = 60;
    /// Canonical tier for every CONVERSION pool in this suite (0.3% / 60).
    ///
    /// Not cosmetic: the fee is what sizes a safe conversion chunk (`fee x depth`), so a
    /// fee-free route has no safe size and converts NOTHING, forever. `setUsdcPool` and
    /// `setBodkinPool` both refuse fee 0 for exactly that reason, and 0 was never a
    /// canonical tier anyway — CanonicalTiers allows only 100/500/3000/10000.
    /// The LAUNCH pools stay at fee 0: there the hook itself is the fee.
    uint24 constant PAYOUT_FEE = 3000;

    /// Launcher stand-in for FeeHook._beforeSwap's TradingFrozen gate: it calls
    /// `curvePositions(token)` on the launcher (us). This suite never exercises the curve/freeze
    /// path, so report every token as open — tickLower == 0 short-circuits the freeze check. Added
    /// because _beforeSwap began calling this when the curve+migration freeze landed; without it
    /// every swap in this suite reverts inside beforeSwap (HookCallFailed).
    function curvePositions(address) external pure returns (int24, int24, uint128, bool) {
        return (0, 0, 0, false);
    }

    function setUp() public {
        vm.deal(address(this), 10_000 ether);
        manager = new PoolManager(address(this));
        lp = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);
        token = new MockToken();
        usdc = new MockUSDC();
        creatorNFT = new MockCreatorNFT();
        // Wrapped ETH is a constructor arg now (mined into the hook's CREATE2 address), so it must
        // exist before the hook. It lets a launch pay out a token whose liquidity is a V4 WETH pool
        // (the hook wraps native ETH -> WETH to convert into it). See _openWethPool.
        weth9 = new MockWETH();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );
        bytes memory args = abi.encode(
            IPoolManager(address(manager)),
            ICreatorNFT(address(creatorNFT)),
            team,
            address(usdc),
            address(weth9),
            address(this)
        );
        (address hookAddr, bytes32 salt) = HookMiner.find(address(this), flags, type(FeeHook).creationCode, args);
        hook = new FeeHook{salt: salt}(
            IPoolManager(address(manager)),
            ICreatorNFT(address(creatorNFT)),
            team,
            address(usdc),
            address(weth9),
            address(this)
        );
        require(address(hook) == hookAddr, "hook addr mismatch");

        creatorNFT.set(address(token), creator);
        // This test stands in for the launcher, so it can record launch configs (the
        // hook only accepts them from the launcher, once per launch) and open pools.
        hook.setLauncher(address(this));
        // Default config for the main token: ETH-quoted pool, USDC payout.
        hook.setLaunchConfig(address(token), address(usdc), false, false, 0, 0, address(0), false, 0, 0, false);

        // (native ETH, meme) pool with our fee hook. LP fee 0 — the hook is the fee.
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, SQRT_PRICE_1_1);
        token.approve(address(lp), type(uint256).max);
        _addLiquidity(key, 50e18, 200 ether);
        token.approve(address(swapRouter), type(uint256).max);

        // (native ETH, USDC) conversion pool — PLAIN (no hook) — wired into the hook.
        PoolKey memory usdcKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(usdc)),
            fee: 3000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        manager.initialize(usdcKey, SQRT_PRICE_1_1);
        usdc.approve(address(lp), type(uint256).max);
        _addLiquidity(usdcKey, 10e18, 200 ether);
        hook.setUsdcPool(usdcKey);

        // (native ETH, BODKIN) pool for the burn bucket's buy&burn.
        //
        // 0.3%, NOT the fee-free tier the other test pools use: the hook refuses to wire
        // a zero-fee BODKIN pool, because the pool fee is what makes a bounded burn chunk
        // unprofitable to sandwich. This suite previously built it at fee 0 — the exact
        // configuration the audit found would let a sandwicher take ~99% of every bucket.
        bodkin = new MockToken();
        PoolKey memory bodkinKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(bodkin)),
            fee: 3000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        bodkinPoolKey = bodkinKey;
        manager.initialize(bodkinKey, SQRT_PRICE_1_1);
        bodkin.approve(address(lp), type(uint256).max);
        _addLiquidity(bodkinKey, 10e18, 200 ether);
        hook.setBodkinPool(bodkinKey);
    }

    function _addLiquidity(PoolKey memory k, int256 liq, uint256 ethValue) internal {
        lp.modifyLiquidity{value: ethValue}(
            k,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: liq,
                salt: 0
            }),
            ""
        );
    }

    /// Open a plain (native ETH, `t`) pool and seed it — the direct custom-payout route.
    function _openEthPool(address t, int256 liq) internal returns (PoolKey memory k) {
        k = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(t),
            fee: PAYOUT_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        manager.initialize(k, SQRT_PRICE_1_1);
        ERC20(t).approve(address(lp), type(uint256).max);
        _addLiquidity(k, liq, 200 ether);
    }

    /// Open a plain (USDC, `t`) pool and seed it — the second leg of the via-USDC
    /// route. Currencies are sorted as V4 requires, so `t` may land on either side.
    function _openUsdcPool(address t, int256 liq) internal returns (PoolKey memory k) {
        (address c0, address c1) = address(usdc) < t ? (address(usdc), t) : (t, address(usdc));
        k = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: PAYOUT_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        manager.initialize(k, SQRT_PRICE_1_1);
        usdc.approve(address(lp), type(uint256).max);
        ERC20(t).approve(address(lp), type(uint256).max);
        _addLiquidity(k, liq, 0); // ERC20/ERC20 — no ETH value
    }

    /// Open a plain (WETH, `t`) V4 pool and seed it — the WETH-paired custom-payout route.
    /// Both sides are ERC20 (WETH minted 1:1 from ETH), sorted as V4 requires.
    function _openWethPool(address t, int256 liq) internal returns (PoolKey memory k) {
        (address c0, address c1) = address(weth9) < t ? (address(weth9), t) : (t, address(weth9));
        k = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: PAYOUT_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        manager.initialize(k, SQRT_PRICE_1_1);
        weth9.deposit{value: 300 ether}(); // WETH for the LP side
        weth9.approve(address(lp), type(uint256).max);
        ERC20(t).approve(address(lp), type(uint256).max);
        _addLiquidity(k, liq, 0); // ERC20/ERC20 — no native ETH value
    }

    /// A launch whose creator payout is WETH-paired (its token trades in a V4 (WETH, token)
    /// pool). ETH numeraire, wethPaired = true.
    function _newLaunchWethPaid(address payoutToken) internal returns (MockToken meme, PoolKey memory k) {
        meme = new MockToken();
        creatorNFT.set(address(meme), creator);
        hook.setLaunchConfig(address(meme), payoutToken, false, true, PAYOUT_FEE, TICK_SPACING, address(0), false, 0, 0, false);
        k = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(meme)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        manager.initialize(k, SQRT_PRICE_1_1);
        meme.approve(address(lp), type(uint256).max);
        _addLiquidity(k, 50e18, 200 ether);
    }

    /// Deploy MockTokens until one sorts on the requested side of USDC, so the
    /// via-USDC leg can be exercised with USDC as currency0 AND as currency1.
    function _tokenSortedVsUsdc(bool wantAboveUsdc) internal returns (MockToken t) {
        for (uint256 i = 0; i < 200; i++) {
            t = new MockToken();
            if ((address(t) > address(usdc)) == wantAboveUsdc) return t;
        }
        revert("no token on that side of usdc");
    }

    /// A fresh "launch": a meme token + its hooked (ETH, meme) pool, creator-owned.
    function _newLaunch() internal returns (MockToken meme, PoolKey memory k) {
        return _newLaunchWith(address(usdc), false, 0, 0, address(0), address(0));
    }

    /// A fresh launch with an explicit payout config + numeraire. The config is
    /// recorded BEFORE the pool is opened, exactly as the launcher does it.
    /// @param nftHolder wallet the fee NFT is minted to; address(0) = the default
    ///        `creator`. Stands in for `LauncherV1` minting to `payout.feeRecipient` —
    ///        which is now the ONLY way a fee stream points somewhere other than the
    ///        launching wallet.
    function _newLaunchWith(
        address payoutToken,
        bool viaHub,
        uint24 fee,
        int24 tickSpacing,
        address nftHolder,
        address numeraire
    ) internal returns (MockToken meme, PoolKey memory k) {
        meme = new MockToken();
        creatorNFT.set(address(meme), nftHolder != address(0) ? nftHolder : creator);
        hook.setLaunchConfig(address(meme), payoutToken, viaHub, false, fee, tickSpacing, numeraire, false, 0, 0, false);
        k = PoolKey({
            currency0: Currency.wrap(numeraire),
            currency1: Currency.wrap(address(meme)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        manager.initialize(k, SQRT_PRICE_1_1);
        meme.approve(address(lp), type(uint256).max);
        _addLiquidity(k, 50e18, 200 ether);
    }

    /// A second FeeHook at its own mined address, wired only as far as the launcher —
    /// no USDC pool, no BODKIN pool. Used to prove the burn's failure modes are inert.
    function _deployHook() internal returns (FeeHook fresh) {
        return _deployHookWithLauncher(address(this));
    }

    /// Same as {_deployHook} but wires the launcher to `launcher_`. Pointing it at the `lp`
    /// liquidity router makes that router's adds count as the LAUNCHER's own position — excluded
    /// from external-LP tracking, exactly like the coin's locked curve position in production.
    function _deployHookWithLauncher(address launcher_) internal returns (FeeHook fresh) {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );
        bytes memory args = abi.encode(
            IPoolManager(address(manager)),
            ICreatorNFT(address(creatorNFT)),
            team,
            address(usdc),
            address(weth9),
            address(this)
        );
        // Salt-namespaced by a nonce so repeated calls in one test mine distinct addresses.
        (address addr, bytes32 salt) = HookMiner.find(address(this), flags, type(FeeHook).creationCode, args);
        fresh = new FeeHook{salt: salt}(
            IPoolManager(address(manager)),
            ICreatorNFT(address(creatorNFT)),
            team,
            address(usdc),
            address(weth9),
            address(this)
        );
        require(address(fresh) == addr, "fresh hook addr mismatch");
        fresh.setLauncher(launcher_);
    }

    /// Wire an (ETH, mock-BODKIN) venue on `h` with NO liquidity, so the split under test is the
    /// nominal one AND stays observable. Two things at once: the hook routes the burn slice to the
    /// creator while no venue is wired at all (the BODKIN dev-buy case, see `_accrue`), so a split
    /// test that wants to see the 10% burn bucket must wire one; and an empty venue makes the safe
    /// burn chunk (fee × depth) zero, so the bucket is booked but never spent in-swap — a deep venue
    /// would buy-and-burn it right away and the assertions would read 0.
    function _wireBodkinPool(FeeHook h) internal returns (MockToken b) {
        b = new MockToken();
        PoolKey memory bk = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(b)),
            fee: 3000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        manager.initialize(bk, SQRT_PRICE_1_1);
        h.setBodkinPool(bk);
    }

    /// A launch on a hook whose BODKIN pool was never wired, so every burn attempt fails.
    function _freshHookWithoutBodkinPool() internal returns (FeeHook fresh, MockToken meme, PoolKey memory k) {
        fresh = _deployHook();
        (meme, k) = _launchOn(fresh);
    }

    /// A launch on a fresh hook whose BODKIN pool has `bodkinLiq` of liquidity.
    ///
    /// The liquidity is the point: the safe burn chunk is `fee × depth`, so a THIN pool
    /// makes the cap small enough that a normal bucket exceeds it and the chunking is
    /// observable. The main `setUp` pool is deep enough that a test-sized bucket always
    /// fits in one chunk, which is the correct behaviour but tests nothing.
    function _freshHookWithBodkinPool(int256 bodkinLiq)
        internal
        returns (FeeHook fresh, MockToken meme, PoolKey memory k, MockToken b)
    {
        fresh = _deployHook();
        b = new MockToken();
        PoolKey memory bk = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(b)),
            fee: 3000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        manager.initialize(bk, SQRT_PRICE_1_1);
        b.approve(address(lp), type(uint256).max);
        _addLiquidity(bk, bodkinLiq, 200 ether);
        fresh.setBodkinPool(bk);
        (meme, k) = _launchOn(fresh);
    }

    function _launchOn(FeeHook h) internal returns (MockToken meme, PoolKey memory k) {
        return _launchOnWith(h, false, 0);
    }

    /// A launch on `h` with an explicit autocompound toggle and custom creator fee. Seeds the pool
    /// via the `lp` router; on a hook whose launcher is the test contract that seed counts as an
    /// EXTERNAL full-range provider (so the 25% LP slice banks). The launch config is set from the
    /// hook's launcher — `address(this)` here, matching the default `_deployHook`.
    function _launchOnWith(FeeHook h, bool acOff, uint16 creatorFeeBps)
        internal
        returns (MockToken meme, PoolKey memory k)
    {
        return _launchOnWith(h, acOff, creatorFeeBps, 0);
    }

    /// As above, plus an explicit custom LP fee.
    function _launchOnWith(FeeHook h, bool acOff, uint16 creatorFeeBps, uint16 lpFeeBps)
        internal
        returns (MockToken meme, PoolKey memory k)
    {
        return _launchOnWith(h, acOff, creatorFeeBps, lpFeeBps, false);
    }

    /// As above, plus the LP-rewards-off toggle.
    function _launchOnWith(FeeHook h, bool acOff, uint16 creatorFeeBps, uint16 lpFeeBps, bool lpRewardsOff)
        internal
        returns (MockToken meme, PoolKey memory k)
    {
        meme = new MockToken();
        creatorNFT.set(address(meme), creator);
        h.setLaunchConfig(
            address(meme), address(usdc), false, false, 0, 0, address(0), acOff, creatorFeeBps, lpFeeBps, lpRewardsOff
        );
        k = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(meme)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(h))
        });
        manager.initialize(k, SQRT_PRICE_1_1);
        meme.approve(address(lp), type(uint256).max);
        _addLiquidity(k, 10e18, 200 ether);
    }

    function _buyOn(PoolKey memory k, uint256 amountInEth) internal {
        swapRouter.swap{value: amountInEth}(
            k,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amountInEth),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// Buy on a USDC-QUOTED launch pool, paying in USDC. No `{value:}` — the router
    /// pulls the ERC20 — which is why the ETH helper above cannot serve these pools,
    /// and why the suite had no way to exercise a USDC-quoted launch that actually
    /// trades. That gap is what let a pair of inverted unit conversions sit in the
    /// venue budget with all 92 tests green.
    function _buyOnWithUsdc(PoolKey memory k, uint256 amountInUsdc) internal {
        usdc.approve(address(swapRouter), amountInUsdc);
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: true, // USDC is currency0 of a USDC-quoted launch pool
                amountSpecified: -int256(amountInUsdc),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _buy(uint256 amountInEth) internal {
        swapRouter.swap{value: amountInEth}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amountInEth),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _sell(uint256 amountInToken) internal {
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(amountInToken),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// The split, measured on a hook whose BODKIN pool is not wired.
    ///
    /// It has to be measured there, because on a live hook the 10% burn slice does not
    /// SIT in `burnWei` — the same swap that accrues it already spends it on BODKIN, which
    /// is the whole point of the keeper-less design. Reading the buckets after a swap
    /// therefore shows 90%, and asserting 100% would be asserting that the buyback does
    /// not work. `test_TheBurnAdvancesOnItsOwnWithEverySwap` covers the other half.
    function test_BuyTakesFeeInEth() public {
        FeeHook h = _deployHook();
        _wireBodkinPool(h);
        (MockToken meme, PoolKey memory k) = _launchOn(h);
        uint256 amountIn = 1 ether;
        _buyOn(k, amountIn);

        uint256 expectedFee = (amountIn * 100) / 10_000; // 1% of the ETH input
        // The pool's seed liquidity was added by the test's lp router (an EXTERNAL, full-range provider),
        // so the 25% LP slice is banked for LP claims and the fee-growth accumulator advances — it does
        // NOT fold into autocompound (the no-provider fold is the simple `else` in _accrue).
        uint256 total = h.creatorWei(address(meme)) + h.burnWei(address(meme)) + h.teamWei(address(meme))
            + h.autocompoundWei(address(meme)) + h.lpBankWei(address(meme));
        assertEq(total, expectedFee, "total fee = 1% of ETH input");
        assertEq(h.creatorWei(address(meme)), (expectedFee * 3500) / 10_000, "creator 35%");
        assertEq(h.burnWei(address(meme)), (expectedFee * 1000) / 10_000, "burn 10%");
        assertEq(h.teamWei(address(meme)), (expectedFee * 2000) / 10_000, "team 20%");
        assertEq(h.autocompoundWei(address(meme)), (expectedFee * 1000) / 10_000, "autocompound 10%");
        assertEq(h.lpBankWei(address(meme)), (expectedFee * 2500) / 10_000, "LP 25% banked for external providers");
        assertGt(h.lpLiquidity(address(meme)), 0, "external full-range seed is tracked");
        assertGt(h.lpFeeGrowthGlobalX128(address(meme)), 0, "fee-growth accumulator advanced");
    }

    /// A per-coin custom creator fee is charged ON TOP of the base 1% and lands 100% in the creator
    /// bucket — the base split (team/burn/LP/autocompound) still comes ONLY off the 1%.
    function test_CustomCreatorFeeIsChargedOnTopAndAllToCreator() public {
        FeeHook h = _deployHook(); // launcher == test contract → the `lp` seed is external, LP slice banks
        _wireBodkinPool(h);
        (MockToken meme, PoolKey memory k) = _launchOnWith(h, false, 300); // +3% custom creator fee
        _buyOn(k, 1 ether);

        uint256 baseFee = (1 ether * 100) / 10_000; // 1%
        uint256 totalFee = (1 ether * 400) / 10_000; // 1% + 3%
        uint256 customFee = totalFee - baseFee; // the 3%, all to the creator

        assertEq(
            h.creatorWei(address(meme)),
            (baseFee * 3500) / 10_000 + customFee,
            "creator = base 35% + 100% of the custom 3%"
        );
        assertEq(h.teamWei(address(meme)), (baseFee * 2000) / 10_000, "team off the base 1% only");
        assertEq(h.burnWei(address(meme)), (baseFee * 1000) / 10_000, "burn off the base 1% only");
        assertEq(h.lpBankWei(address(meme)), (baseFee * 2500) / 10_000, "LP off the base 1% only");
        assertEq(h.autocompoundWei(address(meme)), (baseFee * 1000) / 10_000, "autocompound off the base 1% only");
        uint256 total = h.creatorWei(address(meme)) + h.burnWei(address(meme)) + h.teamWei(address(meme))
            + h.autocompoundWei(address(meme)) + h.lpBankWei(address(meme));
        assertEq(total, totalFee, "the full base+custom (4%) was skimmed");
    }

    /// Autocompound OFF (creator's launch choice): the 10% autocompound slice rolls into the creator
    /// cut instead of compounding the coin's own pool. The external LP slice is unaffected.
    function test_AutocompoundOffRoutesSliceToCreator() public {
        FeeHook h = _deployHook();
        _wireBodkinPool(h);
        (MockToken meme, PoolKey memory k) = _launchOnWith(h, true, 0); // autocompound OFF
        _buyOn(k, 1 ether);

        uint256 baseFee = (1 ether * 100) / 10_000;
        assertEq(h.creatorWei(address(meme)), (baseFee * 4500) / 10_000, "creator 35% + autocompound 10% = 45%");
        assertEq(h.autocompoundWei(address(meme)), 0, "nothing compounds when off");
        assertEq(h.lpBankWei(address(meme)), (baseFee * 2500) / 10_000, "external LP slice 25% still banks");
        assertEq(h.teamWei(address(meme)), (baseFee * 2000) / 10_000, "team 20%");
        assertEq(h.burnWei(address(meme)), (baseFee * 1000) / 10_000, "burn 10%");
    }

    /// With NO external LP tracked (only the launcher's own locked position), the 25% LP slice folds
    /// into the CREATOR cut — her choice: reward the creator when there is no third-party liquidity.
    function test_NoExternalLpFoldsLpSliceIntoCreator() public {
        // A launcher that also seeds the pool. Its adds are seen with `sender == launcher`, so they are
        // EXCLUDED from external-LP tracking (the coin's own locked position, as in production).
        MockLauncherLP mlp = new MockLauncherLP(IPoolManager(address(manager)));
        FeeHook h = _deployHookWithLauncher(address(mlp));
        _wireBodkinPool(h);
        MockToken meme = new MockToken();
        creatorNFT.set(address(meme), creator);
        vm.prank(address(mlp));
        h.setLaunchConfig(address(meme), address(usdc), false, false, 0, 0, address(0), false, 0, 0, false);
        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(meme)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(h))
        });
        vm.prank(address(mlp));
        manager.initialize(k, SQRT_PRICE_1_1); // beforeInitialize requires sender == launcher
        meme.approve(address(mlp), type(uint256).max);
        // Seed through the launcher itself → sender == launcher → NOT tracked as external LP.
        mlp.modifyLiquidity{value: 200 ether}(
            k,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: 10e18,
                salt: 0
            }),
            ""
        );
        assertEq(h.lpLiquidity(address(meme)), 0, "the launcher's own position is not external LP");

        _buyOn(k, 1 ether);
        uint256 baseFee = (1 ether * 100) / 10_000;
        assertEq(h.creatorWei(address(meme)), (baseFee * 6000) / 10_000, "creator 35% + folded LP 25% = 60%");
        assertEq(h.lpBankWei(address(meme)), 0, "nothing banked for LPs");
        assertEq(h.lpFeeGrowthGlobalX128(address(meme)), 0, "accumulator never advanced");
        assertEq(h.autocompoundWei(address(meme)), (baseFee * 1000) / 10_000, "autocompound stays 10%");
        assertEq(h.teamWei(address(meme)), (baseFee * 2000) / 10_000, "team 20%");
        assertEq(h.burnWei(address(meme)), (baseFee * 1000) / 10_000, "burn 10%");
    }

    /// Add an external position on ANY range through the test LP router (sender = `lp`, salt = `salt`).
    function _addRange(PoolKey memory k, int24 lower, int24 upper, int256 liq, bytes32 salt, uint256 ethValue) internal {
        lp.modifyLiquidity{value: ethValue}(
            k, ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: liq, salt: salt}), ""
        );
    }

    function _owedOf(FeeHook h, address meme, bytes32 salt) internal view returns (uint256 owed) {
        (,,, owed) = h.lpPosition(meme, address(lp), salt);
    }

    /// Range-aware LP rewards: a concentrated position that CONTAINS the price earns the LP slice
    /// pro-rata with the full-range one (same liquidity → same numeraire); a position parked ABOVE the
    /// price (never in range on buys) earns nothing, and the active total counts only in-range liquidity.
    function test_ConcentratedLpEarnsProRataWhileInRange() public {
        FeeHook h = _deployHook(); // launcher == this test → the `lp` seeds are EXTERNAL (tracked)
        (MockToken meme, PoolKey memory k) = _launchOnWith(h, false, 0); // full-range 10e18 at salt 0, tick 0
        int24 S = TICK_SPACING;
        _addRange(k, -10 * S, 10 * S, 10e18, bytes32(uint256(1)), 5 ether); // around the price
        _addRange(k, 100 * S, 200 * S, 10e18, bytes32(uint256(2)), 5 ether); // far above it
        assertEq(h.lpLiquidity(address(meme)), 20e18, "active = full-range + the in-range position");

        _buyOn(k, 0.01 ether); // tiny: the tick stays inside [-600, 600]
        uint256 full = _owedOf(h, address(meme), bytes32(0));
        uint256 near = _owedOf(h, address(meme), bytes32(uint256(1)));
        uint256 far = _owedOf(h, address(meme), bytes32(uint256(2)));
        assertGt(full, 0, "full-range earned");
        assertApproxEqAbs(near, full, 2, "same liquidity, both in range -> same share");
        assertEq(far, 0, "out-of-range position earns nothing");
        uint256 lpSlice = ((0.01 ether * 100) / 10_000 * 2500) / 10_000;
        assertApproxEqAbs(full + near, lpSlice, 4, "the whole LP slice went to the two active positions");
    }

    /// Once the price leaves a concentrated range, that position stops accruing and the full-range one
    /// takes the whole slice; the crossing is applied by the swap itself (afterSwap), not by a claim.
    function test_ConcentratedLpStopsEarningWhenPriceLeavesItsRange() public {
        FeeHook h = _deployHook();
        (MockToken meme, PoolKey memory k) = _launchOnWith(h, false, 0);
        int24 S = TICK_SPACING;
        _addRange(k, -10 * S, 10 * S, 10e18, bytes32(uint256(1)), 5 ether);

        _buyOn(k, 1 ether); // big enough to push the tick well below -600 (see the liquidity scale)
        (, int24 tick,,) = StateLibrary.getSlot0(IPoolManager(address(manager)), PoolIdLibrary.toId(k));
        assertLt(tick, -10 * S, "price left the concentrated range");
        assertEq(h.lpLiquidity(address(meme)), 10e18, "only the full-range position is active now");

        uint256 nearBefore = _owedOf(h, address(meme), bytes32(uint256(1)));
        uint256 fullBefore = _owedOf(h, address(meme), bytes32(0));
        assertGt(nearBefore, 0, "it earned its share on the way through");
        _buyOn(k, 0.01 ether);
        assertEq(_owedOf(h, address(meme), bytes32(uint256(1))), nearBefore, "out of range: no more accrual");
        uint256 lpSlice = ((0.01 ether * 100) / 10_000 * 2500) / 10_000;
        assertApproxEqAbs(_owedOf(h, address(meme), bytes32(0)) - fullBefore, lpSlice, 2, "full-range takes it all");
    }

    /// Removing an out-of-range position keeps what it earned and never disturbs the active total.
    function test_ConcentratedLpRemoveKeepsEarnedAndActiveTotal() public {
        FeeHook h = _deployHook();
        (MockToken meme, PoolKey memory k) = _launchOnWith(h, false, 0);
        int24 S = TICK_SPACING;
        _addRange(k, -10 * S, 10 * S, 10e18, bytes32(uint256(1)), 5 ether);
        _buyOn(k, 0.01 ether); // in range: earns
        uint256 earned = _owedOf(h, address(meme), bytes32(uint256(1)));
        assertGt(earned, 0);
        _buyOn(k, 1 ether); // now out of range
        _addRange(k, -10 * S, 10 * S, -10e18, bytes32(uint256(1)), 0); // withdraw it
        (,, uint128 liq, uint256 owed) = h.lpPosition(address(meme), address(lp), bytes32(uint256(1)));
        assertEq(liq, 0, "untracked after the remove");
        assertGe(owed, earned, "the earned numeraire stays claimable");
        assertEq(h.lpLiquidity(address(meme)), 10e18, "active total untouched (it was out of range)");
    }

    /// A swap that sweeps across MANY external ranges must apply every crossing it passes, in order,
    /// and leave the active-liquidity total the live tick implies. That total is the denominator the
    /// whole LP reward program divides by, so a crossing skipped or applied twice mis-pays everyone —
    /// and it is exactly what the walk over the tick book maintains. The ranges here OVERLAP and are
    /// strided over more than two bitmap words, so the total changes as the price moves and the walk
    /// has to step from word to word; the price is driven up through them and back down, so both
    /// directions run. There is also no cap on how many boundaries a coin may hold any more: 40 ranges
    /// is 80 of them, well past the 64 the old sorted-array book could hold at all.
    function test_SweepingManyRangesKeepsTheActiveLiquidityExact() public {
        FeeHook h = _deployHook();
        (MockToken meme, PoolKey memory k) = _launchOnWith(h, false, 0);
        // A first buy funds this contract with the token (so it can sell) and settles a starting price.
        _buyOn(k, 5 ether);
        uint256 baseline = h.lpLiquidity(address(meme)); // the seeded full-range position, always in range

        int24[] memory lower = new int24[](40);
        int24 width = 8 * TICK_SPACING;
        // Sized against the position already in the book: a sliver would round its share of the slice to
        // zero and the earnings assertion below would prove nothing.
        uint128 each = uint128(baseline / 20);
        vm.deal(address(this), 10_000 ether);
        (, int24 start,,) = StateLibrary.getSlot0(IPoolManager(address(manager)), PoolIdLibrary.toId(k));
        int24 base = (start / TICK_SPACING) * TICK_SPACING - 32 * TICK_SPACING;
        for (uint256 i = 0; i < lower.length; i++) {
            // Stride 16 spacings over 40 ranges spreads them across ~640 of them — more than two bitmap
            // words — and the first few straddle the starting price, so the total is live from the start.
            lower[i] = base + int24(uint24(i)) * 16 * TICK_SPACING;
            _addRange(k, lower[i], lower[i] + width, int256(uint256(each)), bytes32(i + 1000), 20 ether);
        }

        uint256 live; // checkpoints where at least one range held the price — a guard against a vacuous test
        live += _expectActiveLiquidity(h, meme, k, lower, width, each, baseline, "after the adds");
        _sellOn(k, meme.balanceOf(address(this)) / 8);
        live += _expectActiveLiquidity(h, meme, k, lower, width, each, baseline, "after a sweep up");
        _buyOn(k, 0.5 ether);
        live += _expectActiveLiquidity(h, meme, k, lower, width, each, baseline, "after a step back down");
        _buyOn(k, 4 ether);
        live += _expectActiveLiquidity(h, meme, k, lower, width, each, baseline, "after sweeping down");
        // The price now RESTS inside one of the ranges, which is what makes the next trade pay it: a buy
        // credits the LP slice against the liquidity active at the tick it starts from.
        _buyOn(k, 0.1 ether);
        live += _expectActiveLiquidity(h, meme, k, lower, width, each, baseline, "after a trade from inside a range");
        assertGt(live, 0, "the price must have been inside at least one range, or this test proves nothing");

        // And the book really is paying what it tracked.
        uint256 paid;
        for (uint256 i = 0; i < lower.length; i++) {
            (,,, uint256 owed) = h.lpPosition(address(meme), address(lp), bytes32(i + 1000));
            paid += owed;
        }
        assertGt(paid, 0, "ranges that held the price earned");
        assertLe(paid, h.lpBankWei(address(meme)), "the book never owes more than it banked");
    }

    /// The hook's active external liquidity must equal the sum of the positions whose range contains the
    /// live tick — recomputed here from the pool, not from the hook, so a wrong crossing cannot hide.
    /// Returns 1 when at least one range was in range, so the caller can prove it measured something.
    function _expectActiveLiquidity(
        FeeHook h,
        MockToken meme,
        PoolKey memory k,
        int24[] memory lower,
        int24 width,
        uint128 each,
        uint256 baseline,
        string memory what
    ) internal view returns (uint256 live) {
        (, int24 tick,,) = StateLibrary.getSlot0(IPoolManager(address(manager)), PoolIdLibrary.toId(k));
        uint256 expected = baseline;
        for (uint256 i = 0; i < lower.length; i++) {
            if (tick >= lower[i] && tick < lower[i] + width) {
                expected += each;
                live = 1;
            }
        }
        assertEq(h.lpLiquidity(address(meme)), expected, what);
    }

    /// The convention the whole book rests on: moving UP, a tick the price comes to rest exactly ON is
    /// crossed. It is one comparison in the walk, it is invisible in any test whose price stops between
    /// ticks, and getting it wrong leaves the active-liquidity total permanently off by that tick's net.
    /// Driving a sell into a price limit set exactly at the boundary is the only way to land on it.
    function test_ATickThePriceLandsExactlyOnIsCrossed() public {
        FeeHook h = _deployHook();
        (MockToken meme, PoolKey memory k) = _launchOnWith(h, false, 0);
        _buyOn(k, 5 ether);
        vm.deal(address(this), 10_000 ether);

        (, int24 startTick,,) = StateLibrary.getSlot0(IPoolManager(address(manager)), PoolIdLibrary.toId(k));
        int24 target = ((startTick / TICK_SPACING) * TICK_SPACING) + 20 * TICK_SPACING; // a boundary above the price
        uint256 baseline = h.lpLiquidity(address(meme));
        uint128 each = uint128(baseline / 20);
        _addRange(k, target, target + 4 * TICK_SPACING, int256(uint256(each)), bytes32(uint256(4242)), 20 ether);
        assertEq(h.lpLiquidity(address(meme)), baseline, "the range starts above the price, so not yet active");

        // A sell is not subject to the hook's partial-fill guard, so it may stop at a price limit.
        MockToken(Currency.unwrap(k.currency1)).approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(meme.balanceOf(address(this)) / 2),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(target)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        (, int24 endTick,,) = StateLibrary.getSlot0(IPoolManager(address(manager)), PoolIdLibrary.toId(k));
        assertEq(endTick, target, "the swap stopped exactly on the boundary");
        assertEq(h.lpLiquidity(address(meme)), baseline + each, "landing on a tick counts as crossing it");
    }

    /// Two one-spacing ranges sharing no boundary, swept in both directions: the walk has to cross four
    /// ticks in the right order and undo them in reverse. An off-by-one at either bound shows up here.
    function test_AdjacentOneSpacingRangesSurviveASweepBothWays() public {
        FeeHook h = _deployHook();
        (MockToken meme, PoolKey memory k) = _launchOnWith(h, false, 0);
        _buyOn(k, 5 ether);
        vm.deal(address(this), 10_000 ether);

        uint256 baseline = h.lpLiquidity(address(meme));
        uint128 each = uint128(baseline / 20);
        (, int24 startTick,,) = StateLibrary.getSlot0(IPoolManager(address(manager)), PoolIdLibrary.toId(k));
        int24 a = ((startTick / TICK_SPACING) * TICK_SPACING) + 4 * TICK_SPACING;
        _addRange(k, a, a + TICK_SPACING, int256(uint256(each)), bytes32(uint256(1)), 20 ether);
        _addRange(k, a + 2 * TICK_SPACING, a + 3 * TICK_SPACING, int256(uint256(each)), bytes32(uint256(2)), 20 ether);

        // Every initialized tick carries the bias, so none of these four slots can read as zero.
        int24[4] memory ticks = [a, a + TICK_SPACING, a + 2 * TICK_SPACING, a + 3 * TICK_SPACING];
        for (uint256 i = 0; i < 4; i++) {
            (uint128 gross,, uint256 biased) = h.lpTick(address(meme), ticks[i]);
            assertGt(gross, 0, "tick initialized");
            assertGt(biased, 0, "a live tick's accumulator slot is never zero");
        }

        _sellOn(k, meme.balanceOf(address(this)) / 8); // sweep up past both
        (, int24 up,,) = StateLibrary.getSlot0(IPoolManager(address(manager)), PoolIdLibrary.toId(k));
        assertGt(up, a + 3 * TICK_SPACING, "sanity: swept past both ranges");
        assertEq(h.lpLiquidity(address(meme)), baseline, "above both, neither is active");

        _buyOn(k, 20 ether); // and back down past both
        (, int24 down,,) = StateLibrary.getSlot0(IPoolManager(address(manager)), PoolIdLibrary.toId(k));
        assertLt(down, a, "sanity: swept back below both ranges");
        assertEq(h.lpLiquidity(address(meme)), baseline, "below both, neither is active, and nothing leaked");
    }

    function _sellOn(PoolKey memory k, uint256 amountInToken) internal {
        MockToken(Currency.unwrap(k.currency1)).approve(address(swapRouter), amountInToken);
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(amountInToken),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// The custom creator fee is capped at 5% (500 bps) — the hook rejects anything above.
    function test_CreatorFeeAboveMaxReverts() public {
        FeeHook h = _deployHook();
        MockToken meme = new MockToken();
        creatorNFT.set(address(meme), creator);
        vm.expectRevert(FeeHook.CreatorFeeTooHigh.selector);
        h.setLaunchConfig(address(meme), address(usdc), false, false, 0, 0, address(0), false, 501, 0, false);
    }

    /// A per-coin custom LP fee is charged ON TOP of the base 1% and banks 100% for external LPs —
    /// the base split (creator/team/burn/autocompound) still comes ONLY off the 1%.
    function test_CustomLpFeeIsChargedOnTopAndAllToLps() public {
        FeeHook h = _deployHook(); // launcher == test contract → the `lp` seed is external, LP tracked
        _wireBodkinPool(h);
        (MockToken meme, PoolKey memory k) = _launchOnWith(h, false, 0, 200); // +2% custom LP fee
        _buyOn(k, 1 ether);

        uint256 baseFee = (1 ether * 100) / 10_000; // 1%
        uint256 customLp = (1 ether * 200) / 10_000; // 2%, all to external LPs
        uint256 totalFee = baseFee + customLp;

        assertEq(h.creatorWei(address(meme)), (baseFee * 3500) / 10_000, "creator off the base 1% only");
        assertEq(h.teamWei(address(meme)), (baseFee * 2000) / 10_000, "team off the base 1% only");
        assertEq(h.burnWei(address(meme)), (baseFee * 1000) / 10_000, "burn off the base 1% only");
        assertEq(h.autocompoundWei(address(meme)), (baseFee * 1000) / 10_000, "autocompound off the base 1% only");
        assertEq(
            h.lpBankWei(address(meme)),
            (baseFee * 2500) / 10_000 + customLp,
            "LP = base 25% + 100% of the custom 2%"
        );
        assertGt(h.lpFeeGrowthGlobalX128(address(meme)), 0, "accumulator advanced for LPs");
        uint256 total = h.creatorWei(address(meme)) + h.burnWei(address(meme)) + h.teamWei(address(meme))
            + h.autocompoundWei(address(meme)) + h.lpBankWei(address(meme));
        assertEq(total, totalFee, "the full base+custom (3%) was skimmed");
    }

    /// With NO external LP, a custom LP fee has nobody to reward, so it folds into the CREATOR cut —
    /// exactly like the base LP slice.
    function test_CustomLpFeeFoldsToCreatorWhenNoExternalLp() public {
        MockLauncherLP mlp = new MockLauncherLP(IPoolManager(address(manager)));
        FeeHook h = _deployHookWithLauncher(address(mlp));
        _wireBodkinPool(h);
        MockToken meme = new MockToken();
        creatorNFT.set(address(meme), creator);
        vm.prank(address(mlp));
        h.setLaunchConfig(address(meme), address(usdc), false, false, 0, 0, address(0), false, 0, 200, false); // +2% LP fee
        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(meme)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(h))
        });
        vm.prank(address(mlp));
        manager.initialize(k, SQRT_PRICE_1_1);
        meme.approve(address(mlp), type(uint256).max);
        mlp.modifyLiquidity{value: 200 ether}(
            k,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: 10e18,
                salt: 0
            }),
            ""
        );
        assertEq(h.lpLiquidity(address(meme)), 0, "the launcher's own position is not external LP");

        _buyOn(k, 1 ether);
        uint256 baseFee = (1 ether * 100) / 10_000;
        uint256 customLp = (1 ether * 200) / 10_000;
        // creator = base 35% + folded base-LP 25% (=60% of base) + the folded custom 2%.
        assertEq(h.creatorWei(address(meme)), (baseFee * 6000) / 10_000 + customLp, "creator 60% of base + folded custom LP");
        assertEq(h.lpBankWei(address(meme)), 0, "nothing banked for LPs");
        assertEq(h.teamWei(address(meme)), (baseFee * 2000) / 10_000, "team 20%");
        assertEq(h.burnWei(address(meme)), (baseFee * 1000) / 10_000, "burn 10%");
        assertEq(h.autocompoundWei(address(meme)), (baseFee * 1000) / 10_000, "autocompound 10%");
    }

    /// The custom LP fee is capped at 5% (500 bps) — the hook rejects anything above.
    function test_LpFeeAboveMaxReverts() public {
        FeeHook h = _deployHook();
        MockToken meme = new MockToken();
        creatorNFT.set(address(meme), creator);
        vm.expectRevert(FeeHook.LpFeeTooHigh.selector);
        h.setLaunchConfig(address(meme), address(usdc), false, false, 0, 0, address(0), false, 0, 501, false);
    }

    /// LP rewards OFF (creator's launch choice): the base 25% LP slice AND any custom LP fee go to the
    /// creator EVEN when external LPs exist — nothing banks for them and the accumulator never advances.
    function test_LpRewardsOffRoutesEverythingLpToCreator() public {
        FeeHook h = _deployHook(); // launcher == test contract → the `lp` seed IS external (tracked)
        _wireBodkinPool(h);
        (MockToken meme, PoolKey memory k) = _launchOnWith(h, false, 0, 200, true); // +2% custom LP fee, LP rewards OFF
        assertGt(h.lpLiquidity(address(meme)), 0, "external LP is present and tracked");

        _buyOn(k, 1 ether);
        uint256 baseFee = (1 ether * 100) / 10_000;
        uint256 customLp = (1 ether * 200) / 10_000;
        // creator = base 35% + the folded base-LP 25% (= 60% of base) + the folded custom 2%.
        assertEq(
            h.creatorWei(address(meme)),
            (baseFee * 6000) / 10_000 + customLp,
            "creator gets base 60% + the folded custom LP fee"
        );
        assertEq(h.lpBankWei(address(meme)), 0, "nothing banks for LPs when rewards are off");
        assertEq(h.lpFeeGrowthGlobalX128(address(meme)), 0, "accumulator never advances");
        assertEq(h.teamWei(address(meme)), (baseFee * 2000) / 10_000, "team 20%");
        assertEq(h.burnWei(address(meme)), (baseFee * 1000) / 10_000, "burn 10%");
        assertEq(h.autocompoundWei(address(meme)), (baseFee * 1000) / 10_000, "autocompound 10%");
    }

    function test_SellTakesFeeInEth() public {
        _buy(5 ether);
        uint256 tokBal = token.balanceOf(address(this));
        _sell(tokBal / 2);
        assertGt(hook.creatorOut(address(token)), 0, "sell accrued a fee, already banked in the payout token");
        assertEq(token.balanceOf(address(hook)), 0, "hook never holds the meme token");
    }

    function test_ExactOutputReverts() public {
        vm.expectRevert();
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: int256(1e18), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_DefaultPayoutIsUsdc() public view {
        assertEq(hook.payoutTokenOf(address(token)), address(usdc), "creator default USDC");
        assertEq(hook.teamPayoutToken(), address(usdc), "team default USDC");
    }

    function test_CreatorClaimsUsdcByDefault() public {
        _buy(2 ether);
        assertGt(hook.creatorOut(address(token)), 0);

        vm.prank(creator);
        uint256 paid = hook.claimCreator(address(token));

        assertGt(usdc.balanceOf(creator), 0, "creator received USDC");
        assertEq(usdc.balanceOf(creator), paid, "returned amount = USDC delivered");
        assertEq(creator.balance, 0, "creator got no ETH (paid in USDC)");
        assertEq(hook.creatorOut(address(token)), 0, "banked balance paid out in full");
    }

    function test_CreatorCanOptIntoEth() public {
        // Chosen at launch (launcher-only), not by the creator afterwards.
        (MockToken meme, PoolKey memory k) = _newLaunchWith(address(0), false, 0, 0, address(0), address(0));
        _buyOn(k, 2 ether);
        // ETH payout on an ETH-quoted pool is the no-swap case: the whole slice is
        // reclassified into the banked balance in the same transaction.
        uint256 c = hook.creatorOut(address(meme));
        assertGt(c, 0, "banked in ETH straight away");
        assertEq(hook.creatorWei(address(meme)), 0, "nothing left in the waiting room");

        vm.prank(creator);
        uint256 paid = hook.claimCreator(address(meme));

        assertEq(creator.balance, c, "creator received ETH");
        assertEq(paid, c);
        assertEq(hook.numeraireOf(address(meme)), address(0), "ETH-quoted");
        assertEq(usdc.balanceOf(creator), 0, "no USDC when ETH chosen");
    }

    function test_TeamClaimsUsdcByDefault() public {
        _buy(2 ether);
        assertGt(hook.teamOut(address(token), address(usdc)), 0);

        vm.prank(team);
        hook.claimTeam(address(token));
        assertGt(usdc.balanceOf(team), 0, "team received USDC");
        assertEq(hook.teamWei(address(token)), 0);
    }

    // ── USDC migration (this test IS the launcher, so it can call migrateUsdc directly) ──────────

    /// End-to-end of the atomic USDC migration through the hook: fees banked in the OLD USDC stay
    /// claimable in the OLD USDC, new fees bank in the NEW USDC under their own currency key, and ONE
    /// claim delivers BOTH — nothing strands, nothing is re-denominated. (The 2-of-2 signature layer
    /// that fronts {migrateUsdc} is exercised in LauncherV1.t.sol.)
    function test_UsdcMigration_OldFeesStayClaimable_NewFeesBankSeparately() public {
        // 1. Bank team fees in the OLD usdc.
        _buy(2 ether);
        uint256 oldBanked = hook.teamOut(address(token), address(usdc));
        assertGt(oldBanked, 0, "old-usdc team fees banked");

        // 2. Stand up a NEW usdc + its (ETH, newUsdc) conversion pool, then migrate atomically.
        MockUSDC newUsdc = new MockUSDC();
        PoolKey memory newPool = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(newUsdc)),
            fee: 3000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        manager.initialize(newPool, SQRT_PRICE_1_1);
        newUsdc.approve(address(lp), type(uint256).max);
        _addLiquidity(newPool, 10e18, 200 ether);

        hook.migrateUsdc(address(newUsdc), newPool);
        assertEq(hook.usdc(), address(newUsdc), "usdc re-pointed");
        assertEq(hook.teamPayoutToken(), address(newUsdc), "team payout swung to the new usdc");
        assertEq(hook.teamOut(address(token), address(usdc)), oldBanked, "old-usdc slice intact after migration");

        // 3. New team fees now convert (ETH -> newUsdc via the new pool) and bank under the NEW key.
        //    Advance a block first: only one team conversion is allowed per block (lastTeamConvertBlock),
        //    and step 1's buy already converted in this block.
        vm.roll(vm.getBlockNumber() + 1);
        _buy(2 ether);
        uint256 newBanked = hook.teamOut(address(token), address(newUsdc));
        assertGt(newBanked, 0, "new-usdc team fees banked under their own currency key");

        // 4. One claim delivers BOTH currencies; nothing stranded.
        uint256 oldBefore = usdc.balanceOf(team);
        uint256 newBefore = newUsdc.balanceOf(team);
        vm.prank(team);
        hook.claimTeam(address(token));
        assertEq(usdc.balanceOf(team), oldBefore + oldBanked, "old usdc delivered in OLD usdc");
        assertEq(newUsdc.balanceOf(team), newBefore + newBanked, "new usdc delivered in NEW usdc");
        assertEq(hook.teamOut(address(token), address(usdc)), 0, "old drained");
        assertEq(hook.teamOut(address(token), address(newUsdc)), 0, "new drained");
    }

    /// {migrateUsdc} coin + pool validation and its launcher-only gate (the fat-finger guard on the
    /// 2-of-2). Each bad input reverts and leaves usdc untouched.
    function test_MigrateUsdc_ValidatesCoinAndPoolAndCaller() public {
        MockUSDC newUsdc = new MockUSDC();
        PoolKey memory goodPool = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(newUsdc)),
            fee: 3000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        manager.initialize(goodPool, SQRT_PRICE_1_1);

        // Coin: a no-op re-point (same address) and the zero address are rejected up front.
        vm.expectRevert(FeeHook.BadUsdcMigration.selector);
        hook.migrateUsdc(address(usdc), goodPool);
        vm.expectRevert(FeeHook.BadUsdcMigration.selector);
        hook.migrateUsdc(address(0), goodPool);

        // Coin: an EOA (no code) and a wrong-decimals token (weth9 is 18dp, usdc is 6dp) are rejected.
        vm.expectRevert(FeeHook.FeeTokenHasNoCode.selector);
        hook.migrateUsdc(address(0xE0A), goodPool);
        vm.expectRevert(FeeHook.FeeTokenBadDecimals.selector);
        hook.migrateUsdc(address(weth9), goodPool);

        // Pool: correct coin but an UNINITIALISED pool (sqrtPrice == 0) is rejected.
        MockUSDC newUsdc2 = new MockUSDC();
        PoolKey memory uninit = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(newUsdc2)),
            fee: 3000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        vm.expectRevert(FeeHook.BadUsdcMigration.selector);
        hook.migrateUsdc(address(newUsdc2), uninit);

        // Pool: a pool carrying a hook is rejected (no re-entrant/hostile hook on the conversion pool).
        PoolKey memory hooked = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(newUsdc)),
            fee: 3000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert(FeeHook.BadUsdcMigration.selector);
        hook.migrateUsdc(address(newUsdc), hooked);

        // Only the launcher may call it.
        vm.prank(address(0xBEEF));
        vm.expectRevert(FeeHook.NotLauncher.selector);
        hook.migrateUsdc(address(newUsdc), goodPool);

        assertEq(hook.usdc(), address(usdc), "usdc unchanged through every rejection");
    }

    /// After a USDC migration, an OLD-usdc-NUMERAIRE launch's ONGOING team fees can no longer route out
    /// of the deprecated numeraire (its bucket is old-usdc, the canonical pool is now (ETH,newUsdc)), so
    /// they FALL BACK into that old numeraire — like the creator's numeraire fallback — instead of
    /// stalling, and stay claimable. (Regression guard for the adversarial review's confirmed gap.)
    function test_UsdcMigration_StaleNumeraireLaunch_TeamFeesFallBackNotStranded() public {
        // A USDC(old)-quoted launch. Team payout is usdc == numeraire, so pre-migration its team fee
        // banks losslessly (noSwap) into teamOut[meme][oldUsdc].
        MockToken meme = _tokenSortedVsUsdc(true);
        creatorNFT.set(address(meme), creator);
        hook.setLaunchConfig(address(meme), address(usdc), false, false, 0, 0, address(usdc), false, 0, 0, false);
        PoolKey memory mk = PoolKey({
            currency0: Currency.wrap(address(usdc)),
            currency1: Currency.wrap(address(meme)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        manager.initialize(mk, SQRT_PRICE_1_1);
        meme.approve(address(lp), type(uint256).max);
        usdc.approve(address(lp), type(uint256).max);
        _addLiquidity(mk, 50e18, 0);

        _buyOnWithUsdc(mk, 50_000e6);
        uint256 preMig = hook.teamOut(address(meme), address(usdc));
        assertGt(preMig, 0, "pre-migration team fee banked in old usdc (noSwap)");

        // Migrate to a new usdc + its (ETH, newUsdc) pool. teamPayoutToken swings to newUsdc.
        MockUSDC newUsdc = new MockUSDC();
        PoolKey memory newPool = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(newUsdc)),
            fee: 3000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        manager.initialize(newPool, SQRT_PRICE_1_1);
        newUsdc.approve(address(lp), type(uint256).max);
        _addLiquidity(newPool, 10e18, 200 ether);
        hook.migrateUsdc(address(newUsdc), newPool);
        assertEq(hook.teamPayoutToken(), address(newUsdc), "team payout swung to new usdc");

        // A post-migration buy on the STALE-numeraire launch: the team fee (old usdc) can't route to
        // newUsdc, so it FALLS BACK into the old-usdc numeraire instead of stalling.
        vm.roll(vm.getBlockNumber() + 1);
        _buyOnWithUsdc(mk, 50_000e6);
        uint256 postMig = hook.teamOut(address(meme), address(usdc));
        assertGt(postMig, preMig, "ongoing team fee fell back into old usdc, not stranded");
        assertEq(hook.teamOut(address(meme), address(newUsdc)), 0, "nothing mis-banked into new usdc");

        // And it is claimable, in old usdc.
        uint256 before = usdc.balanceOf(team);
        vm.prank(team);
        hook.claimTeam(address(meme));
        assertEq(usdc.balanceOf(team), before + postMig, "stale-numeraire team fees claimable in old usdc");
    }

    // ── the team's slice rides along on the creator's claim ──────────────────

    /// One transaction settles BOTH parties for a token: the creator pulls, the team is
    /// pushed. Otherwise the team's 20% sits banked indefinitely, one manual `claimTeam`
    /// per launch behind, on a launchpad that may have thousands of them.
    function test_ACreatorClaimAlsoDeliversTheTeamsSlice() public {
        _buy(2 ether);
        uint256 teamBanked = hook.teamOut(address(token), address(usdc));
        assertGt(teamBanked, 0, "the team's slice is banked and waiting");

        vm.prank(creator);
        hook.claimCreator(address(token));

        assertEq(usdc.balanceOf(team), teamBanked, "the team was paid in the SAME transaction");
        assertEq(hook.teamOut(address(token), address(usdc)), 0, "and its banked balance is zeroed, not double-counted");
    }

    /// THE safety property of the ride-along: the creator's money cannot be held hostage
    /// by a problem on the team's leg. The team's slice is not lost either — it stays
    /// banked, and the manual escape hatch still collects it.
    ///
    /// The failure is injected in the TOKEN, not the recipient: `_deliver` goes through
    /// `PoolManager.take`, a bare transfer with no callback, so a contract at `team`
    /// has no way to refuse. A blocklisting stablecoin does — and USDC is one.
    function test_AFailedTeamPushCannotCostTheCreatorTheirClaim() public {
        _buy(2 ether);
        uint256 creatorBanked = hook.creatorOut(address(token));
        uint256 teamBanked = hook.teamOut(address(token), address(usdc));
        assertGt(creatorBanked, 0);
        assertGt(teamBanked, 0);

        usdc.setRejects(team, true); // every USDC transfer to the team now reverts

        vm.prank(creator);
        uint256 paid = hook.claimCreator(address(token));

        assertEq(paid, creatorBanked, "the claim went through in full");
        assertEq(usdc.balanceOf(creator), creatorBanked, "and the creator actually holds it");
        assertEq(hook.creatorOut(address(token)), 0, "creator side settled");
        // The whole point: the failed leg rolled back rather than consuming the balance.
        assertEq(hook.teamOut(address(token), address(usdc)), teamBanked, "the team's slice is intact, not burned by the failure");
        assertEq(usdc.balanceOf(team), 0, "and nothing reached the team");

        // …so the escape hatch still works once the obstruction is gone.
        usdc.setRejects(team, false);
        vm.prank(team);
        assertEq(hook.claimTeam(address(token)), teamBanked, "claimTeam still collects it later");
        assertEq(usdc.balanceOf(team), teamBanked);
        assertEq(hook.teamOut(address(token), address(usdc)), 0);
    }

    /// Nothing banked for the team = nothing happens. No unlock, no transfer, no event —
    /// and above all no revert, because the overwhelmingly common claim is one where the
    /// push already ran on a previous claim.
    function test_ACreatorClaimWithNothingBankedForTheTeamIsFree() public {
        // Two identical launches. On A the team's slice is drained first, so its claim
        // has nothing to push; B keeps its slice and pays the full ride-along cost.
        (MockToken memeA, PoolKey memory kA) = _newLaunch();
        (MockToken memeB, PoolKey memory kB) = _newLaunch();
        _buyOn(kA, 2 ether);
        _buyOn(kB, 2 ether);

        // A third claim FIRST, purely to warm what the two measured claims share: the
        // creator's and the team's USDC balance slots. Without it the first measured
        // claim pays a 20k zero->nonzero SSTORE that the second does not, which is
        // larger than the ride-along it is supposed to be compared against — the gas
        // assertion below then measures cold storage rather than the push.
        (MockToken memeWarm, PoolKey memory kWarm) = _newLaunch();
        _buyOn(kWarm, 2 ether);
        vm.prank(creator);
        hook.claimCreator(address(memeWarm));

        vm.prank(team);
        hook.claimTeam(address(memeA));
        assertEq(hook.teamOut(address(memeA), address(usdc)), 0, "A has nothing left for the team");
        assertGt(hook.teamOut(address(memeB), address(usdc)), 0, "B still does");

        uint256 teamBalance = usdc.balanceOf(team);
        vm.recordLogs();

        vm.prank(creator);
        uint256 gasBefore = gasleft();
        uint256 paidA = hook.claimCreator(address(memeA));
        uint256 gasNoPush = gasBefore - gasleft();

        assertGt(paidA, 0, "the creator is paid as normal");
        assertEq(usdc.balanceOf(team), teamBalance, "the team's balance did not move");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != FeeHook.TeamClaimed.selector, "no team payout was even attempted");
        }

        vm.prank(creator);
        gasBefore = gasleft();
        hook.claimCreator(address(memeB));
        uint256 gasWithPush = gasBefore - gasleft();

        // "Costs nothing extra", measured: the empty case skips a whole unlock + take +
        // settle + ERC20 transfer. The 10k margin is deliberate — a bare `assertLt` here
        // passes or fails on a handful of gas when the ride-along is absent entirely,
        // which would make this assertion useless as a mutation detector.
        assertGt(gasWithPush, gasNoPush + 10_000, "an empty team bucket short-circuits before the delivery");
    }

    /// The team's payout currency DEFAULTS to USDC but is changeable — launcher-only, driven by the
    /// launcher's 2-of-2 governance (the end-to-end flow is in LauncherV1.t.sol). Here, at the hook
    /// level (this test contract is the wired launcher): a non-launcher cannot move it, the launcher
    /// may flip it to native ETH, and only ETH or an deployer-allowed token is accepted.
    function test_TeamPayoutTokenChangeableByLauncherOnly() public {
        assertEq(hook.teamPayoutToken(), address(usdc), "defaults to USDC");
        assertEq(hook.teamPayoutToken(), hook.usdc(), "and specifically the hook's own USDC");

        // Not the launcher -> rejected.
        vm.prank(address(0xBEEF));
        vm.expectRevert(FeeHook.NotLauncher.selector);
        hook.setTeamPayoutToken(address(0));

        // The launcher (this test contract) may flip it to native ETH (always allowed).
        hook.setTeamPayoutToken(address(0));
        assertEq(hook.teamPayoutToken(), address(0), "launcher moved it to ETH");

        // A token that is neither ETH nor deployer-allowed is refused.
        vm.expectRevert(bytes("FeeHook: team token not allowed"));
        hook.setTeamPayoutToken(address(0xD00D));

        // Back to USDC — seeded as allowed at deploy.
        hook.setTeamPayoutToken(address(usdc));
        assertEq(hook.teamPayoutToken(), address(usdc), "USDC is an allowed target");
    }

    function test_NonCreatorCannotClaim() public {
        _buy(1 ether);
        vm.expectRevert(FeeHook.NotCreator.selector);
        hook.claimCreator(address(token));
    }

    function test_PayoutIsOneTimeAndLauncherOnly() public {
        MockToken fresh = new MockToken();
        // Not the launcher → rejected (the creator has no changer either).
        vm.prank(creator);
        vm.expectRevert(FeeHook.NotLauncher.selector);
        hook.setLaunchConfig(address(fresh), address(0), false, false, 0, 0, address(0), false, 0, 0, false);

        // Launcher sets it once…
        hook.setLaunchConfig(address(fresh), address(0), false, false, 0, 0, address(0), false, 0, 0, false);
        assertEq(hook.payoutTokenOf(address(fresh)), address(0), "payout set to ETH");

        // …and can never change it again — the choice is immutable after creation.
        vm.expectRevert(FeeHook.PayoutAlreadySet.selector);
        hook.setLaunchConfig(address(fresh), address(usdc), false, false, 0, 0, address(0), false, 0, 0, false);
    }

    /// The buy & burn runs off TRADING, with nobody operating it. This is the property
    /// that replaces a keeper: a swap accrues the bucket and advances the buyback in the
    /// same transaction.
    function test_TheBurnAdvancesOnItsOwnWithEverySwap() public {
        uint256 deadBefore = bodkin.balanceOf(DEAD);
        _buy(2 ether);
        assertGt(bodkin.balanceOf(DEAD), deadBefore, "a swap alone bought and burned BODKIN");
    }

    /// The manual entrypoint, on a THIN BODKIN pool so a normal bucket exceeds one safe
    /// chunk and there is a remainder left to see.
    function test_ProcessBurnBuysAndBurnsBodkin() public {
        (FeeHook h, MockToken meme, PoolKey memory k, MockToken b) = _freshHookWithBodkinPool(1e17);
        _buyOn(k, 2 ether);
        // The buy already took this block's chunk — one per token per block is what stops
        // a sandwich from draining the bucket through repeated calls in one transaction.
        assertEq(h.processBurn(address(meme)), 0, "same block: no second chunk");
        vm.roll(vm.getBlockNumber() + 1);

        uint256 bucketBefore = h.burnWei(address(meme));
        assertGt(bucketBefore, 0, "the remainder is KEPT for the next block");
        uint256 deadBefore = b.balanceOf(DEAD);

        uint256 burned = h.processBurn(address(meme)); // permissionless, no keeper

        assertGt(burned, 0, "returned the amount burned");
        assertGt(b.balanceOf(DEAD), deadBefore, "BODKIN bought and burned to dEaD");
        assertLt(h.burnWei(address(meme)), bucketBefore, "bucket drew down");
    }

    /// Calling twice in one block is a no-op, not a revert — a bot looping on this must
    /// never be punished for being early, and the block cap is what bounds a sandwich.
    function test_OnlyOneBurnChunkPerBlock() public {
        (FeeHook h, MockToken meme, PoolKey memory k,) = _freshHookWithBodkinPool(1e17);
        _buyOn(k, 2 ether);
        vm.roll(vm.getBlockNumber() + 1);
        assertGt(h.processBurn(address(meme)), 0, "first call in the block burns");
        assertEq(h.processBurn(address(meme)), 0, "second is a silent no-op");
        assertEq(h.lastBurnBlock(address(meme)), block.number);
    }

    /// The remainder is KEPT and successive blocks continue the buyback: the on-chain
    /// equivalent of a TWAP keeper, time-averaged but driven by trading instead of a bot.
    function test_ABigBucketIsBurnedInChunksAcrossBlocks() public {
        (FeeHook h, MockToken meme, PoolKey memory k,) = _freshHookWithBodkinPool(1e17);
        _buyOn(k, 20 ether);

        uint256 bucket = h.burnWei(address(meme));
        assertGt(bucket, 0, "one swap cannot drain a bucket this big -- the chunk is capped");

        // Each further block takes another bite, with no keeper and no manual sizing.
        // NOTE the explicit counter. `vm.roll(vm.getBlockNumber() + 1)` in a loop advances the
        // block exactly ONCE — `block.number` inside the running frame does not observe
        // the roll, so every later iteration rolls to the same number and the one-chunk-
        // per-block guard silently blocks them. That reads as "the burn stalled" when it
        // is really the harness. Track the target block ourselves.
        uint256 blk = block.number;
        uint256 steps;
        while (h.burnWei(address(meme)) > 0 && steps < 400) {
            blk++;
            vm.roll(blk);
            h.processBurn(address(meme));
            steps++;
        }
        assertGt(steps, 1, "it genuinely took several blocks, i.e. it was chunked");
        assertEq(h.burnWei(address(meme)), 0, "and it does finish -- the bucket is not stranded");
    }

    /// THE safety property, stated as a test: a swap must go through even when the burn
    /// cannot. Here the BODKIN pool is never wired — and trading is completely unaffected.
    /// With no venue the hook does not even book a burn slice (it would only strand ETH):
    /// that 10% rolls to the creator, exactly like BODKIN's own trades, so the dev buy
    /// INSIDE the BODKIN launch (which runs before {setBodkinPool} can) never self-burns.
    function test_ASwapSucceedsEvenWhenTheBurnCannotRun() public {
        // A hook with no BODKIN pool wired at all.
        (FeeHook bare, MockToken meme, PoolKey memory k) = _freshHookWithoutBodkinPool();

        _buyOn(k, 1 ether); // must not revert
        uint256 fee = (1 ether * 100) / 10_000;
        assertEq(bare.burnWei(address(meme)), 0, "no venue: nothing is booked for a burn that can never run");
        assertEq(bare.creatorWei(address(meme)), (fee * 4500) / 10_000, "the burn slice rolled to the creator (35% + 10%)");
        assertEq(bare.processBurn(address(meme)), 0, "and the burn is a no-op, not a revert");
    }

    /// A zero-fee BODKIN pool can never be wired. The pool fee IS the burn's protection
    /// (it is what a sandwicher pays twice), the setter is one-shot, and the owner is
    /// renounced at deploy — so this is the only moment the mistake can be caught.
    function test_AZeroFeeBodkinPoolIsRefused() public {
        FeeHook fresh = _deployHook();
        MockToken b2 = new MockToken();
        PoolKey memory zeroFee = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(b2)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        vm.expectRevert(bytes("FeeHook: bodkin pool needs a fee"));
        fresh.setBodkinPool(zeroFee);

        // And a dynamic-fee pool likewise: the chunk sizing needs a fee it can read.
        zeroFee.fee = 0x800000;
        vm.expectRevert(bytes("FeeHook: bodkin pool needs a fee"));
        fresh.setBodkinPool(zeroFee);

        // A pool on SOMEBODY ELSE'S hook is not our venue either — the FEE_BPS toll
        // argument only holds for this hook's own skim.
        zeroFee.fee = 0;
        zeroFee.hooks = IHooks(address(0xBAD));
        vm.expectRevert(bytes("FeeHook: bodkin pool needs a fee"));
        fresh.setBodkinPool(zeroFee);
    }

    // ── BODKIN as a launch: its own hooked pool as the burn venue ────────────

    /// A fresh hook where BODKIN itself IS a launch — creator fee, NFT, the works —
    /// and its hooked (pool-fee-0) launch pool doubles as the buy & burn venue.
    function _freshHookWithLaunchedBodkin()
        internal
        returns (FeeHook fresh, MockToken meme, PoolKey memory k, MockToken b, PoolKey memory bk)
    {
        fresh = _deployHook();
        (b, bk) = _launchOn(fresh);
        fresh.setBodkinPool(bk);
        (meme, k) = _launchOn(fresh);
    }

    function test_SetBodkinPool_AcceptsItsOwnHookedPool() public {
        (FeeHook fresh,,, MockToken b,) = _freshHookWithLaunchedBodkin();
        assertEq(fresh.bodkin(), address(b), "the hooked launch pool is the venue");
    }

    /// The heart of the model: a trade on ANOTHER launch funds its burn bucket, and
    /// the burn's buy executes on the HOOKED venue — the nested beforeSwap/afterSwap
    /// (the hook taxing its own burn swap) must settle, terminate, and still burn.
    function test_BurnAdvancesOnHookedVenue() public {
        (FeeHook fresh, MockToken meme,, MockToken b,) = _freshHookWithLaunchedBodkin();
        uint256 deadBefore = b.balanceOf(DEAD);
        _buyOn(_launchKey(fresh, address(meme)), 5 ether); // funds meme's burn bucket
        vm.roll(vm.getBlockNumber() + 1);
        _buyOn(_launchKey(fresh, address(meme)), 1 ether); // this swap advances the burn
        assertGt(b.balanceOf(DEAD), deadBefore, "the hooked venue bought and burned BODKIN");
    }

    /// A trade ON BODKIN itself: the hook taxes it like any launch (creator bucket
    /// fills), its own burn bucket buys BODKIN on the same pool, and the recursion
    /// bottoms out on the per-block markers instead of spiralling.
    function test_SwapOnBodkinItselfAccruesAndTerminates() public {
        (FeeHook fresh,,, MockToken b, PoolKey memory bk) = _freshHookWithLaunchedBodkin();
        _buyOn(bk, 5 ether); // must not revert (nested hook callbacks settle)
        assertGt(
            fresh.creatorWei(address(b)) + fresh.creatorOut(address(b)),
            0,
            "BODKIN accrues creator fees like any launch"
        );
        // BODKIN never buys-and-burns ITSELF: its 10% burn slice rolls into the creator cut, so its burn
        // bucket stays empty and its own trades send nothing to the dead address. BODKIN's deflation
        // rides only on every OTHER coin's fees.
        assertEq(fresh.burnWei(address(b)), 0, "BODKIN banks no burn slice for itself");
        // BODKIN now AUTOCOMPOUNDS itself per its launch config (autocompoundOff=false): its 10%
        // autocompound slice folds into its OWN pool like any coin, instead of rolling to the creator
        // cut. Only the burn exemption above stays BODKIN-specific.
        uint256 deadBefore = b.balanceOf(DEAD);
        for (uint256 i = 1; i <= 80; i++) {
            vm.roll(100 + i);
            _buyOn(bk, 0.0005 ether);
        }
        assertEq(fresh.burnWei(address(b)), 0, "still no burn slice after many of BODKIN's own trades");
        assertEq(b.balanceOf(DEAD), deadBefore, "BODKIN's own trades burn no BODKIN");
    }

    /// The external entrypoint drains an oversized bucket in bounded chunks on the
    /// hooked venue, exactly as it does on a plain one.
    function test_ProcessBurnChunksOnHookedVenue() public {
        (FeeHook fresh, MockToken meme,, MockToken b,) = _freshHookWithLaunchedBodkin();
        PoolKey memory mk = _launchKey(fresh, address(meme));
        // Build a bucket that is genuinely bigger than one safe chunk, IN ONE BLOCK.
        // Only a token's FIRST buy of a block runs its burn (`lastBurnBlock` gates the
        // rest), so every later same-block buy piles the bucket up WITHOUT draining it —
        // a single big buy would instead burn one capped chunk in its own afterSwap and,
        // at a small burn share, drain the whole bucket then and there, leaving nothing
        // for `processBurn` to chunk. Sizing the pile against `safeBurnChunkView()` keeps
        // this independent of the exact FEE_BPS / BURN_BPS split.
        uint256 cap = fresh.safeBurnChunkView();
        for (uint256 i = 0; i < 60 && fresh.burnWei(address(meme)) <= cap * 2; i++) {
            _buyOn(mk, 5 ether);
        }
        uint256 remaining = fresh.burnWei(address(meme));
        assertGt(remaining, cap, "sanity: the bucket exceeds one safe chunk");
        uint256 deadBefore = b.balanceOf(DEAD);
        for (uint256 i = 0; i < 40 && fresh.burnWei(address(meme)) > 0; i++) {
            vm.roll(vm.getBlockNumber() + 1);
            fresh.processBurn(address(meme));
            assertLe(fresh.burnWei(address(meme)), remaining, "the bucket only ever drains");
            remaining = fresh.burnWei(address(meme));
        }
        assertGt(b.balanceOf(DEAD), deadBefore, "chunked burning still lands at the dead address");
    }

    /// The venue budget: N tokens' burns share ONE safe chunk per block.
    ///
    /// Without it, `lastBurnBlock` (keyed per token) let an attacker buy BODKIN, call
    /// `processBurn` once per launch — each passing its own per-token gate and each
    /// spending its own full cap — and sell into the aggregate push. A measured PoC on
    /// 8 launches forced 8.3x the safe chunk (4.1x the sandwich break-even) and cleared
    /// ~0.14 ETH per pass, repeatable every block.
    uint256 constant BLOCK_MEASURE = 100;
    uint256 constant BLOCK_NEXT = 101;

    function test_VenueBudgetCapsTheWholeBlockNotJustOneToken() public {
        FeeHook fresh = _deployHook();
        (MockToken b, PoolKey memory bk) = _launchOn(fresh);
        fresh.setBodkinPool(bk);

        // Eight launches, each with a burn bucket far bigger than one safe chunk.
        //
        // Filled in ONE block on purpose: only a token's FIRST buy of a block can run
        // its burn (`lastBurnBlock` gates the rest), so the later rounds accrue without
        // draining and the buckets pile up — the state an attacker waits for.
        MockToken[] memory memes = new MockToken[](8);
        PoolKey[] memory keys = new PoolKey[](8);
        for (uint256 i = 0; i < memes.length; i++) {
            (MockToken m, PoolKey memory mk) = _launchOn(fresh);
            memes[i] = m;
            keys[i] = mk;
        }
        for (uint256 round = 0; round < 5; round++) {
            for (uint256 i = 0; i < memes.length; i++) {
                _buyOn(keys[i], 5 ether);
            }
        }
        uint256 cap = fresh.safeBurnChunkView();
        assertGt(cap, 0, "sanity: the venue has a nonzero safe chunk");

        // One block, every bucket poked: the TOTAL spend may not exceed one chunk.
        //
        // ABSOLUTE block numbers, not `block.number + 1`: with via-IR the optimizer
        // treats NUMBER as loop-invariant within a call frame (true on a real chain,
        // false under cheatcodes), so a SECOND relative roll in one test silently
        // compiles to a no-op and the test would measure two burns in one block.
        vm.roll(BLOCK_MEASURE);
        uint256 spent;
        uint256 totalBuckets;
        for (uint256 i = 0; i < memes.length; i++) {
            uint256 before = fresh.burnWei(address(memes[i]));
            totalBuckets += before;
            fresh.processBurn(address(memes[i]));
            spent += before - fresh.burnWei(address(memes[i]));
        }
        assertLe(spent, cap, "one block of burning must not exceed one safe chunk");
        assertLt(spent, totalBuckets, "the budget actually bit: not everything drained");

        // And the budget REFILLS: whatever the cap held back burns in the next block,
        // so the buckets still drain — just no faster than one chunk per block.
        uint256 leftover;
        for (uint256 i = 0; i < memes.length; i++) {
            if (fresh.burnWei(address(memes[i])) > 0) {
                leftover = i;
                break;
            }
        }
        uint256 deadBefore = b.balanceOf(DEAD);
        uint256 bucketBefore = fresh.burnWei(address(memes[leftover]));
        vm.roll(BLOCK_NEXT);
        assertGt(fresh.safeBurnChunkView(), 0, "sanity: the venue still has depth to burn into");
        fresh.processBurn(address(memes[leftover]));
        assertLt(fresh.burnWei(address(memes[leftover])), bucketBefore, "the next block resumes burning");
        assertGt(b.balanceOf(DEAD), deadBefore, "and BODKIN still reaches the dead address");
    }

    /// The fee-CONVERSION venue (the shared ETH<->USDC `_usdcPool`) is bounded PER BLOCK across ALL
    /// tokens, not just one — so N launches' creator/team conversions cannot be batched into a single
    /// sandwiched tx on that one pool. Mirrors {test_VenueBudgetCapsTheWholeBlockNotJustOneToken}.
    function test_ConvertVenueBudgetCapsTheWholeBlockNotJustOneToken() public {
        // Eight ETH-numeraire launches with the DEFAULT (USDC) payout — every creator conversion routes
        // its ETH->USDC leg through the one shared _usdcPool.
        MockToken[] memory memes = new MockToken[](8);
        PoolKey[] memory keys = new PoolKey[](8);
        for (uint256 i = 0; i < memes.length; i++) {
            (memes[i], keys[i]) = _newLaunch();
        }
        // Pile up each creatorWei bucket in ONE block: only a token's FIRST conversion of a block runs
        // (lastCreatorConvertBlock gates the rest), so the later rounds accrue without draining.
        vm.roll(2000);
        for (uint256 round = 0; round < 8; round++) {
            for (uint256 i = 0; i < memes.length; i++) _buyOn(keys[i], 5 ether);
        }

        // One block, every creator bucket poked: the TOTAL ETH pushed through _usdcPool may not exceed
        // one safe chunk — without the aggregate budget it would be up to one chunk PER token.
        vm.roll(2001);
        uint256 cap = hook.convVenueChunkView();
        assertGt(cap, 0, "sanity: the usdc conversion venue has a nonzero safe chunk");
        uint256 totalBuckets;
        for (uint256 i = 0; i < memes.length; i++) {
            totalBuckets += hook.creatorWei(address(memes[i]));
            hook.processConvert(address(memes[i]), true);
        }
        uint256 spent = hook.venueConvSpent();
        assertGt(spent, 0, "conversions ran through the shared usdc pool");
        assertLe(spent, cap, "one block of conversions must not exceed one safe usdc-pool chunk");
        assertLt(spent, totalBuckets, "the venue budget bit: not every bucket converted this block");

        // The budget refills: whatever was held back converts in a later block.
        vm.roll(2002);
        uint256 leftover = type(uint256).max;
        for (uint256 i = 0; i < memes.length; i++) {
            if (hook.creatorWei(address(memes[i])) > 0) {
                leftover = i;
                break;
            }
        }
        assertLt(leftover, memes.length, "some bucket was held back by the budget");
        uint256 outBefore = hook.creatorOut(address(memes[leftover]));
        hook.processConvert(address(memes[leftover]), true);
        assertGt(hook.creatorOut(address(memes[leftover])), outBefore, "next block resumes converting");
    }

    /// Rebuild a launch's pool key the way `_launchOn` created it.
    /// THE PRODUCT PROPERTY: the fee pipeline keeps pace with ordinary trading.
    ///
    /// The automatic per-swap processing is the platform's flagship behaviour — fees
    /// ground down in small chunks, paced by trading itself, no keeper. The 2% band
    /// cannot tell an attack from a busy block, so it necessarily skips some. This
    /// asserts that "some" is not "most": over twenty blocks of continuous two-sided
    /// trading, every bucket must actually drain rather than ratchet up.
    ///
    /// Simulated skip rate for this shape of flow is 8-30% depending on how heavy the
    /// blocks are, and the per-block cap is far larger than the fee inflow, so a skipped
    /// block costs latency and nothing else.
    function test_PipelineKeepsPaceWithOrdinaryTrading() public {
        uint256 convertedAtLeastOnce;
        uint256 burnedAtLeastOnce;
        uint256 deadStart = bodkin.balanceOf(DEAD);
        uint256 outStart = hook.creatorOut(address(token));

        for (uint256 i = 0; i < 20; i++) {
            vm.roll(500 + i);
            // Two-sided flow, alternating, so the venue moves both ways like a real book.
            if (i % 2 == 0) _buy(0.2 ether);
            else _sell(token.balanceOf(address(this)) / 200);
            if (hook.creatorOut(address(token)) > outStart) convertedAtLeastOnce++;
            if (bodkin.balanceOf(DEAD) > deadStart) burnedAtLeastOnce++;
        }

        assertGt(convertedAtLeastOnce, 0, "creator fees convert during ordinary trading");
        assertGt(burnedAtLeastOnce, 0, "the buy & burn advances during ordinary trading");
        // The bucket must not simply accumulate: what came in has largely gone out.
        assertGt(
            hook.creatorOut(address(token)),
            hook.creatorWei(address(token)),
            "more has been converted than is left waiting - the pipeline keeps up"
        );
    }

    /// A USDC-quoted burn books its REAL ETH cost against the shared venue budget.
    ///
    /// THE TEST THE SUITE COULD NOT HAVE HAD, and the reason a pair of inverted unit
    /// conversions sat in `_bookVenueSpend`/`_burnChunk` with all 92 tests green. Two
    /// things were missing and both are set up here:
    ///
    ///   * the ETH/USDC pool has to be OFF `SQRT_PRICE_1_1`. At a price of exactly 1,
    ///     multiplying and dividing by it give the same answer, so a flipped direction
    ///     is invisible. `setUp` initialises it at 1:1.
    ///   * a USDC-quoted launch has to actually TRADE, which needs `_buyOnWithUsdc` —
    ///     `_buyOn` sends `{value:}` and can only drive ETH-quoted pools.
    ///
    /// The assertion is directional rather than a magic number. After the 4-ETH buy the
    /// pool sits near P = 0.5 (raw micro-USDC per wei), so converting a USDC amount into
    /// ETH must make the number BIGGER — dividing by a price below one. The inverted
    /// flag multiplies instead and makes it smaller. At a realistic mainnet rate the
    /// same inversion truncates the booking to zero outright, which is what silently
    /// disabled the aggregate cap for every USDC-quoted launch.
    function test_UsdcQuotedBurnBooksItsRealCostAgainstTheVenueBudget() public {
        vm.roll(900);
        _buyOn(_usdcKey(), 4 ether); // move ETH/USDC off 1:1 so the directions differ

        // A USDC-quoted launch. The token is MINED to sort above USDC — the launcher's
        // `token > numeraire` invariant is what lets one set of range math serve both.
        MockToken meme = _tokenSortedVsUsdc(true);
        creatorNFT.set(address(meme), creator);
        hook.setLaunchConfig(address(meme), address(usdc), false, false, 0, 0, address(usdc), false, 0, 0, false);
        PoolKey memory mk = PoolKey({
            currency0: Currency.wrap(address(usdc)),
            currency1: Currency.wrap(address(meme)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        manager.initialize(mk, SQRT_PRICE_1_1);
        meme.approve(address(lp), type(uint256).max);
        usdc.approve(address(lp), type(uint256).max);
        _addLiquidity(mk, 50e18, 0);

        // One USDC-paid buy. The fee accrues AND `_afterSwap` spends the burn chunk in
        // the same transaction, so the bucket is already empty when this returns — the
        // budget is where the evidence lives.
        uint256 amountIn = 50_000e6;
        _buyOnWithUsdc(mk, amountIn);

        uint256 burned = (amountIn * hook.FEE_BPS() / 10_000) * hook.BURN_BPS() / 10_000;
        uint256 booked = hook.venueBurnSpent();
        assertGt(booked, 0, "a USDC burn books a real ETH cost, not zero");
        assertGt(
            booked,
            burned,
            "USDC->ETH must DIVIDE by a sub-1 price; the inverted flag multiplies and books less"
        );
    }

    function _usdcKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(usdc)),
            fee: 3000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }

    /// The creator's conversion REFUSES to sell into a venue that moved against it
    /// since an earlier block — and resumes on the next one.
    ///
    /// Both halves matter. Without the first, 90% of all fees are sandwichable. Without
    /// the second, one displacement stops creator payouts forever, and there is no
    /// admin left to fix it — the first version of this band did exactly that, because
    /// it only advanced its reference when a step SUCCEEDED.
    ///
    /// ABSOLUTE block numbers throughout: `vm.roll(vm.getBlockNumber() + 1)` twice in one test
    /// is a no-op under via-IR, which makes a working pipeline look permanently stuck.
    function test_CreatorConversionWaitsOnADisplacedVenueThenResumes() public {
        vm.roll(200);
        _buy(5 ether);
        vm.roll(201);
        hook.processConvert(address(token), true); // establishes the reference
        uint256 banked0 = hook.creatorOut(address(token));
        assertGt(banked0, 0, "the undisturbed conversion works");

        // Displace the ETH/USDC pool against the conversion: it sells ETH for USDC, so
        // it is hurt when USDC-per-ETH falls, which is what buying USDC with ETH does.
        vm.roll(202);
        _buyOn(_usdcKey(), 4 ether);
        _buy(1 ether); // fresh fees + a carrier for the automatic attempt
        uint256 pending = hook.creatorWei(address(token));
        assertGt(pending, 0, "fees are waiting to convert");

        uint256 bankedBefore = hook.creatorOut(address(token));
        hook.processConvert(address(token), true);
        assertEq(hook.creatorOut(address(token)), bankedBefore, "it waits, it does not sell into the displacement");
        assertEq(hook.creatorWei(address(token)), pending, "and the bucket is untouched");

        // ONE block is NOT enough: `_advanceRef` clamps the reference to one band-width
        // per block, so a big displacement takes several blocks to become the reference.
        // Without that clamp the attacker's price would be accepted wholesale next block
        // and the band would be worth exactly one block of delay.
        vm.roll(203);
        hook.processConvert(address(token), true);
        assertEq(hook.creatorOut(address(token)), bankedBefore, "one block does not clear a large displacement");

        // ...but it DOES clear, unaided, once the reference has walked far enough.
        uint256 resumedAt;
        for (uint256 i = 2; i <= 60; i++) {
            vm.roll(203 + i);
            hook.processConvert(address(token), true);
            if (hook.creatorOut(address(token)) > bankedBefore) { resumedAt = i; break; }
        }
        assertGt(resumedAt, 1, "the walk is what makes holding the price expensive");
        assertGt(hook.creatorOut(address(token)), bankedBefore, "and it never deadlocks");
    }

    /// The team's 20% rides the same venue and gets the same gate — it is not the
    /// creator's protection with the platform left exposed.
    function test_TeamConversionIsGatedOnTheSameBand() public {
        vm.roll(300);
        _buy(5 ether);
        vm.roll(301);
        hook.processConvert(address(token), false);
        assertGt(hook.teamOut(address(token), address(usdc)), 0, "the undisturbed team conversion works");

        vm.roll(302);
        _buyOn(_usdcKey(), 4 ether);
        _buy(1 ether);
        uint256 before = hook.teamOut(address(token), address(usdc));
        hook.processConvert(address(token), false);
        assertEq(hook.teamOut(address(token), address(usdc)), before, "the team slice waits too");

        vm.roll(303);
        hook.processConvert(address(token), false);
        assertEq(hook.teamOut(address(token), address(usdc)), before, "one block does not clear it either");
        bool resumed;
        for (uint256 i = 2; i <= 60; i++) {
            vm.roll(303 + i);
            hook.processConvert(address(token), false);
            if (hook.teamOut(address(token), address(usdc)) > before) { resumed = true; break; }
        }
        assertTrue(resumed, "the team slice resumes once the reference has walked");
    }

    /// The same for the buy & burn, on its own venue.
    function test_BurnWaitsOnADisplacedVenueThenResumes() public {
        vm.roll(400);
        _buy(5 ether);
        vm.roll(401);
        hook.processBurn(address(token));
        uint256 dead0 = bodkin.balanceOf(DEAD);
        assertGt(dead0, 0, "the undisturbed burn works");

        // Make BODKIN dearer in ETH: buy it.
        vm.roll(402);
        _buyOn(bodkinPoolKey, 3 ether);
        _buy(1 ether);
        uint256 deadBefore = bodkin.balanceOf(DEAD);
        hook.processBurn(address(token));
        assertEq(
            bodkin.balanceOf(DEAD),
            deadBefore,
            "the burn waits rather than buying BODKIN at the displaced price"
        );

        vm.roll(403);
        hook.processBurn(address(token));
        assertEq(bodkin.balanceOf(DEAD), deadBefore, "one block does not clear it either");
        bool burnResumed;
        for (uint256 i = 2; i <= 60; i++) {
            vm.roll(403 + i);
            hook.processBurn(address(token));
            if (bodkin.balanceOf(DEAD) > deadBefore) { burnResumed = true; break; }
        }
        assertTrue(burnResumed, "the burn resumes once the reference has walked");
    }

    function _launchKey(FeeHook h, address meme) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(meme),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(h))
        });
    }

    /// `burnStep` is the swap-path entrypoint and must be unreachable from outside —
    /// it moves money and skips the unlock that an external caller would need.
    function test_BurnStepIsNotCallableExternally() public {
        vm.expectRevert(FeeHook.NotManager.selector);
        hook.burnStep(address(token));
    }

    /// Claiming is a TRANSFER, not a conversion, so there is no price to be wrong about.
    /// This replaces a test that asserted the claim reverts on an unreachable floor —
    /// the floor is gone along with the swap it used to protect.
    function test_ClaimingIsAPureTransferAndCannotRevertOnPrice() public {
        _buy(2 ether);
        // The buy itself already converted the creator's slice into the payout token.
        uint256 banked = hook.creatorOut(address(token));
        assertGt(banked, 0, "fees arrive ALREADY in USDC, not in the numeraire");

        uint256 before = usdc.balanceOf(creator);
        vm.prank(creator);
        uint256 paid = hook.claimCreator(address(token));

        assertEq(paid, banked, "pays exactly what was banked -- no swap, no slippage");
        assertEq(usdc.balanceOf(creator) - before, paid);
        assertEq(hook.creatorOut(address(token)), 0);

        // And a second claim is a no-op rather than a revert.
        vm.prank(creator);
        assertEq(hook.claimCreator(address(token)), 0, "nothing banked -> nothing paid");
    }

    /// The fee is denominated in the payout token from the moment it is earned. That is
    /// the whole point of converting on the swap path rather than at claim time: the
    /// creator is never left holding the numeraire while they wait to click.
    function test_FeesAreBankedInThePayoutTokenNotTheNumeraire() public {
        _buy(2 ether);
        assertGt(hook.creatorOut(address(token)), 0, "creator slice banked in USDC");
        assertGt(hook.teamOut(address(token), address(usdc)), 0, "team slice too");
        // The numeraire waiting room drained in the same transaction.
        assertEq(hook.creatorWei(address(token)), 0, "nothing left waiting");
    }

    // (The old `test_ProcessBurnRevertsOnSlippage` is gone with the parameter it tested.
    //  A caller-supplied floor on a call ANYONE can make was never protection — an
    //  attacker simply passes 0 — and it is now replaced by a size cap the caller has no
    //  say in. Removing it also removes the last way the burn could revert, which is what
    //  lets a swap carry it. See `test_ASwapSucceedsEvenWhenTheBurnCannotRun`.)

    // ---- custom payout token (any token routable on Uniswap) ----

    function test_CreatorClaimsCustomTokenDirect() public {
        // An RWA-style token with its own (ETH, RWA) pool → single-hop conversion.
        MockToken rwa = new MockToken();
        _openEthPool(address(rwa), 10e18);
        (MockToken meme, PoolKey memory k) =
            _newLaunchWith(address(rwa), false, PAYOUT_FEE, TICK_SPACING, address(0), address(0));

        _buyOn(k, 2 ether);
        assertGt(hook.creatorOut(address(meme)), 0, "fee accrued and banked");

        vm.prank(creator);
        uint256 paid = hook.claimCreator(address(meme));

        assertGt(rwa.balanceOf(creator), 0, "creator paid in the custom token");
        assertEq(rwa.balanceOf(creator), paid, "return value = delivered amount");
        assertEq(hook.creatorOut(address(meme)), 0, "banked balance paid out in full");
        assertEq(usdc.balanceOf(address(hook)), 0, "no USDC touched on the direct route");
    }

    function test_CreatorFallsBackToNumeraireWhenPayoutPoolIsDry() public {
        // A custom-payout launch whose (ETH, RWA) pool has liquidity at launch, then is
        // drained. Fees earned while liquid convert to RWA; once there is no route, that
        // swap's fee falls back to ETH (the numeraire) instead of stranding — decided per
        // swap, no mode. The claim then pays BOTH legs (RWA + the ETH fallback).
        MockToken rwa = new MockToken();
        PoolKey memory rwaPool = _openEthPool(address(rwa), 10e18);
        (MockToken meme, PoolKey memory k) =
            _newLaunchWith(address(rwa), false, PAYOUT_FEE, TICK_SPACING, address(0), address(0));

        // 1) Pool liquid → the fee converts to the custom token, nothing falls back.
        _buyOn(k, 2 ether);
        uint256 inToken = hook.creatorOut(address(meme));
        assertGt(inToken, 0, "converted to the custom token while liquid");
        assertEq(hook.creatorOutNum(address(meme)), 0, "no fallback while liquid");

        // 2) Drain the payout pool → its whole-route cap is 0 (no healthy route).
        _addLiquidity(rwaPool, -10e18, 0);

        // 3) The next swap's fee has no route → it falls back to ETH this swap.
        vm.roll(vm.getBlockNumber() + 1);
        _buyOn(k, 2 ether);
        uint256 inNum = hook.creatorOutNum(address(meme));
        assertGt(inNum, 0, "no route -> the slice fell back to the numeraire, not stranded");
        assertEq(hook.creatorWei(address(meme)), 0, "waiting room drained into the fallback");
        assertEq(hook.creatorOut(address(meme)), inToken, "the payout-token leg is untouched");

        // 4) One claim pays BOTH currencies: the custom token AND the ETH fallback.
        uint256 ethBefore = creator.balance;
        vm.prank(creator);
        uint256 paid = hook.claimCreator(address(meme));

        assertEq(paid, inToken, "return value = the payout-token leg");
        assertEq(rwa.balanceOf(creator), inToken, "creator paid the custom-token leg");
        assertEq(creator.balance - ethBefore, inNum, "creator paid the ETH fallback leg");
        assertEq(hook.creatorOut(address(meme)), 0, "payout-token leg settled");
        assertEq(hook.creatorOutNum(address(meme)), 0, "fallback leg settled");
    }

    function test_ConversionResumesToTheTokenAfterLiquidityReturns() public {
        // The fallback is PER SWAP, not a mode: a pool that was healthy, went dry, then came
        // back converts to the chosen token again with nothing to un-set.
        MockToken rwa = new MockToken();
        PoolKey memory rwaPool = _openEthPool(address(rwa), 10e18);
        (MockToken meme, PoolKey memory k) =
            _newLaunchWith(address(rwa), false, PAYOUT_FEE, TICK_SPACING, address(0), address(0));

        // Healthy → converts to the chosen token.
        _buyOn(k, 2 ether);
        uint256 tokenBefore = hook.creatorOut(address(meme));
        assertGt(tokenBefore, 0, "converts to the token while healthy");

        // Drain → the next swap has no route and falls back to ETH.
        _addLiquidity(rwaPool, -10e18, 0);
        vm.roll(vm.getBlockNumber() + 1);
        _buyOn(k, 2 ether);
        uint256 fellBack = hook.creatorOutNum(address(meme));
        assertGt(fellBack, 0, "no route -> fell back to ETH");

        // Refill -> the route is healthy again, and the fallback was never a "mode": new fees convert
        // into the chosen token again, with nothing to un-set. This used to assert that they merely
        // WAITED in creatorWei, which was an artifact of a broken test: `vm.roll(block.number + 1)`
        // reads a block number the compiler had already cached, so every roll after the first in a
        // function was a no-op and the anti-sandwich band's reference never walked. With the blocks
        // actually advancing, the band recovers and the conversions go through.
        _addLiquidity(rwaPool, 10e18, 200 ether);
        for (uint256 i = 0; i < 3; i++) {
            vm.roll(vm.getBlockNumber() + 1);
            _buyOn(k, 2 ether);
        }
        assertGt(hook.creatorOut(address(meme)), tokenBefore, "route back -> conversions resume into the token");
        assertEq(hook.creatorOutNum(address(meme)), fellBack, "and no NEW ETH fallback once a route is back");
        assertEq(hook.creatorWei(address(meme)), 0, "nothing left waiting");
    }

    function test_DeepPayoutPoolNeverFallsBack() public {
        // A healthy, always-routable payout pool (stand-in for a USDC/PEPE pool) must NEVER
        // touch the fallback — every fee converts to the chosen token. Full-range liquidity
        // is always in range, so getLiquidity stays > 0 through every trade.
        MockToken rwa = new MockToken();
        _openEthPool(address(rwa), 10e18);
        (MockToken meme, PoolKey memory k) =
            _newLaunchWith(address(rwa), false, PAYOUT_FEE, TICK_SPACING, address(0), address(0));

        for (uint256 i = 0; i < 5; i++) {
            vm.roll(vm.getBlockNumber() + 1);
            _buyOn(k, 3 ether);
        }
        assertGt(hook.creatorOut(address(meme)), 0, "fees convert to the chosen token");
        assertEq(hook.creatorOutNum(address(meme)), 0, "a healthy pool never falls back");
    }

    // ---- WETH-paired payout (token whose liquidity is a V4 (WETH, token) pool) ----

    function test_WethPairedPayoutConvertsOnlyViaProcessConvert() public {
        MockToken rwa = new MockToken();
        _openWethPool(address(rwa), 10e18);
        (MockToken meme, PoolKey memory k) = _newLaunchWethPaid(address(rwa));

        // Swaps accrue the creator slice but must NOT convert it — the ETH->WETH wrap is an
        // external call that cannot ride a stranger's swap, so convertStep leaves it pending.
        _buyOn(k, 2 ether);
        assertGt(hook.creatorWei(address(meme)), 0, "slice pending in the ETH bucket");
        assertEq(hook.creatorOut(address(meme)), 0, "not converted on a swap (skipped)");
        assertEq(hook.creatorOutNum(address(meme)), 0, "and NOT fallen back to the numeraire");

        // processConvert (own tx) wraps ETH -> WETH and swaps the (WETH, RWA) pool.
        vm.roll(vm.getBlockNumber() + 1);
        uint256 banked = hook.processConvert(address(meme), true);
        assertGt(banked, 0, "processConvert converted the pending slice");
        assertGt(hook.creatorOut(address(meme)), 0, "banked in the WETH-paired payout token");
        assertEq(hook.creatorOutNum(address(meme)), 0, "no numeraire fallback while the WETH pool is liquid");

        // The creator claims and receives the RWA token, not ETH/USDC.
        vm.prank(creator);
        uint256 paid = hook.claimCreator(address(meme));
        assertEq(paid, banked, "claim delivers exactly what was banked");
        assertGt(rwa.balanceOf(creator), 0, "creator paid in the WETH-paired token");
        assertEq(rwa.balanceOf(creator), paid, "return value = delivered amount");
    }

    function test_WethPairedPayoutNeverBlocksASwap() public {
        MockToken rwa = new MockToken();
        _openWethPool(address(rwa), 10e18);
        (MockToken meme, PoolKey memory k) = _newLaunchWethPaid(address(rwa));
        // Five swaps: none may revert on the WETH wrap (it never rides a swap); the slice just
        // keeps accruing in the ETH bucket for processConvert to drain later.
        for (uint256 i = 0; i < 5; i++) {
            vm.roll(vm.getBlockNumber() + 1);
            _buyOn(k, 1 ether);
        }
        assertGt(hook.creatorWei(address(meme)), 0, "slice accrued, never stranded or reverted");
        assertEq(hook.creatorOut(address(meme)), 0, "never converted on a swap");
        assertEq(hook.creatorOutNum(address(meme)), 0, "never fell back either");
    }

    function test_WethPairedDryPoolFallsBackToNumeraire() public {
        // A WETH-paired payout whose (WETH, token) pool goes DRY must fall back to the numeraire, EXACTLY
        // like every other dry creator route — not sit pending forever. Same fallback logic, now on the
        // WETH path too: a dry route is a pure storage reclassify (no wrap, no pool), safe on the swap.
        MockToken rwa = new MockToken();
        PoolKey memory wethPool = _openWethPool(address(rwa), 10e18);
        (MockToken meme, PoolKey memory k) = _newLaunchWethPaid(address(rwa));

        // While the WETH pool is liquid the slice accrues pending (converts only via processConvert).
        _buyOn(k, 2 ether);
        assertGt(hook.creatorWei(address(meme)), 0, "slice pending while the WETH pool is liquid");
        assertEq(hook.creatorOutNum(address(meme)), 0, "no fallback while liquid");

        // The WETH payout pool dries up (all its liquidity removed).
        _addLiquidity(wethPool, -10e18, 0);
        vm.roll(vm.getBlockNumber() + 1);

        // Next swap: the WETH route is dry, so the WHOLE creator bucket now falls back to ETH — the same
        // routeDry reclassify (creatorWei -> creatorOutNum) the non-WETH routes use, decided per swap.
        _buyOn(k, 2 ether);
        uint256 inNum = hook.creatorOutNum(address(meme));
        assertGt(inNum, 0, "dry WETH pool -> fell back to the numeraire (ETH)");
        assertEq(hook.creatorWei(address(meme)), 0, "the pending bucket was fully reclassified, not stranded");

        // The creator claims and receives the ETH fallback in full.
        uint256 ethBefore = creator.balance;
        vm.prank(creator);
        hook.claimCreator(address(meme));
        assertEq(creator.balance - ethBefore, inNum, "ETH fallback delivered");
        assertEq(hook.creatorOutNum(address(meme)), 0, "fallback leg settled");
    }

    function test_FallbackClaimSurvivesADeadPayoutToken() public {
        // The HIGH-severity case the review caught: the payout token's pool dies AND its
        // transfers start reverting (a rugged/paused token). The numeraire fallback the
        // creator is owed must still be claimable — the dead token's failing delivery leg
        // must not take the whole claim down with it.
        RevertOnFlagToken bad = new RevertOnFlagToken();
        PoolKey memory badPool = _openEthPool(address(bad), 10e18);
        (MockToken meme, PoolKey memory k) =
            _newLaunchWith(address(bad), false, PAYOUT_FEE, TICK_SPACING, address(0), address(0));

        // Earn some fees in the bad token while its pool is alive.
        _buyOn(k, 2 ether);
        assertGt(hook.creatorOut(address(meme)), 0, "banked some bad-token fees");

        // Pool dies; the next swap's fee has no route and falls back to ETH.
        _addLiquidity(badPool, -10e18, 0);
        vm.roll(vm.getBlockNumber() + 1);
        _buyOn(k, 2 ether); // no route -> falls back to ETH this swap
        uint256 inNum = hook.creatorOutNum(address(meme));
        assertGt(inNum, 0, "fell back to ETH");

        // Now make the bad token's transfers revert, then claim. The bad-token leg fails
        // (its balance stays banked), but the ETH fallback is delivered in full.
        bad.setReverting(true);
        uint256 ethBefore = creator.balance;
        vm.prank(creator);
        hook.claimCreator(address(meme));

        assertEq(creator.balance - ethBefore, inNum, "ETH fallback delivered despite the dead token");
        assertEq(hook.creatorOutNum(address(meme)), 0, "fallback leg settled");
        assertGt(hook.creatorOut(address(meme)), 0, "the un-deliverable bad-token leg stays banked for later");
    }

    function test_CreatorClaimsCustomTokenViaUsdc() public {
        // A token with NO ETH pair, only a USDC pair → ETH→USDC→token (2 hops).
        MockToken rwa = _tokenSortedVsUsdc(true);
        _openUsdcPool(address(rwa), 10e18);
        (MockToken meme, PoolKey memory k) =
            _newLaunchWith(address(rwa), true, PAYOUT_FEE, TICK_SPACING, address(0), address(0));

        _buyOn(k, 2 ether);
        // Already converted through both hops by the buy itself — so the evidence is the
        // BANKED balance, not the numeraire waiting room.
        uint256 owed = hook.creatorOut(address(meme));
        assertGt(owed, 0, "fee accrued and converted across the USDC hop");

        vm.prank(creator);
        uint256 paid = hook.claimCreator(address(meme));

        assertGt(paid, 0, "creator paid via the USDC hop");
        assertEq(rwa.balanceOf(creator), paid, "creator holds the payout token");
        // The intermediate must leave NOTHING behind in the hook.
        assertEq(usdc.balanceOf(address(hook)), 0, "no loose USDC in the hook");
        // USDC is the INTERMEDIATE of this route, and it must net to exactly zero — the
        // +got1 credit and the -got1 debt cancel inside one unlock. But the hook now also
        // BANKS the team's slice in USDC (the default team payout), so the right assertion
        // is "holds the banked amount and not a wei more", not "holds nothing". Asserting
        // zero here would fail for a legitimate reason and hide a real leak behind it.
        assertEq(
            manager.balanceOf(address(hook), uint160(address(usdc))),
            hook.teamOut(address(meme), address(usdc)),
            "the intermediate leaked nothing -- only the team's banked slice remains"
        );
        assertEq(hook.creatorOut(address(meme)), 0, "banked balance paid out in full");
    }

    function test_ViaUsdcBothSortOrders() public {
        // The (USDC, token) leg must work with USDC as currency0 AND as currency1 —
        // the direction/price-limit are derived, never assumed. This is the most
        // likely production break, so cover both explicitly.
        MockToken above = _tokenSortedVsUsdc(true); // usdc < payout → USDC is currency0
        MockToken below = _tokenSortedVsUsdc(false); // payout < usdc → USDC is currency1
        assertTrue(address(above) > address(usdc), "payout sorts above usdc");
        assertTrue(address(below) < address(usdc), "payout sorts below usdc");
        _openUsdcPool(address(above), 10e18);
        _openUsdcPool(address(below), 10e18);

        // One launch per sort order, each with its own hooked (ETH, meme) pool.
        (MockToken memeA, PoolKey memory keyA) =
            _newLaunchWith(address(above), true, PAYOUT_FEE, TICK_SPACING, address(0), address(0));
        (MockToken memeB, PoolKey memory keyB) =
            _newLaunchWith(address(below), true, PAYOUT_FEE, TICK_SPACING, address(0), address(0));

        _buyOn(keyA, 2 ether);
        _buyOn(keyB, 2 ether);
        assertGt(hook.creatorOut(address(memeA)), 0, "A accrued");
        assertGt(hook.creatorOut(address(memeB)), 0, "B accrued");

        vm.prank(creator);
        uint256 pA = hook.claimCreator(address(memeA));
        vm.prank(creator);
        uint256 pB = hook.claimCreator(address(memeB));

        assertGt(pA, 0, "USDC-as-currency0 leg delivered");
        assertGt(pB, 0, "USDC-as-currency1 leg delivered");
        assertEq(above.balanceOf(creator), pA, "creator got the above-usdc token");
        assertEq(below.balanceOf(creator), pB, "creator got the below-usdc token");
        assertEq(usdc.balanceOf(address(hook)), 0, "no USDC stranded either way");
    }

    function test_ViaUsdcNonEighteenDecimalPayout() public {
        // Payout tokens don't have to be 18-decimal (RWAs/stables often aren't).
        MockUSDC six = new MockUSDC();
        _openUsdcPool(address(six), 10e18);
        (MockToken meme, PoolKey memory k) =
            _newLaunchWith(address(six), true, PAYOUT_FEE, TICK_SPACING, address(0), address(0));

        _buyOn(k, 2 ether);
        vm.prank(creator);
        uint256 paid = hook.claimCreator(address(meme));

        assertGt(paid, 0, "6-decimal payout delivered");
        assertEq(six.balanceOf(creator), paid);
        assertEq(usdc.balanceOf(address(hook)), 0, "no USDC stranded");
    }

    /// A creator directs their fee stream elsewhere by having the fee NFT MINTED there —
    /// not by an override in the hook. So the destination wallet is also the only one
    /// that can claim, and the income stays attached to (and sellable with) the NFT.
    ///
    /// The hook used to carry a `recipient` that paid a fixed address while a different
    /// wallet triggered the claim. That decoupled the money from the NFT: transferring
    /// the "fee stream" would have moved the trigger but not the income.
    function test_FeeStreamFollowsTheNftHolder() public {
        address treasury = makeAddr("treasury");
        MockToken rwa = new MockToken();
        _openEthPool(address(rwa), 10e18);
        // The launcher minted the NFT to the treasury, so the treasury IS the creator.
        (MockToken meme, PoolKey memory k) =
            _newLaunchWith(address(rwa), false, PAYOUT_FEE, TICK_SPACING, treasury, address(0));
        assertEq(hook.payoutRecipientOf(address(meme)), treasury, "recipient is the holder");

        _buyOn(k, 2 ether);

        // The wallet that launched but does NOT hold the NFT cannot claim at all.
        vm.prank(creator);
        vm.expectRevert(FeeHook.NotCreator.selector);
        hook.claimCreator(address(meme));

        vm.prank(treasury);
        uint256 paid = hook.claimCreator(address(meme));
        assertGt(paid, 0, "treasury claimed something");
        assertEq(rwa.balanceOf(treasury), paid, "and receives it");
        assertEq(rwa.balanceOf(creator), 0, "launching wallet untouched");
    }

    /// And with no chosen wallet, it is simply whoever holds the NFT — one address for
    /// both the permission and the payout.
    function test_ClaimerAndPayeeAreTheSameAddress() public {
        (MockToken meme, PoolKey memory k) = _newLaunch();
        _buyOn(k, 1 ether);
        uint256 before = usdc.balanceOf(creator);
        vm.prank(creator);
        uint256 paid = hook.claimCreator(address(meme));
        assertEq(usdc.balanceOf(creator) - before, paid, "the caller is the payee");
    }

    /// A dust-liquidity payout pool no longer costs anyone a reverted claim. The
    /// conversion is chunked, so a thin pool simply converts LESS per block: the
    /// remainder waits in the numeraire bucket and nothing is stranded or lost.
    function test_AThinPayoutPoolDelaysTheConversionInsteadOfFailingIt() public {
        MockToken rwa = _tokenSortedVsUsdc(true);
        _openUsdcPool(address(rwa), 1e6); // dust liquidity
        (MockToken meme, PoolKey memory k) =
            _newLaunchWith(address(rwa), true, PAYOUT_FEE, TICK_SPACING, address(0), address(0));

        _buyOn(k, 5 ether); // large fee vs. a dust pool -- cannot convert in one go

        uint256 waiting = hook.creatorWei(address(meme));
        assertGt(waiting, 0, "the bulk is still waiting, capped by the thin pool");
        assertEq(usdc.balanceOf(address(hook)), 0, "nothing stranded as loose tokens");

        // Claiming what HAS converted works and never reverts, whatever the pool's rate.
        vm.prank(creator);
        hook.claimCreator(address(meme));

        // The queue is not stuck by accident — it is PACED. Each block converts at most
        // what the thinner leg can absorb, so a dust pool converts very little and the
        // rest waits rather than being dumped into it at a terrible rate. Nothing is
        // lost: the waiting balance is still exactly the creator's.
        uint256 blk = block.number;
        for (uint256 i = 0; i < 20; i++) {
            blk++;
            vm.roll(blk);
            hook.processFees(address(meme));
        }
        assertLe(hook.creatorWei(address(meme)), waiting, "never grows");
        assertEq(usdc.balanceOf(address(hook)), 0, "still nothing stranded");
        // Nothing was lost: every wei is either banked or still queued.
        assertGt(hook.creatorOut(address(meme)) + hook.creatorWei(address(meme)), 0, "no wei lost");
    }

    function test_OnlyLauncherCanOpenHookedPool() public {
        // PoolManager.initialize is permissionless, so the hook itself must refuse
        // anyone but the launcher. Otherwise a bystander could (a) front-run a
        // pending launch() by initializing its pool first — the launch reverts and
        // the creator loses gas + the pinned metadata + the mined salt — or (b) open
        // a second hooked pool for an existing token, feeding its fee buckets from a
        // pool the launchpad never sanctioned.
        MockToken victim = new MockToken();
        hook.setLaunchConfig(address(victim), address(usdc), false, false, 0, 0, address(0), false, 0, 0, false);
        PoolKey memory squatted = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(victim)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(); // wrapped by the PoolManager's hook-call revert
        manager.initialize(squatted, SQRT_PRICE_1_1);

        // The launcher (this test) can still open it — the pool wasn't bricked.
        int24 tick = manager.initialize(squatted, SQRT_PRICE_1_1);
        assertEq(tick, 0, "launcher opened the pool at 1:1");
    }

    function test_ConversionPoolsAreOneShot() public {
        // Both pools were wired in setUp. Even the owner (this test) can never
        // re-point them at a hostile thin-LP pool to drain fee conversions.
        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(usdc)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        vm.expectRevert(bytes("FeeHook: usdc pool set"));
        hook.setUsdcPool(k);

        PoolKey memory b = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(bodkin)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        vm.expectRevert(bytes("FeeHook: bodkin pool set"));
        hook.setBodkinPool(b);
    }

    receive() external payable {}

    /// Audit fix order #8. An exact-input buy pays its 1% in `beforeSwap`, off the FULL
    /// requested input — before the pool has revealed how much it can absorb. A price-
    /// limited swap that only partially fills would therefore be charged on numeraire
    /// that never swapped. There is no refund path (the fee sits on the specified side),
    /// so the hook must refuse the fill — matching the V4Quoter, which reverts rather
    /// than quote a partial fill. This is the guard that keeps the overcharge
    /// unreachable even if a future deployment sets a tiny startFdvOf, which is
    /// constructor-only on an ownerless launcher and impossible to correct later.
    function test_PriceLimitedPartialFillBuyReverts() public {
        // Pool sits exactly at SQRT_PRICE_1_1. Allow the price to move only ~0.2%
        // down, then ask to swap far more than that tolerance can absorb: the pool
        // stops at the limit with most of the input unconsumed.
        uint160 limit = uint160((uint256(SQRT_PRICE_1_1) * 999) / 1000);
        vm.expectRevert(); // FeeHook.PartialFill, wrapped by v4-core's hook-call bubbling
        swapRouter.swap{value: 10 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(10 ether), sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Same size with an unbounded limit fills whole and passes — proving the
        // revert above is about the PARTIAL fill, not the size.
        _buyOn(key, 10 ether);
    }

    // ── fallback audit: every conversion site, every claim leg, under a USDC / WETH re-point ──

    /// Stand up a NEW usdc + its (ETH, newUsdc) conversion pool and migrate the hook to it.
    function _migrateToNewUsdc() internal returns (MockUSDC newUsdc) {
        newUsdc = new MockUSDC();
        PoolKey memory newPool = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(newUsdc)),
            fee: 3000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        manager.initialize(newPool, SQRT_PRICE_1_1);
        newUsdc.approve(address(lp), type(uint256).max);
        _addLiquidity(newPool, 10e18, 200 ether);
        hook.migrateUsdc(address(newUsdc), newPool);
    }

    /// A WETH re-point (the 2-of-2 escape hatch) leaves an existing WETH-paired launch with no
    /// (newWETH, token) pool. Its ongoing creator fees fall back to the numeraire instead of
    /// sitting pending; what was converted before stays in the token; one claim pays both legs.
    function test_WethRepoint_WethPairedLaunchFallsBackToNumeraire() public {
        MockToken rwa = new MockToken();
        _openWethPool(address(rwa), 10e18);
        (MockToken meme, PoolKey memory k) = _newLaunchWethPaid(address(rwa));

        // Healthy: the swap leaves the slice pending (a wrap never rides a stranger's swap) and the
        // permissionless step converts it through the (WETH, rwa) pool.
        _buyOn(k, 2 ether);
        assertGt(hook.creatorWei(address(meme)), 0, "pending for processConvert while WETH is live");
        hook.processConvert(address(meme), true);
        uint256 inRwa = hook.creatorOut(address(meme));
        assertGt(inRwa, 0, "converted into the WETH-paired token");

        // Governance re-points WETH to a fresh contract that has no (WETH2, rwa) pool.
        MockWETH weth2 = new MockWETH();
        uint8 wethSel = hook.FEE_TOKEN_WETH();
        hook.setFeeToken(wethSel, address(weth2));

        vm.roll(vm.getBlockNumber() + 1);
        _buyOn(k, 2 ether);
        uint256 inEth = hook.creatorOutNum(address(meme));
        assertGt(inEth, 0, "no (newWETH, rwa) pool -> the slice fell back to ETH");
        assertEq(hook.creatorWei(address(meme)), 0, "nothing left pending");
        assertEq(hook.creatorOut(address(meme)), inRwa, "the earlier token leg is untouched");

        uint256 ethBefore = creator.balance;
        vm.prank(creator);
        hook.claimCreator(address(meme));
        assertEq(rwa.balanceOf(creator), inRwa, "token leg delivered");
        assertEq(creator.balance, ethBefore + inEth, "ETH fallback delivered");
    }

    /// WETH DISABLED (re-pointed to address(0)) while a plain (ETH, token) pool at the same tier
    /// exists — the pair key (address(0), token) then IS that pool, so the route used to read as a
    /// healthy WETH leg and the slice sat pending forever behind a wrap that can only revert. It
    /// now falls back to the numeraire like every other dry route.
    function test_WethDisabled_WethPairedLaunchFallsBackEvenWhenAnEthPoolMatchesTheKey() public {
        MockToken rwa = new MockToken();
        _openWethPool(address(rwa), 10e18);
        (MockToken meme, PoolKey memory k) = _newLaunchWethPaid(address(rwa));
        _openEthPool(address(rwa), 10e18); // the trap: (ETH, rwa) at PAYOUT_FEE / TICK_SPACING

        uint8 wethSel = hook.FEE_TOKEN_WETH();
        hook.setFeeToken(wethSel, address(0));
        assertEq(hook.weth(), address(0), "WETH payouts disabled");

        _buyOn(k, 2 ether);
        assertEq(hook.creatorWei(address(meme)), 0, "nothing pending behind a wrap that cannot run");
        uint256 inEth = hook.creatorOutNum(address(meme));
        assertGt(inEth, 0, "fell back to ETH on the swap path");
        assertEq(hook.processConvert(address(meme), true), 0, "the manual step has nothing to do and does not revert");

        uint256 ethBefore = creator.balance;
        vm.prank(creator);
        hook.claimCreator(address(meme));
        assertEq(creator.balance, ethBefore + inEth, "claimable in ETH");
        assertEq(rwa.balanceOf(creator), 0, "no token leg was ever produced");
    }

    /// An ETH-quoted launch on the DEFAULT payout (USDC pinned at launch) after a USDC migration:
    /// the pinned old USDC is no longer the canonical hub, its fee-0 default route reaches no pool,
    /// so ongoing creator fees fall back to ETH; the already-banked old-USDC slice stays claimable in
    /// old USDC. One claim delivers both — and a dead old-USDC leg cannot block the ETH leg.
    function test_UsdcMigration_EthLaunchDefaultPayout_OngoingFeesFallBackToEth_BankedStayOldUsdc() public {
        _buy(2 ether);
        uint256 inOldUsdc = hook.creatorOut(address(token));
        assertGt(inOldUsdc, 0, "pre-migration creator fee banked in old usdc");

        _migrateToNewUsdc();
        assertEq(hook.payoutTokenOf(address(token)), address(usdc), "payout stays pinned to the old usdc");

        vm.roll(vm.getBlockNumber() + 1);
        _buy(2 ether);
        uint256 inEth = hook.creatorOutNum(address(token));
        assertGt(inEth, 0, "ongoing creator fee fell back to ETH (no route to the deprecated usdc)");
        assertEq(hook.creatorWei(address(token)), 0, "nothing stranded in the waiting room");
        assertEq(hook.creatorOut(address(token)), inOldUsdc, "old-usdc leg intact");

        // The old usdc refuses the creator (a blocklisting stablecoin): the token leg fails and stays
        // banked, the ETH leg still pays.
        usdc.setRejects(creator, true);
        uint256 ethBefore = creator.balance;
        vm.prank(creator);
        hook.claimCreator(address(token));
        assertEq(creator.balance, ethBefore + inEth, "ETH fallback paid despite the dead usdc leg");
        assertEq(hook.creatorOut(address(token)), inOldUsdc, "usdc leg still banked, not lost");

        // Once the old usdc accepts transfers again, the banked leg is delivered in OLD usdc.
        usdc.setRejects(creator, false);
        uint256 usdcBefore = usdc.balanceOf(creator);
        vm.prank(creator);
        hook.claimCreator(address(token));
        assertEq(usdc.balanceOf(creator), usdcBefore + inOldUsdc, "old-usdc leg delivered in old usdc");
        assertEq(hook.creatorOut(address(token)), 0, "drained");
    }

    /// A custom payout reached VIA the USDC hub (numeraire -> USDC -> token): after a migration the
    /// hub is the new USDC, the (newUSDC, token) pool does not exist, and the route is dry — the
    /// creator's ongoing fees fall back to the numeraire rather than stall or route into thin air.
    function test_UsdcMigration_ViaHubCustomPayout_FallsBackToNumeraire() public {
        MockToken rwa = _tokenSortedVsUsdc(true);
        _openUsdcPool(address(rwa), 10e18);
        (MockToken meme, PoolKey memory k) =
            _newLaunchWith(address(rwa), true, PAYOUT_FEE, TICK_SPACING, address(0), address(0));

        _buyOn(k, 2 ether);
        uint256 inRwa = hook.creatorOut(address(meme));
        assertGt(inRwa, 0, "bridged ETH -> old usdc -> rwa while the hub was the old usdc");

        _migrateToNewUsdc();
        vm.roll(vm.getBlockNumber() + 1);
        _buyOn(k, 2 ether);
        assertGt(hook.creatorOutNum(address(meme)), 0, "hub moved: no (newUSDC, rwa) pool -> ETH fallback");
        assertEq(hook.creatorWei(address(meme)), 0, "nothing stranded");
        assertEq(hook.creatorOut(address(meme)), inRwa, "earlier rwa leg intact");
    }

    /// The team's payout token pointed at a custom token: the default route carries no tier, so
    /// there is no reachable pool and the team slice used to wait in `teamWei` forever. It now
    /// falls back into the numeraire (native ETH is a registered team currency from construction)
    /// and is claimable there.
    function test_TeamCustomPayoutToken_FallsBackToNumeraireInsteadOfStalling() public {
        assertTrue(hook.teamCurrencyKnown(address(0)), "native ETH is a registered team currency");
        MockToken rwa = new MockToken();
        hook.setTeamPayoutAllowed(address(rwa), true); // deployer role (this)
        hook.setTeamPayoutToken(address(rwa)); // launcher (this)

        vm.roll(vm.getBlockNumber() + 1);
        _buy(2 ether);
        uint256 inEth = hook.teamOut(address(token), address(0));
        assertGt(inEth, 0, "team slice fell back into ETH, its numeraire");
        assertEq(hook.teamWei(address(token)), 0, "not stalled in the waiting room");
        assertEq(hook.teamOut(address(token), address(rwa)), 0, "nothing banked in the unroutable token");

        uint256 before = team.balance;
        vm.prank(team);
        hook.claimTeam(address(token));
        assertEq(team.balance, before + inEth, "claimable in ETH");
    }

    /// A USDC-quoted launch after its USDC is DEPRECATED: trading keeps working, external LPs keep
    /// earning the LP slice in the old USDC and can claim it, the creator's and team's fees fall
    /// back into the old USDC, and the buy&burn (no route to BODKIN from a stale numeraire) is
    /// simply paused — its bucket accrues, nothing reverts.
    function test_StaleNumeraireLaunch_LpRewardsClaimable_BurnPauses_NoRevert() public {
        MockPositionManager pm = new MockPositionManager(manager);
        hook.setPositionManager(address(pm));

        MockToken meme = _tokenSortedVsUsdc(true);
        creatorNFT.set(address(meme), creator);
        hook.setLaunchConfig(address(meme), address(usdc), false, false, 0, 0, address(usdc), false, 0, 0, false);
        PoolKey memory mk = PoolKey({
            currency0: Currency.wrap(address(usdc)),
            currency1: Currency.wrap(address(meme)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        manager.initialize(mk, SQRT_PRICE_1_1);
        meme.approve(address(lp), type(uint256).max);
        usdc.approve(address(lp), type(uint256).max);
        _addLiquidity(mk, 50e18, 0);

        // An external LP position (tokenId 7) minted through the "PositionManager".
        address lpOwner = address(0x1B);
        pm.setOwner(7, lpOwner);
        meme.approve(address(pm), type(uint256).max);
        usdc.approve(address(pm), type(uint256).max);
        pm.modifyLiquidity(
            mk,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: 5e18,
                salt: bytes32(uint256(7))
            }),
            ""
        );

        _buyOnWithUsdc(mk, 50_000e6);
        uint256 owedBefore = hook.lpRewardsOwed(address(meme), 7);
        assertGt(owedBefore, 0, "LP earns while the usdc is canonical");

        _migrateToNewUsdc();
        vm.roll(vm.getBlockNumber() + 1);
        uint256 burnAtMigration = hook.burnWei(address(meme));
        uint256 creatorBefore = hook.creatorOut(address(meme));

        _buyOnWithUsdc(mk, 50_000e6); // must not revert on a stale-numeraire pool
        assertGt(hook.lpRewardsOwed(address(meme), 7), owedBefore, "LP keeps earning in the old usdc");
        assertGt(hook.burnWei(address(meme)), burnAtMigration, "burn bucket accrues but is not spent (paused)");
        // The creator's payout IS the (old) usdc numeraire, so it banks losslessly (no swap) as before.
        assertGt(hook.creatorOut(address(meme)), creatorBefore, "creator fee keeps banking in old usdc");
        assertEq(hook.creatorWei(address(meme)), 0, "nothing stranded for the creator");
        assertGt(hook.teamOut(address(meme), address(usdc)), 0, "team fee fell back into old usdc");

        // The LP claim pays the position's owner in the old usdc — permissionless to trigger.
        uint256 owed = hook.lpRewardsOwed(address(meme), 7);
        uint256 before = usdc.balanceOf(lpOwner);
        vm.prank(address(0xD15C));
        hook.claimLpRewards(address(meme), 7);
        assertEq(usdc.balanceOf(lpOwner), before + owed, "LP reward delivered in the old usdc");
        assertEq(hook.lpRewardsOwed(address(meme), 7), 0, "settled");
    }

    /// A position closed on UNISWAP (the PositionManager burns the NFT before it removes the liquidity)
    /// keeps its unclaimed reward: the hook remembers the last owner and {claimLpRewards} still pays it.
    function test_LpRewardsClaimableAfterUniswapBurn() public {
        MockPositionManager pm = new MockPositionManager(manager);
        hook.setPositionManager(address(pm));

        MockToken meme = _tokenSortedVsUsdc(true);
        creatorNFT.set(address(meme), creator);
        hook.setLaunchConfig(address(meme), address(usdc), false, false, 0, 0, address(usdc), false, 0, 0, false);
        PoolKey memory mk = PoolKey({
            currency0: Currency.wrap(address(usdc)),
            currency1: Currency.wrap(address(meme)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        manager.initialize(mk, SQRT_PRICE_1_1);
        meme.approve(address(lp), type(uint256).max);
        usdc.approve(address(lp), type(uint256).max);
        _addLiquidity(mk, 50e18, 0);

        address lpOwner = address(0x1B);
        pm.setOwner(9, lpOwner);
        meme.approve(address(pm), type(uint256).max);
        usdc.approve(address(pm), type(uint256).max);
        int24 lo = TickMath.minUsableTick(TICK_SPACING);
        int24 hi = TickMath.maxUsableTick(TICK_SPACING);
        pm.modifyLiquidity(mk, ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: 5e18, salt: bytes32(uint256(9))}), "");
        assertEq(hook.lpRewardRecipient(address(meme), 9), lpOwner, "owner recorded on add");

        _buyOnWithUsdc(mk, 50_000e6);
        uint256 owed = hook.lpRewardsOwed(address(meme), 9);
        assertGt(owed, 0, "earned while open");

        // Close on Uniswap without claiming: NFT gone, liquidity out.
        vm.prank(lpOwner);
        pm.burn(9, mk, lo, hi, 5e18);
        vm.expectRevert(bytes("no such position"));
        pm.ownerOf(9);

        // The reward survived the burn, still attributed to the owner, and a later swap adds nothing
        // more (no liquidity left) but does not disturb it.
        assertEq(hook.lpRewardsOwed(address(meme), 9), owed, "owed checkpointed at the burn");
        assertEq(hook.lpRewardRecipient(address(meme), 9), lpOwner, "last owner remembered");
        _buyOnWithUsdc(mk, 10_000e6);
        assertEq(hook.lpRewardsOwed(address(meme), 9), owed, "closed position earns nothing more");

        uint256 before = usdc.balanceOf(lpOwner);
        vm.prank(address(0xD15C)); // permissionless trigger
        uint256 paid = hook.claimLpRewards(address(meme), 9);
        assertEq(paid, owed, "paid the checkpointed reward");
        assertEq(usdc.balanceOf(lpOwner), before + owed, "delivered to the last owner");
        assertEq(hook.lpRewardsOwed(address(meme), 9), 0, "settled");
        // Nothing to claim twice.
        vm.prank(address(0xD15C));
        assertEq(hook.claimLpRewards(address(meme), 9), 0, "no double pay");
    }

    // ── A second PositionManager (e.g. a newer Uniswap one) added after deploy ────────────────────

    event LpRewardsClaimed(address indexed token, uint256 indexed tokenId, address indexed to, uint256 amount);
    event LpRewardsClaimedVia(
        address indexed token, address indexed positionManager, uint256 indexed tokenId, address to, uint256 amount
    );

    /// A USDC-quoted launch with base liquidity, ready for an external LP through `pm`.
    function _usdcLaunchForLp(MockPositionManager pm) internal returns (MockToken meme, PoolKey memory mk) {
        meme = _tokenSortedVsUsdc(true);
        creatorNFT.set(address(meme), creator);
        hook.setLaunchConfig(address(meme), address(usdc), false, false, 0, 0, address(usdc), false, 0, 0, false);
        mk = PoolKey({
            currency0: Currency.wrap(address(usdc)),
            currency1: Currency.wrap(address(meme)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        manager.initialize(mk, SQRT_PRICE_1_1);
        meme.approve(address(lp), type(uint256).max);
        usdc.approve(address(lp), type(uint256).max);
        _addLiquidity(mk, 50e18, 0);
        meme.approve(address(pm), type(uint256).max);
        usdc.approve(address(pm), type(uint256).max);
    }

    function _lpThrough(MockPositionManager pm, PoolKey memory mk, uint256 tokenId, address owner_) internal {
        pm.setOwner(tokenId, owner_);
        pm.modifyLiquidity(
            mk,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: 5e18,
                salt: bytes32(tokenId)
            }),
            ""
        );
    }

    function test_AddPositionManager_ListsItAddOnly() public {
        MockPositionManager pm1 = new MockPositionManager(manager);
        MockPositionManager pm2 = new MockPositionManager(manager);
        hook.setPositionManager(address(pm1));
        hook.addPositionManager(address(pm2)); // this test contract is the launcher
        assertTrue(hook.isPositionManager(address(pm1)), "primary listed");
        assertTrue(hook.isPositionManager(address(pm2)), "added one listed");
        address[] memory all = hook.positionManagers();
        assertEq(all.length, 2);
        assertEq(all[0], address(pm1), "primary first");
        assertEq(all[1], address(pm2));
        assertEq(hook.positionManager(), address(pm1), "the primary is not re-pointed");
    }

    function test_AddPositionManager_Refusals() public {
        MockPositionManager pm1 = new MockPositionManager(manager);
        hook.setPositionManager(address(pm1));

        MockPositionManager pm2 = new MockPositionManager(manager);
        vm.prank(address(0xBAD));
        vm.expectRevert(FeeHook.NotLauncher.selector);
        hook.addPositionManager(address(pm2));

        vm.expectRevert(FeeHook.BadPositionManager.selector);
        hook.addPositionManager(address(0));
        vm.expectRevert(FeeHook.BadPositionManager.selector);
        hook.addPositionManager(address(0xE0A)); // no code
        vm.expectRevert(FeeHook.BadPositionManager.selector);
        hook.addPositionManager(address(pm1)); // already listed
        vm.expectRevert(FeeHook.BadPositionManager.selector);
        hook.addPositionManager(address(usdc)); // has code, but no poolManager()

        // A PositionManager bound to ANOTHER PoolManager can never hold liquidity in our pools.
        MockPositionManager foreign = new MockPositionManager(new PoolManager(address(this)));
        vm.expectRevert(FeeHook.BadPositionManager.selector);
        hook.addPositionManager(address(foreign));
    }

    /// Positions minted through an ADDED PositionManager earn, are claimable through the three-argument
    /// claim (to the NFT owner of THAT PositionManager), never mix with the primary's tokenIds, and an
    /// unlisted PositionManager cannot claim.
    function test_AddedPositionManager_PositionsEarnAndClaim() public {
        MockPositionManager pm1 = new MockPositionManager(manager);
        MockPositionManager pm2 = new MockPositionManager(manager);
        hook.setPositionManager(address(pm1));
        hook.addPositionManager(address(pm2));
        (MockToken meme, PoolKey memory mk) = _usdcLaunchForLp(pm2);

        address lpOwner = address(0x1C);
        _lpThrough(pm2, mk, 7, lpOwner);
        assertEq(hook.lpRewardRecipient(address(meme), address(pm2), 7), lpOwner, "owner resolved via pm2");

        _buyOnWithUsdc(mk, 50_000e6);
        uint256 owed = hook.lpRewardsOwed(address(meme), address(pm2), 7);
        assertGt(owed, 0, "earns through the added PositionManager");
        assertEq(hook.lpRewardsOwed(address(meme), 7), 0, "not visible under the primary's tokenId 7");

        MockPositionManager stranger = new MockPositionManager(manager);
        vm.expectRevert(FeeHook.UnknownPositionManager.selector);
        hook.claimLpRewards(address(meme), address(stranger), 7);
        assertEq(hook.lpRewardsOwed(address(meme), address(stranger), 7), 0, "unlisted reads as nothing");

        uint256 before = usdc.balanceOf(lpOwner);
        vm.expectEmit(true, true, true, true, address(hook));
        emit LpRewardsClaimedVia(address(meme), address(pm2), 7, lpOwner, owed);
        vm.prank(address(0xD15C)); // permissionless trigger
        uint256 paid = hook.claimLpRewards(address(meme), address(pm2), 7);
        assertEq(paid, owed);
        assertEq(usdc.balanceOf(lpOwner), before + owed, "paid to pm2's NFT owner");
        assertEq(hook.lpRewardsOwed(address(meme), address(pm2), 7), 0, "settled");
    }

    /// The three-argument claim with the PRIMARY PositionManager is the same claim as the two-argument
    /// one, and keeps emitting the original event (what the indexer reads).
    function test_PrimaryPositionManager_ThreeArgClaimMatchesTwoArg() public {
        MockPositionManager pm1 = new MockPositionManager(manager);
        hook.setPositionManager(address(pm1));
        (MockToken meme, PoolKey memory mk) = _usdcLaunchForLp(pm1);
        address lpOwner = address(0x1D);
        _lpThrough(pm1, mk, 3, lpOwner);
        _buyOnWithUsdc(mk, 50_000e6);

        uint256 owed = hook.lpRewardsOwed(address(meme), 3);
        assertEq(hook.lpRewardsOwed(address(meme), address(pm1), 3), owed, "same book");
        vm.expectEmit(true, true, true, true, address(hook));
        emit LpRewardsClaimed(address(meme), 3, lpOwner, owed);
        assertEq(hook.claimLpRewards(address(meme), address(pm1), 3), owed);
        assertEq(hook.lpRewardsOwed(address(meme), 3), 0, "settled for the two-argument view too");
    }

    /// A position closed through the ADDED PositionManager (NFT burned first) keeps its reward: the hook
    /// remembered the owner for listed PositionManagers, not only for the primary.
    function test_AddedPositionManager_RewardSurvivesBurn() public {
        MockPositionManager pm1 = new MockPositionManager(manager);
        MockPositionManager pm2 = new MockPositionManager(manager);
        hook.setPositionManager(address(pm1));
        hook.addPositionManager(address(pm2));
        (MockToken meme, PoolKey memory mk) = _usdcLaunchForLp(pm2);
        address lpOwner = address(0x1E);
        _lpThrough(pm2, mk, 11, lpOwner);
        _buyOnWithUsdc(mk, 50_000e6);
        uint256 owed = hook.lpRewardsOwed(address(meme), address(pm2), 11);
        assertGt(owed, 0);

        vm.prank(lpOwner);
        pm2.burn(11, mk, TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), 5e18);
        assertEq(hook.lpRewardRecipient(address(meme), address(pm2), 11), lpOwner, "last owner remembered");

        uint256 before = usdc.balanceOf(lpOwner);
        assertEq(hook.claimLpRewards(address(meme), address(pm2), 11), owed);
        assertEq(usdc.balanceOf(lpOwner), before + owed);
    }

    /// Liquidity a PositionManager added BEFORE it was listed was already booked (every adder is), so
    /// once listed its open positions can claim what they earned, from the start.
    function test_PositionManagerListedLater_OpenPositionsClaimFullHistory() public {
        MockPositionManager pm1 = new MockPositionManager(manager);
        MockPositionManager pm2 = new MockPositionManager(manager);
        hook.setPositionManager(address(pm1));
        (MockToken meme, PoolKey memory mk) = _usdcLaunchForLp(pm2);
        address lpOwner = address(0x1F);
        _lpThrough(pm2, mk, 5, lpOwner); // pm2 not listed yet
        _buyOnWithUsdc(mk, 50_000e6);
        vm.expectRevert(FeeHook.UnknownPositionManager.selector);
        hook.claimLpRewards(address(meme), address(pm2), 5);

        hook.addPositionManager(address(pm2));
        uint256 owed = hook.lpRewardsOwed(address(meme), address(pm2), 5);
        assertGt(owed, 0, "earned while unlisted, claimable once listed");
        uint256 before = usdc.balanceOf(lpOwner);
        assertEq(hook.claimLpRewards(address(meme), address(pm2), 5), owed);
        assertEq(usdc.balanceOf(lpOwner), before + owed);
    }

    /// A position CLOSED through a PositionManager before the 2-of-2 listed it keeps its reward: the hook
    /// records the owner for every adder, so the claim works once the PositionManager is listed.
    function test_PositionManagerListedLater_ClosedPositionStillClaims() public {
        MockPositionManager pm1 = new MockPositionManager(manager);
        MockPositionManager pm2 = new MockPositionManager(manager);
        hook.setPositionManager(address(pm1));
        (MockToken meme, PoolKey memory mk) = _usdcLaunchForLp(pm2);
        address lpOwner = address(0x2A);
        _lpThrough(pm2, mk, 5, lpOwner); // pm2 not listed yet
        _buyOnWithUsdc(mk, 50_000e6);
        vm.prank(lpOwner);
        pm2.burn(5, mk, TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), 5e18);

        hook.addPositionManager(address(pm2));
        uint256 owed = hook.lpRewardsOwed(address(meme), address(pm2), 5);
        assertGt(owed, 0);
        assertEq(hook.lpRewardRecipient(address(meme), address(pm2), 5), lpOwner, "owner recorded while unlisted");
        uint256 before = usdc.balanceOf(lpOwner);
        assertEq(hook.claimLpRewards(address(meme), address(pm2), 5), owed);
        assertEq(usdc.balanceOf(lpOwner), before + owed);
    }

    /// A LISTED contract whose owner reads are malformed (empty answer, or a word that is not an address)
    /// cannot make its own adds and removes revert, and its unresolvable positions simply cannot claim.
    function test_MalformedPositionManager_NeverBlocksAddOrRemove() public {
        MockPositionManager pm1 = new MockPositionManager(manager);
        hook.setPositionManager(address(pm1));
        MalformedPositionManager bad = new MalformedPositionManager(manager);
        hook.addPositionManager(address(bad));
        MockToken meme = _tokenSortedVsUsdc(true);
        creatorNFT.set(address(meme), creator);
        hook.setLaunchConfig(address(meme), address(usdc), false, false, 0, 0, address(usdc), false, 0, 0, false);
        PoolKey memory mk = PoolKey({
            currency0: Currency.wrap(address(usdc)),
            currency1: Currency.wrap(address(meme)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        manager.initialize(mk, SQRT_PRICE_1_1);
        meme.approve(address(lp), type(uint256).max);
        usdc.approve(address(lp), type(uint256).max);
        _addLiquidity(mk, 50e18, 0);
        meme.approve(address(bad), type(uint256).max);
        usdc.approve(address(bad), type(uint256).max);
        int24 lo = TickMath.minUsableTick(TICK_SPACING);
        int24 hi = TickMath.maxUsableTick(TICK_SPACING);

        for (uint256 i; i < 2; ++i) {
            bad.setDirtyWord(i == 1);
            bytes32 salt = bytes32(i + 1);
            bad.modifyLiquidity(mk, ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: 1e18, salt: salt}), "");
            bad.modifyLiquidity(mk, ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: -1e18, salt: salt}), "");
            assertEq(hook.lpRewardRecipient(address(meme), address(bad), i + 1), address(0), "no owner resolved");
            vm.expectRevert(bytes("FeeHook: unknown position"));
            hook.claimLpRewards(address(meme), address(bad), i + 1);
        }
    }

    /// An ERC-721 that answers address(0) for a burned id (instead of reverting) still pays the owner the
    /// hook remembered at the burn.
    function test_OwnerOfZeroAfterBurnFallsBackToRememberedOwner() public {
        MockPositionManager pm1 = new MockPositionManager(manager);
        hook.setPositionManager(address(pm1));
        pm1.setZeroOnMissing(true);
        (MockToken meme, PoolKey memory mk) = _usdcLaunchForLp(pm1);
        address lpOwner = address(0x2B);
        _lpThrough(pm1, mk, 9, lpOwner);
        _buyOnWithUsdc(mk, 50_000e6);
        uint256 owed = hook.lpRewardsOwed(address(meme), 9);
        assertGt(owed, 0);
        vm.prank(lpOwner);
        pm1.burn(9, mk, TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), 5e18);
        assertEq(pm1.ownerOf(9), address(0), "burned id answers zero");
        assertEq(hook.lpRewardRecipient(address(meme), 9), lpOwner, "remembered owner");
        uint256 before = usdc.balanceOf(lpOwner);
        assertEq(hook.claimLpRewards(address(meme), 9), owed);
        assertEq(usdc.balanceOf(lpOwner), before + owed);
    }

    /// A tokenId the hook never saw and the PositionManager does not know: no owner → refuse, not pay 0x0.
    function test_LpClaimUnknownPositionReverts() public {
        MockPositionManager pm = new MockPositionManager(manager);
        hook.setPositionManager(address(pm));
        vm.expectRevert(bytes("FeeHook: unknown position"));
        hook.claimLpRewards(address(token), 4242);
    }

    /// Team payout token re-pointed to native ETH on an ETH-quoted launch: a no-swap reclassify
    /// (payout == numeraire) that banks under the ETH key and is claimable there; flipping back to
    /// USDC later leaves the ETH slice where it is (per-currency banking).
    function test_TeamPayoutEth_NoSwapBanksAndClaimsInEth_FlipBackKeepsIt() public {
        // ABSOLUTE block numbers: a second relative `vm.roll(vm.getBlockNumber() + 1)` in one test rolls to
        // the same block under via-IR, and the one-chunk-per-block gate would then read as a stall.
        hook.setTeamPayoutToken(address(0));
        vm.roll(3000);
        _buy(2 ether);
        uint256 inEth = hook.teamOut(address(token), address(0));
        assertGt(inEth, 0, "banked under the ETH key without a swap");
        assertEq(hook.teamWei(address(token)), 0, "whole bucket moved at once");

        hook.setTeamPayoutToken(address(usdc));
        // Two swaps a block apart: the conversion's price-reference band needs one sighting of the
        // (ETH, usdc) pool before it lets a chunk through.
        vm.roll(3001);
        _buy(2 ether);
        vm.roll(3002);
        _buy(2 ether);
        assertEq(hook.teamOut(address(token), address(0)), inEth, "earlier ETH slice untouched by the flip");
        assertGt(hook.teamOut(address(token), address(usdc)), 0, "new slice banks in usdc");

        uint256 ethBefore = team.balance;
        uint256 usdcBefore = usdc.balanceOf(team);
        vm.prank(team);
        hook.claimTeam(address(token));
        assertEq(team.balance, ethBefore + inEth, "ETH slice delivered");
        assertGt(usdc.balanceOf(team), usdcBefore, "usdc slice delivered");
    }


    // ── the 2-of-2's infra escape hatches must not RETARGET an existing launch ──

    /// The WETH re-point exists for a deprecated WETH. Its validation is only "has code" and
    /// "decimals() == 18", which a contract whose deposit() forwards the ETH elsewhere passes — and the
    /// hook wraps REAL ETH through whatever `weth` points at. A launch that chose a WETH-paired payout
    /// now pins that address, so a re-point cannot send its banked ETH anywhere: the slice takes the
    /// same numeraire fallback a dry route takes.
    function test_WethRepointCannotRedirectAnExistingLaunchsBankedEth() public {
        MockToken rwa = new MockToken();
        _openWethPool(address(rwa), 10e18);
        (MockToken meme, PoolKey memory k) = _newLaunchWethPaid(address(rwa));

        _buyOn(k, 2 ether);
        hook.processConvert(address(meme), true);
        uint256 inRwa = hook.creatorOut(address(meme));
        assertGt(inRwa, 0, "sanity: converted through the WETH this launch chose");

        address thief = makeAddr("thief");
        EvilWeth evil = new EvilWeth(thief);
        hook.setFeeToken(hook.FEE_TOKEN_WETH(), address(evil)); // passes code + decimals()==18

        // Give the re-pointed route somewhere healthy to go, which is what makes the theft possible at
        // all: an (EvilWETH, rwa) pool at this launch's pinned tier, stocked for free on the evil side.
        evil.mintFree(address(this), 1_000e18);
        (address e0, address e1) =
            address(evil) < address(rwa) ? (address(evil), address(rwa)) : (address(rwa), address(evil));
        PoolKey memory evilPool = PoolKey({
            currency0: Currency.wrap(e0),
            currency1: Currency.wrap(e1),
            fee: PAYOUT_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        manager.initialize(evilPool, SQRT_PRICE_1_1);
        evil.approve(address(lp), type(uint256).max);
        rwa.approve(address(lp), type(uint256).max);
        _addLiquidity(evilPool, 10e18, 0);

        vm.roll(vm.getBlockNumber() + 1);
        _buyOn(k, 2 ether);
        assertEq(hook.processConvert(address(meme), true), 0, "the manual path has nothing to convert");

        assertEq(thief.balance, 0, "not one wei reached the re-pointed contract");
        assertEq(evil.deposits(), 0, "the hook never wrapped through it");
        assertEq(hook.creatorOut(address(meme)), inRwa, "no new leg through a route the launch never chose");
        assertGt(hook.creatorOutNum(address(meme)), 0, "the slice fell back to the numeraire");
        assertEq(hook.creatorWei(address(meme)), 0, "nothing stranded");
    }

    /// The same for the hub: migrateUsdc re-points the canonical ETH<->USDC pool that a viaHub route's
    /// FIRST leg crosses. The existing coverage only had the second leg MISSING after a migration; here
    /// it exists and is priced against the creator, which is what an attacker would actually set up. The
    /// launch keeps the hub it chose, so its fees fall back to the numeraire instead of crossing it.
    function test_UsdcMigrationCannotRedirectAnExistingViaHubLaunch() public {
        MockToken rwa = _tokenSortedVsUsdc(true);
        _openUsdcPool(address(rwa), 10e18);
        (MockToken meme, PoolKey memory k) =
            _newLaunchWith(address(rwa), true, PAYOUT_FEE, TICK_SPACING, address(0), address(0));

        _buyOn(k, 2 ether);
        uint256 inRwa = hook.creatorOut(address(meme));
        assertGt(inRwa, 0, "sanity: bridged through the hub this launch chose");

        MockUSDC newUsdc = _migrateToNewUsdc();
        // Stand up the second leg the re-pointed hub would use, so the route would otherwise be healthy.
        (address c0, address c1) =
            address(newUsdc) < address(rwa) ? (address(newUsdc), address(rwa)) : (address(rwa), address(newUsdc));
        PoolKey memory afterHub = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: PAYOUT_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        manager.initialize(afterHub, SQRT_PRICE_1_1);
        newUsdc.approve(address(lp), type(uint256).max);
        rwa.approve(address(lp), type(uint256).max);
        _addLiquidity(afterHub, 10e18, 0);

        vm.roll(vm.getBlockNumber() + 1);
        _buyOn(k, 2 ether);
        assertEq(hook.creatorOut(address(meme)), inRwa, "no leg through the hub the launch never chose");
        assertGt(hook.creatorOutNum(address(meme)), 0, "the slice fell back to the numeraire");
        assertEq(hook.creatorWei(address(meme)), 0, "nothing stranded");
    }
}

/// A "WETH" that passes {FeeHook._validateFeeErc20} — it has code and answers decimals() == 18 — and is
/// a real enough ERC20 for a V4 pool: deposit() mints the caller its IOU, so the hook's settle nets out,
/// while the actual ETH is forwarded somewhere else. What a re-point can point at.
contract EvilWeth is ERC20 {
    address public immutable thief;
    uint256 public deposits;

    constructor(address t) ERC20("Evil Wrapped Ether", "EWETH") {
        thief = t;
    }

    function deposit() external payable {
        deposits++;
        _mint(msg.sender, msg.value);
        (bool ok,) = thief.call{value: msg.value}("");
        require(ok, "EvilWeth: forward failed");
    }

    /// The attacker's own side of the (EvilWETH, token) pool costs nothing to stock.
    function mintFree(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
