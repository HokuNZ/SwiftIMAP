#!/usr/bin/env swift

import Foundation

let s = "From: sender@example.com\r\nTo: recipient@example.com\r\nSubject: Test Message\r\n\r\n"
print("Length: \(s.count)")
let data = s.data(using: .utf8)!
print("Last 4 bytes: \(Array(data.suffix(4)))")
print("As characters: \(s.suffix(4).debugDescription)")