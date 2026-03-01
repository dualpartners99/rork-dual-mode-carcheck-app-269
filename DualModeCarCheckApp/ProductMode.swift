import SwiftUI

nonisolated enum ProductMode: String, CaseIterable, Sendable {
    case ppsr = "PPSR CarCheck Automation"
    case login = "Joe & Ignition Login Tester"

    var title: String { rawValue }
    var baseURL: String {
        switch self {
        case .ppsr: return "https://transact.ppsr.gov.au/CarCheck/"
        case .login: return "https://joefortune24.com/login"
        }
    }
}
