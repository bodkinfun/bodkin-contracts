// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./LauncherV1.t.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

/// @notice The two ticks the protocol's own positions sit on are RESERVED against outside adds.
///
/// v4-core caps the gross liquidity referencing any single tick and reverts `TickLiquidityOverflow` on the
/// add that would exceed it. At the extreme ticks that cap is reachable for a couple of millionths of an
/// ETH, because the amount a given L needs shrinks towards the ends of the range. Both protocol positions —
/// the launcher's migrated full range and the hook's autocompound, which deepens it — use the same pair of
/// extreme ticks, and both must keep being able to add to them: migration is the ONLY way to clear the
/// post-curve trading freeze, and autocompound is the only consumer of its bank. Saturating either tick
/// therefore froze a coin permanently, for a price anyone can pay, with no way to undo it (the dust
/// position belongs to the attacker). These tests reproduce the attack and prove the pool now refuses it
/// while every honest range — including a UI "full range", one spacing outside on both sides — still works.
contract ReservedTicksTest is LauncherV1Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    int24 internal constant RESERVED_LO = -887160; // the launcher's migrated tickLower
    int24 internal constant RESERVED_HI = 887160; // the launcher's migrated tickUpper
    int24 internal constant UI_FULL_LO = -887220; // what a Uniswap UI calls "full range" at spacing 60
    int24 internal constant UI_FULL_HI = 887220;

    PoolModifyLiquidityTest internal lpRouter;
    address internal attacker;

    function setUp() public override {
        super.setUp();
        lpRouter = new PoolModifyLiquidityTest(manager);
        attacker = makeAddr("attacker");
        vm.deal(attacker, 10 ether);
    }

    /// v4-core's `Pool.tickSpacingToMaxLiquidityPerTick(60)`: floor(MIN/60) = -14788, MAX/60 = 14787,
    /// so 29576 usable ticks share `type(uint128).max`.
    function _maxLiqPerTick60() internal pure returns (uint128) {
        return uint128(type(uint128).max / uint256(29576));
    }

    function _buyUntilCurveComplete(PoolKey memory key, address token) internal {
        PoolSwapTest.TestSettings memory st = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        (int24 tickLower,,,) = launcher.curvePositions(token);
        for (uint256 i = 0; i < 200; i++) {
            (, int24 curTick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
            if (curTick <= tickLower + 60) break;
            swapRouter.swap{value: 0.2 ether}(
                key,
                SwapParams({zeroForOne: true, amountSpecified: -0.2 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
                st,
                ""
            );
        }
    }

    /// v4 wraps a failing hook callback rather than bubbling it raw, and the wrapper's exact shape is
    /// its business, not ours. So: make the call by hand, require that it failed, and require that OUR
    /// selector is in what came back. Asserting only "it reverted" would pass for any reason at all —
    /// including the TickLiquidityOverflow this guard exists to prevent.
    function _refusedAsReservedTick(PoolKey memory key, int24 lower, int24 upper, uint128 liq) internal {
        vm.prank(attacker);
        (bool ok, bytes memory ret) = address(lpRouter).call{value: 1 ether}(
            // The three-argument overload, named explicitly: the router has two.
            abi.encodeWithSignature(
                "modifyLiquidity((address,address,uint24,int24,address),(int24,int24,int256,bytes32),bytes)",
                key,
                ModifyLiquidityParams({
                    tickLower: lower,
                    tickUpper: upper,
                    liquidityDelta: int256(uint256(liq)),
                    salt: 0
                }),
                bytes("")
            )
        );
        assertFalse(ok, "the add must revert");
        assertTrue(_mentions(ret, FeeHook.ReservedBoundaryTick.selector), "and for the reserved-tick reason");
    }

    /// Does `data` contain these four bytes anywhere? (The reason sits nested inside v4's wrapper.)
    function _mentions(bytes memory data, bytes4 selector) internal pure returns (bool) {
        for (uint256 i = 0; i + 4 <= data.length; i++) {
            if (bytes4(bytes.concat(data[i], data[i + 1], data[i + 2], data[i + 3])) == selector) return true;
        }
        return false;
    }

    function _tryFillTick(PoolKey memory key, int24 lower, int24 upper, uint128 liq) internal {
        vm.prank(attacker);
        lpRouter.modifyLiquidity{value: 1 ether}(
            key,
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: int256(uint256(liq)), salt: 0}),
            ""
        );
    }

    /// The attack itself: filling the migration's upper boundary tick is refused, so its gross liquidity
    /// is untouched. Every way of referencing a reserved tick — as the position's upper OR its lower —
    /// is covered, for both reserved ticks.
    function test_OutsiderCannotReferenceEitherReservedTick() public {
        address token = _launch();
        PoolKey memory key = launcher.poolKeyOf(token);
        // A DELIBERATELY SMALL position: this test is about the guard refusing a reserved boundary at all,
        // not about saturation. Sized to the per-tick cap, v4-core would refuse the lower pair first with
        // its own TickLiquidityOverflow — the launcher's wall already sits on that tick — and the test
        // would pass without the guard existing. The saturation attack itself is the next two tests.
        uint128 small = 1e9;

        // A range BELOW the price is paid for in the token, so the attacker needs some: without it the
        // add would revert for want of funds and prove nothing about the guard. (That is exactly what
        // an earlier version of this test did — it asserted only that something reverted.)
        PoolSwapTest.TestSettings memory st = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            st,
            ""
        );
        IERC20(token).transfer(attacker, IERC20(token).balanceOf(address(this)));
        vm.prank(attacker);
        IERC20(token).approve(address(lpRouter), type(uint256).max);

        (uint128 grossHiBefore,) = IPoolManager(address(manager)).getTickLiquidity(key.toId(), RESERVED_HI);
        (uint128 grossLoBefore,) = IPoolManager(address(manager)).getTickLiquidity(key.toId(), RESERVED_LO);

        _refusedAsReservedTick(key, 887100, RESERVED_HI, small); // reserved tick as the UPPER bound
        _refusedAsReservedTick(key, RESERVED_HI, UI_FULL_HI, small); // ...and as the LOWER bound
        _refusedAsReservedTick(key, UI_FULL_LO, RESERVED_LO, small);
        _refusedAsReservedTick(key, RESERVED_LO, -887100, small);

        (uint128 grossHiAfter,) = IPoolManager(address(manager)).getTickLiquidity(key.toId(), RESERVED_HI);
        (uint128 grossLoAfter,) = IPoolManager(address(manager)).getTickLiquidity(key.toId(), RESERVED_LO);
        assertEq(grossHiAfter, grossHiBefore, "nothing was added to the upper reserved tick");
        assertEq(grossLoAfter, grossLoBefore, "nothing was added to the lower reserved tick");
    }

    /// End to end: the attack that used to brick migrate() now cannot land, the curve graduates, migration
    /// completes and trading is live again.
    function test_MigrationSurvivesTheBoundaryTickAttack() public {
        address token = _launch();
        PoolKey memory key = launcher.poolKeyOf(token);

        _refusedAsReservedTick(key, 887100, RESERVED_HI, _maxLiqPerTick60());

        _buyUntilCurveComplete(key, token);
        launcher.migrate(token);
        (,,, bool migrated) = launcher.curvePositions(token);
        assertTrue(migrated, "migration completed despite the attempt");

        PoolSwapTest.TestSettings memory st = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap{value: 0.01 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -0.01 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            st,
            ""
        );
    }

    /// The same tick also carries the hook's autocompound position after migration: the fill is refused
    /// there too, so the bank keeps draining into liquidity instead of growing forever.
    function test_AutocompoundSurvivesTheBoundaryTickAttack() public {
        address token = _launch();
        PoolKey memory key = launcher.poolKeyOf(token);
        _buyUntilCurveComplete(key, token);
        launcher.migrate(token);

        (uint128 gross,) = IPoolManager(address(manager)).getTickLiquidity(key.toId(), RESERVED_HI);
        _refusedAsReservedTick(key, 887100, RESERVED_HI, _maxLiqPerTick60() - gross);
        (uint128 grossAfter,) = IPoolManager(address(manager)).getTickLiquidity(key.toId(), RESERVED_HI);
        assertEq(grossAfter, gross, "the compound position's tick was not saturated");

        // The slice accrued over the whole curve is still banked; the next buy folds it back into the
        // coin's own full-range position from inside the swap. Under the attack this add reverted forever
        // and the bank could only grow.
        uint256 bankBefore = hook.autocompoundWei(token);
        assertGt(bankBefore, 0, "sanity: the autocompound bank filled over the curve");
        uint128 liqBefore = IPoolManager(address(manager)).getLiquidity(key.toId());
        PoolSwapTest.TestSettings memory st = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap{value: 3 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -3 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            st,
            ""
        );
        assertGt(IPoolManager(address(manager)).getLiquidity(key.toId()), liqBefore, "the compound deepened the pool");
        assertLt(hook.autocompoundWei(token), bankBefore, "the bank was spent, not stranded");
    }

    /// Honest liquidity is untouched: a UI "full range" sits one spacing outside both reserved ticks, and
    /// an ordinary narrow range never comes near them.
    function test_HonestRangesStillAdd() public {
        address token = _launch();
        PoolKey memory key = launcher.poolKeyOf(token);
        // A two-sided range needs the token as well, so buy some first.
        PoolSwapTest.TestSettings memory st = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            st,
            ""
        );
        IERC20(token).approve(address(lpRouter), type(uint256).max);

        // The UI's "full range" — one spacing outside both reserved ticks.
        lpRouter.modifyLiquidity{value: 1 ether}(
            key,
            ModifyLiquidityParams({tickLower: UI_FULL_LO, tickUpper: UI_FULL_HI, liquidityDelta: 1e12, salt: 0}),
            ""
        );
        (uint128 grossUi,) = IPoolManager(address(manager)).getTickLiquidity(key.toId(), UI_FULL_HI);
        assertGt(grossUi, 0, "the UI full range was added");

        // A range that SPANS a reserved tick is fine too: only a position's two BOUNDARY ticks carry gross
        // liquidity, so nothing in between can be saturated.
        (uint128 grossResBefore,) = IPoolManager(address(manager)).getTickLiquidity(key.toId(), RESERVED_LO);
        lpRouter.modifyLiquidity{value: 1 ether}(
            key,
            ModifyLiquidityParams({tickLower: UI_FULL_LO, tickUpper: -887100, liquidityDelta: 1e12, salt: 0}),
            ""
        );
        (uint128 grossResAfter,) = IPoolManager(address(manager)).getTickLiquidity(key.toId(), RESERVED_LO);
        assertEq(grossResAfter, grossResBefore, "spanning a reserved tick adds nothing to it");
    }
}
