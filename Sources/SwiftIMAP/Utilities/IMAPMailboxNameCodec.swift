import Foundation

enum IMAPMailboxNameCodec {
    static func encode(_ input: String) -> String {
        var result = ""
        var utf16Buffer: [UInt16] = []
        var inBase64 = false
        
        for scalar in input.unicodeScalars {
            if scalar.value >= 0x20 && scalar.value <= 0x7E && scalar.value != 0x26 {
                if inBase64 {
                    result += encodeBase64(utf16Buffer) + "-"
                    utf16Buffer.removeAll()
                    inBase64 = false
                }
                result.append(Character(scalar))
            } else if scalar.value == 0x26 {
                if inBase64 {
                    result += encodeBase64(utf16Buffer) + "-"
                    utf16Buffer.removeAll()
                    inBase64 = false
                }
                result += "&-"
            } else {
                if !inBase64 {
                    result += "&"
                    inBase64 = true
                }
                
                let utf16 = Array(scalar.utf16)
                utf16Buffer.append(contentsOf: utf16)
            }
        }
        
        if inBase64 {
            result += encodeBase64(utf16Buffer) + "-"
        }
        
        return result
    }
    
    static func decode(_ input: String) -> String {
        var result = ""
        var index = input.startIndex
        
        while index < input.endIndex {
            if input[index] == "&" {
                let next = input.index(after: index)
                if next < input.endIndex && input[next] == "-" {
                    result.append("&")
                    index = input.index(after: next)
                    continue
                }
                
                guard let end = input[next...].firstIndex(of: "-") else {
                    result.append("&")
                    index = next
                    continue
                }
                
                let encoded = String(input[next..<end]).replacingOccurrences(of: ",", with: "/")
                var padded = encoded
                let remainder = padded.count % 4
                if remainder != 0 {
                    padded += String(repeating: "=", count: 4 - remainder)
                }
                
                if let data = Data(base64Encoded: padded) {
                    var scalars: [UInt16] = []
                    var dataIndex = data.startIndex
                    
                    while dataIndex < data.endIndex {
                        let high = data[dataIndex]
                        let lowIndex = data.index(after: dataIndex)
                        guard lowIndex < data.endIndex else { break }
                        let low = data[lowIndex]
                        scalars.append(UInt16(high) << 8 | UInt16(low))
                        dataIndex = data.index(lowIndex, offsetBy: 1)
                    }
                    
                    result += String(decoding: scalars, as: UTF16.self)
                } else {
                    result += "&" + String(input[next..<end]) + "-"
                }
                
                index = input.index(after: end)
            } else {
                result.append(input[index])
                index = input.index(after: index)
            }
        }
        
        return result
    }
    
    private static func encodeBase64(_ buffer: [UInt16]) -> String {
        var data = Data()
        for value in buffer {
            data.append(UInt8((value >> 8) & 0xFF))
            data.append(UInt8(value & 0xFF))
        }
        
        var base64 = data.base64EncodedString()
        base64 = base64.replacingOccurrences(of: "/", with: ",")
        base64 = base64.replacingOccurrences(of: "=", with: "")
        return base64
    }
}
