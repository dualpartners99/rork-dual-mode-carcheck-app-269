import Foundation

@Observable
@MainActor
class LoginURLRotationService {
    static let shared = LoginURLRotationService()

    var isIgnitionMode: Bool = false {
        didSet { persistState() }
    }

    private(set) var joeURLs: [RotatingURL] = []
    private(set) var ignitionURLs: [RotatingURL] = []
    private var joeIndex: Int = 0
    private var ignitionIndex: Int = 0

    private let persistKey = "login_url_rotation_state_v1"

    struct RotatingURL: Identifiable {
        let id: UUID = UUID()
        let urlString: String
        var isEnabled: Bool
        var lastFailure: Date?
        var failCount: Int
        var totalResponseTime: TimeInterval = 0
        var responseCount: Int = 0
        var successCount: Int = 0
        var totalAttempts: Int = 0

        var url: URL? { URL(string: urlString) }
        var host: String { URL(string: urlString)?.host ?? urlString }

        var averageResponseTime: TimeInterval {
            responseCount > 0 ? totalResponseTime / Double(responseCount) : .infinity
        }

        var successRate: Double {
            totalAttempts > 0 ? Double(successCount) / Double(totalAttempts) : 0.5
        }

        var performanceScore: Double {
            guard totalAttempts >= 2 else { return 0.5 }
            let speedScore: Double
            if averageResponseTime < 3 { speedScore = 1.0 }
            else if averageResponseTime < 6 { speedScore = 0.7 }
            else if averageResponseTime < 10 { speedScore = 0.4 }
            else { speedScore = 0.1 }
            return (successRate * 0.6) + (speedScore * 0.4)
        }

        var formattedAvgResponse: String {
            responseCount > 0 ? String(format: "%.1fs", averageResponseTime) : "—"
        }

        var formattedSuccessRate: String {
            totalAttempts > 0 ? String(format: "%.0f%%", successRate * 100) : "—"
        }
    }

    init() {
        joeURLs = Self.defaultJoeURLStrings.map { RotatingURL(urlString: $0, isEnabled: true, lastFailure: nil, failCount: 0) }
        ignitionURLs = Self.defaultIgnitionURLStrings.map { RotatingURL(urlString: $0, isEnabled: true, lastFailure: nil, failCount: 0) }
        loadState()
    }

    static let defaultJoeURLStrings: [String] = [
        "https://joefortune.com/login",
        "https://joefortune.eu/login",
        "https://joefortune.club/login",
        "https://joefortune.eu.com/login",
        "https://joefortune.fun/login",
        "https://joefortune.lv/login",
        "https://joefortune.ooo/login",
        "https://joefortune24.com/login",
        "https://joefortune36.com/login",
        "https://joefortuneonlinepokies.com/login",
        "https://joefortuneonlinepokies.eu/login",
        "https://joefortuneonlinepokies.net/login",
        "https://joefortunepokies.com/login",
        "https://joefortunepokies.eu/login",
        "https://joefortunepokies.net/login",
    ]

    static let defaultIgnitionURLStrings: [String] = [
        "https://ignitioncasino.lat/login",
        "https://ignitioncasino.cool/login",
        "https://ignitioncasino.fun/login",
        "https://ignitioncasino.ooo/login",
        "https://ignition231.com/login",
        "https://ignition165.com/login",
        "https://ignition551.com/login",
        "https://ignitionpoker.net/login",
        "https://ignitionpoker.net.lv/login",
        "https://ignitionpoker.eu/login",
        "https://ignitioncasino.net/login",
        "https://ignitionpoker.com/login",
        "https://ignitioncasino.buzz/login",
        "https://ignitioncasino.com/login",
        "https://ignitioncasino.org.lv/login",
        "https://ignitioncasino.net.lv/login",
        "https://ignitioncasino.ltd/login",
        "https://ignitioncasino.lv/login",
        "https://ignitioncasino.eu/login",
        "https://ignitioncasino.eu.com/login",
    ]

    var activeURLs: [RotatingURL] {
        isIgnitionMode ? ignitionURLs : joeURLs
    }

