import Foundation
import Network

enum NetworkUtils {
    /// True when the endpoint's address belongs to a private/link-local/loopback range.
    /// Ensemble only accepts receivers from the local network.
    static func isLocalNetwork(_ endpoint: NWEndpoint?) -> Bool {
        guard let endpoint, case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let a):
            return isPrivateIPv4(a)
        case .ipv6(let a):
            if a.isIPv4Mapped, let v4 = a.asIPv4 { return isPrivateIPv4(v4) }
            return a.isLinkLocal || a.isUniqueLocal || a.isLoopback
        case .name(let n, _):
            return n == "localhost"
        @unknown default:
            return false
        }
    }

    private static func isPrivateIPv4(_ a: IPv4Address) -> Bool {
        let b = [UInt8](a.rawValue)
        guard b.count == 4 else { return false }
        if b[0] == 10 { return true }
        if b[0] == 172, (16...31).contains(b[1]) { return true }
        if b[0] == 192, b[1] == 168 { return true }
        if b[0] == 169, b[1] == 254 { return true }
        if b[0] == 127 { return true }
        return false
    }

    static func describe(_ endpoint: NWEndpoint?) -> String {
        guard let endpoint else { return "?" }
        switch endpoint {
        case .hostPort(let host, let port):
            var h = "\(host)"
            if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
            return "\(h):\(port)"
        case .service(let name, _, _, _):
            return name
        default:
            return "\(endpoint)"
        }
    }

    static func remoteHost(of connection: NWConnection) -> NWEndpoint.Host? {
        if case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint { return host }
        if case let .hostPort(host, _) = connection.endpoint { return host }
        return nil
    }
}
