# $BODKIN Contracts

Foundry project for the $BODKIN smart-contract layer: the **single-sided Uniswap V4
launchpad** (`src/launchpad/v1/`). The frontends build against the files in `exports/`.

## Architecture

```
                   Uniswap V4 PoolManager (singleton)
                              │
        ┌─────────────────────┴─────────────────────┐
        │                                           │
   LauncherV1 ──▶ BodkinERC20 × N            FeeHook (hooks address on every launch pool)
        │                                           │ 1% skim on the NUMERAIRE side
        └──▶ CreatorNFT (fee stream)                ▼
                                     70% creator / 10% BODKIN buy&burn / 20% team
   Uniswap Universal Router ──▶ every swap routes through it (ETH↔token, token↔token,
                                external→token); ERC-20 inputs pulled via Permit2
```

## The model

A launch deposits the **entire fixed supply** one-sided into a Uniswap V4 range just
above spot, priced from a fixed starting FDV (~$4,000 either way: `1.5 ether` for an
ETH-quoted pool, `4_000e6` for a USDC-quoted one) and graduating at a fixed cap (`12 ether` /
`30_000e6`, ~$30k). Anyone can buy the coin from its
first block. The position is **permanently locked**: it is minted to the launcher
and never withdrawable, so liquidity can't be pulled. No bonding curve, no graduation,
no fee-on-transfer — launched tokens are plain ERC20s.

Revenue is a **1% fee skimmed by the hook on the numeraire side only** (`FEE_BPS = 100`,
never on the meme token), accrued per token into three pull-claimed buckets:
`CREATOR_BPS = 7_000` / `BURN_BPS = 1_000` / remainder to the team. All three are
`constant` with no setter — changing the split means a new hook. Each bucket is then
converted into its destination token by the same swaps that fill it, so nothing waits in
the numeraire for someone to come and collect it.

Two things are chosen **once, at launch, and can never change**:

- **The numeraire** — native ETH (default) or USDC. The launcher enforces
  `token > numeraire` so the numeraire is always `currency0`; that invariant is what
  lets one set of range/direction/fee math serve both.
- **The creator's payout token** — ETH, USDC, or any token with a canonical-tier
  Uniswap pool. The hook converts AS THE FEE IS EARNED (on the swap path, in capped
  chunks), so the balance is already in that token when it is claimed, and pays the
  current fee-NFT holder. To
  direct the fees at a different wallet, pass `PayoutParams.feeRecipient` and the fee
  NFT is MINTED there — there is no payout override, so the income never gets separated
  from the NFT that represents it.

A flat `launchFeeWei = 0.0005 ether` comes off the front of `msg.value` to
`launchFeeRecipient`; the remainder is an optional dev buy swapped to the creator.

NSFW moderation is entirely **off-chain** — there is no on-chain moderator role.

### No admin

`LauncherV1` ships ownerless by construction: no owner, no setters, so launch pricing
can never be changed. `FeeHook` and `CreatorNFT` do have owners, but only for one-time
deploy wiring (`setLauncher`, `setUsdcPool`, `setBodkinPool`, `setLaunchpad`), and
`DeployLocalV1` calls `renounceOwnership()` on both once wiring is done — so the
launchpad ships with `owner == address(0)`. `test/v1/DeployRenounce.t.sol` asserts it,
because this promise was previously made in this README and not kept by the code.

The consequence is deliberate: after deploy the USDC and BODKIN conversion pools can
never be re-pointed. Anything that must stay tunable has to be a launch-time parameter.

## Contracts

- **`src/launchpad/v1/LauncherV1.sol`** — the launcher.
  `launch(name, symbol, supply, metadataURI, salt, numeraire, devBuyAmount, payout)`
  (payable) clones `BodkinERC20` via CREATE2 (off-chain salt mining gives every token a
  `…b0d41` vanity address), initializes the pool with `FeeHook` as its hooks address,
  mints the single-sided position, and mints the `CreatorNFT` to `payout.feeRecipient`
  (or the caller when that is zero) — which is what makes the fee stream point there.

