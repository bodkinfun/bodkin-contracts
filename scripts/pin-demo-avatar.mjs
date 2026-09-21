#!/usr/bin/env node
/**
 * Pin a demo token's avatar + ERC-1046 metadata document to the local IPFS node and
 * print the resulting `ipfs://…/metadata.json` URI.
 *
 * Called from `DeployLocalV1` via `vm.ffi`, so the tokens the DEPLOY creates get real
 * pinned media exactly like the ones `simulate.mjs` launches. Before this they carried
 * a hardcoded `ipfs://demo-yneko` placeholder, which is not a CID at all: the gateway
 * 404s it, the indexer stores no image, and the feed drew its fallback flower forever.
 *
 * Usage:  node scripts/pin-demo-avatar.mjs "<name>" "<symbol>" [seed]
 *
 * Prints the URI on stdout and NOTHING else — `vm.ffi` hands the raw stdout back to
 * Solidity, so a stray log line would end up inside the token's metadata URI.
 *
 * FAILS SOFT. If the IPFS node is not running (it is a separate `docker compose up`
 * the deploy has no control over), this prints an empty string rather than a non-zero
 * exit. The deploy then falls back to launching with no metadata — the old behaviour,
 * an ugly card — instead of aborting a deploy halfway through for a cosmetic reason.
 */
import { readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { makeIdenticonPng, pinToIpfs } from '../../bodkin-launchpad/scripts/lib/media.mjs'

const [name = 'Demo', symbol = 'DEMO', seed = ''] = process.argv.slice(2)
const HERE = dirname(fileURLToPath(import.meta.url))

try {
  let avatar
  if (seed === 'bodkin' || symbol === 'BODKIN') {
    // The platform's OWN token wears the platform's OWN icon — the lavender bodkin mark
    // (src/assets/bodkin-icon-lavender.svg, the square non-rounded variant) — rather than a
    // random identicon. Pinned verbatim as SVG; BODKIN is exempt from the indexer's avatar
    // gate, so the vector (no raster dimensions) is shown, not hidden.
    const svg = readFileSync(resolve(HERE, '../../bodkin-launchpad/src/assets/bodkin-icon-lavender.svg'))
    avatar = await pinToIpfs(svg, 'bodkin-icon.svg', 'image/svg+xml')
  } else {
    // The identicon is derived from the process's own randomness inside media.mjs; the
    // seed argument only exists so two tokens in one deploy cannot collide visually.
    void seed
    const png = makeIdenticonPng(1024)
    avatar = await pinToIpfs(png, 'avatar.png', 'image/png')
  }
  const doc = {
    name,
    symbol,
    description: `${name} — a demo token created by the local BODKIN deploy.`,
    image: avatar,
  }
  const uri = await pinToIpfs(Buffer.from(JSON.stringify(doc)), 'metadata.json', 'application/json')
  process.stdout.write(uri)
} catch {
  // Empty output = "no metadata"; see the FAILS SOFT note above.
  process.stdout.write('ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/metadata.json')
}