    var enabledURLs: [RotatingURL] {
        activeURLs.filter(\.isEnabled)
    }

    var currentSiteName: String {
        isIgnitionMode ? "Ignition Casino" : "Joe Fortune"
    }

    var currentIcon: String {
        isIgnitionMode ? "flame.fill" : "suit.spade.fill"
    }

    func nextURL() -> URL? {
        let urls = enabledURLs
        guard !urls.isEmpty else { return nil }

        let hasPerformanceData = urls.contains { $0.totalAttempts >= 2 }

        if hasPerformanceData {
            return weightedRandomURL(from: urls)
        }

        if isIgnitionMode {
            ignitionIndex = ignitionIndex % urls.count
            let url = urls[ignitionIndex].url
            ignitionIndex += 1
            return url
        } else {
            joeIndex = joeIndex % urls.count
            let url = urls[joeIndex].url
            joeIndex += 1
            return url
        }
    }

    private func weightedRandomURL(from urls: [RotatingURL]) -> URL? {
        let scores = urls.map { max($0.performanceScore, 0.05) }
        let totalWeight = scores.reduce(0, +)
        var random = Double.random(in: 0..<totalWeight)

        for (index, score) in scores.enumerated() {
            random -= score
            if random <= 0 {
                return urls[index].url
            }
        }
        return urls.last?.url
    }

    func reportFailure(urlString: String) {
        if let idx = joeURLs.firstIndex(where: { $0.urlString == urlString }) {
            joeURLs[idx].failCount += 1
            joeURLs[idx].lastFailure = Date()
            joeURLs[idx].totalAttempts += 1
            if joeURLs[idx].failCount >= 2 {
                joeURLs[idx].isEnabled = false
            }
        }
        if let idx = ignitionURLs.firstIndex(where: { $0.urlString == urlString }) {
            ignitionURLs[idx].failCount += 1
            ignitionURLs[idx].lastFailure = Date()
            ignitionURLs[idx].totalAttempts += 1
            if ignitionURLs[idx].failCount >= 2 {
                ignitionURLs[idx].isEnabled = false
            }
        }
        persistState()
    }

    func reportSuccess(urlString: String) {
        if let idx = joeURLs.firstIndex(where: { $0.urlString == urlString }) {
            joeURLs[idx].failCount = 0
            joeURLs[idx].successCount += 1
            joeURLs[idx].totalAttempts += 1
        }
        if let idx = ignitionURLs.firstIndex(where: { $0.urlString == urlString }) {
            ignitionURLs[idx].failCount = 0
            ignitionURLs[idx].successCount += 1
            ignitionURLs[idx].totalAttempts += 1
        }
    }

    func reportResponseTime(urlString: String, duration: TimeInterval) {
        if let idx = joeURLs.firstIndex(where: { $0.urlString == urlString }) {
            joeURLs[idx].totalResponseTime += duration
            joeURLs[idx].responseCount += 1
        }
        if let idx = ignitionURLs.firstIndex(where: { $0.urlString == urlString }) {
            ignitionURLs[idx].totalResponseTime += duration
            ignitionURLs[idx].responseCount += 1
        }
    }

    func resetPerformanceStats() {
        for i in joeURLs.indices {
            joeURLs[i].totalResponseTime = 0
            joeURLs[i].responseCount = 0
            joeURLs[i].successCount = 0
            joeURLs[i].totalAttempts = 0
        }
        for i in ignitionURLs.indices {
            ignitionURLs[i].totalResponseTime = 0
            ignitionURLs[i].responseCount = 0
            ignitionURLs[i].successCount = 0
            ignitionURLs[i].totalAttempts = 0
        }
        persistState()
    }

    func toggleURL(id: UUID, enabled: Bool) {
        if let idx = joeURLs.firstIndex(where: { $0.id == id }) {
            joeURLs[idx].isEnabled = enabled
            joeURLs[idx].failCount = enabled ? 0 : joeURLs[idx].failCount
        }
        if let idx = ignitionURLs.firstIndex(where: { $0.id == id }) {
            ignitionURLs[idx].isEnabled = enabled
            ignitionURLs[idx].failCount = enabled ? 0 : ignitionURLs[idx].failCount
        }
        persistState()
    }

