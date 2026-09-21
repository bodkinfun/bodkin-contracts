// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployLocalV1} from "../../script/DeployLocalV1.s.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";

/// @notice The simulator's traders must actually hold USDC after the deploy, or every
///         USDC-quoted sim launch reverts in the launcher's transferFrom.
contract DeployFundingTest is Test, DeployLocalV1 {
    function test_TradersAreFundedWithUsdc() public {
        MockUSDC usdc = new MockUSDC(1e30);
        _fundTraders(usdc);
        // Anvil accounts #2 and #9 (the old hardcoded range) still hold USDC, and so does the
        // last of the 64 mnemonic-derived traders (#65) and NOT the one past it (#66).
        assertEq(usdc.balanceOf(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC), 500_000e6, "first trader funded");
        assertEq(usdc.balanceOf(0xa0Ee7A142d267C1f36714E4a8F75612F20a79720), 500_000e6, "trader #9 funded");
        assertEq(usdc.balanceOf(vm.addr(vm.deriveKey(ANVIL_MNEMONIC, 65))), 500_000e6, "last trader (#65) funded");
        assertEq(usdc.balanceOf(vm.addr(vm.deriveKey(ANVIL_MNEMONIC, 66))), 0, "#66 is not a trader");
    }
}
