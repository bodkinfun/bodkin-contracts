// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title BodkinERC20
/// @notice A plain, immutable-after-init ERC20 for the single-sided launch model.
///         There is NO fee-on-transfer — the platform fee is skimmed by the V4 fee hook
///         on the numeraire side of a swap, so the token stays a clean, ordinary ERC20
///         that behaves identically on any venue.
///
///         Clone-friendly: deployed ONCE as an implementation, then each launch is an
///         EIP-1167 minimal-proxy clone that `initialize`s its own name/symbol and
///         mints the full supply. Per-token creation is thus a ~40k-gas clone instead
///         of a full contract deploy. Name/symbol live in storage (set at init) rather
///         than in the OZ constructor, so they survive on the clone.
contract BodkinERC20 is ERC20 {
    string private _tokenName;
    string private _tokenSymbol;
    bool private _initialized;

    /// @notice ERC-1046 token metadata URI — points to a JSON document
    ///         ({name, symbol, description, image, twitter, telegram, website}) pinned
    ///         to IPFS, exactly like an NFT's tokenURI. External tools (explorers,
    ///         aggregators) that understand ERC-1046 can read a launch's metadata
    ///         straight off the token. Set ONCE at init and never editable: the launcher
///         has no call path that would change it, so a token's metadata is as fixed as
///         its supply.
    string private _tokenURI;

    /// @dev The implementation is constructed once and locked, so it can never be
    ///      initialized or used as a token itself — only its clones can.
    constructor() ERC20("", "") {
        _initialized = true;
    }

    /// @notice Initialize a fresh clone: set metadata (incl. the ERC-1046 tokenURI) and
    ///         mint the full supply to `mintTo`. Callable exactly once (guarded), so the
    ///         token is fully immutable afterwards.
    function initialize(
        string calldata name_,
        string calldata symbol_,
        uint256 supply_,
        address mintTo,
        string calldata tokenURI_
    ) external {
        require(!_initialized, "BodkinERC20: initialized");
        require(mintTo != address(0), "BodkinERC20: mint to zero");
        require(supply_ > 0, "BodkinERC20: zero supply");
        _initialized = true;
        _tokenName = name_;
        _tokenSymbol = symbol_;
        _tokenURI = tokenURI_;
        _mint(mintTo, supply_);
    }

    function name() public view override returns (string memory) {
        return _tokenName;
    }

    function symbol() public view override returns (string memory) {
        return _tokenSymbol;
    }

    /// @notice ERC-1046 metadata pointer (an `ipfs://…` JSON URI).
    function tokenURI() external view returns (string memory) {
        return _tokenURI;
    }

    // ── EIP-2612 permit ──────────────────────────────────────────────────────
    // Gasless, deadline-bounded approval: the holder signs a permit off-chain and a
    // router consumes it in the SAME tx as the swap (via selfPermit + multicall), so
    // there is never a lingering allowance. Clone-safe: OZ's EIP712 caches the name
    // hash in an `immutable` (baked into the implementation bytecode, so wrong for a
    // clone whose name is set in `initialize`), so we build the EIP-712 domain from
    // the STORED name each call instead of inheriting ERC20Permit.

    bytes32 private constant _PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    mapping(address => uint256) private _nonces;

    /// @notice EIP-712 domain separator, rebuilt from the clone's own name + address.
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(_DOMAIN_TYPEHASH, keccak256(bytes(_tokenName)), keccak256("1"), block.chainid, address(this))
        );
    }

    /// @notice Current permit nonce for `owner` (consumed and incremented per permit).
    function nonces(address owner) public view returns (uint256) {
        return _nonces[owner];
    }

    /// @notice EIP-2612: set `spender`'s allowance from `owner` via an off-chain
    ///         signature valid until `deadline`.
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
    {
        require(block.timestamp <= deadline, "BodkinERC20: permit expired");
        bytes32 structHash =
            keccak256(abi.encode(_PERMIT_TYPEHASH, owner, spender, value, _nonces[owner]++, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
        require(ECDSA.recover(digest, v, r, s) == owner, "BodkinERC20: invalid signature");
        _approve(owner, spender, value);
    }
}
