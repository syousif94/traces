import SwiftUI

struct AgentPanel: View {
    @Environment(\.palette) private var palette

    @Bindable var doc: DocumentModel
    var compact = false
    var onClose: (() -> Void)?
    var openSettings: (() -> Void)?
    @State private var speech = SpeechInput()
    @State private var pendingSend: Task<Void, Never>?
    @State private var showDiff = false
    private var session: AgentSession { doc.agent }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: compact ? 8 : 10) {
                        if session.items.isEmpty { emptyState }
                        if compact { compactItems } else { ForEach(session.items) { item($0) } }
                        if session.running {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Working…").foregroundStyle(Theme.muted) }
                                .font(.callout).id("running")
                        }
                        if let change = doc.pendingChange, !session.running { diffCard(change).id("diff") }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(16)
                }
                .onChange(of: session.items.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: doc.pendingChange?.added) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            input
        }
        .sheet(isPresented: $showDiff) { ReviewDiffSheet(doc: doc) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Agent").font(.headline)
            Spacer()
            Menu {
                Picker("Model", selection: Binding(get: { session.provider }, set: { session.setProvider($0) })) {
                    Text("Claude (Anthropic API)").tag("anthropic")
                    Text("OpenAI-compatible (LM Studio)").tag("openai")
                }
                Button("New thread", systemImage: "square.and.pencil") { session.newThread() }
            } label: {
                Text(session.modelLabel).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(.primary.opacity(0.07), in: .capsule)
            }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()
            if let openSettings {
                Button(action: openSettings) { HeaderIcon(symbol: "gearshape") }.buttonStyle(.plain).accessibilityLabel("Settings")
            }
            if let onClose {
                Button(action: onClose) { HeaderIcon(symbol: "xmark") }.buttonStyle(.plain).accessibilityLabel("Close agent")
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
    }

    private var hasKey: Bool {
        session.provider == "openai" || !AppSettings.shared.anthropicKey.isEmpty
    }

    @ViewBuilder private var emptyState: some View {
        if !hasKey {
            VStack(spacing: 12) {
                Image(systemName: "key.horizontal.fill").font(.system(size: 30)).foregroundStyle(palette.accent)
                    .frame(width: 68, height: 68).background(palette.accent.opacity(0.14), in: .circle)
                Text("Design by describing it").font(.title3.weight(.bold))
                Text("The agent edits this board's tscircuit code with the same tools you use, on a branch you review. It runs on Claude with your Anthropic API key, or on a local OpenAI-compatible model.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if let openSettings {
                    Button(action: openSettings) {
                        Label("Add an API key", systemImage: "plus").font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 18).frame(height: 40)
                            .background(palette.accent, in: .capsule).foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Ask for a change to the board. Edits land on an agent branch you review as a diff.")
                    .font(.subheadline).foregroundStyle(.secondary)
                ForEach(["Add ESD protection on the USB data lines", "Move the LEDs to the bottom edge", "Fix the DRC errors"], id: \.self) { s in
                    Button { session.send(s) } label: {
                        Text(s).font(.subheadline).padding(.horizontal, 12).frame(minHeight: 34)
                            .background(.primary.opacity(0.06), in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private func item(_ i: AgentSession.Item) -> some View {
        switch i.kind {
        case .user:
            HStack { Spacer(minLength: 40); Text(i.text).padding(.horizontal, 16).padding(.vertical, 12)
                .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: 18, style: .continuous)).foregroundStyle(.white) }
        case .text:
            Text(.init(i.text)).foregroundStyle(Theme.text).textSelection(.enabled)
        case .error:
            Label(i.text, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning).font(.callout)
        case .tool:
            HStack {
                Text("\(i.name)\(i.args.isEmpty ? "" : " " + i.args)").lineLimit(1)
                Spacer()
                if i.running { ProgressView().controlSize(.mini) } else {
                    Text(i.chip).foregroundStyle(chipColor(i))
                }
            }
            .font(Theme.mono(13))
            .padding(.horizontal, 14).frame(minHeight: 40)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    /// iPhone: user bubble, then compact wrapped chips, then text.
    @ViewBuilder private var compactItems: some View {
        let groups = groupedItems()
        ForEach(groups.indices, id: \.self) { gi in
            let g = groups[gi]
            if g.first?.kind == .tool {
                FlowLayout(spacing: 8) {
                    ForEach(g) { t in
                        HStack(spacing: 6) {
                            Text(t.name == "edit_file" || t.name == "read_file" ? "\(t.name.replacingOccurrences(of: "_file", with: "")) \(t.args)" : t.name)
                            if t.running { ProgressView().controlSize(.mini) } else { Image(systemName: t.ok ? "checkmark" : "xmark").font(.system(size: 11, weight: .bold)) }
                        }
                        .font(Theme.mono(14)).padding(.horizontal, 12).frame(minHeight: 40)
                        .background(Color.primary.opacity(0.06), in: .capsule)
                    }
                }
            } else {
                ForEach(g) { item($0) }
            }
        }
    }

    private func groupedItems() -> [[AgentSession.Item]] {
        var out: [[AgentSession.Item]] = []
        for i in session.items {
            if i.kind == .tool, let last = out.last, last.first?.kind == .tool { out[out.count - 1].append(i) } else { out.append([i]) }
        }
        return out
    }

    private func chipColor(_ i: AgentSession.Item) -> Color {
        if !i.ok { return Theme.danger }
        if i.chip.contains("warning") { return Theme.warning }
        if i.chip.hasPrefix("+") || i.chip == "0 errors" || i.chip == "0 issues" || i.chip == "viewed" || i.chip == "done" { return Theme.success }
        if i.chip.contains("error") { return Theme.danger }
        return Theme.muted
    }

    private func diffCard(_ change: AgentChange) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(change.files.count) file\(change.files.count == 1 ? "" : "s") changed").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("+\(change.added)").foregroundStyle(Theme.success) + Text(" −\(change.removed)").foregroundStyle(Theme.danger)
            }
            .font(Theme.mono(13))
            if compact {
                ForEach(change.files.prefix(2), id: \.path) { f in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack { Text(f.path).font(Theme.mono(14, .semibold)); Spacer(); Text("+\(f.added) −\(f.removed)").font(Theme.mono(13)).foregroundStyle(Theme.muted) }
                            .padding(10).background(Theme.surfaceRaised)
                        HunkView(diff: f, maxRows: 12)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.separator.opacity(0.6)))
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { buttons(change) }
                VStack(spacing: 8) { buttons(change) }
            }
        }
        .padding(16)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    @ViewBuilder private func buttons(_ change: AgentChange) -> some View {
        Button("Accept & commit") { Task { await doc.acceptAgentChange(summary: session.lastSummary, request: session.lastRequest) } }
            .buttonStyle(PillButtonStyle(kind: .success))
            .keyboardShortcut(.return, modifiers: .command)
        if !compact { Button("Review diff") { showDiff = true }.buttonStyle(PillButtonStyle(kind: .secondary)) }
        Button("Discard") { Task { await doc.discardAgentChange() } }.buttonStyle(PillButtonStyle(kind: .secondary))
    }

    private var input: some View {
        HStack(spacing: 10) {
            TextField(speech.listening ? "Listening…" : (doc.pendingChange != nil ? "Ask for a follow-up…" : "Ask or hold to talk…"), text: Binding(get: { session.draft }, set: { session.draft = $0 }), axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...5)
                .onSubmit { session.send() }
                .disabled(session.running)
            if pendingSend != nil {
                Button("Cancel") { pendingSend?.cancel(); pendingSend = nil }.font(.callout).buttonStyle(.plain).foregroundStyle(palette.accent)
            }
            micButton
            if session.running {
                Button { session.cancel() } label: { Image(systemName: "stop.fill").frame(width: 44, height: 44) }
                    .buttonStyle(.plain).background(Color.primary.opacity(0.07), in: .circle)
                    .accessibilityLabel("Stop the agent")
            } else if !session.draft.isEmpty {
                Button { session.send() } label: { Image(systemName: "arrow.up").font(.system(size: 17, weight: .bold)).frame(width: 44, height: 44) }
                    .buttonStyle(.plain).foregroundStyle(Theme.onAccent)
                    .background(palette.accent, in: .circle)
                    .accessibilityLabel("Send")
            }
        }
        .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 6)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(12)
        .alert("Speech", isPresented: Binding(get: { speech.error != nil }, set: { if !$0 { speech.error = nil } })) {} message: { Text(speech.error ?? "") }
    }

    /// Hold to talk; the transcript shows in the input for a second before sending.
    private var micButton: some View {
        Image(systemName: speech.listening ? "waveform" : "mic")
            .font(.system(size: 17, weight: .semibold))
            .frame(width: 44, height: 44)
            .foregroundStyle(speech.listening ? Theme.onAccent : Color.primary)
            .background(speech.listening ? palette.accent : Color.primary.opacity(0.07), in: .circle)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !speech.listening { speech.start() } }
                .onEnded { _ in
                    let text = speech.finish().trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { return }
                    session.draft = text
                    pendingSend = Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        guard !Task.isCancelled else { return }
                        session.send()
                        pendingSend = nil
                    }
                })
            .onChange(of: speech.transcript) { _, t in if speech.listening { session.draft = t } }
            .accessibilityLabel("Hold to talk")
            .accessibilityAddTraits(.isButton)
    }
}

struct ReviewDiffSheet: View {
    @Bindable var doc: DocumentModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(doc.pendingChange?.files ?? [], id: \.path) { f in
                        VStack(alignment: .leading, spacing: 0) {
                            HStack { Text(f.path).font(Theme.mono(14, .semibold)); Spacer(); Text("+\(f.added) −\(f.removed)").font(Theme.mono(13)).foregroundStyle(Theme.muted) }
                                .padding(10).background(Theme.surfaceRaised)
                            HunkView(diff: f)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.separator.opacity(0.6)))
                    }
                }
                .padding(20)
            }
            .background(Theme.canvas)
            .navigationTitle(doc.branch)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Accept & commit") { Task { await doc.acceptAgentChange(summary: doc.agent.lastSummary, request: doc.agent.lastRequest); dismiss() } }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 480)
    }
}

/// Wrapping row layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, w: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > maxW, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height); w = max(w, x)
        }
        return CGSize(width: min(maxW, w), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}
