import Foundation
import UIKit
import WebKit

nonisolated enum LoginOutcome: Sendable {
    case success
    case permDisabled
    case tempDisabled
    case noAcc
    case unsure
    case connectionFailure
    case timeout
    case redBannerError
}

@MainActor
class LoginAutomationEngine {
    private var activeSessions: Int = 0
    let maxConcurrency: Int = 8
    var debugMode: Bool = false
    var stealthEnabled: Bool = false
    var onScreenshot: ((PPSRDebugScreenshot) -> Void)?
    var onConnectionFailure: ((String) -> Void)?
    var onUnusualFailure: ((String) -> Void)?
    var onLog: ((String, PPSRLogEntry.Level) -> Void)?
    var onURLFailure: ((String) -> Void)?
    var onURLSuccess: ((String) -> Void)?
    var onResponseTime: ((String, TimeInterval) -> Void)?

    var canStartSession: Bool {
        activeSessions < maxConcurrency
    }

    func runLoginTest(_ attempt: LoginAttempt, targetURL: URL, timeout: TimeInterval = 45) async -> LoginOutcome {
        activeSessions += 1
        defer { activeSessions -= 1 }

        attempt.startedAt = Date()

        let session = LoginSiteWebSession(targetURL: targetURL)
        session.stealthEnabled = stealthEnabled
        session.onFingerprintLog = { [weak self] msg, level in
            attempt.logs.append(PPSRLogEntry(message: msg, level: level))
            self?.onLog?(msg, level)
        }
        session.setUp(wipeAll: true)
        defer { session.tearDown(wipeAll: true) }

        let outcome: LoginOutcome = await withTaskGroup(of: LoginOutcome.self) { group in
            group.addTask {
                return await self.performLoginTest(session: session, attempt: attempt)
            }

            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return .timeout
            }

            let first = await group.next() ?? .timeout
            group.cancelAll()
            return first
        }

        if outcome == .timeout {
            attempt.status = .failed
            attempt.errorMessage = "Test timed out after \(Int(timeout))s — auto-requeuing"
            attempt.completedAt = Date()
            attempt.logs.append(PPSRLogEntry(message: "TIMEOUT: Test exceeded \(Int(timeout))s limit", level: .warning))
            onUnusualFailure?("Timeout for \(attempt.credential.username) after \(Int(timeout))s")
        }

        if outcome == .connectionFailure {
            onURLFailure?(targetURL.absoluteString)
            onUnusualFailure?("Connection failure for \(attempt.credential.username)")
        }

        if outcome == .success || outcome == .noAcc || outcome == .permDisabled || outcome == .tempDisabled {
            onURLSuccess?(targetURL.absoluteString)
        }

        if let started = attempt.startedAt {
            let responseTime = Date().timeIntervalSince(started)
            onResponseTime?(targetURL.absoluteString, responseTime)
        }

