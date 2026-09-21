#!/usr/bin/env node
/**
 * Mine a `b0d41` vanity salt for a launch, so the deploy's OWN tokens — BODKIN on every network, and
 * BODKIN and the demos — carry the platform suffix exactly like create-form and simulated
 * launches. Called from DeployV1 / DeployLocalV1 via `vm.ffi`; the ~1/1e6 search cannot be done in
 * the Solidity script (an on-chain loop of a million keccaks), so it runs here off-chain.
 *
 * ACROSS THE CORES, because this runs in the middle of a forked deploy simulation and the pause is
 * not a fixed cost: the search length is geometric, and five runs of one job measured 2.2s, 156.4s,
 * 34.5s, 11.9s and 98.3s. A forked block's state has a shelf life, and how long varies
 * ENORMOUSLY by endpoint — measured the same minute on the same chain: a public Robinhood RPC served
 * 6-7k blocks (~20 min), while the endpoint a deploy box actually reached served ~100 (~20 SECONDS).
 * A deploy that stalls past it dies on the next fetch of an untouched account, as an undecodable
 * revert that looks nothing like the timeout it is. Every core searching a disjoint random region
 * cuts the tail that causes that; bin/deploy.sh checks the endpoint before it starts.
 *
 * Usage:  node scripts/mine-vanity-salt.mjs <sender> <launcher> <impl> [minAddress]
 *   sender   — the launch() caller (the salt is namespaced to it, like LauncherV1)
 *   launcher — the LauncherV1 (CREATE2 deployer of the clone)
 *   impl     — the clone implementation (BodkinERC20)
 *   min      — a USDC pool's numeraire: the token must sort ABOVE it (omit / 0x0 for ETH)
 *
 * Env: VANITY_SUFFIX overrides the suffix, MINE_WORKERS the core count (default: cores - 1).
 *
 * Prints ONLY the `0x…` 32-byte salt on stdout — vm.ffi decodes that hex straight to bytes32.
 * Anything else it has to say goes to stderr, which vm.ffi ignores.
 */
import os from 'node:os'
import { Worker } from 'node:worker_threads'
import { cloneInitCodeHash, mineVanitySalt } from './lib/mine.mjs'

const [sender, launcher, impl, minRaw = ''] = process.argv.slice(2)
const suffix = (process.env.VANITY_SUFFIX ?? 'b0d41').toLowerCase()
const min = minRaw && !/^0x0+$/i.test(minRaw) ? minRaw : null

// Derive the init-code hash ONCE here rather than in every worker — it is the same for all of them.
const job = { id: 1, sender, launcher, initHash: cloneInitCodeHash(impl), suffix, min }

const cores = Math.max(1, (os.cpus()?.length ?? 1) - 1)
const count = Math.max(1, Number(process.env.MINE_WORKERS || cores))

// A single worker would only add thread-spawn latency to a search this parent could run itself.
if (count === 1) {
  process.stdout.write(mineVanitySalt(job))
} else {
  const workerUrl = new URL('./lib/mine-worker.mjs', import.meta.url)
  const workers = []
  let settled = false

  /** First answer wins; the losers are mid-search and would otherwise keep the process alive. */
  const finish = (salt, code = 0) => {
    if (settled) return
    settled = true
    if (salt) process.stdout.write(salt)
    for (const w of workers) w.terminate()
    process.exit(code)
  }

  let dead = 0
  for (let i = 0; i < count; i++) {
    const w = new Worker(workerUrl)
    workers.push(w)
    w.on('message', ({ salt }) => finish(salt))
    // One worker dying is survivable — the others are searching the same space. All of them dying
    // is not, and must not look like a salt of zero bytes to the caller.
    w.on('error', (err) => {
      if (++dead === count) {
        process.stderr.write(`mine-vanity-salt: every worker failed (${err.message})\n`)
        finish(null, 1)
      }
    })
    w.postMessage(job)
  }
}
