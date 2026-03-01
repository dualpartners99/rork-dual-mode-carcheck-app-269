import SwiftUI

struct LoginDashboardView: View {
    let vm: PPSRAutomationViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                statusHeader
                if vm.connectionStatus == .error || vm.diagnosticReport != nil {
                    connectionDiagnosticsCard
                }
                if vm.isRunning {
                    testingBanner
                    queueControls
                }
                if vm.stealthEnabled {
                    stealthBadge
                }
                statsRow
                if !vm.untestedCards.isEmpty {
                    cardSection(title: "Queued — Untested", cards: vm.untestedCards, color: .secondary, icon: "clock.fill")
                }
                if !vm.testingCards.isEmpty {
                    cardSection(title: "Testing Now", cards: vm.testingCards, color: .teal, icon: "arrow.triangle.2.circlepath")
                }
                if !vm.deadCards.isEmpty {
                    deadCardsSection
                }
                if vm.cards.isEmpty {
                    emptyState
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Dashboard")
        .task {
            await vm.testConnection()
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.shield.fill")
                .font(.system(size: 32))
                .foregroundStyle(.teal)
                .symbolEffect(.pulse, isActive: vm.isRunning)

            VStack(alignment: .leading, spacing: 2) {
                Text("PPSR TestFlow")
                    .font(.title3.bold())
                Text("transact.ppsr.gov.au")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            connectionBadge
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
    }

    private var connectionBadge: some View {
        Button {
            Task { await vm.testConnection() }
        } label: {
            HStack(spacing: 4) {
                if vm.connectionStatus == .connecting || vm.isDiagnosticRunning {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Circle()
                        .fill(connectionColor)
                        .frame(width: 7, height: 7)
                }
                Text(vm.connectionStatus == .connecting ? "Testing..." : vm.connectionStatus.rawValue)
                    .font(.caption2.bold())
                    .foregroundStyle(connectionColor)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(connectionColor.opacity(0.12))
            .clipShape(Capsule())
        }
        .sensoryFeedback(.impact(weight: .light), trigger: vm.connectionStatus.rawValue)
    }

    private var connectionColor: Color {
        switch vm.connectionStatus {
        case .connected: .green
        case .connecting: .orange
        case .disconnected: .secondary
        case .error: .red
        }
    }

    private var stealthBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash.fill")
                .font(.caption)
                .foregroundStyle(.purple)
            Text("Ultra Stealth Mode")
                .font(.caption.bold())
                .foregroundStyle(.purple)
            Spacer()
            Text("Rotating UA + Fingerprints")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.purple.opacity(0.08))
        .clipShape(.rect(cornerRadius: 10))
    }

    private var testingBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(.teal)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("Testing in Progress")
                        .font(.subheadline.bold())
                        .foregroundStyle(.teal)
                    if vm.isPaused {
                        Text("PAUSED")
                            .font(.system(.caption2, design: .monospaced, weight: .heavy))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    if vm.isStopping {
                        Text("STOPPING")
                            .font(.system(.caption2, design: .monospaced, weight: .heavy))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                Text("\(vm.activeTestCount) active · \(vm.untestedCards.count) queued · \(vm.testingCards.count) testing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color.teal.opacity(0.08))
        .clipShape(.rect(cornerRadius: 12))
    }

    private var queueControls: some View {
        HStack(spacing: 10) {
            if vm.isPaused {
                Button {
                    vm.resumeQueue()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.green.opacity(0.15))
                        .foregroundStyle(.green)
                        .clipShape(.rect(cornerRadius: 12))
                }
            } else {
                Button {
                    vm.pauseQueue()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.orange.opacity(0.15))
                        .foregroundStyle(.orange)
                        .clipShape(.rect(cornerRadius: 12))
                }
            }

            Button {
                vm.stopQueue()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.red.opacity(0.15))
                    .foregroundStyle(.red)
                    .clipShape(.rect(cornerRadius: 12))
            }
            .disabled(vm.isStopping)
        }
    }

    private var statsRow: some View {
        HStack(spacing: 10) {
            MiniStat(value: "\(vm.workingCards.count)", label: "Working", color: .green, icon: "checkmark.circle.fill")
            MiniStat(value: "\(vm.untestedCards.count)", label: "Queued", color: .secondary, icon: "clock")
            MiniStat(value: "\(vm.deadCards.count)", label: "Dead", color: .red, icon: "xmark.circle.fill")
            MiniStat(value: "\(vm.cards.count)", label: "Total", color: .blue, icon: "creditcard.fill")
        }
    }

