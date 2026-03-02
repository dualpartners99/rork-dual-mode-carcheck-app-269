import Foundation
import WebKit
import UIKit

nonisolated enum LoginTargetSite: String, CaseIterable, Sendable {
    case joefortune = "Joe Fortune"
    case ignition = "Ignition Casino"

    var url: URL {
        switch self {
        case .joefortune: URL(string: "https://joefortune24.com/login")!
        case .ignition: URL(string: "https://www.ignitioncasino.eu/login")!
        }
    }

    var host: String {
        switch self {
        case .joefortune: "joefortune24.com"
        case .ignition: "ignitioncasino.eu"
        }
    }

    var icon: String {
        switch self {
        case .joefortune: "suit.spade.fill"
        case .ignition: "flame.fill"
        }
    }

    var accentColorName: String {
        switch self {
        case .joefortune: "green"
        case .ignition: "orange"
        }
    }
}

@MainActor
class LoginSiteWebSession: NSObject {
    private var webView: WKWebView?
    private let sessionId: UUID = UUID()
    private var pageLoadContinuation: CheckedContinuation<Bool, Never>?
    private var isPageLoaded: Bool = false
    private var loadTimeoutTask: Task<Void, Never>?
    var stealthEnabled: Bool = false
    var lastNavigationError: String?
    var lastHTTPStatusCode: Int?
    var targetURL: URL
    private var stealthProfile: PPSRStealthService.SessionProfile?
    private(set) var lastFingerprintScore: FingerprintValidationService.FingerprintScore?
    var onFingerprintLog: ((String, PPSRLogEntry.Level) -> Void)?

    init(targetURL: URL) {
        self.targetURL = targetURL
        super.init()
    }

