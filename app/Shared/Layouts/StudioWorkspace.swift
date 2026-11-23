import SwiftUI

/// The board studio, laid out like Nurby's part studio on every device: the live view full-bleed,
/// back + the Schematic / PCB / 3D / Code switcher top left, the board tools floating at the
/// bottom, and one sidebar on the right: the drawer (parts, layers, files, history, or the parts
/// library) above the agent. Drag the gap between them to share the height; drag the gap or the
/// sidebar's left edge sideways to put it away, and pull it back from the right edge. When the
/// window is taller than wide the two panels sit side by side along the bottom instead (drag their
/// top edge to resize or put them away); on a narrow screen they page sideways, with a Selected
/// page first, so the board always stays in sight.
struct StudioWorkspace: View {
    @Bindable var doc: DocumentModel
    var onClose: () -> Void
    @State private var drawerTab: DrawerTab = .parts
    @State private var library = false
    @State private var showSettings = false
    /// The drawer's share of the sidebar's height (the agent gets the rest).
    @AppStorage("sidebarSplit") private var split = 0.5
    @State private var splitStart: Double?
    /// Live sideways drag of the sidebar (points, + = towards the right edge).
    @State private var slide: CGFloat = 0
    @State private var gapAxis: Axis?
    @State private var screen: CGSize = .zero
    /// The size that decides side or bottom panels (ignores the keyboard shortening the screen).
    @State private var layoutSize: CGSize = .zero
    @AppStorage("dockSplit") private var dockShare = 0.42
    @State private var dockStart: Double?
    @State private var dockDrag: CGFloat = 0
    @State private var insets = EdgeInsets()
    /// Which bottom panel is in view when they page sideways (0 selected, 1 drawer, 2 agent).
    @State private var dockPage: Int? = 1
    @State private var keyboardUp = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSize
    private var compact: Bool { hSize == .compact }
    #else
    private let compact = false
    #endif

    private var showSidebar: Bool {
        get { doc.showAgentPanel }
        nonmutating set { doc.showAgentPanel = newValue }
    }

    private let sidebarWidth: CGFloat = 380
    private let margin: CGFloat = 12
    private let gap: CGFloat = 12
    private let toolsBand: CGFloat = 70
    private let dockPanelMax: CGFloat = 440
    private let dockPanelMin: CGFloat = 300
    #if os(macOS)
    /// Room for the window's traffic lights above the back button.
    private let topInset: CGFloat = 30
    #else
    private let topInset: CGFloat = 0
    #endif

    private var narrow: Bool { compact || (screen.width > 0 && screen.width < 700) }
    private var docked: Bool { layoutSize.height > layoutSize.width }
    private var typingDocked: Bool { docked && keyboardUp }
    private var dockPaged: Bool { screen.width - margin * 2 < dockPanelMin * 2 + gap }
    private var dockPanelWidth: CGFloat { max(min(screen.width - (gap + 24) * 2, dockPanelMax), 200) }
    private var dockHeight: CGFloat { (screen.height * dockShare).rounded() }
    private var dockOff: CGFloat { dockHeight + margin * 2 + insets.bottom + 16 }
    private var dockOffset: CGFloat { min(max((showSidebar ? 0 : dockOff) + dockDrag, 0), dockOff) }
    private var dockVisible: CGFloat { docked ? max(dockHeight + margin - dockOffset, 0) : 0 }
    private var sidebarOff: CGFloat { sidebarWidth + margin * 2 + insets.trailing + 16 }
    private var sidebarOffset: CGFloat { min(max((showSidebar ? 0 : sidebarOff) + slide, 0), sidebarOff) }
    private var sidebarAway: Bool { docked ? dockOffset > 0 : sidebarOffset > 0 }
    /// Width the side sidebar covers (0 when docked or put away).
    private var sideCover: CGFloat { docked ? 0 : max(sidebarWidth + margin * 2 - sidebarOffset, 0) }
    private var showsTools: Bool { doc.viewMode == .pcb || doc.viewMode == .schematic }

    private var palette: Palette { .for(doc.viewMode) }

