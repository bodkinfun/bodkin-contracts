// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CreatorNFT} from "../src/launchpad/CreatorNFT.sol";

contract CreatorNFTTest is Test {
    CreatorNFT internal nft;
    address internal launchpad = makeAddr("launchpad");
    address internal creator = makeAddr("creator");
    address internal buyer = makeAddr("buyer");
    address internal token = makeAddr("token");

    function setUp() public {
        nft = new CreatorNFT("");
        nft.setLaunchpad(launchpad);
    }

    function test_MintAssignsCreatorRevenue() public {
        vm.prank(launchpad);
        uint256 id = nft.mint(creator, token);
        assertEq(nft.ownerOf(id), creator, "creator holds the NFT");
        assertEq(nft.creatorOf(token), creator, "creator entitled to the fee");
    }

    function test_TransferMovesTheRevenueStream() public {
        vm.prank(launchpad);
        uint256 id = nft.mint(creator, token);

        // Creator sells the revenue stream to buyer.
        vm.prank(creator);
        nft.transferFrom(creator, buyer, id);

        assertEq(nft.creatorOf(token), buyer, "buyer now receives the creator fee");
    }

    function test_OnlyLaunchpadMints() public {
        vm.prank(creator);
        vm.expectRevert(bytes("NFT: only launchpad"));
        nft.mint(creator, token);
    }

    function test_OneNftPerLaunch() public {
        vm.startPrank(launchpad);
        nft.mint(creator, token);
        vm.expectRevert(bytes("NFT: already minted"));
        nft.mint(creator, token);
        vm.stopPrank();
    }

    function test_UnknownTokenHasNoCreator() public {
        assertEq(nft.creatorOf(makeAddr("other")), address(0), "no NFT -> no creator");
    }

    /// Id 0 is a REAL id, held by the first launch (BODKIN on the live deploy). The
    /// old design burned it as a "none" sentinel; if anything still reads a zero as
    /// "no NFT", that launch's fees become permanently unclaimable — `claimCreator`
    /// compares the caller against `creatorOf`, and nobody is address(0).
    function test_FirstLaunchHoldsIdZeroAndIsStillResolvable() public {
        vm.prank(launchpad);
        uint256 id = nft.mint(creator, token);
        assertEq(id, 0, "ids count from zero");
        assertEq(nft.ownerOf(0), creator);
        assertEq(nft.creatorOf(token), creator, "id 0 resolves to its holder, not to 'none'");
        assertEq(nft.launchToken(0), token, "and maps back to its launch");

        // A DIFFERENT token still reads as having none, even though its nftOf is also 0.
        address other = makeAddr("other-token");
        assertEq(nft.nftOf(other), 0, "unminted tokens read zero too");
        assertEq(nft.creatorOf(other), address(0), "but resolve to no creator");

        // And the holder of id 0 cannot be given a second NFT for the same launch.
        vm.prank(launchpad);
        vm.expectRevert(bytes("NFT: already minted"));
        nft.mint(creator, token);
    }

    /// With a base URI, metadata is SERVED per launch token — which is what lets the
    /// card art, the wording and our website link change later without a contract call,
    /// on every NFT ever minted. The path after the base is the coin's OWN IPFS document,
    /// so the link stays readable through any gateway once the prefix is swapped.
    function test_TokenUriIsServedPerLaunchToken() public {
        CreatorNFT served = new CreatorNFT("https://api.bodkin.xyz/api/fee-nft/");
        served.setLaunchpad(launchpad);
        MockLaunchToken launched = new MockLaunchToken("ipfs://bafyDOC/metadata.json");
        vm.prank(launchpad);
        uint256 id = served.mint(creator, address(launched));

        assertEq(served.tokenURI(id), "https://api.bodkin.xyz/api/fee-nft/bafyDOC/metadata.json");
    }

    /// A document that is not `ipfs://` cannot be put behind a gateway, so it is returned as-is
    /// even with a base URI (no launcher of ours produces one; this pins the contract's behaviour).
    function test_TokenUriLeavesANonIpfsDocumentUntouched() public {
        CreatorNFT served = new CreatorNFT("https://api.bodkin.xyz/api/fee-nft/");
        served.setLaunchpad(launchpad);
        MockLaunchToken launched = new MockLaunchToken("https://elsewhere.example/doc.json");
        vm.prank(launchpad);
        uint256 id = served.mint(creator, address(launched));
        assertEq(served.tokenURI(id), "https://elsewhere.example/doc.json");
    }

    /// With NO base URI it falls back to the launched token's own ERC-1046 document, so
    /// a local deploy still renders the right avatar and name with no server running.
    function test_TokenUriFallsBackToTheLaunchTokensOwnDocument() public {
        MockLaunchToken launched = new MockLaunchToken("ipfs://bafyDOC/metadata.json");
        vm.prank(launchpad);
        uint256 id = nft.mint(creator, address(launched));
        assertEq(nft.tokenURI(id), "ipfs://bafyDOC/metadata.json");
    }

    function test_TokenUriRevertsForAnUnmintedId() public {
        vm.expectRevert();
        nft.tokenURI(999);
    }
}

/// Minimal stand-in for a launched token's ERC-1046 pointer.
contract MockLaunchToken {
    string private _uri;

    constructor(string memory uri_) {
        _uri = uri_;
    }

    function tokenURI() external view returns (string memory) {
        return _uri;
    }
}
