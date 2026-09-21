#!/usr/bin/env bash
#
# Verify a SINGLE contract by address on Robinhood Chain's Blockscout — for one-offs the whole-deploy
# `bin/verify.sh` can't cover: a specific address, a re-verify of just one contract, or a launched
# token if you ever want to submit it explicitly (BodkinERC20 clones are minimal proxies, so Blockscout
# usually auto-recognises them against the verified implementation — you rarely need this for clones).
#
# Compiler/optimizer/via_ir are taken from foundry.toml automatically (must match the deploy).
#
#   bin/verify-one.sh <testnet|mainnet> <address> <src/Path.sol:Name> [ctorArgsHex]
#
# Examples:
#   bin/verify-one.sh mainnet 0xLauncher… src/launchpad/v1/LauncherV1.sol:LauncherV1 \
#       $(cast abi-encode "constructor(address,address,address,address,address,address,address,(address,uint256)[])" \
#         $MANAGER $HOOK $NFT $IMPL $TEAM $RESOLVER $DEPLOYER_WALLET "[(0x0,1500000000000000000),($USDC,3000000000)]")
#   bin/verify-one.sh mainnet 0xImpl… src/launchpad/BodkinERC20.sol:BodkinERC20        # no-arg ctor
#
# The constructor arg types come from each contract's constructor (see DeployV1.s.sol for the values):
#   FeeHook(address manager, ICreatorNFT nft, address team, address usdc, address weth, address deployer)
#   LauncherV1(address manager, IHooks hook, CreatorNFT nft, address impl, address team, address resolver, address deployer, StartFdv[] fdvs)
#   CreatorNFT(string baseUri)   V4Quoter(address manager)   StateView(address manager)   BodkinERC20()  # none
set -euo pipefail
cd "$(dirname "$0")/.."
. bin/_env.sh

net="${1:-}"; addr="${2:-}"; target="${3:-}"; ctor="${4:-}"
[ -n "$net" ] && [ -n "$addr" ] && [ -n "$target" ] \
  || { echo "usage: $0 <testnet|mainnet> <address> <src/File.sol:Name> [ctorArgsHex]" >&2; exit 1; }
case "$net" in testnet|mainnet) load_contracts_env "$net" ;; esac

case "$net" in
  testnet) chain_id=46630; url="${ROBINHOOD_TESTNET_VERIFIER_URL:-}" ;;
  mainnet) chain_id=4663;  url="${ROBINHOOD_MAINNET_VERIFIER_URL:-https://robinhoodchain.blockscout.com/api/}" ;;
  *) echo "net must be testnet|mainnet" >&2; exit 1 ;;
esac
[ -n "$url" ] || { echo "set ROBINHOOD_$(_upper "$net")_VERIFIER_URL in $CONTRACTS_ENV_FILE" >&2; exit 1; }

verifier="${ROBINHOOD_VERIFIER_TYPE:-blockscout}"
key_args=();  [ -n "${ROBINHOOD_VERIFIER_KEY:-}" ] && key_args=(--etherscan-api-key "$ROBINHOOD_VERIFIER_KEY")
ctor_args=(); [ -n "$ctor" ] && ctor_args=(--constructor-args "$ctor")

echo "+ verify-contract $addr ($target) on $net (chain $chain_id) via $verifier"
exec forge verify-contract "$addr" "$target" \
  --chain-id "$chain_id" \
  --verifier "$verifier" --verifier-url "$url" "${key_args[@]}" \
  "${ctor_args[@]}" \
  --watch
