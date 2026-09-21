// One CPU's share of a CREATE2 vanity-salt search, off the main thread.
//
// The search is a ~1/1e6 needle hunt whose length is GEOMETRIC, not fixed: five runs of the same
// job here measured 2.2s, 156.4s, 34.5s, 11.9s and 98.3s. Run single-threaded inside a deploy that
// pause is dead time in the middle of a forked simulation, and a fork's pinned block state has a
// shelf life that varies hugely by endpoint — measured 6-7k blocks (~20 min) on one Robinhood RPC
// and ~100 blocks (~20 SECONDS) on another, the same minute. Past it, every fetch of a not-yet-
// touched account fails and the frame dies undecodably. Spreading the search over the cores cuts
// both the mean and, which is what actually bites, the tail.
//
// One message in — { id, sender, launcher, impl | initHash, suffix, min } — one message back —
// { id, salt }. Each worker starts from its own random base (see mineVanitySalt), so N workers
// search N disjoint regions and the first to answer wins; the pool terminates the rest.
import { parentPort } from 'node:worker_threads'
import { mineVanitySalt } from './mine.mjs'

parentPort.on('message', ({ id, sender, launcher, impl, initHash, suffix, min }) => {
  const salt = mineVanitySalt({ sender, launcher, impl, initHash, suffix, min })
  parentPort.postMessage({ id, salt })
})
