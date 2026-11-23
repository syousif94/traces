import SwiftUI

struct TraceworksApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                #if os(macOS)
                .frame(minWidth: 1100, minHeight: 680)
                #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1600, height: 1000)
        .commands { TraceworksCommands() }
        #endif
    }
}

struct RootView: View {
    @State private var store = ProjectStore()
    @State private var doc: DocumentModel?
    @State private var error: String?

    var body: some View {
        ZStack {
            EngineHostView()
            if let doc {
                workspace(doc).id(doc.url)
            } else {
                StartView(store: store) { url, scoped, prompt in openProject(url, scoped: scoped, prompt: prompt) }
            }
        }
        .alert("Couldn't open project", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {} message: { Text(error ?? "") }
        .task {
            #if os(macOS)
            if AppSettings.shared.mcpEnabled { MCPServer.shared.start() }
            #endif
            // UI-test / demo hook: open a project folder given on the command line.
            if let i = CommandLine.arguments.firstIndex(of: "-open"), i + 1 < CommandLine.arguments.count {
                openProject(URL(fileURLWithPath: CommandLine.arguments[i + 1]), scoped: false)
            } else if CommandLine.arguments.contains("-openFirst"), let first = store.items.first {
                openProject(first.url, scoped: false)
            } else if CommandLine.arguments.contains("-newFromTemplate"), let t = store.templates().first {
                if let u = try? store.create(from: t, name: "esp32-s3-devboard") { openProject(u, scoped: false) }
            }
        }
    }

    /// The same Nurby-style studio on Mac, iPad and iPhone; it adapts to the window's shape.
    private func workspace(_ doc: DocumentModel) -> some View {
        StudioWorkspace(doc: doc, onClose: close)
    }

    private func openProject(_ url: URL, scoped: Bool, prompt: String? = nil) {
        do {
            let d = try DocumentModel(url: url, securityScoped: scoped)
            doc = d
            if let prompt, !prompt.isEmpty { d.agent.send(prompt) }
        } catch { self.error = error.localizedDescription }
    }

    private func close() {
        doc?.close()
        doc = nil
        store.reload()
    }
}

#if os(macOS)
struct TraceworksCommands: Commands {
    @FocusedValue(\.document) private var doc
    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            // Text fields keep their own undo; elsewhere ⌘Z undoes board edits.
            Button("Undo") {
                if NSApp.keyWindow?.firstResponder is NSTextView { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
                else { Task { await doc?.undo() } }
            }.keyboardShortcut("z")
            Button("Redo") {
                if NSApp.keyWindow?.firstResponder is NSTextView { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
                else { Task { await doc?.redo() } }
            }.keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandMenu("Board") {
            Button("Toggle Agent") { doc?.showAgentPanel.toggle() }.keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Run DRC") { Task { await doc?.runDRC(); doc?.showDRC = true } }.keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Export Fab ZIP…") { doc?.exportRequested += 1 }
            Divider()
            Button("Schematic") { doc?.viewMode = .schematic }.keyboardShortcut("1")
            Button("PCB") { doc?.viewMode = .pcb }.keyboardShortcut("2")
            Button("3D") { doc?.viewMode = .threeD }.keyboardShortcut("3")
        }
    }
}
#endif
