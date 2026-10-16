// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SqueekChainToken} from "../src/SqueekChainToken.sol";

/// @notice Drives the token with random transfers and approvals from a fixed set of actors so the
///         invariant test can check that the supply never changes and balances always sum to it.
contract SqueekChainHandler is Test {
    SqueekChainToken public immutable token;
    address[] public actors;

    constructor(SqueekChainToken token_, address deployer) {
        token = token_;
        actors.push(deployer);
        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xCA401));
        actors.push(address(0xDA7E));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        token.transfer(to, amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        vm.prank(owner);
        token.approve(spender, amount);
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 cap = token.balanceOf(owner);
        uint256 allowed = token.allowance(owner, spender);
        if (allowed < cap) cap = allowed;
        amount = bound(amount, 0, cap);
        vm.prank(spender);
        token.transferFrom(owner, to, amount);
    }
}

contract SqueekChainTokenInvariantTest is Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 * 1e18;
    address internal constant DEPLOYER = address(0xFAC7);

    SqueekChainToken internal token;
    SqueekChainHandler internal handler;

    function setUp() public {
        vm.prank(DEPLOYER);
        token = new SqueekChainToken();
        handler = new SqueekChainHandler(token, DEPLOYER);
        targetContract(address(handler));
    }

    function invariant_totalSupplyIsFixed() public view {
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function invariant_balancesSumToSupply() public view {
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, EXPECTED_SUPPLY);
    }
}
