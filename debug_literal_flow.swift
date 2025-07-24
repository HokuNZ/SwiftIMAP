#!/usr/bin/env swift

// Debug the literal parsing flow step by step

let response = "* 1 FETCH (BODY[] {5}\r\nHello)\r\nA001 OK\r\n"
print("Full response: \(response.debugDescription)\n")

// Break it down into what the parser sees:
print("Step 1: First line extraction")
if let crlfIndex = response.firstIndex(of: "\r\n") {
    let firstLine = response[..<crlfIndex]
    print("  First line: \"\(firstLine)\"")
    print("  Contains literal marker: \(firstLine.contains("{5}"))")
    
    let afterFirst = response[response.index(crlfIndex, offsetBy: 2)...]
    print("  Remaining: \(String(afterFirst).debugDescription)")
    
    print("\nStep 2: After literal marker {5}, we need 5 bytes")
    let literalData = afterFirst.prefix(5)
    print("  Literal data: \"\(literalData)\"")
    
    let afterLiteral = afterFirst.dropFirst(5)
    print("  After literal: \(String(afterLiteral).debugDescription)")
    
    print("\nStep 3: The problem - what comes after the literal?")
    print("  Next character: '\(afterLiteral.first ?? " ")'")
    print("  Is it CRLF? \(afterLiteral.hasPrefix("\r\n"))")
    
    print("\nStep 4: Finding the next line")
    if let nextCrlf = afterLiteral.firstIndex(of: "\r\n") {
        let continuationPart = afterLiteral[..<nextCrlf]
        print("  Continuation of FETCH: \"\(continuationPart)\"")
        
        let nextLine = afterLiteral[afterLiteral.index(nextCrlf, offsetBy: 2)...]
        print("  Next complete line: \"\(nextLine.prefix(while: { $0 != "\r" }))\"")
    }
}