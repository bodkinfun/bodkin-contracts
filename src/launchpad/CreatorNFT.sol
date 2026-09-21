// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @dev The launched token exposes its ERC-1046 metadata pointer via tokenURI().
interface ILaunchTokenURI {
    function tokenURI() external view returns (string memory);
}

/// @title CreatorNFT
/// @notice One transferable NFT per launch, representing the right to that
///         launch's creator-fee payouts (35% of every swap fee by default; more with the
///         per-coin options chosen at launch).
///         Whoever HOLDS the NFT receives the creator fee — so a creator can
///         sell or transfer their revenue stream (Let's-Bonk style). The
///         launchpad mints it to the token's creator at launch; distribution
///         reads `creatorOf(token)` to know who to pay.
contract CreatorNFT is ERC721 {
    address public owner;
    address public launchpad;
    uint256 public nextId;

    /// @notice Where `tokenURI` points, e.g. "https://api.bodkin.xyz/api/fee-nft/".
    ///         The launch token's own `ipfs://` document path is appended, and the server
    ///         composes the ERC-721 document live from the indexer's data.
    ///
    ///         Set once, in the constructor, with NO setter — the launchpad ships with
    ///         no admin, and a mutable metadata pointer would be exactly the kind of
    ///         lever that undermines that. Everything a human actually wants to change
    ///         (the marketing site link, the wording, the card art) lives in the SERVED
    ///         document, behind the indexer's own env — not here.
    ///
    ///         Empty = fall back to the launched token's own ERC-1046 document, which is
    ///         what local deploys use so the NFT still renders with no server running.
    string public baseURI;

    /// @notice launch token each NFT id corresponds to (for display / lookups).
    ///
    ///         Also the EXISTENCE RECORD: an id belongs to a token if and only if
    ///         `launchToken[id] == token`. That replaces the old "id 0 means none"
    ///         sentinel, which cost the collection its first id — see {nftOf}.
    mapping(uint256 => address) public launchToken;
    /// @notice launch token -> its creator NFT id.
    ///
    ///         `0` is a REAL id here, held by the first launch (BODKIN itself), so this
    ///         mapping alone cannot answer "does this token have an NFT" — every such
    ///         question goes through `launchToken[nftOf[token]] == token`. Reading a
    ///         zero from here and concluding "none" is the one mistake this contract
    ///         invites, which is why the check lives in {creatorOf} and {mint} rather
    ///         than at each call site.
    mapping(address => uint256) public nftOf;

    event LaunchpadSet(address launchpad);
    event CreatorMinted(uint256 indexed id, address indexed token, address indexed creator);
    event OwnershipRenounced();

    /// @dev The ERC-721 `name()` is what wallets and marketplaces show as the COLLECTION: the site.
    constructor(string memory baseURI_) ERC721("bodkin.fun", "BODKINFEE") {
        owner = msg.sender;
        // Ids start at ZERO: the platform's own token is the first launch, so BODKIN
        // holds #0 and every launch after it counts up from there. No id is burned on
        // a sentinel — existence is `launchToken[id] == token` instead.
        nextId = 0;
        baseURI = baseURI_;
    }

    function setLaunchpad(address launchpad_) external {
        require(msg.sender == owner, "NFT: only owner");
        require(launchpad == address(0), "NFT: launchpad already set");
        require(launchpad_ != address(0), "NFT: launchpad is zero");
        launchpad = launchpad_;
        emit LaunchpadSet(launchpad_);
    }

    /// @notice Permanently renounce admin control (owner -> zero). `setLaunchpad` is
    ///         already one-shot; after renounce there is no admin power left at all.
    ///         Called by the deploy script once the launchpad is wired.
    function renounceOwnership() external {
        require(msg.sender == owner, "NFT: only owner");
        owner = address(0);
        emit OwnershipRenounced();
    }

    /// @notice Mint the creator NFT for a launch, to `creator`. Launchpad only.
    function mint(address creator, address token) external returns (uint256 id) {
        require(msg.sender == launchpad, "NFT: only launchpad");
        require(creator != address(0), "NFT: creator is zero");
        // "Already has one" is `launchToken[nftOf[token]] == token`, never `nftOf != 0`
        // — id 0 is a real id. As a side effect this also refuses `token == address(0)`
        // before the first mint, which is correct: there is no such launch.
        require(launchToken[nftOf[token]] != token, "NFT: already minted");
        id = nextId++;
        launchToken[id] = token;
        nftOf[token] = id;
        _mint(creator, id);
        emit CreatorMinted(id, token, creator);
    }

    /// @notice ERC-721 metadata for the fee NFT.
    ///
    ///         The launched token's own ERC-1046 document is an immutable `ipfs://<cid>/metadata.json`
    ///         pinned at launch. With a `baseURI` set, this returns `<baseURI><cid>/metadata.json`:
    ///         the path after our prefix IS the coin's IPFS document, so anyone can swap the prefix
    ///         for any IPFS gateway and read the pinned original, while our server (which stores
    ///         every coin's tokenURI at index time and looks the coin up by it) composes the
    ///         wallet-facing document — the coin's icon as an https image, its symbol as the
    ///         title, the fee terms — from its OWN env, so wording can change at any time and every
    ///         NFT ever minted follows, with no contract call.
    ///
    ///         With no `baseURI`, it falls back to the coin's document as-is. That renders the
    ///         right art and name too, just without the fee-stream framing — and it needs no
    ///         server, which is why local deploys use it. A document that is not `ipfs://` (no
    ///         launcher of ours produces one) is likewise returned untouched.
    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id); // reverts for a nonexistent id, per ERC-721
        string memory doc = ILaunchTokenURI(launchToken[id]).tokenURI();
        if (bytes(baseURI).length == 0) return doc;
        bytes memory b = bytes(doc);
        // "ipfs://" is 7 bytes; anything else is not a content path we can put behind a gateway.
        if (
            b.length <= 7 || b[0] != "i" || b[1] != "p" || b[2] != "f" || b[3] != "s" || b[4] != ":" || b[5] != "/"
                || b[6] != "/"
        ) return doc;
        bytes memory path = new bytes(b.length - 7);
        for (uint256 i = 7; i < b.length; ++i) {
            path[i - 7] = b[i];
        }
        return string.concat(baseURI, string(path));
    }

    /// @notice The address currently entitled to a launch's creator fee — the
    ///         current holder of that launch's NFT (address(0) if none).
    function creatorOf(address token) external view returns (address) {
        uint256 id = nftOf[token];
        // Not `id == 0`: BODKIN legitimately holds id 0, and treating that as "none"
        // would make its creator fees permanently unclaimable — `claimCreator` compares
        // the caller against this address, and nobody is address(0).
        if (launchToken[id] != token) return address(0);
        return ownerOf(id);
    }
}
