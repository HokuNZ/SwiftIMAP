import Foundation

extension IMAPEncoder {
    func encodeSearchCriteria(_ criteria: IMAPCommand.SearchCriteria) -> String {
        if let simple = encodeSimpleSearchCriteria(criteria) {
            return simple
        }

        switch criteria {
        case .keyword(let keyword):
            return "KEYWORD \(keyword)"
        case .unkeyword(let keyword):
            return "UNKEYWORD \(keyword)"
        case .before(let date):
            return "BEFORE \(formatSearchDate(date))"
        case .on(let date):
            return "ON \(formatSearchDate(date))"
        case .since(let date):
            return "SINCE \(formatSearchDate(date))"
        case .sentBefore(let date):
            return "SENTBEFORE \(formatSearchDate(date))"
        case .sentOn(let date):
            return "SENTON \(formatSearchDate(date))"
        case .sentSince(let date):
            return "SENTSINCE \(formatSearchDate(date))"
        case .from(let address):
            return "FROM \(quote(address))"
        case .to(let address):
            return "TO \(quote(address))"
        case .cc(let address):
            return "CC \(quote(address))"
        case .bcc(let address):
            return "BCC \(quote(address))"
        case .subject(let text):
            return "SUBJECT \(quote(text, force: true))"
        case .body(let text):
            return "BODY \(quote(text, force: true))"
        case .text(let text):
            return "TEXT \(quote(text, force: true))"
        case .header(let field, let value):
            return "HEADER \(quote(field)) \(quote(value))"
        case .larger(let size):
            return "LARGER \(size)"
        case .smaller(let size):
            return "SMALLER \(size)"
        case .uid(let sequence):
            return "UID \(sequence.stringValue)"
        case .not(let nested):
            return "NOT \(encodeSearchCriteria(nested))"
        case .or(let criteria1, let criteria2):
            return "OR \(encodeSearchCriteria(criteria1)) \(encodeSearchCriteria(criteria2))"
        case .and(let criteriaList):
            return criteriaList.map { encodeSearchCriteria($0) }.joined(separator: " ")
        case .sequence(let set):
            return set.stringValue
        case .all, .answered, .deleted, .draft, .flagged, .new, .old, .recent,
             .seen, .unanswered, .undeleted, .undraft, .unflagged, .unseen:
            return ""
        }
    }

    private func encodeSimpleSearchCriteria(_ criteria: IMAPCommand.SearchCriteria) -> String? {
        switch criteria {
        case .all:
            return "ALL"
        case .answered:
            return "ANSWERED"
        case .deleted:
            return "DELETED"
        case .draft:
            return "DRAFT"
        case .flagged:
            return "FLAGGED"
        case .new:
            return "NEW"
        case .old:
            return "OLD"
        case .recent:
            return "RECENT"
        case .seen:
            return "SEEN"
        case .unanswered:
            return "UNANSWERED"
        case .undeleted:
            return "UNDELETED"
        case .undraft:
            return "UNDRAFT"
        case .unflagged:
            return "UNFLAGGED"
        case .unseen:
            return "UNSEEN"
        default:
            return nil
        }
    }

    private func formatSearchDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd-MMM-yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return quote(formatter.string(from: date))
    }
}
