import Foundation

nonisolated struct PPSRTestResult: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let success: Bool
    let vin: String
    let duration: TimeInterval
    let errorMessage: String?

    init(success: Bool, vin: String, duration: TimeInterval, errorMessage: String? = nil, timestamp: Date? = nil) {
        self.id = UUID()
        self.timestamp = timestamp ?? Date()
        self.success = success
        self.vin = vin
        self.duration = duration
        self.errorMessage = errorMessage
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
