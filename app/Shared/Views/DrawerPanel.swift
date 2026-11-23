import SwiftUI

enum DrawerTab: String, CaseIterable { case parts = "Parts", layers = "Layers", files = "Files", history = "History" }

/// The editor half of the sidebar (Nurby's drawer): project menu with branch and save state,
/// undo / redo, hide, then the parts on the board, layers, files and history. It draws no glass of
/// its own: the studio holds it (or the parts library) in one panel.
struct DrawerPanel: View {
    @Environment(\.palette) private var palette

    @Bindable var doc: DocumentModel
    @Binding var tab: DrawerTab
    var hide: () -> Void
    var hideSymbol = "sidebar.right"
    var addPart: () -> Void
    var openSettings: () -> Void
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                header
                Picker("Section", selection: $tab) {
                    ForEach(DrawerTab.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding([.horizontal, .top], 12)

            ScrollView {
                Group {
                    switch tab {
                    case .parts: parts
                    case .layers: LayersList(doc: doc)
                    case .files: FilesList(doc: doc) { doc.viewMode = .code }
                    case .history: HistoryList(doc: doc)
                    }
                }
                .padding(12)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Export fab ZIP…", systemImage: "square.and.arrow.up") { doc.exportRequested += 1 }
                Button("Run DRC", systemImage: "checkmark.shield") { Task { await doc.runDRC(); doc.showDRC = true } }
                Divider()
                #if os(macOS)
                Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([doc.url]) }
                #endif
                Button("Settings", systemImage: "gearshape") { openSettings() }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(doc.name).font(.headline).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(Color.primary)
                    HStack(spacing: 6) {
                        Label(doc.branch, systemImage: "arrow.triangle.branch")
                            .labelStyle(.titleAndIcon).font(.caption2.weight(.semibold)).lineLimit(1)
                            .padding(.horizontal, 6).frame(height: 18)
                            .background(palette.accent.opacity(0.14), in: .rect(cornerRadius: 7, style: .continuous))
                            .foregroundStyle(palette.accent)
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                        Text(statusText)
                    }
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                // Clear of the panel's rounded corner.
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .menuStyle(.button).buttonStyle(.plain)
            .accessibilityLabel("Project menu")

            HStack(spacing: 0) {
                Button { Task { await doc.undo() } } label: { Image(systemName: "arrow.uturn.backward").frame(width: 36, height: 34) }
                    .disabled(doc.undoStack.isEmpty).accessibilityLabel("Undo")
                Divider().frame(height: 16)
                Button { Task { await doc.redo() } } label: { Image(systemName: "arrow.uturn.forward").frame(width: 36, height: 34) }
                    .disabled(doc.redoStack.isEmpty).accessibilityLabel("Redo")
            }
            .buttonStyle(.plain)
            .font(.system(size: 15, weight: .medium))
            .background(.primary.opacity(0.07), in: .capsule)
            Button(action: hide) { HeaderIcon(symbol: hideSymbol) }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide panels")
        }
    }

    private var statusColor: Color {
        if doc.compiling { return .yellow }
        if doc.compileErrors.contains(where: { $0.type == "compile_error" }) { return .red }
        return doc.uncommitted.isEmpty ? .green : .orange
    }

    private var statusText: String {
        if doc.compiling { return "Compiling…" }
        if doc.compileErrors.contains(where: { $0.type == "compile_error" }) { return "Doesn't compile" }
        if doc.pendingChange != nil { return "Agent change to review" }
        return doc.uncommitted.isEmpty ? "Committed" : "Not committed"
    }

    @ViewBuilder private var parts: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: addPart) {
                Label("Add a part", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity).frame(height: 40)
                    .background(palette.accent.opacity(0.12), in: .capsule)
                    .foregroundStyle(palette.accent)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            if doc.circuit.components.count > 8 {
                TextField("Filter", text: $filter)
                    .textFieldStyle(.plain).padding(.horizontal, 12).frame(height: 36)
                    .background(.primary.opacity(0.06), in: .capsule)
            }
            ComponentsList(doc: doc, filter: filter)
            VariablesCard(doc: doc)
        }
    }
}
