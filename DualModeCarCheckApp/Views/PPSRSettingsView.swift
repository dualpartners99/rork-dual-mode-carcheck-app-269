import SwiftUI

struct PPSRSettingsView: View {
    @Bindable var vm: PPSRAutomationViewModel
    @AppStorage("productMode") private var modeRaw: String = ProductMode.ppsr.rawValue
    @State private var showEmailImport: Bool = false
    @State private var emailCSVText: String = ""
    @State private var cropX: String = ""
    @State private var cropY: String = ""
    @State private var cropW: String = ""
    @State private var cropH: String = ""
    @State private var showCropEditor: Bool = false

    var body: some View {
        List {
            modeSection
            importSection
            automationSection
            stealthSection
            dohSection
            emailSection
            screenshotSection
            debugSection
            appearanceSection
            iCloudSection
            concurrencySection
            endpointSection
            aboutSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
        .sheet(isPresented: $showEmailImport) { emailImportSheet }
        .sheet(isPresented: $showCropEditor) { cropEditorSheet }
    }

    private var modeSection: some View {
        Section("Mode") {
            Picker("Active Product", selection: Binding(
                get: { ProductMode(rawValue: modeRaw) ?? .ppsr },
                set: { modeRaw = $0.rawValue }
            )) {
                Text("PPSR CarCheck").tag(ProductMode.ppsr)
                Text("Joe & Ignition Login").tag(ProductMode.login)
            }
            .pickerStyle(.menu)
        }
    }

    private var stealthSection: some View {
        Section {
            Toggle(isOn: $vm.stealthEnabled) {
                HStack(spacing: 10) {
                    Image(systemName: "eye.slash.fill").foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ultra Stealth Mode").font(.body)
                        Text("Rotating user agents, fingerprints & viewports").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .tint(.purple)
            .sensoryFeedback(.impact(weight: .light), trigger: vm.stealthEnabled)
        } header: {
            Text("Stealth")
        } footer: {
            Text(vm.stealthEnabled ? "Each session uses a unique browser identity. Canvas, WebGL, timezone and navigator properties are spoofed." : "Enable to rotate browser fingerprints across sessions.")
        }
    }

    private var dohSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill").foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Secure DoH DNS Rotation").font(.body)
                    Text("\(PPSRDoHService.shared.providerCount) providers · rotates each test").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: vm.stealthEnabled ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(vm.stealthEnabled ? .green : .secondary)
            }

            if vm.stealthEnabled {
                ForEach(Array(PPSRDoHService.shared.providers.enumerated()), id: \.offset) { index, provider in
                    HStack(spacing: 10) {
                        Text("\(index + 1)").font(.system(.caption2, design: .monospaced, weight: .bold)).foregroundStyle(.secondary).frame(width: 18)
                        Text(provider.name).font(.system(.subheadline, design: .monospaced))
                        Spacer()
                        Text(provider.url.replacingOccurrences(of: "https://", with: ""))
                            .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
            }
        } header: {
            Text("DNS-over-HTTPS")
        } footer: {
            Text(vm.stealthEnabled ? "Each test resolves the target domain through a different secure DoH provider." : "Enable Ultra Stealth Mode to activate DoH DNS rotation.")
        }
    }

    private var automationSection: some View {
        Section {
            Toggle(isOn: $vm.retrySubmitOnFail) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Retry Submit on Fail").font(.body)
                        Text("Automatically retries submit if no clear result").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .tint(.orange)
            .sensoryFeedback(.impact(weight: .light), trigger: vm.retrySubmitOnFail)
        } header: {
            Text("Automation")
        }
    }

    private var screenshotSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.dashed").foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Screenshot Mode").font(.body)
                    Text("Full-page capture on every test").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Full Page").font(.system(.caption, design: .monospaced, weight: .bold)).foregroundStyle(.indigo)
                    .padding(.horizontal, 8).padding(.vertical, 4).background(Color.indigo.opacity(0.12)).clipShape(Capsule())
            }

            Button {
                cropX = vm.screenshotCropRect == .zero ? "" : "\(Int(vm.screenshotCropRect.origin.x))"
                cropY = vm.screenshotCropRect == .zero ? "" : "\(Int(vm.screenshotCropRect.origin.y))"
                cropW = vm.screenshotCropRect == .zero ? "" : "\(Int(vm.screenshotCropRect.size.width))"
                cropH = vm.screenshotCropRect == .zero ? "" : "\(Int(vm.screenshotCropRect.size.height))"
                showCropEditor = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "crop").foregroundStyle(.indigo)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Focus Crop Area").font(.body)
                        Text(vm.screenshotCropRect == .zero ? "No crop — showing full page" : "Crop: \(Int(vm.screenshotCropRect.origin.x)),\(Int(vm.screenshotCropRect.origin.y)) \(Int(vm.screenshotCropRect.width))×\(Int(vm.screenshotCropRect.height))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }

            if vm.screenshotCropRect != .zero {
                Button(role: .destructive) {
                    vm.screenshotCropRect = .zero
                    vm.persistSettings()
                    vm.log("Cleared screenshot focus crop area")
                } label: {
                    Label("Clear Focus Crop", systemImage: "xmark.circle")
                }
            }
        } header: {
            Text("Screenshots")
        }
    }

    private var debugSection: some View {
        Section {
            Toggle(isOn: $vm.debugMode) {
                HStack(spacing: 10) {
                    Image(systemName: "ladybug.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Debug Mode").font(.body)
                        Text("Captures full-page screenshot per test").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .tint(.orange)

            if vm.debugMode {
                NavigationLink {
                    PPSRDebugScreenshotsView(vm: vm)
                } label: {
                    HStack {
                        Image(systemName: "photo.stack").foregroundStyle(.orange)
                        Text("Debug Screenshots")
                        Spacer()
                        Text("\(vm.debugScreenshots.count)").font(.system(.caption, design: .monospaced, weight: .bold)).foregroundStyle(.secondary)
                    }
                }

                if !vm.debugScreenshots.isEmpty {
                    Button(role: .destructive) { vm.debugScreenshots.removeAll() } label: { Label("Clear All Screenshots", systemImage: "trash") }
                }
            }
        } header: {
            Text("Debug")
        } footer: {
            Text(vm.debugMode ? "Full-page screenshot captured per test." : "Enable to capture WebView screenshots during automation.")
        }
    }

    private var importSection: some View {
        Section {
            if !vm.untestedCards.isEmpty {
                Button {
                    vm.testAllUntested()
                } label: {
                    HStack {
                        Spacer()
                        Label("Test All Untested (\(vm.untestedCards.count))", systemImage: "play.fill").font(.headline)
                        Spacer()
                    }
                }
                .disabled(vm.isRunning)
                .listRowBackground(vm.isRunning ? Color.indigo.opacity(0.4) : Color.indigo)
                .foregroundStyle(.white)
                .sensoryFeedback(.impact(weight: .heavy), trigger: vm.isRunning)
            }
        } header: {
            Text("Quick Actions")
        }
    }

    private var iCloudSection: some View {
        Section {
            Button { vm.syncFromiCloud() } label: {
                HStack(spacing: 10) { Image(systemName: "icloud.and.arrow.down").foregroundStyle(.blue); Text("Sync from iCloud") }
            }
            Button {
                vm.persistCards()
                vm.log("Forced save to local + iCloud", level: .success)
            } label: {
                HStack(spacing: 10) { Image(systemName: "icloud.and.arrow.up").foregroundStyle(.blue); Text("Force Save to iCloud") }
            }
        } header: {
            Text("iCloud Sync")
        } footer: {
            Text("Cards are automatically saved locally and to iCloud.")
        }
    }

    private var emailSection: some View {
        Section {
            Toggle(isOn: $vm.useEmailRotation) {
                HStack(spacing: 10) {
                    Image(systemName: "envelope.arrow.triangle.branch.fill").foregroundStyle(.teal)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Generate Email").font(.body)
                        Text("Rotate through uploaded email list").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .tint(.teal)

            if vm.useEmailRotation {
                HStack {
                    Image(systemName: "list.bullet").foregroundStyle(.teal)
                    Text("Email Pool")
                    Spacer()
                    Text("\(vm.rotationEmailCount) emails").font(.system(.caption, design: .monospaced, weight: .bold)).foregroundStyle(.secondary)
                }
                Button { showEmailImport = true } label: { Label("Import Email CSV", systemImage: "square.and.arrow.down") }
                if vm.rotationEmailCount > 0 {
                    Button { vm.resetRotationEmailsToDefault() } label: { Label("Reset to Default List", systemImage: "arrow.counterclockwise") }
                    Button(role: .destructive) { vm.clearRotationEmails() } label: { Label("Clear Email List", systemImage: "trash") }
                }
            }

            if !vm.useEmailRotation {
                TextField("Test email", text: $vm.testEmail)
                    .keyboardType(.emailAddress).textContentType(.emailAddress)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .font(.system(.body, design: .monospaced))
            }
        } header: {
            Text("Email")
        } footer: {
            Text(vm.useEmailRotation ? "Each test uses the next email from the pool." : "Applied to all PPSR checks.")
        }
    }

    private var concurrencySection: some View {
        Section {
            Picker("Max Sessions", selection: $vm.maxConcurrency) {
                ForEach(1...8, id: \.self) { n in Text("\(n)").tag(n) }
            }
            .pickerStyle(.menu)
        } header: {
            Text("Concurrency")
        } footer: {
            Text("Up to 8 concurrent WKWebView sessions.")
        }
    }

    private var endpointSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Target") {
                    HStack(spacing: 4) {
                        Circle().fill(endpointColor).frame(width: 6, height: 6)
                        Text(vm.connectionStatus == .connected ? "Live Production" : vm.connectionStatus.rawValue)
                            .font(.system(.body, design: .monospaced)).foregroundStyle(endpointColor)
                    }
                }
                LabeledContent("URL") { Text("transact.ppsr.gov.au/CarCheck/").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }
                LabeledContent("Cost") { Text("$2.00 per check").foregroundStyle(.orange) }
                LabeledContent("Timeout") { Text("\(Int(vm.testTimeout))s per test").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary) }
            }

            Button {
                Task { await vm.testConnection() }
            } label: {
                HStack {
                    if vm.connectionStatus == .connecting { ProgressView().controlSize(.small) }
                    Image(systemName: "antenna.radiowaves.left.and.right")
                    Text(vm.connectionStatus == .connecting ? "Testing..." : "Test Connection")
                }
            }
            .disabled(vm.connectionStatus == .connecting)

            Button {
                Task { await vm.runFullDiagnostic() }
            } label: {
                HStack {
                    if vm.isDiagnosticRunning { ProgressView().controlSize(.small) }
                    Image(systemName: "stethoscope").foregroundStyle(.cyan)
                    Text(vm.isDiagnosticRunning ? "Running Diagnostics..." : "Full Connection Diagnostic")
                }
            }
            .disabled(vm.isDiagnosticRunning)

            if let report = vm.diagnosticReport {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(report.steps) { step in
                        HStack(spacing: 6) {
                            Image(systemName: diagnosticStepIcon(step.status)).font(.caption2).foregroundStyle(diagnosticStepColor(step.status)).frame(width: 14)
                            Text(step.name).font(.system(.caption2, design: .monospaced, weight: .semibold))
                            Spacer()
                            if let ms = step.latencyMs { Text("\(ms)ms").font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary) }
                            Text(step.status.rawValue).font(.system(.caption2, design: .monospaced, weight: .bold)).foregroundStyle(diagnosticStepColor(step.status))
                        }
                    }
                }
                Text(report.recommendation).font(.caption2).foregroundStyle(report.overallHealthy ? .green : .orange)
            }
        } header: {
            Text("Live Endpoint")
        } footer: {
            if let health = vm.lastHealthCheck {
                Text("Last check: \(health.healthy ? "Healthy" : "Unhealthy") — \(health.detail)")
            }
        }
    }

    private var endpointColor: Color {
        switch vm.connectionStatus {
        case .connected: .green; case .connecting: .orange; case .disconnected: .secondary; case .error: .red
        }
    }

    private func diagnosticStepIcon(_ status: DiagnosticStep.StepStatus) -> String {
        switch status {
        case .passed: "checkmark.circle.fill"; case .failed: "xmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"; case .running: "arrow.triangle.2.circlepath"; case .pending: "circle"
        }
    }

    private func diagnosticStepColor(_ status: DiagnosticStep.StepStatus) -> Color {
        switch status {
        case .passed: .green; case .failed: .red; case .warning: .orange; case .running: .blue; case .pending: .secondary
        }
    }

    private var appearanceSection: some View {
        Section {
            Picker(selection: $vm.appearanceMode) {
                ForEach(PPSRAutomationViewModel.AppearanceMode.allCases, id: \.self) { mode in
                    Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                }
            } label: {
                HStack(spacing: 10) { Image(systemName: "paintbrush.fill").foregroundStyle(.purple); Text("Appearance") }
            }
        } header: {
            Text("Appearance")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: "7.0.0")
            LabeledContent("Engine", value: "WKWebView Live")
            LabeledContent("Storage", value: "Unlimited · Local + iCloud")
            LabeledContent("Stealth") { Text(vm.stealthEnabled ? "Ultra Stealth" : "Standard").foregroundStyle(vm.stealthEnabled ? .purple : .secondary) }
            LabeledContent("Mode") { Text("Live — Real Transactions").foregroundStyle(.orange) }
            Button(role: .destructive) { vm.clearAll() } label: { Label("Clear Session History", systemImage: "trash") }
        } header: {
            Text("About")
        }
    }

    private var cropEditorSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Focus Crop Area").font(.headline)
                    Text("Define a rectangle (in points) to crop from the full-page screenshot.").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        cropField("X", text: $cropX)
                        cropField("Y", text: $cropY)
                    }
                    HStack(spacing: 12) {
                        cropField("Width", text: $cropW)
                        cropField("Height", text: $cropH)
                    }
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Focus Crop").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showCropEditor = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let x = Double(cropX) ?? 0; let y = Double(cropY) ?? 0
                        let w = Double(cropW) ?? 0; let h = Double(cropH) ?? 0
                        if w > 0 && h > 0 {
                            vm.screenshotCropRect = CGRect(x: x, y: y, width: w, height: h)
                            vm.log("Set focus crop: \(Int(x)),\(Int(y)) \(Int(w))×\(Int(h))")
                        } else {
                            vm.screenshotCropRect = .zero
                        }
                        vm.persistSettings()
                        showCropEditor = false
                    }
                }
            }
        }
        .presentationDetents([.medium]).presentationDragIndicator(.visible)
    }

    private func cropField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.bold()).foregroundStyle(.secondary)
            TextField("0", text: text)
                .keyboardType(.numberPad).font(.system(.body, design: .monospaced))
                .padding(10).background(Color(.tertiarySystemGroupedBackground)).clipShape(.rect(cornerRadius: 8))
        }
    }

    private var emailImportSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Import Emails").font(.headline)
                    Text("Paste email addresses separated by commas or newlines.").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                TextEditor(text: $emailCSVText)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden).padding(12)
                    .background(Color(.tertiarySystemGroupedBackground)).clipShape(.rect(cornerRadius: 10))
                    .frame(minHeight: 180)
                Spacer()
            }
            .padding()
            .navigationTitle("Import Emails").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showEmailImport = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        let count = vm.importEmails(emailCSVText)
                        emailCSVText = ""
                        showEmailImport = false
                        vm.log("Imported \(count) emails for rotation", level: .success)
                    }
                    .disabled(emailCSVText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }
}
