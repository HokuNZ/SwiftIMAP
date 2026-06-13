import Foundation

extension StringProtocol {
    /// Truncate untrusted server input before embedding it in a parser error.
    ///
    /// Parser errors include the offending input to aid debugging, but a malformed
    /// or oversized response line can contain message content (subjects, body
    /// fragments). Capping the length stops unbounded content from leaking into
    /// logs or crash reporters while keeping enough context to diagnose the parse.
    ///
    /// - Note: `limit` and the reported total are in `Character` units (grapheme
    ///   clusters), not bytes, so a line of multi-byte characters yields a longer
    ///   byte string than `limit`. That is fine for bounding diagnostic output.
    func truncatedForDiagnostics(limit: Int = 200) -> String {
        let total = count
        guard total > limit else { return String(self) }
        return "\(prefix(limit))… (\(total) chars total, truncated)"
    }
}
