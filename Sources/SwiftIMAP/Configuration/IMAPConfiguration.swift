import Foundation
import NIOSSL

public struct IMAPConfiguration: Sendable {
    public let hostname: String
    public let port: Int
    public let tlsMode: TLSMode
    public let authMethod: AuthMethod
    public let connectionTimeout: TimeInterval
    public let commandTimeout: TimeInterval
    public let logLevel: LogLevel
    public let retryConfiguration: RetryConfiguration
    
    public init(
        hostname: String,
        port: Int = 993,
        tlsMode: TLSMode = .requireTLS,
        authMethod: AuthMethod,
        connectionTimeout: TimeInterval = 30,
        commandTimeout: TimeInterval = 60,
        logLevel: LogLevel = .info,
        retryConfiguration: RetryConfiguration = .default
    ) {
        self.hostname = hostname
        self.port = port
        self.tlsMode = tlsMode
        self.authMethod = authMethod
        self.connectionTimeout = connectionTimeout
        self.commandTimeout = commandTimeout
        self.logLevel = logLevel
        self.retryConfiguration = retryConfiguration
    }
    
    public enum TLSMode: Sendable {
        case requireTLS
        case startTLS
        case disabled
    }
    
    public enum AuthMethod: Sendable {
        case plain(username: String, password: String)
        case login(username: String, password: String)
        case oauth2(username: String, accessToken: String)
        case external
    }
    
    public enum LogLevel: Int, Sendable, Comparable {
        case none = 0
        case error = 1
        case warning = 2
        case info = 3
        case debug = 4
        case trace = 5
        
        public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }
}

public struct RetryConfiguration: Sendable {
    public let maxAttempts: Int
    public let initialDelay: TimeInterval
    public let maxDelay: TimeInterval
    public let multiplier: Double
    public let jitter: Double
    public let retryableErrors: Set<RetryableError>
    
    public init(
        maxAttempts: Int = 3,
        initialDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 60.0,
        multiplier: Double = 2.0,
        jitter: Double = 0.1,
        retryableErrors: Set<RetryableError> = .default
    ) {
        self.maxAttempts = maxAttempts
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.multiplier = multiplier
        self.jitter = jitter
        self.retryableErrors = retryableErrors
    }
    
    public static let `default` = RetryConfiguration()
    
    public static let aggressive = RetryConfiguration(
        maxAttempts: 5,
        initialDelay: 0.5,
        maxDelay: 30.0,
        multiplier: 1.5
    )
    
    public static let conservative = RetryConfiguration(
        maxAttempts: 2,
        initialDelay: 2.0,
        maxDelay: 120.0,
        multiplier: 3.0
    )
}

public enum RetryableError: Hashable, Sendable {
    case connectionLost
    case timeout
    case temporaryFailure
    case networkError
    case tlsHandshakeFailure
}

extension Set where Element == RetryableError {
    public static let `default`: Set<RetryableError> = [
        .connectionLost,
        .timeout,
        .networkError
    ]
}

public struct TLSConfiguration: Sendable {
    public let minimumTLSVersion: TLSVersion
    public let trustRoots: NIOSSLTrustRoots
    public let certificateVerification: CertificateVerification
    public let hostnameOverride: String?
    
    public init(
        minimumTLSVersion: TLSVersion = .tlsv12,
        trustRoots: NIOSSLTrustRoots = .default,
        certificateVerification: CertificateVerification = .fullVerification,
        hostnameOverride: String? = nil
    ) {
        self.minimumTLSVersion = minimumTLSVersion
        self.trustRoots = trustRoots
        self.certificateVerification = certificateVerification
        self.hostnameOverride = hostnameOverride
    }
}