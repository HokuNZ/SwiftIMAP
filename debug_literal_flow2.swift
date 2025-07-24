#!/usr/bin/env swift

import Foundation

// Debug the literal parsing flow step by step

let response = "* 1 FETCH (BODY[] {5}\r\nHello)\r\nA001 OK\r\n"
let data = response.data(using: .utf8)!

print("Full response: \(response.debugDescription)")
print("Total bytes: \(data.count)\n")

// Find first CRLF
if let firstCRLF = data.range(of: Data([0x0D, 0x0A])) {
    let firstLine = String(data: data[..<firstCRLF.lowerBound], encoding: .utf8)!
    print("Step 1: First line = \"\(firstLine)\"")
    
    // After first CRLF
    var pos = firstCRLF.upperBound
    print("  Position after first CRLF: \(pos)")
    
    // The literal size is 5, so read 5 bytes
    let literalData = data[pos..<(pos + 5)]
    let literalString = String(data: literalData, encoding: .utf8)!
    print("\nStep 2: Literal data (5 bytes) = \"\(literalString)\"")
    pos += 5
    
    print("\nStep 3: What's after the literal?")
    let remaining = data[pos...]
    let remainingString = String(data: remaining, encoding: .utf8)!
    print("  Remaining: \(remainingString.debugDescription)")
    print("  First char: '\(remainingString.first ?? " ")'")
    
    // The key insight: After the literal, we DON'T have a CRLF
    // The response continues with ")" which is part of the FETCH response
    
    print("\nStep 4: The complete FETCH response is:")
    print("  \"* 1 FETCH (BODY[] \" + <5 bytes of literal data> + \")\"")
    print("  = \"* 1 FETCH (BODY[] \" + \"Hello\" + \")\"")
}