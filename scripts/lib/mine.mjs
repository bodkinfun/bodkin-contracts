// Shared CREATE2 vanity-salt miner — used by the sim's worker pool AND the DeployLocalV1
// FFI miner, so every path (create form, simulator, deploy) derives the address the SAME
// way LauncherV1 does and every launched token ends in the platform suffix.
import { concatHex, getAddress, keccak256, pad, toHex } from 'viem'
import { webcrypto } from 'node:crypto'

/** EIP-1167 minimal-proxy init-code hash for `Clones.cloneDeterministic(impl)`. */
export const cloneInitCodeHash = (impl) =>
  keccak256(concatHex(['0x3d602d80600a3d3981f3363d3d373d3d3d363d73', impl, '0x5af43d82803e903d91602b57fd5bf3']))

/** Address of the clone at `salt`. Deployer is the launcher; hash MUST match LauncherV1. */
const create2Addr = (launcher, effectiveSalt, initHash) =>
  getAddress('0x' + keccak256(concatHex(['0xff', launcher, effectiveSalt, initHash])).slice(-40))

/**
 * Mine a salt whose LauncherV1 clone address ends in `suffix` (and, when `min` is given,
 * sorts strictly above it — the launcher's token > numeraire invariant for USDC pools).
 * The salt is namespaced per caller exactly as LauncherV1 does: effective = keccak256(
 * sender, salt). Pass `initHash` to skip re-deriving it from `impl`. Returns the 0x…32-byte
 * salt. Neither constraint set → it returns after one iteration (nothing to search).
 */
export function mineVanitySalt({ sender, launcher, impl, initHash, suffix = '', min = null }) {
  const h = initHash ?? cloneInitCodeHash(impl)
  const s = (suffix || '').toLowerCase()
  const m = min ? min.toLowerCase() : null
  // Random 224-bit start so two searches never walk the same salts.
  let base = 0n
  for (const b of webcrypto.getRandomValues(new Uint8Array(28))) base = (base << 8n) | BigInt(b)
  for (let i = 0n; ; i++) {
    const salt = pad(toHex(base + i), { size: 32 })
    const effective = keccak256(concatHex([sender, salt]))
    const addr = create2Addr(launcher, effective, h).toLowerCase()
    if (s && !addr.endsWith(s)) continue
    if (m && !(addr > m)) continue
    return salt
  }
}
