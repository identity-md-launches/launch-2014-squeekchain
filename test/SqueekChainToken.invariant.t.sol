// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SqueekChainToken} from "../src/SqueekChainToken.sol";

/// @notice Drives successful and rejected calls from a closed set of five holders.
/// @dev The ghost ledger starts from the requested supply and changes only from call inputs,
///      never by copying the token's balances or allowances. A conserved but misdirected transfer
///      therefore fails the per-holder checks even if the sum of balances remains correct.
contract SqueekChainHandler is Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 * 1e18;

    SqueekChainToken public immutable token;
    address[] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    constructor(SqueekChainToken token_, address deployer) {
        token = token_;
        actors.push(deployer);
        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xCA401));
        actors.push(address(0xDA7E));
        expectedBalance[deployer] = EXPECTED_SUPPLY;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = bound(amount, 0, expectedBalance[from]);
        _transfer(from, to, amount);
    }

    /// @dev Pin zero, one minor unit, full-balance and self-transfers throughout each campaign.
    function transferBoundary(uint256 fromSeed, uint256 toSeed, uint256 mode) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 balance = expectedBalance[from];
        mode %= 4;
        uint256 amount = mode == 0 ? 0 : mode == 1 && balance > 0 ? 1 : balance;
        if (mode == 3) to = from;
        _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        vm.prank(from);
        assertTrue(token.transfer(to, amount), "valid transfer must succeed");
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        _approve(owner, spender, amount);
    }

    /// @dev Exercise revocation and both sides of the infinite-allowance sentinel often.
    function approveBoundary(uint256 ownerSeed, uint256 spenderSeed, uint256 mode) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        uint256[5] memory amounts = [uint256(0), 1, EXPECTED_SUPPLY, type(uint256).max - 1, type(uint256).max];
        _approve(owner, spender, amounts[mode % amounts.length]);
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "valid approval must succeed");
        expectedAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 cap = expectedBalance[owner];
        uint256 allowed = expectedAllowance[owner][spender];
        if (allowed < cap) cap = allowed;
        amount = bound(amount, 0, cap);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount), "authorized transfer must succeed");
        expectedBalance[owner] -= amount;
        expectedBalance[to] += amount;
        if (allowed != type(uint256).max) expectedAllowance[owner][spender] -= amount;
    }

    function transferAboveBalance(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 balance = expectedBalance[from];
        amount = bound(amount, balance + 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount));
        vm.prank(from);
        token.transfer(to, amount);
    }

    /// @dev With an infinite approval, overdraw the balance instead of overflowing allowance + 1.
    function transferFromInvalid(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 allowed = expectedAllowance[owner][spender];
        if (allowed == type(uint256).max) {
            uint256 balance = expectedBalance[owner];
            amount = bound(amount, balance + 1, type(uint256).max);
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount)
            );
        } else {
            amount = bound(amount, allowed + 1, type(uint256).max);
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
            );
        }
        vm.prank(spender);
        token.transferFrom(owner, to, amount);
    }

    function transferToZero(uint256 fromSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        amount = bound(amount, 0, expectedBalance[from]);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(from);
        token.transfer(address(0), amount);
    }

    /// @dev The failed transfer must also undo any finite allowance spent before recipient validation.
    function transferFromToZero(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        uint256 cap = expectedBalance[owner];
        uint256 allowed = expectedAllowance[owner][spender];
        if (allowed < cap) cap = allowed;
        amount = bound(amount, 0, cap);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(owner, address(0), amount);
    }

    function approveZero(uint256 ownerSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(owner);
        token.approve(address(0), amount);
    }

    /// @dev Probe the fixed-supply/no-admin boundary between ordinary user operations, including
    ///      calls from the original deployer. All payloads have correctly encoded argument types.
    function privilegedCall(uint256 callerSeed, uint256 holderSeed, uint256 amount, uint256 mode) external {
        address caller = actors[callerSeed % actors.length];
        address holder = actors[holderSeed % actors.length];
        bytes[7] memory payloads = [
            abi.encodeWithSignature("mint(address,uint256)", holder, amount),
            abi.encodeWithSignature("burn(uint256)", amount),
            abi.encodeWithSignature("burnFrom(address,uint256)", holder, amount),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("freeze(address)", holder),
            abi.encodeWithSignature("setBlacklist(address,bool)", holder, true),
            abi.encodeWithSignature("initialize(address)", caller)
        ];
        vm.prank(caller);
        (bool ok,) = address(token).call(payloads[mode % payloads.length]);
        assertFalse(ok, "unexpected privileged entry point");
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract SqueekChainTokenInvariantTest is Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 * 1e18;
    address internal constant DEPLOYER = address(0xFAC7);

    SqueekChainToken internal token;
    SqueekChainHandler internal handler;

    function setUp() public {
        vm.prank(DEPLOYER);
        token = new SqueekChainToken();
        handler = new SqueekChainHandler(token, DEPLOYER);

        // Start with funded actors and finite/infinite approvals so successful delegated transfers
        // are reachable immediately. These are real token calls, not storage edits or token deals.
        uint256 n = handler.actorCount();
        for (uint256 i = 1; i < n; ++i) {
            handler.transfer(0, i, EXPECTED_SUPPLY / n);
        }
        for (uint256 i; i < n; ++i) {
            handler.approve(i, (i + 1) % n, i % 2 == 0 ? type(uint256).max : EXPECTED_SUPPLY / n);
        }

        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.transferBoundary.selector;
        selectors[2] = handler.approve.selector;
        selectors[3] = handler.approveBoundary.selector;
        selectors[4] = handler.transferFrom.selector;
        selectors[5] = handler.transferAboveBalance.selector;
        selectors[6] = handler.transferFromInvalid.selector;
        selectors[7] = handler.transferToZero.selector;
        selectors[8] = handler.transferFromToZero.selector;
        selectors[9] = handler.approveZero.selector;
        selectors[10] = handler.privilegedCall.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
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

    function invariant_eachHolderHasExactlyTheirTokens() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.expectedBalance(actor), "holder balance differs from ledger");
        }
        assertEq(token.balanceOf(address(0)), 0, "zero address must not receive tokens");
        assertEq(token.balanceOf(address(token)), 0, "no hidden fee to token contract");
        assertEq(token.balanceOf(address(handler)), 0, "handler must not receive tokens");
    }

    function invariant_allowancesMatchAuthorizations() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address owner = handler.actors(i);
            for (uint256 j; j < n; ++j) {
                address spender = handler.actors(j);
                assertEq(
                    token.allowance(owner, spender),
                    handler.expectedAllowance(owner, spender),
                    "allowance differs from authorization ledger"
                );
            }
            assertEq(token.allowance(owner, address(0)), 0);
            assertEq(token.allowance(address(0), owner), 0);
        }
    }

    function invariant_metadataRemainsFixed() public view {
        assertEq(token.name(), "SqueekChain");
        assertEq(token.symbol(), "SQK");
        assertEq(token.decimals(), 18);
    }

    /// @dev Every holder can still move their entire balance after any generated sequence.
    function afterInvariant() public {
        uint256 n = handler.actorCount();
        handler.transfer(0, 1, handler.expectedBalance(DEPLOYER));
        for (uint256 i = 1; i < n; ++i) {
            handler.transfer(i, 0, handler.expectedBalance(handler.actors(i)));
        }
        assertEq(token.balanceOf(DEPLOYER), EXPECTED_SUPPLY, "all balances remain transferable");
        invariant_totalSupplyIsFixed();
        invariant_balancesSumToSupply();
        invariant_eachHolderHasExactlyTheirTokens();
        invariant_allowancesMatchAuthorizations();
    }
}
