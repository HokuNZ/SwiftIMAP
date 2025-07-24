import Foundation
@testable import SwiftIMAP

// Test envelope parsing with debug output
let parser = IMAPParser()

// Test case from failing test
let input = """
* 2 FETCH (ENVELOPE ("Mon, 7 Feb 1994 21:52:25 -0800" "Test" (("Terry Gray" NIL "gray" "cac.washington.edu")) NIL NIL (("Terry Gray" NIL "gray" "cac.washington.edu")) NIL NIL NIL "<B27397-0100000@cac.washington.edu>"))\r
A001 OK Fetch completed\r
"""

parser.append(Data(input.utf8))

do {
    let responses = try parser.parseResponses()
    print("Successfully parsed \(responses.count) responses")
    
    if let fetch = responses.first {
        print("First response: \(fetch)")
    }
} catch {
    print("Parse error: \(error)")
    
    // Try parsing just the address part
    let scanner = Scanner(string: "(\"Terry Gray\" NIL \"gray\" \"cac.washington.edu\")")
    scanner.charactersToBeSkipped = nil
    
    print("\nScanner test:")
    print("String: \(scanner.string)")
    print("Can scan '(': \(scanner.scanString("(") != nil)")
    scanner.currentIndex = scanner.string.startIndex // Reset
    
    // Try to understand what's happening
    var index = 0
    while !scanner.isAtEnd && index < 20 {
        let char = scanner.scanCharacter()
        print("Char \(index): '\(char ?? "nil")' (Unicode: \(char?.unicodeScalars.first?.value ?? 0))")
        index += 1
    }
}