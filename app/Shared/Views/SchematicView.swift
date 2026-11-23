import SwiftUI

enum SchematicRenderer {
    static func draw(_ ctx: inout GraphicsContext, model m: CircuitModel, t: ViewTransform, selection: String?, highlight: Set<String>) {
        let line = Palette.schLine, body = Palette.schBody
        let lw = max(1, t.len(0.03))
        for w in m.schWires {
            var p = Path(); p.move(to: t.toScreen(w.a)); p.addLine(to: t.toScreen(w.b))
            ctx.stroke(p, with: .color(line), lineWidth: lw)
        }
        for j in m.schJunctions {
            let s = t.toScreen(j), d = max(4, t.len(0.1))
            ctx.fill(Path(ellipseIn: CGRect(x: s.x - d / 2, y: s.y - d / 2, width: d, height: d)), with: .color(line))
        }
        for c in m.schComponents {
            guard let cc = c.schCenter, let sz = c.schSize else { continue }
            let r = PCBRenderer.screenRect(center: cc, size: sz, t: t)
            let selected = c.name == selection || highlight.contains(c.name)
            if let sym = c.symbol {
                drawSymbol(&ctx, sym, in: r, color: body, lw: lw)
            } else {
                let path = Path(roundedRect: r, cornerRadius: 2)
                ctx.fill(path, with: .color(body.opacity(0.06)))
                ctx.stroke(path, with: .color(body), lineWidth: lw)
            }
            if selected {
                ctx.stroke(Path(roundedRect: r.insetBy(dx: -6, dy: -6), cornerRadius: 6), with: .color(Palette.schematic.accent), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
        }

        // Text goes on last, most important first; anything that would overlap text already
        // placed is left out (zoom in to see it). Pin labels also scale with the zoom.
        var labels = LabelLayout()
        let paper = Palette.schematic.canvas
        for l in m.schLabels {
            let fs = max(7.5, t.len(0.16))
            let anchor: UnitPoint = switch l.side { case "left": .leading; case "right": .trailing; case "top": .top; default: .bottom }
            let at = t.toScreen(l.at)
            let gap: CGPoint = switch l.side { case "left": CGPoint(x: 2, y: 0); case "right": CGPoint(x: -2, y: 0); case "top": CGPoint(x: 0, y: 1); default: CGPoint(x: 0, y: -1) }
            labels.place(&ctx, l.text, size: fs, weight: .bold, color: Palette.schLabel, at: CGPoint(x: at.x + gap.x, y: at.y + gap.y), anchor: anchor, backing: paper)
        }
        let big = m.schTexts.filter { $0.size >= 0.16 }, small = m.schTexts.filter { $0.size < 0.16 }
        for tx in big {
            labels.place(&ctx, tx.text, size: max(7.5, t.len(tx.size)), weight: .semibold, color: body, at: t.toScreen(tx.at), anchor: Self.anchor(tx.anchor))
        }
        for c in m.schComponents {
            guard let cc = c.schCenter, let sz = c.schSize else { continue }
            labels.addObstacle(PCBRenderer.screenRect(center: cc, size: sz, t: t))
        }
        for p in m.schPorts {
            let a = t.toScreen(p.at)
            labels.addObstacle(CGRect(x: a.x - 3, y: a.y - 3, width: 6, height: 6))
        }
        for w in m.schWires {
            let a = t.toScreen(w.a), b = t.toScreen(w.b)
            labels.addObstacle(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).insetBy(dx: -1, dy: -1))
        }
        for c in m.schComponents where c.symbol != nil {
            guard let cc = c.schCenter, let sz = c.schSize else { continue }
            let r = PCBRenderer.screenRect(center: cc, size: sz, t: t)
            let fs = max(7.5, t.len(0.18)), vs = max(7, t.len(0.15))
            // Name over value, to the right of the symbol, else to its left.
            for (x, anchor) in [(r.maxX + 3, UnitPoint.leading), (r.minX - 3, UnitPoint.trailing)] {
                let name = CGPoint(x: x, y: c.value == nil ? r.midY : r.midY - fs * 0.6)
                let value = CGPoint(x: x, y: r.midY + fs * 0.6)
                guard labels.isFree(c.name, size: fs, at: name, anchor: anchor, avoidBodies: true) else { continue }
                labels.place(&ctx, c.name, size: fs, weight: .semibold, color: body, at: name, anchor: anchor, avoidBodies: true)
                if let v = c.value { labels.place(&ctx, v, size: vs, color: Palette.schMuted, at: value, anchor: anchor, avoidBodies: true) }
                break
            }
        }
        for tx in small {
            labels.place(&ctx, tx.text, size: max(6.5, t.len(tx.size)), color: Palette.schMuted, at: t.toScreen(tx.at), anchor: Self.anchor(tx.anchor), backing: paper)
        }
        // Pin names inside box parts: as big as the pin pitch allows, hidden when too small to read.
        let pfs = t.len(0.13)
        for p in m.schPorts {
            let s = t.toScreen(p.at)
            ctx.fill(Path(ellipseIn: CGRect(x: s.x - 1.5, y: s.y - 1.5, width: 3, height: 3)), with: .color(line))
            guard pfs >= 5, let label = p.label, let comp = p.componentId, m.component(named: comp)?.symbol == nil else { continue }
            let inward: CGPoint = switch p.side {
            case "left": CGPoint(x: s.x + 3 + t.len(0.4), y: s.y)
            case "right": CGPoint(x: s.x - 3 - t.len(0.4), y: s.y)
            case "top": CGPoint(x: s.x, y: s.y + 3 + t.len(0.4))
            default: CGPoint(x: s.x, y: s.y - 3 - t.len(0.4))
            }
            let anchor: UnitPoint = switch p.side { case "left": .leading; case "right": .trailing; case "top": .top; default: .bottom }
            labels.place(&ctx, label, size: min(pfs, 13), color: body.opacity(0.85), at: inward, anchor: anchor)
        }
    }

    /// circuit-json text anchors name the point of the text box that sits on `position`.
    static func anchor(_ a: String) -> UnitPoint {
        switch a {
        case "left": .leading
        case "right": .trailing
        case "top": .top
        case "bottom": .bottom
        case "top_left": .topLeading
        case "top_right": .topTrailing
        case "bottom_left": .bottomLeading
        case "bottom_right": .bottomTrailing
        default: .center
        }
    }

    /// Simple symbols keyed by tscircuit symbol names (`boxresistor_down`, `capacitor_right`...).
    static func drawSymbol(_ ctx: inout GraphicsContext, _ name: String, in r: CGRect, color: Color, lw: CGFloat) {
        let vertical = name.hasSuffix("_down") || name.hasSuffix("_up")
        var c = ctx
        c.translateBy(x: r.midX, y: r.midY)
        if !vertical { c.rotate(by: .degrees(90)) }
        let len = vertical ? r.height : r.width
        let wid = vertical ? r.width : r.height
        let half = len / 2
        var leads = Path()
        let st = StrokeStyle(lineWidth: lw, lineCap: .round)
        if name.contains("resistor") {
            let body = CGRect(x: -wid * 0.22, y: -half * 0.55, width: wid * 0.44, height: half * 1.1)
            c.stroke(Path(body), with: .color(color), style: st)
            leads.move(to: CGPoint(x: 0, y: -half)); leads.addLine(to: CGPoint(x: 0, y: -half * 0.55))
            leads.move(to: CGPoint(x: 0, y: half * 0.55)); leads.addLine(to: CGPoint(x: 0, y: half))
        } else if name.contains("capacitor") {
            let g = half * 0.18
            var plates = Path()
            plates.move(to: CGPoint(x: -wid * 0.38, y: -g)); plates.addLine(to: CGPoint(x: wid * 0.38, y: -g))
            plates.move(to: CGPoint(x: -wid * 0.38, y: g)); plates.addLine(to: CGPoint(x: wid * 0.38, y: g))
            c.stroke(plates, with: .color(color), style: StrokeStyle(lineWidth: lw * 1.6, lineCap: .round))
            leads.move(to: CGPoint(x: 0, y: -half)); leads.addLine(to: CGPoint(x: 0, y: -g))
            leads.move(to: CGPoint(x: 0, y: g)); leads.addLine(to: CGPoint(x: 0, y: half))
        } else if name.contains("led") || name.contains("diode") {
            let s = min(wid * 0.36, half * 0.4)
            var tri = Path()
            tri.move(to: CGPoint(x: -s, y: -s * 0.8)); tri.addLine(to: CGPoint(x: s, y: -s * 0.8)); tri.addLine(to: CGPoint(x: 0, y: s * 0.8)); tri.closeSubpath()
            c.stroke(tri, with: .color(color), style: st)
            var bar = Path(); bar.move(to: CGPoint(x: -s, y: s * 0.8)); bar.addLine(to: CGPoint(x: s, y: s * 0.8))
            c.stroke(bar, with: .color(color), style: st)
            leads.move(to: CGPoint(x: 0, y: -half)); leads.addLine(to: CGPoint(x: 0, y: -s * 0.8))
            leads.move(to: CGPoint(x: 0, y: s * 0.8)); leads.addLine(to: CGPoint(x: 0, y: half))
            if name.contains("led") {
                var arrows = Path()
                for k in [0.0, 1.0] {
                    let y0 = -s * 0.2 + CGFloat(k) * s * 0.5
                    arrows.move(to: CGPoint(x: s * 1.1, y: y0)); arrows.addLine(to: CGPoint(x: s * 1.8, y: y0 - s * 0.5))
                }
                c.stroke(arrows, with: .color(color), style: StrokeStyle(lineWidth: lw * 0.8, lineCap: .round))
            }
        } else {
            c.stroke(Path(CGRect(x: -wid / 2, y: -half, width: wid, height: len)), with: .color(color), style: st)
        }
        c.stroke(leads, with: .color(color), style: st)
    }
}

struct SchematicView: View {
    @Bindable var doc: DocumentModel
    @State private var t = ViewTransform()
    @State private var panStart: CGPoint?
    @State private var zoomStart: CGFloat?
    @State private var fitted = false
    @State private var lastSize: CGSize = .zero
    /// Set once you pan or zoom; until then the drawing refits whenever the view changes size.
    @State private var userMoved = false
    /// Space covered by floating panels; the drawing fits in what is left.
    var fitInsets = EdgeInsets()

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                var tt = t
                tt.size = size
                SchematicRenderer.draw(&ctx, model: doc.circuit, t: tt, selection: doc.selection, highlight: [])
            }
            .background(Palette.schematic.canvas)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { v in
                    if panStart == nil { panStart = t.center; userMoved = true }
                    if let s = panStart { t.center = CGPoint(x: s.x - v.translation.width / t.scale, y: s.y + v.translation.height / t.scale) }
                }
                .onEnded { _ in panStart = nil })
            .simultaneousGesture(MagnifyGesture()
                .onChanged { v in
                    if zoomStart == nil { zoomStart = t.scale; userMoved = true }
                    t.zoom(to: min(800, max(4, (zoomStart ?? t.scale) * v.magnification)), about: v.startLocation)
                }
                .onEnded { _ in zoomStart = nil })
            .onTapGesture(count: 2) { userMoved = false; fit(geo.size, animated: true) }
            .onTapGesture { loc in doc.select(doc.circuit.schHitTest(t.toBoard(loc))?.name, reveal: true) }
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
            .accessibilityLabel("Schematic view")
        }
    }

    /// Fit the drawing into the part of the screen the bar and panels leave clear.
    private func fit(_ size: CGSize, animated: Bool = false) {
        // Names and values sit outside the parts, mostly above them.
        guard !doc.circuit.isEmpty,
              let nt = ViewTransform.fit(doc.circuit.schBounds.insetBy(dx: -0.4, dy: -0.6), in: size, insets: fitInsets, padding: 24)
        else { return }
        if animated { withAnimation(.snappy) { t = nt } } else { t = nt }
        fitted = true
    }
}

