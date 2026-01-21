// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Airdrop} from "../src/Airdrop.sol";
import {Token} from "../src/Token.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract AirdropTest is Test {
    event BoardManagerUpdated(address indexed newBoardManager);

    Token public gridToken;
    Airdrop public airdrop;

    address public owner = address(this);
    address public boardManager = address(0xBEEF);
    address public winner1 = address(0xA11CE);
    address public winner2 = address(0xB0B00);
    address public outsider = address(0xCAFE);

    function setUp() public {
        gridToken = new Token();
        airdrop = new Airdrop(address(gridToken), boardManager);
    }

    function _fundAirdrop(uint256 amount) internal {
        gridToken.mint(address(this), amount);
        gridToken.transfer(address(airdrop), amount);
    }

    function testConstructorSetsState() public view {
        assertEq(airdrop.owner(), owner);
        assertEq(address(airdrop.gridToken()), address(gridToken));
        assertEq(airdrop.boardManager(), boardManager);
    }

    function testConstructorRevertsWithoutToken() public {
        vm.expectRevert("Airdrop: token required");
        new Airdrop(address(0), boardManager);
    }

    function testConstructorRevertsWithoutBoardManager() public {
        vm.expectRevert("Airdrop: board required");
        new Airdrop(address(gridToken), address(0));
    }

    function testSetBoardManagerUpdatesManager() public {
        address newManager = address(0x1234);
        vm.expectEmit(true, false, false, false);
        emit BoardManagerUpdated(newManager);

        airdrop.setBoardManager(newManager);

        assertEq(airdrop.boardManager(), newManager);
    }

    function testSetBoardManagerOnlyOwner() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        airdrop.setBoardManager(outsider);
    }

    function testPayoutTransfersEntireBalance() public {
        uint256 pot = 1_000 ether;
        _fundAirdrop(pot);

        vm.prank(boardManager);
        uint256 paid = airdrop.payout(winner1);

        assertEq(paid, pot);
        assertEq(gridToken.balanceOf(winner1), pot);
        assertEq(gridToken.balanceOf(address(airdrop)), 0);
    }

    function testPayoutRevertsForNonManager() public {
        _fundAirdrop(100 ether);
        vm.prank(outsider);
        vm.expectRevert("Airdrop: not board manager");
        airdrop.payout(winner1);
    }

    function testPayoutRequiresValidWinner() public {
        _fundAirdrop(100 ether);
        vm.prank(boardManager);
        vm.expectRevert("Airdrop: invalid winner");
        airdrop.payout(address(0));
    }

    function testPayoutRevertsWhenEmpty() public {
        vm.prank(boardManager);
        vm.expectRevert("Airdrop: empty");
        airdrop.payout(winner1);
    }

    function testCurrentBalanceTracksPot() public {
        _fundAirdrop(250 ether);
        assertEq(airdrop.currentBalance(), 250 ether);
    }

    function testPayoutMultipleDistributesProportionally() public {
        uint256 pot = 900 ether;
        _fundAirdrop(pot);

        address[] memory winners = new address[](2);
        winners[0] = winner1;
        winners[1] = winner2;
        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 2;
        allocations[1] = 1;

        vm.prank(boardManager);
        uint256 totalPaid = airdrop.payoutMultiple(winners, allocations);

        assertEq(totalPaid, pot);
        assertEq(gridToken.balanceOf(winner1), 600 ether);
        assertEq(gridToken.balanceOf(winner2), 300 ether);
        assertEq(gridToken.balanceOf(address(airdrop)), 0);
    }

    function testPayoutMultipleRevertsLengthMismatch() public {
        address[] memory winners = new address[](1);
        winners[0] = winner1;

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 1;
        allocations[1] = 2;

        vm.prank(boardManager);
        vm.expectRevert("Airdrop: length mismatch");
        airdrop.payoutMultiple(winners, allocations);
    }

    function testPayoutMultipleRequiresWinners() public {
        address[] memory winners = new address[](0);
        uint256[] memory allocations = new uint256[](0);

        vm.prank(boardManager);
        vm.expectRevert("Airdrop: no winners");
        airdrop.payoutMultiple(winners, allocations);
    }

    function testPayoutMultipleRequiresBalance() public {
        address[] memory winners = new address[](1);
        winners[0] = winner1;
        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 1;

        vm.prank(boardManager);
        vm.expectRevert("Airdrop: empty");
        airdrop.payoutMultiple(winners, allocations);
    }

    function testPayoutMultipleRequiresAllocations() public {
        _fundAirdrop(100 ether);

        address[] memory winners = new address[](1);
        winners[0] = winner1;
        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 0;

        vm.prank(boardManager);
        vm.expectRevert("Airdrop: no allocations");
        airdrop.payoutMultiple(winners, allocations);
    }

    function testPayoutMultipleRejectsInvalidWinner() public {
        _fundAirdrop(100 ether);

        address[] memory winners = new address[](2);
        winners[0] = winner1;
        winners[1] = address(0);
        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 1;
        allocations[1] = 1;

        vm.prank(boardManager);
        vm.expectRevert("Airdrop: invalid winner");
        airdrop.payoutMultiple(winners, allocations);
    }
}
