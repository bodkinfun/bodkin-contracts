// Exports ABIs for the frontends to exports/abis/<Name>.json.
// - Project contracts: read from out/<Name>.sol/<Name>.json (forge build output)
// - ERC20: a minimal hand-rolled ABI (works for BODKIN and every launched token)
//
// No vendored-artifact section any more: the Uniswap-V3 model is gone, so nothing needs
// UniswapV3Pool/NFPM/SwapRouter/QuoterV2, and V4 core is compiled in-repo.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const outDir = join(root, "exports", "abis");
mkdirSync(outDir, { recursive: true });

const forgeContracts = [
  "CreatorNFT",
  // single-sided Uniswap V4 model (fee hook + launcher). Swaps now route through the Uniswap
  // Universal Router (+ Permit2), so there is no bespoke swap contract to export an ABI for —
  // the frontend + sim encode the router's `execute(...)` calldata directly.
  "FeeHook",
  "LauncherV1",
  // V4 read-only lenses for the frontend route-finder
  "V4Quoter",
  "StateView",
];

for (const name of forgeContracts) {
  const artifact = JSON.parse(
    readFileSync(join(root, "out", `${name}.sol`, `${name}.json`), "utf8")
  );
  writeFileSync(join(outDir, `${name}.json`), JSON.stringify(artifact.abi, null, 2) + "\n");
  console.log(`exported ${name}.json (${artifact.abi.length} entries)`);
}

// Minimal ERC20 ABI (transfer/approve/allowance/balanceOf/totalSupply/metadata + events)
const erc20 = [
  { type: "function", name: "name", inputs: [], outputs: [{ name: "", type: "string" }], stateMutability: "view" },
  { type: "function", name: "symbol", inputs: [], outputs: [{ name: "", type: "string" }], stateMutability: "view" },
  { type: "function", name: "decimals", inputs: [], outputs: [{ name: "", type: "uint8" }], stateMutability: "view" },
  { type: "function", name: "totalSupply", inputs: [], outputs: [{ name: "", type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "balanceOf", inputs: [{ name: "account", type: "address" }], outputs: [{ name: "", type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "allowance", inputs: [{ name: "owner", type: "address" }, { name: "spender", type: "address" }], outputs: [{ name: "", type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "approve", inputs: [{ name: "spender", type: "address" }, { name: "value", type: "uint256" }], outputs: [{ name: "", type: "bool" }], stateMutability: "nonpayable" },
  { type: "function", name: "transfer", inputs: [{ name: "to", type: "address" }, { name: "value", type: "uint256" }], outputs: [{ name: "", type: "bool" }], stateMutability: "nonpayable" },
  { type: "function", name: "transferFrom", inputs: [{ name: "from", type: "address" }, { name: "to", type: "address" }, { name: "value", type: "uint256" }], outputs: [{ name: "", type: "bool" }], stateMutability: "nonpayable" },
  { type: "event", name: "Transfer", inputs: [{ name: "from", type: "address", indexed: true }, { name: "to", type: "address", indexed: true }, { name: "value", type: "uint256", indexed: false }], anonymous: false },
  { type: "event", name: "Approval", inputs: [{ name: "owner", type: "address", indexed: true }, { name: "spender", type: "address", indexed: true }, { name: "value", type: "uint256", indexed: false }], anonymous: false },
];
writeFileSync(join(outDir, "ERC20.json"), JSON.stringify(erc20, null, 2) + "\n");
console.log(`exported ERC20.json (${erc20.length} entries)`);
