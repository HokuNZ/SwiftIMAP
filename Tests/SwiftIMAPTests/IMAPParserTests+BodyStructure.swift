import XCTest
@testable import SwiftIMAP

extension IMAPParserTests {
    func testParseBodyStructureMultipartFields() throws {
        let input = "* 1 FETCH (BODYSTRUCTURE ((\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" 1152 23 NIL NIL NIL NIL) (\"TEXT\" \"HTML\" (\"CHARSET\" \"UTF-8\") NIL NIL \"QUOTED-PRINTABLE\" 2048 45 NIL NIL NIL NIL) \"MIXED\" (\"BOUNDARY\" \"abc\") (\"INLINE\" (\"FILENAME\" \"demo\")) (\"EN\" \"US\") \"loc\" (\"EXT\" \"VALUE\")))\r\n"
        parser.append(Data(input.utf8))

        let responses = try parser.parseResponses()

        guard case .untagged(.fetch(_, let attributes)) = responses.first else {
            return XCTFail("Expected FETCH response")
        }

        guard let bodyStructure = attributes.compactMap({
            if case .bodyStructure(let data) = $0 { return data }
            return nil
        }).first else {
            return XCTFail("Expected BODYSTRUCTURE attribute")
        }

        XCTAssertEqual(bodyStructure.subtype, "MIXED")
        XCTAssertEqual(bodyStructure.parameters?["boundary"], "abc")
        XCTAssertEqual(bodyStructure.disposition?.type, "INLINE")
        XCTAssertEqual(bodyStructure.disposition?.parameters?["filename"], "demo")
        XCTAssertEqual(bodyStructure.language ?? [], ["EN", "US"])
        XCTAssertEqual(bodyStructure.location, "loc")
        XCTAssertEqual(bodyStructure.extensions ?? [], ["(EXT VALUE)"])
        XCTAssertEqual(bodyStructure.parts?.count, 2)
    }

    func testParseBodyStructureSinglePartExtensions() throws {
        let input = "* 1 FETCH (BODYSTRUCTURE (\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" 12 1 \"md5hash\" (\"ATTACHMENT\" (\"FILENAME\" \"a.txt\")) \"EN\" \"loc\" (\"X\" \"Y\")))\r\n"
        parser.append(Data(input.utf8))

        let responses = try parser.parseResponses()

        guard case .untagged(.fetch(_, let attributes)) = responses.first else {
            return XCTFail("Expected FETCH response")
        }

        guard let bodyStructure = attributes.compactMap({
            if case .bodyStructure(let data) = $0 { return data }
            return nil
        }).first else {
            return XCTFail("Expected BODYSTRUCTURE attribute")
        }

        XCTAssertEqual(bodyStructure.md5, "md5hash")
        XCTAssertEqual(bodyStructure.disposition?.type, "ATTACHMENT")
        XCTAssertEqual(bodyStructure.disposition?.parameters?["filename"], "a.txt")
        XCTAssertEqual(bodyStructure.language ?? [], ["EN"])
        XCTAssertEqual(bodyStructure.location, "loc")
        XCTAssertEqual(bodyStructure.extensions ?? [], ["(X Y)"])
    }
}
