import Foundation

public final class IMAPClient: Sendable {
    let configuration: IMAPConfiguration
    let tlsConfiguration: TLSConfiguration
    let connection: ConnectionActor
    let retryHandler: RetryHandler
    let logger: Logger

    public init(configuration: IMAPConfiguration, tlsConfiguration: TLSConfiguration = TLSConfiguration()) {
        self.configuration = configuration
        self.tlsConfiguration = tlsConfiguration
        self.logger = Logger(label: "IMAPClient", level: configuration.logLevel)
        self.connection = ConnectionActor(configuration: configuration, tlsConfiguration: tlsConfiguration)
        self.retryHandler = RetryHandler(configuration: configuration.retryConfiguration, logger: logger)
    }
}
