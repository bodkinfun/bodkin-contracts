#!/usr/bin/env bash
# Deploy the Bodkin v1 launchpad (script/DeployV1.s.sol) to Robinhood Chain.
#
#   bin/deploy.sh testnet                    # dry-run: simulate only, send nothing
#   bin/deploy.sh testnet broadcast          # send the transactions
#   bin/deploy.sh mainnet broadcast          # (prompts for a typed confirmation first)
#   bin/deploy.sh testnet broadcast verify   # also verify sources on the explorer
#
# Config (see .env.example) comes from ONE file: $CONTRACTS_ENV, else .env.<net>, else .env — see
# bin/_env.sh. The wrapper exports it, so forge and the --verify flag below see the same values.
set -euo pipefail
cd "$(dirname "$0")/.."
. bin/_env.sh

net="${1:-}"
mode="${2:-dry}"
verify="${3:-}"

case "$net" in
  testnet|mainnet) ;;
  *) echo "usage: $0 <testnet|mainnet> [broadcast] [verify]" >&2; exit 1 ;;
esac
load_contracts_env "$net"
case "$net" in
  testnet) rpc="robinhood_testnet"; verifier_url="${ROBINHOOD_TESTNET_VERIFIER_URL:-}" ;;
  mainnet) rpc="robinhood_mainnet"; verifier_url="${ROBINHOOD_MAINNET_VERIFIER_URL:-}" ;;
esac

# --code-size-limit: forge's OWN EIP-170 check inside the simulation, separate from the chain's.
# Robinhood Chain allows 96 KB of runtime code (FeeHook ~36 KB, LauncherV1 ~26 KB fit), but the
# check also applies to the DeployV1 SCRIPT contract itself, which forge deploys into the
# simulated EVM and which is ~105 KB — newer forge (1.8+) fails it with
# "EvmError: CreateContractSizeLimit" before a single real tx is simulated. 256 KB clears the
# script; the real contracts are bounded by the chain, not by this flag (a genuinely oversized
# contract still reverts at broadcast, and the dry-run prints every deployed size).
args=(script/DeployV1.s.sol:DeployV1 --rpc-url "$rpc" --code-size-limit 262144 -vvv)

case "$mode" in
  dry) ;; # simulation only — the default, and always safe
  broadcast)
    if [ "$net" = "mainnet" ]; then
      printf 'About to BROADCAST to Robinhood MAINNET (real funds) with %s, label "%s". Type "deploy mainnet" to continue: ' \
        "$CONTRACTS_ENV_FILE" "${DEPLOY_LABEL:-<unset>}"
      read -r confirm
      [ "$confirm" = "deploy mainnet" ] || { echo "aborted." >&2; exit 1; }
    fi
    # --slow sends the dependent txs one at a time, waiting for each receipt.
    args+=(--broadcast --slow)
    if [ "$verify" = "verify" ]; then
      if [ -n "$verifier_url" ]; then
        # Blockscout-style explorer (no API key). If Robinhood's explorer is Etherscan-style,
        # swap `--verifier blockscout` for `--verifier etherscan --etherscan-api-key <key>`.
        args+=(--verify --verifier blockscout --verifier-url "$verifier_url")
      else
        echo "note: 'verify' requested but ROBINHOOD_$(_upper "$net")_VERIFIER_URL is unset in $CONTRACTS_ENV_FILE — skipping verification." >&2
      fi
    fi
    ;;
  *) echo "unknown mode '$mode' (expected 'broadcast', or omit for a dry-run)" >&2; exit 1 ;;
esac

# Preflight: does this RPC still have the state the run will ask it for? `forge script` pins its fork
# at ONE block and then fetches lazily, so every account and slot the script touches for the first
# time — a fresh pool's ticks, the address a CREATE2 is about to land on — is fetched from the node at
# THAT block, minutes after it was pinned. A node that keeps only the last few hundred blocks answers
# `historical state … is not available`, and what the operator sees is an undecodable `EvmError:
# Revert` or a `FatalExternalError` deep inside the trace, with the real reason printed above it and
# easy to miss. One endpoint cost an evening exactly this way: it served state 50 blocks back and
# nothing at 200, i.e. under a minute of history against a three-minute deploy.
#
# The depth is measured in TIME, not blocks, because the chains differ: Robinhood testnet runs at
# 0.194 s/block and mainnet at 0.101 s, so one fixed block count means two different windows (a
# 2000-block rule was 6.5 min on one and 3.4 on the other, against a deploy that takes ~3). Ask for
# 5 minutes of history and derive the block count from the chain itself. Slot 0 of the PoolManager:
# a real, live contract this deploy depends on anyway. Set SKIP_RPC_STATE_CHECK=1 to bypass (e.g. a
# local anvil, which has no history and needs none).
if [ -z "${SKIP_RPC_STATE_CHECK:-}" ] && [ -n "${POOL_MANAGER:-}" ] && command -v cast >/dev/null; then
  _head="$(cast block-number --rpc-url "$rpc" 2>/dev/null || true)"
  case "$_head" in
    ''|*[!0-9]*) echo "note: could not read the head block from $rpc — skipping the RPC state check" >&2 ;;
    *)
      # Block time from a 1000-block span, then the count that covers 5 minutes. A chain too young
      # for the span, or an unreadable timestamp, falls back to 2000 blocks rather than skipping.
      _need=2000
      _t1="$(cast block "$_head" --field timestamp --rpc-url "$rpc" 2>/dev/null || true)"
      _t0="$(cast block "$((_head - 1000))" --field timestamp --rpc-url "$rpc" 2>/dev/null || true)"
      case "$_t1$_t0" in
        ''|*[!0-9]*) ;;
        *) [ "$_t1" -gt "$_t0" ] && _need=$(( 300 * 1000 / (_t1 - _t0) )) ;;
      esac
      [ "$_need" -lt 500 ] && _need=500
      _probe=$((_head - _need))
      if [ "$_probe" -gt 0 ] && ! cast storage "$POOL_MANAGER" 0 --rpc-url "$rpc" --block "$_probe" >/dev/null 2>&1; then
        echo "error: this RPC does not serve state $_need blocks back (~5 min); a forked deploy needs ~3." >&2
        echo "       It answers for the head but forgets almost immediately, so the run will die partway" >&2
        echo "       through on whatever it touches first — as an undecodable revert, not as a timeout." >&2
        echo "       Point ROBINHOOD_$(_upper "$net")_RPC_URL in $CONTRACTS_ENV_FILE at a provider that" >&2
        echo "       keeps history, then re-run. To test any endpoint by hand:" >&2
        echo "       cast storage $POOL_MANAGER 0 --rpc-url <url> --block \$(( \$(cast block-number --rpc-url <url>) - $_need ))" >&2
        exit 1
      fi
      echo "rpc: serves state $_need blocks back (~5 min) — enough for this deploy" >&2
      ;;
  esac
