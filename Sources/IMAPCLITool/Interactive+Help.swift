import Foundation

extension Interactive {
    func printHelp() {
        print("""
        Available commands:
          help, ?               - Show this help message
          quit, exit, bye      - Disconnect and exit
          list [pattern]       - List mailboxes (default pattern: *)
          select <mailbox>     - Select a mailbox
          status [mailbox]     - Show mailbox status
          messages             - List messages with details (subject, from, date)
          fetch <uid>          - Fetch a message by UID
          capability           - Show server capabilities
          close                - Close selected mailbox

        Search commands (require mailbox selected):
          search               - Search all messages
          search from <email>  - Search by sender email
          search subject <text> - Search by subject
          search text <text>   - Search in message body
          search unread        - Show unread messages
          search flagged       - Show flagged/starred messages
          search since <date>  - Messages since date (e.g., '7d' or '2024-01-01')

        Message manipulation commands (require mailbox selected):
          read <uid>           - Mark message as read
          unread <uid>         - Mark message as unread
          flag <uid>           - Flag message (star/important)
          unflag <uid>         - Remove flag from message
          copy <uid> <mailbox> - Copy message to another mailbox
          move <uid> <mailbox> - Move message to another mailbox
          delete <uid>         - Mark message for deletion
          expunge              - Permanently delete messages marked for deletion
        """)
    }
}
