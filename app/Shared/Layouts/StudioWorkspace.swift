import SwiftUI

/// The board studio, laid out like Nurby's part studio on every device: the live view full-bleed,
/// one bar floating at the bottom (back, the Schematic / PCB / 3D / Code switcher, the view's
/// tools, PCB layers, DRC and the panels button; drag it up or down to resize or hide the
/// panels), and one sidebar on the right: the drawer (parts, layers, files, history, or the parts
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
    /// A drag on the bar is resizing the panels (vertical) rather than scrolling it.
    @State private var barAxis: Axis?
    /// A finger is held on the bar reading names: its drag doesn't move the panels.
    @State private var barScrubbing = false
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
    /// The bar and the space under it.
    private let barBand: CGFloat = 56 + 14
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

    private var palette: Palette { .for(doc.viewMode) }

    var body: some View {
        ZStack {
            palette.canvas.ignoresSafeArea()
            LiveView(doc: doc, compact: narrow, fitInsets: fitInsets)
                .ignoresSafeArea()

            selectionOverlay
            bar

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

    /// What the bar and panels cover: the views fit, centre and zoom the board in the rest. The views
    /// ignore the safe area but the bar keeps above it, so its bottom inset counts.
    private var fitInsets: EdgeInsets {
        EdgeInsets(top: margin + topInset, leading: 0,
                   bottom: (typingDocked ? 0 : barBand + insets.bottom) + dockVisible + margin,
                   trailing: sideCover)
    }

    // MARK: Selection

    private var showsSelectionCard: Bool {
        doc.viewMode == .pcb && doc.selection != nil && !(docked && dockPaged && dockOffset == 0)
    }

    /// The selected part's exact position, top left of the open area.
    private var selectionOverlay: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading) {
                if showsSelectionCard {
                    NumberInputBar(doc: doc, vertical: true)
                        .frame(width: 350, alignment: .leading)
                        .transition(.scale(scale: 0.92, anchor: .topLeading).combined(with: .opacity))
                }
                Spacer(minLength: 0)
            }
            .padding(margin)
            .padding(.top, topInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            if !docked { Color.clear.frame(width: sideCover).allowsHitTesting(false) }
        }
        .animation(.snappy(duration: 0.25), value: doc.selection)
    }

    // MARK: Bar

    @Namespace private var barSpace
    /// The width the bar's tools want (reported by the bar).
    @State private var barContent: CGFloat = 0
    /// The room for the bar: the screen less the sidebar and the margins.
    private var barRoom: CGFloat { screen.width - (docked ? 0 : sideCover) - margin * 2 }
    /// Not enough room for the bar's tools and the panels button side by side.
    private var barTight: Bool { barContent > 0 && barContent + 8 + 56 > barRoom }

    private var panelsButton: some View {
        PanelsButton(shown: !sidebarAway,
                     symbol: docked ? "rectangle.bottomhalf.inset.filled" : "sidebar.right",
                     blocked: barAxis == .vertical,
                     action: { sidebarAway ? reveal() : hide() })
            .matchedGeometryEffect(id: "panels", in: barSpace)
    }

    /// The bar, centred in the part of the screen the panels leave open, above the dock. The panels
    /// button sits to its right, or above its right end when the bar's tools need the room.
    private var bar: some View {
        HStack(spacing: 0) {
            VStack(alignment: .trailing, spacing: 10) {
                Spacer()
                if barTight { panelsButton }
                if doc.tool == .place && doc.viewMode == .pcb { PlacingChip(doc: doc).frame(maxWidth: .infinity) }
                HStack(spacing: 8) {
                    StudioBar(doc: doc, short: narrow, blocked: barAxis == .vertical,
                              back: onClose, addPart: openLibrary, ask: ask,
                              contentWidth: { barContent = $0 }, scrubbing: { barScrubbing = $0 })
                        .fixedSize(horizontal: false, vertical: true)
                    if !barTight { panelsButton }
                }
            }
            .simultaneousGesture(barDrag)
            .animation(.snappy(duration: 0.3), value: barTight)
            .padding(.horizontal, margin)
            .padding(.bottom, 14 + dockVisible)
            // While typing to the agent the keyboard takes the room the bar had.
            .opacity(typingDocked ? 0 : 1)
            .allowsHitTesting(!typingDocked)
            .animation(.easeOut(duration: 0.2), value: typingDocked)
            .frame(maxWidth: .infinity)
            if !docked { Color.clear.frame(width: sideCover).allowsHitTesting(false) }
        }
    }

    /// Up or down on the bar does what the panels' top edge does: resize them, or drag them away
    /// and back. In the side layout, down puts the sidebar away and up brings it back. Sideways
    /// drags are left to the bar's own scrolling, and taps to its buttons.
    private var barDrag: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { v in
                if barAxis == nil && barScrubbing { barAxis = .horizontal }
                if barAxis == nil { barAxis = abs(v.translation.height) > abs(v.translation.width) ? .vertical : .horizontal }
                if barAxis == .vertical && docked { dockResize(v) }
            }
            .onEnded { v in
                if barAxis == .vertical {
                    if docked { dockSettle(v) }
                    else if v.predictedEndTranslation.height > 60 { hide() }
                    else if v.predictedEndTranslation.height < -60 { reveal() }
                }
                // Let go after the button under the finger has seen the lift (and stayed blocked).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { barAxis = nil }
            }
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
