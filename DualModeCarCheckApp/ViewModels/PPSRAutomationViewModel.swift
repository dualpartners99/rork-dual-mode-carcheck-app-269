import Foundation
import SwiftUI
import BackgroundTasks

nonisolated struct BatchResult: Sendable {
    let working: Int
    let dead: Int
    let requeued: Int
    let total: Int

    var alivePercentage: Int {
        guard total > 0 else { return 0 }
        return Int(Double(working) / Double(total) * 100)
    }
}

@Observable
@MainActor
class PPSRAutomationViewModel {
    var cards: [PPSRCard] = []
    var checks: [PPSRCheck] = []
    var testEmail: String = "dev@test.ppsr.gov.au"
    var maxConcurrency: Int = 8
    var isRunning: Bool = false
    var isPaused: Bool = false
    var isStopping: Bool = false
    var globalLogs: [PPSRLogEntry] = []
    var connectionStatus: ConnectionStatus = .disconnected
    var lastDiagnostics: String = ""
    var activeTestCount: Int = 0
    var debugMode: Bool = false
    var debugScreenshots: [PPSRDebugScreenshot] = []
    var appearanceMode: AppearanceMode = .dark
    var useEmailRotation: Bool = false
    var stealthEnabled: Bool = true
    var retrySubmitOnFail: Bool = false
    var screenshotCropRect: CGRect = .zero
    var showBatchResultPopup: Bool = false
    var showUnusualFailureAlert: Bool = false
    var unusualFailureMessage: String = ""
    var consecutiveUnusualFailures: Int = 0
    var lastBatchResult: BatchResult?
    var testTimeout: TimeInterval = 30
    var diagnosticReport: DiagnosticReport?
    var isDiagnosticRunning: Bool = false
    var lastHealthCheck: (healthy: Bool, detail: String)?
    var autoHealAttempted: Bool = false
    var consecutiveConnectionFailures: Int = 0
    var fingerprintPassRate: String { FingerprintValidationService.shared.formattedPassRate }
    var fingerprintAvgScore: Double { FingerprintValidationService.shared.averageScore }
    var fingerprintHistory: [FingerprintValidationService.FingerprintScore] { FingerprintValidationService.shared.scoreHistory }
    var lastFingerprintScore: FingerprintValidationService.FingerprintScore? { FingerprintValidationService.shared.lastScore }

    nonisolated enum AppearanceMode: String, CaseIterable, Sendable {
        case system = "System"
        case light = "Light"
        case dark = "Dark"

        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }

