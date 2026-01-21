// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Referral} from "../src/Referral.sol";

contract MockToken {
    string public name = "Mock Token";
    string public symbol = "MTK";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor() {
        totalSupply = 1e24;
        balanceOf[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }
}

contract ReferralTest is Test {
    Referral public referral;

    address public paymentToken;
    address public gridToken;
    address public referrer = address(0x1234);

    function setUp() public {
        paymentToken = address(new MockToken());
        gridToken = address(new MockToken());
        referral = new Referral(paymentToken, gridToken);
    }

    function _setReferrer(address user, address _referrer) internal {
        vm.prank(user);
        referral.setReferredBy(_referrer);
    }

    function testReferralCountAndList() public {
        address user1 = address(0x1);
        address user2 = address(0x2);
        address user3 = address(0x3);

        _setReferrer(user1, referrer);
        _setReferrer(user2, referrer);
        _setReferrer(user3, referrer);

        assertEq(referral.getReferralCount(referrer), 3);

        address[] memory firstPage = referral.getReferrals(referrer, 0, 100);
        assertEq(firstPage.length, 3);
        assertEq(firstPage[0], user1);
        assertEq(firstPage[1], user2);
        assertEq(firstPage[2], user3);
    }

    function testPagination() public {
        uint256 totalReferrals = 250;
        for (uint256 i = 0; i < totalReferrals; i++) {
            _setReferrer(address(uint160(i + 1)), referrer);
        }

        assertEq(referral.getReferralCount(referrer), totalReferrals);

        address[] memory pageOne = referral.getReferrals(referrer, 0, 100);
        assertEq(pageOne.length, 100);
        assertEq(pageOne[0], address(uint160(1)));
        assertEq(pageOne[99], address(uint160(100)));

        address[] memory pageTwo = referral.getReferrals(referrer, 100, 100);
        assertEq(pageTwo.length, 100);
        assertEq(pageTwo[0], address(uint160(101)));
        assertEq(pageTwo[99], address(uint160(200)));

        address[] memory lastPage = referral.getReferrals(referrer, 200, 100);
        assertEq(lastPage.length, 50);
        assertEq(lastPage[0], address(uint160(201)));
        assertEq(lastPage[49], address(uint160(250)));

        address[] memory emptyPage = referral.getReferrals(referrer, 1000, 100);
        assertEq(emptyPage.length, 0);
    }
}
