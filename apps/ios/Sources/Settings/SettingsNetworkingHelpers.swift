import Foundation
import OpenClawKit

struct SettingsHostPort: Equatable {
    var host: String
    var port: Int
    var path: String?

    init(host: String, port: Int, path: String? = nil) {
        self.host = host
        self.port = port
        self.path = path
    }
}

enum SettingsNetworkingHelpers {
    static func parseHostPort(from address: String) -> SettingsHostPort? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let (authority, rawPath) = self.splitPath(trimmed)
        let normalizedPath = GatewayConnectDeepLink.normalizePath(rawPath)
        guard normalizedPath != .invalid else { return nil }
        let path = normalizedPath.value

        if authority.hasPrefix("["),
           let close = authority.firstIndex(of: "]"),
           close < authority.endIndex
        {
            let host = String(authority[authority.index(after: authority.startIndex)..<close])
            let portStart = authority.index(after: close)
            guard portStart < authority.endIndex, authority[portStart] == ":" else { return nil }
            let portString = String(authority[authority.index(after: portStart)...])
            guard let port = Int(portString) else { return nil }
            return SettingsHostPort(host: host, port: port, path: path)
        }

        guard let colon = authority.lastIndex(of: ":") else { return nil }
        let host = String(authority[..<colon])
        let portString = String(authority[authority.index(after: colon)...])
        guard !host.isEmpty, let port = Int(portString) else { return nil }
        return SettingsHostPort(host: host, port: port, path: path)
    }

    /// Split `host:port/route` into authority and route. The search starts after a
    /// bracketed IPv6 literal so its colons and the closing bracket are not mistaken
    /// for a path separator.
    private static func splitPath(_ address: String) -> (authority: String, path: String?) {
        let searchStart: String.Index = if address.hasPrefix("["),
                                           let close = address.firstIndex(of: "]")
        {
            address.index(after: close)
        } else {
            address.startIndex
        }
        guard searchStart < address.endIndex,
              let slash = address[searchStart...].firstIndex(of: "/")
        else { return (address, nil) }
        return (String(address[..<slash]), String(address[slash...]))
    }

    static func httpURLString(host: String?, port: Int?, path: String? = nil, fallback: String) -> String {
        if let host, let port {
            let needsBrackets = host.contains(":") && !host.hasPrefix("[") && !host.hasSuffix("]")
            let hostPart = needsBrackets ? "[\(host)]" : host
            let pathPart = GatewayConnectDeepLink.normalizePath(path).value ?? ""
            return "http://\(hostPart):\(port)\(pathPart)"
        }
        return "http://\(fallback)"
    }
}
