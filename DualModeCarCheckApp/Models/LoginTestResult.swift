import Foundation

nonisolated struct LoginTestResult: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let success: Bool
    let duration: TimeInterval
    let errorMessage: String?
    let responseDetail: String?

    init(success: Bool, duration: TimeInterval, errorMessage: String? = nil, responseDetail: String? = nil, timestamp: Date? = nil) {
        self.id = UUID()
        self.timestamp = timestamp ?? Date()
        self.success = success
        self.duration = duration
        self.errorMessage = errorMessage
        self.responseDetail = responseDetail
    }

    var formattedDuration: String {
        String(format: "%.1fs", duration)
    }

    var formattedDate: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: timestamp)
    }

    var formattedTime: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: timestamp)
    }
}
