// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

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

import {FeeHook, ICreatorNFT} from "../../src/launchpad/v1/FeeHook.sol";
import {LauncherV1} from "../../src/launchpad/v1/LauncherV1.sol";
import {BodkinERC20} from "../../src/launchpad/BodkinERC20.sol";
import {CreatorNFT} from "../../src/launchpad/CreatorNFT.sol";
import {MockWETH} from "../../src/mocks/MockWETH.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USD Coin", "mUSDC") {
        _mint(msg.sender, 1e30);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @notice The FeeHook access model AFTER the fee-infra addresses moved onto the launcher's 2-of-2:
///         - the deployer-only ops admin survives the `owner` renounce and now maintains ONLY the
///           team payout-token allow-list ({setTeamPayoutAllowed}); it can no longer touch weth;
///         - {setFeeToken} (the weth re-point) is launcher-ONLY — the hook rejects every other caller
///           (admin included) with NotLauncher; the 2-of-2 signature layer that fronts it lives in
///           {LauncherV1.updateFeeToken} and is exercised in LauncherV1.t.sol;
///         - the WETH branch re-points `weth`; the USDC selector reverts (UsdcUsesDedicatedPath) —
///           USDC has its own atomic 2-of-2 migration ({FeeHook.migrateUsdc} via
///           {LauncherV1.updateUsdc}) because it also re-wires the pool, payout token and FDV.
contract FeeHookDeployerTest is Test {
    uint160 constant SQRT_PRICE_ETH_USDC = 4339505179874779475002393; // (ETH,USDC) ~ $3,000/ETH

    PoolManager manager;
    PoolModifyLiquidityTest lp;
    FeeHook hook;
    CreatorNFT creatorNFT;
    LauncherV1 launcher;
    MockUSDC usdc;

    address team = address(0x7EA);
    address feeRecipient = address(0xFEE);
    address resolver = address(0x454552);
    address stranger = address(0xBAD);
    // The deployer (the hook's `deployer` role) — the test contract itself opens everything, so `hook.deployer()` == this.
    address deployer;

    function setUp() public {
        deployer = address(this);
        vm.deal(address(this), 100_000 ether);

        manager = new PoolManager(address(this));
        lp = new PoolModifyLiquidityTest(manager);
        usdc = new MockUSDC();
        creatorNFT = new CreatorNFT("");

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );
        // owner_ (6th arg) = the deployer = admin. weth_ (5th) = address(0): WETH-paired payouts
        // start disabled; the launcher's 2-of-2 re-points it (proven via a launcher prank below).
        bytes memory args = abi.encode(
            IPoolManager(address(manager)),
            ICreatorNFT(address(creatorNFT)),
            team,
            address(usdc),
            address(0),
            deployer
        );
        (address hookAddr, bytes32 salt) = HookMiner.find(address(this), flags, type(FeeHook).creationCode, args);
        hook = new FeeHook{salt: salt}(
            IPoolManager(address(manager)),
            ICreatorNFT(address(creatorNFT)),
            team,
            address(usdc),
            address(0),
            deployer
        );
        require(address(hook) == hookAddr, "hook addr");

        address impl = address(new BodkinERC20());
        LauncherV1.StartFdv[] memory fdvs = new LauncherV1.StartFdv[](2);
        fdvs[0] = LauncherV1.StartFdv({numeraire: address(0), fdvRaw: 1 ether, migrationTargetRaw: 15789e15});
        fdvs[1] = LauncherV1.StartFdv({numeraire: address(usdc), fdvRaw: 3_000e6, migrationTargetRaw: 30_000e6});
        launcher = new LauncherV1(
            IPoolManager(address(manager)), IHooks(address(hook)), creatorNFT, impl, feeRecipient, resolver, deployer, fdvs
        );
        creatorNFT.setLaunchpad(address(launcher));
        hook.setLauncher(address(launcher));
        hook.setUsdcPool(_seedEthPool(address(usdc), 3000, 60, SQRT_PRICE_ETH_USDC));
    }

    function test_AdminIsDeployer_AndSurvivesOwnerRenounce() public {
        assertEq(hook.deployer(), deployer, "deployer role = deployer at construction");
        assertEq(hook.owner(), deployer, "owner = deployer at construction");

        hook.renounceOwnership();
        assertEq(hook.owner(), address(0), "owner renounced");
        assertEq(hook.deployer(), deployer, "deployer role SURVIVES the owner renounce");

        // The owner-only wiring setters are dead...
        vm.expectRevert(FeeHook.NotOwner.selector);
        hook.setLauncher(address(0x1234));
        // ...but the admin can still maintain the team payout-token allow-list (its remaining power).
        hook.setTeamPayoutAllowed(address(0xC0FFEE), true);
        assertTrue(hook.teamPayoutAllowed(address(0xC0FFEE)), "admin allow-list still works post-renounce");
    }

    /// The admin can NO LONGER re-point weth — that moved onto the launcher's 2-of-2. Even after the
    /// owner renounce the admin's only power is the payout-token allow-list.
    function test_Admin_CannotSetFeeToken() public {
        // Hoist the selector read: vm.expectRevert attaches to the NEXT external call, so evaluating
        // hook.FEE_TOKEN_WETH() inline would consume the expectation instead of setFeeToken.
        uint8 wethSel = hook.FEE_TOKEN_WETH();
        hook.renounceOwnership();
        // The admin (== this) is not the launcher, so the hook rejects a direct re-point.
        vm.expectRevert(FeeHook.NotLauncher.selector);
        hook.setFeeToken(wethSel, address(0x1337));
        // A stranger is likewise rejected — only the launcher may call it.
        vm.prank(stranger);
        vm.expectRevert(FeeHook.NotLauncher.selector);
        hook.setFeeToken(wethSel, address(0xCCC3));
    }

    /// The hook-side behaviour of {setFeeToken} when the LAUNCHER calls it (the 2-of-2 signature
    /// front-end is tested separately in LauncherV1.t.sol): WETH re-points, USDC + unknown revert.
    function test_SetFeeToken_LauncherOnly_WethRepoints_UsdcAndUnknownRevert() public {
        uint8 wethSel = hook.FEE_TOKEN_WETH();
        uint8 usdcSel = hook.FEE_TOKEN_USDC();

        // WETH branch: launcher re-points it to a real 18-decimal token (coin-validated), repeatably,
        // including back to address(0) (disable — skips validation).
        address newWeth = address(new MockWETH());
        vm.prank(address(launcher));
        hook.setFeeToken(wethSel, newWeth);
        assertEq(hook.weth(), newWeth, "weth re-pointed by launcher");
        vm.prank(address(launcher));
        hook.setFeeToken(wethSel, address(0));
        assertEq(hook.weth(), address(0), "weth cleared by launcher");

        // USDC branch is rejected by the generic setter — it has its own atomic {migrateUsdc} path.
        vm.prank(address(launcher));
        vm.expectRevert(FeeHook.UsdcUsesDedicatedPath.selector);
        hook.setFeeToken(usdcSel, address(0xBBB2));
        assertEq(hook.usdc(), address(usdc), "usdc unchanged after the reverted re-point");

        // Any other selector is rejected outright.
        vm.prank(address(launcher));
        vm.expectRevert(FeeHook.UnknownFeeToken.selector);
        hook.setFeeToken(2, address(0xBBB2));
    }

    function test_SetAdmin_TransferAndRenounce() public {
        // Transfer admin to a new key; the old admin loses the allow-list power.
        hook.setDeployer(stranger);
        assertEq(hook.deployer(), stranger, "deployer role transferred");
        vm.expectRevert(FeeHook.NotDeployer.selector);
        hook.setTeamPayoutAllowed(address(0xC0FFEE), true); // old admin (this) can no longer

        // The new admin renounces → the allow-list is frozen forever.
        vm.prank(stranger);
        hook.setDeployer(address(0));
        assertEq(hook.deployer(), address(0), "deployer role renounced");
        vm.prank(stranger);
        vm.expectRevert(FeeHook.NotDeployer.selector);
        hook.setTeamPayoutAllowed(address(0xC0FFEE), true);
    }

    function test_UsdcIsImmutable() public view {
        // No live re-point path yet (the {setFeeToken} USDC branch reverts); usdc is the constructor
        // value (documented rationale: banked per-currency fees would strand on a naive re-point).
        assertEq(hook.usdc(), address(usdc), "usdc frozen to the constructor value");
        assertEq(hook.teamPayoutToken(), address(usdc), "teamPayoutToken == usdc, immutable");
    }

    /// Open + seed a plain (native ETH, token) pool, returning its key.
    function _seedEthPool(address token, uint24 fee, int24 spacing, uint160 sqrtPrice)
        internal
        returns (PoolKey memory key)
    {
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: fee,
            tickSpacing: spacing,
            hooks: IHooks(address(0))
        });
        manager.initialize(key, sqrtPrice);
        MockUSDC(token).approve(address(lp), type(uint256).max);
        lp.modifyLiquidity{value: 500 ether}(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(spacing),
                tickUpper: TickMath.maxUsableTick(spacing),
                liquidityDelta: 5e15,
                salt: 0
            }),
            ""
        );
    }

    receive() external payable {}
}