    private func cardSection(title: String, cards: [PPSRCard], color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(color)
                Text(title)
                    .font(.headline)
                Spacer()
                Text("\(cards.count)")
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.12))
                    .clipShape(Capsule())
                    .foregroundStyle(color)
            }

            ForEach(cards) { card in
                NavigationLink(value: card.id) {
                    CardRow(card: card, accentColor: color)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var deadCardsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "trash.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                Text("Dead Cards")
                    .font(.headline)
                Spacer()
                Text("\(vm.deadCards.count)")
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.12))
                    .clipShape(Capsule())
                    .foregroundStyle(.red)

                Button {
                    vm.purgeDeadCards()
                } label: {
                    Text("Purge All")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                }
            }

            ForEach(vm.deadCards) { card in
                NavigationLink(value: card.id) {
                    CardRow(card: card, accentColor: .red)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var connectionDiagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: vm.connectionStatus == .error ? "exclamationmark.triangle.fill" : "stethoscope")
                    .font(.title3)
                    .foregroundStyle(vm.connectionStatus == .error ? .red : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.connectionStatus == .error ? "Connection Issue Detected" : "Connection Diagnostics")
                        .font(.subheadline.bold())
                    if let health = vm.lastHealthCheck {
                        Text(health.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if vm.isDiagnosticRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let report = vm.diagnosticReport {
                VStack(spacing: 6) {
                    ForEach(report.steps) { step in
                        HStack(spacing: 8) {
                            Image(systemName: stepIcon(step.status))
                                .font(.caption)
                                .foregroundStyle(stepColor(step.status))
                                .frame(width: 16)
                            Text(step.name)
                                .font(.system(.caption, design: .monospaced, weight: .semibold))
                                .frame(width: 110, alignment: .leading)
                            Text(step.detail)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Spacer()
                            if let ms = step.latencyMs {
                                Text("\(ms)ms")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                Text(report.recommendation)
                    .font(.caption)
                    .foregroundStyle(report.overallHealthy ? .green : .orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background((report.overallHealthy ? Color.green : Color.orange).opacity(0.08))
                    .clipShape(.rect(cornerRadius: 8))
            }

            HStack(spacing: 10) {
                Button {
                    Task { await vm.runFullDiagnostic() }
                } label: {
                    Label(vm.isDiagnosticRunning ? "Running..." : "Run Diagnostics", systemImage: "stethoscope")
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.blue.opacity(0.12))
                        .foregroundStyle(.blue)
                        .clipShape(.rect(cornerRadius: 10))
                }
                .disabled(vm.isDiagnosticRunning)

                Button {
                    Task { await vm.testConnection() }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.green.opacity(0.12))
                        .foregroundStyle(.green)
                        .clipShape(.rect(cornerRadius: 10))
                }
                .disabled(vm.connectionStatus == .connecting)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
    }

    private func stepIcon(_ status: DiagnosticStep.StepStatus) -> String {
        switch status {
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .running: "arrow.triangle.2.circlepath"
        case .pending: "circle"
        }
    }

    private func stepColor(_ status: DiagnosticStep.StepStatus) -> Color {
        switch status {
        case .passed: .green
        case .failed: .red
        case .warning: .orange
        case .running: .blue
        case .pending: .secondary
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "creditcard.trianglebadge.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No Cards Added")
                .font(.title3.bold())
            Text("Go to Cards tab to import.\nSupports many formats automatically.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

struct MiniStat: View {
    let value: String
    let label: String
    let color: Color
    let icon: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
            Text(value)
                .font(.system(.title3, design: .monospaced, weight: .bold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 10))
    }
}

struct CardRow: View {
    let card: PPSRCard
    let accentColor: Color

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(brandColor.opacity(0.12))
                    .frame(width: 38, height: 38)
                Image(systemName: card.brand.iconName)
                    .font(.title3)
                    .foregroundStyle(brandColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(card.brand.rawValue)
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                    Text(card.number)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    Text(card.formattedExpiry)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    if card.totalTests > 0 {
                        Text("\(card.successCount)/\(card.totalTests) passed")
                            .font(.caption2)
                            .foregroundStyle(card.status == .working ? .green : .red)
                    }
                }
            }

            Spacer()

            if card.status == .testing {
                ProgressView()
                    .tint(.teal)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 10))
    }

    private var brandColor: Color {
        switch card.brand {
        case .visa: .blue
        case .mastercard: .orange
        case .amex: .green
        case .jcb: .red
        case .discover: .purple
        case .dinersClub: .indigo
        case .unionPay: .teal
        case .unknown: .secondary
        }
    }
}
