// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Token} from "../src/Token.sol";

contract TokenTest is Test {
    Token public token;
    address public owner;
    address public user1;
    address public user2;

    function setUp() public {
        owner = address(this);
        user1 = address(0x1);
        user2 = address(0x2);
        
        token = new Token();
    }

    function testInitialState() public {
        assertEq(token.name(), "Miniera Protocol Token");
        assertEq(token.symbol(), "MINB");
        assertEq(token.owner(), owner);
        assertEq(token.totalSupply(), 0);
    }

    function testMint() public {
        uint256 amount = 1000 * 10**18;
        token.mint(user1, amount);
        
        assertEq(token.balanceOf(user1), amount);
        assertEq(token.totalSupply(), amount);
    }

    function testMintOnlyOwner() public {
        uint256 amount = 1000 * 10**18;
        
        vm.prank(user1);
        vm.expectRevert();
        token.mint(user2, amount);
    }

    function testBurn() public {
        uint256 amount = 1000 * 10**18;
        token.mint(user1, amount);
        
        token.burn(user1, amount);
        
        assertEq(token.balanceOf(user1), 0);
        assertEq(token.totalSupply(), 0);
    }

    function testBurnOnlyOwner() public {
        uint256 amount = 1000 * 10**18;
        token.mint(user1, amount);
        
        vm.prank(user1);
        vm.expectRevert();
        token.burn(user1, amount);
    }

    function testBurnInsufficientBalance() public {
        uint256 amount = 1000 * 10**18;
        token.mint(user1, amount);

        vm.expectRevert();
        token.burn(user1, amount + 1);
    }

    function testSetBurner() public {
        token.setBurner(user1);
        assertEq(token.burner(), user1);
    }

    function testSetBurnerOnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        token.setBurner(user2);
    }

    function testBurnFromBurner() public {
        uint256 amount = 1000 * 10**18;
        token.mint(user1, amount);

        // Set user2 as burner
        token.setBurner(user2);

        // Burner can burn tokens
        vm.prank(user2);
        token.burn(user1, amount);

        assertEq(token.balanceOf(user1), 0);
        assertEq(token.totalSupply(), 0);
    }

    function testBurnFromNonBurner() public {
        uint256 amount = 1000 * 10**18;
        token.mint(user1, amount);

        // user2 is not owner or burner
        vm.prank(user2);
        vm.expectRevert();
        token.burn(user1, amount);
    }
}
