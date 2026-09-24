import XCTest
@testable import SwiftIMAP

/// `BodyStructure` as read from a `BODYSTRUCTURE` fetch: part numbering, attachment
/// metadata, and rebuilding a message from selected parts.
final class BodyStructureTests: XCTestCase {
    /// multipart/mixed ( multipart/alternative ( text/plain, text/html ), application/pdf ),
    /// the common shape of a message with one attachment.
    private let mixedWithAttachment = """
        * 1 FETCH (UID 7 BODYSTRUCTURE (((\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"QUOTED-PRINTABLE\" 12 1 NIL NIL NIL)\
        (\"TEXT\" \"HTML\" (\"CHARSET\" \"UTF-8\") NIL NIL \"QUOTED-PRINTABLE\" 22 1 NIL NIL NIL) \"ALTERNATIVE\" (\"BOUNDARY\" \"alt\") NIL NIL)\
        (\"APPLICATION\" \"PDF\" (\"NAME\" \"report.pdf\") NIL NIL \"BASE64\" 78000 NIL (\"ATTACHMENT\" (\"FILENAME\" \"report.pdf\")) NIL) \
        \"MIXED\" (\"BOUNDARY\" \"mix\") NIL NIL))\r\n
        """

    private func structure(from line: String) throws -> BodyStructure {
        let parser = IMAPParser()
        parser.append(Data(line.utf8))
        guard case .untagged(.fetch(_, let attributes))? = try parser.parseResponses().first,
              let data = attributes.compactMap({ attribute -> IMAPResponse.BodyStructureData? in
                  if case .bodyStructure(let data) = attribute { return data }
                  return nil
              }).first else {
            XCTFail("no BODYSTRUCTURE parsed from \(line)")
            throw IMAPError.parsingError("no BODYSTRUCTURE")
        }
        return BodyStructure(data)
    }

    private func leaf(
        _ type: String,
        _ subtype: String,
        parameters: [String: String] = [:],
        id: String? = nil,
        disposition: String? = nil,
        dispositionParameters: [String: String] = [:]
    ) -> BodyStructure {
        BodyStructure(type: type, subtype: subtype, parameters: parameters, id: id, encoding: "base64",
                      size: 100, disposition: disposition, dispositionParameters: dispositionParameters)
    }

    // MARK: - Sections

    func testSectionsNumberNestedPartsPositionally() throws {
        let sections = try structure(from: mixedWithAttachment).sections
        XCTAssertEqual(sections.map(\.number), ["1.1", "1.2", "2"])
        XCTAssertEqual(sections.map(\.part.mimeType), ["text/plain", "text/html", "application/pdf"])
    }

    func testASinglePartMessageIsPartOne() throws {
        let single = try structure(from: "* 1 FETCH (BODYSTRUCTURE (\"TEXT\" \"PLAIN\" (\"CHARSET\" \"US-ASCII\") NIL NIL \"7BIT\" 5 1))\r\n")
        XCTAssertEqual(single.sections.map(\.number), ["1"])
    }

    func testAnAttachedMessageIsOneLeaf() throws {
        let line = "* 1 FETCH (BODYSTRUCTURE ((\"TEXT\" \"PLAIN\" NIL NIL NIL \"7BIT\" 5 1)(\"MESSAGE\" \"RFC822\" NIL NIL NIL \"7BIT\" 300 "
            + "(NIL \"Inner\" NIL NIL NIL NIL NIL NIL NIL NIL) (\"TEXT\" \"PLAIN\" NIL NIL NIL \"7BIT\" 10 1) 12) \"MIXED\"))\r\n"
        XCTAssertEqual(try structure(from: line).sections.map(\.number), ["1", "2"])
    }

    // MARK: - Attachment metadata

    func testAttachmentMetadataComesFromTheStructure() throws {
        let sections = try structure(from: mixedWithAttachment).sections
        XCTAssertEqual(sections.map(\.part.isAttachment), [false, false, true])
        XCTAssertEqual(sections[2].part.filename, "report.pdf")
        XCTAssertEqual(sections[2].part.size, 78000)
        XCTAssertEqual(sections[2].part.estimatedDecodedSize, 57000)
    }