        var icon: String {
            switch self {
            case .system: "circle.lefthalf.filled"
            case .light: "sun.max.fill"
            case .dark: "moon.fill"
            }
        }
    }

    nonisolated enum ConnectionStatus: String, Sendable {
        case disconnected = "Disconnected"
        case connecting = "Connecting"
        case connected = "Connected"
        case error = "Error"
    }

    private let engine = PPSRAutomationEngine()
    private let persistence = PPSRPersistenceService.shared
    private let notifications = PPSRNotificationService.shared
    private let emailRotation = PPSREmailRotationService.shared
    private let diagnostics = PPSRConnectionDiagnosticService.shared
    private var batchTask: Task<Void, Never>?

    init() {
        engine.onScreenshot = { [weak self] screenshot in
            self?.debugScreenshots.insert(screenshot, at: 0)
        }
        engine.onConnectionFailure = { [weak self] detail in
            self?.notifications.sendConnectionFailure(detail: detail)
        }
        engine.onUnusualFailure = { [weak self] detail in
            guard let self else { return }
            self.consecutiveUnusualFailures += 1
            if self.consecutiveUnusualFailures >= 2 {
                self.unusualFailureMessage = detail
                self.showUnusualFailureAlert = true
            }
        }
        engine.onLog = { [weak self] message, level in
            self?.log(message, level: level)
        }
        notifications.requestPermission()
        loadPersistedData()
    }

    private func loadPersistedData() {
        cards = persistence.loadCards()
        if let settings = persistence.loadSettings() {
            testEmail = settings.email
            maxConcurrency = settings.maxConcurrency
            debugMode = settings.debugMode
            if let mode = AppearanceMode(rawValue: settings.appearanceMode) {
                appearanceMode = mode
            }
            useEmailRotation = settings.useEmailRotation
            stealthEnabled = settings.stealthEnabled
            retrySubmitOnFail = settings.retrySubmitOnFail
            if let rect = settings.screenshotCropRect {
                screenshotCropRect = rect
            }
        }
        if !cards.isEmpty {
            log("Restored \(cards.count) cards from storage")
        }
    }

    func persistCards() {
        persistence.saveCards(cards)
    }

    func persistSettings() {
        persistence.saveSettings(
            email: testEmail,
            maxConcurrency: maxConcurrency,
            debugMode: debugMode,
            appearanceMode: appearanceMode.rawValue,
            useEmailRotation: useEmailRotation,
            stealthEnabled: stealthEnabled,
            retrySubmitOnFail: retrySubmitOnFail,
            screenshotCropRect: screenshotCropRect
        )
    }

    func syncFromiCloud() {
        if let synced = persistence.syncFromiCloud() {
            let existingIds = Set(cards.map(\.number))
            var added = 0
            for card in synced where !existingIds.contains(card.number) {
                cards.append(card)
                added += 1
            }
            if added > 0 {
                log("iCloud sync: merged \(added) new cards", level: .success)
                persistCards()
            } else {
                log("iCloud sync: no new cards found", level: .info)
            }
        }
    }

    var workingCards: [PPSRCard] { cards.filter { $0.status == .working } }
    var deadCards: [PPSRCard] { cards.filter { $0.status == .dead } }
    var untestedCards: [PPSRCard] { cards.filter { $0.status == .untested } }
    var testingCards: [PPSRCard] { cards.filter { $0.status == .testing } }
    var activeChecks: [PPSRCheck] { checks.filter { !$0.status.isTerminal } }
    var completedChecks: [PPSRCheck] { checks.filter { $0.status == .completed } }
    var failedChecks: [PPSRCheck] { checks.filter { $0.status == .failed } }
    var totalSuccessfulCards: Int { cards.filter { $0.status == .working }.count }

    private func resolveEmail() -> String {
        if useEmailRotation, let rotated = emailRotation.nextEmail() {
            return rotated
        }
        return testEmail
    }

    func testConnection() async {
        connectionStatus = .connecting
        log("Testing connection to \(LoginWebSession.targetURL.absoluteString)...")

        let quickCheck = await diagnostics.quickHealthCheck()
        lastHealthCheck = quickCheck

        if !quickCheck.healthy {
            connectionStatus = .error
            log("Quick health check failed: \(quickCheck.detail)", level: .error)
            log("Running full diagnostics to identify the issue...", level: .warning)
            await runFullDiagnostic()

            if let report = diagnosticReport, !report.overallHealthy {
                if !autoHealAttempted {
                    autoHealAttempted = true
                    log("Attempting auto-heal...", level: .info)
                    await attemptAutoHeal(report: report)
                }
            }
            return
        }

        log("Quick health check passed: \(quickCheck.detail)", level: .success)

        let session = LoginWebSession()
        session.stealthEnabled = stealthEnabled
        session.setUp()
        defer { session.tearDown() }

        let loaded = await session.loadPage(timeout: 30)
        guard loaded else {
            connectionStatus = .error
            let errorDetail = session.lastNavigationError ?? "Unknown error"
            let httpCode = session.lastHTTPStatusCode.map { " (HTTP \($0))" } ?? ""
            log("WebView page load failed: \(errorDetail)\(httpCode)", level: .error)
            notifications.sendConnectionFailure(detail: "Page load failed: \(errorDetail)")

            log("Running full diagnostics...", level: .warning)
            await runFullDiagnostic()
            return
        }

        let pageTitle = await session.getPageTitle()
        log("Page loaded: \(pageTitle)")

        let structure = await session.dumpPageStructure()
        lastDiagnostics = structure
        log("DOM structure captured (\(structure.count) chars)")

        let verification = await session.verifyFieldsExist()
        if verification.found == 6 {
            connectionStatus = .connected
            consecutiveConnectionFailures = 0
            autoHealAttempted = false
            log("Connected — all 6 form fields verified on live PPSR page", level: .success)
        } else if verification.found > 0 {
            connectionStatus = .connected
            consecutiveConnectionFailures = 0
            log("Connected — found \(verification.found)/6 fields. Missing: \(verification.missing.joined(separator: ", "))", level: .warning)
        } else {
            connectionStatus = .connected
            log("Connected to page but 0/6 fields found — page may use dynamic rendering", level: .warning)

            let iframes = await session.checkForIframes()
            if iframes > 0 {
                log("Detected \(iframes) iframe(s) on page — fields may be inside iframe", level: .warning)
            }

            log("Waiting 3s for dynamic JS to render...")
            try? await Task.sleep(for: .seconds(3))
            let retryVerification = await session.verifyFieldsExist()
            if retryVerification.found > 0 {
                log("After wait: found \(retryVerification.found)/6 fields", level: .success)
            } else {
                log("Still 0 fields after wait — check page structure in diagnostics", level: .error)
            }
        }
    }

    func runFullDiagnostic() async {
        isDiagnosticRunning = true
        log("Starting full connection diagnostic...")
        let report = await diagnostics.runFullDiagnostic()
        diagnosticReport = report
        isDiagnosticRunning = false

        for step in report.steps {
            let level: PPSRLogEntry.Level
            switch step.status {
            case .passed: level = .success
            case .failed: level = .error
            case .warning: level = .warning
            default: level = .info
            }
            let latencyStr = step.latencyMs.map { " (\($0)ms)" } ?? ""
            log("[\(step.status.rawValue.uppercased())] \(step.name): \(step.detail)\(latencyStr)", level: level)
        }

        log("Recommendation: \(report.recommendation)", level: report.overallHealthy ? .info : .warning)
    }

    private func attemptAutoHeal(report: DiagnosticReport) async {
        let failedSteps = report.steps.filter { $0.status == .failed }

        for step in failedSteps {
            switch step.name {
            case "System DNS":
                log("Auto-heal: System DNS failed — enabling stealth mode for DoH resolution", level: .info)
                if !stealthEnabled {
                    stealthEnabled = true
                    persistSettings()
                    log("Auto-heal: Enabled Ultra Stealth Mode", level: .success)
                }

            case "HTTPS Reachability":
                if step.detail.contains("403") || step.detail.contains("blocked") {
                    log("Auto-heal: Server blocking detected — enabling stealth + reducing concurrency", level: .info)
                    if !stealthEnabled {
                        stealthEnabled = true
                    }
                    if maxConcurrency > 2 {
                        maxConcurrency = 2
                    }
                    persistSettings()
                    log("Auto-heal: Stealth ON, concurrency reduced to \(maxConcurrency)", level: .success)
                } else if step.detail.contains("timed out") {
                    log("Auto-heal: Connection timeout — increasing test timeout", level: .info)
                    if testTimeout < 45 {
                        testTimeout = 45
                        log("Auto-heal: Test timeout increased to 45s", level: .success)
                    }
                }

            case "Page Content":
                if step.detail.contains("CAPTCHA") || step.detail.contains("challenge") {
                    log("Auto-heal: CAPTCHA detected — enabling stealth + reducing concurrency to 1", level: .info)
                    stealthEnabled = true
                    maxConcurrency = 1
                    persistSettings()
                    log("Auto-heal: Stealth ON, concurrency set to 1", level: .success)
                }

            default:
                break
            }
        }

        log("Auto-heal complete — retesting connection...", level: .info)
        try? await Task.sleep(for: .seconds(2))
        await testConnection()
    }

    func addCardFromPipeFormat(_ input: String) {
        smartImportCards(input)
    }

    func smartImportCards(_ input: String) {
        let parsed = PPSRCard.smartParse(input)
        let lines = input.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if parsed.isEmpty && !lines.isEmpty {
            for line in lines {
                log("Could not parse: \(line)", level: .warning)
            }
            return
        }

        for card in parsed {
            let isDuplicate = cards.contains { $0.number == card.number }
            if isDuplicate {
                log("Skipped duplicate: \(card.brand.rawValue) \(card.number)", level: .warning)
            } else {
                cards.append(card)
                log("Added \(card.brand.rawValue) \(card.number) exp \(card.formattedExpiry)")
                Task { await card.loadBINData() }
            }
        }

        if parsed.count > 0 {
            log("Smart import: \(parsed.count) card(s) parsed from \(lines.count) line(s)", level: .success)
        }
        persistCards()
    }

    func deleteCard(_ card: PPSRCard) {
        cards.removeAll { $0.id == card.id }
        log("Removed \(card.brand.rawValue) card: \(card.number)")
        persistCards()
    }

    func restoreCard(_ card: PPSRCard) {
        card.status = .untested
        log("Restored \(card.brand.rawValue) \(card.number) to untested")
        persistCards()
    }

    func purgeDeadCards() {
        let count = deadCards.count
        cards.removeAll { $0.status == .dead }
        log("Purged \(count) dead card(s)")
        persistCards()
    }

    func clearDebugScreenshots() {
        let count = debugScreenshots.count
        debugScreenshots.removeAll()
        log("Cleared \(count) debug screenshots")
    }

    func correctResult(for screenshot: PPSRDebugScreenshot, override: UserResultOverride) {
        screenshot.userOverride = override

        guard let card = cards.first(where: { $0.id == screenshot.cardId }) else {
            log("Correction: could not find card \(screenshot.cardDisplayNumber)", level: .warning)
            return
        }

        let isPass = override == .markedPass
        card.applyCorrection(success: isPass)

        let label = isPass ? "PASS" : "FAIL"
        log("Debug correction: \(card.brand.rawValue) \(card.number) marked as \(label) by user", level: isPass ? .success : .error)
        persistCards()
    }

    func resetScreenshotOverride(_ screenshot: PPSRDebugScreenshot) {
        screenshot.userOverride = .none
        log("Reset override for screenshot at \(screenshot.formattedTime)")
    }

    func requeueCardFromScreenshot(_ screenshot: PPSRDebugScreenshot) {
        guard let card = cards.first(where: { $0.id == screenshot.cardId }) else {
            log("Requeue: could not find card \(screenshot.cardDisplayNumber)", level: .warning)
            return
        }
        card.status = .untested
        log("Requeued \(card.brand.rawValue) \(card.number) for retesting", level: .info)
        persistCards()
    }

    func stopAfterCurrent() {
        isStopping = true
        isPaused = false
        log("Stopping after current batch due to unusual failures...", level: .warning)
    }

    func testSingleCard(_ card: PPSRCard) {
        guard !isRunning || activeTestCount < maxConcurrency else {
            log("Max concurrency reached", level: .warning)
            return
        }

        let vin = PPSRVINGenerator.generate()
        let email = resolveEmail()
        card.status = .testing

        let check = PPSRCheck(vin: vin, email: email, card: card, sessionIndex: activeTestCount + 1)
        checks.insert(check, at: 0)

        Task {
            configureEngine()
            isRunning = true
            activeTestCount += 1
            let outcome = await engine.runCheck(check, timeout: testTimeout)
            activeTestCount -= 1
            handleOutcome(outcome, card: card, check: check, vin: vin)
            if activeTestCount == 0 { isRunning = false }
            persistCards()
        }
    }

    private func configureEngine() {
        engine.debugMode = debugMode
        engine.stealthEnabled = stealthEnabled
        engine.retrySubmitOnFail = retrySubmitOnFail
        engine.screenshotCropRect = screenshotCropRect
    }

    private func handleOutcome(_ outcome: CheckOutcome, card: PPSRCard, check: PPSRCheck, vin: String) {
        let duration = check.duration ?? 0

        switch outcome {
        case .pass:
            card.recordResult(success: true, vin: vin, duration: duration, error: nil)
            log("\(card.brand.rawValue) \(card.number) — PASSED (\(check.formattedDuration))", level: .success)
            consecutiveUnusualFailures = 0

        case .failInstitution:
            card.recordResult(success: false, vin: vin, duration: duration, error: check.errorMessage)
            log("\(card.brand.rawValue) \(card.number) — FAILED: institution detected", level: .error)
            consecutiveUnusualFailures = 0

        case .uncertain, .timeout, .connectionFailure:
            card.status = .untested
            let reason: String
            switch outcome {
            case .timeout: reason = "timeout"
            case .connectionFailure:
                reason = "connection failure"
                consecutiveConnectionFailures += 1
                if consecutiveConnectionFailures >= 3 {
                    log("3+ consecutive connection failures — auto-running diagnostics", level: .error)
                    Task { await runFullDiagnostic() }
                }
            default: reason = "uncertain result"
            }
            log("\(card.brand.rawValue) \(card.number) — requeued (\(reason))", level: .warning)
        }
    }

    func testAllUntested() {
        let cardsToTest = untestedCards
        guard !cardsToTest.isEmpty else {
            log("No untested cards in queue", level: .warning)
            return
        }

        isPaused = false
        isStopping = false
        log("Starting batch test: \(cardsToTest.count) cards, max \(maxConcurrency) concurrent, stealth: \(stealthEnabled ? "ON" : "OFF")")
        isRunning = true

        var batchWorking = 0
        var batchDead = 0
        var batchRequeued = 0

        batchTask = Task {
            configureEngine()
            await withTaskGroup(of: Void.self) { group in
                var running = 0

                for card in cardsToTest {
                    if isStopping { break }

                    while isPaused && !isStopping {
                        try? await Task.sleep(for: .milliseconds(500))
                    }

                    if isStopping { break }

                    if running >= maxConcurrency {
                        await group.next()
                        running -= 1
                    }

                    running += 1
                    let vin = PPSRVINGenerator.generate()
                    let email = resolveEmail()
                    card.status = .testing
                    let sessionIdx = running

                    let check = PPSRCheck(vin: vin, email: email, card: card, sessionIndex: sessionIdx)
                    checks.insert(check, at: 0)
                    activeTestCount += 1

                    group.addTask { [engine, testTimeout] in
                        let outcome = await engine.runCheck(check, timeout: testTimeout)
                        await MainActor.run {
                            self.activeTestCount -= 1
                            self.handleOutcome(outcome, card: card, check: check, vin: vin)

                            switch outcome {
                            case .pass: batchWorking += 1
                            case .failInstitution: batchDead += 1
                            case .uncertain, .timeout, .connectionFailure: batchRequeued += 1
                            }

                            self.persistCards()
                        }
                    }
                }

                await group.waitForAll()
            }

            let result = BatchResult(working: batchWorking, dead: batchDead, requeued: batchRequeued, total: batchWorking + batchDead + batchRequeued)
            lastBatchResult = result
            isRunning = false
            isPaused = false

            let stoppedEarly = isStopping
            isStopping = false

            if stoppedEarly {
                log("Batch stopped: \(batchWorking) working, \(batchDead) dead, \(batchRequeued) requeued", level: .warning)
            } else {
                log("Batch complete: \(batchWorking) working, \(batchDead) dead, \(batchRequeued) requeued", level: .success)
            }

            showBatchResultPopup = true
            notifications.sendBatchComplete(working: batchWorking, dead: batchDead, requeued: batchRequeued)
            persistCards()
        }
    }

    func pauseQueue() {
        isPaused = true
        log("Queue paused — completing current tests then holding", level: .warning)
    }

    func resumeQueue() {
        isPaused = false
        log("Queue resumed", level: .info)
    }

    func stopQueue() {
        isStopping = true
        isPaused = false
        log("Stopping queue — completing current tests then stopping...", level: .warning)
    }

    func retestCard(_ card: PPSRCard) {
        card.status = .untested
        testSingleCard(card)
    }

    func clearHistory() {
        checks.removeAll(where: { $0.status.isTerminal })
        log("Cleared completed checks")
    }

    func clearAll() {
        checks.removeAll()
        globalLogs.removeAll()
    }

    func exportWorkingCards() -> String {
        workingCards.map(\.pipeFormat).joined(separator: "\n")
    }

    func importEmails(_ text: String) -> Int {
        let count = emailRotation.importFromCSV(text)
        log("Imported \(count) emails for rotation", level: .success)
        return count
    }

    func clearRotationEmails() {
        emailRotation.clear()
        log("Cleared email rotation list")
    }

    func resetRotationEmailsToDefault() {
        emailRotation.resetToDefault()
        log("Reset email list to default (\(emailRotation.count) emails)", level: .success)
    }

    var rotationEmailCount: Int { emailRotation.count }
    var rotationEmails: [String] { emailRotation.emails }

    func screenshotsForCard(_ cardId: String) -> [PPSRDebugScreenshot] {
        debugScreenshots.filter { $0.cardId == cardId }
    }

    func screenshotsForCheck(_ check: PPSRCheck) -> [PPSRDebugScreenshot] {
        let ids = Set(check.screenshotIds)
        return debugScreenshots.filter { ids.contains($0.id) }
    }

    func log(_ message: String, level: PPSRLogEntry.Level = .info) {
        globalLogs.insert(PPSRLogEntry(message: message, level: level), at: 0)
    }
}
