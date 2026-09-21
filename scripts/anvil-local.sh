#!/usr/bin/env bash
# Launch a local anvil that behaves like Robinhood Chain.
#
# Robinhood Chain's runtime bytecode limit is 96 KB (init code 192 KB), NOT Ethereum's EIP-170
# 24,576 B. Anvil defaults to the EIP-170 limit, so our FeeHook (~28 KB with autocompound + the
# sandwich-hardening) would fail its CREATE2 deploy locally ("max code size exceeded") even though
# it deploys fine on Robinhood. Raising the limit to 96 KB makes anvil mirror the real chain — and
# still flags anything that would genuinely exceed Robinhood's own limit.
#
# --prune-history / --transaction-block-keeper bound anvil's in-RAM history for the long sim runs
# (keep N > the indexer's block lag). Pass any extra flags through: ./anvil-local.sh --host 0.0.0.0
exec "${HOME}/.foundry/bin/anvil" \
  --code-size-limit 98304 \
  --prune-history \
  --transaction-block-keeper 50000 \
  --accounts 66 \
  "$@"
