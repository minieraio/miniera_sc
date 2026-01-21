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

contract MinterTest is Test {
    Token public token;
    MockUSDC public usdc;
    Vault public vault;
    Minter public minter;
    
    address public owner;
    address public boardContract;
    address public user1;
    address public user2;
    address public constant airdropRecipient = address(0xdead);

    uint256 internal constant SHARE_SCALE = 1e18;
    uint256 internal constant TOTAL_SHARE_UNITS = 10_000 * SHARE_SCALE;

    function setUp() public {
        owner = address(this);
        boardContract = address(0x1);
        user1 = address(0x2);
        user2 = address(0x3);
        
        // Deploy contracts
        token = new Token();
        usdc = new MockUSDC();
        vault = new Vault(address(usdc), address(token));
        minter = new Minter(address(usdc), address(token), address(vault), 100 * 10**6, 100);
        
        // Setup relationships
        token.transferOwnership(address(minter));
        vault.setMinter(address(minter));
        minter.setBoardContract(boardContract);

        // Seed board contract with collateral and approval
        usdc.transfer(boardContract, 1_000_000 * 10**6);
        vm.prank(boardContract);
        usdc.approve(address(minter), type(uint256).max);
    }

    function _defaultDistribution()
        internal
        view
        returns (address[] memory recipients, uint256[] memory shareUnits)
    {
        recipients = new address[](3);
        recipients[0] = user1;
        recipients[1] = user2;
        recipients[2] = airdropRecipient;

        shareUnits = new uint256[](3);
        shareUnits[0] = 6_000 * SHARE_SCALE;
        shareUnits[1] = 4_000 * SHARE_SCALE;
        shareUnits[2] = 0;
    }

    function _currentUnitPrice() internal view returns (uint256) {
        uint256 dynamicComponent = Math.mulDiv(
            minter.growthRate(),
            minter.totalMinted(),
            1e18
        );
        return minter.baseCost() + dynamicComponent;
    }

    function _solveMint(uint256 collateral, uint256 startSupply)
        internal
        view
        returns (uint256 mintedTokens, uint256 collateralUsed)
    {
        uint256 base = minter.baseCost();
        uint256 growth = minter.growthRate();

        if (collateral == 0) return (0, 0);

        if (growth == 0) {
            mintedTokens = Math.mulDiv(collateral, 1e18, base);
            collateralUsed = Math.mulDiv(mintedTokens, base, 1e18);
            return (mintedTokens, collateralUsed);
        }

        // Quadratic coefficients (scaled by 2 * 1e36):
        // a = growth
        // b = 2 * (1e18 * base + growth * startSupply)
        // c = -2 * collateral * 1e36
        uint256 a = growth;
        uint256 b = 2 * (1e18 * base + growth * startSupply);
        uint256 c = 2 * collateral * 1e36;

        uint256 discriminant = b * b + 4 * a * c;
        uint256 sqrtDisc = Math.sqrt(discriminant);

        mintedTokens = (sqrtDisc - b) / (2 * a);

        collateralUsed = _costFor(startSupply, mintedTokens, base, growth);
        if (collateralUsed > collateral && mintedTokens > 0) {
            mintedTokens -= 1;
            collateralUsed = _costFor(startSupply, mintedTokens, base, growth);
        }
    }

    function _costFor(uint256 startSupply, uint256 mintAmount, uint256 base, uint256 growth)
        internal
        pure
        returns (uint256)
    {
        if (mintAmount == 0) return 0;
        uint256 baseComponent = Math.mulDiv(mintAmount, base, 1e18);
        uint256 growthNumerator = mintAmount * (2 * startSupply + mintAmount);
        uint256 growthComponent = Math.mulDiv(growth, growthNumerator, 2 * 1e36);
        return baseComponent + growthComponent;
    }

    function testInitialState() public {
        assertEq(minter.owner(), owner);
        assertEq(address(minter.gridToken()), address(token));
        assertEq(address(minter.vault()), address(vault));
        assertEq(minter.totalMinted(), 0);
        assertEq(minter.circulatingSupply(), 0);
        assertEq(minter.baseCost(), 100 * 10**6);
        assertEq(minter.growthRate(), 100);
        assertEq(minter.boardContract(), boardContract);
    }

    function testMint() public {
        uint256 collateral = 150_000 * 10**6;
        (address[] memory recipients, uint256[] memory shares) = _defaultDistribution();
        (uint256 expectedMint, uint256 expectedCost) = _solveMint(
            collateral,
            minter.totalMinted()
        );

        uint256 vaultBalanceBefore = usdc.balanceOf(address(vault));
        uint256 boardBalanceBefore = usdc.balanceOf(boardContract);

        vm.prank(boardContract);
        (uint256[] memory mintedAmounts, uint256 mintedTokens, uint256 collateralUsed) =
            minter.mintFromCollateral(collateral, recipients, shares, TOTAL_SHARE_UNITS);

        assertEq(mintedTokens, expectedMint);
        assertEq(collateralUsed, expectedCost);
        assertEq(minter.totalMinted(), mintedTokens);
        assertEq(minter.circulatingSupply(), mintedTokens);

        uint256 expectedUser1 = (mintedTokens * shares[0]) / TOTAL_SHARE_UNITS;
        uint256 expectedUser2 = (mintedTokens * shares[1]) / TOTAL_SHARE_UNITS;
        assertEq(token.balanceOf(user1), mintedAmounts[0]);
        assertEq(token.balanceOf(user2), mintedAmounts[1]);
        assertEq(mintedAmounts[0], expectedUser1);
        assertEq(mintedAmounts[1], expectedUser2);
        assertEq(
            usdc.balanceOf(address(vault)) - vaultBalanceBefore,
            collateralUsed
        );
        assertEq(
            boardBalanceBefore - usdc.balanceOf(boardContract),
            collateralUsed
        );
    }

    function testMintOnlyBoardContract() public {
        uint256 collateral = 100_000 * 10**6;
        (address[] memory recipients, uint256[] memory shares) = _defaultDistribution();

        vm.startPrank(user1);
        vm.expectRevert("Minter: Only board contract can mint");
        minter.mintFromCollateral(
            collateral,
            recipients,
            shares,
            TOTAL_SHARE_UNITS
        );
        vm.stopPrank();
    }

    function testMintArrayLengthMismatch() public {
        uint256 collateral = 50_000 * 10**6;
        address[] memory recipients = new address[](2);
        uint256[] memory shares = new uint256[](1);
        recipients[0] = user1;
        recipients[1] = user2;
        shares[0] = 6_000 * SHARE_SCALE;

        vm.startPrank(boardContract);
        vm.expectRevert("Minter: Arrays length mismatch");
        minter.mintFromCollateral(
            collateral,
            recipients,
            shares,
            TOTAL_SHARE_UNITS
        );
        vm.stopPrank();
    }

    function testMintRequiresShareTotal() public {
        uint256 collateral = 25_000 * 10**6;
        (address[] memory recipients, uint256[] memory shares) = _defaultDistribution();
        vm.startPrank(boardContract);
        vm.expectRevert("Minter: invalid share total");
        minter.mintFromCollateral(
            collateral,
            recipients,
            shares,
            0
        );
        vm.stopPrank();
    }

    function testMintWithoutAllowanceReverts() public {
        uint256 collateral = 10_000 * 10**6;
        (address[] memory recipients, uint256[] memory shares) = _defaultDistribution();

        vm.prank(boardContract);
        usdc.approve(address(minter), 0);

        vm.startPrank(boardContract);
        vm.expectRevert("MockUSDC: insufficient allowance");
        minter.mintFromCollateral(
            collateral,
            recipients,
            shares,
            TOTAL_SHARE_UNITS
        );
        vm.stopPrank();
    }

    function testBurnNotification() public {
        uint256 collateral = 75_000 * 10**6;
        (address[] memory recipients, uint256[] memory shares) = _defaultDistribution();

        vm.prank(boardContract);
        (, uint256 mintedTokens, ) = minter.mintFromCollateral(
            collateral,
            recipients,
            shares,
            TOTAL_SHARE_UNITS
        );
        
        uint256 burnAmount = 500 * 10**18;
        vm.prank(address(vault));
        minter.burnNotification(burnAmount);
        
        assertEq(minter.circulatingSupply(), mintedTokens - burnAmount);
    }

    function testBurnNotificationOnlyVault() public {
        uint256 burnAmount = 500 * 10**18;
        
        vm.prank(user1);
        vm.expectRevert();
        minter.burnNotification(burnAmount);
    }

    function testSetBaseCost() public {
        uint256 newBaseCost = 200 * 10**6;
        
        minter.setBaseCost(newBaseCost);
        assertEq(minter.baseCost(), newBaseCost);
    }

    function testSetBaseCostOnlyOwner() public {
        uint256 newBaseCost = 200 * 10**6;
        
        vm.prank(user1);
        vm.expectRevert();
        minter.setBaseCost(newBaseCost);
    }

    function testSetGrowthRate() public {
        uint256 newGrowthRate = 200;
        
        minter.setGrowthRate(newGrowthRate);
        assertEq(minter.growthRate(), newGrowthRate);
    }

    function testSetBoardContract() public {
        address newBoardContract = address(0x999);
        
        minter.setBoardContract(newBoardContract);
        assertEq(minter.boardContract(), newBoardContract);
    }

    function testSetVault() public {
        address newVault = address(0x888);
        
        minter.setVault(newVault);
        assertEq(address(minter.vault()), newVault);
    }

    function testIntegralPricingMatchesAverage() public {
        // Configure growth so price doubles after 1,000 tokens
        uint256 targetTokens = 1_000;
        uint256 base = minter.baseCost();
        uint256 expectedGrowth = base / targetTokens;
        minter.setGrowthRate(expectedGrowth);

        // Collateral equal to 1.5 * base * 1,000 should mint exactly 1,000 tokens
        uint256 collateral = (base * targetTokens * 3) / 2;
        (address[] memory recipients, uint256[] memory shares) = _defaultDistribution();

        vm.prank(boardContract);
        (, uint256 minted, uint256 collateralUsed) = minter.mintFromCollateral(
            collateral,
            recipients,
            shares,
            TOTAL_SHARE_UNITS
        );

        assertEq(minted, targetTokens * 1e18);
        assertApproxEqAbs(collateralUsed, collateral, 1); // allow 1-unit rounding
        assertEq(_currentUnitPrice(), base * 2); // next unit price is doubled
    }
}
