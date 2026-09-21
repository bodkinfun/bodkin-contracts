// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";

import {FeeHook, ICreatorNFT} from "../../src/launchpad/v1/FeeHook.sol";

/// `IV4Router.ExactInputSingleParams` as the Universal Router DEPLOYED on Robinhood Chain (0x8876…)
/// decodes it — v4-periphery main, with `minHopPriceX36` before `hookData`. The vendored
/// v4-periphery 1.0.3 `IV4Router` has no such field; encoding that older struct for this router
/// shifts every later word, and the router then reads currency0 as the hookData length. For a pool
/// whose currency0 is native ETH that is 0 and the swap still works, but a USDC-quoted pool reverts
/// (see test_UsdcQuotedPool_LegacyLayoutReverts). Must match `EXACT_IN_SINGLE_TUPLE` in
/// `lib/universalRouter.ts`; 0 = no per-hop price floor.
struct ExactInputSingleParamsCurrent {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    uint256 minHopPriceX36;
    bytes hookData;
}

/// The 3-arg (deadline) `execute` overload — exactly what `lib/universalRouter.ts` targets.
interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// Canonical Permit2 — the router pulls ERC-20 swap inputs through it. Its allowance can be set
/// on-chain (no signature) which is all a fork test needs; production uses a signed permit.
interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// ERC-6909 claim balance on the PoolManager — the fee the hook skims is held here as ETH claims.
interface IClaimBalance {
    function balanceOf(address owner, uint256 id) external view returns (uint256);
}

contract ForkCoin is ERC20 {
    constructor() ERC20("Fork Coin", "FORK") {
        _mint(msg.sender, 1_000_000_000e18);
    }
}

