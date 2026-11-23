import SwiftUI

/// The live PCB view: full-bleed canvas with pan, pinch-zoom (with inertia), tap-to-select,
/// drag-to-move with a 60 Hz ghost that snaps to the grid, measure, route and via tools.
struct PCBView: View {
    @Bindable var doc: DocumentModel
    @State private var t = ViewTransform()
    @State private var fitted = false
    @State private var panStart: CGPoint?
    @State private var zoomStart: CGFloat?
    @State private var dragging: (name: String, start: CGPoint)?
    @State private var ghostOffset: CGPoint = .zero
    @State private var lastSize: CGSize = .zero
    /// Set once you pan or zoom; until then the board refits whenever the view or panels change.
    @State private var userMoved = false
    var compact = false
    /// Space covered by floating panels; the board fits in what is left.
    var fitInsets = EdgeInsets()

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                var tt = t
                tt.size = size
                let overlay = PCBOverlay(
                    selection: doc.selection,
                    ghost: dragging.map { ($0.name, ghostOffset) },
                    measure: doc.measureA.map { ($0, doc.measureB) },
                    routeFrom: doc.routeFrom?.at,
                    drcMarkers: doc.violations.compactMap { v in doc.violationPosition(v).map { ($0, v.isError) } }
                )
                PCBRenderer.draw(&ctx, model: doc.circuit, t: tt, layers: doc.layerVisible, opacity: doc.layerOpacity, overlay: overlay)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .simultaneousGesture(zoomGesture)
            .onTapGesture(count: 2) { userMoved = false; fit(geo.size, animated: true) }
            .onTapGesture { loc in tap(at: loc) }
            .contextMenu { contextMenu }
            #if os(macOS)
            .modifier(ScrollZoom(t: $t) { userMoved = true })
            #endif
            .onAppear { lastSize = geo.size; t.size = geo.size; fit(geo.size) }
            .onChange(of: geo.size) { _, s in
                t.size = s
                if !fitted || !userMoved || lastSize == .zero { fit(s) }
                lastSize = s
            }
            .onChange(of: doc.circuit.elementCount) { _, _ in if !fitted { fit(geo.size) } }
            .onChange(of: fitInsets) { old, new in
                if userMoved { t.recentre(from: old, to: new) } else { fit(geo.size) }
            }
            .onChange(of: doc.fitRequested) { _, _ in userMoved = false; fit(geo.size, animated: true) }
            .overlay(alignment: .bottomTrailing) { measureReadout.padding(12) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("PCB view, \(doc.circuit.components.count) components")
        }
    }

    private func fit(_ size: CGSize, animated: Bool = false) {
        guard !doc.circuit.isEmpty,
              let nt = ViewTransform.fit(doc.circuit.pcbBounds.insetBy(dx: -3, dy: -3), in: size, insets: fitInsets, padding: compact ? 16 : 40)
        else { return }
        if animated { withAnimation(.snappy) { t = nt } } else { t = nt }
        fitted = true
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in
                if dragging == nil, panStart == nil {
                    let p = t.toBoard(v.startLocation)
                    if doc.tool == .select, !doc.showsAgentView, let c = doc.circuit.hitTest(p), c.name == doc.selection || doc.selection == nil {
                        doc.selection = c.name
                        dragging = (c.name, c.center)
                    } else {
                        panStart = t.center
                        userMoved = true
                    }
                }
                if let d = dragging {
                    // Snap the component centre to the grid (or a pad centre nearby).
                    let raw = CGPoint(x: v.translation.width / t.scale, y: -v.translation.height / t.scale)
                    let target = CGPoint(x: doc.snap(d.start.x + raw.x), y: doc.snap(d.start.y + raw.y))
                    ghostOffset = CGPoint(x: target.x - d.start.x, y: target.y - d.start.y)
                } else if let s = panStart {
                    t.center = CGPoint(x: s.x - v.translation.width / t.scale, y: s.y + v.translation.height / t.scale)
                }
            }
            .onEnded { v in
                if let d = dragging {
                    let target = CGPoint(x: d.start.x + ghostOffset.x, y: d.start.y + ghostOffset.y)
                    let moved = ghostOffset != .zero
                    let name = d.name
                    Task {
                        if moved { await doc.move(name, to: target) }
                        dragging = nil
                        ghostOffset = .zero
                    }
                } else if let s = panStart {
                    // Inertia: glide toward the predicted end.
                    let end = CGPoint(x: s.x - v.predictedEndTranslation.width / t.scale, y: s.y + v.predictedEndTranslation.height / t.scale)
                    withAnimation(.easeOut(duration: 0.35)) { t.center = end }
                }
                panStart = nil
            }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if zoomStart == nil { zoomStart = t.scale; userMoved = true }
                let anchor = t.toBoard(v.startLocation)
                let newScale = min(400, max(1, (zoomStart ?? t.scale) * v.magnification))
                // Keep the pinch point fixed.
                t.scale = newScale
                let after = t.toBoard(v.startLocation)
                t.center = CGPoint(x: t.center.x + anchor.x - after.x, y: t.center.y + anchor.y - after.y)
            }
            .onEnded { _ in zoomStart = nil }
    }

    private func tap(at loc: CGPoint) {
        let p = t.toBoard(loc)
        switch doc.tool {
        case .select:
            doc.select(doc.circuit.hitTest(p)?.name, reveal: true)
        case .measure:
            if doc.measureA == nil || doc.measureB != nil {
                doc.measureA = CGPoint(x: doc.snap(p.x), y: doc.snap(p.y)); doc.measureB = nil
            } else {
                doc.measureB = CGPoint(x: doc.snap(p.x), y: doc.snap(p.y))
            }
        case .place:
            Task { await doc.placePart(at: p) }
        case .via:
            Task { await doc.placeVia(at: p) }
        case .route:
            Task { await doc.routeTap(at: p) }
        }
    }

    @ViewBuilder private var contextMenu: some View {
        if let s = doc.selection {
            Button("Rotate 90°", systemImage: "rotate.right") { Task { await doc.nudgeRotation(s, by: 90) } }
            Button("Show in source", systemImage: "chevron.left.forwardslash.chevron.right") { doc.revealInSource(s); doc.viewMode = doc.viewMode }
            Button("Ask the agent about \(s)", systemImage: "sparkles") { doc.agent.draft = "\(s): " }
            Divider()
        }
        Button("Fit board", systemImage: "arrow.up.left.and.arrow.down.right") { fit(lastSize, animated: true) }
    }

    @ViewBuilder private var measureReadout: some View {
        if doc.tool == .measure, let a = doc.measureA, let b = doc.measureB {
            let dx = b.x - a.x, dy = b.y - a.y
            VStack(alignment: .leading, spacing: 2) {
                Text("\(fmt(Double(hypot(dx, dy)))) mm").font(Theme.mono(15, .semibold))
                Text("dX \(fmt(Double(dx)))  dY \(fmt(Double(dy)))").font(Theme.mono(12)).foregroundStyle(Theme.muted)
            }
            .padding(12).glassPanel(radius: 16)
        } else if doc.tool == .route, let r = doc.routeFrom {
            Text("From \(r.component).\(r.port): tap the other pad").font(.callout).padding(10).glassPanel(radius: 14)
        }
    }
}

#if os(macOS)
/// Trackpad/mouse: two-finger scroll pans, ⌘-scroll zooms about the pointer.
struct ScrollZoom: ViewModifier {
    @Binding var t: ViewTransform
    var moved: () -> Void = {}
    @State private var monitor: Any?
    @State private var pointer: CGPoint?
    func body(content: Content) -> some View {
        content
            .onContinuousHover { phase in
                if case .active(let p) = phase { pointer = p } else { pointer = nil }
            }
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
                    guard let p = pointer else { return e }
                    moved()
                    if e.modifierFlags.contains(.command) {
                        let f = 1 + e.scrollingDeltaY * 0.01
                        t.zoom(to: min(400, max(1, t.scale * f)), about: p)
                    } else {
                        t.center.x -= e.scrollingDeltaX / t.scale
                        t.center.y += e.scrollingDeltaY / t.scale
                    }
                    return nil
                }
            }
            .onDisappear { if let m = monitor { NSEvent.removeMonitor(m) } }
    }
}
#endif
