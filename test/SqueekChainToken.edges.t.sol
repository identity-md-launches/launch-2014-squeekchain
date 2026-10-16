// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SqueekChainToken} from "src/SqueekChainToken.sol";

/// @dev A real contract caller checks factory-style deployment without impersonating CREATE2.
contract SqueekChainDeploymentFixture {
    function deploy(bytes32 salt) external returns (SqueekChainToken) {
        return new SqueekChainToken{salt: salt}();
    }
}

/// @notice Regression tests for allowance boundaries, failure atomicity and aliasing of ERC-20 roles.
/// forge-config: default.fuzz.runs = 1000
contract SqueekChainTokenEdgesTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 1e18;
    SqueekChainToken internal token;
    address internal owner;
    address internal alice;
    address internal bob;
    address internal spender;

    function setUp() public {
        owner = makeAddr("SQK deployer");
        alice = makeAddr("SQK holder Alice");
        bob = makeAddr("SQK holder Bob");
        spender = makeAddr("SQK spender");
        vm.prank(owner);
        token = new SqueekChainToken();
    }

    function testFuzz_factoryMintHasExactlyOneTransfer(bytes32 salt) public {
        SqueekChainDeploymentFixture factory = new SqueekChainDeploymentFixture();
        address predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), address(factory), salt, keccak256(type(SqueekChainToken).creationCode)
                        )
                    )
                )
            )
        );

        vm.recordLogs();
        vm.prank(alice, bob);
        SqueekChainToken fresh = factory.deploy(salt);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(address(fresh), predicted);
        assertEq(fresh.totalSupply(), SUPPLY);
        assertEq(fresh.balanceOf(address(factory)), SUPPLY, "immediate deployer owns the entire mint");
        assertEq(fresh.balanceOf(alice), 0, "factory caller is not the token deployer");
        assertEq(fresh.balanceOf(bob), 0, "transaction origin receives no mint");
        assertEq(fresh.balanceOf(address(fresh)), 0);
        assertEq(logs.length, 1, "constructor must emit exactly one mint");
        assertEq(logs[0].emitter, address(fresh));
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(factory)))));
        assertEq(logs[0].data, abi.encode(SUPPLY));
    }

    function test_oneMinorUnitAndWholeSupplyCanRoundTrip() public {
        _transfer(owner, alice, 1);
        assertEq(token.balanceOf(alice), 1);
        _transfer(alice, owner, 1);
        _assertBalances(SUPPLY, 0, 0);

        _transfer(owner, alice, SUPPLY);
        _assertBalances(0, SUPPLY, 0);
        _transfer(alice, owner, SUPPLY);
        _assertBalances(SUPPLY, 0, 0);
    }

    function test_zeroTransfersEmitEventsEvenWithoutBalanceOrApproval() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, bob, 0);
        _transfer(alice, bob, 0);

        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, bob, 0);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.allowance(alice, spender), 0);
        _assertBalances(SUPPLY, 0, 0);
    }

    function test_zeroValueStillRejectsZeroRecipientAndSpender() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(owner);
        token.transfer(address(0), 0);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(owner, address(0), 0);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(owner);
        token.approve(address(0), 0);
        assertEq(token.allowance(owner, address(0)), 0);
        _assertBalances(SUPPLY, 0, 0);
    }

    function test_zeroAddressCannotBeSenderOrApprover() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        vm.prank(address(0));
        token.transfer(alice, 0);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(address(0));
        token.approve(spender, 1);

        // Both source and authorization are invalid; no error-ordering guarantee is needed.
        vm.expectRevert();
        vm.prank(spender);
        token.transferFrom(address(0), alice, 0);
        assertEq(token.allowance(address(0), spender), 0);
        _assertBalances(SUPPLY, 0, 0);
    }

    function test_maximumTransferRevertsAtomically() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, SUPPLY, type(uint256).max)
        );
        vm.prank(owner);
        token.transfer(alice, type(uint256).max);
        _assertBalances(SUPPLY, 0, 0);
    }

    function test_selfTransferStillRequiresEnoughBalance() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, SUPPLY, SUPPLY + 1)
        );
        vm.prank(owner);
        token.transfer(owner, SUPPLY + 1);
        _assertBalances(SUPPLY, 0, 0);
    }

    function test_delegatedSelfTransferConsumesFiniteAllowance() public {
        _approve(owner, spender, 50);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(owner, owner, 12);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, owner, 12));
        assertEq(token.allowance(owner, spender), 38);
        _assertBalances(SUPPLY, 0, 0);
    }

    function test_delegatedSelfTransferCannotOverdrawOrConsumeAllowance() public {
        _approve(owner, spender, SUPPLY + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, SUPPLY, SUPPLY + 1)
        );
        vm.prank(spender);
        token.transferFrom(owner, owner, SUPPLY + 1);
        assertEq(token.allowance(owner, spender), SUPPLY + 1);
        _assertBalances(SUPPLY, 0, 0);
    }

    function test_ownerTransferFromRequiresSelfApproval() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, owner, 0, 1));
        vm.prank(owner);
        token.transferFrom(owner, alice, 1);
        _assertBalances(SUPPLY, 0, 0);

        _approve(owner, owner, 1);
        vm.prank(owner);
        assertTrue(token.transferFrom(owner, alice, 1));
        assertEq(token.allowance(owner, owner), 0);
        _assertBalances(SUPPLY - 1, 1, 0);
    }

    function test_exhaustedAllowanceCannotBeSpentTwice() public {
        _approve(owner, spender, 10);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, alice, 10));

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(owner, bob, 1);
        assertEq(token.allowance(owner, spender), 0);
        _assertBalances(SUPPLY - 10, 10, 0);
    }

    function test_infiniteApprovalCanBeRevokedAndReplaced() public {
        _approve(owner, spender, type(uint256).max);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, alice, 1));
        assertEq(token.allowance(owner, spender), type(uint256).max);

        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Approval(owner, spender, 0);
        _approve(owner, spender, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(owner, bob, 1);
        _assertBalances(SUPPLY - 1, 1, 0);

        _approve(owner, spender, 2);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, bob, 2));
        assertEq(token.allowance(owner, spender), 0);
        _assertBalances(SUPPLY - 3, 1, 2);
    }

    function test_maximumMinusOneAllowanceIsFinite() public {
        _approve(owner, spender, type(uint256).max - 1);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, alice, 1));
        assertEq(token.allowance(owner, spender), type(uint256).max - 2);
        _assertBalances(SUPPLY - 1, 1, 0);
    }

    function test_infiniteApprovalDoesNotAuthorizeOverdrawing() public {
        _approve(owner, spender, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, SUPPLY, SUPPLY + 1)
        );
        vm.prank(spender);
        token.transferFrom(owner, alice, SUPPLY + 1);
        assertEq(token.allowance(owner, spender), type(uint256).max);
        _assertBalances(SUPPLY, 0, 0);

        vm.prank(spender);
        assertTrue(token.transferFrom(owner, alice, SUPPLY));
        assertEq(token.allowance(owner, spender), type(uint256).max);
        _assertBalances(0, SUPPLY, 0);
    }

    function test_spenderCanReceiveEntireSupplyWithExactApproval() public {
        _approve(owner, spender, SUPPLY);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, spender, SUPPLY));
        assertEq(token.balanceOf(owner), 0);
        assertEq(token.balanceOf(spender), SUPPLY);
        assertEq(token.allowance(owner, spender), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_approvalAboveBalanceSurvivesDirectTransfers() public {
        _approve(alice, spender, type(uint256).max);
        _assertBalances(SUPPLY, 0, 0);
        _transfer(owner, alice, 1);
        _transfer(alice, bob, 1);
        assertEq(token.allowance(alice, spender), type(uint256).max);
        _assertBalances(SUPPLY - 1, 0, 1);
    }

    function test_transferToTokenContractDoesNotBurnSupply() public {
        _transfer(owner, address(token), SUPPLY);
        assertEq(token.balanceOf(owner), 0);
        assertEq(token.balanceOf(address(token)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function testFuzz_failedOverdrawPreservesBalancesAndAllowance(uint256 funded, uint256 amount, bool infinite)
        public
    {
        funded = bound(funded, 0, SUPPLY);
        amount = bound(amount, funded + 1, type(uint256).max);
        _transfer(owner, alice, funded);
        uint256 approved = infinite ? type(uint256).max : amount;
        _approve(alice, spender, approved);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, funded, amount));
        vm.prank(spender);
        token.transferFrom(alice, bob, amount);
        assertEq(token.allowance(alice, spender), approved, "revert must undo the allowance debit");
        _assertBalances(SUPPLY - funded, funded, 0);
    }

    function testFuzz_zeroRecipientFailurePreservesAllowance(uint256 approved, uint256 amount) public {
        uint256 cap = approved < SUPPLY ? approved : SUPPLY;
        amount = bound(amount, 0, cap);
        _approve(owner, spender, approved);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(owner, address(0), amount);
        assertEq(token.allowance(owner, spender), approved, "recipient failure must undo the allowance debit");
        _assertBalances(SUPPLY, 0, 0);
    }

    function testFuzz_approvalReplacementAndIsolation(uint256 first, uint256 replacement, uint256 unrelated) public {
        replacement = bound(replacement, 0, SUPPLY - 1);
        _approve(owner, spender, first);
        _approve(owner, bob, unrelated);
        _approve(alice, spender, unrelated);
        _approve(owner, spender, replacement);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, spender, replacement, replacement + 1
            )
        );
        vm.prank(spender);
        token.transferFrom(owner, alice, replacement + 1);
        assertEq(token.allowance(owner, spender), replacement);
        assertEq(token.allowance(owner, bob), unrelated, "another spender's grant is independent");
        assertEq(token.allowance(alice, spender), unrelated, "another owner's grant is independent");
        _assertBalances(SUPPLY, 0, 0);
    }

    function testFuzz_otherSpenderCannotUseApproval(uint256 approved, uint256 amount) public {
        amount = bound(amount, 1, SUPPLY);
        _approve(owner, spender, approved);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, amount));
        vm.prank(alice);
        token.transferFrom(owner, bob, amount);
        assertEq(token.allowance(owner, spender), approved);
        assertEq(token.allowance(owner, alice), 0);
        _assertBalances(SUPPLY, 0, 0);
    }

    function testFuzz_splitDelegatedTransferMatchesSingleTransfer(uint256 total, uint256 first) public {
        total = bound(total, 0, SUPPLY);
        first = bound(first, 0, total);
        vm.prank(owner);
        SqueekChainToken single = new SqueekChainToken();
        vm.prank(owner);
        assertTrue(single.approve(spender, total));
        vm.prank(spender);
        assertTrue(single.transferFrom(owner, bob, total));

        _approve(owner, spender, total);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, bob, first));
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, bob, total - first));

        assertEq(token.balanceOf(owner), single.balanceOf(owner));
        assertEq(token.balanceOf(bob), single.balanceOf(bob));
        assertEq(token.allowance(owner, spender), single.allowance(owner, spender));
        assertEq(token.allowance(owner, spender), 0);
        _assertBalances(SUPPLY - total, 0, total);
    }

    function testFuzz_roundTripPreservesBalancesAndApprovals(uint256 amount, uint256 approved) public {
        amount = bound(amount, 0, SUPPLY);
        _approve(owner, spender, approved);
        _approve(alice, bob, approved);
        _transfer(owner, alice, amount);
        assertEq(token.balanceOf(alice), amount, "forward leg delivers exactly the requested amount");
        _transfer(alice, owner, amount);
        assertEq(token.allowance(owner, spender), approved);
        assertEq(token.allowance(alice, bob), approved);
        _assertBalances(SUPPLY, 0, 0);
    }

    function _approve(address from, address to, uint256 amount) internal {
        vm.prank(from);
        assertTrue(token.approve(to, amount));
    }

    function _transfer(address from, address to, uint256 amount) internal {
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
    }

    function _assertBalances(uint256 ownerBalance, uint256 aliceBalance, uint256 bobBalance) internal view {
        assertEq(token.balanceOf(owner), ownerBalance);
        assertEq(token.balanceOf(alice), aliceBalance);
        assertEq(token.balanceOf(bob), bobBalance);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