    func enableAllURLs() {
        for i in joeURLs.indices {
            joeURLs[i].isEnabled = true
            joeURLs[i].failCount = 0
            joeURLs[i].lastFailure = nil
        }
        for i in ignitionURLs.indices {
            ignitionURLs[i].isEnabled = true
            ignitionURLs[i].failCount = 0
            ignitionURLs[i].lastFailure = nil
        }
        persistState()
    }

    var topPerformingURLs: [RotatingURL] {
        enabledURLs.filter { $0.totalAttempts >= 2 }.sorted { $0.performanceScore > $1.performanceScore }
    }

    private func persistState() {
        var disabledJoe: [String] = []
        for u in joeURLs where !u.isEnabled { disabledJoe.append(u.urlString) }
        var disabledIgnition: [String] = []
        for u in ignitionURLs where !u.isEnabled { disabledIgnition.append(u.urlString) }

        var perfJoe: [String: [String: Double]] = [:]
        for u in joeURLs where u.totalAttempts > 0 {
            perfJoe[u.urlString] = [
                "totalResponseTime": u.totalResponseTime,
                "responseCount": Double(u.responseCount),
                "successCount": Double(u.successCount),
                "totalAttempts": Double(u.totalAttempts),
            ]
        }
        var perfIgnition: [String: [String: Double]] = [:]
        for u in ignitionURLs where u.totalAttempts > 0 {
            perfIgnition[u.urlString] = [
                "totalResponseTime": u.totalResponseTime,
                "responseCount": Double(u.responseCount),
                "successCount": Double(u.successCount),
                "totalAttempts": Double(u.totalAttempts),
            ]
        }

        let dict: [String: Any] = [
            "isIgnitionMode": isIgnitionMode,
            "disabledJoe": disabledJoe,
            "disabledIgnition": disabledIgnition,
            "perfJoe": perfJoe,
            "perfIgnition": perfIgnition,
        ]
        UserDefaults.standard.set(dict, forKey: persistKey)
    }

    private func loadState() {
        guard let dict = UserDefaults.standard.dictionary(forKey: persistKey) else { return }
        if let mode = dict["isIgnitionMode"] as? Bool { isIgnitionMode = mode }
        if let disabled = dict["disabledJoe"] as? [String] {
            for url in disabled {
                if let idx = joeURLs.firstIndex(where: { $0.urlString == url }) {
                    joeURLs[idx].isEnabled = false
                }
            }
        }
        if let disabled = dict["disabledIgnition"] as? [String] {
            for url in disabled {
                if let idx = ignitionURLs.firstIndex(where: { $0.urlString == url }) {
                    ignitionURLs[idx].isEnabled = false
                }
            }
        }
        if let perfJoe = dict["perfJoe"] as? [String: [String: Double]] {
            for (urlStr, stats) in perfJoe {
                if let idx = joeURLs.firstIndex(where: { $0.urlString == urlStr }) {
                    joeURLs[idx].totalResponseTime = stats["totalResponseTime"] ?? 0
                    joeURLs[idx].responseCount = Int(stats["responseCount"] ?? 0)
                    joeURLs[idx].successCount = Int(stats["successCount"] ?? 0)
                    joeURLs[idx].totalAttempts = Int(stats["totalAttempts"] ?? 0)
                }
            }
        }
        if let perfIgnition = dict["perfIgnition"] as? [String: [String: Double]] {
            for (urlStr, stats) in perfIgnition {
                if let idx = ignitionURLs.firstIndex(where: { $0.urlString == urlStr }) {
                    ignitionURLs[idx].totalResponseTime = stats["totalResponseTime"] ?? 0
                    ignitionURLs[idx].responseCount = Int(stats["responseCount"] ?? 0)
                    ignitionURLs[idx].successCount = Int(stats["successCount"] ?? 0)
                    ignitionURLs[idx].totalAttempts = Int(stats["totalAttempts"] ?? 0)
                }
            }
        }
    }
}
