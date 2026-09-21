#!/usr/bin/env bash
#
# Verify the deployed Bodkin v1 contracts on Robinhood Chain's explorer — STANDALONE (after the fact),
# separate from the deploy. Use it when you deployed without `verify`, or a deploy-time verification
# failed and you want to retry (already-verified contracts are skipped).
#
# Robinhood Chain uses BLOCKSCOUT (robinhoodchain.blockscout.com, chain 4663); Etherscan does NOT index
# it, and Blockscout needs no API key. It re-verifies the WHOLE last deployment from its broadcast —
# addresses AND constructor args are read from broadcast/DeployV1.s.sol/<chainId>/run-latest.json — so
# run it after `bin/deploy.sh <net> broadcast`. Compiler/optimizer/via_ir come from foundry.toml.
#
#   bin/verify.sh testnet
#   bin/verify.sh mainnet
#
# Config from the same file the deploy used — $CONTRACTS_ENV, else .env.<net>, else .env (bin/_env.sh):
# ROBINHOOD_{TESTNET,MAINNET}_VERIFIER_URL, ROBINHOOD_VERIFIER_TYPE,
# ROBINHOOD_VERIFIER_KEY (only if your explorer ever requires one — Blockscout does not), and the
# deployer's PRIVATE_KEY or MNEMONIC: forge 1.3+ resumes only with --broadcast and a wallet, though a
# COMPLETE broadcast has nothing left to send — the script checks that before it runs.
# Run it where the broadcast ran (broadcast/ is local to that box), with the SAME src/ as the deploy.
set -euo pipefail
cd "$(dirname "$0")/.."
. bin/_env.sh

net="${1:-}"
case "$net" in testnet|mainnet) load_contracts_env "$net" ;; esac
case "$net" in
  testnet) rpc="robinhood_testnet"; chain_id=46630
           url="${ROBINHOOD_TESTNET_VERIFIER_URL:-}" ;;
  mainnet) rpc="robinhood_mainnet"; chain_id=4663
           url="${ROBINHOOD_MAINNET_VERIFIER_URL:-https://robinhoodchain.blockscout.com/api/}" ;;
  *) echo "usage: $0 <testnet|mainnet>" >&2; exit 1 ;;
esac
[ -n "$url" ] || { echo "verifier URL for $net is unset — set ROBINHOOD_$(_upper "$net")_VERIFIER_URL in $CONTRACTS_ENV_FILE" >&2; exit 1; }

verifier="${ROBINHOOD_VERIFIER_TYPE:-blockscout}"
key_args=(); [ -n "${ROBINHOOD_VERIFIER_KEY:-}" ] && key_args=(--etherscan-api-key "$ROBINHOOD_VERIFIER_KEY")

bc="broadcast/DeployV1.s.sol/$chain_id/run-latest.json"
[ -f "$bc" ] || { echo "no broadcast at $bc — deploy first: bin/deploy.sh $net broadcast" >&2; exit 1; }

# Newer forge (1.3+) refuses `--resume` without `--broadcast`, and on resume it does not run the
# script again, so it needs the deployer wallet on the command line even when nothing is left to send.
# `--resume --broadcast` SENDS whatever the recorded broadcast did not get through — so first prove
# the broadcast is COMPLETE (every recorded transaction has a receipt). Then there is nothing to send
# and this only verifies; a partial deploy is refused here rather than silently finished.
complete="$(
  node -e 'const r=require(process.argv[1]); const t=r.transactions.length, n=r.receipts.length;
           console.log(t > 0 && n >= t ? "yes" : `no (${n} of ${t} transactions confirmed)`)' "$PWD/$bc" 2>/dev/null \
  || python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); t=len(r["transactions"]); n=len(r["receipts"]); print("yes" if t and n>=t else f"no ({n} of {t} transactions confirmed)")' "$bc" 2>/dev/null \
  || echo "unknown (needs node or python3 to read $bc)"
)"
if [ "$complete" != "yes" ]; then
  echo "the last $net broadcast is not complete: $complete" >&2
  echo "refusing: resuming it would SEND the missing transactions. Inspect $bc and finish the deploy deliberately." >&2
  exit 1
fi

# The same wallet DeployV1 broadcast from (script/DeployV1.s.sol _deployerKey): PRIVATE_KEY wins,
# else MNEMONIC + MNEMONIC_INDEX. Never echoed.
if [ -n "${PRIVATE_KEY:-}" ]; then
  wallet_args=(--private-key "$PRIVATE_KEY")
elif [ -n "${MNEMONIC:-}" ]; then
  wallet_args=(--mnemonics "$MNEMONIC" --mnemonic-indexes "${MNEMONIC_INDEX:-0}")
else
  echo "set PRIVATE_KEY or MNEMONIC in $CONTRACTS_ENV_FILE — forge needs the deployer wallet to resume (nothing is sent)" >&2
  exit 1
fi

echo "+ verifying $net deployment (chain $chain_id) via $verifier @ $url (broadcast complete — nothing will be sent)"
# --resume replays the recorded broadcast; with every receipt present it sends NOTHING, and --verify
# submits the sources + constructor args for each contract the broadcast deployed.
exec forge script script/DeployV1.s.sol:DeployV1 \
  --rpc-url "$rpc" \
  --resume --broadcast "${wallet_args[@]}" \
  --verify --verifier "$verifier" --verifier-url "$url" "${key_args[@]}" \
  -vvv
