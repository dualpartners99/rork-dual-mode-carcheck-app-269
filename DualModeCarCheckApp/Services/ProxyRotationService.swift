import Foundation
import Observation

@Observable
@MainActor
class ProxyRotationService {
    static let shared = ProxyRotationService()

    var savedProxies: [ProxyConfig] = []
    var currentProxyIndex: Int = 0
    var rotateAfterDisabled: Bool = true
    var lastImportReport: ImportReport?

    struct ImportReport {
        let added: Int
        let duplicates: Int
        let failed: [String]
        var total: Int { added + duplicates + failed.count }
    }

    private let persistKey = "saved_socks5_proxies_v2"

    init() {
        loadProxies()
    }

    func bulkImportSOCKS5(_ text: String) -> ImportReport {
        let rawLines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var expandedLines: [String] = []
        for line in rawLines {
            if line.contains("\t") {
                expandedLines.append(contentsOf: line.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            } else if line.contains(" ") && !line.contains("://") {
                expandedLines.append(contentsOf: line.components(separatedBy: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            } else {
                expandedLines.append(line)
            }
        }

        var added = 0
        var duplicates = 0
        var failed: [String] = []

        for line in expandedLines {
            if let proxy = parseProxyLine(line) {
                let isDuplicate = savedProxies.contains { $0.host == proxy.host && $0.port == proxy.port && $0.username == proxy.username }
                if isDuplicate {
                    duplicates += 1
                } else {
                    savedProxies.append(proxy)
                    added += 1
                }
            } else {
                failed.append(line)
            }
        }

        if added > 0 { persistProxies() }

        let report = ImportReport(added: added, duplicates: duplicates, failed: failed)
        lastImportReport = report
        return report
    }

    private func parseProxyLine(_ raw: String) -> ProxyConfig? {
        var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }

        let schemePatterns = ["socks5h://", "socks5://", "socks4://", "socks://", "http://", "https://"]
        for scheme in schemePatterns {
            if line.lowercased().hasPrefix(scheme) {
                line = String(line.dropFirst(scheme.count))
                break
            }
        }

        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))

        guard !line.isEmpty else { return nil }

        var username: String?
        var password: String?
        var hostPort: String

        if let atIndex = line.lastIndex(of: "@") {
            let authPart = String(line[line.startIndex..<atIndex])
            hostPort = String(line[line.index(after: atIndex)...])

            let authComponents = splitFirst(authPart, separator: ":")
            if let pw = authComponents.rest {
                username = authComponents.first
                password = pw
            } else {
                username = authPart
            }
        } else {
            let colonCount = line.filter({ $0 == ":" }).count
            if colonCount >= 3 {
                let parts = line.components(separatedBy: ":")
                if parts.count == 4, let _ = Int(parts[3]) {
                    username = parts[0]
                    password = parts[1]
                    hostPort = "\(parts[2]):\(parts[3])"
                } else if parts.count == 4, let _ = Int(parts[1]) {
                    hostPort = "\(parts[0]):\(parts[1])"
                    username = parts[2]
                    password = parts[3]
                } else {
                    hostPort = line
                }
            } else {
                hostPort = line
            }
        }

        hostPort = hostPort.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))

        guard !hostPort.isEmpty else { return nil }

        let hpParts = hostPort.components(separatedBy: ":")
        guard hpParts.count >= 2 else { return nil }

        let portString = hpParts.last?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let port = Int(portString), port > 0, port <= 65535 else { return nil }

        let host = hpParts.dropLast().joined(separator: ":").trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return nil }

        let validHostChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let hostChars = CharacterSet(charactersIn: host)
        guard validHostChars.isSuperset(of: hostChars) || isValidIPv4(host) else { return nil }

        if let u = username, u.isEmpty { username = nil }
        if let p = password, p.isEmpty { password = nil }

        return ProxyConfig(host: host, port: port, username: username, password: password)
    }

    private func splitFirst(_ s: String, separator: Character) -> (first: String, rest: String?) {
        if let idx = s.firstIndex(of: separator) {
            return (String(s[s.startIndex..<idx]), String(s[s.index(after: idx)...]))
        }
        return (s, nil)
    }

    private func isValidIPv4(_ host: String) -> Bool {
        let octets = host.components(separatedBy: ".")
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { octet in
            guard let num = Int(octet) else { return false }
            return num >= 0 && num <= 255
        }
    }

    func nextWorkingProxy() -> ProxyConfig? {
        let working = savedProxies.filter(\.isWorking)
        guard !working.isEmpty else {
            return savedProxies.isEmpty ? nil : savedProxies[currentProxyIndex % savedProxies.count]
        }
        currentProxyIndex = currentProxyIndex % working.count
        let proxy = working[currentProxyIndex]
        currentProxyIndex += 1
        return proxy
    }

    func markProxyWorking(_ proxy: ProxyConfig) {
        if let idx = savedProxies.firstIndex(where: { $0.id == proxy.id }) {
            savedProxies[idx].isWorking = true
            savedProxies[idx].lastTested = Date()
            savedProxies[idx].failCount = 0
            persistProxies()
        }
    }

    func markProxyFailed(_ proxy: ProxyConfig) {
        if let idx = savedProxies.firstIndex(where: { $0.id == proxy.id }) {
            savedProxies[idx].failCount += 1
            savedProxies[idx].lastTested = Date()
            if savedProxies[idx].failCount >= 3 {
                savedProxies[idx].isWorking = false
            }
            persistProxies()
        }
    }

    func removeProxy(_ proxy: ProxyConfig) {
        savedProxies.removeAll { $0.id == proxy.id }
        persistProxies()
    }

    func removeAll() {
        savedProxies.removeAll()
        currentProxyIndex = 0
        persistProxies()
    }

    func removeDead() {
        savedProxies.removeAll { !$0.isWorking && $0.lastTested != nil }
        persistProxies()
    }

    func resetAllStatus() {
        for i in savedProxies.indices {
            savedProxies[i].isWorking = false
            savedProxies[i].lastTested = nil
            savedProxies[i].failCount = 0
        }
        persistProxies()
    }

    func testAllProxies() async {
        await withTaskGroup(of: (Int, Bool).self) { group in
            for i in savedProxies.indices {
                let proxy = savedProxies[i]
                group.addTask {
                    let working = await self.testSingleProxy(proxy)
                    return (i, working)
                }
            }

            for await (index, working) in group {
                if index < savedProxies.count {
                    savedProxies[index].isWorking = working
                    savedProxies[index].lastTested = Date()
                    if working { savedProxies[index].failCount = 0 }
                }
            }
        }
        persistProxies()
    }

    private nonisolated func testSingleProxy(_ proxy: ProxyConfig) async -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 15
        var proxyDict: [String: Any] = [
            "SOCKSEnable": true,
            "SOCKSProxy": proxy.host,
            "SOCKSPort": proxy.port,
        ]
        if let u = proxy.username { proxyDict["SOCKSUser"] = u }
        if let p = proxy.password { proxyDict["SOCKSPassword"] = p }
        config.connectionProxyDictionary = proxyDict

        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let testURLs = [
            "https://httpbin.org/ip",
            "https://api.ipify.org?format=json",
            "https://ifconfig.me/ip"
        ]

        for urlString in testURLs {
            guard let url = URL(string: urlString) else { continue }
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = 10
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    return true
                }
            } catch {
                continue
            }
        }
        return false
    }

    func exportProxies() -> String {
        savedProxies.map { proxy in
            var result = ""
            if let u = proxy.username, let p = proxy.password {
                result = "socks5://\(u):\(p)@\(proxy.host):\(proxy.port)"
            } else {
                result = "socks5://\(proxy.host):\(proxy.port)"
            }
            return result
        }.joined(separator: "\n")
    }

    private func persistProxies() {
        let encoded = savedProxies.map { p -> [String: Any] in
            var dict: [String: Any] = [
                "id": p.id.uuidString,
                "host": p.host,
                "port": p.port,
                "isWorking": p.isWorking,
                "failCount": p.failCount,
            ]
            if let u = p.username { dict["username"] = u }
            if let pw = p.password { dict["password"] = pw }
            if let d = p.lastTested { dict["lastTested"] = d.timeIntervalSince1970 }
            return dict
        }
        if let data = try? JSONSerialization.data(withJSONObject: encoded) {
            UserDefaults.standard.set(data, forKey: persistKey)
        }
    }

    private func loadProxies() {
        guard let data = UserDefaults.standard.data(forKey: persistKey),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            migrateFromV1()
            return
        }

        savedProxies = array.compactMap { dict -> ProxyConfig? in
            guard let host = dict["host"] as? String,
                  let port = dict["port"] as? Int else { return nil }
            var proxy = ProxyConfig(
                host: host,
                port: port,
                username: dict["username"] as? String,
                password: dict["password"] as? String
            )
            proxy.isWorking = dict["isWorking"] as? Bool ?? false
            proxy.failCount = dict["failCount"] as? Int ?? 0
            if let ts = dict["lastTested"] as? TimeInterval {
                proxy.lastTested = Date(timeIntervalSince1970: ts)
            }
            return proxy
        }
    }

    private func migrateFromV1() {
        let v1Key = "saved_socks5_proxies_v1"
        guard let data = UserDefaults.standard.data(forKey: v1Key),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

        savedProxies = array.compactMap { dict -> ProxyConfig? in
            guard let host = dict["host"] as? String,
                  let port = dict["port"] as? Int else { return nil }
            var proxy = ProxyConfig(
                host: host,
                port: port,
                username: dict["username"] as? String,
                password: dict["password"] as? String
            )
            proxy.isWorking = dict["isWorking"] as? Bool ?? false
            if let ts = dict["lastTested"] as? TimeInterval {
                proxy.lastTested = Date(timeIntervalSince1970: ts)
            }
            return proxy
        }

        if !savedProxies.isEmpty {
            persistProxies()
            UserDefaults.standard.removeObject(forKey: v1Key)
        }
    }
}
