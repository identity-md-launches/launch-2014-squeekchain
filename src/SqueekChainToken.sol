// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title SqueekChain (SQK)
/// @notice A plain, fixed-supply ERC-20. The whole supply of 1,000,000,000 SQK (18 decimals) is
///         minted once, in the constructor, to the deployer (`msg.sender`). At launch the deployer
///         is IMD's ProjectFactory, which pays the supply out: the swarm's share to the launch's
///         MerkleDistributor, the requester's pool share into the Uniswap v4 pool, and the
///         remainder to the requester's address.
/// @dev Deliberately minimal:
///      - no owner, no roles, no pause, no blocklist, no freeze, no seize;
///      - no mint function of any kind after the constructor, so the supply can never grow;
///      - no fee, tax or burn on transfer, so every launch flow moves exactly what it says;
///      - no external calls, no delegatecall, no selfdestruct, no proxy, no upgrade path.
///      Holders may still burn by sending to an address nobody controls, which is their business;
///      the contract exposes no burn function because none was requested.
///      The contract name (`SqueekChainToken`) is the launch's Solidity identifier and is distinct
///      from the token's `name()` and `symbol()`.
contract SqueekChainToken is ERC20 {
    /// @notice Human-readable token name returned by `name()`.
    string public constant TOKEN_NAME = "SqueekChain";

    /// @notice Ticker returned by `symbol()`.
    string public constant TOKEN_SYMBOL = "SQK";

    /// @notice Number of decimals, the ERC-20 default of 18.
    uint8 public constant TOKEN_DECIMALS = 18;

    /// @notice Whole-token supply before decimals: one billion.
    uint256 public constant SUPPLY_WHOLE_TOKENS = 1_000_000_000;

    /// @notice The fixed total supply in minor units: 1,000,000,000 * 10^18 = 1e27.
    ///         This is the value the launch manifest records as `token.totalSupply`.
    uint256 public constant TOTAL_SUPPLY = SUPPLY_WHOLE_TOKENS * 10 ** TOKEN_DECIMALS;

    /// @notice Mints the entire fixed supply to the deployer. Takes no arguments and calls no
    ///         other contract, so it deploys on an empty chain and through the factory's CREATE2.
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
