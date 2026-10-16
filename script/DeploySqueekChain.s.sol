// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {SqueekChainToken} from "../src/SqueekChainToken.sol";

/// @title Deploy script for SqueekChain (SQK)
/// @notice For local forks and rehearsals only. The production launch is performed by IMD's
///         deployer through ProjectFactory.launchCustom from the attested bytecode; nobody runs
///         this script against Ethereum mainnet for the launch, and it signs nothing by itself.
/// @dev The token takes no constructor arguments, so there is no configuration to pass. `deploy()`
///      is the function tests call directly; `run()` only wraps it in a broadcast whose sender is
///      whatever the forge CLI was given (`--private-key`, `--account`, or `--sender`). The script
///      reads no environment variables.
contract DeploySqueekChain is Script {
    /// @notice Deploys the token. The caller of this function (inside a broadcast, the broadcast
    ///         sender) becomes the deployer and receives the whole supply.
    function deploy() public returns (SqueekChainToken token) {
        token = new SqueekChainToken();
    }

    /// @notice Broadcast entry point: `forge script script/DeploySqueekChain.s.sol --broadcast ...`.
    function run() external returns (SqueekChainToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
