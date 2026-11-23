import SwiftUI
import UniformTypeIdentifiers

/// Traces' home, laid out like Nurby's: describe a board to start one with the agent, start
/// from a template, open a folder, or pick up a recent project (each with a 3D picture of its board).
struct StartView: View {
    @Environment(\.palette) private var palette

    @Bindable var store: ProjectStore
    /// Open a project folder (security-scoped?), optionally sending the agent a first request.
    var open: (URL, Bool, String?) -> Void
    @State private var importing = false
    @State private var newName = ""
    @State private var naming: URL?
    @State private var showSettings = false
    @State private var error: String?
    @State private var prompt = ""
    @State private var thumbs = 0
    @State private var forgetting: ProjectStore.Item?
    @FocusState private var promptFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 280), spacing: 16)]

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    promptCard
                    actions
                    recents
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                #if os(macOS)
                .padding(.top, 20)
                #endif
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { r in
            switch r {
            case .success(let url):
                let scoped = url.startAccessingSecurityScopedResource()
                store.remember(url)
                open(url, scoped, nil)
            case .failure(let e): error = e.localizedDescription
            }
        }
        .alert("New project", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $newName)
            Button("Create") {
                guard let t = naming else { return }
                do { open(try store.create(from: t, name: newName), false, nil) } catch { self.error = error.localizedDescription }
                naming = nil
            }
            Button("Cancel", role: .cancel) { naming = nil }
        }
        .confirmationDialog("Remove \(forgetting?.name ?? "") from the list?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }), titleVisibility: .visible) {
            Button("Remove from list") { if let f = forgetting { store.forget(f) }; forgetting = nil }
        } message: { Text("The folder itself stays where it is.") }
        .alert("Couldn't open", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {} message: { Text(error ?? "") }
        .sheet(isPresented: $showSettings) { SettingsView(doc: nil) }
        .onAppear { store.reload() }
        .task(id: store.items.map(\.id)) {
            await Thumbnails.fillMissing(store.items.map(\.url)) { thumbs += 1 }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Traces").font(.largeTitle.weight(.bold))
                Text("Circuit boards you can talk to").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape").font(.title3).frame(width: 44, height: 44).contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Settings")
        }
    }

    private var hasKey: Bool { !AppSettings.shared.anthropicKey.isEmpty }

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Start with the agent", systemImage: "sparkles").font(.headline).foregroundStyle(palette.accent)
            TextField("Describe a board — “an ESP32-S3 dev board with USB-C, a 3.3 V regulator and two status LEDs”", text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...5)
                .focused($promptFocused)
                .onSubmit(startWithPrompt)
            HStack {
                if !hasKey {
                    Button("Add a key") { showSettings = true }.font(.footnote).buttonStyle(.plain).foregroundStyle(palette.accent)
                } else {
                    Text(AppSettings.shared.anthropicModel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button(action: startWithPrompt) {
                    Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 34, height: 34).background(prompt.isEmpty ? Color.gray : palette.accent, in: .circle)
                }
                .buttonStyle(.plain)
                .disabled(prompt.isEmpty)
                .accessibilityLabel("Start board")
            }
        }
        .padding(16)
        .glassEffect(in: .rect(cornerRadius: 26))
    }

    /// Scrolls sideways when the buttons don't fit, running to the screen edges.
    private var actions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                let templates = store.templates()
                if templates.count == 1, let t = templates.first {
                    actionButton("New board", "plus") { newName = t.lastPathComponent; naming = t }
                } else {
                    Menu {
                        ForEach(templates, id: \.self) { t in Button(t.lastPathComponent) { newName = t.lastPathComponent; naming = t } }
                    } label: { actionLabel("New board", "plus") }
                    .menuStyle(.button).buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
                actionButton("Open folder", "square.and.arrow.down") { importing = true }
                if let last = store.items.first {
                    actionButton("Continue \(last.name)", "arrow.uturn.right") { open(last.url, last.external, nil) }
                }
            }
            .padding(.vertical, 8)
        }
        .contentMargins(.horizontal, 24, for: .scrollContent)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .padding(.horizontal, -24)
        .padding(.vertical, -8)
    }

    private func actionLabel(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)).lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 16).frame(height: 44)
            .contentShape(.capsule)
    }

    private func actionButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { actionLabel(title, symbol) }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent boards").font(.title3.weight(.semibold))
            if store.items.isEmpty {
                Text("Your boards appear here. Each is a plain tscircuit folder with its own git history, in the Files app under Traces (on the Mac, Documents › Traces).")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(store.items) { p in
                    Button { open(p.url, p.external, nil) } label: { ProjectCard(item: p, revision: thumbs) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Open", systemImage: "arrow.up.forward.app") { open(p.url, p.external, nil) }
                            #if os(macOS)
                            Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([p.url]) }
                            #endif
                            if p.external { Button("Remove from list", systemImage: "minus.circle") { forgetting = p } }
                        }
                }
            }
        }
    }

    /// A new board from the first template, with the description as the agent's first request.
    private func startWithPrompt() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard hasKey else { showSettings = true; return }
        guard let t = store.templates().first else { error = "No project template in the app bundle."; return }
        let name = text.split(separator: " ").prefix(4).joined(separator: "-").lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        do {
            let url = try store.create(from: t, name: name.isEmpty ? "board" : name)
            prompt = ""
            open(url, false, text)
        } catch { self.error = error.localizedDescription }
    }
}

/// A recent board: its 3D picture, name and when it last changed.
private struct ProjectCard: View {
    let item: ProjectStore.Item
    /// Changes when new pictures have been drawn.
    var revision: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background.opacity(scheme == .dark ? 0.25 : 0.6))
                if let img = Thumbnails.image(for: item.url) {
                    img.resizable().scaledToFit().padding(8)
                } else {
                    Image(systemName: "cpu").font(.system(size: 36, weight: .light)).foregroundStyle(.tertiary)
                }
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .id(revision)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Group {
                    if item.external { Text(item.url.deletingLastPathComponent().path).truncationMode(.middle) }
                    else { Text(item.modified, format: .relative(presentation: .named)) }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
        .padding(8)
        .glassEffect(in: .rect(cornerRadius: 24))
        .contentShape(.rect)
    }
}
