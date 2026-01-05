import Foundation

extension IMAPParser {
    func parseUntaggedResponseWithLiteral(_ line: String, literalData: Data) throws -> IMAPResponse {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard !parts.isEmpty else {
            throw IMAPError.parsingError("Empty untagged response")
        }

        let first = String(parts[0])
        let remainder = parts.count > 1 ? String(parts[1]) : ""

        if let number = UInt32(first) {
            return try parseNumericUntaggedResponseWithLiteral(number, remainder: remainder, literalData: literalData)
        } else {
            throw IMAPError.parsingError("Unexpected untagged response with literal")
        }
    }

    func parseUntaggedResponseWithMultipleLiterals(_ line: String, literalDataArray: [Data]) throws -> IMAPResponse {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard !parts.isEmpty else {
            throw IMAPError.parsingError("Empty untagged response")
        }

        let first = String(parts[0])
        let remainder = parts.count > 1 ? String(parts[1]) : ""

        if let number = UInt32(first) {
            return try parseNumericUntaggedResponseWithMultipleLiterals(number, remainder: remainder, literalDataArray: literalDataArray)
        } else {
            throw IMAPError.parsingError("Unexpected untagged response with multiple literals")
        }
    }

    func parseNumericUntaggedResponseWithLiteral(
        _ number: UInt32,
        remainder: String,
        literalData: Data
    ) throws -> IMAPResponse {
        let parts = remainder.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard !parts.isEmpty else {
            throw IMAPError.parsingError("Invalid numeric untagged response")
        }

        let command = String(parts[0]).uppercased()

        if command == "FETCH" {
            let fetchData = parts.count > 1 ? String(parts[1]) : ""
            let attributes = try parseFetchAttributesWithLiteral(fetchData, literalData: literalData)
            return .untagged(.fetch(number, attributes))
        } else {
            throw IMAPError.parsingError("Unexpected numeric response with literal: \(command)")
        }
    }

    func parseNumericUntaggedResponseWithMultipleLiterals(
        _ number: UInt32,
        remainder: String,
        literalDataArray: [Data]
    ) throws -> IMAPResponse {
        let parts = remainder.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard !parts.isEmpty else {
            throw IMAPError.parsingError("Invalid numeric untagged response")
        }

        let command = String(parts[0]).uppercased()

        if command == "FETCH" {
            let fetchData = parts.count > 1 ? String(parts[1]) : ""
            let attributes = try parseFetchAttributesWithMultipleLiterals(fetchData, literalDataArray: literalDataArray)
            return .untagged(.fetch(number, attributes))
        } else {
            throw IMAPError.parsingError("Unexpected numeric response with multiple literals: \(command)")
        }
    }

    func parseFetchAttributesWithLiteral(_ input: String, literalData: Data) throws -> [IMAPResponse.FetchAttribute] {
        return try withLiteralQueue([literalData]) {
            var literalDataQueue: [Data]? = nil
            return try parseFetchAttributesInternal(input, literalDataQueue: &literalDataQueue)
        }
    }

    func parseFetchAttributesWithMultipleLiterals(
        _ input: String,
        literalDataArray: [Data]
    ) throws -> [IMAPResponse.FetchAttribute] {
        return try withLiteralQueue(literalDataArray) {
            var literalDataQueue: [Data]? = nil
            return try parseFetchAttributesInternal(input, literalDataQueue: &literalDataQueue)
        }
    }
}
