import SwiftUI
import BackgroundTasks

@main
struct DualModeCarCheckAppApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("productMode") private var modeRaw: String = ProductMode.ppsr.rawValue
    @AppStorage("hasSelectedMode") private var hasSelectedMode: Bool = false
    @State private var introFinished: Bool = false

    private var currentMode: ProductMode {
        ProductMode(rawValue: modeRaw) ?? .ppsr
    }

    var body: some Scene {
        WindowGroup {
            if !introFinished {
                IntroVideoView(isFinished: $introFinished)
                    .transition(.opacity)
            } else if hasSelectedMode {
                Group {
                    if currentMode == .ppsr {
                        ContentView()
                    } else {
                        LoginContentView()
                    }
                }
                .transition(.opacity)
            } else {
                ModeSelectorView(hasSelectedMode: $hasSelectedMode)
                    .transition(.opacity)
            }
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    nonisolated func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "app.rork.dual-mode-carcheck-app.refresh", using: nil) { task in
            task.setTaskCompleted(success: true)
        }

        BGTaskScheduler.shared.register(forTaskWithIdentifier: TempDisabledCheckService.bgTaskIdentifier, using: nil) { task in
            Task { @MainActor in
                guard let processingTask = task as? BGProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                let service = TempDisabledCheckService.shared
                guard service.backgroundCheckEnabled else {
                    processingTask.setTaskCompleted(success: true)
                    return
                }
                let credentials = LoginPersistenceService.shared.loadCredentials()
                let urlRotation = LoginURLRotationService.shared
                service.runPasswordCheck(
                    credentials: credentials,
                    getURL: { urlRotation.nextURL() ?? URL(string: "https://www.joefortune.com")! },
                    persistCredentials: { LoginPersistenceService.shared.saveCredentials(credentials) },
                    onLog: { msg, _ in print("[BG TempDisabled] \(msg)") }
                )
                processingTask.expirationHandler = {
                    service.stopCheck()
                }
                while service.isRunning {
                    try? await Task.sleep(for: .seconds(1))
                }
                processingTask.setTaskCompleted(success: true)
            }
        }
        return true
    }

    nonisolated func applicationDidEnterBackground(_ application: UIApplication) {
        scheduleBackgroundRefresh()
    }

    nonisolated private func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: "app.rork.dual-mode-carcheck-app.refresh")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)

        Task { @MainActor in
            if TempDisabledCheckService.shared.backgroundCheckEnabled {
                TempDisabledCheckService.shared.scheduleNextBackgroundCheck()
            }
        }
    }
}
