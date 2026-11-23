import SwiftUI

/// The full-bleed views under the floating bar and panels. All four stay loaded, so switching is
/// instant and cross-fades, and each keeps its own zoom. `fitInsets` is the room the bar and panels
/// cover: the 2D views fit and centre the board in what is left, the 3D view is stretched past the
/// screen edges so its centre is the middle of the open area, and the code editor is padded clear.
struct LiveView: View {
    @Bindable var doc: DocumentModel
    var compact = false
    var fitInsets = EdgeInsets()
    var body: some View {
        ZStack {
            layer(.schematic) { SchematicView(doc: doc, fitInsets: fitInsets) }
            layer(.pcb) { PCBView(doc: doc, compact: compact, fitInsets: fitInsets) }
            layer(.threeD) {
                Board3DView(doc: doc)
                    .padding(.leading, -max(fitInsets.trailing - fitInsets.leading, 0))
                    .padding(.trailing, -max(fitInsets.leading - fitInsets.trailing, 0))
                    .padding(.top, -max(fitInsets.bottom - fitInsets.top, 0))
                    .padding(.bottom, -max(fitInsets.top - fitInsets.bottom, 0))
            }
            layer(.code) {
                CodePane(doc: doc)
                    .clipShape(.rect(cornerRadius: 24, style: .continuous))
                    .padding(.top, max(fitInsets.top, 12)).padding(.leading, max(fitInsets.leading, 12))
                    .padding(.trailing, max(fitInsets.trailing, 12)).padding(.bottom, max(fitInsets.bottom, 12))
                    .background(Palette.code.canvas)
            }
        }
    }

    private func layer(_ mode: ViewMode, @ViewBuilder _ content: () -> some View) -> some View {
        let on = doc.viewMode == mode
        return content()
            .opacity(on ? 1 : 0)
            .scaleEffect(on ? 1 : 0.985)
            .allowsHitTesting(on)
            .accessibilityHidden(!on)
            .zIndex(on ? 1 : 0)
    }
}

/// The one bar of the studio, at the bottom: back, the view switcher, the view's tools, the PCB
/// layers and design-rule status, in groups with dividers. It scrolls sideways when it doesn't fit,
/// and reports the width it wants so the studio can move the panels button (`PanelsButton`) above it.
/// Dragging it up or down resizes or hides the panels (the studio does that); `blocked` is set while
/// it does, so the tool under the finger doesn't run on release. Hold a finger on it and slide to
/// read each control's name (`ToolScrub`, as in Nurby).
struct StudioBar: View {
    @Environment(\.palette) private var palette
    @Bindable var doc: DocumentModel
    var short = false
    var blocked = false
    var back: () -> Void
    var addPart: () -> Void
    var ask: (String) -> Void
    /// The width the bar's contents want, unscrolled.
    var contentWidth: (CGFloat) -> Void = { _ in }
    /// A finger is held on the bar, reading names: the studio keeps its drag off the panels.
    var scrubbing: (Bool) -> Void = { _ in }

    @State private var scrub = ToolScrub()

