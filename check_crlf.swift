#!/usr/bin/env swift

import Foundation

let crlf = "\r\n"
print("String '\\r\\n' character count: \(crlf.count)")
print("String '\\r\\n' utf8 count: \(crlf.utf8.count)")

let data = crlf.data(using: .utf8)!
print("Data byte count: \(data.count)")
print("Bytes: \(Array(data))")

// Now check the literal
let literal = "From: sender@example.com\r\nTo: recipient@example.com\r\nSubject: Test Message\r\n\r\n"
print("\nLiteral character count: \(literal.count)")  
print("Literal UTF-8 count: \(literal.utf8.count)")

let literalData = literal.data(using: .utf8)!
print("Literal data byte count: \(literalData.count)")