- **`src/launchpad/v1/FeeHook.sol`** — the Uniswap V4 hook. `_beforeInitialize` accepts
  a pool **only from the launcher** and only with an allow-listed numeraire;
  `_afterSwap` skims the 1%.

  **The fee is banked in the token each party chose, not in the numeraire.** The skim
  itself has to happen in the numeraire — that is the only currency the swap touches —
  but it does not stay there: the same swap converts the creator's and the team's slices
  into their payout token and banks them as `creatorOut` / `teamOut`. So `creatorWei` is
  a waiting room, not a balance.

  Consequently `claimCreator(token)` and `claimTeam(token)` take **no `minOut`**: they
  hand over an already-converted amount, perform no swap, and cannot revert on price.
  The conversion is protected where it actually happens — on the swap path, by a size cap
  no caller can influence.

  The **whole fee pipeline needs no keeper**: `_afterSwap` advances the buy & burn AND
  both conversions on every swap, so trading itself paces them. Each step converts at most `fee × depth` of the BODKIN pool —
  the largest amount a sandwich cannot profit from — and keeps the remainder for the next
  block, which is an on-chain TWAP by construction. It can never fail a trade: the step
  runs behind a try/catch, so a bad step rolls back and leaves the bucket untouched for
  the next swap to retry. `processFees(token)` runs all three manually (and `processBurn`
  / `processConvert` individually); each returns 0 rather than reverting when there is
  nothing to do.

  That chunk is bounded **per venue per block**, not just per token. Every ETH launch
  burns through the same BODKIN pool and `processBurn` is permissionless, so a per-token
  cap alone let one transaction stack N tokens' chunks into a single forced buy (measured
  on 8 launches: 8.3× the safe chunk, 4.1× the sandwich break-even). The hook books each
  spend against a venue budget that is frozen when the block's first burn runs — the
  budget must not grow on the buying it is meant to bound.

  Consequence worth knowing: `setUsdcPool` **rejects a zero-fee pool**, and so does
  `setBodkinPool` — unless the pool is one of THIS HOOK's own launch pools. The toll a
  sandwicher pays twice is what sizes a safe chunk; a plain pool charges it as an LP fee,
  while on our own pool the hook's `FEE_BPS` skim on the numeraire side is the same toll
  paid to the protocol instead of the LPs, and `_safeBurnChunk` prices it accordingly.
  That is what lets **BODKIN itself be a normal launch** — hook fee, 70/10/20 split,
  creator NFT — while also being the burn venue. Both setters are one-shot and ownership is
  renounced at deploy, so this is the only moment it can be caught. (0 was never a
  canonical tier either: `CanonicalTiers` allows 100/500/3000/10000.)

- **Swaps → Uniswap Universal Router.** There is no bespoke swap contract any more: the app
  encodes the router's `execute(commands, inputs, deadline)` calldata for every swap (ETH↔token,
  token↔token, external-wallet-token→token), and ERC-20 inputs are pulled through Permit2. On
  Robinhood both are canonical; locally `src/dev/LocalUniversalRouter.sol` + `src/dev/Permit2Deployer.sol`
  stand in (a bare anvil has neither). The old `SwapZapV1` was retired — see `UNIVERSAL_ROUTER_MIGRATION.md`.

- **`src/launchpad/v1/CanonicalTiers.sol`** — the shared fee/tickSpacing tier list, so
  the launcher, the zap and the frontend's route scan agree on what a valid pool is.

- **`src/launchpad/BodkinERC20.sol`** — the minimal launched ERC20: fixed supply,
  clone-safe EIP-2612 permit, and an ERC-1046 `tokenURI()` (an `ipfs://…` JSON pointer
  with name/description/image/socials) set once at launch. No owner, no mint, no fees.
  `LauncherV1` sets the URI at initialize and there is no editor at all, so token
  metadata is as immutable as the supply. (The old `setTokenURI`/`_launcher` pair was
  deleted: the launcher never had a call path to it, so it was unreachable code paying
  for a storage slot on every launch.)