/// Greedy label placement: each label is drawn only if its box is clear of the ones before it.
struct LabelLayout {
    private var placed: [CGRect] = []
    private var bodies: [CGRect] = []

    /// Monospaced box for `text` at `size`, positioned so `anchor` sits on `at`.
    static func box(_ text: String, size: CGFloat, at: CGPoint, anchor: UnitPoint) -> CGRect {
        let w = CGFloat(text.count) * size * 0.61, h = size * 1.2
        return CGRect(x: at.x - w * anchor.x, y: at.y - h * anchor.y, width: w, height: h)
    }

    /// A part body that labels placed with `avoidBodies` keep clear of.
    mutating func addObstacle(_ r: CGRect) { bodies.append(r) }

    func isFree(_ text: String, size: CGFloat, at: CGPoint, anchor: UnitPoint, avoidBodies: Bool = false) -> Bool {
        let probe = Self.box(text, size: size, at: at, anchor: anchor).insetBy(dx: 1, dy: size * 0.15)
        if placed.contains(where: { $0.intersects(probe) }) { return false }
        return !avoidBodies || !bodies.contains(where: { $0.intersects(probe) })
    }

    @discardableResult
    mutating func place(_ ctx: inout GraphicsContext, _ text: String, size: CGFloat, weight: Font.Weight = .regular, color: Color,
                        at: CGPoint, anchor: UnitPoint, backing: Color? = nil, avoidBodies: Bool = false) -> Bool {
        guard !text.isEmpty, isFree(text, size: size, at: at, anchor: anchor, avoidBodies: avoidBodies) else { return false }
        let r = Self.box(text, size: size, at: at, anchor: anchor)
        placed.append(r)
        if let backing { ctx.fill(Path(roundedRect: r.insetBy(dx: -1.5, dy: 0), cornerRadius: 2), with: .color(backing.opacity(0.85))) }
        ctx.draw(Text(text).font(.system(size: size, weight: weight, design: .monospaced)).foregroundStyle(color), at: at, anchor: anchor)
        return true
    }
}
