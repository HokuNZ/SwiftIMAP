import ArgumentParser
import Foundation
import SwiftIMAP

struct Interactive: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start an interactive IMAP session"
    )

    @Option(name: .shortAndLong, help: "IMAP server hostname")
    var host: String

    @Option(name: .long, help: "IMAP server port")
    var port: Int = 993

    @Option(name: .shortAndLong, help: "Username for authentication")
    var username: String

    @Option(name: .shortAndLong, help: "Password for authentication")
    var password: String

    @ArgumentParser.Flag(name: .long, help: "Use STARTTLS instead of direct TLS")
    var starttls = false

    @ArgumentParser.Flag(name: .long, help: "Disable TLS (insecure)")
    var noTls = false

    @ArgumentParser.Flag(name: .shortAndLong, help: "Enable verbose logging")
    var verbose = false

    func run() async throws {
        let client = makeClient()

        print("Connecting to \(host):\(port)...")

        do {
            try await client.connect()
            print("✓ Connected and authenticated successfully")
            print("\nType 'help' for available commands, 'quit' to exit")
            await runSession(client: client)
        } catch {
            print("Connection error: \(error)")
            await client.disconnect()
            throw ExitCode.failure
        }
    }

    private func makeClient() -> IMAPClient {
        let config = IMAPConfiguration(
            hostname: host,
            port: port,
            tlsMode: resolveTLSMode(),
            authMethod: .login(username: username, password: password),
            logLevel: verbose ? .debug : .info
        )

        return IMAPClient(configuration: config)
    }

    private func resolveTLSMode() -> IMAPConfiguration.TLSMode {
        if noTls {
            return .disabled
        }
        if starttls {
            return .startTLS
        }
        return .requireTLS
    }
}
