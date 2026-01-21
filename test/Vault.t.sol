// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Token} from "../src/Token.sol";
import {Vault} from "../src/Vault.sol";
import {Minter} from "../src/Minter.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract MockUSDC {
    string public name = "Mock USDC";
    string public symbol = "USDC";
    uint8 public decimals = 6;
    uint256 public totalSupply;
    
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    
    constructor() {
        totalSupply = 1000000 * 10**6; // 1M USDC
        balanceOf[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
    }
    
    function transfer(address to, uint256 value) external returns (bool) {
        require(balanceOf[msg.sender] >= value, "MockUSDC: insufficient balance");
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        emit Transfer(msg.sender, to, value);
        return true;
    }
    
    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }
    
    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        require(balanceOf[from] >= value, "MockUSDC: insufficient balance");
        require(allowance[from][msg.sender] >= value, "MockUSDC: insufficient allowance");
        balanceOf[from] -= value;
        balanceOf[to] += value;
        allowance[from][msg.sender] -= value;
        emit Transfer(from, to, value);
        return true;
    }
    
    function mint(address to, uint256 value) external {
        totalSupply += value;
        balanceOf[to] += value;
        emit Transfer(address(0), to, value);
    }
}

contract VaultTest is Test {
    Token public token;
    MockUSDC public usdc;
    Vault public vault;
    Minter public minter;
    
    address public owner;
    address public user1;
    address public user2;
    address internal constant AIRDROP = address(0xdead);
    uint256 internal constant SHARE_SCALE = 1e18;
    uint256 internal constant TOTAL_SHARE_UNITS = 10_000 * SHARE_SCALE;
    uint256 internal mintedCollateral;
    uint256 internal manualCollateral;

    function setUp() public {
        owner = address(this);
        user1 = address(0x1);
        user2 = address(0x2);
        mintedCollateral = 0;
        manualCollateral = 0;
        
        // Deploy contracts
        token = new Token();
        usdc = new MockUSDC();
        vault = new Vault(address(usdc), address(token));
        minter = new Minter(address(usdc), address(token), address(vault), 100 * 10**6, 100);
        
        // Setup relationships
        token.setBurner(address(vault));
        token.transferOwnership(address(minter));
        vault.setMinter(address(minter));
        vault.setBoardContract(owner);
        minter.setBoardContract(address(this));
        usdc.approve(address(minter), type(uint256).max);
        
        // Mint some tokens to user1 for testing
        _mintFromBoard(user1, 1000 * 10**18);
        
        // Transfer some USDC to vault for testing
        usdc.transfer(address(vault), 100000 * 10**6);
        vault.receivePaymentAmount(100000 * 10**6);
        manualCollateral = 100000 * 10**6;
    }

    function testInitialState() public {
        assertEq(vault.owner(), owner);
        assertEq(address(vault.paymentToken()), address(usdc));
        assertEq(address(vault.gridToken()), address(token));
        assertEq(address(vault.minter()), address(minter));
        uint256 expectedBalance = mintedCollateral + manualCollateral;
        assertEq(vault.totalPaymentAmount(), expectedBalance);
        assertEq(vault.totalBurnedAmount(), 0);
        assertEq(vault.totalRedeemedAmount(), 0);
    }

    function testGetPrice() public {
        // Mint some tokens to create circulating supply
        _mintFromBoard(user2, 1000 * 10**18);
        
        uint256 price = vault.getPrice();
        uint256 totalBalance = mintedCollateral + manualCollateral;
        uint256 expectedPrice = (totalBalance * 1e18) / minter.circulatingSupply();
        assertEq(price, expectedPrice);
    }

    function testRedeem() public {
        uint256 tokenAmount = 100 * 10**18;
        uint256 userBalance = token.balanceOf(user1);

        uint256 vaultBalanceBefore = vault.getBalance();
        uint256 circulatingBefore = minter.circulatingSupply();

        // Redeem tokens
        vm.prank(user1);
        vault.redeem(tokenAmount);

        // Check state changes
        assertEq(token.balanceOf(user1), userBalance - tokenAmount);
        assertEq(vault.totalBurnedAmount(), tokenAmount);

        // Check USDC transfer (simplified calculation)
        uint256 expectedUSDC = (vaultBalanceBefore * tokenAmount) /
            circulatingBefore;
        assertEq(usdc.balanceOf(user1), expectedUSDC);
    }

    function testRedeemInsufficientBalance() public {
        uint256 tokenAmount = 2000 * 10**18; // More than user has

        vm.prank(user1);
        vm.expectRevert();
        vault.redeem(tokenAmount);
    }

    function testReceivePaymentAmount() public {
        uint256 amount = 50000 * 10**6;
        
        vm.prank(address(minter));
        vault.receivePaymentAmount(amount);
        mintedCollateral += amount;
        
        assertEq(
            vault.totalPaymentAmountReceived(),
            mintedCollateral + manualCollateral
        );
    }

    function testReceivePaymentAmountFromBoard() public {
        uint256 amount = 25_000 * 10**6;
        vault.setBoardContract(user1);

        vm.prank(user1);
        vault.receivePaymentAmount(amount);
        manualCollateral += amount;

        assertEq(
            vault.totalPaymentAmountReceived(),
            mintedCollateral + manualCollateral
        );
    }

    function testReceivePaymentAmountOnlyMinter() public {
        uint256 amount = 50000 * 10**6;
        
        vm.prank(user1);
        vm.expectRevert();
        vault.receivePaymentAmount(amount);
    }

    function testGetState() public {
        (
            uint256 balance,
            uint256 burnedAmount,
            uint256 redeemedAmount,
            uint256 totalReceived
        ) = vault.getState();
        
        assertEq(balance, mintedCollateral + manualCollateral);
        assertEq(burnedAmount, 0);
        assertEq(redeemedAmount, 0);
        assertEq(totalReceived, mintedCollateral + manualCollateral);
    }

    function _mintFromBoard(address recipient, uint256 tokenAmount) internal {
        uint256 collateral = _collateralForTokens(tokenAmount);
        address[] memory recipients = new address[](2);
        recipients[0] = recipient;
        recipients[1] = AIRDROP;
        uint256[] memory shareUnits = new uint256[](2);
        shareUnits[0] = TOTAL_SHARE_UNITS;
        shareUnits[1] = 0;
        (, uint256 mintedTokens, uint256 usedCollateral) = minter.mintFromCollateral(
            collateral,
            recipients,
            shareUnits,
            TOTAL_SHARE_UNITS
        );
        require(mintedTokens == tokenAmount, "VaultTest: mint mismatch");
        mintedCollateral += usedCollateral;
    }

    function _collateralForTokens(uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        uint256 base = minter.baseCost();
        uint256 growth = minter.growthRate();
        uint256 startSupply = minter.totalMinted();

        // Integral cost for linear price curve:
        // base * m / 1e18 + growth * m * (2*start + m) / (2 * 1e36)
        uint256 baseComponent = Math.mulDiv(amount, base, 1e18);
        uint256 growthNumerator = amount * (2 * startSupply + amount);
        uint256 growthComponent = Math.mulDiv(growth, growthNumerator, 2 * 1e36);

        return baseComponent + growthComponent;
    }
}
