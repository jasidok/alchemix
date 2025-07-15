// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "../src/base/Multicall.sol";
import "../src/base/MutexLock.sol";

contract TestContract is Multicall, MutexLock {
    uint256 public count = 0;
    
    function incrementCounter() external lock {
        count++;
        // Simulate reentrancy by calling multicall directly
        if (count == 1) {
            bytes[] memory calls = new bytes[](1);
            calls[0] = abi.encodeWithSignature("incrementCounter()");
            // This will test if multicall can bypass the mutex
            this.multicall(calls);
        }
    }
}

contract SimpleTest is Test {
    TestContract testContract;
    
    function setUp() public {
        testContract = new TestContract();
    }
    
    function testDirectMulticallReentrancy() public {
        console2.log("=== DIRECT MULTICALL REENTRANCY TEST ===");
        console2.log("Initial count:", testContract.count());
        
        // Try direct call first (should work)
        testContract.incrementCounter();
        
        console2.log("Final count:", testContract.count());
        
        if (testContract.count() > 1) {
            console2.log("VULNERABILITY: Direct multicall bypassed mutex!");
        } else {
            console2.log("Mutex worked: Only single increment");
        }
    }
}
