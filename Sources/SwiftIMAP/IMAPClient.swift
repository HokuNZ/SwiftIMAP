import Foundation

/// A client for a single IMAP connection.
///
/// ## Concurrency
///
/// An `IMAPClient` wraps one connection with one selected mailbox, so its
/// mailbox-scoped operations (`fetchMessage`, `searchMessages`, `storeFlags`,
/// `moveMessage(s)`, `copyMessage(s)`, `expunge`, `deleteMessage(s)`, …) are
/// **not safe to run concurrently** on the same instance: each is a `SELECT`
/// followed by its commands, and a `SELECT` from another in-flight operation can
/// change the selected mailbox in between, so a command runs against the wrong
/// mailbox. Issue mailbox-scoped operations one at a time, or use a separate
/// `IMAPClient` per concurrent context. (`connect()` is the exception — its
/// concurrent calls coalesce safely.)
public final class IMAPClient: Sendable {
    let configuration: IMAPConfiguration
    let tlsConfiguration: TLSConfiguration
    let connection: ConnectionActor
    let retryHandler: RetryHandler
    let logger: Logger
    let connectCoordinator = ConnectCoordinator()

    public init(configuration: IMAPConfiguration, tlsConfiguration: TLSConfiguration = TLSConfiguration()) {
        self.configuration = configuration
        self.tlsConfiguration = tlsConfiguration
        self.logger = Logger(label: "IMAPClient", level: configuration.logLevel)
        self.connection = ConnectionActor(configuration: configuration, tlsConfiguration: tlsConfiguration)
        self.retryHandler = RetryHandler(configuration: configuration.retryConfiguration, logger: logger)
    }
}