    var body: some View {
        ZStack {
            palette.canvas.ignoresSafeArea()
            LiveView(doc: doc, compact: narrow, fitInsets: fitInsets)
                .ignoresSafeArea()

            tools
            topOverlay

            if docked { dock } else { side }
        }
        .environment(\.palette, palette)
        .environment(\.colorScheme, palette.scheme)
        .tint(palette.accent)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            screen = size
            if size.width != layoutSize.width || size.height >= layoutSize.height {
                layoutSize = size
            } else {
                // Only shorter: the keyboard, unless it is still down a moment later.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if !keyboardUp && screen.height < layoutSize.height { layoutSize = screen }
                }
            }
        }
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { insets = $0 }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
        .statusBarHidden(true)
        #endif
        .workspaceChrome(doc)
        .sheet(isPresented: $showSettings) { SettingsView(doc: doc) }
        #if os(macOS)
        .onAppear { MCPServer.shared.document = doc }
        #endif
    }

    /// What the floating panels cover, for fitting the board into the rest.
    private var fitInsets: EdgeInsets {
        EdgeInsets(top: 76 + topInset, leading: 0,
                   bottom: docked ? dockVisible + toolsBand + margin : (showsTools ? 84 : margin),
                   trailing: sideCover)
    }

    // MARK: Top

    /// Back and the view switcher top left; DRC top right of the open area; the selected part
    /// under them.
    private var topOverlay: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    backButton
                    ViewSwitcher(doc: doc, short: narrow)
                    Spacer(minLength: 0)
                    DRCPill(doc: doc, compact: narrow)
                }
                if doc.viewMode == .pcb, doc.selection != nil, !(docked && dockPaged && dockOffset == 0) {
                    NumberInputBar(doc: doc, vertical: true)
                        .frame(width: 350, alignment: .leading)
                        .transition(.scale(scale: 0.92, anchor: .topLeading).combined(with: .opacity))
                }
                Spacer(minLength: 0)
            }
            .padding(margin)
            .padding(.top, topInset)
            .frame(maxWidth: .infinity)
            if !docked { Color.clear.frame(width: sideCover).allowsHitTesting(false) }
        }
        .animation(.snappy(duration: 0.25), value: doc.selection)
    }

    private var backButton: some View {
        Button(action: onClose) {
            Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold))
                .frame(width: 52, height: 52).contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("All projects")
        .help("All projects")
    }

    // MARK: Tools

    private var tools: some View {
        HStack(spacing: 0) {
            VStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 10) {
                    if doc.tool == .place && doc.viewMode == .pcb { PlacingChip(doc: doc).frame(maxWidth: .infinity) }
                    if narrow && sidebarAway { sidebarButton }
                    HStack(spacing: 10) {
                        if showsTools { ToolsBar(doc: doc, addPart: openLibrary, ask: ask) }
                        if !narrow && sidebarAway { sidebarButton }
                    }
                    .frame(maxWidth: .infinity, alignment: showsTools ? .center : .trailing)
                }
                .padding(.horizontal, margin)
                .padding(.bottom, 14 + dockVisible)
                .opacity(typingDocked ? 0 : 1)
                .allowsHitTesting(!typingDocked)
                .animation(.easeOut(duration: 0.2), value: typingDocked)
            }
            .frame(maxWidth: .infinity)
            if !docked { Color.clear.frame(width: sideCover).allowsHitTesting(false) }
        }
    }

    private var sidebarButton: some View {
        Button { reveal() } label: {
            Image(systemName: docked ? "rectangle.bottomhalf.inset.filled" : "sidebar.right").font(.system(size: 18))
                .frame(width: 52, height: 52).contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Show sidebar")
    }

    // MARK: Panels

    private var editor: some View {
        ZStack(alignment: .top) {
            if library {
                PartsLibraryPanel(doc: doc, close: closeLibrary, openSettings: { showSettings = true }, autofocus: !docked)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                DrawerPanel(doc: doc, tab: $drawerTab, hide: hide,
                            hideSymbol: docked ? "rectangle.bottomhalf.inset.filled" : "sidebar.right",
                            addPart: openLibrary, openSettings: { showSettings = true })
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipShape(.rect(cornerRadius: Theme.panelRadius, style: .continuous))
        .glassEffect(in: .rect(cornerRadius: Theme.panelRadius))
    }

    private var agentPanel: some View {
        AgentPanel(doc: doc, compact: narrow, openSettings: { showSettings = true })
            .clipShape(.rect(cornerRadius: Theme.panelRadius, style: .continuous))
            .glassEffect(in: .rect(cornerRadius: Theme.panelRadius))
    }

    /// Drawer above, agent below, with the gap between them as the (invisible) divider.
    private var side: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            GeometryReader { geo in
                let total = max(geo.size.height - gap, 1)
                let top = min(max(total * split, 140), max(total - 180, 140))
                VStack(spacing: 0) {
                    editor.frame(height: top)
                    Color.clear
                        .frame(height: gap)
                        .contentShape(.rect.inset(by: -6))
                        .gesture(gapDrag(total: total))
                        .accessibilityLabel("Resize")
                    agentPanel.frame(maxHeight: .infinity)
                }
            }
            .frame(width: sidebarWidth)
            .overlay(alignment: .leading) { slideHandle.offset(x: -margin - 6) }
            .padding(margin)
            .padding(.top, topInset)
            .offset(x: sidebarOffset)
        }
        .overlay(alignment: .trailing) {
            if sidebarOffset > 0 { slideHandle }   // pull it back from the right edge
        }
    }

    /// Drawer and agent side by side along the bottom, under the tools.
    private var dock: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Group {
                if dockPaged {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: gap) {
                            selectedCard.frame(width: dockPanelWidth, height: dockHeight).id(0)
                            editor.frame(width: dockPanelWidth, height: dockHeight).id(1)
                            agentPanel.frame(width: dockPanelWidth, height: dockHeight).id(2)
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .scrollPosition(id: $dockPage)
                    .defaultScrollAnchor(.center)
                    .contentMargins(.horizontal, (screen.width - dockPanelWidth) / 2, for: .scrollContent)
                    .scrollClipDisabled()
                    .padding(.horizontal, -margin)
                } else {
                    HStack(spacing: gap) {
                        editor.frame(maxWidth: .infinity).frame(height: dockHeight)
                        agentPanel.frame(maxWidth: .infinity).frame(height: dockHeight)
                    }
                }
            }
            .frame(height: dockHeight)
            .overlay(alignment: .top) { dockHandle.offset(y: -13) }
            .padding(margin)
            .offset(y: dockOffset)
        }
        .overlay(alignment: .bottom) {
            if dockOffset > 0 { dockHandle }   // pull them back up from the bottom edge
        }
    }

    /// On a narrow screen, the first page: the selected part with its exact position.
    private var selectedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Selected").font(.headline)
                Spacer(minLength: 8)
                if doc.selection != nil {
                    Button("Clear") { doc.select(nil) }.font(.subheadline.weight(.medium)).foregroundStyle(palette.accent).buttonStyle(.plain)
                }
            }
            .frame(minHeight: 36)
            if let s = doc.selection, let c = doc.circuit.component(named: s) {
                Text(c.displayPart).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if let sp = c.supplierPart { Text("LCSC \(sp)").font(.caption.monospaced()).foregroundStyle(.secondary) }
                NumberInputBar(doc: doc, vertical: true, bare: true)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                Label("Tap a part on the board to select it.", systemImage: "hand.tap")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).multilineTextAlignment(.center)
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassEffect(in: .rect(cornerRadius: Theme.panelRadius))
    }

    // MARK: Gestures

    private var dockHandle: some View {
        Color.clear
            .frame(maxWidth: .infinity).frame(height: 14)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global).onChanged(dockResize).onEnded(dockSettle))
    }

    private func dockResize(_ v: DragGesture.Value) {
        guard showSidebar, screen.height > 0 else { dockDrag = v.translation.height; return }
        let start = dockStart ?? dockShare
        dockStart = start
        let want = start - v.translation.height / screen.height
        let lo = 0.22, hi = 0.75
        if want < lo { dockShare = lo; dockDrag = (lo - want) * screen.height }
        else { dockShare = min(want, hi); dockDrag = 0 }
    }

    private func dockSettle(_ v: DragGesture.Value) {
        let off = dockOff
        withAnimation(.spring(duration: 0.35)) {
            if showSidebar {
                if dockDrag > 80 || (dockDrag > 0 && v.predictedEndTranslation.height - v.translation.height > 150) { showSidebar = false }
            } else {
                showSidebar = off + v.predictedEndTranslation.height < off * 0.6
            }
            dockDrag = 0
        }
        dockStart = nil
    }

    /// Up/down shares the height between drawer and agent; sideways slides the sidebar.
    private func gapDrag(total: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { v in
                if gapAxis == nil { gapAxis = abs(v.translation.width) > abs(v.translation.height) ? .horizontal : .vertical }
                if gapAxis == .vertical {
                    let start = splitStart ?? split
                    splitStart = start
                    split = min(max(start + v.translation.height / total, 0.12), 0.88)
                } else {
                    slide = v.translation.width
                }
            }
            .onEnded { v in
                if gapAxis == .horizontal { settleSlide(v) }
                gapAxis = nil
                splitStart = nil
            }
    }

    private var slideHandle: some View {
        Color.clear
            .frame(width: 22).frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .global)
                .onChanged { slide = $0.translation.width }
                .onEnded(settleSlide))
    }

    private func settleSlide(_ v: DragGesture.Value) {
        let off = sidebarOff
        let end = (showSidebar ? 0 : off) + v.predictedEndTranslation.width
        withAnimation(.spring(duration: 0.35)) {
            showSidebar = end < off / 2
            slide = 0
        }
    }

    // MARK: Actions

    private func hide() { withAnimation(.spring) { showSidebar = false } }
    private func reveal() { withAnimation(.spring) { showSidebar = true } }

    private func openLibrary() {
        reveal()
        withAnimation(.spring(duration: 0.3)) { library = true; dockPage = 1 }
    }

    private func closeLibrary() {
        withAnimation(.spring(duration: 0.3)) { library = false }
    }

    /// A tool that asks the agent: send it, or (empty) bring the composer up.
    private func ask(_ prompt: String) {
        reveal()
        withAnimation { dockPage = 2 }
        if prompt.isEmpty { return }
        doc.agent.send(prompt)
    }
}
