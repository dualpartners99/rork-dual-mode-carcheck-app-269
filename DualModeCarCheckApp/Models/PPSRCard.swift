import Foundation
import Observation

nonisolated enum CardBrand: String, Sendable, Codable {
    case visa = "Visa"
    case mastercard = "Mastercard"
    case amex = "Amex"
    case jcb = "JCB"
    case discover = "Discover"
    case dinersClub = "Diners"
    case unionPay = "UnionPay"
    case unknown = "Card"

    var iconName: String {
        switch self {
        case .visa: "v.circle.fill"
        case .mastercard: "m.circle.fill"
        case .amex: "a.circle.fill"
        case .jcb: "j.circle.fill"
        case .discover: "d.circle.fill"
        case .dinersClub: "d.circle.fill"
        case .unionPay: "u.circle.fill"
        case .unknown: "creditcard.fill"
        }
    }

    var brandColor: String {
        switch self {
        case .visa: "blue"
        case .mastercard: "orange"
        case .amex: "green"
        case .jcb: "red"
        case .discover: "purple"
        case .dinersClub: "indigo"
        case .unionPay: "teal"
        case .unknown: "gray"
        }
    }

    static func detect(_ number: String) -> CardBrand {
        let n = number.filter { $0.isNumber }
        if n.hasPrefix("4") { return .visa }
        if n.hasPrefix("34") || n.hasPrefix("37") { return .amex }
        if n.hasPrefix("35") { return .jcb }
        if n.hasPrefix("36") || n.hasPrefix("38") || n.hasPrefix("300") || n.hasPrefix("301") || n.hasPrefix("302") || n.hasPrefix("303") || n.hasPrefix("304") || n.hasPrefix("305") { return .dinersClub }
        if n.hasPrefix("6011") || n.hasPrefix("65") || n.hasPrefix("644") || n.hasPrefix("645") || n.hasPrefix("646") || n.hasPrefix("647") || n.hasPrefix("648") || n.hasPrefix("649") { return .discover }
        if n.hasPrefix("62") { return .unionPay }
        if n.hasPrefix("5") || n.hasPrefix("2") { return .mastercard }
        return .unknown
    }
}

nonisolated enum CardStatus: String, Sendable, Codable {
    case untested = "Untested"
    case testing = "Testing"
    case working = "Working"
    case dead = "Dead"
}

@Observable
class PPSRCard: Identifiable {
    private(set) var id: String
    let number: String
    let expiryMonth: String
    let expiryYear: String
    let cvv: String
    let brand: CardBrand
    private(set) var addedAt: Date
    var status: CardStatus
    var testResults: [PPSRTestResult]
    var binData: PPSRBINData?

    var binPrefix: String {
        String(number.prefix(6))
    }

    var displayNumber: String {
        number
    }

    var pipeFormat: String {
        "\(number)|\(expiryMonth)|\(expiryYear)|\(cvv)"
    }

    func overrideId(_ newId: String) {
        id = newId
    }

    func overrideAddedAt(_ date: Date) {
        addedAt = date
    }

    var formattedExpiry: String {
        "\(expiryMonth)/\(expiryYear)"
    }

    var totalTests: Int { testResults.count }
    var successCount: Int { testResults.filter { $0.success }.count }
    var failureCount: Int { testResults.filter { !$0.success }.count }

    var successRate: Double {
        guard totalTests > 0 else { return 0 }
        return Double(successCount) / Double(totalTests)
    }

    var lastTestedAt: Date? {
        testResults.first?.timestamp
    }

    var lastTestSuccess: Bool? {
        testResults.first?.success
    }

    var countryDisplay: String {
        binData?.country ?? ""
    }

    var issuerDisplay: String {
        binData?.issuer ?? ""
    }

    var cardTypeDisplay: String {
        binData?.type ?? ""
    }

    init(number: String, expiryMonth: String, expiryYear: String, cvv: String) {
        self.id = UUID().uuidString
        self.number = number
        self.expiryMonth = Self.sanitizeTwoDigit(expiryMonth)
        self.expiryYear = Self.sanitizeTwoDigit(expiryYear)
        self.cvv = cvv
        self.brand = CardBrand.detect(number)
        self.addedAt = Date()
        self.status = .untested
        self.testResults = []
    }

