import SwiftUI

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased()).font(.system(size: 12, weight: .semibold)).tracking(0.8).foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 6)
    }
}

struct RowBackground: View {
    var selected: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous).fill(selected ? Color.primary.opacity(0.07) : .clear)
    }
}

struct FilesList: View {
    @Bindable var doc: DocumentModel
    var onOpen: () -> Void = {}
    var body: some View {
        VStack(spacing: 2) {
            ForEach(doc.files, id: \.path) { f in
                Button { doc.open(f.path); onOpen() } label: {
                    HStack {
                        Text(f.path).lineLimit(1)
                        Spacer()
                        if f.agentModified { Text("A").foregroundStyle(Theme.success).accessibilityLabel("changed by agent") }
                        else if doc.uncommitted.contains(f.path) { Text("M").foregroundStyle(Theme.warning).accessibilityLabel("modified") }
                    }
                    .font(.system(size: 15))
                    .padding(.horizontal, 12).frame(minHeight: 36)
                    .background(RowBackground(selected: f.path == doc.openFile && doc.viewMode == .code))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ComponentsList: View {
    @Environment(\.palette) private var palette

    @Bindable var doc: DocumentModel
    var filter = ""
    var body: some View {
        VStack(spacing: 2) {
            let comps = doc.circuit.components.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) || $0.displayPart.localizedCaseInsensitiveContains(filter) }
            if comps.isEmpty {
                Text(doc.circuit.isEmpty ? "Compiling…" : "No matches").foregroundStyle(Theme.muted).font(.callout).padding(12)
            }
            ForEach(comps) { c in
                Button { doc.select(c.name, reveal: true) } label: {
                    HStack {
                        Text(c.name).foregroundStyle(c.name == doc.selection ? palette.accent : Theme.text)
                        Spacer(minLength: 8)
                        Text(c.displayPart).foregroundStyle(c.name == doc.selection ? palette.accent : Theme.muted).lineLimit(1)
                    }
                    .font(.system(size: 15))
                    .padding(.horizontal, 12).frame(minHeight: 38)
                    .background(RowBackground(selected: c.name == doc.selection))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct HistoryList: View {
    @Environment(\.palette) private var palette

    @Bindable var doc: DocumentModel
    @State private var detail: CommitInfo?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let change = doc.pendingChange {
                row(title: "Agent: \(doc.agent.lastRequest.isEmpty ? change.branch : doc.agent.lastRequest)", sub: "uncommitted · \(change.files.count) file\(change.files.count == 1 ? "" : "s")", dot: palette.accent)
            }
            if !doc.uncommitted.isEmpty {
                row(title: "Local edits", sub: "uncommitted · \(doc.uncommitted.count) file\(doc.uncommitted.count == 1 ? "" : "s")", dot: Theme.warning)
            }
            ForEach(doc.history, id: \.id) { c in
                Button { detail = c } label: {
                    row(title: c.summary, sub: "main · \(relative(c.time))", dot: Theme.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(item: $detail) { c in CommitDetail(doc: doc, commit: c) }
    }

    private func row(title: String, sub: String, dot: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(dot).frame(width: 8, height: 8).padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14)).foregroundStyle(Theme.text).lineLimit(2)
                Text(sub).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func relative(_ t: Int64) -> String {
        { let d = Date(timeIntervalSince1970: TimeInterval(t)); return Date().timeIntervalSince(d) < 60 ? "just now" : RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date()) }()
    }
}

extension CommitInfo: Identifiable {}

struct CommitDetail: View {
    @Bindable var doc: DocumentModel
    let commit: CommitInfo
    @Environment(\.dismiss) private var dismiss
    @State private var diffs: [FileDiff] = []
    @State private var branchName = ""
    @State private var confirmRestoreAll = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(commit.summary).font(.headline)
                    Text("\(commit.short) · \(Date(timeIntervalSince1970: TimeInterval(commit.time)).formatted())").font(Theme.mono(12)).foregroundStyle(Theme.muted)
                    HStack {
                        TextField("new-branch-name", text: $branchName).textFieldStyle(.roundedBorder).font(Theme.mono(13))
                        Button("Create branch") { doc.branch(from: commit, name: branchName) }.disabled(branchName.isEmpty)
                    }
                    ForEach(diffs, id: \.path) { f in
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Text(f.path).font(Theme.mono(13, .semibold))
                                Spacer()
                                Button("Restore this file") { Task { await doc.restore(commit: commit, path: f.path); dismiss() } }.font(.callout)
                            }
                            .padding(10).background(Theme.surfaceRaised)
                            HunkView(diff: f)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .padding(20)
            }
            .background(Theme.canvas)
            .navigationTitle("Commit")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Restore board") { confirmRestoreAll = true } }
            }
            .confirmationDialog("Restore the whole board to \(commit.short)? This makes a new commit on main.", isPresented: $confirmRestoreAll) {
                Button("Restore board") { Task { await doc.restore(commit: commit, path: nil); dismiss() } }
            }
        }
        .frame(minWidth: 560, minHeight: 460)
        .task { diffs = (try? doc.project.commitDiff(id: commit.id)) ?? [] }
    }
}

struct LayersList: View {
    @Bindable var doc: DocumentModel
    var body: some View {
        VStack(spacing: 2) {
            ForEach(PCBLayer.allCases) { l in
                HStack(spacing: 10) {
                    Circle().fill(l.color).frame(width: 10, height: 10)
                    Text(l.rawValue).font(.system(size: 15)).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    Slider(value: Binding(get: { doc.layerOpacity[l] ?? 1 }, set: { doc.layerOpacity[l] = $0 }), in: 0.15...1).frame(width: 52)
                        .accessibilityLabel("\(l.rawValue) opacity")
                    Button { doc.layerVisible[l] = !(doc.layerVisible[l] ?? true) } label: {
                        Image(systemName: doc.layerVisible[l] ?? true ? "eye" : "eye.slash").frame(width: 32, height: 36)
                    }
                    .buttonStyle(.plain).foregroundStyle(doc.layerVisible[l] ?? true ? Theme.text : Theme.muted)
                    .accessibilityLabel("\(doc.layerVisible[l] ?? true ? "Hide" : "Show") \(l.rawValue)")
                }
                .padding(.horizontal, 12).frame(minHeight: 40)
            }
            Picker("Snap", selection: $doc.snapStep) {
                Text("0.1 mm").tag(0.1); Text("0.5 mm").tag(0.5); Text("1 mm").tag(1.0)
            }
            .pickerStyle(.segmented).padding(12)
        }
    }
}

struct VariablesCard: View {
    @Bindable var doc: DocumentModel
    @State private var editing: String?
    @State private var text = ""
    var body: some View {
        if !doc.variables.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Variables").font(.system(size: 15, weight: .semibold))
                ForEach(doc.variables) { v in
                    HStack(spacing: 4) {
                        Text("\(v.name) =").foregroundStyle(Theme.muted)
                        if editing == v.name {
                            TextField("", text: $text).textFieldStyle(.plain).frame(width: 60)
                                .onSubmit { Task { await doc.setVariable(v.name, to: text); editing = nil } }
                        } else {
                            Button(v.value) { editing = v.name; text = v.value }.buttonStyle(.plain)
                        }
                        Text(v.unit).foregroundStyle(Theme.muted)
                    }
                    .font(Theme.mono(14))
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.canvas.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

/// Bottom inspector card (Mac) for the selected part.
struct InspectorCard: View {
    @Bindable var doc: DocumentModel
    var body: some View {
        if let s = doc.selection, let c = doc.circuit.component(named: s) {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(c.name) · \(c.displayPart)").font(.system(size: 16, weight: .semibold))
                Text([c.footprint, c.supplierPart.map { "LCSC \($0)" }, c.value].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 14)).foregroundStyle(Theme.muted)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 22) { coords(c) }
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                        GridRow { Text("X \(fmt(Double(c.center.x), 2)) mm"); Text("Y \(fmt(Double(c.center.y), 2)) mm") }
                        GridRow { Text("Rot \(fmt(c.rotation))°"); Text(c.layer == .top ? "Top" : "Bottom") }
                    }
                }
                .font(Theme.mono(14)).lineLimit(1).fixedSize(horizontal: false, vertical: true)
            }
            .padding(18).glassPanel(radius: 20)
        }
    }

    @ViewBuilder private func coords(_ c: CircuitModel.Component) -> some View {
        Text("X \(fmt(Double(c.center.x), 2)) mm"); Text("Y \(fmt(Double(c.center.y), 2)) mm"); Text("Rot \(fmt(c.rotation))°"); Text(c.layer == .top ? "Top" : "Bottom")
    }
}

/// Exact numeric entry next to the selection: X, Y (mm), rotation (°). Accepts expressions and
/// project variables; Enter commits, Tab moves to the next field.
struct NumberInputBar: View {
    @Environment(\.palette) private var palette

    @Bindable var doc: DocumentModel
    var vertical = false
    /// Inside another panel: no glass of its own, no title row.
    var bare = false
    @State private var x = ""
    @State private var y = ""
    @State private var r = ""
    @FocusState private var focus: Field?
    enum Field { case x, y, r }

    var body: some View {
        if let s = doc.selection, let c = doc.circuit.component(named: s) {
            let layout = vertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 10))
            layout {
                if vertical && !bare {
                    HStack {
                        Text(c.name).font(.system(size: 22, weight: .bold)).foregroundStyle(palette.accent)
                        Text(c.displayPart).foregroundStyle(Theme.muted)
                        Spacer()
                        Button { Task { await doc.nudgeRotation(s, by: 90) } } label: { Image(systemName: "rotate.right").frame(width: 44, height: 44) }
                            .buttonStyle(.plain).accessibilityLabel("Rotate 90 degrees")
                    }
                    HStack(spacing: 10) { fields }
                } else if bare {
                    HStack(spacing: 10) { fields }
                    Button { Task { await doc.nudgeRotation(s, by: 90) } } label: { Label("Rotate 90°", systemImage: "rotate.right") }
                        .font(.subheadline.weight(.semibold)).buttonStyle(.plain).foregroundStyle(palette.accent)
                } else {
                    Text(c.name).font(.system(size: 18, weight: .bold)).foregroundStyle(palette.accent)
                    fields
                    Text("mm").foregroundStyle(Theme.muted)
                }
            }
            .padding(bare ? 0 : vertical ? 18 : 12)
            .fixedSize(horizontal: !vertical, vertical: true)
            .glassEffect(bare ? .identity : .regular, in: .rect(cornerRadius: vertical ? 28 : 22))
            .onAppear { load(c) }
            .onChange(of: doc.selection) { _, _ in if let c = doc.circuit.component(named: doc.selection ?? "") { load(c) } }
            .onChange(of: doc.circuit.elementCount) { _, _ in if focus == nil, let c = doc.circuit.component(named: s) { load(c) } }
        }
    }

