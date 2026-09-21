// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {IAllowanceTransfer} from "@uniswap/v4-periphery/src/interfaces/IPermit2Forwarder.sol";
import {IEIP712} from "permit2/src/interfaces/IEIP712.sol";

import {FeeHook, ICreatorNFT} from "../../src/launchpad/v1/FeeHook.sol";
import {LauncherV1} from "../../src/launchpad/v1/LauncherV1.sol";
import {BodkinERC20} from "../../src/launchpad/BodkinERC20.sol";
import {CreatorNFT} from "../../src/launchpad/CreatorNFT.sol";
import {LocalUniversalRouter} from "../../src/dev/LocalUniversalRouter.sol";
import {Permit2Runtime} from "../../src/dev/Permit2Deployer.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USD Coin", "mUSDC") {
        _mint(msg.sender, 1e30);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @notice Proves the DEV-ONLY {LocalUniversalRouter} (the anvil stand-in for Uniswap's Universal
///         Router) drives the launchpad's *regular* swaps — ecosystem buy/sell, USDC-numeraire
///         buy/sell, cross-ETH coin↔coin — with calldata encoded EXACTLY the way the frontend's
///         `urChain.ts` / `universalRouter.ts` encode it (same command bytes, V4 action bytes, tuple
///         layouts, and ADDRESS_THIS / CONTRACT_BALANCE / OPEN_DELTA / MSG_SENDER sentinels). ERC-20
///         inputs are pulled through a REAL (etched) Permit2, so `_pay` is exercised for real. This
///         is the local counterpart to the Robinhood-fork proof in UniversalRouterSwapFork.t.sol.
contract LocalUniversalRouterSwapTest is Test {
    uint160 constant SQRT_PRICE_ETH_USDC = 4339505179874779475002393; // (ETH,USDC) ~ $3,000/ETH

    // Permit2 EIP-712 type hashes (permit2 PermitHash.sol).
    bytes32 constant PERMIT_DETAILS_TYPEHASH =
        keccak256("PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)");
    bytes32 constant PERMIT_SINGLE_TYPEHASH = keccak256(
        "PermitSingle(PermitDetails details,address spender,uint256 sigDeadline)PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"
    );

    PoolManager manager;
    PoolModifyLiquidityTest lp;
    FeeHook hook;
    CreatorNFT creatorNFT;
    LauncherV1 launcher;
    MockUSDC usdc;
    IAllowanceTransfer permit2;
    LocalUniversalRouter router;

    address creator = address(0xC0FFEE);
    address team = address(0x7EA);
    address feeRecipient = address(0xFEE);
    address resolver = address(0x454552);
    address deployer = address(0xADA);
    uint256 userPk = 0xA11CE;
    address user;

    function setUp() public {
        user = vm.addr(userPk);
        vm.deal(address(this), 100_000 ether);
        vm.deal(user, 10_000 ether);

        manager = new PoolManager(address(this));
        lp = new PoolModifyLiquidityTest(manager);
        usdc = new MockUSDC();
        creatorNFT = new CreatorNFT("");

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );
        bytes memory args = abi.encode(
            IPoolManager(address(manager)), ICreatorNFT(address(creatorNFT)), team, address(usdc), address(0), address(this)
        );
        (address hookAddr, bytes32 salt) = HookMiner.find(address(this), flags, type(FeeHook).creationCode, args);
        hook = new FeeHook{salt: salt}(
            IPoolManager(address(manager)), ICreatorNFT(address(creatorNFT)), team, address(usdc), address(0), address(this)
        );
        require(address(hook) == hookAddr, "hook addr");

        address impl = address(new BodkinERC20());
        LauncherV1.StartFdv[] memory fdvs = new LauncherV1.StartFdv[](2);
        // These tests exercise the ROUTER path, not graduation: the migration target is set far above
        // what the tests' buys can reach, so the (now 400M-token, faster) curve never completes and
        // freezes trading mid-test.
        fdvs[0] = LauncherV1.StartFdv({numeraire: address(0), fdvRaw: 1 ether, migrationTargetRaw: 400 ether});
        fdvs[1] = LauncherV1.StartFdv({numeraire: address(usdc), fdvRaw: 3_000e6, migrationTargetRaw: 1_200_000e6});
        launcher = new LauncherV1(
            IPoolManager(address(manager)), IHooks(address(hook)), creatorNFT, impl, feeRecipient, resolver, deployer, fdvs
        );
        creatorNFT.setLaunchpad(address(launcher));
        hook.setLauncher(address(launcher));

        // (ETH, USDC) conversion pool the hook needs to convert USDC payouts.
        PoolKey memory usdcKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(usdc)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        manager.initialize(usdcKey, SQRT_PRICE_ETH_USDC);
        usdc.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity{value: 500 ether}(
            usdcKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 5e15,
                salt: 0
            }),
            ""
        );
        hook.setUsdcPool(usdcKey);

        // The pieces under test, deployed EXACTLY as DeployLocalV1 does them: the canonical
        // Permit2 runtime injected at a fresh CREATE address (`Permit2Runtime`, a real deploy —
        // not an `vm.etch`), and our dev Universal Router on top.
        permit2 = IAllowanceTransfer(address(new Permit2Runtime()));
        router = new LocalUniversalRouter(IPoolManager(address(manager)), permit2);
        assertEq(address(permit2).code.length, 9152, "Permit2 runtime injected");
    }

    // ---------------------------------------------------------------------------------------------
    // ecosystem buy: native ETH -> coin
    // ---------------------------------------------------------------------------------------------

    function test_EcosystemBuy_EthForToken() public {
        address token = _launch("Neko", "NEKO");
        PoolKey memory key = launcher.poolKeyOf(token); // currency0 = ETH(0), currency1 = coin

        (bytes memory commands, bytes[] memory inputs) = _ecoBuy(key, 1 ether, 1);
        vm.prank(user);
        router.execute{value: 1 ether}(commands, inputs, block.timestamp);

        assertGt(BodkinERC20(token).balanceOf(user), 0, "user got coins");
        assertEq(address(router).balance, 0, "router holds no ETH");
        // 1% fee accrued on the ETH side. The autocompound slice (10%, banked in ETH until it is
        // compounded) is the fee's fingerprint: this suite wires the USDC pool, so the creator and
        // team slices are converted and delivered in-swap and read 0 here, and it wires no BODKIN
        // venue, so the hook books no burn slice at all (that 10% goes to the creator instead).
        assertApproxEqRel(hook.autocompoundWei(token), (0.01 ether * 1000) / 10_000, 0.01e18, "1% eth fee accrued");
        assertEq(hook.burnWei(token), 0, "no venue: no burn is booked");
    }

    function test_EcosystemBuy_EnforcesMinOut() public {
        address token = _launch("Neko", "NEKO");
        PoolKey memory key = launcher.poolKeyOf(token);
        (bytes memory commands, bytes[] memory inputs) = _ecoBuy(key, 1 ether, type(uint128).max);
        vm.prank(user);
        vm.expectRevert(); // TAKE_ALL: V4TooLittleReceived
        router.execute{value: 1 ether}(commands, inputs, block.timestamp);
    }

    // ---------------------------------------------------------------------------------------------
    // ecosystem sell: coin -> native ETH (ERC-20 input via Permit2 direct-approve)
    // ---------------------------------------------------------------------------------------------

    function test_EcosystemSell_TokenForEth() public {
        address token = _launch("Neko", "NEKO");
        PoolKey memory key = launcher.poolKeyOf(token);
        uint128 bought = _buy(token, key, 2 ether);

        _permit2Approve(token, bought);
        // coin (currency1) -> ETH (currency0): zeroForOne=false, output taken to the user.
        (bytes memory commands, bytes[] memory inputs) =
            _hookPoolSwap(key, false, token, address(0), bought, 1, ActionConstants.MSG_SENDER);

        uint256 ethBefore = user.balance;
        vm.prank(user);
        router.execute(commands, inputs, block.timestamp);

        assertGt(user.balance - ethBefore, 0, "cashed out to native ETH");
        assertEq(BodkinERC20(token).balanceOf(user), 0, "coin fully spent");
        assertEq(address(router).balance, 0, "no ETH stranded in router");
    }

    /// The same ecosystem sell, but authorizing the router through the in-batch PERMIT2_PERMIT
    /// command with a signed PermitSingle — proving the router's 0x0a dispatch, not just _pay.
    function test_EcosystemSell_WithSignedPermitCommand() public {
        address token = _launch("Neko", "NEKO");
        PoolKey memory key = launcher.poolKeyOf(token);
        uint128 bought = _buy(token, key, 2 ether);

        // Only the one-time ERC-20 approve to Permit2; the router allowance comes from the signature.
        vm.prank(user);
        BodkinERC20(token).approve(address(permit2), type(uint256).max);

        (IAllowanceTransfer.PermitSingle memory ps, bytes memory sig) =
            _signPermit(token, address(router), bought, uint48(block.timestamp + 3600));

        bytes memory permitInput = abi.encode(ps, sig);
        (, bytes[] memory swapInputs) =
            _hookPoolSwap(key, false, token, address(0), bought, 1, ActionConstants.MSG_SENDER);

        // Prepend the PERMIT2_PERMIT (0x0a) command to the V4_SWAP (0x10).
        bytes memory commands = abi.encodePacked(uint8(0x0a), uint8(0x10));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = permitInput;
        inputs[1] = swapInputs[0];

        uint256 ethBefore = user.balance;
        vm.prank(user);
        router.execute(commands, inputs, block.timestamp);

        assertGt(user.balance - ethBefore, 0, "sold via signed Permit2 permit");
        assertEq(BodkinERC20(token).balanceOf(user), 0, "coin fully spent");
    }

    // ---------------------------------------------------------------------------------------------
    // USDC-numeraire buy/sell: USDC <-> coin (ERC-20 input via Permit2)
    // ---------------------------------------------------------------------------------------------

    function test_NumeraireBuy_UsdcForToken() public {
        address token = _launchUsdc("Yen", "YEN");
        PoolKey memory key = launcher.poolKeyOf(token); // currency0 = USDC, currency1 = coin
        usdc.transfer(user, 10_000e6);

        _permit2Approve(address(usdc), 1_000e6);
        // USDC (currency0) -> coin (currency1): zeroForOne=true.
        (bytes memory commands, bytes[] memory inputs) =
            _hookPoolSwap(key, true, address(usdc), token, 1_000e6, 1, ActionConstants.MSG_SENDER);

        vm.prank(user);
        router.execute(commands, inputs, block.timestamp);

        assertGt(BodkinERC20(token).balanceOf(user), 0, "got coins for USDC");
        uint256 fee = hook.creatorWei(token) + hook.burnWei(token) + hook.teamWei(token) + hook.autocompoundWei(token)
            + hook.creatorOut(token) + hook.teamOut(token, address(usdc));
        assertEq(fee, (1_000e6 * 100) / 10_000, "1% USDC fee accrued");
    }

    function test_NumeraireSell_TokenForUsdc() public {
        address token = _launchUsdc("Yen", "YEN");
        PoolKey memory key = launcher.poolKeyOf(token);
        usdc.transfer(user, 10_000e6);

        // Buy some coin first (USDC -> coin), then sell it back.
        _permit2Approve(address(usdc), 2_000e6);
        (bytes memory bc, bytes[] memory bi) =
            _hookPoolSwap(key, true, address(usdc), token, 2_000e6, 1, ActionConstants.MSG_SENDER);
        vm.prank(user);
        router.execute(bc, bi, block.timestamp);
        uint128 bought = uint128(BodkinERC20(token).balanceOf(user));

        _permit2Approve(token, bought);
        // coin (currency1) -> USDC (currency0): zeroForOne=false.
        (bytes memory commands, bytes[] memory inputs) =
            _hookPoolSwap(key, false, token, address(usdc), bought, 1, ActionConstants.MSG_SENDER);
        uint256 before = usdc.balanceOf(user);
        vm.prank(user);
        router.execute(commands, inputs, block.timestamp);

        assertGt(usdc.balanceOf(user) - before, 0, "got USDC back");
        assertEq(BodkinERC20(token).balanceOf(user), 0, "coin fully spent");
    }

    // ---------------------------------------------------------------------------------------------
    // coin <-> coin (both ETH-quoted): two chained V4_SWAP commands, ETH held in the router between
    // ---------------------------------------------------------------------------------------------

    function test_CoinToCoin_BothEthQuoted() public {
        address tokenIn = _launch("In", "IN");
        address tokenOut = _launch("Out", "OUT");
        PoolKey memory keyIn = launcher.poolKeyOf(tokenIn);
        PoolKey memory keyOut = launcher.poolKeyOf(tokenOut);
        uint128 bought = _buy(tokenIn, keyIn, 2 ether);

        _permit2Approve(tokenIn, bought);

        // Hop 1: tokenIn -> ETH, taken to the router (ADDRESS_THIS), pulled via Permit2.
        bytes memory hop1 = _hop(keyIn, false, tokenIn, bought, true, address(0), ActionConstants.ADDRESS_THIS, 0);
        // Hop 2: router's ETH -> tokenOut, delivered to the user.
        bytes memory hop2 = _hop(
            keyOut, true, address(0), ActionConstants.CONTRACT_BALANCE, false, tokenOut, ActionConstants.MSG_SENDER, 1
        );

        bytes memory commands = abi.encodePacked(uint8(0x10), uint8(0x10));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = hop1;
        inputs[1] = hop2;

        vm.prank(user);
        router.execute(commands, inputs, block.timestamp);

        assertGt(BodkinERC20(tokenOut).balanceOf(user), 0, "crossed coin->coin");
        assertEq(BodkinERC20(tokenIn).balanceOf(user), 0, "tokenIn fully spent");
        assertEq(address(router).balance, 0, "no ETH stranded in router");
    }

    // ---------------------------------------------------------------------------------------------
    // bridge: USDC-quoted coin bought with / sold to native ETH (ETH ↔ USDC plain pool + hooked pool)
    // — the sim exercises these; the local UR handles a plain-pool hop chained with a hooked one.
    // ---------------------------------------------------------------------------------------------

    function test_BridgeBuy_EthForUsdcQuotedCoin() public {
        address token = _launchUsdc("Yen", "YEN");
        PoolKey memory coinKey = launcher.poolKeyOf(token); // USDC = currency0, coin = currency1

        // Hop 1: ETH → USDC through the plain bridge pool, USDC kept in the router (ADDRESS_THIS).
        bytes memory hop1 = _nativeHop(_bridgeKey(), true, 0.02 ether, address(usdc), ActionConstants.ADDRESS_THIS, 0);
        // Hop 2: the router's USDC → coin through our hooked pool, delivered to the user.
        bytes memory hop2 =
            _hop(coinKey, true, address(usdc), ActionConstants.CONTRACT_BALANCE, false, token, ActionConstants.MSG_SENDER, 1);

        bytes memory commands = abi.encodePacked(uint8(0x10), uint8(0x10));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = hop1;
        inputs[1] = hop2;

        vm.prank(user);
        router.execute{value: 0.02 ether}(commands, inputs, block.timestamp);

        assertGt(BodkinERC20(token).balanceOf(user), 0, "bridged ETH -> USDC -> coin");
        assertEq(address(router).balance, 0, "no ETH stranded");
        assertEq(usdc.balanceOf(address(router)), 0, "no USDC stranded");
    }

    function test_BridgeSell_UsdcQuotedCoinForEth() public {
        address token = _launchUsdc("Yen", "YEN");
        PoolKey memory coinKey = launcher.poolKeyOf(token);
        usdc.transfer(user, 10_000e6);

        // Buy some coin with USDC first.
        _permit2Approve(address(usdc), 2_000e6);
        (bytes memory bc, bytes[] memory bi) =
            _hookPoolSwap(coinKey, true, address(usdc), token, 2_000e6, 1, ActionConstants.MSG_SENDER);
        vm.prank(user);
        router.execute(bc, bi, block.timestamp);
        uint128 bought = uint128(BodkinERC20(token).balanceOf(user));

        _permit2Approve(token, bought);
        // Hop 1: coin → USDC through our hooked pool, USDC kept in the router.
        bytes memory hop1 =
            _hop(coinKey, false, token, bought, true, address(usdc), ActionConstants.ADDRESS_THIS, 0);
        // Hop 2: the router's USDC → ETH through the plain bridge pool, delivered to the user.
        bytes memory hop2 = _hop(
            _bridgeKey(), false, address(usdc), ActionConstants.CONTRACT_BALANCE, false, address(0), ActionConstants.MSG_SENDER, 1
        );

        bytes memory commands = abi.encodePacked(uint8(0x10), uint8(0x10));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = hop1;
        inputs[1] = hop2;

        uint256 ethBefore = user.balance;
        vm.prank(user);
        router.execute(commands, inputs, block.timestamp);

        assertGt(user.balance - ethBefore, 0, "bridged coin -> USDC -> ETH");
        assertEq(usdc.balanceOf(address(router)), 0, "no USDC stranded");
    }

    // ---------------------------------------------------------------------------------------------
    // guards
    // ---------------------------------------------------------------------------------------------

    function test_UnsupportedCommand_Reverts() public {
        bytes memory commands = abi.encodePacked(uint8(0x0b)); // WRAP_ETH — not implemented locally
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(ActionConstants.ADDRESS_THIS, uint256(0));
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(LocalUniversalRouter.UnsupportedCommand.selector, uint256(0x0b)));
        router.execute(commands, inputs, block.timestamp);
    }

    function test_Execute_RevertsExpired() public {
        address token = _launch("Neko", "NEKO");
        PoolKey memory key = launcher.poolKeyOf(token);
        (bytes memory commands, bytes[] memory inputs) = _ecoBuy(key, 1 ether, 1);
        vm.warp(1000);
        vm.prank(user);
        vm.expectRevert(LocalUniversalRouter.TransactionDeadlinePassed.selector);
        router.execute{value: 1 ether}(commands, inputs, block.timestamp - 1);
    }

    // ---------------------------------------------------------------------------------------------
    // encoders — byte-identical to urChain.ts / universalRouter.ts
    // ---------------------------------------------------------------------------------------------

    /// The plain (ETH, USDC) bridge pool key at this suite's tier.
    function _bridgeKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(usdc)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }

    /// A native-ETH first hop (SWAP_EXACT_IN_SINGLE + SETTLE_ALL + TAKE), output taken to `recipient`
    /// (ADDRESS_THIS keeps it in the router for a chained next hop). Mirrors urChain.ts `v4NativeInHop`.
    function _nativeHop(
        PoolKey memory key,
        bool zeroForOne,
        uint128 amountIn,
        address outputCurrency,
        address recipient,
        uint128 minOut
    ) internal pure returns (bytes memory) {
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                hookData: ""
            })
        );
        params[1] = abi.encode(Currency.unwrap(key.currency0), uint256(amountIn)); // SETTLE_ALL(ETH, amountIn)
        params[2] = abi.encode(outputCurrency, recipient, uint256(ActionConstants.OPEN_DELTA)); // TAKE
        return abi.encode(actions, params);
    }

    /// Native-ETH ecosystem buy: SWAP_EXACT_IN_SINGLE + SETTLE_ALL + TAKE_ALL (universalRouter.ts).
    function _ecoBuy(PoolKey memory key, uint128 amountIn, uint128 minOut)
        internal
        pure
        returns (bytes memory commands, bytes[] memory inputs)
    {
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                hookData: ""
            })
        );
        params[1] = abi.encode(Currency.unwrap(key.currency0), uint256(amountIn)); // SETTLE_ALL(ETH, amountIn)
        params[2] = abi.encode(Currency.unwrap(key.currency1), uint256(minOut)); // TAKE_ALL(coin, minOut)

        commands = abi.encodePacked(uint8(0x10));
        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
    }

    /// A single hooked-pool swap with an ERC-20 input (Permit2), output to `recipient`:
    /// SETTLE + SWAP_EXACT_IN_SINGLE + TAKE (urChain.ts `v4HopCmd` / `encodeHookPoolSwap`).
    function _hookPoolSwap(
        PoolKey memory key,
        bool zeroForOne,
        address inputCurrency,
        address outputCurrency,
        uint128 amountIn,
        uint128 minOut,
        address recipient
    ) internal pure returns (bytes memory commands, bytes[] memory inputs) {
        commands = abi.encodePacked(uint8(0x10));
        inputs = new bytes[](1);
        inputs[0] = _hop(key, zeroForOne, inputCurrency, amountIn, true, outputCurrency, recipient, minOut);
    }

    /// One V4_SWAP input: SETTLE(currency,amount,payerIsUser) + SWAP_EXACT_IN_SINGLE(OPEN_DELTA)
    /// + TAKE(outputCurrency,recipient,OPEN_DELTA). Mirrors urChain.ts `v4HopCmd` exactly.
    function _hop(
        PoolKey memory key,
        bool zeroForOne,
        address settleCurrency,
        uint256 settleAmount,
        bool payerIsUser,
        address takeCurrency,
        address takeRecipient,
        uint128 minOut
    ) internal pure returns (bytes memory) {
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SETTLE), uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.TAKE));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(settleCurrency, settleAmount, payerIsUser);
        params[1] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: ActionConstants.OPEN_DELTA,
                amountOutMinimum: minOut,
                hookData: ""
            })
        );
        params[2] = abi.encode(takeCurrency, takeRecipient, uint256(ActionConstants.OPEN_DELTA));
        return abi.encode(actions, params);
    }

    // ---------------------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------------------

    /// User grants the router a Permit2 allowance for `token` (one-time ERC-20 approve + Permit2 approve).
    function _permit2Approve(address token, uint256 amount) internal {
        vm.startPrank(user);
        ERC20(token).approve(address(permit2), type(uint256).max);
        permit2.approve(token, address(router), uint160(amount), uint48(block.timestamp + 3600));
        vm.stopPrank();
    }

    /// Buy `ethIn` worth of `token` through the router; returns the coin amount received.
    function _buy(address token, PoolKey memory key, uint256 ethIn) internal returns (uint128) {
        (bytes memory commands, bytes[] memory inputs) = _ecoBuy(key, uint128(ethIn), 1);
        vm.prank(user);
        router.execute{value: ethIn}(commands, inputs, block.timestamp);
        return uint128(BodkinERC20(token).balanceOf(user));
    }

    function _signPermit(address token, address spender, uint160 amount, uint48 sigDeadline)
        internal
        view
        returns (IAllowanceTransfer.PermitSingle memory ps, bytes memory sig)
    {
        (,, uint48 nonce) = permit2.allowance(user, token, spender);
        ps = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: token,
                amount: amount,
                expiration: sigDeadline,
                nonce: nonce
            }),
            spender: spender,
            sigDeadline: sigDeadline
        });
        bytes32 detailsHash = keccak256(abi.encode(PERMIT_DETAILS_TYPEHASH, ps.details));
        bytes32 structHash = keccak256(abi.encode(PERMIT_SINGLE_TYPEHASH, detailsHash, ps.spender, ps.sigDeadline));
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", IEIP712(address(permit2)).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function _usdcPayout() internal view returns (LauncherV1.PayoutParams memory) {
        return LauncherV1.PayoutParams({
            token: address(usdc),
            viaHub: false,
            wethPaired: false,
            fee: 0,
            tickSpacing: 0,
            feeRecipient: address(0), autocompoundOff: false, creatorFeeBps: 0, lpFeeBps: 0, lpRewardsOff: false
        });
    }

    function _launch(string memory name, string memory sym) internal returns (address token) {
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        token = launcher.launch{value: 0.0005 ether}(name, sym, "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/metadata.json", bytes32(0), address(0), 0, _usdcPayout());
    }

    function _launchUsdc(string memory name, string memory sym) internal returns (address token) {
        vm.deal(creator, 1 ether);
        bytes32 salt;
        for (uint256 i = 1; i < 512; i++) {
            address predicted = Clones.predictDeterministicAddress(
                launcher.launchTokenImpl(), keccak256(abi.encodePacked(creator, bytes32(i))), address(launcher)
            );
            if (predicted > address(usdc)) {
                salt = bytes32(i);
                break;
            }
        }
        require(salt != bytes32(0), "no salt above usdc");
        vm.prank(creator);
        token = launcher.launch{value: 0.0005 ether}(name, sym, "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/metadata.json", salt, address(usdc), 0, _usdcPayout());
    }

    receive() external payable {}
}