    func recordResult(success: Bool, vin: String, duration: TimeInterval, error: String? = nil) {
        let result = PPSRTestResult(
            success: success,
            vin: vin,
            duration: duration,
            errorMessage: error
        )
        testResults.insert(result, at: 0)

        if success {
            status = .working
        } else {
            status = .dead
        }
    }

    func applyCorrection(success: Bool) {
        if success {
            status = .working
        } else {
            status = .dead
        }
        if let latest = testResults.first {
            let corrected = PPSRTestResult(
                success: success,
                vin: latest.vin,
                duration: latest.duration,
                errorMessage: success ? nil : "Manually marked as fail"
            )
            testResults[0] = corrected
        }
    }

    func loadBINData() async {
        let data = await BINLookupService.shared.lookup(bin: binPrefix)
        binData = data
    }

    static func sanitizeTwoDigit(_ value: String) -> String {
        let digits = value.filter { $0.isNumber }
        if digits.count >= 2 {
            return String(digits.suffix(2))
        } else if digits.count == 1 {
            return "0\(digits)"
        }
        return "00"
    }

    static func smartParse(_ input: String) -> [PPSRCard] {
        let lines = input.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var cards: [PPSRCard] = []
        for line in lines {
            if let card = parseLine(line) {
                cards.append(card)
            }
        }
        return cards
    }

    static func parseLine(_ line: String) -> PPSRCard? {
        let separators: [String] = ["|", ":", ";", ",", "\t", " "]

        for sep in separators {
            let parts = line.components(separatedBy: sep)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if parts.count >= 4 {
                if let card = tryBuildCard(from: parts) {
                    return card
                }
            }
        }

        let digits = extractDigitGroups(from: line)
        if digits.count >= 4 {
            if let card = tryBuildCard(from: digits) {
                return card
            }
        }

        return nil
    }

    private static func extractDigitGroups(from line: String) -> [String] {
        var groups: [String] = []
        var current = ""
        for char in line {
            if char.isNumber {
                current.append(char)
            } else {
                if !current.isEmpty {
                    groups.append(current)
                    current = ""
                }
            }
        }
        if !current.isEmpty {
            groups.append(current)
        }
        return groups
    }

    private static func tryBuildCard(from parts: [String]) -> PPSRCard? {
        let cardNum = parts[0].filter { $0.isNumber }
        guard cardNum.count >= 13, cardNum.count <= 19 else { return nil }

        var month: String
        var year: String
        var cvv: String

        if parts.count >= 4 {
            let p1 = parts[1].filter { $0.isNumber }
            let p2 = parts[2].filter { $0.isNumber }
            let p3 = parts[3].filter { $0.isNumber }

            if p1.count <= 2 && p2.count <= 4 && p3.count >= 3 {
                month = p1
                year = p2
                cvv = p3
            } else if p1.count == 4 && p1.hasPrefix("20") {
                year = String(p1.suffix(2))
                month = p2
                cvv = p3
            } else if parts[1].contains("/") {
                let expParts = parts[1].components(separatedBy: "/")
                if expParts.count == 2 {
                    month = expParts[0].filter { $0.isNumber }
                    year = expParts[1].filter { $0.isNumber }
                    cvv = p2
                } else {
                    month = p1
                    year = p2
                    cvv = p3
                }
            } else {
                month = p1
                year = p2
                cvv = p3
            }
        } else if parts.count == 3 {
            let expStr = parts[1]
            if expStr.contains("/") {
                let expParts = expStr.components(separatedBy: "/")
                guard expParts.count == 2 else { return nil }
                month = expParts[0].filter { $0.isNumber }
                year = expParts[1].filter { $0.isNumber }
            } else {
                let digits = expStr.filter { $0.isNumber }
                guard digits.count == 4 else { return nil }
                month = String(digits.prefix(2))
                year = String(digits.suffix(2))
            }
            cvv = parts[2].filter { $0.isNumber }
        } else {
            return nil
        }

        let sanitizedMonth = sanitizeTwoDigit(month)
        guard let monthInt = Int(sanitizedMonth), monthInt >= 1, monthInt <= 12 else { return nil }
        guard cvv.count >= 3, cvv.count <= 4 else { return nil }

        let sanitizedYear = sanitizeTwoDigit(year)

        return PPSRCard(number: cardNum, expiryMonth: sanitizedMonth, expiryYear: sanitizedYear, cvv: String(cvv.prefix(4)))
    }

    static func fromPipeFormat(_ input: String) -> PPSRCard? {
        return parseLine(input)
    }
}