contract ForkUsdc is ERC20 {
    constructor() ERC20("Fork USD", "fUSD") {
        _mint(msg.sender, 1e30);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract ForkCreatorNFT is ICreatorNFT {
    mapping(address => address) internal _owner;

    function set(address token, address who) external {
        _owner[token] = who;
    }

    function creatorOf(address token) external view returns (address) {
        return _owner[token];
    }
}

/// @notice Proves the *real* Uniswap Universal Router on Robinhood Chain executes a V4 swap through
///         one of OUR custom-`FeeHook` launch pools, using the exact calldata layout that the
///         frontend encoder (`lib/universalRouter.ts` / `encodeV4ExactInSwap`) produces.
///
/// Uniswap's hook allowlist only gates off-chain route DISCOVERY (the SOR); on-chain `execute` never
/// checks it, so the router will settle any pool key we hand it — including a brand-new hooked pool.
/// This test forks Robinhood mainnet so the genuine Universal Router (0x8876…) and PoolManager
/// (0x8366…) are present, deploys our hook + a launch pool onto the fork, and drives an ETH→coin buy.
///
/// Network-gated: only runs when `ROBINHOOD_RPC` (or `FORK_RPC`) is set, so the normal offline suite
/// never reaches out. Run it with:
///   ROBINHOOD_RPC=https://rpc.mainnet.chain.robinhood.com \
///     forge test --match-contract UniversalRouterSwapFork -vv
contract UniversalRouterSwapForkTest is Test {
    // Verified Robinhood mainnet (chain 4663) deployments.
    IPoolManager constant MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IUniversalRouter constant ROUTER = IUniversalRouter(0x8876789976dEcBfCbBbe364623C63652db8C0904);

    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Must match `lib/universalRouter.ts` byte-for-byte.
    bytes constant COMMANDS = hex"10"; // V4_SWAP
    bytes constant ACTIONS = hex"060c0f"; // SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL

    /// The hook asks its launcher (us, via setLauncher below) for the launch's curve position on
    /// every swap (range-aware LP rewards + the trading freeze). No curve here: report "no
    /// position, not migrated", the same stand-in FeeHook.t.sol uses.
    function curvePositions(address) external pure returns (int24, int24, uint128, bool) {
        return (0, 0, 0, false);
    }

    // Chaining sentinels (v4-periphery ActionConstants + universal-router Constants).
    address constant ADDRESS_THIS = address(2); // "the router itself" — keep funds in the router
    address constant MSG_SENDER = address(1); // "the caller" — deliver to the user
    uint256 constant CONTRACT_BALANCE = 1 << 255; // "settle my whole balance"
    uint128 constant OPEN_DELTA = 0; // swap/take the full open credit

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    int24 constant TICK_SPACING = 60;
    uint24 constant EXT_FEE = 3000; // the external leg's plain-pool tier

    bool internal active;
    PoolModifyLiquidityTest internal lp;
    FeeHook internal hook;
    ForkCoin internal coin;
    ForkCoin internal ext; // an "external" token with a plain (ETH, ext) V4 pool
    ForkCreatorNFT internal creatorNFT;
    ForkUsdc internal usdc;
    PoolKey internal key;
    PoolKey internal extKey;

    address internal creator = address(0xC0FFEE);
    address internal team = address(0x7EA);
    address internal buyer = address(0xB0B);

    /// The LP router refunds excess native ETH from `modifyLiquidity` to us — must accept it.
    receive() external payable {}

    function setUp() public {
        string memory url = _rpc();
        if (bytes(url).length == 0) return; // offline: skip (see modifier)
        vm.createSelectFork(url);
        active = true;

        vm.deal(address(this), 1_000 ether);
        lp = new PoolModifyLiquidityTest(MANAGER);
        coin = new ForkCoin();
        usdc = new ForkUsdc();
        creatorNFT = new ForkCreatorNFT();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );
        bytes memory args =
            abi.encode(MANAGER, ICreatorNFT(address(creatorNFT)), team, address(usdc), address(0), address(this));
        (address hookAddr, bytes32 salt) = HookMiner.find(address(this), flags, type(FeeHook).creationCode, args);
        hook =
            new FeeHook{salt: salt}(MANAGER, ICreatorNFT(address(creatorNFT)), team, address(usdc), address(0), address(this));
        require(address(hook) == hookAddr, "hook addr mismatch");

        creatorNFT.set(address(coin), creator);
        // Stand in for the launcher: record the launch config, then open + seed the pool.
        hook.setLauncher(address(this));
        hook.setLaunchConfig(address(coin), address(usdc), false, false, 0, 0, address(0), false, 0, 0, false);

        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(coin)),
            fee: 0, // the hook is the fee
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        MANAGER.initialize(key, SQRT_PRICE_1_1);
        coin.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity{value: 200 ether}(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: 50e18,
                salt: 0
            }),
            ""
        );

        // A plain (ETH, ext) V4 pool with NO hook — stands in for external Uniswap liquidity that
        // the Trading API would route. ETH (0x0) always sorts first, so ext is currency1.
        ext = new ForkCoin();
        extKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(ext)),
            fee: EXT_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        MANAGER.initialize(extKey, SQRT_PRICE_1_1);
        ext.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity{value: 200 ether}(
            extKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: 50e18,
                salt: 0
            }),
            ""
        );
    }

    modifier onlyFork() {
        if (!active) {
            emit log("skipped: set ROBINHOOD_RPC (or FORK_RPC) to run the Universal Router fork test");
            return;
        }
        _;
    }

    /// The genuine Universal Router settles an ETH→coin buy through our hooked pool, the buyer
    /// receives the coin, and the FeeHook skims its 1% ETH fee (held as a PoolManager claim).
    function test_UniversalRouterBuysOurHookedPool() public onlyFork {
        uint128 amountIn = 1 ether;
        uint128 minOut = 0; // exact-in; we assert receipt below

        // Same three params, same order, as encodeV4ExactInSwap: swap / settle(input) / take(output).
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ExactInputSingleParamsCurrent({
                poolKey: key,
                zeroForOne: true, // spend currency0 (ETH), receive currency1 (coin)
                amountIn: amountIn,
                amountOutMinimum: minOut,
                minHopPriceX36: 0,
                hookData: ""
            })
        );
        params[1] = abi.encode(Currency.wrap(address(0)), uint256(amountIn)); // SETTLE_ALL(ETH, amountIn)
        params[2] = abi.encode(Currency.wrap(address(coin)), uint256(minOut)); // TAKE_ALL(coin, minOut)

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(ACTIONS, params); // the V4_SWAP command's input

        uint256 hookFeeBefore = IClaimBalance(address(MANAGER)).balanceOf(address(hook), 0);
        assertEq(coin.balanceOf(buyer), 0, "buyer starts with no coin");

        vm.deal(buyer, 5 ether);
        vm.prank(buyer);
        ROUTER.execute{value: amountIn}(COMMANDS, inputs, block.timestamp + 3600);

        assertGt(coin.balanceOf(buyer), 0, "buyer received coin from the router");
        uint256 hookFeeAfter = IClaimBalance(address(MANAGER)).balanceOf(address(hook), 0);
        assertGt(hookFeeAfter, hookFeeBefore, "FeeHook skimmed its ETH fee on the router swap");
        // ~1% of 1 ETH; generous bounds absorb slippage/rounding without asserting exact math.
        assertApproxEqAbs(hookFeeAfter - hookFeeBefore, 0.01 ether, 0.002 ether, "fee is ~1% of amountIn");
    }

    /// The heart of the external-swap migration: ONE Universal Router `execute` atomically routes an
    /// external ERC-20 (ext) into native ETH, then through OUR hooked (ETH, coin) pool into coin for
    /// the buyer — as TWO chained V4_SWAP commands. Command 1 TAKEs the ETH to the router
    /// (recipient=ADDRESS_THIS); command 2 SETTLEs the router's whole ETH balance (CONTRACT_BALANCE)
    /// and swaps it (amountIn=OPEN_DELTA) — the exact hand-off a real V3/V2 external leg + UNWRAP_WETH
    /// feeds into. Two standalone swaps, not a multi-hop path: our FeeHook's before/after-swap delta
    /// logic only composes as a TERMINAL/standalone hop, so we never put it mid-path. ext is pulled
    /// via Permit2 (allowance set on-chain here; production signs a PERMIT2_PERMIT — identical pull).
    function test_ChainedExternalBuyThroughOurHook() public onlyFork {
        uint128 amountIn = 1e18; // 1 ext
        uint128 minOut = 0; // exact-in; asserted below

        // Command 1 — ext → ETH via the plain external pool; TAKE the ETH to the router.
        bytes[] memory p0 = new bytes[](3);
        p0[0] = abi.encode(
            ExactInputSingleParamsCurrent({
                poolKey: extKey,
                zeroForOne: false, // ext is currency1 → spend ext, receive ETH (currency0)
                amountIn: amountIn,
                amountOutMinimum: 0, // slippage enforced on the final coin leg
                minHopPriceX36: 0,
                hookData: ""
            })
        );
        p0[1] = abi.encode(Currency.wrap(address(ext)), uint256(amountIn)); // SETTLE_ALL(ext) — pulls via Permit2
        p0[2] = abi.encode(Currency.wrap(address(0)), ADDRESS_THIS, uint256(OPEN_DELTA)); // TAKE(ETH → router, full)
        bytes memory input0 = abi.encode(hex"060c0e", p0); // SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE

        // Command 2 — SETTLE the router's whole ETH balance, swap it ETH → coin through our hook,
        // TAKE the coin to the user. This is byte-identical to the ecosystem hop after any external leg.
        bytes[] memory p1 = new bytes[](3);
        p1[0] = abi.encode(Currency.wrap(address(0)), CONTRACT_BALANCE, false); // SETTLE(ETH, whole balance, payer=router)
        p1[1] = abi.encode(
            ExactInputSingleParamsCurrent({
                poolKey: key,
                zeroForOne: true, // ETH (currency0) → coin
                amountIn: OPEN_DELTA, // swap the full settled ETH credit
                amountOutMinimum: minOut,
                minHopPriceX36: 0,
                hookData: ""
            })
        );
        p1[2] = abi.encode(Currency.wrap(address(coin)), MSG_SENDER, uint256(OPEN_DELTA)); // TAKE(coin → user, full)
        bytes memory input1 = abi.encode(hex"0b060e", p1); // SETTLE, SWAP_EXACT_IN_SINGLE, TAKE

        bytes[] memory inputs = new bytes[](2);
        inputs[0] = input0;
        inputs[1] = input1;

        ext.transfer(buyer, 5e18);
        uint256 hookFeeBefore = IClaimBalance(address(MANAGER)).balanceOf(address(hook), 0);
        assertEq(coin.balanceOf(buyer), 0, "buyer starts with no coin");

        vm.startPrank(buyer);
        ext.approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(address(ext), address(ROUTER), type(uint160).max, type(uint48).max);
        ROUTER.execute(hex"1010", inputs, block.timestamp + 3600); // two V4_SWAP commands; no msg.value
        vm.stopPrank();

        assertGt(coin.balanceOf(buyer), 0, "buyer received coin from the chained external route");
        assertEq(ext.balanceOf(buyer), 4e18, "exactly 1 ext was spent");
        assertGt(
            IClaimBalance(address(MANAGER)).balanceOf(address(hook), 0),
            hookFeeBefore,
            "FeeHook still skims its fee on the ecosystem hop of the chained route"
        );
    }

    /// The SELL mirror: coin → external ERC-20, atomic, as two chained V4_SWAP commands. Command 1
    /// pulls the coin via Permit2 and swaps it coin→ETH through OUR hooked pool, TAKEing the ETH to
    /// the router; command 2 SETTLEs that whole ETH balance and swaps ETH→ext to the seller. Proves
    /// the sell-side hand-off (Permit2 pull INTO our hook, then spend the router's ETH) — byte-identical
    /// to a real close-into-token after WRAP_ETH + a V3/V2 leg.
    function test_ChainedExternalSellThroughOurHook() public onlyFork {
        address seller = address(0x5E11);
        uint128 amountInCoin = 1e18;

        // Command 1 — coin → ETH through our hooked pool; ETH taken to the router.
        bytes[] memory p0 = new bytes[](3);
        p0[0] = abi.encode(Currency.wrap(address(coin)), uint256(amountInCoin), true); // SETTLE(coin, exact, payer=user via Permit2)
        p0[1] = abi.encode(
            ExactInputSingleParamsCurrent({
                poolKey: key,
                zeroForOne: false, // coin (currency1) → ETH (currency0)
                amountIn: OPEN_DELTA,
                amountOutMinimum: 0,
                minHopPriceX36: 0,
                hookData: ""
            })
        );
        p0[2] = abi.encode(Currency.wrap(address(0)), ADDRESS_THIS, uint256(OPEN_DELTA)); // TAKE(ETH → router, full)
        bytes memory input0 = abi.encode(hex"0b060e", p0); // SETTLE, SWAP_EXACT_IN_SINGLE, TAKE

        // Command 2 — SETTLE the router's whole ETH balance, swap ETH → ext to the seller.
        bytes[] memory p1 = new bytes[](3);
        p1[0] = abi.encode(Currency.wrap(address(0)), CONTRACT_BALANCE, false); // SETTLE(ETH, whole balance, payer=router)
        p1[1] = abi.encode(
            ExactInputSingleParamsCurrent({
                poolKey: extKey,
                zeroForOne: true, // ETH (currency0) → ext
                amountIn: OPEN_DELTA,
                amountOutMinimum: 0,
                minHopPriceX36: 0,
                hookData: ""
            })
        );
        p1[2] = abi.encode(Currency.wrap(address(ext)), MSG_SENDER, uint256(OPEN_DELTA)); // TAKE(ext → seller, full)
        bytes memory input1 = abi.encode(hex"0b060e", p1);

        bytes[] memory inputs = new bytes[](2);
        inputs[0] = input0;
        inputs[1] = input1;

        coin.transfer(seller, 10e18);
        uint256 hookFeeBefore = IClaimBalance(address(MANAGER)).balanceOf(address(hook), 0);
        assertEq(ext.balanceOf(seller), 0, "seller starts with no ext");

        vm.startPrank(seller);
        coin.approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(address(coin), address(ROUTER), type(uint160).max, type(uint48).max);
        ROUTER.execute(hex"1010", inputs, block.timestamp + 3600); // two V4_SWAP commands; no msg.value
        vm.stopPrank();

        assertGt(ext.balanceOf(seller), 0, "seller received ext from the chained sell route");
        assertEq(coin.balanceOf(seller), 9e18, "exactly 1 coin was spent");
        assertGt(
            IClaimBalance(address(MANAGER)).balanceOf(address(hook), 0),
            hookFeeBefore,
            "FeeHook skims its fee on the ecosystem hop of the chained sell"
        );
    }

    /// Phase 1b: SELL coin → native ETH via a SINGLE V4_SWAP through our hooked pool, Permit2-pulled,
    /// ETH delivered to the seller. Proves encodeEcosystemSell's structure (SETTLE coin via Permit2 →
    /// SWAP coin→ETH → TAKE ETH to the user) — the ecosystem sell SwapZapV1 does today, now on the UR.
    function test_UniversalRouterSellsOurHookedPool() public onlyFork {
        address seller = address(0x5E22);
        uint128 amountInCoin = 1e18;

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(Currency.wrap(address(coin)), uint256(amountInCoin), true); // SETTLE(coin, exact, Permit2)
        params[1] = abi.encode(
            ExactInputSingleParamsCurrent({
                poolKey: key,
                zeroForOne: false, // coin (currency1) → ETH (currency0)
                amountIn: OPEN_DELTA,
                amountOutMinimum: 0,
                minHopPriceX36: 0,
                hookData: ""
            })
        );
        params[2] = abi.encode(Currency.wrap(address(0)), MSG_SENDER, uint256(OPEN_DELTA)); // TAKE(ETH → seller, full)
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(hex"0b060e", params); // SETTLE, SWAP_EXACT_IN_SINGLE, TAKE

        coin.transfer(seller, 5e18);
        uint256 hookFeeBefore = IClaimBalance(address(MANAGER)).balanceOf(address(hook), 0);
        assertEq(seller.balance, 0, "seller starts with no ETH");

        vm.startPrank(seller);
        coin.approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(address(coin), address(ROUTER), type(uint160).max, type(uint48).max);
        ROUTER.execute(COMMANDS, inputs, block.timestamp + 3600); // single V4_SWAP; no msg.value
        vm.stopPrank();

        assertGt(seller.balance, 0, "seller received native ETH from the sell");
        assertEq(coin.balanceOf(seller), 4e18, "exactly 1 coin was spent");
        assertGt(
            IClaimBalance(address(MANAGER)).balanceOf(address(hook), 0),
            hookFeeBefore,
            "FeeHook skims its fee on the ecosystem sell"
        );
    }

    /// A USDC-quoted launch pool — currency0 is the dollar ERC-20, not native ETH — bought through the
    /// genuine router exactly as `encodeHookPoolSwap` builds it: SETTLE(usdc, amountIn, payerIsUser),
    /// SWAP_EXACT_IN_SINGLE(OPEN_DELTA), TAKE(coin, MSG_SENDER, OPEN_DELTA). The input is pulled via
    /// Permit2 (allowance set on-chain here; production signs a PERMIT2_PERMIT — identical pull).
    function test_UniversalRouterBuysAUsdcQuotedPool() public onlyFork {
        (PoolKey memory usdcKey, ForkCoin usdCoin) = _usdcQuotedPool();
        uint256 amountIn = 50e6; // 50 fUSD

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _usdcBuyInput(usdcKey, usdCoin, amountIn, _swapParamCurrent(usdcKey));
        vm.prank(buyer);
        ROUTER.execute(COMMANDS, inputs, block.timestamp + 3600);

        assertGt(usdCoin.balanceOf(buyer), 0, "buyer received the USDC-quoted coin from the router");
        assertEq(usdc.balanceOf(buyer), 100e6 - amountIn, "exactly amountIn of fUSD was pulled via Permit2");
    }

    /// The same buy with the v4-periphery 1.0.3 struct (no minHopPriceX36) REVERTS on the deployed
    /// router — the bug that showed as "Network fee: Unavailable" for every USD-quoted swap. Kept so
    /// that a future encoder or router change that drifts again fails here, not in a user's wallet.
    function test_UsdcQuotedPool_LegacyLayoutReverts() public onlyFork {
        (PoolKey memory usdcKey, ForkCoin usdCoin) = _usdcQuotedPool();
        bytes memory legacy = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: usdcKey,
                zeroForOne: true,
                amountIn: OPEN_DELTA,
                amountOutMinimum: 0,
                hookData: ""
            })
        );
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _usdcBuyInput(usdcKey, usdCoin, 50e6, legacy);
        vm.prank(buyer);
        vm.expectRevert();
        ROUTER.execute(COMMANDS, inputs, block.timestamp + 3600);
    }

    /// Opens + seeds a (fUSD, coin) pool on our hook the way a USDC-quoted launch does (numeraire =
    /// the hook's usdc, which must sort BELOW the coin), and funds + Permit2-approves the buyer.
    function _usdcQuotedPool() internal returns (PoolKey memory usdcKey, ForkCoin usdCoin) {
        // The launcher mines a salt so the coin sorts ABOVE its numeraire (currency0 = fUSD). Here the
        // coin is simply placed at a high address; its constructor runs with this contract as sender.
        address high = address(type(uint160).max - 0xB0D);
        deployCodeTo("UniversalRouterSwapFork.t.sol:ForkCoin", high);
        usdCoin = ForkCoin(high);
        require(address(usdCoin) > address(usdc), "the coin must sort above fUSD");
        creatorNFT.set(address(usdCoin), creator);
        hook.setLaunchConfig(address(usdCoin), address(usdc), false, false, 0, 0, address(usdc), false, 0, 0, false);

        usdcKey = PoolKey({
            currency0: Currency.wrap(address(usdc)),
            currency1: Currency.wrap(address(usdCoin)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        MANAGER.initialize(usdcKey, SQRT_PRICE_1_1);
        usdc.approve(address(lp), type(uint256).max);
        usdCoin.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(
            usdcKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: 50e18,
                salt: 0
            }),
            ""
        );

        usdc.transfer(buyer, 100e6);
        vm.startPrank(buyer);
        usdc.approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(address(usdc), address(ROUTER), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function _swapParamCurrent(PoolKey memory usdcKey) internal pure returns (bytes memory) {
        return abi.encode(
            ExactInputSingleParamsCurrent({
                poolKey: usdcKey,
                zeroForOne: true, // spend currency0 (fUSD), receive currency1 (coin)
                amountIn: OPEN_DELTA, // swap the whole settled credit
                amountOutMinimum: 0,
                minHopPriceX36: 0,
                hookData: ""
            })
        );
    }

    /// The V4_SWAP input `encodeHookPoolSwap` sends: SETTLE, SWAP_EXACT_IN_SINGLE, TAKE.
    function _usdcBuyInput(PoolKey memory usdcKey, ForkCoin usdCoin, uint256 amountIn, bytes memory swapParam)
        internal
        pure
        returns (bytes memory)
    {
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(usdcKey.currency0, amountIn, true); // SETTLE(fUSD, amountIn, payerIsUser)
        params[1] = swapParam;
        params[2] = abi.encode(Currency.wrap(address(usdCoin)), MSG_SENDER, uint256(OPEN_DELTA)); // TAKE
        return abi.encode(hex"0b060e", params);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // MAINNET-ONLY external legs — the routes the Trading API returns on Robinhood mainnet (4663) and
    // that the testnet cannot run at all (its router hard-codes mainnet WETH and the mainnet V2/V3
    // factories). Each replays the command sequence `encodeExternalBuy` / `encodeExternalSell` in
    // lib/urChain.ts builds, with REAL USDG against the REAL pools, so a layout or wrap/unwrap drift in
    // the encoder fails here instead of in a user's wallet.
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73; // canonical mainnet WETH
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // Paxos Global Dollar, 6 dec
    /// The dynamic-fee hook the Trading API routes USDG↔WETH through (a WETH-keyed V4 pool).
    address constant WETH_USDG_HOOK = 0x64E9ae1066c47Ac4a3cc0a5bd7B135908590e088;

    /// Commands are skipped on the testnet fork: these pools exist only on mainnet.
    modifier onlyMainnetFork() {
        if (!active || block.chainid != 4663) {
            emit log("skipped: needs a Robinhood MAINNET fork (ROBINHOOD_RPC=https://rpc.mainnet.chain.robinhood.com)");
            return;
        }
        _;
    }

    /// V3 leg (USDG → WETH, fee 100), UNWRAP_WETH, then our hook: commands 00 0c 10 — the V3 input
    /// carries UR 2.1.1's trailing `uint256[] minHopPriceX36` (empty = no per-hop floor).
    function test_Mainnet_V3UsdgLegBuysOurCoin() public onlyMainnetFork {
        uint256 amountIn = _fundUsdg(buyer, 0.5 ether);
        bytes[] memory inputs = new bytes[](3);
        inputs[0] = abi.encode(ADDRESS_THIS, amountIn, uint256(0), abi.encodePacked(USDG, uint24(100), WETH), true, new uint256[](0));
        inputs[1] = abi.encode(ADDRESS_THIS, uint256(0)); // UNWRAP_WETH(router, min 0)
        inputs[2] = _ecoBuyFromRouter();
        _assertBuy(hex"000c10", inputs, amountIn);
    }

    /// The same V3 input WITHOUT the trailing `uint256[] minHopPriceX36` (the pre-2.1 layout the
    /// encoder used to send) is rejected by the deployed router — the regression guard for that fix.
    function test_Mainnet_V3LegWithoutMinHopArrayReverts() public onlyMainnetFork {
        uint256 amountIn = _fundUsdg(buyer, 0.5 ether);
        bytes[] memory inputs = new bytes[](3);
        inputs[0] = abi.encode(ADDRESS_THIS, amountIn, uint256(0), abi.encodePacked(USDG, uint24(100), WETH), true);
        inputs[1] = abi.encode(ADDRESS_THIS, uint256(0));
        inputs[2] = _ecoBuyFromRouter();
        vm.prank(buyer);
        vm.expectRevert();
        ROUTER.execute(hex"000c10", inputs, block.timestamp + 3600);
    }

    /// A WETH-keyed V4 leg WITHOUT the UNWRAP_WETH leaves WETH in the router, so the ecosystem hop
    /// settles 0 ETH and the whole buy reverts — the regression guard for the unwrap fix.
    function test_Mainnet_WethKeyedV4LegWithoutUnwrapReverts() public onlyMainnetFork {
        uint256 amountIn = _fundUsdg(buyer, 0.2 ether);
        bytes[] memory p = new bytes[](3);
        p[0] = abi.encode(Currency.wrap(USDG), amountIn, true);
        p[1] = abi.encode(_param(_wethUsdgKey(), false, uint128(amountIn)));
        p[2] = abi.encode(Currency.wrap(WETH), ADDRESS_THIS, uint256(OPEN_DELTA));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(hex"0b060e", p);
        inputs[1] = _ecoBuyFromRouter();
        vm.prank(buyer);
        vm.expectRevert();
        ROUTER.execute(hex"1010", inputs, block.timestamp + 3600);
    }

    /// Our hook → ETH in the router, WRAP_ETH, V3 leg (WETH → USDG) to the seller: commands 10 0b 00.
    function test_Mainnet_V3UsdgLegSellsOurCoin() public onlyMainnetFork {
        bytes[] memory inputs = new bytes[](3);
        inputs[0] = _ecoSellToRouter(1e18);
        inputs[1] = abi.encode(ADDRESS_THIS, CONTRACT_BALANCE); // WRAP_ETH(router, whole balance)
        inputs[2] = abi.encode(MSG_SENDER, CONTRACT_BALANCE, uint256(1), abi.encodePacked(WETH, uint24(100), USDG), false, new uint256[](0));
        _assertSell(hex"100b00", inputs);
    }

    /// V2 leg (USDG → WETH), UNWRAP_WETH, our hook: commands 08 0c 10.
    function test_Mainnet_V2UsdgLegBuysOurCoin() public onlyMainnetFork {
        uint256 amountIn = _fundUsdg(buyer, 0.5 ether);
        address[] memory path = new address[](2);
        (path[0], path[1]) = (USDG, WETH);
        bytes[] memory inputs = new bytes[](3);
        inputs[0] = abi.encode(ADDRESS_THIS, amountIn, uint256(0), path, true, new uint256[](0));
        inputs[1] = abi.encode(ADDRESS_THIS, uint256(0));
        inputs[2] = _ecoBuyFromRouter();
        _assertBuy(hex"080c10", inputs, amountIn);
    }

    /// Our hook, WRAP_ETH, V2 leg (WETH → USDG) to the seller: commands 10 0b 08.
    function test_Mainnet_V2UsdgLegSellsOurCoin() public onlyMainnetFork {
        address[] memory path = new address[](2);
        (path[0], path[1]) = (WETH, USDG);
        bytes[] memory inputs = new bytes[](3);
        inputs[0] = _ecoSellToRouter(1e18);
        inputs[1] = abi.encode(ADDRESS_THIS, CONTRACT_BALANCE);
        inputs[2] = abi.encode(MSG_SENDER, CONTRACT_BALANCE, uint256(1), path, false, new uint256[](0));
        _assertSell(hex"100b08", inputs);
    }

    /// V4 leg on the WETH-keyed hooked pool (USDG → WETH, i.e. currency1 → currency0), UNWRAP_WETH,
    /// our hook: commands 10 0c 10. Without the unwrap the ecosystem hop settles 0 ETH and reverts.
    function test_Mainnet_WethKeyedV4LegBuysOurCoin() public onlyMainnetFork {
        uint256 amountIn = _fundUsdg(buyer, 0.2 ether);
        bytes[] memory p = new bytes[](3);
        p[0] = abi.encode(Currency.wrap(USDG), amountIn, true); // SETTLE(USDG, exact, payerIsUser)
        p[1] = abi.encode(_param(_wethUsdgKey(), false, uint128(amountIn)));
        p[2] = abi.encode(Currency.wrap(WETH), ADDRESS_THIS, uint256(OPEN_DELTA)); // TAKE(WETH → router)
        bytes[] memory inputs = new bytes[](3);
        inputs[0] = abi.encode(hex"0b060e", p);
        inputs[1] = abi.encode(ADDRESS_THIS, uint256(0));
        inputs[2] = _ecoBuyFromRouter();
        _assertBuy(hex"100c10", inputs, amountIn);
    }

    /// Our hook, WRAP_ETH, V4 leg on the WETH-keyed pool (WETH → USDG) to the seller: commands 10 0b 10.
    function test_Mainnet_WethKeyedV4LegSellsOurCoin() public onlyMainnetFork {
        bytes[] memory p = new bytes[](3);
        p[0] = abi.encode(Currency.wrap(WETH), CONTRACT_BALANCE, false); // SETTLE(WETH, router's whole balance)
        p[1] = abi.encode(_param(_wethUsdgKey(), true, OPEN_DELTA));
        p[2] = abi.encode(Currency.wrap(USDG), MSG_SENDER, uint256(OPEN_DELTA)); // TAKE(USDG → seller)
        bytes[] memory inputs = new bytes[](3);
        inputs[0] = _ecoSellToRouter(1e18);
        inputs[1] = abi.encode(ADDRESS_THIS, CONTRACT_BALANCE);
        inputs[2] = abi.encode(hex"0b060e", p);
        _assertSell(hex"100b10", inputs);
    }

    /// The mainnet PoolManager has a live protocol-fee controller. Our launch pools pay 0 today, but the
    /// controller can turn a protocol fee on for ANY pool at any time. With the maximum (0.1% each way)
    /// set on our launch pool, buys and sells through the router must still work and the hook must
    /// still take its own ~1% — the protocol fee comes out of the swap, not out of the hook's cut.
    function test_Mainnet_ProtocolFeeOnOurLaunchPoolKeepsTradingWorking() public onlyMainnetFork {
        address controller = MANAGER.protocolFeeController();
        assertTrue(controller != address(0), "mainnet has a protocol-fee controller");
        vm.prank(controller);
        MANAGER.setProtocolFee(key, uint24(1000 | (1000 << 12))); // MAX_PROTOCOL_FEE both directions

        uint256 accruedEth = MANAGER.protocolFeesAccrued(Currency.wrap(address(0)));
        uint256 hookFeeBefore = IClaimBalance(address(MANAGER)).balanceOf(address(hook), 0);

        // Buy: 1 ETH → coin (the same single V4_SWAP as test_UniversalRouterBuysOurHookedPool).
        bytes[] memory p = new bytes[](3);
        p[0] = abi.encode(_param(key, true, 1 ether));
        p[1] = abi.encode(Currency.wrap(address(0)), uint256(1 ether));
        p[2] = abi.encode(Currency.wrap(address(coin)), uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(ACTIONS, p);
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        ROUTER.execute{value: 1 ether}(COMMANDS, inputs, block.timestamp + 3600);

        uint256 bought = coin.balanceOf(buyer);
        assertGt(bought, 0, "the buy still fills");
        assertGt(MANAGER.protocolFeesAccrued(Currency.wrap(address(0))), accruedEth, "the protocol fee was charged");
        assertApproxEqAbs(
            IClaimBalance(address(MANAGER)).balanceOf(address(hook), 0) - hookFeeBefore, 0.01 ether, 0.002 ether, "hook fee still ~1%"
        );

        // Sell half of it back to ETH.
        uint256 accruedCoin = MANAGER.protocolFeesAccrued(Currency.wrap(address(coin)));
        inputs[0] = _ecoSellWith(bought / 2, MSG_SENDER);
        vm.startPrank(buyer);
        coin.approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(address(coin), address(ROUTER), type(uint160).max, type(uint48).max);
        ROUTER.execute(COMMANDS, inputs, block.timestamp + 3600);
        vm.stopPrank();
        assertGt(buyer.balance, 0, "the sell still fills");
        assertGt(MANAGER.protocolFeesAccrued(Currency.wrap(address(coin))), accruedCoin, "protocol fee on the sell's input");
    }

    /// Buy USDG with native ETH through the deepest (ETH, USDG) pool (100/1), and Permit2-approve it
    /// for the router — the real token, not a `deal` (USDG's balances are share-based).
    function _fundUsdg(address who, uint256 ethIn) internal returns (uint256 usdg) {
        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(USDG),
            fee: 100,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });
        bytes[] memory p = new bytes[](3);
        p[0] = abi.encode(_param(k, true, uint128(ethIn)));
        p[1] = abi.encode(Currency.wrap(address(0)), ethIn);
        p[2] = abi.encode(Currency.wrap(USDG), uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(ACTIONS, p);
        vm.deal(who, ethIn);
        vm.startPrank(who);
        ROUTER.execute{value: ethIn}(COMMANDS, inputs, block.timestamp + 3600);
        ERC20(USDG).approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(USDG, address(ROUTER), type(uint160).max, type(uint48).max);
        vm.stopPrank();
        usdg = ERC20(USDG).balanceOf(who);
        require(usdg > 0, "no USDG bought");
    }

    function _wethUsdgKey() internal pure returns (PoolKey memory) {
        // WETH (0x0Bd7…) sorts below USDG (0x5fc5…); dynamic fee flag, tick spacing 1.
        return PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(USDG),
            fee: 0x800000,
            tickSpacing: 1,
            hooks: IHooks(WETH_USDG_HOOK)
        });
    }

    function _param(PoolKey memory k, bool zeroForOne, uint128 amountIn) internal pure returns (ExactInputSingleParamsCurrent memory) {
        return ExactInputSingleParamsCurrent({
            poolKey: k,
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            amountOutMinimum: 0,
            minHopPriceX36: 0,
            hookData: ""
        });
    }

    /// The ecosystem hop after an external leg: SETTLE the router's whole ETH, swap it → coin, TAKE to the user.
    function _ecoBuyFromRouter() internal view returns (bytes memory) {
        bytes[] memory p = new bytes[](3);
        p[0] = abi.encode(Currency.wrap(address(0)), CONTRACT_BALANCE, false);
        p[1] = abi.encode(_param(key, true, OPEN_DELTA));
        p[2] = abi.encode(Currency.wrap(address(coin)), MSG_SENDER, uint256(OPEN_DELTA));
        return abi.encode(hex"0b060e", p);
    }

    /// The ecosystem hop before an external leg: pull `amount` coin via Permit2, swap → ETH, TAKE to `to`.
    function _ecoSellWith(uint256 amount, address to) internal view returns (bytes memory) {
        bytes[] memory p = new bytes[](3);
        p[0] = abi.encode(Currency.wrap(address(coin)), amount, true);
        p[1] = abi.encode(_param(key, false, OPEN_DELTA));
        p[2] = abi.encode(Currency.wrap(address(0)), to, uint256(OPEN_DELTA));
        return abi.encode(hex"0b060e", p);
    }

    function _ecoSellToRouter(uint256 amount) internal view returns (bytes memory) {
        return _ecoSellWith(amount, ADDRESS_THIS);
    }

    function _assertBuy(bytes memory commands, bytes[] memory inputs, uint256 usdgIn) internal {
        uint256 hookFeeBefore = IClaimBalance(address(MANAGER)).balanceOf(address(hook), 0);
        uint256 routerWeth = ERC20(WETH).balanceOf(address(ROUTER));
        vm.prank(buyer);
        ROUTER.execute(commands, inputs, block.timestamp + 3600);
        assertGt(coin.balanceOf(buyer), 0, "buyer received the coin");
        assertEq(ERC20(USDG).balanceOf(buyer), 0, "all of the USDG input was spent");
        assertGt(usdgIn, 0);
        assertGt(IClaimBalance(address(MANAGER)).balanceOf(address(hook), 0), hookFeeBefore, "the hook took its fee");
        assertLe(ERC20(WETH).balanceOf(address(ROUTER)), routerWeth, "no WETH stranded in the router");
    }

    function _assertSell(bytes memory commands, bytes[] memory inputs) internal {
        address seller = address(0x5E33);
        coin.transfer(seller, 5e18);
        uint256 hookFeeBefore = IClaimBalance(address(MANAGER)).balanceOf(address(hook), 0);
        uint256 routerWeth = ERC20(WETH).balanceOf(address(ROUTER));
        vm.startPrank(seller);
        coin.approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(address(coin), address(ROUTER), type(uint160).max, type(uint48).max);
        ROUTER.execute(commands, inputs, block.timestamp + 3600);
        vm.stopPrank();
        assertGt(ERC20(USDG).balanceOf(seller), 0, "seller received USDG");
        assertEq(coin.balanceOf(seller), 4e18, "exactly 1 coin was spent");
        assertGt(IClaimBalance(address(MANAGER)).balanceOf(address(hook), 0), hookFeeBefore, "the hook took its fee");
        assertLe(ERC20(WETH).balanceOf(address(ROUTER)), routerWeth, "no WETH stranded in the router");
    }

    function _rpc() internal view returns (string memory) {
        try vm.envString("ROBINHOOD_RPC") returns (string memory u) {
            return u;
        } catch {
            try vm.envString("FORK_RPC") returns (string memory u) {
                return u;
            } catch {
                return "";
            }
        }
    }
}