fi

# Preflight: BODKIN's address is mined for the `b0d41` suffix by script/DeployV1.s.sol calling
# `node scripts/mine-vanity-salt.mjs` over ffi, and that miner imports viem. On a deploy box whose
# `npm ci` predates viem landing in package.json the import fails, and forge reports it as an opaque
# ffi failure in the middle of the simulation. Say it plainly here instead, while nothing has been
# sent. BODKIN_SALT pins a pre-mined salt and skips the miner entirely, so only check when it is unset.
if [ -z "${BODKIN_SALT:-}" ]; then
  if ! command -v node >/dev/null; then
    echo "error: node is not installed on this box, and DeployV1 mines BODKIN's vanity salt with it." >&2
    echo "       install node, or pin a pre-mined salt: BODKIN_SALT=0x… in $CONTRACTS_ENV_FILE" >&2
    exit 1
  fi
  if ! node -e "import('viem').then(()=>0,()=>process.exit(1))" 2>/dev/null; then
    echo "error: viem does not resolve from $(pwd) — scripts/mine-vanity-salt.mjs cannot mine BODKIN's salt." >&2
    echo "       run:  npm ci        (in this directory; viem is a dependency since the vanity-salt move)" >&2
    echo "       or pin a pre-mined salt: BODKIN_SALT=0x… in $CONTRACTS_ENV_FILE" >&2
    exit 1
  fi
fi

echo "+ forge script ${args[*]}"
forge script "${args[@]}"

# A broadcast wrote exports/v1.<DEPLOY_LABEL|chainId>.json. The ABIs are network-independent but
# the frontends import them from the same exports dir, so refresh them and sync BOTH apps to this
# deploy right here (same as scripts/deploy-v1-local.sh does for anvil) — each app keeps its own
# copy under src/generated and builds from it, so a forgotten sync means a frontend pointing at a
# CreatorNFT / launcher / hook that exists on another network. The label the sync uses is the one
# the exports file got: DEPLOY_LABEL, else the chain id.
if [ "$mode" = "broadcast" ]; then
  label="${DEPLOY_LABEL:-}"
  if [ -z "$label" ]; then
    label="$(cast chain-id --rpc-url "$rpc" 2>/dev/null || true)"
  fi
  # Re-check the deployment against the LIVE chain before anything is synced from it. Every `require`
  # inside DeployV1 ran in forge's simulation only — forge simulates the script, records each call's
  # calldata and broadcasts it afterwards — so anything that landed in between (most sharply, a
  # stranger's launch() shifting which address the recorded setBodkinPool carries) would pass there and
  # be wrong here. The wiring is one-shot and the owners are renounced, so this is the last moment it
  # can be caught. Read-only; it fails loudly and stops the sync.
  echo "==> Verifying the live deployment (script/VerifyV1.s.sol)"
  forge script script/VerifyV1.s.sol:VerifyV1 --rpc-url "$rpc" --code-size-limit 262144
  echo "==> Exporting ABIs -> exports/abis/"
  node scripts/export-abis.mjs
  for app in bodkin-launchpad bodkin-coin-website; do
    if [ -d "../$app/node_modules" ]; then
      echo "==> Syncing ABIs + addresses (v1.${label}.json) -> ../$app/src/generated/"
      ( cd "../$app" && npm run -s sync-contracts -- --label "$label" )
    else
      echo "note: ../$app has no node_modules — sync it yourself: cd ../$app && npm install && npm run sync-contracts -- --label $label" >&2
    fi
  done
  echo ""
  echo "==> Deployed and synced (label = ${label}). Next:"
  echo "    1. frontends:  set VITE_ROBINHOOD_CHAIN_ID / VITE_ROBINHOOD_RPC_URL / VITE_ROBINHOOD_EXPLORER in each app's .env,"
  echo "                   then build (deploy/upload-frontend.sh ${net} … re-syncs with this label before building)"
  echo "    2. backend:    EXPORTS_FILE=v1.${label}.json + CHAIN_ID in each box's .env (see deploy/RUNBOOK.md),"
  echo "                   START_BLOCK = the deployBlock printed above (read from the exports file when unset)"
  echo "    3. resolver:   EXPORTS_JSON=../contracts/exports/v1.${label}.json + RPC_URL + RESOLVER_PRIVATE_KEY"
fi
