// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title CanonicalTiers
/// @notice The canonical Uniswap fee ↔ tickSpacing pairs the launchpad accepts for
///         plain (hook-less) external pools. Shared so the swap router (SwapZapV1)
///         and the launcher's payout-pool validation (LauncherV1) can never drift
///         apart: rejecting off-spec tiers stops a caller from smuggling a bespoke
///         or spoofed pool into either the swap path or a creator's fee conversion.
library CanonicalTiers {
    function isCanonical(uint24 fee, int24 tickSpacing) internal pure returns (bool) {
        return (fee == 100 && tickSpacing == 1) || (fee == 500 && tickSpacing == 10)
            || (fee == 3000 && tickSpacing == 60) || (fee == 10000 && tickSpacing == 200);
    }
}
