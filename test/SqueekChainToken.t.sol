// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SqueekChainToken} from "../src/SqueekChainToken.sol";
import {DeploySqueekChain} from "../script/DeploySqueekChain.s.sol";

/// @notice Behaviour of the SqueekChain token: metadata, the one-time mint to the deployer, plain
///         ERC-20 transfers and approvals, the reverts the standard requires, and the absence of
///         any admin surface. Runs with an empty environment and in any order.
contract SqueekChainTokenTest is Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 * 1e18;

    /// @dev Stands in for the factory: the token is deployed from this address, so it holds the supply.
    address internal constant DEPLOYER = address(0xFAC7);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant SPENDER = address(0x5BE4D);

    SqueekChainToken internal token;

    function setUp() public {
        vm.prank(DEPLOYER);
        token = new SqueekChainToken();
    }

    // ---------------------------------------------------------------------------------------------
    // Metadata and supply
    // ---------------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "SqueekChain", "name");
        assertEq(token.symbol(), "SQK", "symbol");
        assertEq(token.decimals(), 18, "decimals");
        assertEq(token.TOKEN_DECIMALS(), 18, "decimals constant");
    }

    function test_supplyConstantsAgree() public view {
        assertEq(token.TOTAL_SUPPLY(), EXPECTED_SUPPLY, "TOTAL_SUPPLY");
        assertEq(token.TOTAL_SUPPLY(), 1e27, "TOTAL_SUPPLY in minor units");
        assertEq(token.SUPPLY_WHOLE_TOKENS() * 10 ** token.decimals(), token.TOTAL_SUPPLY(), "derivation");
    }

    function test_mintsWholeSupplyOnceToDeployer() public view {
        assertEq(token.totalSupply(), EXPECTED_SUPPLY, "totalSupply");
        assertEq(token.balanceOf(DEPLOYER), EXPECTED_SUPPLY, "deployer balance");
        assertEq(token.balanceOf(address(this)), 0, "test contract must hold nothing");
        assertEq(token.balanceOf(address(token)), 0, "token must hold nothing");
    }

    /// @dev The mint goes to `msg.sender` of the constructor, never to `tx.origin`.
    function test_mintGoesToMsgSenderNotTxOrigin() public {
        address origin = address(0x0121);
        address sender = address(0x5E4D);
        vm.prank(sender, origin);
        SqueekChainToken fresh = new SqueekChainToken();
        assertEq(fresh.balanceOf(sender), EXPECTED_SUPPLY, "msg.sender holds the supply");
        assertEq(fresh.balanceOf(origin), 0, "tx.origin holds nothing");
    }

    function test_constructorEmitsSingleMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), DEPLOYER, EXPECTED_SUPPLY);
        vm.prank(DEPLOYER);
        new SqueekChainToken();
    }

    /// @dev Two deployments are independent: each mints its own supply to its own deployer.
    function test_eachDeploymentMintsToItsOwnDeployer() public {
        vm.prank(ALICE);
        SqueekChainToken second = new SqueekChainToken();
        assertEq(second.balanceOf(ALICE), EXPECTED_SUPPLY);
        assertEq(second.balanceOf(DEPLOYER), 0);
        assertEq(token.balanceOf(ALICE), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers: success
    // ---------------------------------------------------------------------------------------------

    function test_transferMovesExactAmount() public {
        uint256 amount = 123_456 * 1e18;
        vm.prank(DEPLOYER);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(DEPLOYER, ALICE, amount);
        assertTrue(token.transfer(ALICE, amount), "transfer returns true");
        assertEq(token.balanceOf(ALICE), amount, "recipient receives exactly the amount");
        assertEq(token.balanceOf(DEPLOYER), EXPECTED_SUPPLY - amount, "sender loses exactly the amount");
        assertEq(token.totalSupply(), EXPECTED_SUPPLY, "supply unchanged");
    }

    function test_transferWholeBalance() public {
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(ALICE, EXPECTED_SUPPLY));
        assertEq(token.balanceOf(DEPLOYER), 0);
        assertEq(token.balanceOf(ALICE), EXPECTED_SUPPLY);
    }

    function test_transferZeroAmountSucceeds() public {
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0));
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(DEPLOYER, 1e18));
        assertEq(token.balanceOf(DEPLOYER), EXPECTED_SUPPLY);
    }

    /// @dev The launch flows: factory -> distributor -> claimant, and factory -> pool, each arrive whole.
    function test_launchFlowsArriveWhole() public {
        address distributor = address(0xD157);
        address claimant = address(0xC1A1);
        address pool = address(0x9001);
        uint256 swarm = (EXPECTED_SUPPLY * 1_000) / 10_000;
        uint256 poolShare = (EXPECTED_SUPPLY * 8_000) / 10_000;

        vm.startPrank(DEPLOYER);
        token.transfer(distributor, swarm);
        token.transfer(pool, poolShare);
        vm.stopPrank();
        vm.prank(distributor);
        token.transfer(claimant, swarm);

        assertEq(token.balanceOf(claimant), swarm, "claim arrived whole");
        assertEq(token.balanceOf(distributor), 0, "distributor kept nothing");
        assertEq(token.balanceOf(pool), poolShare, "pool share arrived whole");
        assertEq(token.balanceOf(DEPLOYER), EXPECTED_SUPPLY - swarm - poolShare, "remainder");
        assertEq(token.totalSupply(), EXPECTED_SUPPLY, "supply unchanged by launch flows");
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 0, EXPECTED_SUPPLY);
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(to, amount));
        if (to == DEPLOYER) {
            assertEq(token.balanceOf(DEPLOYER), EXPECTED_SUPPLY, "self-transfer keeps the balance");
        } else {
            assertEq(token.balanceOf(to), amount);
            assertEq(token.balanceOf(to) + token.balanceOf(DEPLOYER), EXPECTED_SUPPLY);
        }
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function testFuzz_chainedTransfersConserveSupply(address a, address b, uint256 x, uint256 y) public {
        vm.assume(a != address(0) && b != address(0) && a != b && a != DEPLOYER && b != DEPLOYER);
        x = bound(x, 0, EXPECTED_SUPPLY);
        y = bound(y, 0, x);
        vm.prank(DEPLOYER);
        token.transfer(a, x);
        vm.prank(a);
        token.transfer(b, y);
        assertEq(token.balanceOf(a), x - y);
        assertEq(token.balanceOf(b), y);
        assertEq(token.balanceOf(DEPLOYER) + token.balanceOf(a) + token.balanceOf(b), EXPECTED_SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers: failure
    // ---------------------------------------------------------------------------------------------

    function test_transferRevertsWhenBalanceInsufficient() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        token.transfer(BOB, 1);
    }

    function test_transferRevertsOneWeiOverBalance() public {
        vm.prank(DEPLOYER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, DEPLOYER, EXPECTED_SUPPLY, EXPECTED_SUPPLY + 1
            )
        );
        token.transfer(ALICE, EXPECTED_SUPPLY + 1);
    }

    function test_transferToZeroAddressReverts() public {
        vm.prank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function testFuzz_transferRevertsAboveBalance(uint256 amount) public {
        amount = bound(amount, EXPECTED_SUPPLY + 1, type(uint256).max);
        vm.prank(DEPLOYER);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, DEPLOYER, EXPECTED_SUPPLY, amount)
        );
        token.transfer(ALICE, amount);
    }

    // ---------------------------------------------------------------------------------------------
    // Approvals and transferFrom: success
    // ---------------------------------------------------------------------------------------------

    function test_approveSetsAllowanceAndEmits() public {
        vm.prank(DEPLOYER);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(DEPLOYER, SPENDER, 5e18);
        assertTrue(token.approve(SPENDER, 5e18));
        assertEq(token.allowance(DEPLOYER, SPENDER), 5e18);
    }

    function test_approveOverwritesPreviousAllowance() public {
        vm.startPrank(DEPLOYER);
        token.approve(SPENDER, 5e18);
        token.approve(SPENDER, 2e18);
        vm.stopPrank();
        assertEq(token.allowance(DEPLOYER, SPENDER), 2e18);
    }

    function test_transferFromSpendsAllowance() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, 10e18);

        vm.prank(SPENDER);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(DEPLOYER, BOB, 4e18);
        assertTrue(token.transferFrom(DEPLOYER, BOB, 4e18));

        assertEq(token.balanceOf(BOB), 4e18);
        assertEq(token.balanceOf(DEPLOYER), EXPECTED_SUPPLY - 4e18);
        assertEq(token.allowance(DEPLOYER, SPENDER), 6e18, "allowance decreases by the amount spent");
        assertEq(token.balanceOf(SPENDER), 0, "spender gets nothing itself");
    }

    function test_transferFromWithInfiniteAllowanceDoesNotDecrease() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, type(uint256).max);
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, BOB, 1e18);
        assertEq(token.allowance(DEPLOYER, SPENDER), type(uint256).max);
        assertEq(token.balanceOf(BOB), 1e18);
    }

    function testFuzz_transferFromWithinAllowance(uint256 allowance, uint256 amount) public {
        allowance = bound(allowance, 0, EXPECTED_SUPPLY);
        amount = bound(amount, 0, allowance);
        vm.prank(DEPLOYER);
        token.approve(SPENDER, allowance);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(DEPLOYER, BOB, amount));
        assertEq(token.balanceOf(BOB), amount);
        assertEq(token.allowance(DEPLOYER, SPENDER), allowance - amount);
    }

    // ---------------------------------------------------------------------------------------------
    // Approvals and transferFrom: failure
    // ---------------------------------------------------------------------------------------------

    function test_transferFromWithoutAllowanceReverts() public {
        vm.prank(SPENDER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        token.transferFrom(DEPLOYER, BOB, 1);
    }

    function test_transferFromAboveAllowanceReverts() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, 3e18);
        vm.prank(SPENDER);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 3e18, 3e18 + 1)
        );
        token.transferFrom(DEPLOYER, BOB, 3e18 + 1);
    }

    function test_transferFromAboveBalanceRevertsEvenWithAllowance() public {
        vm.prank(ALICE);
        token.approve(SPENDER, 1e18);
        vm.prank(SPENDER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1e18));
        token.transferFrom(ALICE, BOB, 1e18);
    }

    function test_transferFromToZeroAddressReverts() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, 1e18);
        vm.prank(SPENDER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(DEPLOYER, address(0), 1e18);
    }

    function test_approveZeroSpenderReverts() public {
        vm.prank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    /// @dev Nobody, including the deployer, can move a holder's balance without an allowance.
    function test_deployerCannotPullFromHolder() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 1e18);
        vm.prank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, DEPLOYER, 0, 1));
        token.transferFrom(ALICE, DEPLOYER, 1);
        assertEq(token.balanceOf(ALICE), 1e18);
    }

    // ---------------------------------------------------------------------------------------------
    // No admin surface: nothing mints, pauses, freezes, seizes or upgrades
    // ---------------------------------------------------------------------------------------------

    function test_noCallIncreasesSupply() public {
        address attacker = address(0xBEEF);
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "upgradeToAndCall(address,bytes)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)",
            "grantRole(bytes32,address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool okAttacker,) = address(token).call(data);
            assertFalse(okAttacker, string.concat("unexpected function answered: ", signatures[i]));
            vm.prank(DEPLOYER);
            (bool okDeployer,) = address(token).call(data);
            assertFalse(okDeployer, string.concat("unexpected function answered for deployer: ", signatures[i]));
            assertEq(token.totalSupply(), EXPECTED_SUPPLY, signatures[i]);
            assertEq(token.balanceOf(attacker), 0, signatures[i]);
        }
    }

    function test_noPrivilegedCallMovesOrFreezesHolder() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, EXPECTED_SUPPLY / 1_000);
        uint256 held = token.balanceOf(ALICE);

        string[14] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "burn(uint256)",
            "seize(address)",
            "owner()"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, true);
            vm.prank(DEPLOYER);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, string.concat("unexpected function answered: ", signatures[i]));
        }

        assertEq(token.balanceOf(ALICE), held, "holder balance untouched");
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, held / 2), "holder can still transfer");
        assertEq(token.balanceOf(BOB), held / 2);
    }

    function test_noEtherAccepted() public {
        vm.deal(ALICE, 1 ether);
        vm.prank(ALICE);
        (bool ok,) = address(token).call{value: 1 wei}("");
        assertFalse(ok, "token must not accept ether");
        assertEq(address(token).balance, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Bytecode properties the launch floor checks
    // ---------------------------------------------------------------------------------------------

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0, "no runtime");
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    /// @dev The launch deploys through CREATE2 from the factory and records the contract under its
    ///      Solidity name, which must fit 32 bytes.
    function test_contractNameFitsManifest() public pure {
        assertLe(bytes("SqueekChainToken").length, 32);
    }

    function test_deploysThroughCreate2WithNoArguments() public {
        bytes memory code = type(SqueekChainToken).creationCode;
        bytes32 salt = bytes32(uint256(42));
        address predicted =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), DEPLOYER, salt, keccak256(code))))));
        vm.prank(DEPLOYER);
        address deployed;
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        assertEq(deployed, predicted, "CREATE2 prediction");
        assertEq(SqueekChainToken(deployed).balanceOf(DEPLOYER), EXPECTED_SUPPLY, "supply to the CREATE2 deployer");
    }

    // ---------------------------------------------------------------------------------------------
    // Deploy script
    // ---------------------------------------------------------------------------------------------

    function test_deployScriptMintsToItsCaller() public {
        DeploySqueekChain script = new DeploySqueekChain();
        SqueekChainToken deployed = script.deploy();
        assertEq(deployed.name(), "SqueekChain");
        assertEq(deployed.symbol(), "SQK");
        assertEq(deployed.totalSupply(), EXPECTED_SUPPLY);
        // Inside `deploy()` the constructor's msg.sender is the script contract itself.
        assertEq(deployed.balanceOf(address(script)), EXPECTED_SUPPLY);
    }
}