    private let barLayers: [PCBLayer] = [.topCopper, .bottomCopper, .silk, .ratsnest]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    item("All projects", "chevron.left", weight: .semibold, action: back)
                        .scrubItem("back", name: "All projects", in: scrub, run: back)
                    divider
                    switcher
                    if !tools.isEmpty {
                        divider
                        ForEach(tools, id: \.name) { t in
                            item(t.name, t.symbol, active: t.active, action: t.run)
                                .scrubItem("tool." + t.name, name: t.name, in: scrub, run: t.run)
                        }
                    }
                    if doc.viewMode == .pcb {
                        divider
                        ForEach(barLayers) { l in layerToggle(l) }
                    }
                    divider
                    drc
                }
                .padding(.horizontal, 6)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth($0) }
        }
        .scrollDisabled(scrub.scrubbing)
        .scrollClipDisabled()
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .frame(height: 56)
        // Clip to the capsule, but leave room above it for a pressed button's name.
        .mask {
            VStack(spacing: 0) {
                Rectangle().frame(height: 60)
                Capsule()
            }
            .padding(.top, -60)
        }
        .glassEffect(in: .capsule)
        .toolScrubber(scrub)
        .onChange(of: scrub.scrubbing) { _, on in scrubbing(on) }
    }

    /// Taps are off while the bar is dragged up or down, or scrubbed (lifting runs the tool once,
    /// through the scrubber).
    private var tapsOff: Bool { blocked || scrub.blocksTaps }

    // MARK: Groups

    private var switcher: some View {
        HStack(spacing: 2) {
            ForEach(ViewMode.allCases) { m in
                let pick = { withAnimation(.snappy(duration: 0.3)) { doc.viewMode = m } }
                Button { if !tapsOff { pick() } } label: {
                    Text(short ? m.short : m.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, short ? 10 : 13).frame(height: 40)
                        .background(doc.viewMode == m ? palette.accent.opacity(0.16) : .clear, in: .capsule)
                        .foregroundStyle(doc.viewMode == m ? palette.accent : Color.secondary)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(doc.viewMode == m ? .isSelected : [])
                .scrubItem("view." + m.rawValue, name: m.rawValue, in: scrub, run: pick)
            }
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View")
    }

    private struct Tool { let name: String; let symbol: String; var active = false; let run: () -> Void }

    private var tools: [Tool] {
        let pick = { (t: CanvasTool) in Tool(name: t.label, symbol: t.icon, active: doc.tool == t) { select(t) } }
        let fit = Tool(name: "Fit", symbol: "arrow.up.left.and.arrow.down.right") { doc.fitRequested += 1 }
        let add = Tool(name: "Add part", symbol: "plus.square.on.square", active: doc.tool == .place, run: addPart)
        switch doc.viewMode {
        case .schematic:
            return [pick(.select), add, Tool(name: "Ask about the schematic", symbol: "sparkles") { ask("") }, fit]
        case .pcb:
            return [pick(.select), add, pick(.route), pick(.via), pick(.measure),
                    Tool(name: "Autoroute", symbol: "point.3.filled.connected.trianglepath.dotted") { ask("Route every unrouted connection, then run DRC.") },
                    Tool(name: "Fix DRC", symbol: "checkmark.shield") { ask("Fix the DRC errors.") },
                    fit]
        case .threeD:
            return [Tool(name: "Ask about the board", symbol: "sparkles") { ask("") }]
        case .code:
            return [Tool(name: "Ask about the code", symbol: "sparkles") { ask("") }]
        }
    }

    private func layerToggle(_ l: PCBLayer) -> some View {
        let on = doc.layerVisible[l] ?? true
        let flip = { doc.layerVisible[l] = !(doc.layerVisible[l] ?? true) }
        return Button { if !tapsOff { flip() } } label: {
            ZStack {
                Circle().fill(l.color.opacity(on ? 1 : 0.18)).frame(width: 14, height: 14)
                Circle().strokeBorder(l.color, lineWidth: 1.5).frame(width: 14, height: 14)
            }
            .frame(width: 36, height: 44).contentShape(.rect)
        }
        .buttonStyle(OpButtonStyle(name: "\(on ? "Hide" : "Show") \(l.rawValue.lowercased())"))
        .accessibilityLabel("\(l.rawValue): \(on ? "shown" : "hidden")")
        .scrubItem("layer." + l.rawValue, name: "\(on ? "Hide" : "Show") \(l.rawValue.lowercased())", in: scrub, run: flip)
    }

    private var drc: some View {
        Button { if !tapsOff { doc.showDRC = true } } label: {
            HStack(spacing: 6) {
                if doc.drcRunning || doc.compiling { ProgressView().controlSize(.small) }
                else { Circle().fill(drcColor).frame(width: 8, height: 8) }
                Text(drcLabel).font(.subheadline.weight(.semibold)).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 10).frame(height: 44).contentShape(.rect)
        }
        .buttonStyle(OpButtonStyle(name: "Design rules"))
        .accessibilityLabel("Design rule check: \(doc.drcErrors) errors, \(doc.drcWarnings) warnings")
        .scrubItem("drc", name: "Design rules", in: scrub) { doc.showDRC = true }
    }

    private var drcColor: Color {
        !doc.compileErrors.filter { $0.type == "compile_error" }.isEmpty || doc.drcErrors > 0 ? Theme.danger : doc.drcWarnings > 0 ? Theme.warning : Theme.success
    }

    private var drcLabel: String {
        if doc.compiling { return short ? "" : "Compiling" }
        if doc.compileErrors.contains(where: { $0.type == "compile_error" }) { return "Error" }
        let n = doc.drcErrors > 0 ? doc.drcErrors : doc.drcWarnings
        return n > 0 ? (short ? "\(n)" : "DRC \(n)") : "DRC"
    }

    // MARK: Pieces

    private var divider: some View {
        Rectangle().fill(.primary.opacity(0.14)).frame(width: 1, height: 24).padding(.horizontal, 5)
    }

    private func item(_ name: String, _ symbol: String, active: Bool = false, weight: Font.Weight = .regular, action: @escaping () -> Void) -> some View {
        Button { if !tapsOff { action() } } label: {
            Image(systemName: symbol).font(.system(size: 19, weight: weight)).frame(width: 42, height: 44)
                .foregroundStyle(active ? palette.accent : Color.primary)
                .background(active ? palette.accent.opacity(0.15) : .clear, in: .rect(cornerRadius: 19))
                .contentShape(.rect)
        }
        .buttonStyle(OpButtonStyle(name: name))
        .accessibilityLabel(name)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func select(_ t: CanvasTool) {
        doc.tool = t; doc.measureA = nil; doc.measureB = nil; doc.routeFrom = nil
    }
}

/// Show or hide the panels, in its own glass circle beside the bar (above it when space is tight).
struct PanelsButton: View {
    @Environment(\.palette) private var palette
    var shown: Bool
    var symbol: String
    var blocked = false
    var action: () -> Void
    var body: some View {
        let name = shown ? "Hide panels" : "Show panels"
        Button { if !blocked { action() } } label: {
            Image(systemName: symbol).font(.system(size: 19))
                .foregroundStyle(shown ? palette.accent : Color.primary)
                .frame(width: 56, height: 56).contentShape(.circle)
        }
        .buttonStyle(OpButtonStyle(name: name))
        .glassEffect(in: .circle)
        .accessibilityLabel(name)
        .accessibilityAddTraits(shown ? .isSelected : [])
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
        /// The bar is being scrubbed: it shows the name under the finger itself.
        @Environment(\.toolScrubbing) private var scrubbing
        var body: some View {
            configuration.label
                .opacity(enabled ? 1 : 0.35)
                .background(configuration.isPressed ? palette.accent.opacity(0.15) : .clear, in: .rect(cornerRadius: 19))
                .overlay(alignment: .top) {
                    if configuration.isPressed && !scrubbing {
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

// MARK: Scrubbing a bar

extension EnvironmentValues {
    /// A finger is held on a tool bar and slides across it (`toolScrubber`).
    @Entry var toolScrubbing = false
}

/// Hold on a bar to see the name of the control under the finger, slide across to read the others
/// (a tick as each comes under the finger), lift to use the one you're on. Each control reports
/// where it is with `scrubItem`. Ported from Nurby's OperationsBar; keep the two in step.
@MainActor @Observable
final class ToolScrub {
    struct Item { var name: String; var frame: CGRect; var run: () -> Void }
    var items: [String: Item] = [:]
    /// The control under the held finger.
    var active: String?
    var scrubbing = false
    /// The bar's buttons check this: lifting a held finger runs the control once, through the bar.
    var blocksTaps: Bool { scrubbing }

    func item(at p: CGPoint) -> String? {
        // Nearest along the bar, so the gaps between controls and a finger off the edge still count.
        items.filter { $0.value.frame.insetBy(dx: -6, dy: -40).contains(p) }
            .min { abs($0.value.frame.midX - p.x) < abs($1.value.frame.midX - p.x) }?.key
    }
}

extension View {
    /// A control in a scrubbable bar: its name, where it is, and what lifting on it does.
    func scrubItem(_ id: String, name: String, in scrub: ToolScrub, run: @escaping () -> Void) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { scrub.items[id] = .init(name: name, frame: $0, run: run) }
            .onChange(of: name) { _, n in scrub.items[id]?.name = n }
            .onDisappear { scrub.items[id] = nil }
    }

    /// Hold anywhere on the bar to scrub it (see `ToolScrub`).
    func toolScrubber(_ scrub: ToolScrub) -> some View { modifier(ToolScrubber(scrub: scrub)) }
}

private struct ToolScrubber: ViewModifier {
    let scrub: ToolScrub
    @State private var bar: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .environment(\.toolScrubbing, scrub.scrubbing)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { bar = $0 }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.35)
                    .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
                    .onChanged { value in
                        guard case .second(true, let drag) = value else { return }
                        if !scrub.scrubbing {
                            scrub.scrubbing = true
                            #if os(iOS)
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            #endif
                        }
                        guard let drag else { return }
                        let id = scrub.item(at: drag.location)
                        #if os(iOS)
                        if id != scrub.active, id != nil { UISelectionFeedbackGenerator().selectionChanged() }
                        #endif
                        scrub.active = id
                    }
                    .onEnded { _ in
                        if let id = scrub.active { scrub.items[id]?.run() }
                        scrub.active = nil
                        // Still "scrubbing" for a moment, so the button the finger lifted from
                        // doesn't run a second time.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { scrub.scrubbing = false }
                    }
            )
            .overlay(alignment: .topLeading) {
                if let id = scrub.active, let item = scrub.items[id] {
                    Text(item.name).font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .glassEffect(in: .capsule)
                        .fixedSize()
                        .frame(width: 0, height: 0)   // centred on the point below
                        .offset(x: item.frame.midX - bar.minX, y: -22)
                        .allowsHitTesting(false)
                        .animation(.snappy(duration: 0.15), value: id)
                }
            }
    }
}

/// Banner + DRC sheet + export flow, shared by all layouts.
struct WorkspaceChrome: ViewModifier {
    @Bindable var doc: DocumentModel
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let b = doc.banner { BannerView(banner: b).padding(.top, 20).onTapGesture { doc.banner = nil } }
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