    func testAnInlineImageReferencedByContentIDIsNotAnAttachment() {
        let embedded = leaf("IMAGE", "PNG", id: "<logo@x>", disposition: "INLINE", dispositionParameters: ["filename": "logo.png"])
        XCTAssertFalse(embedded.isAttachment)
        let inlineButNamed = leaf("IMAGE", "PNG", disposition: "INLINE", dispositionParameters: ["filename": "photo.png"])
        XCTAssertTrue(inlineButNamed.isAttachment)
    }

    func testATextAttachmentIsAnAttachment() {
        XCTAssertTrue(leaf("TEXT", "CSV", disposition: "ATTACHMENT", dispositionParameters: ["filename": "data.csv"]).isAttachment)
        XCTAssertFalse(leaf("TEXT", "HTML").isAttachment)
    }

    func testFilenameFallsBackToTheContentTypeName() {
        XCTAssertEqual(leaf("APPLICATION", "PDF", parameters: ["name": "a.pdf"]).filename, "a.pdf")
        XCTAssertNil(leaf("APPLICATION", "PDF").filename)
    }

    func testFilenameDecodesRFC2231ExtendedValues() {
        let part = leaf("APPLICATION", "PDF", disposition: "ATTACHMENT",
                        dispositionParameters: ["filename*": "utf-8''R%C3%A9sum%C3%A9.pdf"])
        XCTAssertEqual(part.filename, "Résumé.pdf")
    }

    func testFilenameJoinsRFC2231Continuations() {
        let part = leaf("APPLICATION", "PDF", disposition: "ATTACHMENT", dispositionParameters: [
            "filename*0*": "utf-8''Quarterly%20",
            "filename*1": "report ",
            "filename*2*": "%E2%82%AC.pdf"
        ])
        XCTAssertEqual(part.filename, "Quarterly report €.pdf")
    }

    func testFilenameDecodesRFC2047EncodedWords() {
        let part = leaf("APPLICATION", "PDF", parameters: ["name": "=?UTF-8?B?w6l0w6kucGRm?="])
        XCTAssertEqual(part.filename, "été.pdf")
    }

    // MARK: - Summary

    func testSummaryCarriesTheStructureWhenFetched() throws {
        let parser = IMAPParser()
        parser.append(Data("* 1 FETCH (UID 7 INTERNALDATE \"24-Sep-2026 10:00:00 +1200\" RFC822.SIZE 80000 BODYSTRUCTURE (\"TEXT\" \"PLAIN\" NIL NIL NIL \"7BIT\" 5 1))\r\n".utf8))
        guard case .untagged(.fetch(let sequence, let attributes))? = try parser.parseResponses().first else {
            return XCTFail("expected a FETCH")
        }
        let client = IMAPClient(configuration: IMAPConfiguration(hostname: "example.com", authMethod: .login(username: "u", password: "p")))
        let summary = try client.parseMessageSummary(sequenceNumber: sequence, attributes: attributes)
        XCTAssertEqual(summary.bodyStructure?.mimeType, "text/plain")
    }

    // MARK: - Assembly

    func testAssemblingTheTextPartsGivesTheSameTextWithoutTheAttachment() throws {
        let structure = try structure(from: mixedWithAttachment)
        let message = try XCTUnwrap(structure.assembleMessage(sectionBodies: [
            "1.1": Data("Hello there=\r\n!".utf8),
            "1.2": Data("<p>Hello there!</p>".utf8)
        ]))
        let parsed = try XCTUnwrap(MessageSummary.parseMIMEContent(from: message))
        XCTAssertEqual(parsed.plainTextContent?.trimmingCharacters(in: .whitespacesAndNewlines), "Hello there!")
        XCTAssertEqual(parsed.htmlContent?.trimmingCharacters(in: .whitespacesAndNewlines), "<p>Hello there!</p>")
        XCTAssertTrue(parsed.attachments.isEmpty)
    }

    func testAssemblyKeepsTheCharsetSoNonASCIITextDecodes() throws {
        let structure = BodyStructure(type: "TEXT", subtype: "PLAIN", parameters: ["charset": "ISO-8859-1"],
                                      encoding: "8BIT", size: 4)
        let message = try XCTUnwrap(structure.assembleMessage(sectionBodies: ["1": Data([0x63, 0x61, 0x66, 0xE9])]))
        XCTAssertEqual(try MessageSummary.parseMIMEContent(from: message)?.plainTextContent, "café")
    }

    func testAssemblyWithNoBodiesIsNil() throws {
        XCTAssertNil(try structure(from: mixedWithAttachment).assembleMessage(sectionBodies: [:]))
    }
}
