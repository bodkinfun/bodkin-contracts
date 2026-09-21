// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {DeployV1} from "../../script/DeployV1.s.sol";
import {FeeHook} from "../../src/launchpad/v1/FeeHook.sol";
import {LauncherV1} from "../../src/launchpad/v1/LauncherV1.sol";
import {CreatorNFT} from "../../src/launchpad/CreatorNFT.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";

/// @notice The PRODUCTION deploy (script/DeployV1.s.sol) must, against a canonical Uniswap V4
///         PoolManager + a real USDC + an existing (ETH, USDC) pool, wire the whole launchpad,
///         launch $BODKIN as NFT #0, and renounce — exactly like the local deploy, but env-driven
///         and pointed at pre-existing infrastructure. This runs that same operator code path.
/// Stands in for a PositionManager on a faked real-network chain id: the deploy checks which PoolManager
/// it is bound to.
contract StubPositionManager {
    address public poolManager;

    constructor(address m) {
        poolManager = m;
    }
}

contract DeployV1Test is Test, DeployV1 {
    using StateLibrary for IPoolManager;
    /// (ETH 18-dec = currency0, USDC 6-dec = currency1) at ~$3,000/ETH — same convention as the
    /// local deploy so USD figures read realistically.
    uint160 internal constant SQRT_PRICE_ETH_USDC = 3453475538820956156228900;
    uint256 internal constant DEPLOYER_PK = 0xD1E; // arbitrary test key
    address internal constant TEAM = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address internal constant RESOLVER = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    /// Any non-zero address: the hook only stores it (WETH-paired payouts are not exercised here).
    address internal constant WETH_STUB = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    PoolManager internal manager;
    MockUSDC internal usdc;
    address internal deployer;

    /// The PoolManager refunds excess native ETH after modifyLiquidity — this contract seeds the
    /// stand-in ETH/USDC pool, so it must be able to receive that refund.
    receive() external payable {}

    function setUp() public {
        deployer = vm.addr(DEPLOYER_PK);
        vm.deal(address(this), 1_000 ether); // to seed the stand-in ETH/USDC pool below

        // 1. Stand in for the chain's CANONICAL infrastructure: a V4 PoolManager + real USDC.
        manager = new PoolManager(address(this));
        usdc = new MockUSDC(1e30);

        // 2. An already-existing (native-ETH, USDC) pool at the 500/10 tier, seeded so fee
        //    conversions have depth — this is what a canonical chain already has, and what the
        //    deploy should WIRE (not re-create).
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        PoolKey memory usdcKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(usdc)),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });
        manager.initialize(usdcKey, SQRT_PRICE_ETH_USDC);
        usdc.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity{value: 150 ether}(
            usdcKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(10),
                tickUpper: TickMath.maxUsableTick(10),
                liquidityDelta: 5e15,
                salt: 0
            }),
            ""
        );

        // 3. Fund the deployer with ETH for the launch fee + dev buy + gas.
        vm.deal(deployer, 100 ether);

        // 4. The operator config, exactly as it would come from .env.
        _set("PRIVATE_KEY", vm.toString(bytes32(DEPLOYER_PK)));
        _set("POOL_MANAGER", vm.toString(address(manager)));
        _set("USDC", vm.toString(address(usdc)));
        _set("TEAM_WALLET", vm.toString(TEAM));
        _set("DEPLOYER_WALLET", vm.toString(deployer)); // co-signer; distinct from TEAM
        _set("RESOLVER_WALLET", vm.toString(RESOLVER));
        _set("WETH", vm.toString(WETH_STUB));
        _set("USDC_DEPLOY_MOCK", "false");
        _set("USDC_POOL_SEED", "false");
        _set("USDC_POOL_LIQUIDITY", "0");
        _set("USDC_POOL_FEE", "500");
        _set("USDC_POOL_TICK_SPACING", "10");
        _set("BODKIN_METADATA_URI", "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/metadata.json");
        // Pin the salt so these tests do not shell out to the vanity miner on every deploy(). The
        // mining path itself is covered by test_MinesTheVanitySaltWhenNoneIsPinned below.
        _set("BODKIN_SALT", "0x00000000000000000000000000000000000000000000000000000000000000b0");
        _set("BODKIN_DEV_BUY", "1000000000000000"); // 0.001 ETH
    }

    function test_DeployWiresEverythingAndRenounces() public {
        deploy();

        FeeHook hook = FeeHook(payable(ex.feeHook));
        // Wiring survived.
        assertEq(hook.launcher(), ex.launcher, "hook lost its launcher");
        assertEq(CreatorNFT(ex.creatorNFT).launchpad(), ex.launcher, "NFT lost its launchpad");
        assertTrue(ex.usdcPoolId != bytes32(0), "USDC conversion pool never wired");
        // The wired tier is exported for the frontend's bridge hop (no guessing a fallback tier).
        assertEq(uint256(ex.usdcPoolFee), 500, "usdc pool fee exported");
        assertEq(int256(ex.usdcPoolTickSpacing), int256(10), "usdc pool tick spacing exported");
        assertEq(ex.poolManager, address(manager), "must use the canonical PoolManager, not a fresh one");
        assertEq(ex.usdc, address(usdc), "wrong USDC");
        assertEq(ex.team, TEAM, "wrong team wallet");
        assertEq(ex.weth, WETH_STUB, "WETH must be exported for the frontend/indexer");
        assertEq(LauncherV1(payable(ex.launcher)).resolverWallet(), RESOLVER, "resolver wallet not recorded");

        // No admin remains.
        assertEq(hook.owner(), address(0), "FeeHook still has an owner");
        assertEq(CreatorNFT(ex.creatorNFT).owner(), address(0), "CreatorNFT still has an owner");

        // BODKIN is a real launch and holds creator NFT #0.
        assertTrue(ex.bodkin != address(0), "BODKIN not launched");
        assertEq(CreatorNFT(ex.creatorNFT).nftOf(ex.bodkin), 0, "BODKIN must hold creator NFT #0");
        assertEq(CreatorNFT(ex.creatorNFT).creatorOf(ex.bodkin), TEAM, "BODKIN fee stream (NFT #0) to the team wallet");
        // Booked, not sent — a launch never runs anyone else's code — and the team withdraws it after.
        assertEq(TEAM.balance, 0, "nothing is sent during the launch");
        assertEq(RESOLVER.balance, 0, "and the resolver is not paid from inside it either");
        assertEq(LauncherV1(payable(ex.launcher)).createFeesOwed(), 0.0005 ether, "the fee is booked");
        vm.prank(TEAM);
        LauncherV1(payable(ex.launcher)).withdraw();
        assertEq(TEAM.balance, 0.0005 ether, "and the team wallet withdrew it");
    }

    /// Every coin created through the site is launched under a salt mined so its address ends in the
    /// platform suffix; the production BODKIN used to be the one coin that was not. With no salt pinned,
    /// the deploy mines one the same way — off-chain, through the same script the site uses — and the
    /// address it produces carries the suffix. The salt is exported so the post-deploy verification can
    /// recompute the address rather than trusting the file's own `bodkin` field.
    function test_MinesTheVanitySaltWhenNoneIsPinned() public {
        _set("BODKIN_SALT", "");
        deploy();

        assertTrue(ex.bodkinSalt != bytes32(0), "a salt was mined and exported");
        string memory addr = vm.toLowercase(vm.toString(ex.bodkin));
        bytes memory b = bytes(addr);
        bytes memory tail = new bytes(5);
        for (uint256 i = 0; i < 5; i++) tail[i] = b[b.length - 5 + i];
        assertEq(string(tail), "b0d41", "BODKIN carries the platform vanity suffix");
    }

    function test_AdminSettersRevertAfterDeploy() public {
        deploy();
        FeeHook hook = FeeHook(payable(ex.feeHook));
        // Even the deployer — who held the key a moment ago — is locked out.
        vm.prank(deployer);
        vm.expectRevert(FeeHook.NotOwner.selector);
        hook.setLauncher(address(0xBEEF));
    }

    function test_DeployerDerivedFromMnemonicAlso() public {
        // The other supported key source: a mnemonic (index 0) instead of PRIVATE_KEY. Point the
        // config at a mnemonic-derived deployer, fund it, and the deploy runs the same.
        string memory mnemonic = "test test test test test test test test test test test junk";
        address mnemonicDeployer = vm.addr(vm.deriveKey(mnemonic, 0));
        vm.deal(mnemonicDeployer, 100 ether);
        _set("PRIVATE_KEY", ""); // force the mnemonic branch
        _set("MNEMONIC", mnemonic);
        _set("DEPLOYER_WALLET", vm.toString(mnemonicDeployer));

        deploy();

        assertEq(ex.deployer, mnemonicDeployer, "deployer must come from the mnemonic");
        assertEq(FeeHook(payable(ex.feeHook)).owner(), address(0), "still renounced");
    }

    /// TESTNET path: no dollar token worth trusting and no (ETH, USDC) pool — the deploy mints its own
    /// mock and seeds the pool from the ETH leg alone (USDC_POOL_LIQUIDITY unset → derived).
    function test_TestnetMockUsdc_SeedsPoolWithDerivedLiquidity() public {
        vm.chainId(46630);
        // Mine a real salt here rather than using setUp's placeholder: on a real chain id the deploy
        // REQUIRES BODKIN to carry the b0d41 suffix, which is the invariant these tests are standing in
        // for. Cheap now that the miner runs across the cores.
        _set("BODKIN_SALT", "");
        vm.etch(WETH_STUB, hex"00"); // a real network's WETH has code (the deploy refuses one that doesn't)
        _set("USDC_DEPLOY_MOCK", "true");
        _set("USDC_POOL_SEED", "true");
        _set("USDC_POOL_SQRT_PRICE", vm.toString(uint256(SQRT_PRICE_ETH_USDC)));
        _set("USDC_POOL_ETH_VALUE", "1000000000000000000"); // 1 ETH
        _set("USDC_POOL_LIQUIDITY", "0"); // derive
        address pm = address(new StubPositionManager(address(manager)));
        _set("POSITION_MANAGER", vm.toString(pm)); // required on a real network

        deploy();

        assertEq(FeeHook(payable(ex.feeHook)).positionManager(), pm, "PositionManager wired");
        assertTrue(FeeHook(payable(ex.feeHook)).isPositionManager(pm), "and listed");
        assertTrue(ex.usdc != address(usdc), "must be a fresh mock, not the env USDC");
        assertEq(MockUSDC(ex.usdc).decimals(), 6, "mock keeps USDC's 6 decimals");
        uint128 liq = IPoolManager(address(manager)).getLiquidity(PoolId.wrap(ex.usdcPoolId));
        assertGt(liq, 0, "the (ETH, mock) pool must be seeded");
        // Derived L = 1 ETH * sqrtP / 2^96 — the pool should hold (about) that.
        uint256 expected = (uint256(1 ether) * SQRT_PRICE_ETH_USDC) >> 96;
        assertApproxEqRel(uint256(liq), expected, 1e15, "liquidity derived from the ETH leg");
        assertEq(ex.chainId, 46630, "chain id exported");
        // Still a complete deploy: BODKIN launched, admin gone.
        assertEq(CreatorNFT(ex.creatorNFT).nftOf(ex.bodkin), 0, "BODKIN is NFT #0");
        assertEq(FeeHook(payable(ex.feeHook)).owner(), address(0), "renounced");
    }

    function test_MockUsdcRefusedOnMainnet() public {
        vm.chainId(4663);
        _set("USDC_DEPLOY_MOCK", "true");
        _set("USDC_POOL_SEED", "true");
        vm.expectRevert(bytes("DeployV1: USDC_DEPLOY_MOCK is testnet-only (refused on Robinhood mainnet)"));
        this.deploy();
    }

    function test_MockUsdcRequiresSeedOptIn() public {
        vm.chainId(46630);
        _set("USDC_DEPLOY_MOCK", "true");
        _set("USDC_POOL_SEED", "false");
        vm.expectRevert(bytes("DeployV1: a mock USDC has no pool yet - set USDC_POOL_SEED=true"));
        this.deploy();
    }

    // ── network guardrails (a testnet value in a mainnet deploy would be permanent) ──────────────

    function test_MainnetRefusesANonCanonicalWeth() public {
        vm.chainId(4663);
        address testnetWeth = 0x7943e237c7F95DA44E0301572D358911207852Fa; // the classic mix-up
        vm.etch(testnetWeth, hex"00");
        _set("WETH", vm.toString(testnetWeth));
        _set("DEPLOY_LABEL", "mainnet");
        vm.expectRevert(
            bytes("DeployV1: on Robinhood mainnet WETH must be the canonical L2 WETH 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73")
        );
        this.deploy();
    }

    function test_MainnetRefusesAnyLabelButMainnet() public {
        vm.chainId(4663);
        vm.etch(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73, hex"00");
        _set("WETH", "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73");
        _set("DEPLOY_LABEL", "testnet");
        vm.expectRevert(
            bytes("DeployV1: a Robinhood mainnet deploy must use DEPLOY_LABEL=mainnet (the exports file the apps load)")
        );
        this.deploy();
    }

    function test_RealNetworkRefusesAWethWithoutCode() public {
        vm.chainId(46630);
        _set("USDC_DEPLOY_MOCK", "true");
        _set("USDC_POOL_SEED", "true");
        _set("USDC_POOL_SQRT_PRICE", vm.toString(uint256(SQRT_PRICE_ETH_USDC)));
        _set("USDC_POOL_ETH_VALUE", "1000000000000000000");
        // WETH_STUB has no code here — e.g. the mainnet WETH address used on testnet.
        vm.expectRevert(bytes("DeployV1: WETH has no code on this chain (a testnet address on mainnet, or the reverse?)"));
        this.deploy();
    }

    /// On a real network the one-shot PositionManager wiring cannot be skipped (LP rewards would be
    /// unclaimable forever after the renounce), nor pointed at one bound to another PoolManager.
    function test_RealNetworkRequiresAPositionManager() public {
        _fakeTestnetMockUsdc();
        _set("POSITION_MANAGER", vm.toString(address(0)));
        vm.expectRevert(bytes("DeployV1: POSITION_MANAGER is required on Robinhood (LP rewards would be unclaimable)"));
        this.deploy();
    }

    function test_RealNetworkRefusesAPositionManagerOfAnotherPoolManager() public {
        _fakeTestnetMockUsdc();
        _set("POSITION_MANAGER", vm.toString(address(new StubPositionManager(address(0xF0E)))));
        vm.expectRevert(bytes("DeployV1: POSITION_MANAGER is not bound to POOL_MANAGER"));
        this.deploy();
    }

    /// A testnet-shaped config on a local PoolManager (chain id faked to 46630).
    function _fakeTestnetMockUsdc() internal {
        vm.chainId(46630);
        // Mine a real salt here rather than using setUp's placeholder: on a real chain id the deploy
        // REQUIRES BODKIN to carry the b0d41 suffix, which is the invariant these tests are standing in
        // for. Cheap now that the miner runs across the cores.
        _set("BODKIN_SALT", "");
        vm.etch(WETH_STUB, hex"00");
        _set("USDC_DEPLOY_MOCK", "true");
        _set("USDC_POOL_SEED", "true");
        _set("USDC_POOL_SQRT_PRICE", vm.toString(uint256(SQRT_PRICE_ETH_USDC)));
        _set("USDC_POOL_ETH_VALUE", "1000000000000000000");
    }

    /// A deeper (ETH, USDC) tier exists than the one configured: refuse.
    function test_RefusesAShallowerUsdcTierThanTheDeepest() public {
        _seedDeeperUsdcTier();
        vm.expectRevert(
            bytes(
                "DeployV1: USDC_POOL_FEE/TICK_SPACING is not the deepest (ETH,USDC) tier on this chain. Pick the deepest, or set USDC_POOL_ALLOW_SHALLOW=true on purpose."
            )
        );
        this.deploy();
    }

    /// ...unless the operator overrides it on purpose.
    function test_ShallowUsdcTierAllowedWhenExplicit() public {
        _seedDeeperUsdcTier();
        _set("USDC_POOL_ALLOW_SHALLOW", "true");
        deploy();
        assertEq(uint256(ex.usdcPoolFee), 500, "the configured tier was wired");
    }

    /// A (ETH, USDC) 100/1 pool deeper than setUp's 500/10 one.
    function _seedDeeperUsdcTier() internal {
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        PoolKey memory deeper = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(usdc)),
            fee: 100,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });
        manager.initialize(deeper, SQRT_PRICE_ETH_USDC);
        usdc.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity{value: 300 ether}(
            deeper,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(1),
                tickUpper: TickMath.maxUsableTick(1),
                liquidityDelta: 1e16, // deeper than the 500/10 pool's 5e15
                salt: 0
            }),
            ""
        );
    }

    /// Wrong tier on a chain that HAS the pool: refuse rather than bake a shallow operator pool.
    function test_WrongUsdcTierRefusesWithoutSeedOptIn() public {
        _set("USDC_POOL_FEE", "3000");
        _set("USDC_POOL_TICK_SPACING", "60");
        vm.expectRevert();
        this.deploy();
    }

    // ── live-network forks (opt-in) ──────────────────────────────────────────────────────
    // The operator config from .env.example, run against the REAL canonical Uniswap V4 on Robinhood
    // (same addresses on both networks) — the closest thing to the deploy short of broadcasting.
    // Network-gated like UniversalRouterSwapFork.t.sol: only when the RPC env is set.
    //   ROBINHOOD_TESTNET_RPC_URL=https://rpc.testnet.chain.robinhood.com \
    //   ROBINHOOD_MAINNET_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
    //     forge test --match-contract DeployV1Test --match-test Fork -vv
    address internal constant RH_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant RH_POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address internal constant RH_QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address internal constant RH_STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address internal constant RH_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // Paxos Global Dollar (the dollar we use)
    address internal constant RH_USDC = 0x80e0e24718dbFcad49ECAA6F1e6C89A190586cA8; // canonical-bridge USDC (alternative)
    address internal constant RH_WETH_MAINNET = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant RH_WETH_TESTNET = 0x7943e237c7F95DA44E0301572D358911207852Fa;

    function _forkOrSkip(string memory envKey) internal returns (bool) {
        string memory url = vm.envOr(envKey, string(""));
        if (bytes(url).length == 0) {
            emit log_string(string.concat("skipped: ", envKey, " not set"));
            return false;
        }
        vm.createSelectFork(url);
        vm.deal(deployer, 5 ether);
        _set("POOL_MANAGER", vm.toString(RH_POOL_MANAGER));
        _set("POSITION_MANAGER", vm.toString(RH_POSITION_MANAGER));
        _set("V4_QUOTER", vm.toString(RH_QUOTER));
        _set("STATE_VIEW", vm.toString(RH_STATE_VIEW));
        return true;
    }

    /// Testnet, exactly as .env.example ships it: mock dollar + a seeded (ETH, mock) pool at 500/10.
    function test_ForkTestnet_DeploysAgainstCanonicalV4() public {
        if (!_forkOrSkip("ROBINHOOD_TESTNET_RPC_URL")) return;
        assertEq(block.chainid, 46630, "expected the Robinhood testnet");
        _set("WETH", vm.toString(RH_WETH_TESTNET));
        _set("USDC_DEPLOY_MOCK", "true");
        _set("USDC_POOL_SEED", "true");
        _set("USDC_POOL_FEE", "500");
        _set("USDC_POOL_TICK_SPACING", "10");
        _set("USDC_POOL_SQRT_PRICE", "3961408125713216879677197"); // $2,500/ETH
        _set("USDC_POOL_ETH_VALUE", "500000000000000000"); // 0.5 ETH
        _set("USDC_POOL_LIQUIDITY", "0");
        _set("DEPLOY_LABEL", "testnet");

        deploy();

        assertEq(ex.poolManager, RH_POOL_MANAGER, "wired to the canonical PoolManager");
        assertEq(ex.positionManager, RH_POSITION_MANAGER, "canonical PositionManager wired");
        assertEq(ex.v4Quoter, RH_QUOTER, "reused the canonical quoter");
        assertEq(ex.stateView, RH_STATE_VIEW, "reused the canonical StateView");
        assertGt(IPoolManager(RH_POOL_MANAGER).getLiquidity(PoolId.wrap(ex.usdcPoolId)), 0, "seeded (ETH, mock) pool");
        assertEq(FeeHook(payable(ex.feeHook)).positionManager(), RH_POSITION_MANAGER, "hook resolves LP owners");
        assertEq(CreatorNFT(ex.creatorNFT).nftOf(ex.bodkin), 0, "BODKIN is NFT #0");
        assertEq(FeeHook(payable(ex.feeHook)).owner(), address(0), "renounced");
        // The exported deployBlock must be the L2 height. On an Arbitrum-family fork forge mirrors the
        // chain: `block.number` is the PARENT chain's (Sepolia, ~11.7M) — the value a naive export
        // wrote and an indexer then replayed 109M empty blocks from. eth_blockNumber is the L2 head.
        uint256 l2 = _l2BlockNumber();
        assertGt(l2, 100_000_000, "deployBlock is the L2 head (>100M on the testnet), not block.number");
        assertGt(l2, block.number, "and strictly above the parent-chain block forge reports as block.number");
    }

    /// Mainnet config as .env.example ships it: USDG and its deepest (ETH, USDG) pool (100/1), WIRED —
    /// never seeded, never re-priced by us.
    function test_ForkMainnet_WiresUsdgPool() public {
        if (!_forkOrSkip("ROBINHOOD_MAINNET_RPC_URL")) return;
        assertEq(block.chainid, 4663, "expected Robinhood mainnet");
        _set("WETH", vm.toString(RH_WETH_MAINNET));
        _set("USDC", vm.toString(RH_USDG));
        _set("USDC_DEPLOY_MOCK", "false");
        _set("USDC_POOL_SEED", "false");
        _set("USDC_POOL_FEE", "100");
        _set("USDC_POOL_TICK_SPACING", "1");
        _set("DEPLOY_LABEL", "mainnet");

        deploy();

        assertEq(ex.usdc, RH_USDG, "USDG is the dollar");
        // RELATIVE depth, not an absolute floor: in-range liquidity moves (4.1e17 on 2026-09-07,
        // 1.67e17 on 2026-09-19), so what must hold is that the wired pool is live and at least as
        // deep as every other canonical (ETH, USDG) tier.
        uint128 wired = IPoolManager(RH_POOL_MANAGER).getLiquidity(PoolId.wrap(ex.usdcPoolId));
        assertGt(wired, 0, "the live canonical pool, not a fresh one");
        uint24[4] memory fees = [uint24(100), 500, 3000, 10000];
        int24[4] memory spacings = [int24(1), 10, 60, 200];
        for (uint256 i; i < 4; ++i) {
            PoolKey memory k = PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(RH_USDG),
                fee: fees[i],
                tickSpacing: spacings[i],
                hooks: IHooks(address(0))
            });
            uint128 other = IPoolManager(RH_POOL_MANAGER).getLiquidity(PoolId.wrap(keccak256(abi.encode(k))));
            assertGe(wired, other, "the wired tier is the deepest (ETH, USDG) pool");
        }
        assertEq(uint256(ex.usdcPoolFee), 100, "exported tier fee");
        assertEq(int256(ex.usdcPoolTickSpacing), int256(1), "exported tier spacing");
        assertEq(FeeHook(payable(ex.feeHook)).owner(), address(0), "renounced");
    }

    /// The ALTERNATIVE .env.example documents: the canonical-bridge USDC, which has NO (ETH, USDC)
    /// V4 pool yet — so the deploy seeds one from USDC the deployer bridged in (dealt here). Kept as
    /// proof that seeding works on the real chain; not the shipped config.
    function test_ForkMainnet_SeedsBridgedUsdcPool() public {
        if (!_forkOrSkip("ROBINHOOD_MAINNET_RPC_URL")) return;
        assertEq(block.chainid, 4663, "expected Robinhood mainnet");
        _set("WETH", vm.toString(RH_WETH_MAINNET));
        _set("USDC", vm.toString(RH_USDC));
        _set("USDC_DEPLOY_MOCK", "false");
        _set("USDC_POOL_SEED", "true");
        _set("USDC_POOL_FEE", "500");
        _set("USDC_POOL_TICK_SPACING", "10");
        _set("USDC_POOL_SQRT_PRICE", "3961408125713216879677197"); // $2,500/ETH
        _set("USDC_POOL_ETH_VALUE", "1000000000000000000"); // 1 ETH + 2,500 USDC
        _set("USDC_POOL_LIQUIDITY", "0");
        _set("DEPLOY_LABEL", "mainnet");
        deal(RH_USDC, deployer, 10_000e6); // what the operator bridges in before broadcasting

        deploy();

        assertEq(ex.usdc, RH_USDC, "bridged USDC is the dollar");
        assertGt(IPoolManager(RH_POOL_MANAGER).getLiquidity(PoolId.wrap(ex.usdcPoolId)), 0, "(ETH, USDC) pool seeded");
        assertLt(MockUSDC(RH_USDC).balanceOf(deployer), 10_000e6, "the seed spent the deployer's USDC");
        assertEq(FeeHook(payable(ex.feeHook)).owner(), address(0), "renounced");
    }

    /// Without bridged USDC in the wallet the seed refuses up front, with the reason.
    function test_ForkMainnet_SeedRefusesWithoutBridgedUsdc() public {
        if (!_forkOrSkip("ROBINHOOD_MAINNET_RPC_URL")) return;
        _set("WETH", vm.toString(RH_WETH_MAINNET));
        _set("DEPLOY_LABEL", "mainnet"); // the mainnet guard runs first
        _set("USDC", vm.toString(RH_USDC));
        _set("USDC_POOL_SEED", "true");
        _set("USDC_POOL_FEE", "500");
        _set("USDC_POOL_TICK_SPACING", "10");
        _set("USDC_POOL_SQRT_PRICE", "3961408125713216879677197");
        _set("USDC_POOL_ETH_VALUE", "1000000000000000000");
        vm.expectRevert(bytes("DeployV1: deployer holds less USDC than the seed needs (USDC_POOL_ETH_VALUE x price)"));
        this.deploy();
    }
}
