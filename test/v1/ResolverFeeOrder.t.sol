// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./LauncherV1.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice A resolver wallet that runs code when it is paid — what EIP-7702 turns any hot key into.
///         On receipt it buys the pool of the launch that just happened, best-effort so it can never
///         break the transfer itself (a revert there would revert the launch and prove nothing).
contract SniperResolver {
    LauncherV1 public immutable launcher;
    PoolSwapTest public immutable router;
    uint256 public sniped;
    bool internal running;

    constructor(LauncherV1 l, PoolSwapTest r) {
        launcher = l;
        router = r;
    }

    receive() external payable {
        if (running) return; // the router refunds unused ETH — don't recurse
        try this.snipe() {} catch {}
    }

    function snipe() external {
        require(msg.sender == address(this), "self only");
        running = true;
        uint256 n = launcher.tokensCount();
        address t = launcher.tokens(n - 1); // the launch being processed right now
        PoolKey memory key = launcher.poolKeyOf(t);
        uint256 amt = address(this).balance / 2;
        router.swap{value: amt}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amt), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        sniped = IERC20(t).balanceOf(address(this));
        running = false;
    }
}

/// @notice The flat launch fee is the only payment `launch()` makes to an address outside our own
///         contracts, and it is made with a plain `call` carrying all the gas — so the recipient runs
///         code in the middle of the launch. It used to be paid BEFORE the creator's dev buy, which let
///         a resolver key delegated (EIP-7702) to sniper code buy the freshly seeded pool first and sell
///         into a dev buy that carries no minimum output. The fee now goes out after the dev buy.
contract ResolverFeeOrderTest is LauncherV1Test {
    function _devBuyTokens(string memory sym) internal returns (address token, uint256 got) {
        address dev = makeAddr(sym);
        vm.deal(dev, 5 ether);
        vm.prank(dev);
        token = launcher.launch{value: 0.0005 ether + 1 ether}(
            sym,
            sym,
            "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/metadata.json",
            bytes32(0),
            address(0),
            0,
            _usdcPayout()
        );
        got = BodkinERC20(token).balanceOf(dev);
    }

    function test_TheResolverNeverRunsInsideALaunch() public {
        (, uint256 baseline) = _devBuyTokens("HONEST");
        assertGt(baseline, 0, "sanity: a dev buy with a passive resolver yields tokens");

        // Turn the resolver wallet into that sniper, exactly as a 7702 authorization would: same
        // address, now with code. Immutables live in the runtime code, so the etched copy keeps its
        // wiring, and it is funded well enough to move the price if it ever got the chance.
        address resolver = launcher.resolverWallet();
        SniperResolver impl = new SniperResolver(launcher, swapRouter);
        vm.etch(resolver, address(impl).code);
        vm.deal(resolver, 40 ether);
        uint256 resolverBefore = resolver.balance;

        (, uint256 withSniper) = _devBuyTokens("SNIPED");

        // The fee is BOOKED, not sent, so the launch never hands the resolver a turn at all.
        assertEq(SniperResolver(payable(resolver)).sniped(), 0, "the resolver's code never ran");
        assertEq(resolver.balance, resolverBefore, "and it was not paid mid-launch");
        assertEq(withSniper, baseline, "the dev buy got exactly the launch price");
        assertGt(launcher.createFeesOwed(), 0, "the fee is waiting to be pushed");
    }

    /// The create fees a launch books are the TEAM's to take, and only the team's — and the right to
    /// take them follows the wallet when the 2-of-2 rotates it, including what accrued before the move.
    /// Reading the wallet from storage on every call is what makes that true; caching it would strand
    /// the money with a wallet the team may have rotated away from precisely because it was lost.
    function test_WithdrawIsTeamOnlyAndFollowsARotation() public {
        _devBuyTokens("FEES");
        uint256 owed = launcher.createFeesOwed();
        assertGt(owed, 0, "a launch books its create fee");

        vm.prank(makeAddr("a stranger"));
        vm.expectRevert(bytes("Launcher: not the team wallet"));
        launcher.withdraw();
        vm.prank(creator);
        vm.expectRevert(bytes("Launcher: not the team wallet"));
        launcher.withdraw();

        // The team takes it.
        uint256 before = feeRecipient.balance;
        vm.prank(feeRecipient);
        assertEq(launcher.withdraw(), owed, "the team withdrew what was booked");
        assertEq(feeRecipient.balance, before + owed, "and it landed in the team wallet");
        assertEq(launcher.createFeesOwed(), 0, "nothing left booked");
        vm.prank(feeRecipient);
        assertEq(launcher.withdraw(), 0, "a second withdrawal pays nothing");

        // Book more, then rotate the team wallet through the 2-of-2.
        _devBuyTokens("MOREFEES");
        uint256 owedAfter = launcher.createFeesOwed();
        assertGt(owedAfter, 0, "a second launch books another fee");
        uint256 nonce = launcher.teamWalletNonce();
        bytes memory sigDeployer = _signTeamUpdate(ADMIN_PK, newTeam, nonce);
        bytes memory sigTeam = _signTeamUpdate(TEAM_PK, newTeam, nonce);
        vm.prank(feeRecipient);
        launcher.updateTeamWallet(newTeam, sigDeployer, sigTeam);

        // The old wallet is out; the new one can take what the old one never did.
        vm.prank(feeRecipient);
        vm.expectRevert(bytes("Launcher: not the team wallet"));
        launcher.withdraw();
        uint256 newBefore = newTeam.balance;
        vm.prank(newTeam);
        assertEq(launcher.withdraw(), owedAfter, "the rotated-in wallet withdraws");
        assertEq(newTeam.balance, newBefore + owedAfter, "into the new team wallet");
    }
}