    func setUp(wipeAll: Bool = true) {
        if wipeAll {
            let dataStore = WKWebsiteDataStore.default()
            let allTypes = WKWebsiteDataStore.allWebsiteDataTypes()
            dataStore.removeData(ofTypes: allTypes, modifiedSince: .distantPast) { }
            HTTPCookieStorage.shared.removeCookies(since: .distantPast)
            URLCache.shared.removeAllCachedResponses()
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        if stealthEnabled {
            let stealth = PPSRStealthService.shared
            let profile = stealth.nextProfile()
            self.stealthProfile = profile

            let userScript = stealth.createStealthUserScript(profile: profile)
            config.userContentController.addUserScript(userScript)

            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: profile.viewport.width, height: profile.viewport.height), configuration: config)
            webView.navigationDelegate = self
            webView.customUserAgent = profile.userAgent
            self.webView = webView
        } else {
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
            webView.navigationDelegate = self
            webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
            self.webView = webView
        }
    }

    func tearDown(wipeAll: Bool = true) {
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        webView?.stopLoading()

        if wipeAll, let webView {
            webView.configuration.websiteDataStore.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast
            ) { }
            webView.configuration.userContentController.removeAllUserScripts()
        }

        webView?.navigationDelegate = nil
        webView = nil
        isPageLoaded = false
        if let cont = pageLoadContinuation {
            pageLoadContinuation = nil
            cont.resume(returning: false)
        }
    }

    func injectFingerprint() async {
        guard stealthEnabled, let profile = stealthProfile else { return }
        let js = PPSRStealthService.shared.fingerprintJS()
        _ = await executeJS(js)
    }

    func validateFingerprint(maxRetries: Int = 2) async -> Bool {
        guard stealthEnabled, let wv = webView, let profile = stealthProfile else { return true }

        for attempt in 0..<maxRetries {
            let score = await FingerprintValidationService.shared.validate(in: wv, profileSeed: profile.seed)
            lastFingerprintScore = score

            if score.passed {
                onFingerprintLog?("FP score PASS: \(score.totalScore)/\(score.maxSafeScore) (seed: \(profile.seed))", .success)
                return true
            }

            let signalSummary = score.signals.prefix(3).joined(separator: ", ")
            onFingerprintLog?("FP score FAIL attempt \(attempt + 1): \(score.totalScore)/\(score.maxSafeScore) [\(signalSummary)]", .warning)

            if attempt < maxRetries - 1 {
                onFingerprintLog?("Rotating stealth profile to reduce FP score...", .info)
                let stealth = PPSRStealthService.shared
                let newProfile = stealth.nextProfile()
                self.stealthProfile = newProfile
                webView?.customUserAgent = newProfile.userAgent
                let newJS = stealth.createStealthUserScript(profile: newProfile)
                webView?.configuration.userContentController.removeAllUserScripts()
                webView?.configuration.userContentController.addUserScript(newJS)
                _ = await executeJS(PPSRStealthService.shared.buildComprehensiveStealthJSPublic(profile: newProfile))
                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        onFingerprintLog?("FP validation failed after \(maxRetries) profile rotations — proceeding with caution", .error)
        return false
    }

    func loadPage(timeout: TimeInterval = 30) async -> Bool {
        guard let webView else {
            lastNavigationError = "WebView not initialized"
            return false
        }
        isPageLoaded = false
        lastNavigationError = nil
        lastHTTPStatusCode = nil

        let request = URLRequest(url: targetURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        webView.load(request)

        let loaded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            self.pageLoadContinuation = continuation
            self.loadTimeoutTask = Task {
                try? await Task.sleep(for: .seconds(timeout))
                if self.pageLoadContinuation != nil {
                    self.pageLoadContinuation = nil
                    self.lastNavigationError = self.lastNavigationError ?? "Page load timed out after \(Int(timeout))s"
                    continuation.resume(returning: false)
                }
            }
        }

        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil

        if loaded {
            await injectFingerprint()
            try? await Task.sleep(for: .milliseconds(2000))
            await waitForDOMReady(timeout: 10)
            let _ = await validateFingerprint()
        }

        return loaded
    }

    private func waitForDOMReady(timeout: TimeInterval) async {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            let ready = await executeJS("document.readyState") ?? ""
            if ready == "complete" || ready == "interactive" {
                try? await Task.sleep(for: .milliseconds(500))
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    private let findFieldJS = """
    function findField(strategies) {
        for (var i = 0; i < strategies.length; i++) {
            var s = strategies[i];
            var el = null;
            try {
                if (s.type === 'id') {
                    el = document.getElementById(s.value);
                } else if (s.type === 'name') {
                    var els = document.getElementsByName(s.value);
                    if (els.length > 0) el = els[0];
                } else if (s.type === 'placeholder') {
                    el = document.querySelector('input[placeholder*="' + s.value + '"]');
                } else if (s.type === 'label') {
                    var labels = document.querySelectorAll('label');
                    for (var j = 0; j < labels.length; j++) {
                        var txt = (labels[j].textContent || '').trim().toLowerCase();
                        if (txt.indexOf(s.value.toLowerCase()) !== -1) {
                            var forId = labels[j].getAttribute('for');
                            if (forId) { el = document.getElementById(forId); }
                            else { el = labels[j].querySelector('input'); }
                            if (el) break;
                        }
                    }
                } else if (s.type === 'css') {
                    el = document.querySelector(s.value);
                } else if (s.type === 'ariaLabel') {
                    el = document.querySelector('[aria-label*="' + s.value + '"]');
                }
            } catch(e) {}
            if (el && !el.disabled && el.offsetParent !== null) return el;
            if (el && !el.disabled) return el;
        }
        return null;
    }
    """

    private func fillFieldJS(strategies: String, value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        return """
        (function() {
            \(findFieldJS)
            var el = findField(\(strategies));
            if (!el) return 'NOT_FOUND';
            el.focus();
            el.value = '';
            var nativeInputValueSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
            if (nativeInputValueSetter && nativeInputValueSetter.set) {
                nativeInputValueSetter.set.call(el, '\(escaped)');
            } else {
                el.value = '\(escaped)';
            }
            el.dispatchEvent(new Event('focus', {bubbles: true}));
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
            el.dispatchEvent(new Event('blur', {bubbles: true}));
            if (el.value === '\(escaped)') return 'OK';
            el.value = '\(escaped)';
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
            return el.value === '\(escaped)' ? 'OK' : 'VALUE_MISMATCH';
        })();
        """
    }

    func fillUsername(_ username: String) async -> (success: Bool, detail: String) {
        let strategies = """
        [
            {"type":"id","value":"email"},{"type":"id","value":"username"},{"type":"id","value":"login-email"},
            {"type":"id","value":"login_email"},{"type":"id","value":"user_login"},{"type":"id","value":"loginEmail"},
            {"type":"name","value":"email"},{"type":"name","value":"username"},{"type":"name","value":"login"},
            {"type":"name","value":"user_login"},{"type":"name","value":"loginEmail"},
            {"type":"placeholder","value":"Email"},{"type":"placeholder","value":"email"},
            {"type":"placeholder","value":"Username"},{"type":"placeholder","value":"username"},
            {"type":"placeholder","value":"Enter your email"},{"type":"placeholder","value":"Login"},
            {"type":"label","value":"email"},{"type":"label","value":"username"},{"type":"label","value":"login"},
            {"type":"ariaLabel","value":"email"},{"type":"ariaLabel","value":"username"},
            {"type":"css","value":"input[type='email']"},{"type":"css","value":"input[autocomplete='email']"},
            {"type":"css","value":"input[autocomplete='username']"},
            {"type":"css","value":"form input[type='text']:first-of-type"},
            {"type":"css","value":"input[type='text']"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: username))
        return classifyFillResult(result, fieldName: "Username/Email")
    }

    func fillPassword(_ password: String) async -> (success: Bool, detail: String) {
        let strategies = """
        [
            {"type":"id","value":"password"},{"type":"id","value":"login-password"},
            {"type":"id","value":"login_password"},{"type":"id","value":"user_password"},
            {"type":"id","value":"loginPassword"},{"type":"id","value":"pass"},
            {"type":"name","value":"password"},{"type":"name","value":"user_password"},
            {"type":"name","value":"loginPassword"},{"type":"name","value":"pass"},
            {"type":"placeholder","value":"Password"},{"type":"placeholder","value":"password"},
            {"type":"placeholder","value":"Enter your password"},{"type":"placeholder","value":"Enter password"},
            {"type":"label","value":"password"},{"type":"ariaLabel","value":"password"},
            {"type":"css","value":"input[type='password']"},{"type":"css","value":"input[autocomplete='current-password']"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: password))
        return classifyFillResult(result, fieldName: "Password")
    }

    func clickLoginButton() async -> (success: Bool, detail: String) {
        let js = """
        (function() {
            var strategies = [
                function() {
                    var btns = document.querySelectorAll('button, input[type="submit"], a.btn, [role="button"]');
                    for (var i = 0; i < btns.length; i++) {
                        var text = (btns[i].textContent || btns[i].value || '').toLowerCase().trim();
                        if (text === 'log in' || text === 'login' || text === 'sign in' || text === 'signin') {
                            btns[i].click(); return 'CLICKED_EXACT';
                        }
                    }
                    return null;
                },
                function() {
                    var btns = document.querySelectorAll('button, input[type="submit"], a.btn, [role="button"]');
                    for (var i = 0; i < btns.length; i++) {
                        var text = (btns[i].textContent || btns[i].value || '').toLowerCase().trim();
                        if (text.indexOf('log in') !== -1 || text.indexOf('login') !== -1 || text.indexOf('sign in') !== -1) {
                            btns[i].click(); return 'CLICKED_PARTIAL';
                        }
                    }
                    return null;
                },
                function() {
                    var btn = document.querySelector('button[type="submit"]');
                    if (btn) { btn.click(); return 'CLICKED_SUBMIT_BTN'; }
                    return null;
                },
                function() {
                    var btn = document.querySelector('input[type="submit"]');
                    if (btn) { btn.click(); return 'CLICKED_SUBMIT_INPUT'; }
                    return null;
                },
                function() {
                    var forms = document.querySelectorAll('form');
                    if (forms.length > 0) { forms[0].submit(); return 'FORM_SUBMITTED'; }
                    return null;
                }
            ];
            for (var i = 0; i < strategies.length; i++) {
                var result = strategies[i]();
                if (result) return result;
            }
            return 'NOT_FOUND';
        })();
        """
        let result = await executeJS(js)
        if let result, result != "NOT_FOUND" {
            return (true, "Login clicked via strategy: \(result)")
        }
        return (false, "Login button not found")
    }

    func verifyLoginFieldsExist() async -> (found: Int, missing: [String]) {
        let js = """
        (function() {
            \(findFieldJS)
            var fieldDefs = {
                'username': [{"type":"id","value":"email"},{"type":"id","value":"username"},{"type":"name","value":"email"},{"type":"name","value":"username"},{"type":"css","value":"input[type='email']"},{"type":"css","value":"input[type='text']"},{"type":"placeholder","value":"Email"},{"type":"placeholder","value":"Username"}],
                'password': [{"type":"id","value":"password"},{"type":"name","value":"password"},{"type":"css","value":"input[type='password']"},{"type":"placeholder","value":"Password"}]
            };
            var found = 0; var missing = [];
            for (var name in fieldDefs) {
                var el = findField(fieldDefs[name]);
                if (el) { found++; }
                else { missing.push(name); }
            }
            return JSON.stringify({found: found, missing: missing});
        })();
        """
        guard let result = await executeJS(js),
              let data = result.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let found = json["found"] as? Int,
              let missing = json["missing"] as? [String] else {
            return (0, ["username", "password"])
        }
        return (found, missing)
    }

    struct RapidPollResult {
        let welcomeTextFound: Bool
        let welcomeContext: String?
        let welcomeScreenshot: UIImage?
        let redirectedToHomepage: Bool
        let finalURL: String
        let finalPageContent: String
        let navigationDetected: Bool
        let anyContentChange: Bool
        let errorBannerDetected: Bool
        let errorBannerText: String?
    }

    func rapidWelcomePoll(timeout: TimeInterval = 20, originalURL: String) async -> RapidPollResult {
        let start = Date()
        let originalHost = URL(string: originalURL)?.host ?? ""
        var welcomeScreenshot: UIImage? = nil
        var welcomeContext: String? = nil
        var welcomeFound = false
        var redirectedHome = false
        var navDetected = false
        var contentChanged = false
        var lastContent = ""
        var lastURL = originalURL

        let originalBody = await executeJS("document.body ? document.body.innerText.substring(0, 300) : ''") ?? ""

        while Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(for: .milliseconds(200))

            let currentURL = webView?.url?.absoluteString ?? ""
            lastURL = currentURL

            let currentURLLower = currentURL.lowercased()
            let currentHost = URL(string: currentURL)?.host ?? ""
            let sameHost = currentHost == originalHost || currentHost.contains(originalHost.replacingOccurrences(of: "www.", with: "")) || originalHost.contains(currentHost.replacingOccurrences(of: "www.", with: ""))

            if currentURL != originalURL && !currentURL.isEmpty {
                navDetected = true
                if sameHost && !currentURLLower.contains("/login") && !currentURLLower.contains("/signin") {
                    redirectedHome = true
                }
            }

            let pageText = await executeJS("document.body ? document.body.innerText.substring(0, 2000) : ''") ?? ""
            lastContent = pageText
            if pageText != originalBody && pageText.count > 20 {
                contentChanged = true
            }

            if pageText.contains("Welcome!") {
                welcomeFound = true
                let result = GreenBannerDetector.detectWelcomeText(in: pageText)
                welcomeContext = result.exact
                welcomeScreenshot = await captureScreenshot()
                break
            }

            if redirectedHome {
                try? await Task.sleep(for: .milliseconds(500))
                let postRedirectText = await executeJS("document.body ? document.body.innerText.substring(0, 2000) : ''") ?? ""
                lastContent = postRedirectText
                if postRedirectText.contains("Welcome!") {
                    welcomeFound = true
                    let result = GreenBannerDetector.detectWelcomeText(in: postRedirectText)
                    welcomeContext = result.exact
                    welcomeScreenshot = await captureScreenshot()
                }
                break
            }

            let contentLower = pageText.lowercased()

            let errorBannerTerms = ["error", "error!", "login error", "an error occurred", "error occurred"]
            for term in errorBannerTerms {
                if contentLower.contains(term) && contentChanged {
                    let context = pageText.components(separatedBy: .newlines)
                        .first { $0.lowercased().contains("error") }
                    return RapidPollResult(
                        welcomeTextFound: false,
                        welcomeContext: nil,
                        welcomeScreenshot: nil,
                        redirectedToHomepage: false,
                        finalURL: lastURL,
                        finalPageContent: lastContent,
                        navigationDetected: navDetected,
                        anyContentChange: contentChanged,
                        errorBannerDetected: true,
                        errorBannerText: context?.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
            }

            let failIndicators = ["incorrect", "invalid", "wrong password", "authentication failed",
                                  "login failed", "not recognized", "disabled", "blocked",
                                  "blacklist", "locked", "suspended", "banned",
                                  "temporarily", "too many attempts", "try again"]
            for indicator in failIndicators {
                if contentLower.contains(indicator) && contentChanged {
                    return RapidPollResult(
                        welcomeTextFound: false,
                        welcomeContext: nil,
                        welcomeScreenshot: nil,
                        redirectedToHomepage: false,
                        finalURL: lastURL,
                        finalPageContent: lastContent,
                        navigationDetected: navDetected,
                        anyContentChange: contentChanged,
                        errorBannerDetected: false,
                        errorBannerText: nil
                    )
                }
            }
        }

        return RapidPollResult(
            welcomeTextFound: welcomeFound,
            welcomeContext: welcomeContext,
            welcomeScreenshot: welcomeScreenshot,
            redirectedToHomepage: redirectedHome,
            finalURL: lastURL,
            finalPageContent: lastContent,
            navigationDetected: navDetected,
            anyContentChange: contentChanged,
            errorBannerDetected: false,
            errorBannerText: nil
        )
    }

    /// Polls the login button's DOM state and returns `true` as soon as it
    /// leaves the loading/disabled appearance, or `false` if it is still loading
    /// after `timeout` seconds.  A missing button is treated as "ready" (the
    /// page has navigated away from the login form).
    func waitForLoginButtonReady(timeout: TimeInterval = 8) async -> Bool {
        let js = """
        (function() {
            var btns = document.querySelectorAll('button, input[type="submit"], a.btn, [role="button"]');
            for (var i = 0; i < btns.length; i++) {
                var text = (btns[i].textContent || btns[i].value || '').toLowerCase().trim();
                if (text === 'log in' || text === 'login' || text === 'sign in' || text === 'signin' ||
                    text.indexOf('log in') !== -1 || text.indexOf('login') !== -1 || text.indexOf('sign in') !== -1) {
                    var btn = btns[i];
                    if (btn.disabled) return 'LOADING';
                    var classes = (btn.className || '').toLowerCase();
                    var ariaDisabled = btn.getAttribute('aria-disabled');
                    if (classes.indexOf('loading') !== -1 || classes.indexOf('spinner') !== -1 ||
                        classes.indexOf('pending') !== -1 || classes.indexOf('submitting') !== -1 ||
                        ariaDisabled === 'true') return 'LOADING';
                    return 'READY';
                }
            }
            var spinners = document.querySelectorAll('.spinner, .loading, [aria-busy="true"]');
            if (spinners.length > 0) return 'LOADING';
            return 'READY';
        })();
        """
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            let state = await executeJS(js) ?? "READY"
            if state != "LOADING" { return true }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return false
    }

    func waitForNavigation(timeout: TimeInterval = 20) async -> Bool {
        let start = Date()
        let originalURL = webView?.url?.absoluteString ?? ""
        let originalBody = await executeJS("document.body ? document.body.innerText.substring(0, 200) : ''") ?? ""

        while Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(for: .milliseconds(750))

            let currentURL = webView?.url?.absoluteString ?? ""
            if currentURL != originalURL && !currentURL.isEmpty {
                try? await Task.sleep(for: .milliseconds(1500))
                return true
            }

            let bodyText = await executeJS("document.body ? document.body.innerText.substring(0, 500) : ''") ?? ""
            if bodyText != originalBody && bodyText.count > 30 {
                let bodyLower = bodyText.lowercased()
                let indicators = ["welcome", "dashboard", "account", "balance", "deposit",
                                  "incorrect", "invalid", "wrong", "disabled", "blocked",
                                  "blacklist", "locked", "error", "failed", "try again"]
                for indicator in indicators {
                    if bodyLower.contains(indicator) {
                        try? await Task.sleep(for: .milliseconds(1000))
                        return true
                    }
                }
            }
        }
        return false
    }

    func getPageContent() async -> String {
        await executeJS("document.body ? document.body.innerText.substring(0, 3000) : ''") ?? ""
    }

    func getPageTitle() async -> String {
        await executeJS("document.title") ?? "Unknown"
    }

    func getCurrentURL() async -> String {
        webView?.url?.absoluteString ?? "N/A"
    }

    func captureScreenshot() async -> UIImage? {
        guard let webView else { return nil }
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        do {
            return try await webView.takeSnapshot(configuration: config)
        } catch {
            return nil
        }
    }

    func captureScreenshotWithCrop(cropRect: CGRect?) async -> (full: UIImage?, cropped: UIImage?) {
        guard let fullImage = await captureScreenshot() else { return (nil, nil) }
        guard let cropRect, cropRect != .zero else { return (fullImage, nil) }
        let scale = fullImage.scale
        let scaledRect = CGRect(
            x: cropRect.origin.x * scale,
            y: cropRect.origin.y * scale,
            width: cropRect.size.width * scale,
            height: cropRect.size.height * scale
        )
        if let cgImage = fullImage.cgImage?.cropping(to: scaledRect) {
            let cropped = UIImage(cgImage: cgImage, scale: scale, orientation: fullImage.imageOrientation)
            return (fullImage, cropped)
        }
        return (fullImage, nil)
    }

    func dumpPageStructure() async -> String {
        let js = """
        (function() {
            var info = {};
            info.title = document.title;
            info.url = window.location.href;
            info.readyState = document.readyState;
            var inputs = document.querySelectorAll('input, select, textarea');
            info.inputCount = inputs.length;
            info.inputs = [];
            for (var i = 0; i < Math.min(inputs.length, 20); i++) {
                var inp = inputs[i];
                info.inputs.push({tag: inp.tagName, type: inp.type || '', id: inp.id || '', name: inp.name || '', placeholder: inp.placeholder || ''});
            }
            var buttons = document.querySelectorAll('button, input[type="submit"], [role="button"]');
            info.buttonCount = buttons.length;
            var bodyText = (document.body ? document.body.innerText : '').substring(0, 500);
            info.bodyPreview = bodyText;
            return JSON.stringify(info);
        })();
        """
        return await executeJS(js) ?? "{}"
    }

    private func classifyFillResult(_ result: String?, fieldName: String) -> (success: Bool, detail: String) {
        switch result {
        case "OK":
            return (true, "\(fieldName) filled successfully")
        case "VALUE_MISMATCH":
            return (true, "\(fieldName) filled but value verification mismatch")
        case "NOT_FOUND":
            return (false, "\(fieldName) selector NOT_FOUND")
        case nil:
            return (false, "\(fieldName) JS execution returned nil")
        default:
            return (false, "\(fieldName) unexpected result: '\(result ?? "")'")
        }
    }

    private func executeJS(_ js: String) async -> String? {
        guard let webView else { return nil }
        do {
            let result = try await webView.evaluateJavaScript(js)
            if let str = result as? String { return str }
            if let num = result as? NSNumber { return "\(num)" }
            return nil
        } catch {
            return nil
        }
    }
}

extension LoginSiteWebSession: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.isPageLoaded = true
            if let cont = self.pageLoadContinuation {
                self.pageLoadContinuation = nil
                cont.resume(returning: true)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.lastNavigationError = self.classifyNavigationError(error)
            if let cont = self.pageLoadContinuation {
                self.pageLoadContinuation = nil
                cont.resume(returning: false)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.lastNavigationError = self.classifyNavigationError(error)
            if let cont = self.pageLoadContinuation {
                self.pageLoadContinuation = nil
                cont.resume(returning: false)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(.allow)
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let httpResponse = navigationResponse.response as? HTTPURLResponse {
            Task { @MainActor in
                self.lastHTTPStatusCode = httpResponse.statusCode
            }
        }
        decisionHandler(.allow)
    }

    private func classifyNavigationError(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet: return "No internet connection"
            case NSURLErrorTimedOut: return "Connection timed out"
            case NSURLErrorCannotFindHost: return "DNS resolution failed"
            case NSURLErrorCannotConnectToHost: return "Cannot connect to server"
            case NSURLErrorNetworkConnectionLost: return "Network connection lost"
            case NSURLErrorDNSLookupFailed: return "DNS lookup failed"
            case NSURLErrorSecureConnectionFailed: return "SSL/TLS handshake failed"
            default: return "Network error (\(nsError.code)): \(nsError.localizedDescription)"
            }
        }
        if nsError.domain == "WebKitErrorDomain" {
            switch nsError.code {
            case 102: return "Frame load interrupted"
            case 101: return "Request cancelled"
            default: return "WebKit error (\(nsError.code)): \(nsError.localizedDescription)"
            }
        }
        return "Navigation error: \(error.localizedDescription)"
    }
}
