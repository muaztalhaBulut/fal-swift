import Foundation

/// Supplies headers for requests sent through ``FalClient.withProxy``.
///
/// The provider is evaluated for every proxied request so callers can attach
/// short-lived authorization material without caching it in the client. The
/// headers are never applied to direct FAL or presigned storage URLs.
public typealias ProxyHeadersProvider = () async throws -> [String: String]

public enum ClientCredentials: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .keyPair(value):
            return value
        case let .key(id: id, secret: secret):
            return "\(id):\(secret)"
        case .fromEnv:
            if let keyPair = ProcessInfo.processInfo.environment["FAL_KEY"] {
                return keyPair
            }

            if let keyId = ProcessInfo.processInfo.environment["FAL_KEY_ID"],
               let keySecret = ProcessInfo.processInfo.environment["FAL_KEY_SECRET"]
            {
                return "\(keyId):\(keySecret)"
            }
            return ""
        case let .custom(resolver):
            return resolver()
        }
    }

    case keyPair(_ pair: String)
    case key(id: String, secret: String)
    case fromEnv
    case custom(_ resolver: () -> String)
}

public struct ClientConfig {
    public let credentials: ClientCredentials
    public let requestProxy: String?
    let proxyHeadersProvider: ProxyHeadersProvider?
    let session: URLSession

    init(
        credentials: ClientCredentials = .fromEnv,
        requestProxy: String? = nil,
        proxyHeadersProvider: ProxyHeadersProvider? = nil,
        session: URLSession = .shared
    ) {
        self.credentials = credentials
        self.requestProxy = requestProxy
        self.proxyHeadersProvider = proxyHeadersProvider
        self.session = session
    }
}
