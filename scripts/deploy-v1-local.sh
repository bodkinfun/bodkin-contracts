#!/usr/bin/env bash
# Deploys the single-sided V1 stack (Uniswap V4 PoolManager + FeeHook + launcher +
# swap zap + V4Quoter/StateView lenses) to a local anvil node, exports the ABIs,
# and syncs them into the frontend.
#
# Run this AFTER anvil is already running (see the run guide).
#
#   ./scripts/deploy-v1-local.sh
#   RPC_URL=http://127.0.0.1:8546 ./scripts/deploy-v1-local.sh
set -euo pipefail
cd "$(dirname "$0")/.."   # -> contracts/

# forge/anvil live in ~/.foundry/bin (not always on the default PATH).
export PATH="$HOME/.foundry/bin:$PATH"

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
IPFS_API="${IPFS_API:-http://127.0.0.1:45001}"

# Preflight — fail HERE with the real cause, not 38 transactions later with a cryptic
# on-chain revert. Two dependencies must be up before forge runs:
#   1. anvil, or there is no chain to deploy to;
#   2. the local IPFS (kubo) node, because `_pinAvatar` pins each token's avatar to it and
#      `LauncherV1.launch` REJECTS an empty metadataURI ("Launcher: avatar required"). The
#      pin script fails SOFT (empty output) when kubo is down, so a stopped Docker/IPFS would
#      otherwise surface as that revert on the very first launch (BODKIN) with no hint why.
if ! cast block-number --rpc-url "${RPC_URL}" >/dev/null 2>&1; then
  echo "ERROR: no anvil reachable at ${RPC_URL}. Start it first with the wrapper" >&2
  echo "       (raises the code-size limit to Robinhood's 96 KB for the ~28 KB FeeHook):" >&2
  echo "       ./scripts/anvil-local.sh" >&2
  exit 1
fi
if ! curl -fsS -X POST "${IPFS_API}/api/v0/version" >/dev/null 2>&1; then
  echo "ERROR: local IPFS (kubo) is not reachable at ${IPFS_API}." >&2
  echo "       Avatars can't be pinned, so the BODKIN launch would revert 'avatar required'." >&2
  echo "       Start Docker, then:  ( cd ../bodkin-launchpad && docker compose up -d )" >&2
  exit 1
fi

echo "==> Deploying DeployLocalV1 (Uniswap V4 core + FeeHook + launcher + Universal Router) to ${RPC_URL}"
# --slow sends ONE transaction at a time, waiting for each receipt before the next.
# Without it forge fires all ~38 at once, and a single one being dropped on the way in
# leaves a NONCE HOLE: every later transaction sits in anvil's `queued` pool forever
# (it can never execute out of order), forge polls eth_getTransactionReceipt for
# receipts that will never exist, and the deploy hangs with no error. Costs a few
# seconds; turns a silent hang into a normal failure.
#
# --gas-estimate-multiplier 200: forge fixes each broadcast tx's gas limit from the
# SIMULATION, but a launch's afterSwap buy&burn is SKIPPED in-simulation (same-block gate)
# and RUNS on the real, block-advancing broadcast — so a dev-buy launch can need more gas
# on-chain than estimated and OOG mid-deploy. Doubling the limit gives ample headroom (free
# on anvil). Real chains are unaffected: wallets estimate each tx fresh.
# --code-size-limit 98304: forge has its OWN EIP-170 check (separate from anvil's), which otherwise
# prompts "contract size limit (28220 > 24576). continue? [y/n]" for our ~28 KB FeeHook. Set it to
# Robinhood's 96 KB so forge stops warning — anvil-local.sh raises the node's limit to match.
forge script script/DeployLocalV1.s.sol:DeployLocalV1 --rpc-url "${RPC_URL}" --broadcast --slow --gas-estimate-multiplier 200 --code-size-limit 98304 -vv

echo "==> Exporting ABIs -> exports/abis/"
node scripts/export-abis.mjs

# BOTH frontends. Each keeps its own copy under src/generated (they are separate
# packages and share nothing), and each imports it at build time — so syncing only one
# leaves the other pointing at contracts that no longer exist on a freshly-restarted
# anvil, with no error until a call silently returns nothing.
echo "==> Syncing ABIs + addresses (v1.local.json) -> both frontends' src/generated/"
( cd ../bodkin-launchpad && npm run sync-contracts )
( cd ../bodkin-coin-website && npm run sync-contracts )

# NOTE: there is no set-avatars step — V1 token metadata is IMMUTABLE (written once by
# BodkinERC20.initialize; the contract has no editor at all). The deploy pins a real
# avatar per token up front via `_pinAvatar` (vm.ffi -> scripts/pin-demo-avatar.mjs).
#
# THE LOCAL IPFS NODE IS REQUIRED, not optional. `LauncherV1.launch` rejects an empty
# metadataURI ("Launcher: avatar required"), and the pin script exits 0 with empty
# output when kubo is unreachable — so a stopped IPFS container makes the FIRST launch
# (BODKIN) revert and takes the whole deploy down with it. Start it before running this.

echo ""
echo "==> Done. Next:"
echo "    1. RESTART THE INDEXER — every contract address just changed, so its cached"
echo "       config is stale. It recovers from the chain reset on its own: the cursor in"
echo "       indexer_state (latest_height) is now ahead of a freshly-restarted anvil, and"
echo "       the indexer detects that, logs it, and rewinds instead of silently idling."
echo "       If you also want a clean feed, wipe the CHAIN-DERIVED tables — tokens,"
echo "       trades, balances, wallet_tokens, indexer_state — which re-indexing rebuilds."
echo "       comments/profiles/sessions are NOT derivable: never drop those."
echo "       Elasticsearch prunes tokens that no longer exist by itself, one reindex tick"
echo "       (~30s) after the indexer comes back."
echo "    2. cd ../bodkin-launchpad && nvm use 20 && npm run dev      # dev server on :5175"
