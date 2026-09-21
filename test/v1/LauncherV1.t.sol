// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
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

/// @notice LauncherV1: a launch must open a live (ETH, token) V4 pool wired to the
///         FeeHook, seed 100% of supply single-sided (nothing left on the launcher),
///         permanently lock it, mint the CreatorNFT — and buys must then work and
///         accrue the 1% fee to the hook.
/// The one thing the hook checks about a PositionManager being added: which PoolManager it is bound to.
contract StubPositionManager {
    IPoolManager public poolManager;

    constructor(IPoolManager m) {
        poolManager = m;
    }
}

contract LauncherV1Test is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PoolManager manager;
    PoolSwapTest swapRouter;
    FeeHook hook;
    CreatorNFT creatorNFT;
    LauncherV1 launcher;
    MockUSDC usdc;

    address creator = address(0xC0FFEE);
    // The team wallet is one address across BOTH fee streams (create fee + hook team
    // slice), exactly like the deploy, and is derived from a known key so the 2-of-2
    // governance tests can sign for it. `deployer` (the deployer / co-signer) is a
    // different key; `newTeam` is where the governance moves the wallet to.
    uint256 constant ADMIN_PK = 0xA11CE;
    uint256 constant TEAM_PK = 0x7EA;
    uint256 constant NEW_TEAM_PK = 0xBEEF;
    address deployer;
    address team; // hook team wallet == launcher create-fee recipient
    address feeRecipient;
    address resolver;
    address newTeam;

    uint256 constant SUPPLY = 1_000_000_000e18;

    function setUp() public virtual {
        deployer = vm.addr(ADMIN_PK);
        team = vm.addr(TEAM_PK);
        feeRecipient = team;
        resolver = makeAddr("resolver");
        newTeam = vm.addr(NEW_TEAM_PK);
        vm.deal(address(this), 10_000 ether);
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        usdc = new MockUSDC();
        creatorNFT = new CreatorNFT("");

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );
        // weth = address(0): WETH-paired payouts disabled here (this suite exercises ETH/USDC payouts);
        // the {updateFeeToken} 2-of-2 test re-points it to a nonzero address from this baseline.
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
        fdvs[0] = LauncherV1.StartFdv({numeraire: address(0), fdvRaw: 1 ether, migrationTargetRaw: 15789e15});
        fdvs[1] = LauncherV1.StartFdv({numeraire: address(usdc), fdvRaw: 3_000e6, migrationTargetRaw: 30_000e6});
        launcher = new LauncherV1(
            IPoolManager(address(manager)), IHooks(address(hook)), creatorNFT, impl, feeRecipient, resolver, deployer, fdvs
        );
        creatorNFT.setLaunchpad(address(launcher));
        hook.setLauncher(address(launcher));
    }

    /// Default payout: USDC, paid to whoever holds the creator NFT.
    function _usdcPayout() internal view returns (LauncherV1.PayoutParams memory) {
        return LauncherV1.PayoutParams({
            token: address(usdc),
            viaHub: false, wethPaired: false,
            fee: 0,
            tickSpacing: 0,
            feeRecipient: address(0), autocompoundOff: false, creatorFeeBps: 0, lpFeeBps: 0, lpRewardsOff: false
        });
    }

    /// Creator opts into native ETH at launch.
    function _ethPayout() internal pure returns (LauncherV1.PayoutParams memory) {
        return
            LauncherV1.PayoutParams({token: address(0), viaHub: false, wethPaired: false, fee: 0, tickSpacing: 0, feeRecipient: address(0), autocompoundOff: false, creatorFeeBps: 0, lpFeeBps: 0, lpRewardsOff: false});
    }

    function _launch() internal returns (address token) {
        vm.prank(creator);
        vm.deal(creator, 1 ether);
        token = launcher.launch{value: 0.0005 ether}("Neko", "NEKO", "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/metadata.json", bytes32(0), address(0), 0, _usdcPayout());
    }

    /// A `n`-byte string of 'a', for building an over-length metadata URI.
    function _fill(uint256 n) internal pure returns (string memory) {
        bytes memory b = new bytes(n);
        for (uint256 i; i < n; i++) b[i] = "a";
        return string(b);
    }

    /// The metadata URI must be a well-formed IPFS pointer, not merely non-empty: an empty, too-short,
    /// over-long or foreign-scheme URI is rejected on-chain so no token can carry a broken avatar.
    function test_RejectsMalformedMetadataURI() public {
        vm.deal(creator, 10 ether);
        vm.startPrank(creator);
        string memory ok = "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/metadata.json";

        vm.expectRevert(bytes("Launcher: bad metadata URI length")); // empty
        launcher.launch{value: 0.0005 ether}("A", "A", "", bytes32(0), address(0), 0, _usdcPayout());

        vm.expectRevert(bytes("Launcher: bad metadata URI length")); // ipfs:// but no real CID
        launcher.launch{value: 0.0005 ether}("A", "A", "ipfs://x", bytes32(0), address(0), 0, _usdcPayout());

        vm.expectRevert(bytes("Launcher: bad metadata URI length")); // > 256 bytes
        launcher.launch{value: 0.0005 ether}(
            "A", "A", string(abi.encodePacked("ipfs://", _fill(260))), bytes32(0), address(0), 0, _usdcPayout()
        );

        vm.expectRevert(bytes("Launcher: metadata must be ipfs://")); // right length, wrong scheme
        launcher.launch{value: 0.0005 ether}(
            "A", "A", "https://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/x", bytes32(0), address(0), 0, _usdcPayout()
        );

        // A valid ipfs:// pointer is accepted and stored verbatim as the token's ERC-1046 tokenURI.
        address token = launcher.launch{value: 0.0005 ether}("A", "A", ok, bytes32(0), address(0), 0, _usdcPayout());
        assertEq(BodkinERC20(token).tokenURI(), ok, "valid ipfs:// metadata stored");
        vm.stopPrank();
    }

    /// The smallest salt whose resulting token sorts ABOVE `numeraire` — the launcher's
    /// invariant. Mirrors what the frontend miner does (minus the vanity suffix).
    function _saltAbove(address sender, address numeraire) internal view returns (bytes32) {
        for (uint256 i = 1; i < 512; i++) {
            bytes32 salt = bytes32(i);
            address predicted = Clones.predictDeterministicAddress(
                launcher.launchTokenImpl(), keccak256(abi.encodePacked(sender, salt)), address(launcher)
            );
            if (predicted > numeraire) return salt;
        }
        revert("no salt above numeraire");
    }

    /// A USDC-QUOTED launch: (USDC, token) pool, dev buy paid in USDC.
    function _launchUsdc(uint256 devBuy) internal returns (address token) {
        vm.deal(creator, 1 ether);
        usdc.transfer(creator, devBuy + 1);
        bytes32 salt = _saltAbove(creator, address(usdc));
        vm.startPrank(creator);
        if (devBuy > 0) usdc.approve(address(launcher), devBuy);
        token = launcher.launch{value: 0.0005 ether}(
            "Yen", "YEN", "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/metadata.json", salt, address(usdc), devBuy, _usdcPayout()
        );
        vm.stopPrank();
    }

    // ---- USDC-quoted launches (the numeraire is per-launch; ETH stays default) ----

    function test_UsdcLaunchOpensUsdcQuotedPool() public {
        address token = _launchUsdc(0);

        (,,,, address recNumeraire) = launcher.launchOf(token);
        assertEq(recNumeraire, address(usdc), "recorded as USDC-quoted");
        assertEq(hook.numeraireOf(token), address(usdc), "hook agrees");

        // THE INVARIANT: the numeraire sorts as currency0, so all the range/direction
        // math that ETH pools rely on is unchanged.
        PoolKey memory key = launcher.poolKeyOf(token);
        assertEq(Currency.unwrap(key.currency0), address(usdc), "USDC is currency0");
        assertEq(Currency.unwrap(key.currency1), token, "token is currency1");
        assertTrue(Currency.unwrap(key.currency0) < Currency.unwrap(key.currency1), "sorted");

        (uint160 sqrtP,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertGt(sqrtP, 0, "pool initialized");
        // Supply is fully locked in the position; nothing lingers on the launcher.
        assertEq(BodkinERC20(token).balanceOf(address(launcher)), 0, "launcher holds no token");
    }

    function test_UsdcLaunchAccruesFeesInUsdc() public {
        address token = _launchUsdc(0);
        PoolKey memory key = launcher.poolKeyOf(token);

        // Buy with USDC (currency0 -> currency1 is zeroForOne, same as an ETH pool).
        uint256 amountIn = 1_000e6;
        usdc.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertGt(BodkinERC20(token).balanceOf(address(this)), 0, "buyer got tokens");
        // The 1% fee is skimmed on the NUMERAIRE side, so the buckets hold USDC.
        // Every bucket, WAITING plus BANKED. The creator and team slices are converted
        // into their payout token by the same swap that earns them, so summing only the
        // numeraire buckets would report ~10% of the fee (the burn slice) and look like
        // the fee shrank.
        uint256 fee = hook.creatorWei(token) + hook.burnWei(token) + hook.teamWei(token) + hook.autocompoundWei(token)
            + hook.creatorOut(token) + hook.teamOut(token, address(usdc));
        assertEq(fee, (amountIn * 100) / 10_000, "1% fee accrued in USDC");
        assertEq(BodkinERC20(token).balanceOf(address(hook)), 0, "hook holds no meme token");
    }

    function test_UsdcLaunchDevBuyPullsApproval() public {
        uint256 devBuy = 500e6;
        uint256 before = usdc.balanceOf(creator);
        address token = _launchUsdc(devBuy);

        assertGt(BodkinERC20(token).balanceOf(creator), 0, "creator got dev-buy tokens");
        // The USDC actually left the creator (all but the +1 we funded them with).
        assertLe(usdc.balanceOf(creator), before + 1, "dev buy paid in USDC");
        assertEq(usdc.balanceOf(address(launcher)), 0, "launcher keeps no USDC");
        assertGt(hook.creatorWei(token) + hook.creatorOut(token), 0, "dev buy was fee'd");
    }

    function test_UsdcLaunchRevertsWithoutSalt() public {
        // Only a mined salt can guarantee token > numeraire, so a USDC launch must
        // supply one — the non-deterministic clone path is refused outright.
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        vm.expectRevert(LauncherV1.SaltRequired.selector);
        launcher.launch{value: 0.0005 ether}(
            "Yen", "YEN", "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/metadata.json", bytes32(0), address(usdc), 0, _usdcPayout()
        );
    }

    function test_UsdcLaunchRevertsWhenTokenSortsBelowNumeraire() public {
        // A salt whose token address lands BELOW USDC must be rejected rather than
        // opening a pool with mirrored (untested) semantics.
        bytes32 bad;
        for (uint256 i = 1; i < 512; i++) {
            address predicted = Clones.predictDeterministicAddress(
                launcher.launchTokenImpl(), keccak256(abi.encodePacked(creator, bytes32(i))), address(launcher)
            );
            if (predicted < address(usdc)) {
                bad = bytes32(i);
                break;
            }
        }
        assertTrue(bad != bytes32(0), "found a below-USDC salt");
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        vm.expectRevert(LauncherV1.TokenBelowNumeraire.selector);
        launcher.launch{value: 0.0005 ether}(
            "Low", "LOW", "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/metadata.json", bad, address(usdc), 0, _usdcPayout()
        );
    }

    function test_LaunchRevertsOnUnknownNumeraire() public {
        ERC20 rando = new MockUSDC();
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        vm.expectRevert(LauncherV1.BadNumeraire.selector);
        launcher.launch{value: 0.0005 ether}(
            "Bad", "BAD", "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/metadata.json", bytes32(uint256(1)), address(rando), 0, _usdcPayout()
        );
    }

    function test_UsdcLaunchRejectsExtraEth() public {
        // The launch fee is the ONLY ETH a USDC launch accepts — the dev buy is USDC,
        // so stray ETH is a caller mistake, not an implicit dev buy.
        vm.deal(creator, 2 ether);
        bytes32 salt = _saltAbove(creator, address(usdc));
        vm.prank(creator);
        vm.expectRevert(bytes("Launcher: send only the fee"));
        launcher.launch{value: 0.0005 ether + 1 ether}(
            "Yen", "YEN", "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/metadata.json", salt, address(usdc), 0, _usdcPayout()
        );
    }

    function test_LaunchOpensLockedSingleSidedPool() public {
        uint256 feeRecipBefore = resolver.balance;
        address token = _launch();

        // token exists + recorded, creator owns the fee NFT
        (address recToken,,, address recCreator, address recNumeraire) = launcher.launchOf(token);
        assertEq(recToken, token);
        assertEq(recCreator, creator);
        // ETH-quoted launch, so the recorded numeraire is the zero address. Asserting
        // it also clears the "unused local" warning this destructuring used to raise.
        assertEq(recNumeraire, address(0), "ETH launch records the zero-address numeraire");
        assertEq(creatorNFT.creatorOf(token), creator, "creator holds the fee NFT");

        // 100% of supply is in the pool / locked — nothing lingers on the launcher
        assertEq(BodkinERC20(token).balanceOf(address(launcher)), 0, "launcher holds no token");
        assertEq(BodkinERC20(token).totalSupply(), SUPPLY);

        // pool is initialized (slot0 has a price)
        PoolKey memory key = launcher.poolKeyOf(token);
        (uint160 sqrtP,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertGt(sqrtP, 0, "pool initialized");

        // launch fee forwarded
        // The create fee is BOOKED by the launch, not sent — sending it would run the resolver's code
        // inside someone's launch. Anyone can push it out afterwards.
        // Booked, not sent: a launch runs nobody else's code. The team wallet takes it afterwards.
        assertEq(resolver.balance, feeRecipBefore, "nothing was sent during the launch");
        assertEq(launcher.createFeesOwed(), 0.0005 ether, "the create fee is booked");
        uint256 teamBefore = feeRecipient.balance;
        vm.prank(feeRecipient);
        assertEq(launcher.withdraw(), 0.0005 ether, "the team withdrew it");
        assertEq(feeRecipient.balance, teamBefore + 0.0005 ether, "into the team wallet");
        assertEq(launcher.createFeesOwed(), 0, "nothing left booked");
    }

    function test_LaunchRevertsIfCustomPayoutPoolMissing() public {
        // A custom payout token with NO (ETH, token) pool must be rejected at launch —
        // otherwise fees would accrue but every claim would revert forever.
        ERC20 orphan = new MockUSDC();
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        vm.expectRevert(LauncherV1.PayoutPoolMissing.selector);
        launcher.launch{value: 0.0005 ether}(
            "Orphan",
            "ORPH",
            "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/metadata.json",
            bytes32(0),
            address(0),
            0,
            LauncherV1.PayoutParams({
                token: address(orphan),
                viaHub: false, wethPaired: false,
                fee: 3000,
                tickSpacing: 60,
                feeRecipient: address(0), autocompoundOff: false, creatorFeeBps: 0, lpFeeBps: 0, lpRewardsOff: false
            })
        );
    }

    function test_LaunchRevertsOnNonCanonicalPayoutTier() public {
        ERC20 other = new MockUSDC();
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        vm.expectRevert(LauncherV1.BadPayoutTier.selector);
        launcher.launch{value: 0.0005 ether}(
            "Tier",
            "TIER",
            "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/metadata.json",
            bytes32(0),
            address(0),
            0,
            // fee 1234 / spacing 7 is not a canonical Uniswap tier
            LauncherV1.PayoutParams({
                token: address(other),
                viaHub: false, wethPaired: false,
                fee: 1234,
                tickSpacing: 7,
                feeRecipient: address(0), autocompoundOff: false, creatorFeeBps: 0, lpFeeBps: 0, lpRewardsOff: false
            })
        );
    }

    function test_LaunchStoresFixedFeeRecipient() public {
        address treasury = makeAddr("treasury");
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        address token = launcher.launch{value: 0.0005 ether}(
            "Fix",
            "FIX",
            "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/metadata.json",
            bytes32(0),
            address(0),
            0,
            LauncherV1.PayoutParams({
                token: address(usdc),
                viaHub: false, wethPaired: false,
                fee: 0,
                tickSpacing: 0,
                feeRecipient: treasury, autocompoundOff: false, creatorFeeBps: 0, lpFeeBps: 0, lpRewardsOff: false
            })
        );
        assertEq(hook.payoutRecipientOf(token), treasury, "fees permanently directed to the treasury");
    }

    /// The optional custom creator fee is capped at 5% (500 bps); the launcher rejects a higher one
    /// BEFORE opening the pool (validated in `_validatePayout`, even for a USDC payout token).
    function test_LaunchRevertsOnCreatorFeeAboveMax() public {
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        vm.expectRevert(LauncherV1.CreatorFeeTooHigh.selector);
        launcher.launch{value: 0.0005 ether}(
            "Greed",
            "GREED",
            "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/metadata.json",
            bytes32(0),
            address(0),
            0,
            LauncherV1.PayoutParams({
                token: address(usdc),
                viaHub: false, wethPaired: false,
                fee: 0,
                tickSpacing: 0,
                feeRecipient: address(0), autocompoundOff: false, creatorFeeBps: 501, lpFeeBps: 0, lpRewardsOff: false
            })
        );
    }

    /// The creator's autocompound-off choice and a within-cap custom fee are recorded on the hook.
    function test_LaunchStoresAutocompoundOffAndCustomCreatorFee() public {
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        address token = launcher.launch{value: 0.0005 ether}(
            "Cust",
            "CUST",
            "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/metadata.json",
            bytes32(0),
            address(0),
            0,
            LauncherV1.PayoutParams({
                token: address(usdc),
                viaHub: false, wethPaired: false,
                fee: 0,
                tickSpacing: 0,
                feeRecipient: address(0), autocompoundOff: true, creatorFeeBps: 250, lpFeeBps: 150, lpRewardsOff: true
            })
        );
        FeeHook.PayoutConfig memory cfg = hook.payoutConfigOf(token);
        assertTrue(cfg.autocompoundOff, "autocompound recorded off");
        assertEq(cfg.creatorFeeBps, 250, "custom creator fee recorded (2.5%)");
        assertEq(cfg.lpFeeBps, 150, "custom LP fee recorded (1.5%)");
        assertTrue(cfg.lpRewardsOff, "LP-rewards-off recorded");
    }

    /// The optional custom LP fee is capped at 5% (500 bps); the launcher rejects a higher one BEFORE
    /// opening the pool (validated in `_validatePayout`, even for a USDC payout token).
    function test_LaunchRevertsOnLpFeeAboveMax() public {
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        vm.expectRevert(LauncherV1.LpFeeTooHigh.selector);
        launcher.launch{value: 0.0005 ether}(
            "Greed",
            "GREED",
            "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/metadata.json",
            bytes32(0),
            address(0),
            0,
            LauncherV1.PayoutParams({
                token: address(usdc),
                viaHub: false, wethPaired: false,
                fee: 0,
                tickSpacing: 0,
                feeRecipient: address(0), autocompoundOff: false, creatorFeeBps: 0, lpFeeBps: 501, lpRewardsOff: false
            })
        );
    }

    function test_VanitySaltNamespacedPerSender() public {
        // The SAME mined salt used by two different creators must yield two
        // different token addresses — otherwise the second launch reverts and a
        // front-runner could squat a creator's vanity address. Namespacing the
        // salt to msg.sender makes each creator's address space disjoint.
        bytes32 salt = keccak256("shared-mined-salt");
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);

        vm.prank(alice);
        address a = launcher.launch{value: 0.0005 ether}("A", "A", "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/metadata.json", salt, address(0), 0, _usdcPayout());
        vm.prank(bob);
        address b = launcher.launch{value: 0.0005 ether}("B", "B", "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/metadata.json", salt, address(0), 0, _usdcPayout());

        assertTrue(a != b, "same salt, different senders must not collide");
    }

    function test_BuyOnLaunchedPoolAccruesFee() public {
        address token = _launch();
        PoolKey memory key = launcher.poolKeyOf(token);

        uint256 amountIn = 1 ether;
        swapRouter.swap{value: amountIn}(
            key,
            SwapParams({
                zeroForOne: true, // ETH -> token (buy)
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // buyer received the token, and the 1% ETH fee accrued in the hook
        assertGt(BodkinERC20(token).balanceOf(address(this)), 0, "buyer got tokens");
        // Every bucket, WAITING plus BANKED. The creator and team slices are converted
        // into their payout token by the same swap that earns them, so summing only the
        // numeraire buckets would report ~10% of the fee (the burn slice) and look like
        // the fee shrank.
        uint256 fee = hook.creatorWei(token) + hook.burnWei(token) + hook.teamWei(token) + hook.autocompoundWei(token)
            + hook.creatorOut(token) + hook.teamOut(token, address(usdc));
        assertEq(fee, (amountIn * 100) / 10_000, "1% fee accrued in ETH");
        assertEq(BodkinERC20(token).balanceOf(address(hook)), 0, "hook holds no meme token");
    }

    /// End to end: a launch graduates to ONE full-range position, and its banked autocompound slice
    /// folds back into that SAME position — deepening the pool's active liquidity from its own volume
    /// (the pools.trade property, per-coin). Also covers the one-full-range-position migration path.
    function test_CompoundDeepensTheMigratedPool() public {
        address token = _launch();
        PoolKey memory key = launcher.poolKeyOf(token);
        PoolSwapTest.TestSettings memory st = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        (int24 tickLower,,,) = launcher.curvePositions(token);

        // Drive the curve to completion — buy until the price crosses tickLower (then it freezes). The
        // freeze gate checks the PRE-swap tick, so every buy here is allowed and fully fills.
        for (uint256 i = 0; i < 100; i++) {
            (, int24 curTick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
            if (curTick <= tickLower + 60) break;
            swapRouter.swap{value: 0.2 ether}(
                key,
                SwapParams({zeroForOne: true, amountSpecified: -0.2 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
                st,
                ""
            );
        }

        launcher.migrate(token);
        (,,, bool migrated) = launcher.curvePositions(token);
        assertTrue(migrated, "graduated to one full-range position");

        // The 10% autocompound slice accrued over the whole curve, banked in the hook (no keeper released
        // it — that path is gone). It only folds in once there is a two-sided position to deepen.
        uint256 bankBefore = hook.autocompoundWei(token);
        assertGt(bankBefore, 0, "autocompound slice accrued on the curve");

        // A post-migration buy folds that slice back into the coin's OWN full-range position IN THE SAME
        // swap — the hook does it best-effort in _afterSwap, no keeper, no launcher.compound. getLiquidity
        // is owner-agnostic, so the hook-owned compound add shows up right next to the launcher's seed.
        uint128 liqBefore = IPoolManager(address(manager)).getLiquidity(key.toId());
        swapRouter.swap{value: 3 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -3 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            st,
            ""
        );
        assertGt(
            IPoolManager(address(manager)).getLiquidity(key.toId()),
            liqBefore,
            "in-swap autocompound deepened the pool"
        );
        // The in-swap compound drained the accrued slice (only the compound's OWN 1% fee re-banks a
        // sub-percent dust), even though the buy itself just accrued a fresh, much smaller slice.
        assertLt(hook.autocompoundWei(token), bankBefore, "the in-swap compound drained the accrued slice");

        // The permissionless manual path is still there as an emergency/testable trigger (per-block gated,
        // so roll a block first). It never removes liquidity.
        vm.roll(vm.getBlockNumber() + 1);
        uint128 liqMid = IPoolManager(address(manager)).getLiquidity(key.toId());
        hook.processCompound(token);
        assertGe(
            IPoolManager(address(manager)).getLiquidity(key.toId()),
            liqMid,
            "manual compound never removes liquidity"
        );
    }

    /// Graduation keeps the UNSOLD wall: the numeraire the curve collected is paired into the full-range
    /// position, and every wall token that position could not absorb is re-minted single-sided just
    /// below the graduation price — nothing strands in the launcher. Once the price climbs into that
    /// wall it becomes ACTIVE liquidity, which is what makes the pool deeper at high market caps.
    function test_MigrationKeepsTheUnsoldWallAboveThePrice() public {
        address token = _launch();
        PoolKey memory key = launcher.poolKeyOf(token);
        PoolSwapTest.TestSettings memory st = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        (int24 tickLower,,,) = launcher.curvePositions(token);
        for (uint256 i = 0; i < 100; i++) {
            (, int24 curTick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
            if (curTick <= tickLower + 60) break;
            swapRouter.swap{value: 0.2 ether}(
                key,
                SwapParams({zeroForOne: true, amountSpecified: -0.2 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
                st,
                ""
            );
        }

        launcher.migrate(token);

        (int24 wallUpper, uint128 wallLiq, uint256 wallTokens) = launcher.wallPositions(token);
        assertGt(wallLiq, 0, "the leftover wall was re-minted");
        assertGt(wallTokens, 0, "the wall holds tokens");
        // Most of the BASE wall survives: the numeraire-limited full-range mint absorbs only a share of
        // WALL_SUPPLY (the rungs are separate and untouched), and NOTHING stays behind in the launcher
        // (dust goes to DEAD).
        assertGt(wallTokens, launcher.WALL_SUPPLY() / 2, "most of the base wall is re-minted");
        assertLt(wallTokens, launcher.WALL_SUPPLY(), "some of it was folded into the full-range position");
        assertEq(BodkinERC20(token).balanceOf(address(launcher)), 0, "nothing strands in the launcher");
        (, int24 tickAfter,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertLe(wallUpper, tickAfter, "the wall sits at/below the current tick (token-only)");

        // The wall is NOT active liquidity yet (it is below the price)...
        uint128 activeAtGraduation = IPoolManager(address(manager)).getLiquidity(key.toId());
        assertLt(activeAtGraduation, wallLiq, "wall inactive at graduation");
        // ...but a rally into it turns it on: buy until the tick drops below the wall's top.
        for (uint256 i = 0; i < 50; i++) {
            (, int24 curTick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
            if (curTick < wallUpper - 1) break;
            swapRouter.swap{value: 2 ether}(
                key,
                SwapParams({zeroForOne: true, amountSpecified: -2 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
                st,
                ""
            );
        }
        (, int24 tickDeep,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertLt(tickDeep, wallUpper, "price climbed into the wall");
        assertGe(
            IPoolManager(address(manager)).getLiquidity(key.toId()),
            wallLiq,
            "the wall is now active liquidity on top of the full-range position"
        );
    }

    /// The two rungs: minted at launch far above the graduation price (A bounded, B open-ended),
    /// untouched by migration, and only turned into ACTIVE liquidity once the price climbs into them.
    /// Whole supply accounted for.
    function test_RungsMintedAtLaunchAndActivateAbovePrice() public {
        address token = _launch();
        PoolKey memory key = launcher.poolKeyOf(token);
        PoolSwapTest.TestSettings memory st = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        (int24 tickLower,,,) = launcher.curvePositions(token);
        LauncherV1.RungPosition[2] memory r = launcher.rungsOf(token);
        int24 minUsable = (TickMath.MIN_TICK / 60) * 60 + 60;
        // Rung A: bounded, fully above the graduation price; rung B: open-ended, above rung A's top.
        assertLt(r[0].tickUpper, tickLower, "rung A sits above the graduation price (lower tick)");
        assertLt(r[0].tickLower, r[0].tickUpper, "rung A is a real range");
        assertGt(r[0].tickLower, minUsable, "rung A is bounded (does not run to the usable minimum)");
        assertLt(r[1].tickUpper, r[0].tickLower, "rung B starts above rung A's end");
        assertEq(r[1].tickLower, minUsable, "rung B is open-ended");
        assertEq(r[0].tokens, launcher.RUNG_A_SUPPLY(), "rung A tokens");
        assertEq(r[1].tokens, launcher.RUNG_B_SUPPLY(), "rung B tokens");
        for (uint256 i = 0; i < 2; i++) assertGt(r[i].liquidity, 0, "rung has liquidity");
        assertEq(
            launcher.CURVE_SUPPLY() + launcher.WALL_SUPPLY() + launcher.RUNG_A_SUPPLY() + launcher.RUNG_B_SUPPLY(),
            launcher.TOTAL_SUPPLY(),
            "split covers the supply"
        );
        assertEq(BodkinERC20(token).balanceOf(address(launcher)), 0, "everything is in the pool");

        // Complete the curve and migrate: rungs must be exactly as minted.
        for (uint256 i = 0; i < 100; i++) {
            (, int24 curTick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
            if (curTick <= tickLower + 60) break;
            swapRouter.swap{value: 0.2 ether}(
                key,
                SwapParams({zeroForOne: true, amountSpecified: -0.2 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
                st,
                ""
            );
        }
        launcher.migrate(token);
        LauncherV1.RungPosition[2] memory r2 = launcher.rungsOf(token);
        for (uint256 i = 0; i < 2; i++) {
            assertEq(r2[i].tickLower, r[i].tickLower, "migration leaves the rung lower ticks alone");
            assertEq(r2[i].tickUpper, r[i].tickUpper, "migration leaves the rung upper ticks alone");
            assertEq(r2[i].liquidity, r[i].liquidity, "migration leaves the rung liquidity alone");
        }

        // Rally into rung A: once the tick drops below its top, its liquidity is active.
        for (uint256 i = 0; i < 400; i++) {
            (, int24 curTick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
            if (curTick < r[0].tickUpper - 1) break;
            swapRouter.swap{value: 5 ether}(
                key,
                SwapParams({zeroForOne: true, amountSpecified: -5 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
                st,
                ""
            );
        }
        (, int24 tickDeep,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertLt(tickDeep, r[0].tickUpper, "price climbed into rung A");
        assertGe(IPoolManager(address(manager)).getLiquidity(key.toId()), r[0].liquidity, "rung A is now active liquidity");
    }

    /// THE fee-NFT property, end to end and with the REAL contracts: the income
    /// follows the NFT.
    ///
    /// Both halves of this are covered separately — CreatorNFT.t.sol proves
    /// `creatorOf` reports the new holder after a transfer, and FeeHook.t.sol proves a
    /// non-holder is rejected — but the hook's suite talks to a MOCK NFT, so until now
    /// nothing exercised a real transfer flowing into a real payout. That gap is
    /// exactly where a regression would hide: the hook resolves the payee at CLAIM
    /// time (`creatorNFT.creatorOf(token)` inside `claimCreator`), and someone
    /// "optimising" that into a value cached at launch would pass every other test in
    /// the repo while silently paying the wrong wallet forever.
    function test_FeeStreamFollowsTheNftToItsNewHolder() public {
        // ETH payout on purpose: the payout token IS the numeraire, so the hook banks
        // the creator's slice with no swap. This suite wires no USDC pool, so a USDC
        // payout would have nothing to convert THROUGH and the fee would sit unbanked
        // in `creatorWei` — testing the transfer against an empty balance proves nothing.
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        address token = launcher.launch{value: 0.0005 ether}(
            "Neko", "NEKO", "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/metadata.json", bytes32(0), address(0), 0, _ethPayout()
        );
        PoolKey memory key = launcher.poolKeyOf(token);
        address buyer2 = makeAddr("nft-buyer");

        // Trade so the creator bucket has something in it, converted to USDC.
        swapRouter.swap{value: 2 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(uint256(2 ether)),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertGt(hook.creatorOut(token), 0, "sanity: creator fees banked before the sale");
        uint256 owed = hook.creatorOut(token);

        // The creator sells the stream.
        uint256 id = creatorNFT.nftOf(token);
        // Existence is the mapping back, NOT `id != 0` — the first launch legitimately
        // holds id 0.
        assertEq(creatorNFT.launchToken(id), token, "the launch minted an NFT");
        vm.prank(creator);
        creatorNFT.transferFrom(creator, buyer2, id);

        // The OLD holder can no longer claim…
        vm.prank(creator);
        vm.expectRevert(FeeHook.NotCreator.selector);
        hook.claimCreator(token);

        // …and the new one gets the money, at the new holder's address.
        uint256 before = buyer2.balance;
        uint256 creatorBefore = creator.balance;
        vm.prank(buyer2);
        uint256 paid = hook.claimCreator(token);
        assertEq(paid, owed, "the new holder claimed the whole banked balance");
        assertEq(buyer2.balance - before, paid, "paid to the NFT's CURRENT holder");
        assertEq(creator.balance, creatorBefore, "the previous holder received nothing");
    }

    /// One collection, one id per launch, and the id is never reused or re-mintable.
    function test_OneCollectionWithAUniqueIdPerLaunch() public {
        address a = _launch();
        // Compute the salt BEFORE pranking: `_saltAbove` calls `launcher.launchTokenImpl()`,
        // and that external call would consume the prank, launching as the test contract.
        bytes32 salt = _saltAbove(creator, address(0));
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        address b = launcher.launch{value: 0.0005 ether}(
            "Uma", "UMA", "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/metadata.json", salt, address(0), 0, _usdcPayout()
        );

        uint256 idA = creatorNFT.nftOf(a);
        uint256 idB = creatorNFT.nftOf(b);
        // Ids count from ZERO — on the real deploy that first id is BODKIN's, which is
        // why nothing may treat 0 as "no NFT".
        assertEq(idA, 0, "the first launch holds id 0");
        assertEq(idB, 1, "the second counts up from there");
        assertEq(creatorNFT.nextId(), 2, "the counter is the number minted");
        assertEq(creatorNFT.launchToken(idA), a, "id maps back to its launch");
        assertEq(creatorNFT.launchToken(idB), b);
        // Same ERC-721 contract for every launch — one address to verify on an explorer.
        assertEq(creatorNFT.ownerOf(idA), creator);
        assertEq(creatorNFT.ownerOf(idB), creator);

        // Nobody can mint a second NFT for a launch, launchpad included.
        vm.prank(address(launcher));
        vm.expectRevert(bytes("NFT: already minted"));
        creatorNFT.mint(creator, a);
    }

    /// A COPY of LauncherV1, deployed by anyone, is powerless against our stack.
    ///
    /// Source is public and bytecode is copyable, so "only we may deploy a launcher"
    /// cannot be enforced at deployment — and does not need to be. What matters is
    /// that a foreign launcher cannot touch OUR fee NFT collection or OUR hook, and
    /// that is already true by construction: both wiring setters are one-shot and
    /// owner-only, and the deploy renounces ownership immediately after using them.
    /// Someone deploying this bytecode gets an unrelated launchpad with no access to
    /// our fee stream, our NFT ids, or our pools.
    function test_AForeignLauncherCannotUseOurNftOrHook() public {
        // Same constructor args as ours — the most favourable case for the attacker.
        LauncherV1.StartFdv[] memory fdvs = new LauncherV1.StartFdv[](1);
        fdvs[0] = LauncherV1.StartFdv({numeraire: address(0), fdvRaw: 1 ether, migrationTargetRaw: 15789e15});
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        LauncherV1 evil = new LauncherV1(
            IPoolManager(address(manager)),
            IHooks(address(hook)),
            creatorNFT,
            launcher.launchTokenImpl(),
            attacker,
            attacker,
            makeAddr("evilAdmin"),
            fdvs
        );

        // It cannot mint one of our fee NFTs: `launchpad` is already set to the real
        // launcher and there is no setter left.
        vm.deal(attacker, 1 ether);
        vm.prank(attacker);
        vm.expectRevert(bytes("NFT: only launchpad"));
        evil.launch{value: 0.0005 ether}("Evil", "EVIL", "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/metadata.json", bytes32(0), address(0), 0, _usdcPayout());

        // And the wiring it would need can never be re-pointed at it.
        vm.prank(attacker);
        vm.expectRevert(bytes("NFT: only owner"));
        creatorNFT.setLaunchpad(address(evil));
        vm.prank(attacker);
        vm.expectRevert(FeeHook.NotOwner.selector);
        hook.setLauncher(address(evil));
    }

    function test_DevBuyGivesCreatorTokens() public {
        vm.deal(creator, 3 ether);
        vm.prank(creator);
        address token =
            launcher.launch{value: 0.0005 ether + 1 ether}("Uma", "UMA", "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/metadata.json", bytes32(0), address(0), 0, _usdcPayout());

        assertGt(BodkinERC20(token).balanceOf(creator), 0, "creator got dev-buy tokens");
        // Every bucket, WAITING plus BANKED. The creator and team slices are converted
        // into their payout token by the same swap that earns them, so summing only the
        // numeraire buckets would report ~10% of the fee (the burn slice) and look like
        // the fee shrank.
        uint256 fee = hook.creatorWei(token) + hook.burnWei(token) + hook.teamWei(token) + hook.autocompoundWei(token)
            + hook.creatorOut(token) + hook.teamOut(token, address(usdc));
        assertGt(fee, 0, "dev buy was fee'd");
        assertEq(BodkinERC20(token).balanceOf(address(launcher)), 0, "launcher holds no token");
        // Everything is swept except the create fee booked for the resolver, which waits here for
        // {withdraw} rather than being sent inside the launch.
        assertEq(address(launcher).balance, launcher.createFeesOwed(), "launcher holds only the booked fee");
        vm.prank(team);
        launcher.withdraw();
        assertEq(address(launcher).balance, 0, "launcher fully swept");
    }

    function test_LaunchDefaultsToUsdcPayout() public {
        address token = _launch();
        assertEq(hook.payoutTokenOf(token), address(usdc), "creator fee defaults to USDC");
    }

    function test_LaunchCanOptFeeIntoEthAtLaunch() public {
        vm.prank(creator);
        vm.deal(creator, 1 ether);
        address token = launcher.launch{value: 0.0005 ether}("Eth", "ETH", "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/metadata.json", bytes32(0), address(0), 0, _ethPayout());
        assertEq(hook.payoutTokenOf(token), address(0), "creator opted the fee into ETH at launch");
    }

    /// AUDIT PROBE — migrate() mints the graduated full-range position at the raw, same-tx slot0 with no
    /// price band. The freeze gate reads the PRE-swap tick, so the buy that completes the curve may run
    /// on through the wall and rungs; the attacker then migrates at that displaced price and dumps into
    /// the fresh, thinner full-range book. This measures the attacker's ETH in vs out for three sizes.
    function test_Audit_MigrateAtManipulatedPriceIsNotProfitable() public {
        uint256[3] memory sizes = [uint256(5 ether), 50 ether, 500 ether];
        vm.deal(address(this), 10_000 ether);
        for (uint256 s = 0; s < sizes.length; s++) {
            uint256 outer = vm.snapshotState();
            address token = _launch();
            PoolKey memory key = launcher.poolKeyOf(token);
            PoolSwapTest.TestSettings memory st = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
            (int24 tickLower,,,) = launcher.curvePositions(token);

            // Honest buys up to the LAST step before completion: probe each 0.2 ETH buy on a snapshot and
            // keep it only if the curve is still open afterwards.
            uint256 ethBefore = address(this).balance;
            for (uint256 i = 0; i < 400; i++) {
                uint256 inner = vm.snapshotState();
                swapRouter.swap{value: 0.2 ether}(
                    key, SwapParams({zeroForOne: true, amountSpecified: -0.2 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}), st, ""
                );
                (, int24 t,,) = IPoolManager(address(manager)).getSlot0(key.toId());
                if (t <= tickLower + 60) {
                    vm.revertToState(inner);
                    break;
                }
            }
            // The attack: one buy that completes the curve AND sweeps as far as `sizes[s]` ETH reaches.
            (, int24 tickPre,,) = IPoolManager(address(manager)).getSlot0(key.toId());
            swapRouter.swap{value: sizes[s]}(
                key, SwapParams({zeroForOne: true, amountSpecified: -int256(sizes[s]), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}), st, ""
            );
            (, int24 tickPost,,) = IPoolManager(address(manager)).getSlot0(key.toId());
            uint256 spent = ethBefore - address(this).balance;

            launcher.migrate(token); // at the displaced price, same tx
            uint128 liqAfter = IPoolManager(address(manager)).getLiquidity(key.toId());

            // Dump everything back into the migrated book.
            uint256 bal = BodkinERC20(token).balanceOf(address(this));
            BodkinERC20(token).approve(address(swapRouter), bal);
            uint256 ethMid = address(this).balance;
            swapRouter.swap(
                key, SwapParams({zeroForOne: false, amountSpecified: -int256(bal), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}), st, ""
            );
            uint256 got = address(this).balance - ethMid;
            (, int24 tickEnd,,) = IPoolManager(address(manager)).getSlot0(key.toId());

            console2.log("--- attack size (wei)", sizes[s]);
            console2.log("tick before attack", int256(tickPre));
            console2.log("tick after sweep", int256(tickPost));
            console2.log("tick after dump", int256(tickEnd));
            console2.log("graduation tick (tickLower+60)", int256(tickLower + 60));
            console2.log("ETH spent (all buys) / ETH recovered by dump", spent, got);
            console2.log("pool liquidity after migrate", liqAfter);
            assertLt(got, spent, "the attacker must not come out ahead");
            vm.revertToState(outer);
        }
    }

    receive() external payable {}

    // ---- audit fix order #13/#14 + housekeeping ----

    /// The USDC dev-buy refund must be the delta of THIS launch, never a sweep of the
    /// whole balance: USDC someone mis-sent to the launcher earlier is not the next
    /// creator's to collect. (The ETH branch always had this via `preBal`; this pins
    /// the ERC20 branch to the same rule.)
    function test_UsdcDevBuyRefundDoesNotSweepStrandedUsdc() public {
        uint256 stranded = 777e6;
        usdc.transfer(address(launcher), stranded); // mis-sent long before the launch

        _launchUsdc(50e6);

        assertEq(
            usdc.balanceOf(address(launcher)),
            stranded,
            "the stranded USDC must still be sitting on the launcher"
        );
        // The creator got back only their own unspent numeraire: funded devBuy+1,
        // spent devBuy, so exactly the 1 raw unit of change — not the stranded pile.
        assertEq(usdc.balanceOf(creator), 1, "the creator must not receive a stranger's USDC");
    }

    /// No receive(): ETH sent to the launcher outside launch() has no owner, no sweep
    /// and no refund path — accepting it would burn it forever. Refuse at the door.
    function test_BareEthTransferIsRefused() public {
        vm.deal(address(0xBEEF), 1 ether);
        vm.prank(address(0xBEEF));
        (bool ok,) = address(launcher).call{value: 1 wei}("");
        assertFalse(ok, "a bare ETH transfer must revert, not become an unrecoverable donation");
    }

    // ─── team-wallet 2-of-2 governance ──────────────────────────────────────────────

    /// Produce the off-chain signature one signer makes over the team-wallet payload.
    /// In the sim the two are made independently on separate machines; here two keys.
    function _signTeamUpdate(uint256 pk, address newRecipient, uint256 nonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = launcher.teamWalletUpdateDigest(newRecipient, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// The happy first move: deployer + CURRENT team both sign, either submits.
    function _moveTeamTo(address n) internal {
        uint256 nonce = launcher.teamWalletNonce();
        bytes memory sigDeployer = _signTeamUpdate(ADMIN_PK, n, nonce);
        bytes memory sigTeam = _signTeamUpdate(TEAM_PK, n, nonce);
        vm.prank(deployer);
        launcher.updateTeamWallet(n, sigDeployer, sigTeam);
    }

    /// The headline: a 2-of-2 move re-points BOTH fee streams in one tx — the create fee
    /// (launcher) AND the hook's 20% swap-fee slice, banked amounts included.
    function test_UpdateTeamWallet_MovesBothFeeStreams() public {
        // A USDC launch + a buy, so the team has a real banked USDC slice to follow.
        address token = _launchUsdc(0);
        usdc.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            launcher.poolKeyOf(token),
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(uint256(1_000e6)),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 owed = hook.teamOut(token, address(usdc));
        assertGt(owed, 0, "team has a banked USDC slice before the move");

        // Deployer + CURRENT team sign the SAME payload, independently; either submits.
        uint256 nonce = launcher.teamWalletNonce();
        bytes memory sigDeployer = _signTeamUpdate(ADMIN_PK, newTeam, nonce);
        bytes memory sigTeam = _signTeamUpdate(TEAM_PK, newTeam, nonce);
        vm.prank(feeRecipient); // the team submits this one
        launcher.updateTeamWallet(newTeam, sigDeployer, sigTeam);

        // Both destinations moved, atomically, and the nonce was consumed.
        assertEq(launcher.launchFeeRecipient(), newTeam, "create-fee recipient moved");
        assertEq(hook.team(), newTeam, "hook caught the change: swap-fee slice moved");
        assertEq(launcher.teamWalletNonce(), nonce + 1, "nonce consumed");

        // The banked swap-fee slice is now the NEW team's; the OLD team can't claim it.
        vm.prank(team); // old team wallet
        vm.expectRevert(FeeHook.NotTeam.selector);
        hook.claimTeam(token);

        uint256 beforeUsdc = usdc.balanceOf(newTeam);
        vm.prank(newTeam);
        uint256 paid = hook.claimTeam(token);
        assertEq(paid, owed, "new team claims exactly the banked slice");
        assertEq(usdc.balanceOf(newTeam), beforeUsdc + owed, "swap-fee USDC delivered to the NEW team");
    }

    /// A fresh create fee, after a move, lands on the new team — and never on the old one.
    function test_UpdateResolverWallet_CreateFeeFollows() public {
        _launch(); 
    }

    // ─── ETH launch pricing (2-of-2) ────────────────────────────────────────────────

    function _signEthConfig(uint256 pk, uint256 fdv, uint256 target, uint256 nonce)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, launcher.ethConfigUpdateDigest(fdv, target, nonce));
        return abi.encodePacked(r, s, v);
    }

    /// Both signers sign, either submits; the numbers change for FUTURE launches and the nonce is consumed.
    function test_UpdateEthConfig_Requires2of2() public {
        uint256 fdv = 7 ether;
        uint256 target = 20 ether;
        uint256 nonce = launcher.ethConfigNonce();
        bytes memory sigDeployer = _signEthConfig(ADMIN_PK, fdv, target, nonce);
        bytes memory sigTeam = _signEthConfig(TEAM_PK, fdv, target, nonce);

        // One key alone — even a signer submitting — is refused: the other leg is missing.
        vm.prank(deployer);
        vm.expectRevert(bytes("Launcher: bad team sig"));
        launcher.updateEthConfig(fdv, target, sigDeployer, sigDeployer);
        vm.prank(team);
        vm.expectRevert(bytes("Launcher: bad deployer sig"));
        launcher.updateEthConfig(fdv, target, sigTeam, sigTeam);
        // Valid pair, stranger submits.
        vm.prank(creator);
        vm.expectRevert(bytes("Launcher: not a signer"));
        launcher.updateEthConfig(fdv, target, sigDeployer, sigTeam);

        vm.prank(team);
        launcher.updateEthConfig(fdv, target, sigDeployer, sigTeam);
        assertEq(launcher.startFdvOf(address(0)), fdv, "ETH start fdv re-set");
        assertEq(launcher.migrationTargetOf(address(0)), target, "ETH migration target re-set");
        assertEq(launcher.ethConfigNonce(), nonce + 1, "nonce consumed");

        // Replay of the same pair fails.
        vm.prank(deployer);
        vm.expectRevert(bytes("Launcher: bad deployer sig"));
        launcher.updateEthConfig(fdv, target, sigDeployer, sigTeam);
    }

    /// The bounds still hold under the 2-of-2: the target must exceed the start.
    function test_UpdateEthConfig_RejectsCollapsedCurve() public {
        uint256 nonce = launcher.ethConfigNonce();
        bytes memory sigDeployer = _signEthConfig(ADMIN_PK, 5 ether, 5 ether, nonce);
        bytes memory sigTeam = _signEthConfig(TEAM_PK, 5 ether, 5 ether, nonce);
        vm.prank(deployer);
        vm.expectRevert(bytes("Launcher: target must exceed fdv"));
        launcher.updateEthConfig(5 ether, 5 ether, sigDeployer, sigTeam);
    }

    // ─── deployer rotation (2-of-2) ─────────────────────────────────────────────────

    function _signDeployerUpdate(uint256 pk, address newDeployer, uint256 nonce) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, launcher.deployerUpdateDigest(newDeployer, nonce));
        return abi.encodePacked(r, s, v);
    }

    /// Team + current deployer rotate the deployer; afterwards only the NEW key co-signs.
    function test_UpdateDeployer_RotatesSigner() public {
        uint256 newPk = 0xD00D;
        address newDeployer = vm.addr(newPk);
        uint256 nonce = launcher.deployerNonce();
        bytes memory sigDeployer = _signDeployerUpdate(ADMIN_PK, newDeployer, nonce);
        bytes memory sigTeam = _signDeployerUpdate(TEAM_PK, newDeployer, nonce);

        vm.prank(creator);
        vm.expectRevert(bytes("Launcher: not a signer"));
        launcher.updateDeployer(newDeployer, sigDeployer, sigTeam);
        vm.prank(deployer);
        vm.expectRevert(bytes("Launcher: bad team sig"));
        launcher.updateDeployer(newDeployer, sigDeployer, sigDeployer);

        vm.prank(deployer);
        launcher.updateDeployer(newDeployer, sigDeployer, sigTeam);
        assertEq(launcher.deployer(), newDeployer, "deployer rotated");
        assertEq(launcher.deployerNonce(), nonce + 1, "nonce consumed");

        // The OLD key is out: its signature no longer authorises a team-wallet move …
        uint256 tn = launcher.teamWalletNonce();
        bytes memory oldSig = _signTeamUpdate(ADMIN_PK, newTeam, tn);
        bytes memory teamSig = _signTeamUpdate(TEAM_PK, newTeam, tn);
        vm.prank(team);
        vm.expectRevert(bytes("Launcher: bad deployer sig"));
        launcher.updateTeamWallet(newTeam, oldSig, teamSig);
        // … and the old key can no longer even submit.
        vm.prank(deployer);
        vm.expectRevert(bytes("Launcher: not a signer"));
        launcher.updateTeamWallet(newTeam, oldSig, teamSig);
        // The NEW key co-signs as usual.
        bytes memory newSig = _signTeamUpdate(newPk, newTeam, tn);
        vm.prank(newDeployer);
        launcher.updateTeamWallet(newTeam, newSig, teamSig);
        assertEq(launcher.launchFeeRecipient(), newTeam, "team wallet moved with the rotated deployer");
    }

    /// The deployer may never become the team wallet (1-of-1), nor zero.
    function test_UpdateDeployer_RejectsTeamAndZero() public {
        uint256 nonce = launcher.deployerNonce();
        bytes memory a = _signDeployerUpdate(ADMIN_PK, team, nonce);
        bytes memory b = _signDeployerUpdate(TEAM_PK, team, nonce);
        vm.prank(deployer);
        vm.expectRevert(bytes("Launcher: bad deployer"));
        launcher.updateDeployer(team, a, b);
        vm.prank(deployer);
        vm.expectRevert(bytes("Launcher: bad deployer"));
        launcher.updateDeployer(address(0), a, b);
    }

    /// One key signing both legs is not a 2-of-2.
    function test_UpdateTeamWallet_RejectsSingleSigner() public {
        uint256 nonce = launcher.teamWalletNonce();
        bytes memory sigDeployer = _signTeamUpdate(ADMIN_PK, newTeam, nonce);
        vm.prank(deployer);
        vm.expectRevert(bytes("Launcher: bad team sig"));
        launcher.updateTeamWallet(newTeam, sigDeployer, sigDeployer); // team leg is the deployer's sig
    }

    /// Valid signatures, but a stranger tries to submit them.
    function test_UpdateTeamWallet_RejectsNonSignerCaller() public {
        uint256 nonce = launcher.teamWalletNonce();
        bytes memory sigDeployer = _signTeamUpdate(ADMIN_PK, newTeam, nonce);
        bytes memory sigTeam = _signTeamUpdate(TEAM_PK, newTeam, nonce);
        vm.prank(creator); // neither signer
        vm.expectRevert(bytes("Launcher: not a signer"));
        launcher.updateTeamWallet(newTeam, sigDeployer, sigTeam);
    }

    /// The nonce bump kills the old signatures — no replay.
    function test_UpdateTeamWallet_RejectsReplay() public {
        uint256 nonce = launcher.teamWalletNonce();
        bytes memory sigDeployer = _signTeamUpdate(ADMIN_PK, newTeam, nonce);
        bytes memory sigTeam = _signTeamUpdate(TEAM_PK, newTeam, nonce);
        vm.prank(deployer);
        launcher.updateTeamWallet(newTeam, sigDeployer, sigTeam);
        // Replaying the same two signatures fails: the nonce advanced, so the digest they
        // signed no longer matches what the contract reconstructs.
        vm.prank(deployer);
        vm.expectRevert(bytes("Launcher: bad deployer sig"));
        launcher.updateTeamWallet(newTeam, sigDeployer, sigTeam);
    }

    /// The new recipient may not be the admin — that would collapse the 2-of-2 to a 1-of-1.
    function test_UpdateTeamWallet_RejectsRecipientEqualsAdmin() public {
        uint256 nonce = launcher.teamWalletNonce();
        bytes memory sigDeployer = _signTeamUpdate(ADMIN_PK, deployer, nonce);
        bytes memory sigTeam = _signTeamUpdate(TEAM_PK, deployer, nonce);
        vm.prank(deployer);
        vm.expectRevert(bytes("Launcher: bad recipient"));
        launcher.updateTeamWallet(deployer, sigDeployer, sigTeam);
    }

    // --- team PAYOUT TOKEN 2-of-2 (mirror of the wallet move) -----------------

    function _signPayoutUpdate(uint256 pk, address newToken, uint256 nonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = launcher.teamPayoutTokenUpdateDigest(newToken, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _flipPayoutTo(address newToken) internal {
        uint256 nonce = launcher.teamPayoutTokenNonce();
        bytes memory sigDeployer = _signPayoutUpdate(ADMIN_PK, newToken, nonce);
        bytes memory sigTeam = _signPayoutUpdate(TEAM_PK, newToken, nonce);
        vm.prank(deployer);
        launcher.updateTeamPayoutToken(newToken, sigDeployer, sigTeam);
    }

    /// Happy path: with nothing banked, the 2-of-2 flips the team payout USDC -> native ETH.
    function test_UpdateTeamPayoutToken_FlipsUsdcToEth() public {
        assertEq(hook.teamPayoutToken(), address(usdc), "starts as USDC");
        _flipPayoutTo(address(0)); // native ETH is always allowed
        assertEq(hook.teamPayoutToken(), address(0), "team now paid in ETH");
        assertEq(launcher.teamPayoutTokenNonce(), 1, "nonce consumed");
    }

    /// Per-currency banking removes the old drain-first guard: the payout token flips FREELY while
    /// fees are banked, and the OLD currency stays keyed to itself and fully claimable after the flip
    /// — nothing strands. (This is the invariant that makes a USDC migration safe.)
    function test_UpdateTeamPayoutToken_FlipsWhileBanked_OldCurrencyStillClaimable() public {
        address token = _launchUsdc(0);
        usdc.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            launcher.poolKeyOf(token),
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(uint256(1_000e6)),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 bankedUsdc = hook.teamOut(token, address(usdc));
        assertGt(bankedUsdc, 0, "a converted USDC slice is banked");

        // Flip the payout token to ETH WHILE the USDC slice is banked — no drain-first guard anymore.
        _flipPayoutTo(address(0));
        assertEq(hook.teamPayoutToken(), address(0), "flip allowed while banked");
        // The old USDC slice is untouched and still keyed to USDC (not re-denominated, not stranded).
        assertEq(hook.teamOut(token, address(usdc)), bankedUsdc, "old USDC slice intact after the flip");

        // The team claims and receives it IN USDC — the multi-currency claim reaches the old currency.
        uint256 before = usdc.balanceOf(team);
        vm.prank(team);
        hook.claimTeam(token);
        assertEq(usdc.balanceOf(team), before + bankedUsdc, "old USDC slice delivered in USDC after the flip");
        assertEq(hook.teamOut(token, address(usdc)), 0, "drained");
    }

    /// Only ETH and admin-allowed tokens can be chosen — future-proofing a USDC migration: the
    /// admin adds the new contract address, then the 2-of-2 may switch the team to it.
    function test_UpdateTeamPayoutToken_AllowlistGate() public {
        address migratedUsdc = makeAddr("migratedUsdc");
        uint256 nonce = launcher.teamPayoutTokenNonce();
        bytes memory sigDeployer = _signPayoutUpdate(ADMIN_PK, migratedUsdc, nonce);
        bytes memory sigTeam = _signPayoutUpdate(TEAM_PK, migratedUsdc, nonce);
        vm.prank(deployer);
        vm.expectRevert(bytes("FeeHook: team token not allowed"));
        launcher.updateTeamPayoutToken(migratedUsdc, sigDeployer, sigTeam);

        // Admin allows the migrated USDC (its remaining chain-config role); then the flip works.
        vm.prank(hook.deployer());
        hook.setTeamPayoutAllowed(migratedUsdc, true);
        _flipPayoutTo(migratedUsdc);
        assertEq(hook.teamPayoutToken(), migratedUsdc, "switched to the migrated USDC");
    }

    /// The 2-of-2 discipline carries over: single signer, non-signer submit, and replay all fail.
    function test_UpdateTeamPayoutToken_RejectsSingleSignerNonSignerAndReplay() public {
        uint256 nonce = launcher.teamPayoutTokenNonce();
        bytes memory sigDeployer = _signPayoutUpdate(ADMIN_PK, address(0), nonce);
        vm.prank(deployer);
        vm.expectRevert(bytes("Launcher: bad team sig"));
        launcher.updateTeamPayoutToken(address(0), sigDeployer, sigDeployer); // team leg is deployer's sig

        bytes memory sigTeam = _signPayoutUpdate(TEAM_PK, address(0), nonce);
        vm.prank(creator); // neither signer submits
        vm.expectRevert(bytes("Launcher: not a signer"));
        launcher.updateTeamPayoutToken(address(0), sigDeployer, sigTeam);

        vm.prank(deployer);
        launcher.updateTeamPayoutToken(address(0), sigDeployer, sigTeam); // consumes the nonce
        vm.prank(deployer);
        vm.expectRevert(bytes("Launcher: bad deployer sig"));
        launcher.updateTeamPayoutToken(address(0), sigDeployer, sigTeam); // replay now fails
    }

    /// After a move, the SECOND signer is the new team — the old team can no longer sign.
    function test_UpdateTeamWallet_NewTeamBecomesSigner() public {
        _moveTeamTo(newTeam);
        address third = makeAddr("thirdTeam");
        uint256 nonce = launcher.teamWalletNonce();
        bytes memory sigDeployer = _signTeamUpdate(ADMIN_PK, third, nonce);

        // The OLD team's key is now powerless.
        bytes memory sigOldTeam = _signTeamUpdate(TEAM_PK, third, nonce);
        vm.prank(deployer);
        vm.expectRevert(bytes("Launcher: bad team sig"));
        launcher.updateTeamWallet(third, sigDeployer, sigOldTeam);

        // The current (new) team's key works.
        bytes memory sigNewTeam = _signTeamUpdate(NEW_TEAM_PK, third, nonce);
        vm.prank(newTeam);
        launcher.updateTeamWallet(third, sigDeployer, sigNewTeam);
        assertEq(launcher.launchFeeRecipient(), third, "moved again, with the new team's consent");
        assertEq(hook.team(), third, "hook followed the second move");
    }

    /// A launcher whose two signers are the same key is not a real 2-of-2 — refuse it.
    function test_ConstructorRejectsEqualSigners() public {
        LauncherV1.StartFdv[] memory fdvs = new LauncherV1.StartFdv[](1);
        fdvs[0] = LauncherV1.StartFdv({numeraire: address(0), fdvRaw: 1 ether, migrationTargetRaw: 15789e15});
        // Hoist the external read so expectRevert attaches to the `new`, not to it.
        address impl2 = launcher.launchTokenImpl();
        vm.expectRevert(bytes("Launcher: signers equal"));
        new LauncherV1(
            IPoolManager(address(manager)), IHooks(address(hook)), creatorNFT, impl2, deployer, deployer, deployer, fdvs
        );
    }

    // ─── addPositionManager: the 2-of-2, add-only LP-claim list on the hook ───────────────────────

    function _signPmAdd(uint256 pk, address pm, uint256 nonce) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, launcher.positionManagerAddDigest(pm, nonce));
        return abi.encodePacked(r, s, v);
    }

    /// Happy path: both signers authorise, the hook lists the PositionManager, the nonce is consumed and
    /// the same pair can never be replayed (for the same or another address).
    function test_AddPositionManager_TwoOfTwoListsIt() public {
        address pm = address(new StubPositionManager(IPoolManager(address(manager))));
        uint256 nonce = launcher.positionManagerNonce();
        bytes memory sigDeployer = _signPmAdd(ADMIN_PK, pm, nonce);
        bytes memory sigTeam = _signPmAdd(TEAM_PK, pm, nonce);
        vm.prank(team);
        launcher.addPositionManager(pm, sigDeployer, sigTeam);
        assertTrue(hook.isPositionManager(pm), "listed on the hook");
        assertEq(launcher.positionManagerNonce(), nonce + 1, "nonce consumed");

        address pm2 = address(new StubPositionManager(IPoolManager(address(manager))));
        vm.prank(deployer);
        vm.expectRevert(bytes("Launcher: bad deployer sig"));
        launcher.addPositionManager(pm2, sigDeployer, sigTeam);
    }

    /// One signer is not enough, a non-signer cannot submit, and the hook's own checks still apply
    /// behind a valid pair (a contract bound to another PoolManager is refused; nonce kept).
    function test_AddPositionManager_RefusesSingleSignerNonSignerAndForeignPm() public {
        address pm = address(new StubPositionManager(IPoolManager(address(manager))));
        uint256 nonce = launcher.positionManagerNonce();
        bytes memory sigDeployer = _signPmAdd(ADMIN_PK, pm, nonce);
        vm.prank(deployer);
        vm.expectRevert(bytes("Launcher: bad team sig"));
        launcher.addPositionManager(pm, sigDeployer, sigDeployer);

        bytes memory sigTeam = _signPmAdd(TEAM_PK, pm, nonce);
        vm.prank(creator);
        vm.expectRevert(bytes("Launcher: not a signer"));
        launcher.addPositionManager(pm, sigDeployer, sigTeam);

        address foreign = address(new StubPositionManager(IPoolManager(address(0xF0E))));
        bytes memory fd = _signPmAdd(ADMIN_PK, foreign, nonce);
        bytes memory ft = _signPmAdd(TEAM_PK, foreign, nonce);
        vm.prank(deployer);
        vm.expectRevert(FeeHook.BadPositionManager.selector);
        launcher.addPositionManager(foreign, fd, ft);
        assertEq(launcher.positionManagerNonce(), nonce, "nonce preserved (whole tx rolled back)");
        assertFalse(hook.isPositionManager(foreign));
    }

    // ─── updateFeeToken: the shared 2-of-2 re-point of a fee-infra address (weth/usdc) ───────────

    function _signFeeTokenUpdate(uint256 pk, uint8 which, address newAddr, uint256 nonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = launcher.feeTokenUpdateDigest(which, newAddr, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// Happy path: the 2-of-2 re-points WETH on the hook (the emergency escape hatch for a deprecated
    /// WETH), and the launcher-only hook setter followed the launcher's authorisation.
    function test_UpdateFeeToken_RepointsWeth() public {
        uint8 wethSel = hook.FEE_TOKEN_WETH();
        assertEq(hook.weth(), address(0), "weth starts disabled in this suite");
        address newWeth = address(new MockWETH()); // real 18-decimal token: passes coin validation

        uint256 nonce = launcher.feeTokenNonce();
        bytes memory sigDeployer = _signFeeTokenUpdate(ADMIN_PK, wethSel, newWeth, nonce);
        bytes memory sigTeam = _signFeeTokenUpdate(TEAM_PK, wethSel, newWeth, nonce);
        vm.prank(deployer);
        launcher.updateFeeToken(wethSel, newWeth, sigDeployer, sigTeam);

        assertEq(hook.weth(), newWeth, "weth re-pointed via the 2-of-2");
        assertEq(launcher.feeTokenNonce(), 1, "nonce consumed");

        // Repeatable: the SAME governance can re-point it again (fresh nonce).
        address newerWeth = address(new MockWETH());
        nonce = launcher.feeTokenNonce();
        sigDeployer = _signFeeTokenUpdate(ADMIN_PK, wethSel, newerWeth, nonce);
        sigTeam = _signFeeTokenUpdate(TEAM_PK, wethSel, newerWeth, nonce);
        vm.prank(team);
        launcher.updateFeeToken(wethSel, newerWeth, sigDeployer, sigTeam);
        assertEq(hook.weth(), newerWeth, "weth re-pointed a second time");
        assertEq(launcher.feeTokenNonce(), 2, "second nonce consumed");
    }

    /// The generic address-only selector REFUSES USDC: a bare re-point would leave usdc half-migrated
    /// (its (ETH,usdc) pool and launcher FDV unmoved), so the hook reverts and points at the dedicated
    /// {updateUsdc} path. Even with two VALID signatures usdc stays put and the nonce is NOT consumed.
    function test_UpdateFeeToken_UsdcRejected_UsesDedicatedPath() public {
        uint8 usdcSel = hook.FEE_TOKEN_USDC();
        address migratedUsdc = makeAddr("migratedUsdc");
        uint256 nonce = launcher.feeTokenNonce();
        bytes memory sigDeployer = _signFeeTokenUpdate(ADMIN_PK, usdcSel, migratedUsdc, nonce);
        bytes memory sigTeam = _signFeeTokenUpdate(TEAM_PK, usdcSel, migratedUsdc, nonce);

        vm.prank(deployer);
        vm.expectRevert(FeeHook.UsdcUsesDedicatedPath.selector);
        launcher.updateFeeToken(usdcSel, migratedUsdc, sigDeployer, sigTeam);

        assertEq(hook.usdc(), address(usdc), "usdc unchanged");
        assertEq(launcher.feeTokenNonce(), nonce, "nonce preserved (whole tx rolled back)");
    }

    /// The full 2-of-2 discipline: bad signer leg, non-signer submitter, and replay all fail; a
    /// signature bound to WETH can't be replayed for a different address or after a successful move.
    function test_UpdateFeeToken_RejectsSingleSignerNonSignerAndReplay() public {
        uint8 wethSel = hook.FEE_TOKEN_WETH();
        address a = address(new MockWETH()); // the valid-pair leg re-points weth to it, so it must pass validation
        uint256 nonce = launcher.feeTokenNonce();
        bytes memory sigDeployer = _signFeeTokenUpdate(ADMIN_PK, wethSel, a, nonce);

        // Team leg is actually the deployer's signature → bad team sig.
        vm.prank(deployer);
        vm.expectRevert(bytes("Launcher: bad team sig"));
        launcher.updateFeeToken(wethSel, a, sigDeployer, sigDeployer);

        bytes memory sigTeam = _signFeeTokenUpdate(TEAM_PK, wethSel, a, nonce);
        // A non-signer cannot even submit a valid pair.
        vm.prank(creator);
        vm.expectRevert(bytes("Launcher: not a signer"));
        launcher.updateFeeToken(wethSel, a, sigDeployer, sigTeam);

        // Valid pair consumes the nonce...
        vm.prank(deployer);
        launcher.updateFeeToken(wethSel, a, sigDeployer, sigTeam);
        assertEq(hook.weth(), a, "re-pointed");
        // ...so the very same signatures can never be replayed.
        vm.prank(deployer);
        vm.expectRevert(bytes("Launcher: bad deployer sig"));
        launcher.updateFeeToken(wethSel, a, sigDeployer, sigTeam);
    }

    /// The re-point shares the team-wallet signer: after the team wallet moves, the OLD team key can
    /// no longer authorise a fee-token change; the NEW team's key does.
    function test_UpdateFeeToken_NewTeamBecomesSigner() public {
        _moveTeamTo(newTeam);
        uint8 wethSel = hook.FEE_TOKEN_WETH();
        address w = address(new MockWETH());
        uint256 nonce = launcher.feeTokenNonce();
        bytes memory sigDeployer = _signFeeTokenUpdate(ADMIN_PK, wethSel, w, nonce);

        // The old team's key is powerless now.
        bytes memory sigOldTeam = _signFeeTokenUpdate(TEAM_PK, wethSel, w, nonce);
        vm.prank(deployer);
        vm.expectRevert(bytes("Launcher: bad team sig"));
        launcher.updateFeeToken(wethSel, w, sigDeployer, sigOldTeam);

        // The current (new) team's key works.
        bytes memory sigNewTeam = _signFeeTokenUpdate(NEW_TEAM_PK, wethSel, w, nonce);
        vm.prank(newTeam);
        launcher.updateFeeToken(wethSel, w, sigDeployer, sigNewTeam);
        assertEq(hook.weth(), w, "re-pointed with the new team's consent");
    }

    // ─── updateUsdc: the 2-of-2 re-point of the fee hook's USDC (old-token fee support) ───────────
    // Deliberately does NOT touch the launcher's startFdvOf — launching NEW USDC-quoted tokens against
    // a migrated USDC is done by deploying a fresh launcher, not by mutating this one.

    uint160 constant SQRT_1_1 = 79228162514264337593543950336; // price 1.0 (2**96)

    function _initEthUsdcPool(address coin, uint24 fee) internal returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(coin),
            fee: fee,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        manager.initialize(key, SQRT_1_1);
    }

    function _signUsdcUpdate(uint256 pk, address newUsdc, PoolKey memory pool, uint256 nonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = launcher.usdcUpdateDigest(newUsdc, pool, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// Happy path: ONE 2-of-2 action moves everything USDC is load-bearing in FOR FEE ROUTING — the
    /// hook's usdc address + conversion pool + team payout token + allow-list/registry. It leaves the
    /// launcher's startFdvOf UNTOUCHED (new USDC launches use a fresh launcher).
    function test_UpdateUsdc_MovesFeeRoutingAtomically() public {
        MockUSDC newUsdc = new MockUSDC();
        PoolKey memory pool = _initEthUsdcPool(address(newUsdc), 3000);

        assertEq(hook.usdc(), address(usdc), "old usdc before");
        assertEq(hook.teamPayoutToken(), address(usdc), "team paid in old usdc before");

        uint256 nonce = launcher.usdcNonce();
        bytes memory sa = _signUsdcUpdate(ADMIN_PK, address(newUsdc), pool, nonce);
        bytes memory st = _signUsdcUpdate(TEAM_PK, address(newUsdc), pool, nonce);
        vm.prank(deployer);
        launcher.updateUsdc(address(newUsdc), pool, sa, st);

        assertEq(hook.usdc(), address(newUsdc), "usdc re-pointed");
        assertEq(Currency.unwrap(hook.usdcPool().currency1), address(newUsdc), "conversion pool re-wired");
        assertEq(hook.teamPayoutToken(), address(newUsdc), "team payout swung to the new usdc");
        assertTrue(hook.teamPayoutAllowed(address(newUsdc)), "new usdc allowed as a team payout token");
        assertTrue(hook.teamCurrencyKnown(address(newUsdc)), "new usdc registered for the multi-currency claim");
        assertEq(launcher.startFdvOf(address(newUsdc)), 0, "launcher FDV deliberately NOT set (use a new launcher)");
        assertEq(launcher.usdcNonce(), 1, "nonce consumed");
    }

    /// The 2-of-2 discipline: bad signer leg, non-signer submitter, and replay all fail; a valid pair
    /// consumes the single-use nonce.
    function test_UpdateUsdc_RejectsBadSigNonSignerAndReplay() public {
        MockUSDC newUsdc = new MockUSDC();
        PoolKey memory pool = _initEthUsdcPool(address(newUsdc), 3000);
        uint256 nonce = launcher.usdcNonce();
        bytes memory sa = _signUsdcUpdate(ADMIN_PK, address(newUsdc), pool, nonce);
        bytes memory st = _signUsdcUpdate(TEAM_PK, address(newUsdc), pool, nonce);

        // Team leg is actually the deployer's signature.
        vm.prank(deployer);
        vm.expectRevert(bytes("Launcher: bad team sig"));
        launcher.updateUsdc(address(newUsdc), pool, sa, sa);

        // A non-signer cannot submit a valid pair.
        vm.prank(creator);
        vm.expectRevert(bytes("Launcher: not a signer"));
        launcher.updateUsdc(address(newUsdc), pool, sa, st);

        // Valid pair consumes the nonce...
        vm.prank(team);
        launcher.updateUsdc(address(newUsdc), pool, sa, st);
        assertEq(hook.usdc(), address(newUsdc), "migrated");
        // ...so the same signatures can never be replayed.
        vm.prank(deployer);
        vm.expectRevert(bytes("Launcher: bad deployer sig"));
        launcher.updateUsdc(address(newUsdc), pool, sa, st);
    }

    /// The re-point shares the team-wallet signer: after the team wallet moves, only the NEW team key
    /// can co-authorise a USDC re-point.
    function test_UpdateUsdc_NewTeamBecomesSigner() public {
        _moveTeamTo(newTeam);
        MockUSDC newUsdc = new MockUSDC();
        PoolKey memory pool = _initEthUsdcPool(address(newUsdc), 3000);
        uint256 nonce = launcher.usdcNonce();
        bytes memory sa = _signUsdcUpdate(ADMIN_PK, address(newUsdc), pool, nonce);

        // The old team key is powerless now.
        bytes memory stOld = _signUsdcUpdate(TEAM_PK, address(newUsdc), pool, nonce);
        vm.prank(deployer);
        vm.expectRevert(bytes("Launcher: bad team sig"));
        launcher.updateUsdc(address(newUsdc), pool, sa, stOld);

        // The current (new) team key works.
        bytes memory stNew = _signUsdcUpdate(NEW_TEAM_PK, address(newUsdc), pool, nonce);
        vm.prank(newTeam);
        launcher.updateUsdc(address(newUsdc), pool, sa, stNew);
        assertEq(hook.usdc(), address(newUsdc), "migrated with the new team's consent");
    }
}
