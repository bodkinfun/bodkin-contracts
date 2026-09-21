# Sourced (not run) by bin/deploy.sh, bin/verify.sh and bin/verify-one.sh, from contracts/.
#
#   load_contracts_env <testnet|mainnet>
#
# Picks ONE env file for the run:
#   1. $CONTRACTS_ENV, when set          (e.g. CONTRACTS_ENV=.env.testnet2 bin/deploy.sh testnet)
#   2. .env.<net>, when it exists        (.env.testnet / .env.mainnet — one file per network)
#   3. .env                              (the single-file setup the RUNBOOK describes)
# and exports it, so the wrapper AND forge see the same values.
#
# forge ALSO loads .env by itself, and it never overrides a variable that is already set. So with a
# per-network file the values in that file win — but a key that only .env sets still leaks into the
# run (an FDV_*, USDC=, FEE_NFT_BASE_URI … from the other network). That is refused here: every key
# .env sets must also be in the chosen file (names are printed, values never are).

_env_keys() {
  sed -n -E 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' "$1" | sort -u
}

load_contracts_env() {
  local net="$1" file=""
  if [ -n "${CONTRACTS_ENV:-}" ]; then
    file="$CONTRACTS_ENV"
    [ -f "$file" ] || { echo "CONTRACTS_ENV=$file does not exist" >&2; exit 1; }
  elif [ -f ".env.$net" ]; then
    file=".env.$net"
  elif [ -f .env ]; then
    file=".env"
  else
    echo "note: no .env.$net and no .env — using only the variables already in this shell" >&2
    CONTRACTS_ENV_FILE="(shell environment)"
    return 0
  fi

  if [ "$file" != ".env" ] && [ "$file" != "./.env" ] && [ -f .env ]; then
    local leaked
    leaked="$(comm -23 <(_env_keys .env) <(_env_keys "$file") | tr '\n' ' ')"
    if [ -n "$leaked" ]; then
      echo "refusing: forge also loads .env by itself, and .env sets keys that $file does not:" >&2
      echo "  $leaked" >&2
      echo "they would leak into this $net run. Move them into $file, or remove .env." >&2
      exit 1
    fi
  fi

  local src="$file"
  case "$src" in /*|./*) ;; *) src="./$src" ;; esac
  set -a
  # shellcheck disable=SC1090
  . "$src"
  set +a
  CONTRACTS_ENV_FILE="$file"
  echo "env: $file" >&2
}

# Upper-case a word without bash 4's ${v^^} (macOS ships bash 3.2).
_upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }
