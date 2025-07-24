#!/usr/bin/env swift

import Foundation

// Simulate the multiple literals test data
let response1 = "* 3 FETCH (BODY[1] {11}\r\n"
let literal1 = "Part 1 data"
let response2 = " BODY[2] {11}\r\n"
let literal2 = "Part 2 data"
let trailer = ")\r\nA003 OK Fetch completed\r\n"

// Show what the complete data looks like
let allData = response1 + literal1 + response2 + literal2 + trailer
print("=== Complete Response ===")
print(allData.debugDescription)
print("\n=== Breakdown ===")
print("1. First part: \(response1.debugDescription)")
print("2. Literal 1: \"\(literal1)\" (\(literal1.count) bytes)")
print("3. Continuation: \(response2.debugDescription)") 
print("4. Literal 2: \"\(literal2)\" (\(literal2.count) bytes)")
print("5. Trailer: \(trailer.debugDescription)")

print("\n=== What parser sees after first literal ===")
// After processing first literal, the reconstructed line would be:
let afterFirstLiteral = "* 3 FETCH (BODY[1] {11}~LITERAL~ BODY[2] {11}"
print("Reconstructed: \"\(afterFirstLiteral)\"")
print("This line contains another literal marker!")

print("\n=== The issue ===")
print("Current parser tries to parse this as a complete FETCH response")
print("But it still has {11} which indicates another literal follows")
print("The parser doesn't handle multiple literals in a reconstructed line")