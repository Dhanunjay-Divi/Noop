import StrandDesign
import SwiftUI
import WhoopStore

struct NutritionBarcodeLookupView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var repo: Repository

    let onSelect: (NutritionCatalogItemRow) -> Void

    @State private var barcode = ""
    @State private var loading = false
    @State private var errorMessage: String?
    #if os(iOS)
    @State private var scannerPresented = false
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    NoopCard {
                        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                            TextField("nutrition.barcode.manual_label", text: $barcode)
                                .textFieldStyle(.roundedBorder)
                                #if os(iOS)
                                .keyboardType(.numberPad)
                                #endif
                                .disabled(loading)

                            HStack(spacing: NoopMetrics.space3) {
                                #if os(iOS)
                                Button {
                                    scannerPresented = true
                                } label: {
                                    Label(
                                        "nutrition.barcode.scan",
                                        systemImage: "barcode.viewfinder"
                                    )
                                }
                                .buttonStyle(NoopButtonStyle(.secondary))
                                .disabled(loading)
                                #endif

                                Button {
                                    lookup()
                                } label: {
                                    if loading {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text("nutrition.barcode.looking_up")
                                    } else {
                                        Label(
                                            "nutrition.barcode.lookup",
                                            systemImage: "magnifyingglass"
                                        )
                                    }
                                }
                                .buttonStyle(NoopButtonStyle(.primary))
                                .disabled(loading || barcode.trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                ).isEmpty)
                            }
                        }
                    }

                    NoopCard {
                        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                            Link(
                                destination: URL(string: "https://world.openfoodfacts.org")!
                            ) {
                                Label(
                                    "nutrition.barcode.attribution",
                                    systemImage: "arrow.up.right.square"
                                )
                            }
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.accent)

                            Text("nutrition.barcode.verify")
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(20)
            }
            .background(StrandPalette.surfaceBase)
            .navigationTitle("nutrition.barcode.title")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("nutrition.cancel") { dismiss() }
                        .disabled(loading)
                }
            }
        }
        .frame(minWidth: 360, minHeight: 420)
        #if os(iOS)
        .sheet(isPresented: $scannerPresented) {
            NutritionBarcodeScannerSheet { value in
                scannerPresented = false
                barcode = value
                lookup(value)
            }
        }
        #endif
        .alert("nutrition.barcode.title", isPresented: errorBinding) {
            Button("nutrition.ok", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func lookup(_ value: String? = nil) {
        guard !loading else { return }
        let requested = value ?? barcode
        guard NutritionCatalogContract.normalizedBarcode(requested) != nil else {
            errorMessage = NutritionBarcodeLookupError.invalidBarcode.localizedDescription
            return
        }
        loading = true
        Task { @MainActor in
            do {
                let item = try await repo.lookupNutritionBarcode(requested)
                loading = false
                onSelect(item)
            } catch {
                loading = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct NutritionLibraryPicker: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var repo: Repository

    let onSelect: (NutritionCatalogItemRow) -> Void

    @State private var items: [NutritionCatalogItemRow] = []
    @State private var loading = true
    @State private var deletingID: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    if loading {
                        ScreenStateCard(
                            kind: .loading,
                            title: "nutrition.library.loading_title",
                            message: "nutrition.library.loading_body"
                        )
                    } else if items.isEmpty {
                        ScreenStateCard(
                            kind: .empty,
                            title: "nutrition.library.empty_title",
                            message: "nutrition.library.empty_body",
                            symbol: "books.vertical"
                        )
                    } else {
                        NoopCard(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                    libraryRow(item)
                                    if index < items.count - 1 {
                                        Divider()
                                            .padding(.leading, 58)
                                            .foregroundStyle(StrandPalette.hairline)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(StrandPalette.surfaceBase)
            .navigationTitle("nutrition.library.title")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("nutrition.cancel") { dismiss() }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 480)
        .task { await load() }
        .alert("nutrition.library.title", isPresented: errorBinding) {
            Button("nutrition.ok", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func libraryRow(_ item: NutritionCatalogItemRow) -> some View {
        HStack(spacing: NoopMetrics.space3) {
            Image(systemName: item.kind == NutritionCatalogContract.mealKind
                  ? "fork.knife" : "takeoutbag.and.cup.and.straw.fill")
                .foregroundStyle(StrandPalette.accent)
                .frame(width: 34, height: 34)
                .background(StrandPalette.surfaceInset, in: Circle())
                .accessibilityHidden(true)

            Button {
                onSelect(item)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    Text(itemDetail(item))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("nutrition.library.log_hint"))

            Button(role: .destructive) {
                delete(item)
            } label: {
                if deletingID == item.id {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 44, height: 44)
                } else {
                    Image(systemName: "trash")
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(width: 44, height: 44)
                }
            }
            .buttonStyle(.plain)
            .disabled(deletingID != nil)
            .accessibilityLabel(
                nutritionFormat(
                    String(localized: "nutrition.library.delete_format"),
                    item.name
                )
            )
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
    }

    private func itemDetail(_ item: NutritionCatalogItemRow) -> String {
        var pieces: [String] = []
        if let brand = item.brand { pieces.append(brand) }
        if let calories = item.caloriesKcal {
            pieces.append(
                nutritionFormat(
                    String(localized: "nutrition.library.calories_format"),
                    calories.formatted(.number.precision(.fractionLength(0)))
                )
            )
        }
        if let quantity = item.servingQuantity, let unit = item.servingUnit {
            pieces.append(
                nutritionFormat(
                    String(localized: "nutrition.library.serving_format"),
                    quantity.formatted(.number.precision(.fractionLength(0...2))),
                    unit
                )
            )
        }
        return pieces.isEmpty
            ? String(localized: "nutrition.library.saved_item")
            : pieces.joined(separator: " · ")
    }

    @MainActor
    private func load() async {
        loading = true
        do {
            items = try await repo.nutritionLibrarySnapshot().items
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    private func delete(_ item: NutritionCatalogItemRow) {
        guard deletingID == nil else { return }
        deletingID = item.id
        Task { @MainActor in
            do {
                try await repo.removeNutritionCatalogItem(id: item.id)
                items.removeAll { $0.id == item.id }
            } catch {
                errorMessage = error.localizedDescription
            }
            deletingID = nil
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }
}
