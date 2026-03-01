import SwiftUI

struct ContentView: View {
    @AppStorage("productMode") private var modeRaw: String = ProductMode.ppsr.rawValue
    private var currentMode: ProductMode { ProductMode(rawValue: modeRaw) ?? .ppsr }

    @State private var vm = PPSRAutomationViewModel()
    @State private var selectedTab: AppTab = .dashboard

    nonisolated enum AppTab: String, Sendable {
        case dashboard, savedCards, workingCards, sessions, settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Dashboard", systemImage: "bolt.shield.fill", value: .dashboard) {
                NavigationStack {
                    LoginDashboardView(vm: vm)
                        .navigationDestination(for: String.self) { cardId in
                            if let card = vm.cards.first(where: { $0.id == cardId }) {
                                PPSRCardDetailView(card: card, vm: vm)
                            }
                        }
                }
            }

            Tab("Cards", systemImage: "creditcard.fill", value: .savedCards) {
                NavigationStack {
                    SavedCredentialsView(vm: vm)
                        .navigationDestination(for: String.self) { cardId in
                            if let card = vm.cards.first(where: { $0.id == cardId }) {
                                PPSRCardDetailView(card: card, vm: vm)
                            }
                        }
                }
            }

            Tab("Working", systemImage: "checkmark.shield.fill", value: .workingCards) {
                NavigationStack {
                    WorkingLoginsView(vm: vm)
                        .navigationDestination(for: String.self) { cardId in
                            if let card = vm.cards.first(where: { $0.id == cardId }) {
                                PPSRCardDetailView(card: card, vm: vm)
                            }
                        }
                }
            }

            Tab("Sessions", systemImage: "rectangle.stack", value: .sessions) {
                NavigationStack {
                    LoginSessionMonitorView(vm: vm)
                }
            }

            Tab("Settings", systemImage: "gearshape", value: .settings) {
                NavigationStack {
                    PPSRSettingsView(vm: vm)
                }
            }
        }
        .tint(.teal)
        .preferredColorScheme(vm.appearanceMode.colorScheme)
        .onChange(of: vm.cards.count) { _, _ in
            vm.persistCards()
        }
        .onChange(of: vm.appearanceMode) { _, _ in
            vm.persistSettings()
        }
        .onChange(of: vm.testEmail) { _, _ in
            vm.persistSettings()
        }
        .onChange(of: vm.debugMode) { _, _ in
            vm.persistSettings()
        }
        .onChange(of: vm.maxConcurrency) { _, _ in
            vm.persistSettings()
        }
        .onChange(of: vm.useEmailRotation) { _, _ in
            vm.persistSettings()
        }
        .onChange(of: vm.stealthEnabled) { _, _ in
            vm.persistSettings()
        }
        .onChange(of: vm.retrySubmitOnFail) { _, _ in
            vm.persistSettings()
        }
        .alert("Batch Results", isPresented: $vm.showBatchResultPopup) {
            Button("OK") {
                vm.showBatchResultPopup = false
            }
        } message: {
            if let result = vm.lastBatchResult {
                Text("Alive: \(result.working) (\(result.alivePercentage)%)\nDead: \(result.dead)\nRequeued: \(result.requeued)\nTotal: \(result.total)")
            } else {
                Text("No results available")
            }
        }
        .alert("Unusual Failures Detected", isPresented: $vm.showUnusualFailureAlert) {
            Button("Stop After Current", role: .destructive) {
                vm.stopAfterCurrent()
                vm.consecutiveUnusualFailures = 0
            }
            Button("Continue Testing", role: .cancel) {
                vm.consecutiveUnusualFailures = 0
            }
        } message: {
            Text("Multiple consecutive unusual/unrecognized failures detected.\n\n\(vm.unusualFailureMessage)\n\nWould you like to stop testing after the current batch completes?")
        }
    }
}