    @ViewBuilder private var fields: some View {
        field(vertical ? "X" : "X", $x, .x)
        field("Y", $y, .y)
        field("∠", $r, .r)
    }

    private func field(_ label: String, _ text: Binding<String>, _ f: Field) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(Theme.muted)
            TextField(label, text: text)
                .textFieldStyle(.plain).font(Theme.mono(17))
                .focused($focus, equals: f)
                .frame(minWidth: 52, maxWidth: vertical ? .infinity : 80)
                .padding(.horizontal, 12).frame(minHeight: 44)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(focus == f ? palette.accent : .clear, lineWidth: 1.5))
                .onSubmit { commit() }
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                #endif
                .accessibilityLabel(label == "∠" ? "Rotation in degrees" : "\(label) in millimetres")
        }
    }

    private func load(_ c: CircuitModel.Component) {
        x = String(format: "%.2f", c.center.x); y = String(format: "%.2f", c.center.y); r = fmt(c.rotation)
    }

    private func commit() {
        guard let s = doc.selection, let c = doc.circuit.component(named: s) else { return }
        guard let nx = doc.evaluate(x), let ny = doc.evaluate(y), let nr = doc.evaluate(r) else {
            doc.show("Couldn't read that number", isError: true); return
        }
        let rot: Double? = abs(nr - c.rotation) > 0.001 ? nr : nil
        focus = nil
        Task { await doc.move(s, to: CGPoint(x: nx, y: ny), rotation: rot) }
    }
}

struct DRCSheet: View {
    @Bindable var doc: DocumentModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if doc.violations.isEmpty { Label("No DRC issues", systemImage: "checkmark.shield").foregroundStyle(Theme.success) }
                ForEach(doc.violations) { v in
                    Button {
                        if let id = v.elementIds.first, let c = doc.circuit.component(pcbId: id) { doc.select(c.name) }
                        dismiss()
                    } label: {
                        HStack(alignment: .top) {
                            Image(systemName: v.isError ? "xmark.octagon" : "exclamationmark.triangle").foregroundStyle(v.isError ? Theme.danger : Theme.warning)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(v.message).font(.callout)
                                Text(v.type).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("DRC · \(doc.drcErrors) errors, \(doc.drcWarnings) warnings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Ask agent to fix") { doc.agent.send("Fix the DRC errors."); dismiss() }.disabled(doc.drcErrors == 0) }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}

struct BannerView: View {
    let banner: DocumentModel.Banner
    var body: some View {
        Label(banner.text, systemImage: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .font(.callout).foregroundStyle(Theme.text)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .glassPanel(radius: 16)
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(banner.isError ? Theme.warning : Theme.success, lineWidth: 1))
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}