- **`src/launchpad/CreatorNFT.sol`** — ONE collection (`bodkin.fun` / `BODKINFEE`),
  one id per launch; whoever holds an id owns that token's 70% creator share, and
  `claimCreator` pays that same holder. There is no recipient override anywhere: the
  stream IS the NFT, so it stays transferable and sellable by construction. A creator
  who wants the fees at another wallet passes `PayoutParams.feeRecipient` at launch and
  the NFT is **minted there**. Only the launcher can mint, once per token, and the
  launcher address is a one-shot setter that the deploy renounces — a copy of
  `LauncherV1` deployed by anyone else can mint nothing (pinned by
  `test_AForeignLauncherCannotUseOurNftOrHook`).

  **Ids count from ZERO**, and BODKIN — the first launch — holds #0. That is why nothing
  may read `nftOf[token] == 0` as "no NFT": existence is `launchToken[id] == token`,
  checked inside `mint` and `creatorOf`. Get that wrong in `creatorOf` and BODKIN's fees
  become permanently unclaimable, since `claimCreator` compares the caller against that
  address and nobody is `address(0)`. `DeployLocalV1` asserts BODKIN is the first launch
  rather than assuming it, so reordering the deploy fails loudly instead of quietly
  handing #0 to a demo token.

  `tokenURI` renders it as the token it earns from. With `FEE_NFT_BASE_URI` set at
  deploy it resolves to `<base><cid>/metadata.json` — the coin's own
  IPFS document path behind our prefix, gateway-readable once the prefix is swapped —
  which the indexer composes from the
  token's avatar, symbol and description plus `WEBSITE_URL` from its own env — so the art, the wording
  and the link can all change later, on every NFT ever minted, with no contract call.
  Unset (the local default) it falls back to the launch token's own `ipfs://` document,
  which still shows the right avatar and name with no server running — but wallets
  resolve `ipfs://` only through public IPFS gateways, and those (ipfs.io, dweb.link —
  MetaMask's defaults) are being retired in September 2026, so testnet and mainnet SET
  the base to their API origin + `/api/fee-nft/` and the NFT renders through our own
  image proxy instead. Frozen at deploy: no setter, same reason as everything else here,
  which is why that host has to keep answering (or redirecting) for as long as the NFTs
  exist.

- **`src/mocks/MockUSDC.sol`** — 6-decimal mock USDC. Locally it is both the USDC
  numeraire option and the USD leg of the ETH/USD reference pool.

## Running the local stack

```bash
# 1. one-time setup
npm install

# 2. chain
./scripts/anvil-local.sh        # chainId 31337, http://127.0.0.1:8545

# 3. deploy + export + sync the frontend (another terminal)
./scripts/deploy-v1-local.sh    # honors RPC_URL and PRIVATE_KEY
```

Use the `anvil-local.sh` wrapper, not bare `anvil`: it raises the contract
code-size limit to Robinhood's 96 KB (anvil defaults to EIP-170's 24,576 B and
would reject our ~28 KB FeeHook's CREATE2 deploy with "max code size exceeded"),
and it bounds anvil's in-RAM history for long sim runs (the indexer already
persists the full history to Postgres). Bare equivalent:

```bash
anvil --code-size-limit 98304 --prune-history --transaction-block-keeper 50000 --accounts 66
```

`--prune-history` drops old **state** snapshots (safe: the indexer reads events +
current state, not deep historical state). `--transaction-block-keeper N` keeps
only the last N blocks-with-txs' logs/receipts in memory. ⚠ That second flag
interacts with the indexer: a pruned block's logs are gone for good (no backfill),
so the indexer must be **running and keeping up** (it reads to head at
`CONFIRMATIONS=0`, unhealthy past ~50 blocks behind), and N must stay well above
its worst-case lag — raise it if the indexer is ever stopped mid-run. Do NOT use
`--state` / `--dump-state` here: those persist state to disk to survive restarts,
the opposite of what you want.

`script/DeployLocalV1.s.sol` deploys V4 core, the hook (via CREATE2, so its address
carries the required hook-permission bits), the launcher, the zap, `V4Quoter` +
`StateView` for the frontend's route finder, an ETH/USDC reference pool priced at
~$3,000/ETH, launches **BODKIN itself** (ETH-quoted, USDC payout, creator NFT to the
deployer) and wires its launch pool as the buy & burn venue, then launches the demo
tokens — one ETH-quoted, one USDC-quoted, plus a mock "RWA" with a canonical-tier pool
so custom fee-payout tokens can be exercised — funds the simulator's traders with USDC,
and finally renounces ownership.

`run()` also writes `exports/v1.local.json`; `deploy()` is the same deploy without that
write, which is what the tests call.

Outputs for frontends:

- `exports/v1.local.json` — all deployed addresses + `deployBlock` for the indexer
- `exports/abis/<Name>.json` — plain ABI arrays, regenerated by `scripts/export-abis.mjs`

## Tests

`forge test` — 88 across 8 suites.

- `test/v1/LauncherV1.t.sol`, `test/v1/FeeHook.t.sol`, `test/v1/LocalUniversalRouterSwap.t.sol`
  (every swap route through the local UR + real Permit2), `test/v1/DeployFunding.t.sol`,
  `test/v1/DeployRenounce.t.sol`, plus `CreatorNFT.t.sol`.
- `test/v1/ConstructorUnlock.t.sol` records WHY a launch cannot happen in a
  constructor: pool work goes through `poolManager.unlock`, which calls back into the
  caller, and a constructor has no code yet. It is a note-to-future-self in test form.
- `test/v1/BodkinERC20.t.sol` covers the clone's one-shot `initialize` guard — ported out
  of the deleted V3 suite, which held the only assertion of it.

## History

The repo previously shipped a Uniswap-V2 fee-on-transfer launchpad (`BodkinLaunchpad` +
`TaxLaunchToken` + `FeeManager` + `LiquidityLocker` and a FoT `BodkinToken`), then a
single-sided **Uniswap-V3** launcher (`SingleSidedLauncher` + `PositionLocker` +
`FeeSplitter` + `SwapZap` + `V3PoolSwapper`). Both are gone: the V3 model was deleted on
2026-07-30 once both frontends had moved onto V4 and the indexer. See git history if you
need the old code.
