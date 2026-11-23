import SwiftUI

/// The full-bleed view under the floating panels. `fitInsets` is the room the panels cover; the
/// 2D views fit the board into what is left, and the code editor is padded clear of them.
struct LiveView: View {
    @Bindable var doc: DocumentModel
    var compact = false
    var fitInsets = EdgeInsets()
    var body: some View {
        switch doc.viewMode {
        case .schematic: SchematicView(doc: doc, fitInsets: fitInsets)
        case .pcb: PCBView(doc: doc, compact: compact, fitInsets: fitInsets)
        case .threeD: Board3DView(doc: doc)
        case .code:
            CodePane(doc: doc)
                .clipShape(.rect(cornerRadius: 24, style: .continuous))
                .padding(.top, fitInsets.top).padding(.leading, max(fitInsets.leading, 12))
                .padding(.trailing, max(fitInsets.trailing, 12)).padding(.bottom, max(fitInsets.bottom - 70, 12))
                .background(Palette.code.canvas)
        }
    }
}

/// Schematic / PCB / 3D / Code in one glass capsule, next to the back button.
struct ViewSwitcher: View {
    @Bindable var doc: DocumentModel
    var short = false
    var body: some View {
        HStack(spacing: 2) {
            ForEach(ViewMode.allCases) { m in
                Button { withAnimation(.snappy(duration: 0.25)) { doc.viewMode = m } } label: {
                    Text(short ? m.short : m.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, short ? 10 : 14).frame(height: 40)
                        .background(doc.viewMode == m ? Color.primary.opacity(0.1) : .clear, in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .foregroundStyle(doc.viewMode == m ? Color.primary : Color.secondary)
                .accessibilityAddTraits(doc.viewMode == m ? .isSelected : [])
            }
        }
        .padding(6)
        .glassEffect(in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View")
    }
}

/// Compile and design-rule state; tap for the list.
struct DRCPill: View {
    @Bindable var doc: DocumentModel
    var compact = false
    var body: some View {
        Button { doc.showDRC = true } label: {
            HStack(spacing: 7) {
                if doc.drcRunning || doc.compiling { ProgressView().controlSize(.small) }
                else { Circle().fill(color).frame(width: 8, height: 8) }
                if !compact || doc.drcErrors + doc.drcWarnings > 0 {
                    Text(compact ? "\(doc.drcErrors > 0 ? doc.drcErrors : doc.drcWarnings)" : label)
                        .font(.subheadline.weight(.semibold)).lineLimit(1).fixedSize()
                }
            }
            .padding(.horizontal, compact ? 14 : 16).frame(minWidth: 52).frame(height: 52)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel("Design rule check: \(doc.drcErrors) errors, \(doc.drcWarnings) warnings")
    }
    private var color: Color { !doc.compileErrors.filter { $0.type == "compile_error" }.isEmpty || doc.drcErrors > 0 ? Theme.danger : doc.drcWarnings > 0 ? Theme.warning : Theme.success }
    private var label: String {
        if doc.compiling { return "Compiling" }
        if doc.compileErrors.contains(where: { $0.type == "compile_error" }) { return "Error" }
        if doc.drcErrors > 0 { return "DRC \(doc.drcErrors)" }
        if doc.drcWarnings > 0 { return "DRC \(doc.drcWarnings)" }
        return "DRC"
    }
}

/// Icons-only glass capsule of board tools (Nurby's operations bar). Pressing shows the tool's
/// name; the active tool stays tinted. Add part opens the parts library in the sidebar.
struct ToolsBar: View {
    @Environment(\.palette) private var palette

    @Bindable var doc: DocumentModel
    var addPart: () -> Void
    var ask: (String) -> Void

    private enum Item: Identifiable {
        case tool(CanvasTool), library, agent(String, String, String), action(String, String, () -> Void)
        var id: String {
            switch self {
            case .tool(let t): t.rawValue
            case .library: "library"
            case .agent(let n, _, _): n
            case .action(let n, _, _): n
            }
        }
    }

    private var items: [Item] {
        if doc.viewMode == .schematic { return [.tool(.select), .library, .agent("Ask about the schematic", "sparkles", "")] }
        return [
            .tool(.select), .library, .tool(.route), .tool(.via), .tool(.measure),
            .agent("Autoroute", "point.3.filled.connected.trianglepath.dotted", "Route every unrouted connection, then run DRC."),
            .agent("Fix DRC", "checkmark.shield", "Fix the DRC errors."),
            .action("Fit", "arrow.up.left.and.arrow.down.right", { doc.fitRequested += 1 }),
        ]
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(items) { item in
                    switch item {
                    case .tool(let t):
                        Button { select(t) } label: { icon(t.icon, active: doc.tool == t) }
                            .buttonStyle(OpButtonStyle(name: t.label)).accessibilityLabel(t.label)
                            .accessibilityAddTraits(doc.tool == t ? .isSelected : [])
                    case .library:
                        Button(action: addPart) { icon("plus.square.on.square", active: doc.tool == .place) }
                            .buttonStyle(OpButtonStyle(name: "Add part")).accessibilityLabel("Add part")
                    case .agent(let name, let symbol, let prompt):
                        Button { ask(prompt) } label: { icon(symbol, active: false) }
                            .buttonStyle(OpButtonStyle(name: name)).accessibilityLabel(name)
                    case .action(let name, let symbol, let run):
                        Button(action: run) { icon(symbol, active: false) }
                            .buttonStyle(OpButtonStyle(name: name)).accessibilityLabel(name)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .scrollClipDisabled()
        .frame(maxWidth: CGFloat(items.count) * 44 + 16)
        .frame(height: 56)
        // Clip the icons to the capsule, but leave room above it for a pressed button's name.
        .mask {
            VStack(spacing: 0) {
                Rectangle().frame(height: 60)
                Capsule()
            }
            .padding(.top, -60)
        }
        .glassEffect(in: .capsule)
    }

    private func select(_ t: CanvasTool) {
        doc.tool = t; doc.measureA = nil; doc.measureB = nil; doc.routeFrom = nil
    }

    private func icon(_ symbol: String, active: Bool) -> some View {
        Image(systemName: symbol).font(.system(size: 19)).frame(width: 42, height: 44)
            .foregroundStyle(active ? palette.accent : Color.primary)
            .background(active ? palette.accent.opacity(0.15) : .clear, in: .rect(cornerRadius: 19))
            .contentShape(.rect)
    }
}

/// While the Place tool holds a part: what it is, place it in the middle, or stop.
struct PlacingChip: View {
    @Environment(\.palette) private var palette

    @Bindable var doc: DocumentModel
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.tap").foregroundStyle(palette.accent)
            VStack(alignment: .leading, spacing: 0) {
                Text(doc.placePart.label).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("Tap the board to place").font(.caption).foregroundStyle(.secondary)
            }
            Button("Centre") { Task { await doc.placeAtCentre() } }
                .font(.subheadline.weight(.semibold)).buttonStyle(.plain).foregroundStyle(palette.accent)
            Button { doc.tool = .select } label: { HeaderIcon(symbol: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("Stop placing")
        }
        .padding(.leading, 16).padding(.trailing, 8).frame(height: 52)
        .glassEffect(in: .capsule)
    }
}

/// A tool button in a bar: pressing it tints it and shows its name in a glass pill above it.
struct OpButtonStyle: ButtonStyle {
    let name: String
    func makeBody(configuration: Configuration) -> some View { OpButtonBody(configuration: configuration, name: name) }

    private struct OpButtonBody: View {
        let configuration: Configuration
        let name: String
        @Environment(\.isEnabled) private var enabled
        @Environment(\.palette) private var palette
        var body: some View {
            configuration.label
                .opacity(enabled ? 1 : 0.35)
                .background(configuration.isPressed ? palette.accent.opacity(0.15) : .clear, in: .rect(cornerRadius: 19))
                .overlay(alignment: .top) {
                    if configuration.isPressed {
                        Text(name).font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .glassEffect(in: .capsule)
                            .fixedSize()
                            .offset(y: -50)
                    }
                }
                #if os(macOS)
                .help(name)
                #endif
        }
    }
}

/// Banner + DRC sheet + export flow, shared by all layouts.
struct WorkspaceChrome: ViewModifier {
    @Bindable var doc: DocumentModel
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let b = doc.banner { BannerView(banner: b).padding(.top, 76).onTapGesture { doc.banner = nil } }
            }
            .animation(.snappy, value: doc.banner)
            .sheet(isPresented: $doc.showDRC) { DRCSheet(doc: doc) }
            .exportFlow(doc)
            .focusedSceneValue(\.document, doc)
    }
}

extension FocusedValues {
    @Entry var document: DocumentModel?
}

extension View {
    func workspaceChrome(_ doc: DocumentModel) -> some View { modifier(WorkspaceChrome(doc: doc)) }
}
