import SwiftUI

struct SavedCredentialsView: View {
    let vm: PPSRAutomationViewModel
    @State private var showImportSheet: Bool = false
    @State private var importText: String = ""
    @State private var searchText: String = ""
    @State private var sortOption: SortOption = .dateAdded
    @State private var sortAscending: Bool = false
    @State private var filterBrand: CardBrand? = nil
    @State private var filterStatus: CardStatus? = nil
    @State private var filterCountry: String? = nil
    @State private var showFilters: Bool = false

    nonisolated enum SortOption: String, CaseIterable, Identifiable, Sendable {
        case dateAdded = "Date Added"
        case lastTest = "Last Test"
        case successRate = "Success Rate"
        case totalTests = "Total Tests"
        case bin = "BIN Number"
        case brand = "Brand"
        case country = "Country"
        var id: String { rawValue }
    }

    private var filteredCards: [PPSRCard] {
        var result = vm.cards.filter { $0.status != .dead }
        if !searchText.isEmpty {
            result = result.filter {
                $0.number.localizedStandardContains(searchText) ||
                $0.brand.rawValue.localizedStandardContains(searchText) ||
                $0.binPrefix.localizedStandardContains(searchText) ||
                ($0.binData?.country ?? "").localizedStandardContains(searchText) ||
                ($0.binData?.issuer ?? "").localizedStandardContains(searchText)
            }
        }
        if let brand = filterBrand { result = result.filter { $0.brand == brand } }
        if let status = filterStatus { result = result.filter { $0.status == status } }
        if let country = filterCountry, !country.isEmpty { result = result.filter { $0.binData?.country == country } }

        result.sort { a, b in
            let comparison: Bool
            switch sortOption {
            case .dateAdded: comparison = a.addedAt > b.addedAt
            case .lastTest: comparison = (a.lastTestedAt ?? .distantPast) > (b.lastTestedAt ?? .distantPast)
            case .successRate: comparison = a.successRate > b.successRate
            case .totalTests: comparison = a.totalTests > b.totalTests
            case .bin: comparison = a.binPrefix < b.binPrefix
            case .brand: comparison = a.brand.rawValue < b.brand.rawValue
            case .country: comparison = (a.binData?.country ?? "") < (b.binData?.country ?? "")
            }
            return sortAscending ? !comparison : comparison
        }
        return result
    }

    private var availableCountries: [String] {
        Set(vm.cards.compactMap { $0.binData?.country }.filter { !$0.isEmpty }).sorted()
    }