        return outcome
    }

    private func performLoginTest(session: LoginSiteWebSession, attempt: LoginAttempt) async -> LoginOutcome {
        advanceTo(.loadingPage, attempt: attempt, message: "Loading login page: \(session.targetURL.absoluteString)")

        let preLoginURL = session.targetURL.absoluteString.lowercased()

        var loaded = false
        for attemptNum in 1...3 {
            loaded = await session.loadPage(timeout: 30)
            if loaded { break }
            let errorDetail = session.lastNavigationError ?? "unknown error"
            attempt.logs.append(PPSRLogEntry(message: "Page load attempt \(attemptNum)/3 failed — \(errorDetail)", level: .warning))
            if attemptNum < 3 {
                let waitTime = Double(attemptNum) * 2
                attempt.logs.append(PPSRLogEntry(message: "Retrying in \(Int(waitTime))s...", level: .info))
                try? await Task.sleep(for: .seconds(waitTime))
                if attemptNum == 2 {
                    session.tearDown(wipeAll: true)
                    session.stealthEnabled = stealthEnabled
                    session.setUp(wipeAll: true)
                }
            }
        }

        guard loaded else {
            let errorDetail = session.lastNavigationError ?? "Unknown error"
            failAttempt(attempt, message: "FATAL: Failed to load login page after 3 attempts — \(errorDetail)")
            onConnectionFailure?("Page load failed: \(errorDetail)")
            await captureDebugScreenshot(session: session, attempt: attempt, step: "page_load_failed", note: "Failed to load", autoResult: .unknown)
            return .connectionFailure
        }

        let pageTitle = await session.getPageTitle()
        attempt.logs.append(PPSRLogEntry(message: "Page loaded: \"\(pageTitle)\"", level: .info))

        let preLoginContent = await session.getPageContent()

        let verification = await session.verifyLoginFieldsExist()
        if verification.found < 2 {
            attempt.logs.append(PPSRLogEntry(message: "Field scan: \(verification.found)/2 found. Missing: [\(verification.missing.joined(separator: ", "))]", level: .warning))
            if verification.found == 0 {
                attempt.logs.append(PPSRLogEntry(message: "Waiting 4s for JavaScript-rendered content...", level: .info))
                try? await Task.sleep(for: .seconds(4))
                let retryVerification = await session.verifyLoginFieldsExist()
                if retryVerification.found == 0 {
                    failAttempt(attempt, message: "FATAL: No login fields found after extended wait")
                    await captureDebugScreenshot(session: session, attempt: attempt, step: "no_fields", note: "No login fields found", autoResult: .fail)
                    return .connectionFailure
                }
            }
        } else {
            attempt.logs.append(PPSRLogEntry(message: "Both login fields verified present and enabled", level: .success))
        }

        advanceTo(.fillingCredentials, attempt: attempt, message: "Filling username: \(attempt.credential.username)")
        let usernameResult = await retryFill(session: session, attempt: attempt, fieldName: "Username") {
            await session.fillUsername(attempt.credential.username)
        }
        guard usernameResult else { return .connectionFailure }
        try? await Task.sleep(for: .milliseconds(400))

        attempt.logs.append(PPSRLogEntry(message: "Filling password: \(String(repeating: "•", count: min(attempt.credential.password.count, 8)))", level: .info))
        let passwordResult = await retryFill(session: session, attempt: attempt, fieldName: "Password") {
            await session.fillPassword(attempt.credential.password)
        }
        guard passwordResult else { return .connectionFailure }
        try? await Task.sleep(for: .milliseconds(500))

        let maxSubmitCycles = 4
        var finalOutcome: LoginOutcome = .unsure
        var lastEvaluation: EvaluationResult?
        var successfulButtonPresses = 0

        for cycle in 1...maxSubmitCycles {
            advanceTo(.submitting, attempt: attempt, message: "Submit cycle \(cycle)/\(maxSubmitCycles) — clicking login button")

            if cycle > 1 {
                // Wait for the login button to return to its ready state before
                // re-filling and clicking again.  If it stays in the loading/
                // pressed appearance for longer than 8 seconds the server has
                // hung — requeue the credential to the bottom of the queue.
                attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle): waiting for login button to be ready...", level: .info))
                let buttonReady = await session.waitForLoginButtonReady(timeout: 8)
                if !buttonReady {
                    attempt.logs.append(PPSRLogEntry(message: "Login button hung in loading state for >8s — requeuing", level: .warning))
                    await captureDebugScreenshot(session: session, attempt: attempt, step: "button_hung_cycle_\(cycle)", note: "Login button stuck in loading state after previous press", autoResult: .unknown)
                    attempt.status = .failed
                    attempt.errorMessage = "Login button hung in loading state — requeuing to bottom"
                    attempt.completedAt = Date()
                    return .timeout
                }

                attempt.logs.append(PPSRLogEntry(message: "Re-filling credentials for cycle \(cycle)", level: .info))
                let _ = await session.fillUsername(attempt.credential.username)
                try? await Task.sleep(for: .milliseconds(300))
                let _ = await session.fillPassword(attempt.credential.password)
                try? await Task.sleep(for: .milliseconds(400))
            }

            var submitResult: (success: Bool, detail: String) = (false, "")
            for submitAttempt in 1...3 {
                submitResult = await session.clickLoginButton()
                if submitResult.success {
                    successfulButtonPresses += 1
                    attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle) submit: \(submitResult.detail)", level: .success))
                    break
                }
                attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle) submit attempt \(submitAttempt)/3 failed: \(submitResult.detail)", level: .warning))
                if submitAttempt < 3 {
                    try? await Task.sleep(for: .seconds(Double(submitAttempt)))
                }
            }
            guard submitResult.success else {
                if cycle == 1 {
                    failAttempt(attempt, message: "LOGIN SUBMIT FAILED after 3 attempts: \(submitResult.detail)")
                    await captureDebugScreenshot(session: session, attempt: attempt, step: "submit_failed", note: "Submit button not found", autoResult: .fail)
                    return .connectionFailure
                }
                attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle) submit failed — using last evaluation", level: .warning))
                break
            }

            let preSubmitURL = await session.getCurrentURL()
            attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle): waiting up to 5s for response...", level: .info))

            let pollResult = await session.rapidWelcomePoll(timeout: 5, originalURL: preSubmitURL)

            advanceTo(.evaluatingResult, attempt: attempt, message: "Cycle \(cycle)/\(maxSubmitCycles) — evaluating response...")

            var pageContent = pollResult.finalPageContent
            if pageContent.isEmpty {
                pageContent = await session.getPageContent()
            }
            var currentURL = pollResult.finalURL
            if currentURL.isEmpty {
                currentURL = await session.getCurrentURL()
            }
            attempt.detectedURL = currentURL
            attempt.responseSnippet = String(pageContent.prefix(500))

            let screenshotImage: UIImage?
            if let ws = pollResult.welcomeScreenshot {
                screenshotImage = ws
            } else {
                screenshotImage = await session.captureScreenshot()
            }
            attempt.responseSnapshot = screenshotImage

            let welcomeTextFound = pollResult.welcomeTextFound
            let welcomeContext = pollResult.welcomeContext

            attempt.logs.append(PPSRLogEntry(
                message: "Welcome! rapid poll: \(welcomeTextFound ? "FOUND — \(welcomeContext ?? "")" : "NOT FOUND")",
                level: welcomeTextFound ? .success : .info
            ))
            attempt.logs.append(PPSRLogEntry(
                message: "Redirect check: \(pollResult.redirectedToHomepage ? "REDIRECTED to homepage" : "still on login page") | URL: \(currentURL)",
                level: pollResult.redirectedToHomepage ? .success : .info
            ))

            if pollResult.errorBannerDetected {
                attempt.logs.append(PPSRLogEntry(
                    message: "RED BANNER ERROR detected: \(pollResult.errorBannerText ?? "error")",
                    level: .warning
                ))
                await captureAlwaysScreenshot(session: session, attempt: attempt, cycle: cycle, maxCycles: maxSubmitCycles, welcomeTextFound: false, redirected: false, evaluationReason: "Red banner error", currentURL: currentURL, autoResult: .unknown)
                attempt.status = .failed
                attempt.errorMessage = "Red banner error detected — requeuing to bottom"
                attempt.completedAt = Date()
                return .redBannerError
            }

            let evaluation = evaluateLoginResponse(
                pageContent: pageContent,
                currentURL: currentURL,
                preLoginURL: preLoginURL,
                pageTitle: await session.getPageTitle(),
                welcomeTextFound: welcomeTextFound,
                redirectedToHomepage: pollResult.redirectedToHomepage,
                navigationDetected: pollResult.navigationDetected,
                contentChanged: pollResult.anyContentChange
            )
            lastEvaluation = evaluation

            let autoResult: PPSRDebugScreenshot.AutoDetectedResult
            switch evaluation.outcome {
            case .success: autoResult = .pass
            case .noAcc, .permDisabled, .tempDisabled: autoResult = .fail
            default: autoResult = .unknown
            }

            await captureAlwaysScreenshot(session: session, attempt: attempt, cycle: cycle, maxCycles: maxSubmitCycles, welcomeTextFound: welcomeTextFound, redirected: pollResult.redirectedToHomepage, evaluationReason: evaluation.reason, currentURL: currentURL, autoResult: autoResult)

            attempt.logs.append(PPSRLogEntry(
                message: "Cycle \(cycle) evaluation: \(evaluation.outcome) (score: \(evaluation.score), signals: \(evaluation.signals.count)) — \(evaluation.reason)",
                level: evaluation.outcome == .success ? .success : evaluation.outcome == .unsure ? .warning : .error
            ))

            switch evaluation.outcome {
            case .success:
                advanceTo(.completed, attempt: attempt, message: "LOGIN SUCCESS on cycle \(cycle) — \(evaluation.reason)")
                attempt.completedAt = Date()
                return .success

            case .tempDisabled:
                attempt.logs.append(PPSRLogEntry(message: "TEMP DISABLED after \(cycle) cycles: \(evaluation.reason)", level: .warning))
                failAttempt(attempt, message: "Account temporarily disabled: \(evaluation.reason)")
                return .tempDisabled

            case .permDisabled:
                if cycle >= maxSubmitCycles {
                    attempt.logs.append(PPSRLogEntry(message: "PERM DISABLED after \(cycle) cycles: \(evaluation.reason)", level: .error))
                    failAttempt(attempt, message: "Account permanently disabled/blacklisted: \(evaluation.reason)")
                    return .permDisabled
                }
                finalOutcome = .permDisabled

            case .noAcc:
                if cycle < maxSubmitCycles {
                    attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle): no account — retrying (\(maxSubmitCycles - cycle) cycles left)", level: .warning))
                    finalOutcome = .noAcc
                    try? await Task.sleep(for: .seconds(Double(cycle) * 3.0))
                } else {
                    finalOutcome = .noAcc
                }

            default:
                if cycle < maxSubmitCycles {
                    attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle): uncertain — retrying (\(maxSubmitCycles - cycle) cycles left)", level: .warning))
                    try? await Task.sleep(for: .seconds(Double(cycle) * 3.0))
                }
                finalOutcome = .unsure
            }
        }

        let eval = lastEvaluation
        switch finalOutcome {
        case .success:
            advanceTo(.completed, attempt: attempt, message: "LOGIN SUCCESS — \(eval?.reason ?? "confirmed")")
            attempt.completedAt = Date()
            return .success

        case .permDisabled:
            attempt.logs.append(PPSRLogEntry(message: "PERM DISABLED after \(maxSubmitCycles) cycles: \(eval?.reason ?? "unknown")", level: .error))
            failAttempt(attempt, message: "Account permanently disabled/blacklisted: \(eval?.reason ?? "unknown")")
            return .permDisabled

        case .tempDisabled:
            attempt.logs.append(PPSRLogEntry(message: "TEMP DISABLED after \(maxSubmitCycles) cycles: \(eval?.reason ?? "unknown")", level: .warning))
            failAttempt(attempt, message: "Account temporarily disabled: \(eval?.reason ?? "unknown")")
            return .tempDisabled

        case .noAcc:
            attempt.logs.append(PPSRLogEntry(message: "NO ACC after \(maxSubmitCycles) cycles: \(eval?.reason ?? "unknown")", level: .error))
            failAttempt(attempt, message: "No account found after \(maxSubmitCycles) attempts: \(eval?.reason ?? "unknown")")
            return .noAcc

        default:
            // If the login button was successfully pressed at least 3 times with
            // no temp-disabled or other clear indication, treat as no account.
            if successfulButtonPresses >= 3 {
                attempt.logs.append(PPSRLogEntry(
                    message: "Treating as NO ACC — button pressed \(successfulButtonPresses)x with no temp-disabled or other indication",
                    level: .error
                ))
                failAttempt(attempt, message: "No account after \(successfulButtonPresses) login attempts — unsure result treated as noAcc")
                return .noAcc
            }
            attempt.status = .failed
            attempt.errorMessage = "Unsure after \(maxSubmitCycles) submit cycles — \(eval?.reason ?? "no clear signals"). Auto-requeuing."
            attempt.completedAt = Date()
            let pageContent = await session.getPageContent()
            let snippet = String(pageContent.prefix(200))
            onUnusualFailure?("Unsure login result for \(attempt.credential.username) after \(maxSubmitCycles) cycles: \(snippet)")
            return .unsure
        }
    }

    // MARK: - Weighted Multi-Signal Evaluation

    private struct EvaluationResult {
        let outcome: LoginOutcome
        let score: Int
        let reason: String
        let signals: [String]
    }

    private func evaluateLoginResponse(
        pageContent: String,
        currentURL: String,
        preLoginURL: String,
        pageTitle: String,
        welcomeTextFound: Bool,
        redirectedToHomepage: Bool,
        navigationDetected: Bool,
        contentChanged: Bool
    ) -> EvaluationResult {
        let contentLower = pageContent.lowercased()
        let urlLower = currentURL.lowercased()

        var successScore: Int = 0
        var incorrectScore: Int = 0
        var disabledScore: Int = 0
        var successSignals: [String] = []
        var incorrectSignals: [String] = []
        var disabledSignals: [String] = []

        // --- SUCCESS: ONLY "Welcome!" text (case sensitive) OR homepage redirect ---

        if welcomeTextFound {
            successScore += 100
            successSignals.append("+100 'Welcome!' text captured via rapid poll")
        }

        if redirectedToHomepage && !urlLower.contains("/login") && !urlLower.contains("/signin") {
            successScore += 80
            successSignals.append("+80 redirected away from login to homepage")
        }

        // --- INCORRECT signals (wrong credentials) ---

        let strongIncorrectTerms: [(String, Int)] = [
            ("incorrect password", 50), ("incorrect email", 50),
            ("invalid credentials", 50), ("wrong password", 50),
            ("invalid email or password", 55), ("incorrect username or password", 55),
            ("authentication failed", 45), ("login failed", 40),
            ("invalid login", 45), ("credentials are incorrect", 50),
            ("does not match", 40), ("not recognized", 40),
            ("no account found", 45), ("account not found", 45),
            ("email not found", 45), ("user not found", 45),
            ("please check your", 35), ("not valid", 30),
        ]
        for (term, weight) in strongIncorrectTerms {
            if contentLower.contains(term) {
                incorrectScore += weight
                incorrectSignals.append("+\(weight) '\(term)'")
            }
        }

        let weakIncorrectTerms: [(String, Int)] = [
            ("try again", 15), ("please try again", 20),
            ("invalid email", 20), ("invalid password", 20),
            ("check your credentials", 25), ("unable to log in", 25),
            ("login error", 20), ("sign in error", 20),
            ("incorrect", 25),
            ("error", 5),
        ]
        for (term, weight) in weakIncorrectTerms {
            if contentLower.contains(term) {
                incorrectScore += weight
                incorrectSignals.append("+\(weight) '\(term)'")
            }
        }

        if urlLower.contains("/login") || urlLower.contains("/signin") {
            if contentChanged && incorrectScore > 0 {
                incorrectScore += 10
                incorrectSignals.append("+10 still on login page with error content")
            }
            if !welcomeTextFound && !redirectedToHomepage {
                incorrectScore += 5
                incorrectSignals.append("+5 still on login URL without Welcome! or redirect")
            }
        }

        // --- DISABLED signals (blocked/banned) ---

        var temporarilyLocked = false
        let tempLockTerms = [
            "temporarily", "temporary lock", "temporarily locked",
            "temporarily disabled", "temporarily suspended",
            "temporarily blocked", "too many attempts",
            "too many login attempts", "too many failed",
            "try again later", "try again in", "account temporarily",
            "locked for", "wait before", "exceeded login attempts",
            "multiple failed attempts", "login attempts exceeded",
        ]
        for term in tempLockTerms {
            if contentLower.contains(term) {
                temporarilyLocked = true
                disabledScore += 40
                disabledSignals.append("+40 TEMP_LOCK '\(term)'")
                break
            }
        }

        let strongDisabledTerms: [(String, Int)] = [
            ("account has been disabled", 60), ("account has been suspended", 60),
            ("account has been blocked", 60), ("account has been deactivated", 60),
            ("your account is locked", 55), ("account is restricted", 50),
            ("permanently banned", 60),
            ("blacklisted", 50), ("contact support", 15),
            ("account is closed", 55), ("self-excluded", 40),
        ]
        for (term, weight) in strongDisabledTerms {
            if contentLower.contains(term) {
                disabledScore += weight
                disabledSignals.append("+\(weight) '\(term)'")
            }
        }

        let weakDisabledTerms: [(String, Int)] = [
            ("disabled", 12), ("suspended", 15), ("blocked", 12),
            ("banned", 15), ("locked", 12), ("restricted", 10),
            ("deactivated", 15),
        ]
        for (term, weight) in weakDisabledTerms {
            if contentLower.contains(term) {
                disabledScore += weight
                disabledSignals.append("+\(weight) '\(term)'")
            }
        }

        // --- FALSE POSITIVE guards ---

        if contentLower.contains("captcha") || contentLower.contains("verify you are human") ||
           contentLower.contains("cloudflare") || contentLower.contains("challenge-platform") {
            successScore = 0
            successSignals.append("-ALL CAPTCHA/challenge detected, zeroed success")
        }

        // --- DECISION: STRICT FAIL-BY-DEFAULT ---
        // Success ONLY if Welcome! text was captured OR page redirected to homepage
        // Everything else is a fail unless explicitly matching incorrect/disabled patterns

        let successThreshold = 60
        let incorrectThreshold = 20
        let disabledThreshold = 30

        if disabledScore >= disabledThreshold && disabledScore > incorrectScore {
            let topSignals = disabledSignals.prefix(3).joined(separator: ", ")
            if temporarilyLocked {
                return EvaluationResult(
                    outcome: .tempDisabled,
                    score: disabledScore,
                    reason: "Temporarily disabled [\(topSignals)]",
                    signals: disabledSignals
                )
            } else {
                return EvaluationResult(
                    outcome: .permDisabled,
                    score: disabledScore,
                    reason: "Permanently disabled [\(topSignals)]",
                    signals: disabledSignals
                )
            }
        }

        if successScore >= successThreshold && successScore > incorrectScore && successScore > disabledScore {
            let topSignals = successSignals.prefix(3).joined(separator: ", ")
            let reason = welcomeTextFound ? "WELCOME! TEXT CAPTURED" : "HOMEPAGE REDIRECT CONFIRMED"
            return EvaluationResult(
                outcome: .success,
                score: successScore,
                reason: "\(reason) [\(topSignals)]",
                signals: successSignals
            )
        }

        if incorrectScore >= incorrectThreshold && incorrectScore > successScore {
            let topSignals = incorrectSignals.prefix(3).joined(separator: ", ")
            return EvaluationResult(
                outcome: .noAcc,
                score: incorrectScore,
                reason: "No account / invalid credentials [\(topSignals)]",
                signals: incorrectSignals
            )
        }

        // DEFAULT: No Welcome! text, no redirect, no clear error = FAIL (uncertain)
        // This prevents false positives — the temporary banner was NOT observed
        let maxScore = max(successScore, max(incorrectScore, disabledScore))
        let allSignals = successSignals + incorrectSignals + disabledSignals
        let snippet = String(pageContent.prefix(150)).replacingOccurrences(of: "\n", with: " ")
        return EvaluationResult(
            outcome: .unsure,
            score: maxScore,
            reason: "NO Welcome! text captured, NO homepage redirect (success:\(successScore) incorrect:\(incorrectScore) disabled:\(disabledScore)) content: \"\(snippet)\"",
            signals: allSignals
        )
    }

    // MARK: - Helpers

    private func retryFill(
        session: LoginSiteWebSession,
        attempt: LoginAttempt,
        fieldName: String,
        fill: () async -> (success: Bool, detail: String)
    ) async -> Bool {
        for attemptNum in 1...3 {
            let result = await fill()
            if result.success {
                attempt.logs.append(PPSRLogEntry(message: "\(fieldName): \(result.detail)", level: .success))
                return true
            }
            attempt.logs.append(PPSRLogEntry(message: "\(fieldName) attempt \(attemptNum)/3 FAILED: \(result.detail)", level: .warning))
            if attemptNum < 3 {
                try? await Task.sleep(for: .milliseconds(Double(attemptNum) * 500))
            }
        }
        failAttempt(attempt, message: "\(fieldName) FILL FAILED after 3 attempts")
        return false
    }

    private func advanceTo(_ status: LoginAttemptStatus, attempt: LoginAttempt, message: String) {
        attempt.status = status
        attempt.logs.append(PPSRLogEntry(message: message, level: status == .completed ? .success : .info))
    }

    private func failAttempt(_ attempt: LoginAttempt, message: String) {
        attempt.status = .failed
        attempt.errorMessage = message
        attempt.completedAt = Date()
        attempt.logs.append(PPSRLogEntry(message: "ERROR: \(message)", level: .error))
    }

    private func captureAlwaysScreenshot(session: LoginSiteWebSession, attempt: LoginAttempt, cycle: Int, maxCycles: Int, welcomeTextFound: Bool, redirected: Bool, evaluationReason: String, currentURL: String, autoResult: PPSRDebugScreenshot.AutoDetectedResult) async {
        guard let img = await session.captureScreenshot() else { return }
        attempt.responseSnapshot = img

        let compressed: UIImage
        if let jpegData = img.jpegData(compressionQuality: 0.4), let ci = UIImage(data: jpegData) {
            compressed = ci
        } else {
            compressed = img
        }

        let screenshot = PPSRDebugScreenshot(
            stepName: "post_login_cycle_\(cycle)",
            cardDisplayNumber: attempt.credential.username,
            cardId: attempt.credential.id,
            vin: "",
            email: attempt.credential.username,
            image: compressed,
            note: "Cycle \(cycle)/\(maxCycles) | Welcome!: \(welcomeTextFound ? "YES" : "NO") | Redirect: \(redirected ? "YES" : "NO") | \(evaluationReason) | URL: \(currentURL)",
            autoDetectedResult: autoResult
        )
        attempt.screenshotIds.append(screenshot.id)
        onScreenshot?(screenshot)
    }

    private func captureDebugScreenshot(session: LoginSiteWebSession, attempt: LoginAttempt, step: String, note: String, autoResult: PPSRDebugScreenshot.AutoDetectedResult = .unknown) async {
        guard let fullImage = await session.captureScreenshot() else { return }

        attempt.responseSnapshot = fullImage

        let compressed: UIImage
        if let jpegData = fullImage.jpegData(compressionQuality: 0.4), let ci = UIImage(data: jpegData) {
            compressed = ci
        } else {
            compressed = fullImage
        }

        let screenshot = PPSRDebugScreenshot(
            stepName: step,
            cardDisplayNumber: attempt.credential.username,
            cardId: attempt.credential.id,
            vin: "",
            email: attempt.credential.username,
            image: compressed,
            note: note,
            autoDetectedResult: autoResult
        )
        attempt.screenshotIds.append(screenshot.id)
        onScreenshot?(screenshot)
    }
}
