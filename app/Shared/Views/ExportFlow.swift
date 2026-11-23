import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Export a fab ZIP. Blocked while DRC has errors; warnings need a confirm.
struct ExportFlow: ViewModifier {
    @Bindable var doc: DocumentModel
    @State private var confirmWarnings = false
    @State private var shareURL: URL?

    func body(content: Content) -> some View {
        content
            .onChange(of: doc.exportRequested) { _, _ in Task { await begin() } }
            .confirmationDialog("DRC has \(doc.drcWarnings) warning\(doc.drcWarnings == 1 ? "" : "s"). Export anyway?", isPresented: $confirmWarnings, titleVisibility: .visible) {
                Button("Export") { Task { await export() } }
                Button("Review warnings") { doc.showDRC = true }
            }
            #if os(iOS)
            .sheet(item: Binding(get: { shareURL.map(IdentURL.init) }, set: { shareURL = $0?.url })) { u in
                ShareSheet(items: [u.url]).presentationDetents([.medium, .large])
            }
            #endif
    }

    private func begin() async {
        await doc.runDRC()
        if doc.drcErrors > 0 { doc.show(DocumentModel.ExportError.drcErrors(doc.drcErrors)); doc.showDRC = true; return }
        if doc.drcWarnings > 0 { confirmWarnings = true; return }
        await export()
    }

    private func export() async {
        do {
            let url = try await doc.buildFabZip(allowWarnings: true)
            #if os(macOS)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = url.lastPathComponent
            panel.allowedContentTypes = [.zip]
            if panel.runModal() == .OK, let dest = panel.url {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: url, to: dest)
                doc.show("Exported \(dest.lastPathComponent)", isError: false)
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            }
            #else
            shareURL = url
            #endif
        } catch { doc.show(error) }
    }
}

struct IdentURL: Identifiable { let url: URL; var id: String { url.path } }

#if os(iOS)
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
#endif

extension View {
    func exportFlow(_ doc: DocumentModel) -> some View { modifier(ExportFlow(doc: doc)) }
}