    private var availableBrands: [CardBrand] {
        Set(vm.cards.map(\.brand)).sorted { $0.rawValue < $1.rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            sortFilterBar
            if showFilters { filterSection }
            cardsList
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Saved Cards")
        .searchable(text: $searchText, prompt: "Search cards, BIN, bank, country...")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showImportSheet = true } label: { Image(systemName: "plus") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { withAnimation(.snappy) { showFilters.toggle() } } label: {
                    Image(systemName: showFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
            }
        }
        .sheet(isPresented: $showImportSheet) { importSheet }
    }

    private var sortFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(SortOption.allCases) { option in
                        Button {
                            withAnimation(.snappy) {
                                if sortOption == option { sortAscending.toggle() }
                                else { sortOption = option; sortAscending = false }
                            }
                        } label: {
                            HStack {
                                Text(option.rawValue)
                                if sortOption == option { Image(systemName: sortAscending ? "chevron.up" : "chevron.down") }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down").font(.caption2)
                        Text(sortOption.rawValue).font(.subheadline.weight(.medium))
                        Image(systemName: sortAscending ? "chevron.up" : "chevron.down").font(.caption2)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.teal.opacity(0.15))
                    .foregroundStyle(.teal)
                    .clipShape(Capsule())
                }

                Text("\(filteredCards.count) cards")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Color(.tertiarySystemFill)).clipShape(Capsule())

                if filterBrand != nil || filterStatus != nil || filterCountry != nil {
                    Button {
                        withAnimation(.snappy) { filterBrand = nil; filterStatus = nil; filterCountry = nil }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark").font(.caption2)
                            Text("Clear").font(.subheadline.weight(.medium))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.red.opacity(0.12)).foregroundStyle(.red).clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal).padding(.vertical, 10)
        }
    }

    private var filterSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Text("Brand").font(.caption.bold()).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        FilterChipSmall(title: "All", isSelected: filterBrand == nil) { withAnimation(.snappy) { filterBrand = nil } }
                        ForEach(availableBrands, id: \.self) { brand in
                            FilterChipSmall(title: brand.rawValue, isSelected: filterBrand == brand) { withAnimation(.snappy) { filterBrand = brand } }
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Text("Status").font(.caption.bold()).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        FilterChipSmall(title: "All", isSelected: filterStatus == nil) { withAnimation(.snappy) { filterStatus = nil } }
                        FilterChipSmall(title: "Working", isSelected: filterStatus == .working) { withAnimation(.snappy) { filterStatus = .working } }
                        FilterChipSmall(title: "Untested", isSelected: filterStatus == .untested) { withAnimation(.snappy) { filterStatus = .untested } }
                    }
                }
            }
            if !availableCountries.isEmpty {
                HStack(spacing: 8) {
                    Text("Country").font(.caption.bold()).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            FilterChipSmall(title: "All", isSelected: filterCountry == nil) { withAnimation(.snappy) { filterCountry = nil } }
                            ForEach(availableCountries, id: \.self) { country in
                                FilterChipSmall(title: country, isSelected: filterCountry == country) { withAnimation(.snappy) { filterCountry = country } }
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal).padding(.bottom, 10)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var cardsList: some View {
        Group {
            if filteredCards.isEmpty {
                ContentUnavailableView {
                    Label("No Cards", systemImage: "creditcard.trianglebadge.exclamationmark")
                } description: {
                    if vm.cards.isEmpty { Text("Import cards to get started.") }
                    else { Text("No cards match your filters.") }
                } actions: {
                    if vm.cards.isEmpty { Button("Import Cards") { showImportSheet = true } }
                }
            } else {
                List {
                    ForEach(filteredCards) { card in
                        NavigationLink(value: card.id) {
                            SavedCardRow(card: card)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { vm.deleteCard(card) } label: { Label("Delete", systemImage: "trash") }
                            Button { vm.testSingleCard(card) } label: { Label("Test", systemImage: "play.fill") }.tint(.teal)
                        }
                        .listRowBackground(Color(.secondarySystemGroupedBackground))
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    private var importSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Smart Import").font(.headline)
                    Text("Paste card data in any common format. The parser automatically detects separators.")
                        .font(.caption).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Supported formats:").font(.caption.bold()).foregroundStyle(.secondary)
                        Group {
                            Text("4111111111111111|12|28|123")
                            Text("4111111111111111:12:28:123")
                            Text("4111111111111111,12,28,123")
                            Text("4111111111111111;12;28;123")
                            Text("4111111111111111 12 28 123")
                        }
                        .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                TextEditor(text: $importText)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .clipShape(.rect(cornerRadius: 10))
                    .frame(minHeight: 180)

                Spacer()
            }
            .padding()
            .navigationTitle("Import Cards")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showImportSheet = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        vm.smartImportCards(importText)
                        importText = ""
                        showImportSheet = false
                    }
                    .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }
}

struct SavedCardRow: View {
    let card: PPSRCard

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(brandColor.opacity(0.12)).frame(width: 40, height: 40)
                Image(systemName: card.brand.iconName).font(.title3.bold()).foregroundStyle(brandColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(card.brand.rawValue).font(.subheadline.bold())
                    Text(card.number).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 8) {
                    Text(card.formattedExpiry).font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary)
                    if let binData = card.binData, binData.isLoaded {
                        if !binData.country.isEmpty {
                            Text(binData.country).font(.caption2).foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color(.tertiarySystemFill)).clipShape(Capsule())
                        }
                    }
                }
                HStack(spacing: 8) {
                    Text("BIN \(card.binPrefix)").font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                    if card.totalTests > 0 {
                        Text("\(card.successCount)/\(card.totalTests)").font(.caption2.bold())
                            .foregroundStyle(card.lastTestSuccess == true ? .green : .red)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 3) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(card.status.rawValue).font(.system(.caption2, design: .monospaced)).foregroundStyle(statusColor)
                }
                if card.status == .testing { ProgressView().controlSize(.small).tint(.teal) }
            }
        }
        .padding(.vertical, 4)
        .task { if card.binData == nil { await card.loadBINData() } }
    }

    private var brandColor: Color {
        switch card.brand {
        case .visa: .blue; case .mastercard: .orange; case .amex: .green; case .jcb: .red
        case .discover: .purple; case .dinersClub: .indigo; case .unionPay: .teal; case .unknown: .secondary
        }
    }

    private var statusColor: Color {
        switch card.status {
        case .working: .green; case .dead: .red; case .testing: .teal; case .untested: .secondary
        }
    }
}

struct FilterChipSmall: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(isSelected ? Color.teal : Color(.tertiarySystemFill))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
