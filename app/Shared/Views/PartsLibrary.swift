import SwiftUI

/// Add a real part: search JLCPCB (tscircuit's jlcsearch index, footprints from EasyEDA) or
/// DigiKey (your API key), or drop a generic resistor / capacitor / LED / chip. Choosing one arms
/// the Place tool; the part's module lands in `imports/` with the first placement.
struct PartsLibraryPanel: View {
    @Environment(\.palette) private var palette

    @Bindable var doc: DocumentModel
    var close: () -> Void
    var openSettings: () -> Void
    /// Put the cursor in the search field on open (not when the keyboard would cover the panel).
    var autofocus = true
    @AppStorage("partsSource") private var sourceRaw = PartsCatalog.Source.jlc.rawValue
    @AppStorage("partsInStock") private var inStock = true
    @State private var query = ""
    @State private var hits: [PartsCatalog.Hit] = []
    @State private var searching = false
    @State private var error: String?
    @State private var preparing: String?
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var source: PartsCatalog.Source { PartsCatalog.Source(rawValue: sourceRaw) ?? .jlc }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Button(action: close) { HeaderIcon(symbol: "chevron.left") }
                        .buttonStyle(.plain).accessibilityLabel("Back")
                    Text("Add a part").font(.headline)
                    Spacer()
                    Toggle("In stock", isOn: $inStock).toggleStyle(.button).font(.caption.weight(.semibold))
                        .buttonStyle(.bordered).controlSize(.small).tint(inStock ? palette.accent : .secondary)
                }
                Picker("Source", selection: $sourceRaw) {
                    ForEach(PartsCatalog.Source.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden()
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(source == .jlc ? "Part, value or LCSC number — “ESP32-S3”, “10k 0402”, “C25804”" : "Part or value — “USB-C receptacle”, “100nF 0603”", text: $query)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit { search(now: true) }
                        #if os(iOS)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        #endif
                    if searching { ProgressView().controlSize(.small) }
                    else if !query.isEmpty {
                        Button { query = ""; hits = []; error = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel("Clear")
                    }
                }
                .padding(.horizontal, 14).frame(height: 42)
                .background(.primary.opacity(0.06), in: .capsule)
            }
            .padding([.horizontal, .top], 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let error { errorCard(error) }
                    if query.isEmpty { generics }
                    ForEach(hits) { row($0) }
                    if !query.isEmpty && hits.isEmpty && !searching && error == nil {
                        Text("No parts found.").font(.subheadline).foregroundStyle(.secondary).padding(12)
                    }
                }
                .padding(12)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .onChange(of: query) { _, _ in search(now: false) }
        .onChange(of: sourceRaw) { _, _ in hits = []; error = nil; search(now: true) }
        .onChange(of: inStock) { _, _ in search(now: true) }
        .onAppear { if autofocus { focused = true } }
    }

    // MARK: Rows

    private var generics: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Generic").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 4)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                ForEach(PlaceablePart.allCases) { p in
                    let part = PartToPlace.generic(p)
                    Button { doc.choose(part, module: nil); close() } label: {
                        Label(part.label, systemImage: symbol(p))
                            .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity).frame(height: 40)
                            .background(.primary.opacity(0.06), in: .capsule).contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(source == .jlc
                 ? "Search JLCPCB for a real part: you get its footprint, pin names and LCSC number, ready for JLCPCB assembly. Basic parts are listed first (no loading fee)."
                 : "DigiKey parts take their footprint from the same part at JLCPCB when it's there, or from the package for common passives and ICs.")
                .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4).padding(.top, 6)
        }
    }

    private func symbol(_ p: PlaceablePart) -> String {
        switch p { case .resistor: "rectangle.portrait"; case .capacitor: "pause"; case .led: "lightbulb"; case .chip: "cpu" }
    }

    private func row(_ h: PartsCatalog.Hit) -> some View {
        Button { choose(h) } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(h.mpn).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if h.basic {
                            Text("Basic").font(.caption2.weight(.bold)).padding(.horizontal, 6).frame(height: 18)
                                .background(Theme.success.opacity(0.22), in: .capsule).foregroundStyle(Color.green)
                        }
                    }
                    Text(h.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Text([h.manufacturer, h.package, h.partNumber].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 3) {
                    if preparing == h.id { ProgressView().controlSize(.small) }
                    else if let p = h.price { Text(p < 0.1 ? String(format: "$%.4f", p) : String(format: "$%.2f", p)).font(.caption.weight(.semibold).monospacedDigit()) }
                    Text(h.stock > 0 ? "\(h.stock.formatted(.number.notation(.compactName))) in stock" : "Out of stock")
                        .font(.caption2).foregroundStyle(h.stock > 0 ? Color.secondary : Color.orange)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(.primary.opacity(preparing == h.id ? 0.08 : 0.035), in: .rect(cornerRadius: 16, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(preparing != nil)
        .contextMenu {
            if let u = h.url { Link("Open on \(h.source.rawValue)", destination: u) }
            Button("Copy part number") { copy(h.partNumber) }
        }
    }

    private func errorCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(text, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.primary)
            if source == .digikey && !PartsCatalog.hasDigiKeyKey {
                Button("Open Settings", action: openSettings).font(.subheadline.weight(.semibold)).foregroundStyle(palette.accent).buttonStyle(.plain)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 16, style: .continuous))
    }

    // MARK: Actions

    private func search(now: Bool) {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { hits = []; searching = false; return }
        let src = source, stock = inStock
        searchTask = Task {
            if !now { try? await Task.sleep(for: .milliseconds(450)) }
            guard !Task.isCancelled else { return }
            searching = true
            defer { searching = false }
            do {
                let r = src == .jlc ? try await PartsCatalog.searchJLC(q, inStock: stock) : try await PartsCatalog.searchDigiKey(q, inStock: stock)
                guard !Task.isCancelled else { return }
                hits = r
                error = nil
            } catch {
                guard !Task.isCancelled, (error as? URLError)?.code != .cancelled else { return }
                hits = []
                self.error = error.localizedDescription
            }
        }
    }

    private func choose(_ h: PartsCatalog.Hit) {
        preparing = h.id
        error = nil
        Task {
            defer { preparing = nil }
            do {
                let (part, module) = try await PartsCatalog.prepare(h)
                doc.choose(part, module: module)
                close()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func copy(_ s: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
        #else
        UIPasteboard.general.string = s
        #endif
    }
}
